#!/usr/bin/env bash
# Run the Playwright regression suite against the real container image,
# started with the same runtime restrictions the cluster enforces
# (kubernetes/workloads/platform-status/base/rollout.yaml securityContext):
# read-only root filesystem, UID 1001, all capabilities dropped,
# no-new-privileges.
#
# Usage:
#   scripts/run-regression.sh                      # build locally, then test
#   IMAGE=platform-status:regression scripts/run-regression.sh   # test a prebuilt image
#
# Env:
#   IMAGE         image to test; if unset, builds platform-status:regression
#   APP_VERSION   build arg when building (default: sha-<HEAD short sha>)
#   PROJECT       metrics project name (default: eks-gitops)
#   PORT          published host port (default: 8080)
#   BIND_ADDR     address the port is published on (default: 127.0.0.1)
#   TARGET_HOST   host the tests connect to (default: 127.0.0.1). Under
#                 GitLab docker:dind set BIND_ADDR=0.0.0.0 TARGET_HOST=docker,
#                 since the port is published on the dind service, not the job.
#
# Writes app/e2e/test-results/{junit.xml,cases.json,latency.json,
# container.json,regression-metrics.json}. Exit code is pytest's.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E2E_DIR="${REPO_ROOT}/app/e2e"
RESULTS_DIR="${E2E_DIR}/test-results"
PROJECT="${PROJECT:-eks-gitops}"
PORT="${PORT:-8080}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
TARGET_HOST="${TARGET_HOST:-127.0.0.1}"
CONTAINER="platform-status-regression-$$"
APP_VERSION="${APP_VERSION:-sha-$(git -C "${REPO_ROOT}" rev-parse --short=7 HEAD)}"

rm -rf "${RESULTS_DIR}"
mkdir -p "${RESULTS_DIR}"

if [[ -z "${IMAGE:-}" ]]; then
  IMAGE="platform-status:regression"
  docker build --build-arg "APP_VERSION=${APP_VERSION}" -t "${IMAGE}" "${REPO_ROOT}/app"
fi

cleanup() {
  docker logs "${CONTAINER}" >"${RESULTS_DIR}/container.log" 2>&1 || true
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

now_ns() { python3 -c 'import time; print(time.time_ns())'; }  # BSD date has no %N

started_ns=$(now_ns)
# No --tmpfs: the cluster mounts no writable volume either, so neither does this.
docker run -d --name "${CONTAINER}" \
  --read-only \
  --user 1001:1001 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --health-interval 1s --health-start-period 10s --health-start-interval 250ms \
  -p "${BIND_ADDR}:${PORT}:8080" \
  -e ENVIRONMENT=ci -e CLUSTER_NAME=ci -e POD_NAMESPACE=ci -e POD_NAME=regression \
  "${IMAGE}" >/dev/null

# Wait on the image's own HEALTHCHECK, so a broken HEALTHCHECK fails here too.
status="starting"
for _ in $(seq 1 60); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo "missing")
  [[ "${status}" == "healthy" || "${status}" == "unhealthy" || "${status}" == "missing" ]] && break
  sleep 0.5
done
ready_seconds=$(awk -v s="${started_ns}" -v e="$(now_ns)" 'BEGIN { printf "%.2f", (e - s) / 1e9 }')
image_size=$(docker image inspect -f '{{.Size}}' "${IMAGE}")

if [[ "${status}" != "healthy" ]]; then
  echo "container never became healthy (status=${status})" >&2
  docker logs "${CONTAINER}" >&2 || true
  exit 1
fi
echo "container healthy after ${ready_seconds}s (image ${image_size} bytes)"

cat >"${RESULTS_DIR}/container.json" <<EOF
{"ready_seconds": ${ready_seconds}, "image_size_bytes": ${image_size}, "hardened_runtime": true}
EOF

rc=0
(
  cd "${E2E_DIR}"
  E2E_ENV=ci \
    E2E_BASE_URL="http://${TARGET_HOST}:${PORT}" \
    E2E_EXPECTED_VERSION="${APP_VERSION}" \
    E2E_RESULTS_DIR="${RESULTS_DIR}" \
    python -m pytest
) || rc=$?

python3 "${REPO_ROOT}/scripts/summarize-regression.py" \
  --project "${PROJECT}" \
  --results-dir "${RESULTS_DIR}" \
  --plan "${E2E_DIR}/MANUAL_TEST_PLAN.md" \
  --out "${RESULTS_DIR}/regression-metrics.json" || { [[ ${rc} -eq 0 ]] && rc=1; }

exit "${rc}"
