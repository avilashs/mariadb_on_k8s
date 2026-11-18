#!/usr/bin/env bash
# Monthly node image rotation on AKS, pool by pool (PLAN.md phase 9, section 9.1, method 1).
# Wraps pre-flight, `az aks nodepool upgrade --node-image-only` and post-flight.
#
#   RESOURCE_GROUP=rg CLUSTER=aks scripts/aks-rotate-pools.sh pool1 pool2 ... [--dry-run]
#
# The flags are those of `az aks nodepool upgrade` (current CLI; checked against Microsoft
# Learn). --max-blocked-nodes is only in the aks-preview extension: the script uses it when
# the extension is installed and says so otherwise. Never run this against a cluster
# without a staging rehearsal first (docs/rollout-checklist.md).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${RESOURCE_GROUP:?set RESOURCE_GROUP}" "${CLUSTER:?set CLUSTER}"
dry_run=0
pools=()
for arg in "$@"; do
  if [[ "${arg}" == "--dry-run" ]]; then dry_run=1; else pools+=("${arg}"); fi
done
((${#pools[@]} > 0)) || { echo "usage: $0 <pool>... [--dry-run]" >&2; exit 2; }

upgrade_args=(--resource-group "${RESOURCE_GROUP}" --cluster-name "${CLUSTER}" --node-image-only
  --undrainable-node-behavior Cordon --drain-timeout "${DRAIN_TIMEOUT_MINUTES:-60}" --node-soak-duration 5)
if az extension list --query "[?name=='aks-preview'].name" -o tsv 2>/dev/null | grep -q aks-preview; then
  upgrade_args+=(--max-blocked-nodes 1)
else
  echo "note: aks-preview is not installed: --max-blocked-nodes is not used" >&2
fi

for pool in "${pools[@]}"; do
  echo "==> pool ${pool}"
  if ((dry_run)); then
    echo "az aks nodepool upgrade --name ${pool} ${upgrade_args[*]}"
    continue
  fi
  "${here}/preflight.sh" >"${REPORT_DIR:-/tmp}/preflight-${pool}.txt" || { echo "pre-flight failed before ${pool}" >&2; exit 1; }
  az aks nodepool upgrade --name "${pool}" "${upgrade_args[@]}"
  "${here}/postflight.sh" "${REPORT_DIR:-/tmp}/postflight-${pool}.json" || { echo "post-flight failed after ${pool}; stop here" >&2; exit 1; }
done
