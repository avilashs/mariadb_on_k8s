#!/usr/bin/env bash
# Phase 6 acceptance (PLAN.md phase 6, e2e/failover): with the canary running, the
# primary's pod is force-deleted. A new primary serves within 60 seconds, the old
# primary rejoins as a replica, and the canary's report shows a longest write outage of
# at most 60 seconds and zero acknowledged writes lost.
#
# The canaries are read through port-forward (their image has no shell). Engine-neutral
# in intent; ENGINE=mariadb only until phase 10 adds the PostgreSQL primary helper.

set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${ENGINE}" != "mariadb" ]]; then
  log "failover suite skipped for ENGINE=${ENGINE} until the postgres helper exists (phase 10)"
  exit 0
fi

NAME=alpha
NS="db-${NAME}"
# checks run in subshells (lib.sh), so the pod that failed is handed over in a file.
STATE_FILE="$(mktemp)"
trap 'rm -f "${STATE_FILE}"' EXIT

check_canaries_running() {
  local ready
  ready="$(kc -n "${NS}" get deployment "${NAME}-canary" -o jsonpath='{.status.readyReplicas}')"
  [[ "${ready}" == "2" ]] || { echo "the canary deployment has ${ready:-0} ready replicas, want 2"; return 1; }
}

check_primary_replaced_within_60_seconds() {
  local old new deadline
  old="$(primary_pod "${NAME}")"
  printf '%s' "${old}" >"${STATE_FILE}"
  canary_reset "${NAME}"
  sleep 20
  kc -n "${NS}" delete pod "${old}" --force --grace-period=0 >/dev/null 2>&1
  local started=$SECONDS
  deadline=$((started + 60))
  until new="$(primary_pod "${NAME}")" && [[ -n "${new}" && "${new}" != "${old}" ]] && primary_accepts_writes "${new}"; do
    ((SECONDS < deadline)) || { echo "no new primary within 60 seconds (still ${old:-none})"; return 1; }
    sleep 2
  done
  echo "new primary ${new} serving after $((SECONDS - started)) seconds"
  printf '%s' "${old}" >"${STATE_FILE}"
}

# A new primary accepts writes: it takes a probe row, not just a role in the status.
primary_accepts_writes() {
  marker_write "${NAME}" "$1" "probe-$(date +%s%N)" >/dev/null 2>&1
}

check_old_primary_rejoins_as_replica() {
  local old deadline=$((SECONDS + 900))
  old="$(cat "${STATE_FILE}")"
  until [[ "$(replica_status "${NAME}" "${old}" 2>/dev/null)" == "Yes Yes" ]]; do
    ((SECONDS < deadline)) || { echo "${old} did not rejoin as a replica"; return 1; }
    sleep 10
  done
}

check_canary_report_meets_the_limits() {
  local pod report outage lost attempts
  sleep 30
  while read -r report; do
    pod="$(jq -r '.writer' <<<"${report}")"
    outage="$(jq -r '.longest_write_outage_seconds' <<<"${report}")"
    lost="$(jq -r '.lost_acknowledged_writes' <<<"${report}")"
    attempts="$(jq -r '.write_attempts' <<<"${report}")"
    echo "${pod}: attempts ${attempts}, longest write outage ${outage}s, lost ${lost}"
    ((attempts > 0)) || { echo "${pod} wrote nothing in the window"; return 1; }
    jq -en --argjson o "${outage}" '$o <= 60' >/dev/null || { echo "${pod}: write outage ${outage}s exceeds 60s"; return 1; }
    [[ "${lost}" == "0" ]] || { echo "${pod}: ${lost} acknowledged writes are missing"; return 1; }
  done < <(canary_reports "${NAME}")
}

check "the canary runs with two replicas" check_canaries_running
check "a new primary serves within 60 seconds of the old primary's pod being force-deleted" check_primary_replaced_within_60_seconds
check "the old primary rejoins as a replica" check_old_primary_rejoins_as_replica
check "the canary shows a write outage of at most 60 seconds and no lost acknowledged writes" check_canary_report_meets_the_limits

summary
