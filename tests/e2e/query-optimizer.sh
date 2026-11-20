#!/usr/bin/env bash
# Query optimizer add-on acceptance (docs/query-optimizer.md). Runs on the instances that enable it:
# alpha (MariaDB, database orders) and ledger (PostgreSQL, database ledger), both with the offline mock model.
#
#  - Notify-only (the default): the job finds a slow query of the test workload, names it in its report and
#    changes nothing: no index appears.
#  - Fail closed: with god mode on, a canned recommendation to create an index is NOT applied, because the
#    account the job uses can only read.
#
# The suite leaves the releases as the helmfile defines them.

set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUN_ID="$(date +%s)"
TABLE="qopt_demo_${RUN_ID}"
CHART="${ROOT}/charts/db-query-optimizer"
INSTANCES="${INSTANCES:-alpha ledger}"
IMAGE="${QOPT_IMAGE:-dbaas/query-optimizer:dev}"

engine_of() { yq -r '.engine // "mariadb"' "${ROOT}/environments/${ENV}/instances/$1.yaml"; }

# run_sql <instance> <database> <sql>: runs on the primary as the superuser.
run_sql() {
  local inst="$1" db="$2" stmt="$3" pod
  if [[ "$(engine_of "${inst}")" == "postgres" ]]; then
    pod="$(kc -n "db-${inst}" get cluster "${inst}" -o jsonpath='{.status.currentPrimary}')"
    kc -n "db-${inst}" exec "${pod}" -c postgres -- psql -U postgres -d "${db}" -Atc "${stmt}"
  else
    pod="$(primary_pod "${inst}")"
    sql "${inst}" "${pod}" "${db}" -N -e "${stmt}"
  fi
}

database_of() { yq -r '.queryOptimizer.database // ""' "${ROOT}/environments/${ENV}/instances/$1.yaml"; }

seed_workload() {
  local inst="$1" db="$2" i
  if [[ "$(engine_of "${inst}")" == "postgres" ]]; then
    run_sql "${inst}" "${db}" "create table ${TABLE} as select g as id, (g % 5000) as k, md5(g::text) as pad from generate_series(1,60000) g; analyze ${TABLE};"
    for i in $(seq 1 40); do run_sql "${inst}" "${db}" "select count(*) from ${TABLE} where k = ${i};" >/dev/null; done
  else
    run_sql "${inst}" "${db}" "create table ${TABLE} (id int primary key, k int not null, pad char(32) not null); insert into ${TABLE} select seq, seq % 5000, md5(seq) from seq_1_to_60000;"
    for i in $(seq 1 40); do run_sql "${inst}" "${db}" "select count(*) from ${TABLE} where k = ${i};" >/dev/null; done
  fi
}

index_count() {
  local inst="$1" db="$2"
  if [[ "$(engine_of "${inst}")" == "postgres" ]]; then
    run_sql "${inst}" "${db}" "select count(*) from pg_indexes where tablename='${TABLE}' and indexname not like '%pkey'"
  else
    run_sql "${inst}" "${db}" "select count(*) from information_schema.statistics where table_schema='${db}' and table_name='${TABLE}' and index_name <> 'PRIMARY'"
  fi
}

# run_job <instance> <name>: starts the CronJob's job and prints its log.
run_job() {
  local inst="$1" name="$2"
  kc -n "db-${inst}" delete job "${name}" --ignore-not-found >/dev/null
  kc -n "db-${inst}" create job --from="cronjob/${inst}-query-optimizer" "${name}" >/dev/null
  kc -n "db-${inst}" wait --for=condition=complete "job/${name}" --timeout=240s >/dev/null || {
    kc -n "db-${inst}" logs "job/${name}" | tail -30
    return 1
  }
  kc -n "db-${inst}" logs "job/${name}"
}

check_notify_only() {
  local inst="$1" db="$2" log
  log="$(helm_override "${inst}" "skipRecentHours=0" ; run_job "${inst}" "${inst}-qo-e2e-notify")"
  echo "${log}" | grep -q "notify-only" || { echo "the run did not report notify-only"; echo "${log}"; return 1; }
  echo "${log}" | grep -qi "${TABLE}" || { echo "the workload query on ${TABLE} was not collected"; echo "${log}"; return 1; }
  [[ "$(index_count "${inst}" "${db}")" == "0" ]] || { echo "an index appeared although the job is notify-only"; return 1; }
}

# helm_override <instance> <set args...>: upgrades the release in place with extra values.
helm_override() {
  local inst="$1"
  shift
  local args=() a
  for a in "$@"; do args+=(--set "${a}"); done
  helm --kube-context "${CONTEXT}" -n "db-${inst}" upgrade "${inst}-qopt" "${CHART}" --reuse-values "${args[@]}" >/dev/null
}

check_fail_closed() {
  local inst="$1" db="$2" resp stmt log
  stmt="CREATE INDEX idx_${TABLE}_k ON ${TABLE} (k)"
  resp="$(jq -nc --arg s "${stmt}" '{summary:"index on k",statements:[$s],rewritten_query:null,confidence:0.95,risk:"low",rationale:"full scan on k"}')"
  helm --kube-context "${CONTEXT}" -n "db-${inst}" upgrade "${inst}-qopt" "${CHART}" --reuse-values \
    --set godMode=true --set skipRecentHours=0 --set apply.min_score=0 --set-json "llms=[{\"name\":\"mock\",\"provider\":\"mock\",\"model\":\"mock\",\"options\":{\"response\":$(jq -Rs . <<<"${resp}")}}]" >/dev/null
  log="$(run_job "${inst}" "${inst}-qo-e2e-god" || true)"
  echo "${log}" | tail -15
  [[ "$(index_count "${inst}" "${db}")" == "0" ]] || { echo "the index was created through a read-only account"; return 1; }
}

restore_release() {
  local inst
  for inst in ${INSTANCES}; do
    run_sql "${inst}" "$(database_of "${inst}")" "drop table if exists ${TABLE}" >/dev/null 2>&1 || true
    kc -n "db-${inst}" delete job "${inst}-qo-e2e-notify" "${inst}-qo-e2e-god" --ignore-not-found >/dev/null 2>&1 || true
  done
  (cd "${ROOT}" && ENV="${ENV}" helmfile -f helmfile.d/10-instances.yaml.gotmpl sync --skip-deps --selector stage=optimizer >/dev/null 2>&1) || true
}
trap restore_release EXIT

for inst in ${INSTANCES}; do
  db="$(database_of "${inst}")"
  [[ -n "${db}" && "${db}" != "null" ]] || { echo "instance ${inst} does not enable the query optimizer: skipped"; continue; }
  echo "==> query optimizer on ${inst} ($(engine_of "${inst}"), database ${db})"
  seed_workload "${inst}" "${db}"
  check "[${inst}] notify-only: the slow query is reported and no index is created" check_notify_only "${inst}" "${db}"
  check "[${inst}] god mode with a read-only account fails closed: no index is created" check_fail_closed "${inst}" "${db}"
done

summary
