#!/usr/bin/env bash
# Phase 3 acceptance (PLAN.md phase 3, e2e/topology): one MariaDB instance is a
# primary plus replicas that replicate, with semi-synchronous replication, and
# clients see a single writable endpoint and a read-only one.
#
# Engine-specific: ENGINE=mariadb only.

set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${ENGINE}" != "mariadb" ]]; then
  log "topology suite skipped for ENGINE=${ENGINE}"
  exit 0
fi

NAME=topo
NS="db-${NAME}"

log "topology acceptance: instance ${NAME} on kind-pv2"
trap 'instance_down "${NAME}"' EXIT
instance_up "${NAME}" kind-pv2 small 2

primary() { kc -n "${NS}" get mariadb "${NAME}" -o jsonpath='{.status.currentPrimary}'; }
pods() { kc -n "${NS}" get pods -l "app.kubernetes.io/instance=${NAME}" -o jsonpath='{.items[*].metadata.name}'; }
replica_pods() {
  local p
  for p in $(pods); do
    [[ "${p}" == "$(primary)" ]] || echo "${p}"
  done
}

check_ready() {
  kc -n "${NS}" get mariadb "${NAME}" -o json |
    jq -e '.status.conditions[] | select(.type == "Ready") | .status == "True"' >/dev/null
}

check_one_primary_and_replicas() {
  local count replicas
  count="$(pods | wc -w | tr -d ' ')"
  replicas="$(replica_pods | wc -w | tr -d ' ')"
  [[ "${count}" == "3" ]] || { echo "pods: ${count}, want 3"; return 1; }
  [[ "${replicas}" == "2" ]] || { echo "replicas: ${replicas}, want 2"; return 1; }
  [[ -n "$(primary)" ]] || { echo "no current primary"; return 1; }
}

check_replication_threads() {
  # MariaDB 11.8 reports both Slave_* and Replica_* names, depending on the build.
  local pod status
  for pod in $(replica_pods); do
    status="$(sql "${NAME}" "${pod}" -e 'SHOW REPLICA STATUS\G')"
    if ! { grep -Eq '(Replica|Slave)_IO_Running: Yes' <<<"${status}" &&
      grep -Eq '(Replica|Slave)_SQL_Running: Yes' <<<"${status}"; }; then
      echo "${pod}: replication threads are not both running"
      return 1
    fi
    grep -Eq 'Using_Gtid: (Current|Slave)_Pos' <<<"${status}" ||
      { echo "${pod}: not replicating with GTID"; return 1; }
  done
}

check_semi_sync_on_primary() {
  local value
  value="$(sql "${NAME}" "$(primary)" -N -e "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_master_status'" | awk '{print $2}')"
  [[ "${value}" == "ON" ]] || { echo "semi-synchronous replication is ${value:-missing} on the primary"; return 1; }
}

check_row_reaches_replicas() {
  # Written through the primary Service, read through the secondary Service.
  local marker deadline value pod password
  marker="marker-$(date +%s)"
  password="$(kc -n "${NS}" get secret "${NAME}-root" -o jsonpath='{.data.password}' | base64 -d)"
  pod="$(replica_pods | head -n1)"
  kc -n "${NS}" exec "$(primary)" -c mariadb -- mariadb --ssl -h "${NAME}-primary" -uroot -p"${password}" \
    -e "CREATE TABLE IF NOT EXISTS orders.e2e (v VARCHAR(64) PRIMARY KEY); INSERT INTO orders.e2e VALUES ('${marker}')" >/dev/null
  deadline=$((SECONDS + 5))
  while :; do
    value="$(kc -n "${NS}" exec "${pod}" -c mariadb -- \
      mariadb --ssl -h "${NAME}-secondary" -uroot -p"${password}" -N -e "SELECT v FROM orders.e2e WHERE v='${marker}'" 2>/dev/null || true)"
    [[ "${value}" == "${marker}" ]] && return 0
    ((SECONDS < deadline)) || { echo "row ${marker} did not reach ${NAME}-secondary within 5 seconds"; return 1; }
    sleep 1
  done
}

check_secondary_refuses_application_writes() {
  # The application account is the one that must be refused on a replica. Root is
  # not checked here: MariaDB has no super_read_only, so SUPER accounts can write to
  # a replica. Applications never receive root (see docs/operations.md).
  local pod password output
  pod="$(replica_pods | head -n1)"
  password="$(kc -n "${NS}" get secret "${NAME}-orders-app-credentials" -o jsonpath='{.data.password}' | base64 -d)"
  output="$(kc -n "${NS}" exec "${pod}" -c mariadb -- \
    mariadb --ssl -h "${NAME}-secondary" -uorders_app -p"${password}" orders -e "INSERT INTO e2e VALUES ('from-secondary')" 2>&1 || true)"
  grep -q "read-only option" <<<"${output}" || { echo "application write through ${NAME}-secondary was not refused as read-only: ${output}"; return 1; }
}

check_plaintext_refused() {
  local password
  password="$(kc -n "${NS}" get secret "${NAME}-root" -o jsonpath='{.data.password}' | base64 -d)"
  if kc -n "${NS}" exec "$(primary)" -c mariadb -- \
    mariadb --skip-ssl -h 127.0.0.1 -uroot -p"${password}" -e 'SELECT 1' 2>/dev/null; then
    echo "a connection without TLS was accepted"
    return 1
  fi
}

check "instance reports Ready" check_ready
check "exactly one primary and two replicas" check_one_primary_and_replicas
check "both replicas run IO and SQL threads, using GTID" check_replication_threads
check "semi-synchronous replication is on at the primary" check_semi_sync_on_primary
check "a row written through the primary Service reaches a replica within 5 seconds" check_row_reaches_replicas
check "an application write through the secondary Service is refused as read-only" check_secondary_refuses_application_writes
check "a connection without TLS is refused" check_plaintext_refused

summary
