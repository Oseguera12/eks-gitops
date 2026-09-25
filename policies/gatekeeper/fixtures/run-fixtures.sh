#!/usr/bin/env bash
# run-fixtures.sh
#
# Applies each intentionally-bad manifest in bad-workloads/ with a server-side
# dry run and confirms Gatekeeper rejects it. This is the CI-side half of the
# "admission vs runtime gap" story: these three TTPs (privileged container,
# root user, missing resource limits) are blocked here at admission, and the
# same TTP family is what kubernetes/platform/falco.yaml's custom rules catch
# at runtime if a workload ever gets past admission another way.
#
# Requires a live cluster with Gatekeeper + the constraints in
# policies/gatekeeper/constraints/ already synced (kubeconfig must be set).
# Writes a small JSON summary consumed by scripts/emit-runtime-metrics.py.
#
# Usage: run-fixtures.sh [output-json-path]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/bad-workloads"
OUT_FILE="${1:-/tmp/gatekeeper-fixtures.json}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[fixtures] kubectl not found on PATH" >&2
  exit 1
fi

total=0
blocked=0
declare -a results=()

for fixture in "${FIXTURES_DIR}"/*.yaml; do
  name="$(basename "${fixture}" .yaml)"
  total=$((total + 1))

  echo "[fixtures] applying ${name} (dry-run=server, expecting a deny)..."
  if output=$(kubectl apply --dry-run=server -f "${fixture}" 2>&1); then
    echo "[fixtures] FAIL: ${name} was allowed — Gatekeeper did not block it" >&2
    echo "${output}" >&2
    results+=("{\"fixture\":\"${name}\",\"blocked\":false}")
  else
    echo "[fixtures] OK: ${name} was blocked as expected"
    blocked=$((blocked + 1))
    results+=("{\"fixture\":\"${name}\",\"blocked\":true}")
  fi
done

# Number of Constraint kinds Gatekeeper is actively enforcing — kept in sync by
# hand with policies/gatekeeper/constraints/ (3 files as of this writing:
# enforce-block-privileged, enforce-non-root, enforce-resource-limits).
policies_evaluated=$(find "${SCRIPT_DIR}/../constraints" -name '*.yaml' | wc -l | tr -d ' ')

joined_results=$(IFS=,; echo "${results[*]}")
cat > "${OUT_FILE}" <<EOF
{
  "policies_evaluated": ${policies_evaluated},
  "violations_blocked": ${blocked},
  "fixture_failures": ${blocked},
  "fixtures_total": ${total},
  "results": [${joined_results}]
}
EOF

echo "[fixtures] ${blocked}/${total} bad-workload fixtures blocked. Summary: ${OUT_FILE}"

if [ "${blocked}" -ne "${total}" ]; then
  echo "[fixtures] ${blocked}/${total} blocked — at least one fixture that should have been denied was allowed" >&2
  exit 1
fi
