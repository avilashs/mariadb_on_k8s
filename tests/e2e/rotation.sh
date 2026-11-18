#!/usr/bin/env bash
# Phase 9 acceptance (PLAN.md phase 9, e2e/rotation). With one MariaDB instance on each node
# class and both canaries running, scripts/rotate-nodes.sh rolls all six database nodes
# (discarding the volumes on the NVMe class) and then the two system nodes.
#
#  - pre-flight and post-flight pass
#  - no instance is without a primary for longer than the planned-switchover limit
#  - zero lost acknowledged writes on every instance
#  - at most one pod per instance is away at any moment (sampled every second)
#  - every displaced NVMe pod re-seeded and rejoined without a manual step
#  - a second run refuses to start while a component is down (a broken replica, in
#    the form the pre-flight can see: drain-guard without its replicas)
#
# Engine-specific: ENGINE=mariadb only. Long: about an hour on the kind cluster.
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${ENGINE}" != "mariadb" ]]; then
  log "rotation suite skipped for ENGINE=${ENGINE}"
  exit 0
fi

WORK="$(mktemp -d)"
SAMPLER_PID=""
cleanup() {
  [[ -n "${SAMPLER_PID}" ]] && kill "${SAMPLER_PID}" 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

LIMIT_SWITCHOVER=15

# Sampler: once a second, per instance, how many of its pods are not Ready, and the primary.
start_sampler() {
  (
    while :; do
      ts="$(date +%s)"
      for inst in alpha beta; do
        pods="$(kc -n "db-${inst}" get pods -l "app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=${inst}" -o json 2>/dev/null)"
        away="$(jq '[.items[] | select(([.status.containerStatuses[]? | .ready] | all) | not)] | length' <<<"${pods:-{\}}" 2>/dev/null || echo 0)"
        prim="$(kc -n "db-${inst}" get mariadb "${inst}" -o jsonpath='{.status.currentPrimaryPodIndex}' 2>/dev/null || echo x)"
        echo "${ts} ${inst} away=${away} prim=${prim}"
      done
      sleep 1
    done
  ) >"${WORK}/samples.log" 2>/dev/null &
  SAMPLER_PID=$!
}

stop_sampler() {
  [[ -n "${SAMPLER_PID}" ]] && kill "${SAMPLER_PID}" 2>/dev/null || true
  wait "${SAMPLER_PID}" 2>/dev/null || true
  SAMPLER_PID=""
}

rotation_run() {
  local report="$1"
  "${ROOT}/scripts/rotate-nodes.sh" --classes kind-pv2,kind-nvme --system --report-dir "${report}" >"${WORK}/rotate.log" 2>&1
}

check_rotation_completes() {
  canary_reset alpha
  canary_reset beta
  start_sampler
  rotation_run "${WORK}/report-1" || { tail -30 "${WORK}/rotate.log"; return 1; }
  stop_sampler
  [[ -s "${WORK}/report-1/postflight.json" ]] || { echo "no post-flight report"; return 1; }
  [[ "$(jq -r '.failed' "${WORK}/report-1/postflight.json")" == "0" ]] || { jq . "${WORK}/report-1/postflight.json"; return 1; }
}

check_at_most_one_pod_away() {
  local worst
  worst="$(awk '{ split($3, a, "="); if (a[2] + 0 > max[$2]) max[$2] = a[2] + 0 } END { for (i in max) print i, max[i] }' "${WORK}/samples.log")"
  echo "  most pods away: ${worst//$'\n'/; }"
  awk '{ split($3, a, "="); if (a[2] + 0 > 1) bad = 1 } END { exit bad }' "${WORK}/samples.log" ||
    { echo "more than one pod of an instance was away at some second"; return 1; }
}

check_no_outage_beyond_limit_and_no_loss() {
  local inst report
  for inst in alpha beta; do
    while read -r report; do
      local outage lost
      outage="$(jq -r '.longest_write_outage_seconds' <<<"${report}")"
      lost="$(jq -r '.lost_acknowledged_writes' <<<"${report}")"
      echo "  ${inst}: longest write outage ${outage}s, lost ${lost}"
      jq -en --argjson o "${outage}" --argjson l "${LIMIT_SWITCHOVER}" '$o <= $l' >/dev/null ||
        { echo "${inst}: outage ${outage}s exceeds ${LIMIT_SWITCHOVER}s"; return 1; }
      [[ "${lost}" == "0" ]] || { echo "${inst}: ${lost} acknowledged writes lost"; return 1; }
    done < <(canary_reports "${inst}")
  done
}

check_switchovers_bounded() {
  local inst changes
  for inst in alpha beta; do
    changes="$(awk -v i="${inst}" '$2 == i { split($4, a, "="); if (prev != "" && a[2] != prev) n++; prev = a[2] } END { print n + 0 }' "${WORK}/samples.log")"
    echo "  ${inst}: planned switchovers ${changes} (nodes in its class: 3)"
    [[ "${changes}" -le 3 ]] || { echo "${inst} switched ${changes} times"; return 1; }
  done
}

check_nvme_pods_reseeded() {
  local deadline=$((SECONDS + 900))
  until [[ "$(replica_status beta "$(primary_pod beta)" >/dev/null 2>&1; kc -n db-beta get pods -l app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=beta -o jsonpath='{.items[*].metadata.name}' | wc -w | tr -d ' ')" == "3" ]] &&
    [[ "$(kc -n db-beta get mariadb beta -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]]; do
    ((SECONDS < deadline)) || { echo "beta did not return to three ready pods"; return 1; }
    sleep 10
  done
  local pod
  for pod in $(kc -n db-beta get pods -l app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=beta -o jsonpath='{.items[*].metadata.name}'); do
    [[ "$(replica_status beta "${pod}" 2>/dev/null)" == "Yes Yes" ]] || [[ "${pod}" == "$(primary_pod beta)" ]] ||
      { echo "${pod} did not rejoin replication"; return 1; }
  done
}

check_second_run_refuses_to_start() {
  kc -n dbaas-system scale deployment drain-guard --replicas=0 >/dev/null
  if "${ROOT}/scripts/rotate-nodes.sh" --classes kind-pv2 --report-dir "${WORK}/report-2" >"${WORK}/rotate-2.log" 2>&1; then
    kc -n dbaas-system scale deployment drain-guard --replicas=2 >/dev/null
    echo "the rotation started with drain-guard down"
    return 1
  fi
  kc -n dbaas-system scale deployment drain-guard --replicas=2 >/dev/null
  kc -n dbaas-system rollout status deployment drain-guard --timeout=300s >/dev/null
  grep -q 'refusing to start' "${WORK}/rotate-2.log" || grep -q 'pre-flight FAILED' "${WORK}/rotate-2.log" ||
    { echo "the refusal does not come from the pre-flight"; return 1; }
}

check "every node of both classes and the system pool rolls; post-flight passes" check_rotation_completes
check "at most one pod per instance is away at any moment" check_at_most_one_pod_away
check "no instance is without a primary beyond the switchover limit; zero acknowledged writes lost" check_no_outage_beyond_limit_and_no_loss
check "planned switchovers per instance do not exceed its node count" check_switchovers_bounded
check "the displaced NVMe pods re-seeded and rejoined by themselves" check_nvme_pods_reseeded
check "a rotation refuses to start while a component is down" check_second_run_refuses_to_start

summary
