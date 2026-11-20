#!/usr/bin/env bash
# Removes the volumes of the kind test cluster that nothing uses any more.
#
#   hack/kind-clean-volumes.sh [--dry-run]
#
# The database storage classes use reclaimPolicy Retain (a deleted claim must never delete data), so a
# deleted claim leaves its PersistentVolume in phase Released and its data directory on the kind node.
# Every drill, restore and re-seed of a test run leaves one behind: 41 of them held about 6 GB of the
# sandbox's disk, and a full disk makes the test object store refuse writes. Only Released volumes are
# touched; Bound ones (an instance's data) never are. kind only: the directories are removed with
# docker exec on the node, which has no meaning on a real cluster, where a Released volume is a decision
# for a person.
set -euo pipefail

context="${KUBE_CONTEXT:-kind-dbaas}"
dry_run=0
[[ "${1:-}" == "--dry-run" ]] && dry_run=1
[[ "${context}" == kind-* ]] || { echo "refusing to run against ${context}: kind only" >&2; exit 2; }

removed=0
while read -r pv path node; do
  [[ -n "${pv}" ]] || continue
  case "${path}" in
    /var/local-path-provisioner/pvc-*) ;;
    *) echo "skipping ${pv}: unexpected path '${path}'" >&2; continue ;;
  esac
  if ((dry_run)); then
    echo "would remove ${pv} (${node}:${path})"
  else
    docker exec "${node}" rm -rf "${path}"
    kubectl --context "${context}" delete pv "${pv}" --wait=false >/dev/null
    echo "removed ${pv}"
  fi
  removed=$((removed + 1))
done < <(kubectl --context "${context}" get pv -o json | jq -r '
  .items[] | select(.status.phase == "Released")
  | "\(.metadata.name) \(.spec.local.path // .spec.hostPath.path) \(.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0])"')
echo "${removed} released volume(s) $( ((dry_run)) && echo 'found' || echo 'removed')"
