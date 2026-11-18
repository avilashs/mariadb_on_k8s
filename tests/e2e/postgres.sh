#!/usr/bin/env bash
# Phase 10 acceptance, the PostgreSQL leg (PLAN.md phase 10): the instance `ledger` has the same
# contract as a MariaDB instance. Runs only with ENGINE=postgres; the MariaDB suites skip it.
#
#  - the Cluster is Ready, with the instance's pods on distinct nodes
#  - the managed services <name>-primary and <name>-secondary have endpoints
#  - one standby confirms synchronously (synchronous replication)
#  - the canary writes and reads through the same Service names as MariaDB
#  - a force-deleted primary: a new primary within 60 seconds, a write outage of at most 60
#    seconds, zero acknowledged writes lost
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${ENGINE}" != "postgres" ]]; then
  log "postgres suite skipped for ENGINE=${ENGINE}"
  exit 0
fi

NAME=ledger
NS="db-${NAME}"

pg_pods() { kc -n "${NS}" get pods -l "cnpg.io/cluster=${NAME}" -o jsonpath='{.items[*].metadata.name}'; }
pg_primary() { kc -n "${NS}" get cluster "${NAME}" -o jsonpath='{.status.currentPrimary}'; }
psql_in() { kc -n "${NS}" exec "$1" -c postgres -- psql -U postgres -tAc "$2"; }

check_cluster_ready() {
  kc -n "${NS}" wait "cluster/${NAME}" --for=condition=Ready --timeout=600s >/dev/null
  local nodes
  nodes="$(kc -n "${NS}" get pods -l "cnpg.io/cluster=${NAME}" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort)"
  [[ "$(sort -u <<<"${nodes}" | wc -l)" == "$(wc -l <<<"${nodes}" | tr -d ' ')" ]] || { echo "two pods share a node"; return 1; }
}

check_managed_services_have_endpoints() {
  local svc
  for svc in "${NAME}-primary" "${NAME}-secondary"; do
    kc -n "${NS}" get service "${svc}" >/dev/null || { echo "no service ${svc}"; return 1; }
    local n
    n="$(kc -n "${NS}" get endpointslices -l "kubernetes.io/service-name=${svc}" -o json |
      jq '[.items[].endpoints[]? | select(.conditions.ready == true) | .addresses[]] | length')"
    [[ "${n}" -ge 1 ]] || { echo "${svc} has no endpoint"; return 1; }
  done
}

check_one_standby_confirms_synchronously() {
  local primary n
  primary="$(pg_primary)"
  n="$(psql_in "${primary}" "SELECT count(*) FROM pg_stat_replication WHERE sync_state IN ('sync', 'quorum')")"
  [[ "${n}" -ge 1 ]] || { echo "no synchronous standby (count ${n})"; return 1; }
}

check_canary_writes_and_reads() {
  canary_reset "${NAME}"
  sleep 20
  local report
  while read -r report; do
    echo "  $(jq -r .writer <<<"${report}"): attempts $(jq -r .write_attempts <<<"${report}"), failed $(jq -r .write_failures <<<"${report}")"
    [[ "$(jq -r .write_attempts <<<"${report}")" -gt 0 ]] || { echo "the canary wrote nothing"; return 1; }
    [[ "$(jq -r .read_failures <<<"${report}")" == "0" ]] || { echo "reads failed: ${report}"; return 1; }
  done < <(canary_reports "${NAME}")
}

check_force_deleted_primary_fails_over() {
  local old new started deadline
  canary_reset "${NAME}"
  sleep 15
  old="$(pg_primary)"
  started=$SECONDS
  kc -n "${NS}" delete pod "${old}" --force --grace-period=0 >/dev/null 2>&1
  deadline=$((started + 60))
  until new="$(pg_primary)" && [[ -n "${new}" && "${new}" != "${old}" ]]; do
    ((SECONDS < deadline)) || { echo "no new primary within 60 seconds (still ${old})"; return 1; }
    sleep 2
  done
  echo "  new primary ${new} after $((SECONDS - started)) seconds"
  sleep 30
  local report outage lost
  while read -r report; do
    outage="$(jq -r .longest_write_outage_seconds <<<"${report}")"
    lost="$(jq -r .lost_acknowledged_writes <<<"${report}")"
    echo "  $(jq -r .writer <<<"${report}"): longest write outage ${outage}s, lost ${lost}"
    jq -en --argjson o "${outage}" '$o <= 60' >/dev/null || { echo "write outage ${outage}s exceeds 60s"; return 1; }
    [[ "${lost}" == "0" ]] || { echo "${lost} acknowledged writes lost"; return 1; }
  done < <(canary_reports "${NAME}")
}

check "the Cluster is Ready, one pod per node" check_cluster_ready
check "the managed services <name>-primary and <name>-secondary have endpoints" check_managed_services_have_endpoints
check "one standby confirms synchronously" check_one_standby_confirms_synchronously
check "the canary writes and reads through the same Service names" check_canary_writes_and_reads
check "a force-deleted primary fails over within 60 seconds, with no lost acknowledged write" check_force_deleted_primary_fails_over

summary
