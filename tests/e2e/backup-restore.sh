#!/usr/bin/env bash
# Phase 5 acceptance (PLAN.md phase 5, e2e/backup-restore). Runs on both kind node
# classes: alpha (kind-pv2, Premium SSD v2 stand-in) and beta (kind-nvme, local NVMe
# stand-in). Both instances must have backups enabled in environments/kind/instances.
#
#  - An on-demand backup completes and its object exists in the bucket.
#  - A replica whose pod and volume claim are deleted re-seeds and rejoins by itself.
#    On kind-nvme this is the stand-in for a local NVMe pod that came back empty.
#  - Point in time: marker A, a noted time T, marker B. Restoring to T gives A and not B.
#  - scripts/restore-drill.sh exits 0.
#
# Engine-specific: ENGINE=mariadb only.

set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${ENGINE}" != "mariadb" ]]; then
  log "backup-restore suite skipped for ENGINE=${ENGINE}"
  exit 0
fi

RESTORES=()
cleanup_restores() {
  local r
  for r in "${RESTORES[@]:-}"; do
    [[ -n "${r}" ]] || continue
    kc -n "db-${r%%:*}" delete mariadb "${r#*:}" --ignore-not-found --wait=true --timeout=600s >/dev/null 2>&1 || true
    kc -n "db-${r%%:*}" delete pvc -l "app.kubernetes.io/instance=${r#*:}" --ignore-not-found >/dev/null 2>&1 || true
    kc -n "db-${r%%:*}" delete secret "${r#*:}-root" --ignore-not-found >/dev/null 2>&1 || true
  done
}
trap cleanup_restores EXIT

# Marker labels are unique per run: the table keeps rows from earlier runs.
RUN_ID="$(date +%s)"

# Set per instance before its checks run.
INST=""
NS=""

pod_ready() { kc -n "${NS}" get pod "$1" -o json | jq -e '.status.phase == "Running" and ([.status.containerStatuses[]? | .ready] | all)' >/dev/null; }
wait_for_pod_ready() {
  local pod="$1" deadline=$((SECONDS + 900))
  until pod_ready "${pod}" 2>/dev/null; do
    ((SECONDS < deadline)) || { echo "pod ${pod} did not become Ready"; return 1; }
    sleep 10
  done
}

check_on_demand_backup_in_bucket() {
  local before after deadline
  before="$(s3_objects "${INST}/physical/" | wc -l | tr -d ' ')"
  kc -n "${NS}" patch physicalbackup "${INST}-backup" --type merge \
    -p "{\"spec\":{\"schedule\":{\"onDemand\":\"e2e-$(date +%s)\"}}}" >/dev/null
  deadline=$((SECONDS + 900))
  until after="$(s3_objects "${INST}/physical/" | wc -l | tr -d ' ')" && ((after > before)); do
    ((SECONDS < deadline)) || { echo "the on-demand backup of ${INST} did not reach the bucket"; return 1; }
    sleep 15
  done
}

check_replica_reseeds_after_pod_and_volume_loss() {
  local primary replica index pvc
  primary="$(primary_pod "${INST}")"
  replica="$(kc -n "${NS}" get pods -l "app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=${INST}" -o json |
    jq -r --arg p "${primary}" '[.items[].metadata.name | select(. != $p)] | sort | last')"
  index="${replica##*-}"
  marker_write "${INST}" "${primary}" "before-loss-${INST}" >/dev/null
  pvc="$(kc -n "${NS}" get pod "${replica}" -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}')"
  [[ -n "${pvc}" ]] || { echo "no volume claim found for ${replica}"; return 1; }

  kc -n "${NS}" delete pvc "${pvc}" --wait=false >/dev/null
  kc -n "${NS}" delete pod "${replica}" --wait=false >/dev/null
  # The operator rebuilds the replica from the backup and catches up through GTID.
  wait_for_pod_ready "${replica}" || return 1
  local deadline=$((SECONDS + 900))
  until [[ "$(replica_status "${INST}" "${replica}")" == "Yes Yes" ]]; do
    ((SECONDS < deadline)) || { echo "${replica} (index ${index}) did not rejoin replication"; return 1; }
    sleep 10
  done
  marker_present "${INST}" "${replica}" "before-loss-${INST}" ||
    { echo "${replica} rejoined without the data written before its loss"; return 1; }
}

# restored_marker <restored-instance> <pod> <label>: how many rows carry the label. A restored instance
# lives in the source's namespace (db-${INST}), not in db-<its own name> as the lib helpers assume.
restored_marker() {
  # The restored instance can still be settling when the restore returns (a pod restarting, the
  # primary not yet reported), so a failed lookup is retried for up to two minutes. It prints the
  # count, or nothing when the instance never answered.
  local password primary out deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    password="$(kc -n "${NS}" get secret "$1-root" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
    primary="$(kc -n "${NS}" get mariadb "$1" -o jsonpath='{.status.currentPrimary}' 2>/dev/null)"
    if [[ -n "${password}" && -n "${primary}" ]] &&
      out="$(kc -n "${NS}" exec "${primary}" -c mariadb -- mariadb --ssl -uroot -p"${password}" -N -B \
        -e "SELECT COUNT(*) FROM dbaas_marker.markers WHERE label = '$2'" 2>/dev/null)" && [[ -n "${out}" ]]; then
      printf '%s\n' "${out}"
      return 0
    fi
    sleep 5
  done
  return 1
}

check_point_in_time_restore() {
  local target restored="${INST}-pitr" primary
  marker_write "${INST}" "$(primary_pod "${INST}")" "A-${INST}-${RUN_ID}" >/dev/null
  sleep 2
  target="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sleep 2
  marker_write "${INST}" "$(primary_pod "${INST}")" "B-${INST}-${RUN_ID}" >/dev/null

  RESTORES+=("${NS#db-}:${restored}")
  KUBE_CONTEXT="${CONTEXT}" "${ROOT}/scripts/restore-instance.sh" "${INST}" "${target}" "${restored}" >/dev/null ||
    { echo "restore of ${INST} to ${target} failed"; return 1; }
  [[ "$(restored_marker "${restored}" "A-${INST}-${RUN_ID}")" == "1" ]] ||
    { echo "restored instance lacks A (before ${target})"; return 1; }
  if [[ "$(restored_marker "${restored}" "B-${INST}-${RUN_ID}")" == "1" ]]; then
    echo "restored instance has B (written after ${target})"
    return 1
  fi
}

check_restore_drill_exits_zero() {
  MARKER_TABLE=dbaas_marker.markers KUBE_CONTEXT="${CONTEXT}" "${ROOT}/scripts/restore-drill.sh" "${INST}" >/dev/null ||
    { echo "scripts/restore-drill.sh ${INST} did not exit 0"; return 1; }
}

# want <case>: true when ONLY is unset or lists the case (backup reseed pitr drill); INSTANCES restricts the
# instances, e.g. ONLY="pitr" INSTANCES="beta".
want() { [[ -z "${ONLY:-}" || " ${ONLY} " == *" $1 "* ]]; }

for INST in ${INSTANCES:-alpha beta}; do
  NS="db-${INST}"
  node_class="$(kc -n "${NS}" get mariadb "${INST}" -o jsonpath='{.metadata.labels.dbaas\.local/node-class}')"
  log "backup-restore acceptance for ${INST} on ${node_class}"
  want backup && check "[${INST}] an on-demand backup completes and its object exists in the bucket" check_on_demand_backup_in_bucket
  want reseed && check "[${INST}] a replica that loses its pod and volume re-seeds and rejoins by itself" check_replica_reseeds_after_pod_and_volume_loss
  want pitr && check "[${INST}] point in time restore to T has A and not B" check_point_in_time_restore
  want drill && check "[${INST}] scripts/restore-drill.sh exits 0" check_restore_drill_exits_zero
done

summary
