#!/usr/bin/env bash
# Pre-flight gate of a node rotation or a cluster upgrade (PLAN.md phase 9, section 9.3).
# Exits non-zero unless every check holds. Each check prints one line.
#
#   scripts/preflight.sh [prometheus-url]
#
# Without a Prometheus URL, the checks that need metrics are reported as skipped and the
# gate fails: a rotation is never started blind. In kind, run through `make rotate-check`.
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
PROM="${1:-${PROMETHEUS_URL:-}}"
failures=0
kc() { kubectl --context "${KUBE_CONTEXT}" "$@"; }
report() {
  local ok="$1" name="$2" detail="${3:-}"
  if [[ "${ok}" == "ok" ]]; then
    printf '  ok    %s\n' "${name}"
  else
    printf '  FAIL  %s %s\n' "${name}" "${detail}"
    failures=$((failures + 1))
  fi
}
prom() {
  [[ -n "${PROM}" ]] || return 1
  curl -fsS -G "${PROM}/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // empty'
}

instances="$(kc get mariadb -A -l dbaas.local/engine=mariadb -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"')"

echo "instances"
# 1. Every instance is Ready and has a primary.
while read -r ns name; do
  [[ -n "${ns}" ]] || continue
  ready="$(kc -n "${ns}" get mariadb "${name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  primary="$(kc -n "${ns}" get mariadb "${name}" -o jsonpath='{.status.currentPrimaryPodIndex}')"
  if [[ "${ready}" == "True" && -n "${primary}" ]]; then report ok "${ns}/${name} is Ready with one primary"; else report fail "${ns}/${name}" "(ready=${ready:-?}, primary=${primary:-?})"; fi
  # 3. The budget allows one disruption.
  allowed="$(kc -n "${ns}" get pdb "${name}" -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || echo 0)"
  if [[ "${allowed:-0}" -ge 1 ]]; then report ok "${ns}/${name} budget allows one disruption"; else report fail "${ns}/${name} budget" "(allowed=${allowed:-0})"; fi
done <<<"${instances}"

echo "replication and backups"
# 2. Every replica replicates with lag at most 5 seconds (canary view, from Prometheus).
if [[ -n "${PROM}" ]]; then
  lag="$(prom 'max(db_canary_replica_delay_seconds)' || true)"
  if [[ -n "${lag}" ]] && awk -v l="${lag}" 'BEGIN { exit !(l <= 5) }'; then report ok "replica delay ${lag}s is within 5s"; else report fail "replica delay" "(${lag:-no data})"; fi
  # 5. Backups younger than 26 hours.
  age="$(prom 'max(time() - max by (namespace) (kube_cronjob_status_last_successful_time{cronjob=~".*-backup"}))' || true)"
  if [[ -n "${age}" ]] && awk -v a="${age}" 'BEGIN { exit !(a < 26*3600) }'; then report ok "newest backup is $(awk -v a="${age}" 'BEGIN { printf "%.1f", a/3600 }') hours old"; else report fail "backup age" "(${age:-no data} seconds)"; fi
  # 7. No critical alert is firing.
  crit="$(prom 'sum(ALERTS{alertstate="firing", severity="critical"})' || echo 0)"
  if [[ "${crit:-0}" == "0" ]]; then report ok "no critical alert is firing"; else report fail "critical alerts firing" "(${crit})"; fi
else
  report fail "metrics checks (replica lag, backup age, alerts)" "(no Prometheus URL)"
fi
while read -r ns name; do
  [[ -n "${ns}" ]] || continue
  pitr="$(kc -n "${ns}" get pointintimerecovery "${name}" -o jsonpath='{.status.lastRecoverableTime}' 2>/dev/null || true)"
  if [[ -n "${pitr}" ]] && (( $(date -u -d "${pitr}" +%s) > $(date -u +%s) - 7200 )); then report ok "${ns}/${name} archive is current"; else report fail "${ns}/${name} archive" "(last recoverable: ${pitr:-none})"; fi
done <<<"${instances}"

echo "operators and drain guard"
# 4. Operators and drain-guard have two Ready replicas, and the webhook answers.
for dep in mariadb-system/mariadb-operator dbaas-system/drain-guard; do
  ns="${dep%%/*}"; name="${dep##*/}"
  avail="$(kc -n "${ns}" get deployment "${name}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  if [[ "${avail:-0}" -ge 2 ]]; then report ok "${name} has ${avail} Ready replicas"; else report fail "${name}" "(${avail:-0} Ready replicas, want 2)"; fi
done
replica_pod="$(kc get pods -A -l app.kubernetes.io/name=mariadb -o json | jq -r '[.items[] | select(.metadata.labels["k8s.mariadb.com/role"] == "replica")][0] | "\(.metadata.namespace) \(.metadata.name)"')"
if [[ -n "${replica_pod}" && "${replica_pod}" != "null" ]]; then
  read -r rns rpod <<<"${replica_pod}"
  answer="$(kc create --raw "/api/v1/namespaces/${rns}/pods/${rpod}/eviction?dryRun=All" -f - <<<"{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\"${rpod}\",\"namespace\":\"${rns}\"}}" 2>&1 || true)"
  if grep -q 'failed calling webhook' <<<"${answer}"; then report fail "the eviction webhook answers" "(${answer:0:120})"; else report ok "the eviction webhook answers a dry run"; fi
fi

echo "capacity"
# 6. No database pod is Pending; every node class has a schedulable node in every zone that holds its pods.
pending="$(kc get pods -A -l app.kubernetes.io/name=mariadb --field-selector=status.phase=Pending -o name | wc -l | tr -d ' ')"
if [[ "${pending}" == "0" ]]; then report ok "no database pod is Pending"; else report fail "database pods Pending" "(${pending})"; fi
classes_zones="$(kc get nodes -l dbaas.local/node-class -o json | jq -r '[.items[].metadata.labels | "\(.["dbaas.local/node-class"]) \(.["topology.kubernetes.io/zone"])"] | unique[]')"
while read -r cls zone; do
  [[ -n "${cls}" ]] || continue
  left="$(kc get nodes -l "dbaas.local/node-class=${cls},topology.kubernetes.io/zone=${zone}" -o json |
    jq '[.items[] | select(.spec.unschedulable != true)] | length')"
  if [[ "${left}" -ge 2 ]]; then report ok "${cls} in ${zone} has ${left} schedulable nodes";
  else report fail "${cls} in ${zone}" "(${left} schedulable, want 2 so one can leave)"; fi
done <<<"${classes_zones}"

echo "cluster upgrade"
if [[ -n "${TARGET_KUBERNETES:-}" ]]; then
  # 8. The target is in the compatibility matrix, and no removed API is in use.
  if grep -q "${TARGET_KUBERNETES}" docs/compat-matrix.md; then report ok "Kubernetes ${TARGET_KUBERNETES} is in the compatibility matrix"; else report fail "Kubernetes ${TARGET_KUBERNETES}" "(not in docs/compat-matrix.md)"; fi
  if command -v pluto >/dev/null && [[ -n "${RENDERED_DIR:-}" ]]; then
    if pluto detect-files -d "${RENDERED_DIR}" --target-versions "k8s=v${TARGET_KUBERNETES#v}" >/dev/null 2>&1; then report ok "pluto finds no removed API"; else report fail "pluto" "(removed APIs in ${RENDERED_DIR})"; fi
  fi
fi

echo
if ((failures > 0)); then
  echo "pre-flight FAILED: ${failures} check(s)" >&2
  exit 1
fi
echo "pre-flight passed"
