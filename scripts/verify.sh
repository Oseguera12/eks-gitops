#!/usr/bin/env bash
# verify.sh
#
# Live pass/fail checklist for a demo session — run this right after
# deploy.yml (or a local terraform apply + ArgoCD bootstrap) finishes, while
# the cluster is up, to confirm everything actually works before you record
# a demo or start building interview talking points from it.
#
# This is the fast local complement to the "Runtime Metrics" GitHub Actions
# workflow: that workflow is the system of record (produces the
# metrics/runtime-metrics.json artifact you cite later), this script is the
# quick "did it actually come up clean" check you run first. Both write
# timestamped evidence you can keep — this one to verify-results/.
#
# Requires: kubectl pointed at the cluster (aws eks update-kubeconfig),
# jq, curl.
#
# Usage: scripts/verify.sh [namespace]
#   namespace defaults to platform-status (prod). Pass
#   platform-status-staging to verify the staging environment instead.
# Exit code is non-zero if any check fails.

set -uo pipefail

NAMESPACE="${1:-platform-status}"
RESULTS_DIR="verify-results"
TIMESTAMP="$(date +%Y%m%dT%H%M%S)"
LOG_FILE="${RESULTS_DIR}/verify-${NAMESPACE}-${TIMESTAMP}.txt"
mkdir -p "${RESULTS_DIR}"

PASS_COUNT=0
FAIL_COUNT=0

log() { echo "$*" | tee -a "${LOG_FILE}"; }

check() {
  local name="$1"
  shift
  if "$@" >>"${LOG_FILE}" 2>&1; then
    log "[PASS] ${name}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    log "[FAIL] ${name}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

log "=== eks-gitops verification run: namespace=${NAMESPACE} ${TIMESTAMP} ==="
log ""

# ─── Cluster / nodes ───────────────────────────────────────────────────────

log "--- Cluster & nodes ---"
check "cluster reachable" kubectl cluster-info
check "all nodes Ready" bash -c "! kubectl get nodes --no-headers | grep -v ' Ready '"
check "nodes have no public IPs (private subnets)" bash -c \
  "! kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type==\"ExternalIP\")].address}' | grep -q ."

log ""
log "--- Pods across all namespaces ---"
check "no pods stuck outside Running/Completed/Succeeded" bash -c \
  "! kubectl get pods -A --no-headers | grep -Ev ' (Running|Completed|Succeeded) '"

# ─── ArgoCD ─────────────────────────────────────────────────────────────────

log ""
log "--- ArgoCD applications ---"
if kubectl get namespace argocd >/dev/null 2>&1; then
  APPS_JSON=$(kubectl get applications -n argocd -o json)
  TOTAL=$(echo "${APPS_JSON}" | jq '.items | length')
  HEALTHY=$(echo "${APPS_JSON}" | jq '[.items[] | select(.status.sync.status=="Synced" and .status.health.status=="Healthy")] | length')
  log "  ${HEALTHY}/${TOTAL} Applications Synced+Healthy"
  echo "${APPS_JSON}" | jq -r '.items[] | "    - \(.metadata.name): sync=\(.status.sync.status) health=\(.status.health.status)"' | tee -a "${LOG_FILE}"
  if [ "${TOTAL}" -gt 0 ] && [ "${HEALTHY}" -eq "${TOTAL}" ]; then
    log "[PASS] all ArgoCD Applications Synced+Healthy"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    log "[FAIL] not all ArgoCD Applications Synced+Healthy"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  log "[FAIL] argocd namespace not found"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ─── Application health endpoints ──────────────────────────────────────────

log ""
log "--- platform-status app (namespace=${NAMESPACE}) ---"
kubectl port-forward "svc/platform-status-stable" 18080:8080 -n "${NAMESPACE}" >/dev/null 2>&1 &
PF_PID=$!
sleep 3
check "/health returns healthy" bash -c "curl -sf http://localhost:18080/health | grep -q healthy"
check "/metrics returns Prometheus text format" bash -c "curl -sf http://localhost:18080/metrics | grep -q '^# HELP'"
kill "${PF_PID}" >/dev/null 2>&1 || true
wait "${PF_PID}" 2>/dev/null || true

# ─── Argo Rollouts ──────────────────────────────────────────────────────────

log ""
log "--- Argo Rollouts ---"
check "platform-status rollout is Healthy" bash -c \
  "kubectl get rollout platform-status -n '${NAMESPACE}' -o jsonpath='{.status.phase}' | grep -q Healthy"

# ─── Gateway API traffic routing ───────────────────────────────────────────

log ""
log "--- Gateway API ---"
check "HTTPRoute for platform-status exists" bash -c \
  "kubectl get httproute platform-status -n '${NAMESPACE}' >/dev/null 2>&1"
check "shared Gateway is Programmed" bash -c \
  "kubectl get gateway eks-gitops -n nginx-gateway -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' | grep -q True"

# ─── Gatekeeper policy enforcement ─────────────────────────────────────────

log ""
log "--- OPA Gatekeeper ---"
check "constraint templates registered" bash -c \
  "[ \"\$(kubectl get constrainttemplates --no-headers 2>/dev/null | wc -l)\" -ge 3 ]"
check "root-run pod is rejected at admission" bash -c "
  ! kubectl apply --dry-run=server -n '${NAMESPACE}' -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: verify-gatekeeper-test
spec:
  containers:
  - name: test
    image: nginx
    securityContext:
      runAsUser: 0
EOF
"

# ─── Metrics collection ────────────────────────────────────────────────────

log ""
log "--- Metrics pipeline ---"
check "PodMonitor for platform-status exists" bash -c \
  "kubectl get podmonitor -n '${NAMESPACE}' platform-status >/dev/null 2>&1"
check "Prometheus is up and has a target for platform-status" bash -c "
  kubectl port-forward svc/kube-prometheus-stack-prometheus 19090:9090 -n monitoring >/dev/null 2>&1 &
  pf=\$!
  sleep 3
  result=\$(curl -sf 'http://localhost:19090/api/v1/targets' | jq -r '.data.activeTargets[] | select(.labels.namespace==\"${NAMESPACE}\") | .health' 2>/dev/null)
  kill \$pf >/dev/null 2>&1 || true
  wait \$pf 2>/dev/null || true
  [ \"\$result\" = 'up' ]
"

# ─── Summary ────────────────────────────────────────────────────────────────

log ""
log "=== ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="
log "Full log saved to ${LOG_FILE} — keep this as evidence alongside the"
log "runtime-metrics.json artifact from the 'Runtime Metrics' workflow."

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
