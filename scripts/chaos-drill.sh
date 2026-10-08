#!/usr/bin/env bash
# chaos-drill.sh
#
# Same idea as runtime-drill.sh, applied to availability instead of runtime
# security: break something on purpose, time how long the system takes to
# recover on its own, and write the result out instead of just asserting
# "should be resilient" in a doc.
#
#   - pod-kill: delete a platform-status pod, time until a replacement is
#     Ready again (kube-controller-manager + kubelet self-healing).
#   - node-drain (opt-in, RUN_NODE_DRAIN=1): cordon + drain a node, time
#     until Cluster Autoscaler provisions a replacement and every displaced
#     pod is Ready again. Off by default — it's slow (new EC2 instance +
#     kubelet join) and touches a whole node rather than one pod.
#
# Requires: kubectl configured against the target cluster. Written for the
# GNU coreutils on the GitHub Actions ubuntu-latest runner (uses `date -u`).
#
# Usage: chaos-drill.sh [output-json-path] [namespace]
# Exit code is 0 only if the pod-kill experiment (and the node-drain
# experiment, if requested) both completed and recovered within their
# timeouts — a partial drill is a failed drill, same convention as
# runtime-drill.sh.

set -uo pipefail

OUT_FILE="${1:-/tmp/chaos-drill.json}"
NAMESPACE="${2:-platform-status}"
POD_KILL_TIMEOUT_SECONDS="${POD_KILL_TIMEOUT_SECONDS:-120}"
NODE_DRAIN_TIMEOUT_SECONDS="${NODE_DRAIN_TIMEOUT_SECONDS:-900}"
RUN_NODE_DRAIN="${RUN_NODE_DRAIN:-0}"
POLL_INTERVAL_SECONDS=5

# ─── pod-kill ───────────────────────────────────────────────────────────────

echo "[chaos] pod-kill: selecting a target pod in ${NAMESPACE}..."
target_pod=$(kubectl get pods -n "${NAMESPACE}" -l app=platform-status \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "${target_pod}" ]; then
  echo "[chaos] no platform-status pod found in ${NAMESPACE} — aborting drill" >&2
  exit 1
fi

echo "[chaos] pod-kill: deleting ${target_pod}..."
t_kill=$(date +%s)
kubectl delete pod "${target_pod}" -n "${NAMESPACE}" --wait=false >/dev/null

echo "[chaos] pod-kill: waiting up to ${POD_KILL_TIMEOUT_SECONDS}s for a Ready replacement..."
pod_kill_recovery_seconds="null"
deadline=$((t_kill + POD_KILL_TIMEOUT_SECONDS))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  ready_count=$(kubectl get pods -n "${NAMESPACE}" -l app=platform-status \
    --field-selector=status.phase=Running -o json 2>/dev/null \
    | python3 -c "
import json, sys
pods = json.load(sys.stdin).get('items', [])
ready = [p for p in pods if p['metadata']['name'] != '${target_pod}'
         and all(c.get('status') == 'True' for c in p.get('status', {}).get('conditions', []) if c.get('type') == 'Ready')]
print(len(ready))
" 2>/dev/null || echo 0)
  if [ "${ready_count}" -ge 1 ]; then
    pod_kill_recovery_seconds=$(($(date +%s) - t_kill))
    echo "[chaos] pod-kill: replacement Ready after ${pod_kill_recovery_seconds}s"
    break
  fi
  sleep "${POLL_INTERVAL_SECONDS}"
done

if [ "${pod_kill_recovery_seconds}" = "null" ]; then
  echo "[chaos] pod-kill: WARNING — no Ready replacement observed within timeout" >&2
fi

# ─── node-drain (opt-in) ────────────────────────────────────────────────────

node_drain_recovery_seconds="null"
node_drain_ran=0

if [ "${RUN_NODE_DRAIN}" = "1" ]; then
  node_drain_ran=1
  target_node=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -z "${target_node}" ]; then
    echo "[chaos] node-drain: no node found — skipping" >&2
  else
    echo "[chaos] node-drain: cordoning + draining ${target_node}..."
    t_drain=$(date +%s)
    kubectl cordon "${target_node}" >/dev/null
    kubectl drain "${target_node}" --ignore-daemonsets --delete-emptydir-data \
      --force --timeout="${NODE_DRAIN_TIMEOUT_SECONDS}s" >/dev/null 2>&1 || true

    echo "[chaos] node-drain: waiting up to ${NODE_DRAIN_TIMEOUT_SECONDS}s for Cluster Autoscaler to replace it and all pods to be Ready..."
    deadline=$((t_drain + NODE_DRAIN_TIMEOUT_SECONDS))
    while [ "$(date +%s)" -lt "${deadline}" ]; do
      not_ready=$(kubectl get pods -A --no-headers 2>/dev/null | grep -Evc ' (Running|Completed|Succeeded) ')
      node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
      if [ "${not_ready}" -eq 0 ] && [ "${node_count}" -ge 2 ]; then
        node_drain_recovery_seconds=$(($(date +%s) - t_drain))
        echo "[chaos] node-drain: cluster settled after ${node_drain_recovery_seconds}s"
        break
      fi
      sleep "${POLL_INTERVAL_SECONDS}"
    done

    if [ "${node_drain_recovery_seconds}" = "null" ]; then
      echo "[chaos] node-drain: WARNING — cluster did not settle within timeout" >&2
    fi

    echo "[chaos] node-drain: uncordoning ${target_node} (in case it's the same node, harmless if replaced)..."
    kubectl uncordon "${target_node}" >/dev/null 2>&1 || true
  fi
fi

# ─── output ─────────────────────────────────────────────────────────────────

experiments_json="[{\"name\":\"pod-kill\",\"recovery_seconds\":${pod_kill_recovery_seconds}}"
if [ "${node_drain_ran}" -eq 1 ]; then
  experiments_json="${experiments_json},{\"name\":\"node-drain\",\"recovery_seconds\":${node_drain_recovery_seconds}}"
fi
experiments_json="${experiments_json}]"

cat > "${OUT_FILE}" <<EOF
{
  "experiments": ${experiments_json}
}
EOF

echo "[chaos] summary written to ${OUT_FILE}"

missing=0
[ "${pod_kill_recovery_seconds}" = "null" ] && missing=$((missing + 1))
if [ "${node_drain_ran}" -eq 1 ] && [ "${node_drain_recovery_seconds}" = "null" ]; then
  missing=$((missing + 1))
fi

if [ "${missing}" -gt 0 ]; then
  exit 1
fi
exit 0
