"""Test-data loading shared by conftest.py and the test modules."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path

E2E_DIR = Path(__file__).resolve().parent
PLAN_PATH = E2E_DIR / "MANUAL_TEST_PLAN.md"
ENVIRONMENTS_PATH = E2E_DIR / "test-data" / "environments.json"
PLAN_ROW = re.compile(r"^\|\s*(TC-\d+)\s*\|.*\|\s*(automated|manual-only)\s*\|\s*$")


@dataclass(frozen=True)
class Target:
    name: str
    base_url: str
    expected: dict[str, str]
    version_pattern: str
    latency_p95_budget_ms: float
    expected_version: str | None


def load_plan() -> dict[str, str]:
    """Case ID → status ("automated" | "manual-only") from MANUAL_TEST_PLAN.md."""
    plan: dict[str, str] = {}
    for line in PLAN_PATH.read_text(encoding="utf-8").splitlines():
        match = PLAN_ROW.match(line)
        if match:
            plan[match.group(1)] = match.group(2)
    return plan


def load_target() -> Target:
    name = os.getenv("E2E_ENV", "local")
    environments = json.loads(ENVIRONMENTS_PATH.read_text(encoding="utf-8"))
    if name not in environments:
        raise ValueError(
            f"E2E_ENV={name!r} not in {sorted(environments)} ({ENVIRONMENTS_PATH})"
        )
    env = environments[name]
    return Target(
        name=name,
        base_url=os.getenv("E2E_BASE_URL", env["base_url"]).rstrip("/"),
        expected=env["expected"],
        version_pattern=env["version_pattern"],
        latency_p95_budget_ms=float(env["latency_p95_budget_ms"]),
        expected_version=os.getenv("E2E_EXPECTED_VERSION") or None,
    )
