#!/usr/bin/env python3
"""Turn a Playwright regression run into metrics/regression-metrics.json.

Reads what app/e2e/conftest.py writes (cases.json, latency.json), plus the
optional container.json the CI job writes after starting the image, and the
Status column of app/e2e/MANUAL_TEST_PLAN.md. Validates the result against
metrics/regression-metrics.schema.json with the same stdlib validator
emit-runtime-metrics.py uses, and writes a Markdown table next to the
bundle (regression-summary.md). Works under GitHub Actions and GitLab CI:
the table is also appended to $GITHUB_STEP_SUMMARY when set, and printed
to the job log under GitLab, which has no summary page.

Exits non-zero only if inputs are missing or the output fails validation —
test failures are reported by the pytest step itself, not here.
"""

from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import math
import os
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
PLAN_ROW = re.compile(r"^\|\s*(TC-\d+)\s*\|.*\|\s*(automated|manual-only)\s*\|\s*$")


def load_validator():
    spec = importlib.util.spec_from_file_location(
        "emit_runtime_metrics", REPO_ROOT / "scripts" / "emit-runtime-metrics.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.validate_bundle


def percentile(sorted_values: list[float], pct: float) -> float:
    return sorted_values[max(math.ceil(pct / 100 * len(sorted_values)) - 1, 0)]


def latency_stats(samples_by_path: dict[str, list[float]]) -> dict[str, dict]:
    stats = {}
    for path, samples in sorted(samples_by_path.items()):
        if not samples:
            continue
        ordered = sorted(samples)
        stats[path] = {
            "samples": len(ordered),
            "p50": round(percentile(ordered, 50), 2),
            "p95": round(percentile(ordered, 95), 2),
            "max": round(ordered[-1], 2),
        }
    return stats


def plan_counts(plan_path: pathlib.Path) -> dict:
    statuses = [
        m.group(2)
        for line in plan_path.read_text(encoding="utf-8").splitlines()
        if (m := PLAN_ROW.match(line))
    ]
    automated = statuses.count("automated")
    return {
        "cases_total": len(statuses),
        "cases_automated": automated,
        "cases_manual_only": statuses.count("manual-only"),
        "automation_pct": round(100 * automated / len(statuses), 1)
        if statuses
        else 0.0,
    }


def run_url() -> str | None:
    server, repo, run_id = (
        os.getenv("GITHUB_SERVER_URL"),
        os.getenv("GITHUB_REPOSITORY"),
        os.getenv("GITHUB_RUN_ID"),
    )
    if server and repo and run_id:
        return f"{server}/{repo}/actions/runs/{run_id}"
    return os.getenv("CI_PIPELINE_URL")


def build(args: argparse.Namespace) -> dict:
    results_dir = pathlib.Path(args.results_dir)
    run = json.loads((results_dir / "cases.json").read_text())
    latency = json.loads((results_dir / "latency.json").read_text())
    container_path = results_dir / "container.json"
    container = (
        json.loads(container_path.read_text())
        if container_path.exists()
        else {
            "ready_seconds": None,
            "image_size_bytes": None,
            "hardened_runtime": False,
        }
    )

    cases = run["cases"]
    outcomes = [c["outcome"] for c in cases]
    passed, failed = outcomes.count("pass"), outcomes.count("fail")
    executed = passed + failed

    return {
        "schema_version": "1",
        "project": args.project,
        "collected_at": datetime.datetime.now(datetime.UTC).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "target_env": run["target_env"],
        "commit": os.getenv("GITHUB_SHA") or os.getenv("CI_COMMIT_SHA"),
        "run_url": run_url(),
        "tooling": {
            "playwright_version": run["playwright_version"],
            "browser": run["browser"],
        },
        "container": container,
        "plan": plan_counts(pathlib.Path(args.plan)),
        "results": {
            "tests": len(cases),
            "passed": passed,
            "failed": failed,
            "skipped": outcomes.count("skipped"),
            "pass_rate_pct": round(100 * passed / executed, 1) if executed else 0.0,
            "duration_seconds": run["duration_seconds"],
        },
        "latency_ms": latency_stats(latency),
        "cases": cases,
    }


def markdown(bundle: dict) -> str:
    r, p, c = bundle["results"], bundle["plan"], bundle["container"]
    lines = [
        f"## Playwright regression — `{bundle['target_env']}`",
        "",
        "| Metric | Value |",
        "|---|---|",
        f"| Tests passed | {r['passed']}/{r['tests']} ({r['pass_rate_pct']}%) |",
        f"| Suite duration | {r['duration_seconds']} s |",
        (
            f"| Test plan automated | {p['cases_automated']}/{p['cases_total']} "
            f"({p['automation_pct']}%) |"
        ),
        (
            f"| Playwright | {bundle['tooling']['playwright_version']} "
            f"({bundle['tooling']['browser']}) |"
        ),
    ]
    if c["ready_seconds"] is not None:
        lines.append(f"| Container ready (HEALTHCHECK) | {c['ready_seconds']} s |")
    if c["image_size_bytes"] is not None:
        lines.append(f"| Image size | {c['image_size_bytes'] / 1_000_000:.1f} MB |")
    for path, s in bundle["latency_ms"].items():
        lines.append(
            f"| `{path}` latency p50 / p95 | {s['p50']} / {s['p95']} ms "
            f"(n={s['samples']}) |"
        )
    lines += ["", "| Case | Test | Result | ms |", "|---|---|---|---|"]
    for case in bundle["cases"]:
        icon = {"pass": "✅", "fail": "❌", "skipped": "⏭️"}[case["outcome"]]
        test = case["test"].split("::")[-1]
        lines.append(
            f"| {case['case']} | `{test}` | {icon} | {case['duration_ms']:.0f} |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project", required=True, choices=["eks-gitops", "aks-pipeline"]
    )
    parser.add_argument("--results-dir", default="app/e2e/test-results")
    parser.add_argument("--plan", default="app/e2e/MANUAL_TEST_PLAN.md")
    parser.add_argument("--out", default="app/e2e/test-results/regression-metrics.json")
    parser.add_argument(
        "--schema",
        default=str(REPO_ROOT / "metrics" / "regression-metrics.schema.json"),
    )
    args = parser.parse_args()

    try:
        bundle = build(args)
    except FileNotFoundError as exc:
        print(f"[summarize-regression] missing input: {exc.filename}", file=sys.stderr)
        return 1

    schema = json.loads(pathlib.Path(args.schema).read_text())
    errors = load_validator()(bundle, schema)
    if errors:
        print(
            "[summarize-regression] output failed schema validation:", file=sys.stderr
        )
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(bundle, indent=2) + "\n")
    print(f"[summarize-regression] wrote {out}")

    table = markdown(bundle)
    (out.parent / "regression-summary.md").write_text(table, encoding="utf-8")
    summary_path = os.getenv("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as fh:
            fh.write(table)
    elif os.getenv("GITLAB_CI"):
        print(table)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
