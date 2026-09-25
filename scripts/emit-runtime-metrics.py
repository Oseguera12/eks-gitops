#!/usr/bin/env python3
"""Merge CI gate results, the runtime drill output, the admission fixture
results, and a cost snapshot into metrics/runtime-metrics.json, then validate
the bundle against metrics/runtime-metrics.schema.json before exiting.

Deliberately stdlib-only (no jsonschema/pyyaml dependency) so it drops into
the existing CI images (python:3.12-slim, ubuntu-latest) with no extra
install step. The validator below implements only the subset of JSON Schema
the shared schema actually uses — see metrics/runtime-metrics.schema.json,
which is the same file (same shape) in eks-gitops, aks-pipeline,
platform-engineering-lab, and cowrie-honeypot.

Exit code is non-zero if the merged bundle fails schema validation — the CI
job that calls this must NOT treat a failed validation as passable.
"""

from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_SCHEMA = REPO_ROOT / "metrics" / "runtime-metrics.schema.json"
DEFAULT_OUT = REPO_ROOT / "metrics" / "runtime-metrics.json"

PROJECT_DEFAULT_SENSOR = {
    "eks-gitops": "falco",
    "aks-pipeline": "defender",
    "platform-engineering-lab": "falco",
    "cowrie-honeypot": "none",
}


def utc_now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path: str | None) -> dict:
    if not path:
        return {}
    p = pathlib.Path(path)
    if not p.exists():
        print(f"[emit-runtime-metrics] note: {path} not found, using defaults", file=sys.stderr)
        return {}
    return json.loads(p.read_text())


def parse_gate(spec: str) -> dict:
    # NAME:STATUS:DURATION_MS
    try:
        name, status, duration_ms = spec.split(":", 2)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"--gate must be NAME:STATUS:DURATION_MS, got {spec!r}"
        ) from exc
    if status not in ("pass", "fail", "skipped"):
        raise argparse.ArgumentTypeError(f"--gate status must be pass|fail|skipped, got {status!r}")
    return {"name": name, "status": status, "duration_ms": float(duration_ms)}


def build_bundle(args: argparse.Namespace) -> dict:
    admission_extra = load_json(args.admission_json)
    runtime_extra = load_json(args.runtime_json)

    gates = list(args.gate)
    if args.gates_json:
        p = pathlib.Path(args.gates_json)
        if p.exists():
            gates.extend(json.loads(p.read_text()))
        else:
            print(f"[emit-runtime-metrics] note: {args.gates_json} not found, skipping", file=sys.stderr)

    deploy = {
        "duration_seconds": args.deploy_duration_seconds,
        "destroy_confirmed": args.destroy_confirmed,
    }
    if args.rebuild_duration_seconds is not None:
        deploy["rebuild_duration_seconds"] = args.rebuild_duration_seconds
    if args.cluster_stopped:
        deploy["cluster_stopped"] = True

    identity = {
        "oidc_auth_success": args.oidc_success,
        "long_lived_cloud_keys_in_ci": args.long_lived_keys,
    }

    admission = {
        "policies_evaluated": admission_extra.get("policies_evaluated", 0),
        "violations_blocked": admission_extra.get("violations_blocked", 0),
        "fixture_failures": admission_extra.get("fixture_failures", 0),
    }

    runtime = {
        "sensor": runtime_extra.get("sensor", args.sensor or PROJECT_DEFAULT_SENSOR[args.project]),
        "alerts": runtime_extra.get("alerts", []),
        "mttd_seconds": runtime_extra.get("mttd_seconds"),
        "mttr_seconds": runtime_extra.get("mttr_seconds"),
        "drills_run": runtime_extra.get("drills_run", 0),
    }

    delivery = {}
    if args.canary_promotions is not None:
        delivery["canary_promotions"] = args.canary_promotions
    if args.canary_rollbacks is not None:
        delivery["canary_rollbacks"] = args.canary_rollbacks
    if args.sync_failures is not None:
        delivery["sync_failures"] = args.sync_failures

    cost = {
        "usd_per_hour_estimate": args.cost_per_hour,
        "usd_window_total": args.cost_total,
        "currency": "USD",
        "source": args.cost_source,
    }

    bundle = {
        "schema_version": "1",
        "project": args.project,
        "collected_at": utc_now_iso(),
        "window_start": args.window_start,
        "window_end": args.window_end,
        "deploy": deploy,
        "identity": identity,
        "gates": gates,
        "admission": admission,
        "runtime": runtime,
        "delivery": delivery,
        "cost": cost,
    }

    if args.attacker_telemetry_json:
        bundle["attacker_telemetry"] = load_json(args.attacker_telemetry_json)

    return bundle


# ─── Minimal JSON Schema subset validator ──────────────────────────────────
# Supports: type (incl. lists of types), const, enum, required,
# additionalProperties: false, properties, items. That's every keyword the
# shared schema uses. Deliberately not a general-purpose validator.

def _type_ok(value, ty: str) -> bool:
    if ty == "object":
        return isinstance(value, dict)
    if ty == "array":
        return isinstance(value, list)
    if ty == "string":
        return isinstance(value, str)
    if ty == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if ty == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if ty == "boolean":
        return isinstance(value, bool)
    if ty == "null":
        return value is None
    return True


def _validate(instance, schema: dict, path: str, errors: list[str]) -> None:
    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: expected const {schema['const']!r}, got {instance!r}")
        return
    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: {instance!r} not in enum {schema['enum']}")
        return

    schema_type = schema.get("type")
    if schema_type is not None:
        types = schema_type if isinstance(schema_type, list) else [schema_type]
        if not any(_type_ok(instance, t) for t in types):
            errors.append(f"{path}: expected type {schema_type}, got {type(instance).__name__}")
            return

    if isinstance(instance, dict) and "properties" in schema:
        for req in schema.get("required", []):
            if req not in instance:
                errors.append(f"{path}: missing required field '{req}'")
        props = schema["properties"]
        if schema.get("additionalProperties") is False:
            for key in instance:
                if key not in props:
                    errors.append(f"{path}: unexpected property '{key}'")
        for key, value in instance.items():
            if key in props:
                _validate(value, props[key], f"{path}.{key}", errors)

    elif isinstance(instance, list) and "items" in schema:
        for i, item in enumerate(instance):
            _validate(item, schema["items"], f"{path}[{i}]", errors)


def validate_bundle(bundle: dict, schema: dict) -> list[str]:
    errors: list[str] = []
    _validate(bundle, schema, "$", errors)
    # metrics/runtime-metrics.schema.json's top-level if/then: cowrie-honeypot
    # bundles must carry attacker_telemetry. Handled explicitly rather than
    # with a generic if/then interpreter — it's the only conditional in the
    # shared schema.
    if bundle.get("project") == "cowrie-honeypot" and "attacker_telemetry" not in bundle:
        errors.append("$: project=cowrie-honeypot requires attacker_telemetry")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default="eks-gitops",
                         choices=list(PROJECT_DEFAULT_SENSOR))
    parser.add_argument("--window-start", required=True)
    parser.add_argument("--window-end", required=True)
    parser.add_argument("--out", default=str(DEFAULT_OUT))
    parser.add_argument("--schema", default=str(DEFAULT_SCHEMA))

    parser.add_argument("--gate", action="append", type=parse_gate, default=[],
                         help="Repeatable: NAME:STATUS:DURATION_MS")
    parser.add_argument("--gates-json", default=None,
                         help="Path to a JSON array of {name,status,duration_ms} "
                              "objects, merged in after any --gate flags "
                              "(e.g. built from the GitHub/GitLab jobs API)")

    parser.add_argument("--deploy-duration-seconds", type=float, default=None)
    parser.add_argument("--rebuild-duration-seconds", type=float, default=None)
    parser.add_argument("--destroy-confirmed", action="store_true")
    parser.add_argument("--cluster-stopped", action="store_true")

    parser.add_argument("--oidc-success", action="store_true")
    parser.add_argument("--long-lived-keys", action="store_true",
                         help="Set only if this project's CI genuinely holds a "
                              "long-lived cloud credential. eks-gitops authenticates "
                              "via GitHub OIDC only, so this should never be set here — "
                              "grep the workflow for AWS_ACCESS_KEY_ID before ever passing it.")

    parser.add_argument("--admission-json", default=None,
                         help="Path to the JSON written by a fixtures runner "
                              "(e.g. policies/gatekeeper/fixtures/run-fixtures.sh)")
    parser.add_argument("--runtime-json", default=None,
                         help="Path to the JSON written by scripts/runtime-drill.sh")
    parser.add_argument("--sensor", default=None, choices=["falco", "defender", "none"])

    parser.add_argument("--canary-promotions", type=int, default=None)
    parser.add_argument("--canary-rollbacks", type=int, default=None)
    parser.add_argument("--sync-failures", type=int, default=None)

    parser.add_argument("--cost-per-hour", type=float, default=None)
    parser.add_argument("--cost-total", type=float, default=None)
    parser.add_argument("--cost-source", default="n/a",
                         choices=["cost explorer", "azure cost", "do invoice", "n/a"])

    parser.add_argument("--attacker-telemetry-json", default=None,
                         help="cowrie-honeypot only")

    args = parser.parse_args()

    bundle = build_bundle(args)

    schema_path = pathlib.Path(args.schema)
    if not schema_path.exists():
        print(f"[emit-runtime-metrics] schema not found: {schema_path}", file=sys.stderr)
        return 1
    schema = json.loads(schema_path.read_text())

    errors = validate_bundle(bundle, schema)
    if errors:
        print("[emit-runtime-metrics] bundle failed schema validation:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    out_path = pathlib.Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(bundle, indent=2) + "\n")
    print(f"[emit-runtime-metrics] wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
