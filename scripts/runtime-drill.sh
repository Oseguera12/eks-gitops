#!/usr/bin/env bash
# runtime-drill.sh
#
# End-to-end runtime detection drill: deploy a workload that performs three
# TTPs Falco's custom rules watch for (kubernetes/platform/falco.yaml —
# "Drill - Sensitive Host Path Mounted", "Drill - Shell Spawned In Container",
# "Drill - Write Below Binary Dir"), poll Falco's own pod logs for the
# matching alerts, then tear the workload down. Times every step so
# scripts/emit-runtime-metrics.py can report a real MTTD/MTTR instead of an
# estimate.
#
# Requires: kubectl configured against the target cluster, Falco already
# synced into the `security` namespace. Written for the GNU coreutils on the
# GitHub Actions ubuntu-latest runner (uses `date -u -d @<epoch>`).
#
# Usage: runtime-drill.sh [output-json-path]
# Exit code is 0 only if the drill namespace was applied, all three alerts
# were observed, and cleanup succeeded — a partial drill is a failed drill.

set -uo pipefail

OUT_FILE="${1:-/tmp/runtime-drill.json}"
NAMESPACE="runtime-drill"
POD_NAME="drill-target"
FALCO_LABEL_SELECTOR="app.kubernetes.io/name=falco"
FALCO_NAMESPACE="security"
DETECT_TIMEOUT_SECONDS="${DETECT_TIMEOUT_SECONDS:-120}"
POLL_INTERVAL_SECONDS=3

iso_from_epoch() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

cleanup() {
  echo "[drill] cleaning up namespace ${NAMESPACE}..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[drill] creating namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

t_deploy_start=$(date +%s)

# One pod exercises the "sensitive host path mount" rule on start (hostPath
# mount of /etc), then scripts/runtime-drill.sh execs into it to spawn a
# shell and write below /bin — exercising the other two custom rules the way
# a real post-exploitation session would, rather than baking the exec into
# the pod's own entrypoint.
kubectl apply -n "${NAMESPACE}" -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  labels:
    app.kubernetes.io/part-of: runtime-drill
spec:
  restartPolicy: Never
  containers:
    - name: drill-target
      image: busybox:1.36
      command: ["sleep", "600"]
      volumeMounts:
        - name: host-etc
          mountPath: /host-etc
          readOnly: true
  volumes:
    - name: host-etc
      hostPath:
        path: /etc
EOF

echo "[drill] waiting for ${POD_NAME} to be Running..."
if ! kubectl wait -n "${NAMESPACE}" "pod/${POD_NAME}" --for=condition=Ready --timeout=90s >/dev/null 2>&1; then
  echo "[drill] pod never became Ready — aborting drill" >&2
  exit 1
fi

t_deploy_end=$(date +%s)
echo "[drill] pod Ready in $((t_deploy_end - t_deploy_start))s. Simulating post-exploitation shell..."

# Spawn a shell and write below /bin — mirrors an attacker who has landed a
# shell in a running container and is dropping a payload/persistence file.
kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -- sh -c 'id; touch /bin/pwned-by-drill' >/dev/null 2>&1 || true

t_attack=$(date +%s)

declare -A expected_rules=(
  ["Drill - Sensitive Host Path Mounted"]=0
  ["Drill - Shell Spawned In Container"]=0
  ["Drill - Write Below Binary Dir"]=0
)
declare -A detected_at=()

echo "[drill] polling Falco logs (namespace=${FALCO_NAMESPACE}) for up to ${DETECT_TIMEOUT_SECONDS}s..."
deadline=$((t_attack + DETECT_TIMEOUT_SECONDS))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  logs=$(kubectl logs -n "${FALCO_NAMESPACE}" -l "${FALCO_LABEL_SELECTOR}" --since=5m --tail=2000 --all-containers 2>/dev/null || true)
  for rule in "${!expected_rules[@]}"; do
    if [ "${expected_rules[${rule}]}" -eq 0 ] && grep -qF "${rule}" <<<"${logs}"; then
      expected_rules["${rule}"]=1
      detected_at["${rule}"]=$(date +%s)
      echo "[drill] detected: ${rule}"
    fi
  done

  still_missing=0
  for rule in "${!expected_rules[@]}"; do
    [ "${expected_rules[${rule}]}" -eq 0 ] && still_missing=1
  done
  [ "${still_missing}" -eq 0 ] && break

  sleep "${POLL_INTERVAL_SECONDS}"
done

alerts_json="[]"
first_detected=""
missing=0
for rule in "${!expected_rules[@]}"; do
  if [ "${expected_rules[${rule}]}" -eq 1 ]; then
    ts="${detected_at[${rule}]}"
    if [ -z "${first_detected}" ] || [ "${ts}" -lt "${first_detected}" ]; then
      first_detected="${ts}"
    fi
    priority="warning"
    [[ "${rule}" == *"Sensitive Host Path"* ]] && priority="critical"
    [[ "${rule}" == *"Write Below Binary"* ]] && priority="error"
    entry=$(printf '{"rule":"%s","priority":"%s","detected_at":"%s"}' \
      "${rule}" "${priority}" "$(iso_from_epoch "${ts}")")
    alerts_json=$(python3 -c "import json,sys; a=json.loads(sys.argv[1]); a.append(json.loads(sys.argv[2])); print(json.dumps(a))" "${alerts_json}" "${entry}")
  else
    echo "[drill] WARNING: never observed alert for rule: ${rule}" >&2
    missing=$((missing + 1))
  fi
done

if [ -n "${first_detected}" ]; then
  mttd_seconds=$((first_detected - t_attack))
else
  mttd_seconds="null"
fi

t_cleanup_start=$(date +%s)
cleanup
trap - EXIT
t_cleanup_end=$(date +%s)

if [ -n "${first_detected}" ]; then
  mttr_seconds=$((t_cleanup_end - first_detected))
else
  mttr_seconds="null"
fi

cat > "${OUT_FILE}" <<EOF
{
  "sensor": "falco",
  "alerts": ${alerts_json},
  "mttd_seconds": ${mttd_seconds},
  "mttr_seconds": ${mttr_seconds},
  "drills_run": 1
}
EOF

echo "[drill] summary written to ${OUT_FILE}"
echo "[drill] mttd_seconds=${mttd_seconds} mttr_seconds=${mttr_seconds} missing_rules=${missing}"

if [ "${missing}" -gt 0 ]; then
  exit 1
fi
