#!/usr/bin/env bash
# Phase 5 acceptance (PLAN.md phase 5, e2e/scale-out): an instance that starts with one
# replica gets a second one by changing replicas, and the new replica seeds itself
# from the backup, joins replication and becomes Ready with no manual step. Lowering
# replicas again removes only the newest pod.
#
# Engine-specific: ENGINE=mariadb only.

set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${ENGINE}" != "mariadb" ]]; then
  log "scale-out suite skipped for ENGINE=${ENGINE}"
  exit 0
fi

NAME=grow
NS="db-${NAME}"

log "scale-out acceptance: instance ${NAME} on kind-pv2, one replica, backups enabled"
trap 'instance_down "${NAME}"' EXIT
values="$(instance_values "${NAME}" kind-pv2 small 1)"
yq -i '.backup.enabled = true' "${values}"
helm --kube-context "${CONTEXT}" upgrade --install "ns-${NAME}" "${ROOT}/charts/db-namespace" \
  --set "name=${NAME}" --set "engine=mariadb" >/dev/null
"${ROOT}/scripts/ensure-secret.sh" "${CONTEXT}" "${NS}" "${NAME}-orders-app-credentials" password >/dev/null
"${ROOT}/scripts/ensure-backup-credentials.sh" "${CONTEXT}" "${NS}" "${PLATFORM_FILE}" >/dev/null
helm --kube-context "${CONTEXT}" upgrade --install "${NAME}" "${ROOT}/charts/mariadb-instance" \
  --namespace "${NS}" --values "${values}" --wait=false >/dev/null
kc -n "${NS}" wait "mariadb/${NAME}" --for=condition=Ready --timeout=900s >/dev/null

pods_json() { kc -n "${NS}" get pods -l "app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=${NAME}" -o json; }
pod_count() { pods_json | jq '[.items[] | select(.status.phase == "Running" and ([.status.containerStatuses[]? | .ready] | all))] | length'; }
wait_for_pods() {
  local want="$1" deadline=$((SECONDS + 900))
  until [[ "$(pod_count)" == "${want}" ]]; do
    ((SECONDS < deadline)) || { echo "expected ${want} ready pods, have $(pod_count)"; return 1; }
    sleep 10
  done
}

check_backup_exists_before_growth() {
  # Ask for a backup explicitly: the replica bootstrap needs one, and the immediate backup
  # of a new instance is not something the suite should depend on.
  kc -n "${NS}" patch physicalbackup "${NAME}-backup" --type merge \
    -p "{\"spec\":{\"schedule\":{\"onDemand\":\"e2e-$(date +%s)\"}}}" >/dev/null
  local deadline=$((SECONDS + 600))
  until s3_objects "${NAME}/physical/" | grep -q .; do
    ((SECONDS < deadline)) || { echo "no backup object under ${NAME}/physical/ in the bucket"; return 1; }
    sleep 10
  done
}

check_primary_marker_written() {
  marker_write "${NAME}" "$(primary_pod "${NAME}")" before-growth
}

check_new_replica_seeds_and_joins() {
  helm --kube-context "${CONTEXT}" upgrade "${NAME}" "${ROOT}/charts/mariadb-instance" \
    --namespace "${NS}" --reuse-values --set replicas=2 --wait=false >/dev/null
  wait_for_pods 3 || return 1
  kc -n "${NS}" wait "mariadb/${NAME}" --for=condition=Ready --timeout=900s >/dev/null
  local newest="${NAME}-2"
  marker_present "${NAME}" "${newest}" before-growth ||
    { echo "the new replica does not have the data written before it joined"; return 1; }
  [[ "$(replica_status "${NAME}" "${newest}")" == "Yes Yes" ]] ||
    { echo "the new replica is not replicating: $(replica_status "${NAME}" "${newest}")"; return 1; }
}

check_scale_in_removes_only_the_newest_pod() {
  local before after
  before="$(pods_json | jq -r '[.items[] | select(.metadata.name != "'"${NAME}-2"'") | .metadata.uid] | sort | join(" ")')"
  helm --kube-context "${CONTEXT}" upgrade "${NAME}" "${ROOT}/charts/mariadb-instance" \
    --namespace "${NS}" --reuse-values --set replicas=1 --wait=false >/dev/null
  wait_for_pods 2 || return 1
  after="$(pods_json | jq -r '[.items[] | .metadata.uid] | sort | join(" ")')"
  [[ "${before}" == "${after}" ]] || { echo "a remaining pod was replaced during scale-in"; return 1; }
  kc -n "${NS}" get pod "${NAME}-2" >/dev/null 2>&1 && { echo "the newest pod was not removed"; return 1; }
  return 0
}

check "a backup exists for the instance before it grows" check_backup_exists_before_growth
check "data written before growth is on the primary" check_primary_marker_written
check "raising replicas to 2 seeds a new replica from the backup and it joins replication" check_new_replica_seeds_and_joins
check "lowering replicas removes only the newest pod" check_scale_in_removes_only_the_newest_pod

summary
