#!/usr/bin/env bash
# Planned switchover of one instance (PLAN.md phase 7, step 6). Changes which replica
# holds the primary role, waits until the operator reports it, and prints the canary
# reports of the window, so the switchover is judged by what clients saw.
#
#   scripts/switchover.sh <instance> [target-pod-index]
#
# Without a target, the lowest-indexed Ready replica is chosen.
set -euo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || die "usage: $0 <instance> [target-pod-index]"
instance="$1"
target="${2:-}"
context="${KUBE_CONTEXT:-$(kubectl config current-context)}"
ns="db-${instance}"
kc() { kubectl --context "${context}" "$@"; }

kc -n "${ns}" get mariadb "${instance}" >/dev/null || die "no instance '${instance}' in ${ns}"
current="$(kc -n "${ns}" get mariadb "${instance}" -o jsonpath='{.status.currentPrimaryPodIndex}')"

if [[ -z "${target}" ]]; then
  target="$(kc -n "${ns}" get pods -l "app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=${instance}" -o json |
    jq -r --arg cur "${current}" '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))
      | .metadata.labels["apps.kubernetes.io/pod-index"] | select(. != $cur)] | sort | first // empty')"
  [[ -n "${target}" ]] || die "no Ready replica can take the primary role"
fi
[[ "${target}" != "${current}" ]] || { echo "pod ${target} is already the primary: nothing to do"; exit 0; }

start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "switching the primary of ${instance} from ${current} to ${target} at ${start}"
kc -n "${ns}" patch mariadb "${instance}" --type merge \
  -p "{\"spec\":{\"replication\":{\"primary\":{\"podIndex\":${target}}}}}" >/dev/null

deadline=$((SECONDS + 300))
until [[ "$(kc -n "${ns}" get mariadb "${instance}" -o jsonpath='{.status.currentPrimaryPodIndex}')" == "${target}" ]]; do
  ((SECONDS < deadline)) || die "the switchover did not complete within 300 seconds"
  sleep 2
done
kc -n "${ns}" wait "mariadb/${instance}" --for=condition=Ready --timeout=600s >/dev/null
echo "switchover complete: primary is pod ${target}"

# The canary reports of the window, one per canary pod, through port-forward.
for pod in $(kc -n "${ns}" get pods -l "app.kubernetes.io/name=db-canary,app.kubernetes.io/instance=${instance}" -o jsonpath='{.items[*].metadata.name}'); do
  port=$((19000 + RANDOM % 1000))
  kc -n "${ns}" port-forward "pod/${pod}" "${port}:8080" >/dev/null 2>&1 &
  pf=$!
  for _ in $(seq 1 50); do curl -fsS -o /dev/null "http://127.0.0.1:${port}/healthz" 2>/dev/null && break; sleep 0.2; done
  echo "canary ${pod}:"
  curl -fsS "http://127.0.0.1:${port}/report" | jq . || echo "  (no report)"
  kill "${pf}" 2>/dev/null || true
done
echo "window started at ${start}; compare the outage with docs/operations.md section 7.3 limits"
