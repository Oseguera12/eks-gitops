#!/usr/bin/env bash
# generate-canary-traffic.sh
#
# The AnalysisTemplate's rate() queries (analysis-template.yaml) need a
# non-empty request window to evaluate — with zero traffic hitting the
# Gateway, both queries return NaN and the canary step just times out
# instead of actually passing or failing on real data. Run this manually
# right after triggering a rollout (a push to main, or a `kubectl argo
# rollouts retry`) so there's something for it to measure. Not wired into
# CI — this is a demo aid, not a pipeline dependency.
#
# Usage: scripts/generate-canary-traffic.sh <gateway-lb-hostname> [duration-seconds]
#   duration-seconds defaults to 360 (a bit over one 5m observation window).

set -euo pipefail

HOST="${1:?Usage: generate-canary-traffic.sh <gateway-lb-hostname> [duration-seconds]}"
DURATION="${2:-360}"
URL="http://${HOST}/health"

echo "[traffic] sending requests to ${URL} for ${DURATION}s..."

end=$(($(date +%s) + DURATION))
sent=0
failed=0
while [ "$(date +%s)" -lt "${end}" ]; do
  if curl -sf -o /dev/null --max-time 2 "${URL}"; then
    sent=$((sent + 1))
  else
    failed=$((failed + 1))
  fi
  sleep 0.2
done

echo "[traffic] done. requests sent: ${sent}, failed: ${failed}"
