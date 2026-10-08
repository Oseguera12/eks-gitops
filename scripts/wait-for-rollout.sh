#!/usr/bin/env bash
# Waits until an Argo Rollout's spec references IMAGE, the controller has
# observed that spec, and the rollout reaches phase Healthy. Fails fast if
# the rollout goes Degraded (e.g. the success-rate analysis aborts it).
#
# Usage: scripts/wait-for-rollout.sh <namespace> <rollout> <image> [timeout_seconds]
#
# Prints the elapsed time. Under GitHub Actions it also writes
# rollout_seconds=<n> to $GITHUB_OUTPUT, so callers can report it.

set -euo pipefail

ns="${1:?namespace required}"
name="${2:?rollout name required}"
image="${3:?image required}"
timeout="${4:-1500}"   # canary: 5m pause + 5m analysis + 5m pause, plus pod start

get() { kubectl -n "${ns}" get rollout "${name}" -o jsonpath="$1" 2>/dev/null || true; }

start=${SECONDS}
while :; do
  elapsed=$((SECONDS - start))
  if (( elapsed >= timeout )); then
    echo "Timed out after ${elapsed}s waiting for ${ns}/${name}" >&2
    kubectl -n "${ns}" get rollout "${name}" -o wide >&2 || true
    exit 1
  fi

  spec_image=$(get '{.spec.template.spec.containers[0].image}')
  phase=$(get '{.status.phase}')
  if [[ "${spec_image}" == "${image}" && "$(get '{.status.observedGeneration}')" == "$(get '{.metadata.generation}')" ]]; then
    case "${phase}" in
      Healthy)
        echo "${ns}/${name} Healthy on ${image##*@} after ${elapsed}s"
        [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "rollout_seconds=${elapsed}" >> "${GITHUB_OUTPUT}"
        exit 0
        ;;
      Degraded)
        echo "${ns}/${name} Degraded: $(get '{.status.message}')" >&2
        exit 1
        ;;
    esac
  fi

  echo "  [${elapsed}s] spec image: ${spec_image##*@}  phase: ${phase:-unknown}"
  sleep 10
done
