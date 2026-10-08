"""Shared fixtures and hooks for the Playwright regression suite.

Target selection (see test-data/environments.json):
    E2E_ENV               ci | local | staging | prod   (default: local)
    E2E_BASE_URL          overrides the environment's base_url
    E2E_EXPECTED_VERSION  exact build version to assert (e.g. sha-1a2b3c4)
    E2E_RESULTS_DIR       where cases.json / latency.json go (default: test-results)
"""

from __future__ import annotations

import json
import os
import time
from collections import defaultdict
from collections.abc import Callable, Generator
from dataclasses import dataclass, field
from importlib.metadata import version
from pathlib import Path
from typing import Any

import pytest
from playwright.sync_api import APIRequestContext, APIResponse, Playwright
from targets import PLAN_PATH, Target, load_plan, load_target


@dataclass
class RunRecord:
    started: float = field(default_factory=time.time)
    cases: dict[str, dict[str, Any]] = field(default_factory=dict)
    latency_ms: dict[str, list[float]] = field(
        default_factory=lambda: defaultdict(list)
    )


# pytest_runtest_logreport receives no config object, so the run record is
# module-level rather than stashed on the config.
_RECORD = RunRecord()


def results_dir(config: pytest.Config) -> Path:
    path = Path(os.getenv("E2E_RESULTS_DIR", config.rootpath / "test-results"))
    path.mkdir(parents=True, exist_ok=True)
    return path


# ─── Plan ↔ test traceability ────────────────────────────────────────────────


def pytest_collection_modifyitems(
    config: pytest.Config, items: list[pytest.Item]
) -> None:
    plan = load_plan()
    covered: set[str] = set()
    errors: list[str] = []

    for item in items:
        markers = list(item.iter_markers(name="case"))
        if len(markers) != 1 or len(markers[0].args) != 1:
            errors.append(f"{item.nodeid}: needs exactly one @pytest.mark.case(id)")
            continue
        case_id = markers[0].args[0]
        if case_id not in plan:
            errors.append(f"{item.nodeid}: {case_id} is not in {PLAN_PATH.name}")
            continue
        covered.add(case_id)
        item.user_properties.append(("case", case_id))

    full_run = (
        config.args_source != pytest.Config.ArgsSource.ARGS
        and not config.option.keyword
        and not config.option.markexpr
    )
    if full_run:
        for case_id, status in plan.items():
            if status == "automated" and case_id not in covered:
                errors.append(f"{case_id} is marked automated but has no test")

    if errors:
        raise pytest.UsageError("Test plan traceability:\n  " + "\n  ".join(errors))


def pytest_runtest_logreport(report: pytest.TestReport) -> None:
    entry = _RECORD.cases.setdefault(
        report.nodeid,
        {
            "case": dict(report.user_properties).get("case"),
            "test": report.nodeid,
            "outcome": "pass",
            "duration_ms": 0.0,
        },
    )
    entry["duration_ms"] = round(entry["duration_ms"] + report.duration * 1000, 3)
    if report.skipped:
        entry["outcome"] = "skipped"
    elif report.failed:
        entry["outcome"] = "fail"


def pytest_sessionfinish(session: pytest.Session) -> None:
    config = session.config
    target = load_target()
    out = results_dir(config)

    summary = {
        "target_env": target.name,
        "base_url": target.base_url,
        "playwright_version": version("playwright"),
        "browser": config.getoption("browser", default=["chromium"])[0],
        "duration_seconds": round(time.time() - _RECORD.started, 3),
        "cases": sorted(
            _RECORD.cases.values(), key=lambda c: (c["case"] or "", c["test"])
        ),
    }
    (out / "cases.json").write_text(json.dumps(summary, indent=2) + "\n")
    (out / "latency.json").write_text(
        json.dumps(dict(_RECORD.latency_ms), indent=2) + "\n"
    )


# ─── Fixtures ────────────────────────────────────────────────────────────────


@pytest.fixture(scope="session")
def target() -> Target:
    try:
        return load_target()
    except ValueError as exc:
        raise pytest.UsageError(str(exc)) from exc


@pytest.fixture(scope="session")
def base_url(target: Target) -> str:
    # Overrides pytest-base-url so page.goto("/docs") resolves against the target.
    return target.base_url


@pytest.fixture(scope="session")
def api(
    playwright: Playwright, target: Target
) -> Generator[APIRequestContext, None, None]:
    context = playwright.request.new_context(base_url=target.base_url, timeout=10_000)
    yield context
    context.dispose()


@pytest.fixture
def timed_get(api: APIRequestContext) -> Callable[[str], APIResponse]:
    """GET a path and record its wall-clock latency for latency.json."""

    def _get(path: str) -> APIResponse:
        start = time.perf_counter()
        response = api.get(path)
        elapsed_ms = (time.perf_counter() - start) * 1000
        _RECORD.latency_ms[path].append(round(elapsed_ms, 3))
        return response

    return _get
