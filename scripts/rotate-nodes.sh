#!/usr/bin/env bash
# Rolls the nodes of the given classes one at a time (PLAN.md phase 9, section 9.3). The kind
# implementation, and the model for aks-rotate-pools.sh.
#
#   scripts/rotate-nodes.sh --classes kind-pv2,kind-nvme [--system] [--report-dir DIR] [--dry-run]
#
# Per node: pre-flight once at the start, cordon, drain (plain drain, retried while the
# eviction webhook is unavailable), replace (kind: uncordon; a local NVMe volume of an
# evicted pod is discarded, as on a new node), wait until every instance passes its checks
# again. Nodes that hold a primary go last. Post-flight at the end writes a report.
#
# The plain drain never uses --force or --disable-eviction.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
classes=""
system=0
report_dir="${REPORT_DIR:-$(mktemp -d)}"
dry_run=0
while (($# > 0)); do
  case "$1" in
    --classes) classes="$2"; shift 2 ;;
    --system) system=1; shift ;;
    --report-dir) report_dir="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "${classes}" ]] || { echo "--classes is required" >&2; exit 2; }
KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
export KUBE_CONTEXT
kc() { kubectl --context "${KUBE_CONTEXT}" "$@"; }
mkdir -p "${report_dir}"
log() { printf '==> %s\n' "$*"; }

log "pre-flight"
if ((dry_run == 0)); then "${here}/preflight.sh" >"${report_dir}/preflight.txt" || { cat "${report_dir}/preflight.txt"; echo "refusing to start: pre-flight failed" >&2; exit 1; }; fi

# Nodes of the classes, plus the system nodes when asked. Primaries' nodes go last.
nodes=()
for cls in ${classes//,/ }; do
  while read -r n; do [[ -n "${n}" ]] && nodes+=("${n}"); done < <(kc get nodes -l "dbaas.local/node-class=${cls}" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
done
if ((system)); then
  while read -r n; do [[ -n "${n}" ]] && nodes+=("${n}"); done < <(kc get nodes -l 'pool=system' -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
fi
primary_nodes="$(kc get pods -A -l 'app.kubernetes.io/name=mariadb,k8s.mariadb.com/role=primary' -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}')"
ordered=()
for n in "${nodes[@]}"; do grep -qx "${n}" <<<"${primary_nodes}" || ordered+=("${n}"); done
for n in "${nodes[@]}"; do grep -qx "${n}" <<<"${primary_nodes}" && ordered+=("${n}"); done
log "${#ordered[@]} nodes in order: ${ordered[*]}"
((dry_run == 0)) || exit 0

primaries_before="$(kc get mariadb -A -l dbaas.local/engine=mariadb -o json | jq -c '[.items[] | {ns: .metadata.namespace, name: .metadata.name, primary: .status.currentPrimaryPodIndex}]')"

# drain_with_retry <node>: a plain drain. While the webhook is unavailable, wait and retry.
drain_with_retry() {
  local node="$1" attempt out
  for attempt in $(seq 1 20); do
    out="$(kc drain "${node}" --ignore-daemonsets --delete-emptydir-data --timeout=3600s 2>&1)" && { echo "${out}" >"${report_dir}/drain-${node}.log"; return 0; }
    if grep -qE 'failed calling webhook|no endpoints available|connection refused' <<<"${out}"; then
      log "the eviction webhook is unavailable (attempt ${attempt}); waiting"
      sleep 30
      continue
    fi
    echo "${out}" >"${report_dir}/drain-${node}.log"
    return 1
  done
  return 1
}

# discard_local_volumes <node>: on a local NVMe node the volumes that stayed there are gone with it.
discard_local_volumes() {
  local node="$1" cls
  cls="$(kc get node "${node}" -o jsonpath='{.metadata.labels.dbaas\.local/node-class}')"
  [[ "${cls}" == *nvme* ]] || return 0
  kc get pv -o json | jq -r --arg n "${node}" '.items[] | select(.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0] == $n)
    | select(.spec.claimRef.namespace | startswith("db-")) | "\(.spec.claimRef.namespace) \(.spec.claimRef.name)"' |
  while read -r ns pvc; do
    log "discarding the local volume ${ns}/${pvc} (the node is being replaced)"
    kc -n "${ns}" delete pvc "${pvc}" --wait=false >/dev/null || true
  done
}

wait_for_instances() {
  local deadline=$((SECONDS + 1800)) ok
  until ok="$(kc get mariadb -A -l dbaas.local/engine=mariadb -o json | jq -r '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length == ([.items[]] | length)')" && [[ "${ok}" == "true" ]]; do
    ((SECONDS < deadline)) || { echo "instances did not return to Ready"; return 1; }
    sleep 10
  done
}

for node in "${ordered[@]}"; do
  log "rotating ${node}"
  kc cordon "${node}" >/dev/null
  drain_with_retry "${node}" || { echo "the drain of ${node} failed: see ${report_dir}/drain-${node}.log" >&2; kc uncordon "${node}" >/dev/null; exit 1; }
  discard_local_volumes "${node}"
  # Replacement: on kind the node comes back as it is; on AKS aks-rotate-pools.sh replaces it.
  kc uncordon "${node}" >/dev/null
  wait_for_instances || exit 1
done

log "post-flight"
"${here}/postflight.sh" "${report_dir}/postflight.json"
jq -n --argjson before "${primaries_before}" --arg dir "${report_dir}" '{switchovers_per_instance_before: $before, report_dir: $dir}' >"${report_dir}/summary.json"
echo "rotation complete; reports in ${report_dir}"
