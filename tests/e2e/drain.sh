#!/usr/bin/env bash
# Phase 7 acceptance (PLAN.md phase 7, e2e/drain). Every case uses a plain drain, never
# --force and never --disable-eviction. The canary of each instance is reset before a
# case and judged after it. On kind-pv2 the volume survives a drain (a re-attached disk);
# on kind-nvme the volume is deleted by case i (a new node, an empty disk).
#
# A sampler records, once a second, the primary index, the pods (name, uid, phase) and
# the number of endpoints of the secondary Service. Orders of events are read from it.
#
# Engine-specific: ENGINE=mariadb only. The suite is long (see docs/operations.md).

set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${ENGINE}" != "mariadb" ]]; then
  log "drain suite skipped for ENGINE=${ENGINE}"
  exit 0
fi

WORK="$(mktemp -d)"
SAMPLER_PID=""
DRAIN_PID=""
cleanup() {
  [[ -n "${SAMPLER_PID}" ]] && kill "${SAMPLER_PID}" 2>/dev/null || true
  [[ -n "${DRAIN_PID}" ]] && kill "${DRAIN_PID}" 2>/dev/null || true
  rm -rf "${WORK}"
  # Leave every node schedulable, whatever a failed case left behind.
  local node
  for node in $(kc get nodes -l 'dbaas.local/node-class' -o name 2>/dev/null); do
    kc uncordon "${node#node/}" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

LIMIT_SWITCHOVER=15   # section 7.3, kind column: planned switchover
LIMIT_REPLICA=2       # section 7.3: replica drained is 0 s; 2 s allows one missed tick

node_of() { kc -n "db-$1" get pod "$2" -o jsonpath='{.spec.nodeName}'; }
primary_index() { kc -n "db-$1" get mariadb "$1" -o jsonpath='{.status.currentPrimaryPodIndex}'; }
primary_pod() { echo "$1-$(primary_index "$1")"; }
pods_of() { kc -n "db-$1" get pods -l "app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=$1" -o jsonpath='{.items[*].metadata.name}'; }
class_nodes() { kc get nodes -l "dbaas.local/node-class=$1" -o jsonpath='{.items[*].metadata.name}'; }
replica_node() {
  local inst="$1" primary pod
  primary="$(primary_index "${inst}")"
  for pod in $(pods_of "${inst}"); do
    [[ "${pod##*-}" != "${primary}" ]] && { node_of "${inst}" "${pod}"; return 0; }
  done
  return 1
}

# The secondary Service has no selector: the operator maintains its EndpointSlices.
secondary_endpoints() {
  kc -n "db-$1" get endpointslices -l "kubernetes.io/service-name=$1-secondary" -o json |
    jq '[.items[].endpoints[]? | select(.conditions.ready == true) | .addresses[]] | length'
}

start_sampler() {
  local inst="$1" ns="db-$1" log="${WORK}/$1-samples.log"
  : >"${log}"
  (
    while :; do
      ts="$(date +%s)"
      prim="$(kc -n "${ns}" get mariadb "${inst}" -o jsonpath='{.status.currentPrimaryPodIndex}' 2>/dev/null || echo x)"
      sec="$(secondary_endpoints "${inst}")"
      pods="$(kc -n "${ns}" get pods -l "app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=${inst}" \
        -o jsonpath='{range .items[*]}{.metadata.name}:{.metadata.uid}:{.status.phase}{" "}{end}' 2>/dev/null || true)"
      echo "${ts} prim=${prim} sec=${sec} pods=${pods}"
      sleep 1
    done
  ) >>"${log}" 2>/dev/null &
  SAMPLER_PID=$!
}

stop_sampler() {
  [[ -n "${SAMPLER_PID}" ]] && kill "${SAMPLER_PID}" 2>/dev/null || true
  wait "${SAMPLER_PID}" 2>/dev/null || true
  SAMPLER_PID=""
}

# The old primary's pod is gone at time T; the role moved at time S. The role must move
# before the old primary pod is deleted: S <= T.
check_role_moved_before_pod_deleted() {
  local inst="$1" old="$2" s t
  s="$(awk -v old="${old}" '{
      split($0, a, " "); p = a[2]; sub("prim=", "", p)
      if (p != "" && p != prev && prev != "") { print a[1]; exit }
      prev = p }' "${WORK}/${inst}-samples.log")"
  t="$(awk -v old="${old}" '$0 !~ old":" && seen { print $1; exit }
      index($0, old":") { seen = 1 }' "${WORK}/${inst}-samples.log")"
  [[ -n "${s}" ]] || { echo "the role never moved in the samples"; return 1; }
  if [[ -n "${t}" && "${s}" -gt "${t}" ]]; then
    echo "the old primary pod ${old} was removed at ${t}, before the role moved at ${s}"
    return 1
  fi
}

secondary_always_has_an_endpoint() {
  local inst="$1"
  awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^sec=/) { sub("sec=", "", $i); if ($i + 0 < 1) { bad = 1 } } }
    END { exit bad }' "${WORK}/${inst}-samples.log" || { echo "the secondary Service had no endpoint at some sample"; return 1; }
}

canary_within() {
  local inst="$1" limit="$2" report
  while read -r report; do
    local outage lost failures
    outage="$(jq -r '.longest_write_outage_seconds' <<<"${report}")"
    lost="$(jq -r '.lost_acknowledged_writes' <<<"${report}")"
    failures="$(jq -r '.write_failures' <<<"${report}")"
    echo "  canary $(jq -r .writer <<<"${report}"): longest write outage ${outage}s, failed writes ${failures}, lost ${lost}"
    jq -en --argjson o "${outage}" --argjson l "${limit}" '$o <= $l' >/dev/null ||
      { echo "write outage ${outage}s exceeds ${limit}s"; return 1; }
    [[ "${lost}" == "0" ]] || { echo "${lost} acknowledged writes lost"; return 1; }
  done < <(canary_reports "${inst}")
}

canary_no_failed_writes() {
  local report
  while read -r report; do
    [[ "$(jq -r '.write_failures' <<<"${report}")" == "0" ]] || { echo "writes failed: ${report}"; return 1; }
    [[ "$(jq -r '.lost_acknowledged_writes' <<<"${report}")" == "0" ]] || { echo "lost writes: ${report}"; return 1; }
  done < <(canary_reports "${1}")
}

# drain <node> <timeout-seconds>: the plain drain the platform runs. Output to a file.
drain() {
  local node="$1" timeout="$2"
  kc drain "${node}" --ignore-daemonsets --delete-emptydir-data --timeout="${timeout}s" >"${WORK}/drain-${node}.log" 2>&1
}

wait_ready() {
  local inst="$1" want="$2" deadline=$((SECONDS + 900))
  until [[ "$(kc -n "db-${inst}" get pods -l "app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=${inst}" -o json |
    jq '[.items[] | select(.status.phase == "Running" and ([.status.containerStatuses[]? | .ready] | all))] | length')" == "${want}" ]] &&
    [[ "$(kc -n "db-${inst}" get mariadb "${inst}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]]; do
    ((SECONDS < deadline)) || { echo "${inst} did not return to ${want} ready pods"; return 1; }
    sleep 5
  done
}

# guard_metric <name>: the largest value of a drain-guard series over its replicas. Only the
# leader runs the reconcile loop that sets drain_guard_blocked_instances, so a follower reports 0.
guard_metric() {
  local pod port value best=""
  for pod in $(kc -n dbaas-system get pods -l app.kubernetes.io/name=drain-guard -o jsonpath='{.items[*].metadata.name}'); do
    port=$((28000 + RANDOM % 1000))
    kc -n dbaas-system port-forward "pod/${pod}" "${port}:8080" >/dev/null 2>&1 &
    local pf=$!
    for _ in $(seq 1 50); do curl -fsS -o /dev/null "http://127.0.0.1:${port}/metrics" 2>/dev/null && break; sleep 0.2; done
    value="$(curl -fsS "http://127.0.0.1:${port}/metrics" 2>/dev/null | awk -v m="$1" '$1 == m { print $2; exit }')"
    kill "${pf}" 2>/dev/null || true
    if [[ -n "${value}" ]] && { [[ -z "${best}" ]] || awk -v a="${value}" -v b="${best}" 'BEGIN { exit !(a > b) }'; }; then best="${value}"; fi
  done
  printf '%s\n' "${best:-0}"
}

# eviction <inst> <pod> [dry-run]: asks the eviction API for one pod. Prints its answer.
eviction() {
  local inst="$1" pod="$2" dry="${3:-}" ns="db-$1" query=""
  [[ -n "${dry}" ]] && query="?dryRun=All"
  jq -n --arg n "${pod}" --arg ns "${ns}" '{apiVersion: "policy/v1", kind: "Eviction", metadata: {name: $n, namespace: $ns}}' >"${WORK}/evict.json"
  kc create --raw "/api/v1/namespaces/${ns}/pods/${pod}/eviction${query}" -f "${WORK}/evict.json" 2>&1
}

# ---------------------------------------------------------------- cases

case_a_replica_drained() {
  local inst="$1" node other_pod
  canary_reset "${inst}"
  start_sampler "${inst}"
  node="$(replica_node "${inst}")"
  drain "${node}" 900 || { cat "${WORK}/drain-${node}.log"; return 1; }
  # With one replica away, the other replica's eviction is refused by the budget.
  # The budget reports zero allowed disruptions once the replacement is pending.
  local deadline=$((SECONDS + 120))
  until [[ "$(kc -n "db-${inst}" get pdb "${inst}" -o jsonpath='{.status.disruptionsAllowed}')" == "0" ]]; do
    ((SECONDS < deadline)) || { echo "the budget still allows a disruption with a replica away"; return 1; }
    sleep 2
  done
  # Another replica: Ready, on a node other than the drained one, and not the primary.
  other_pod="$(kc -n "db-${inst}" get pods -l "app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=${inst}" -o json |
    jq -r --arg node "${node}" --arg primary "$(primary_pod "${inst}")" '[.items[] | select(.spec.nodeName != null and .spec.nodeName != $node
      and .metadata.name != $primary and (.status.conditions[]? | select(.type == "Ready" and .status == "True")))
      | .metadata.name] | first // empty')"
  if [[ -n "${other_pod}" ]]; then
    local answer
    answer="$(eviction "${inst}" "${other_pod}" || true)"
    grep -qE 'disruption budget|429|TooManyRequests' <<<"${answer}" ||
      { echo "the second replica's eviction was not refused: ${answer}"; return 1; }
  fi
  kc uncordon "${node}" >/dev/null
  wait_ready "${inst}" 3 || return 1
  stop_sampler
  secondary_always_has_an_endpoint "${inst}" || return 1
  canary_no_failed_writes "${inst}" || return 1
  canary_within "${inst}" "${LIMIT_REPLICA}"
}

case_b_primary_node_drained() {
  local inst="$1" node old
  canary_reset "${inst}"
  start_sampler "${inst}"
  old="$(primary_pod "${inst}")"
  node="$(node_of "${inst}" "${old}")"
  drain "${node}" 900 || { echo "the drain did not finish by itself"; cat "${WORK}/drain-${node}.log"; return 1; }
  stop_sampler
  check_role_moved_before_pod_deleted "${inst}" "${old}" || return 1
  canary_within "${inst}" "${LIMIT_SWITCHOVER}" || return 1
  kc uncordon "${node}" >/dev/null
  wait_ready "${inst}" 3
}

case_c_replica_away_then_primary_drained() {
  local inst="$1" rnode pnode old returned switched
  canary_reset "${inst}"
  start_sampler "${inst}"
  rnode="$(replica_node "${inst}")"
  drain "${rnode}" 900 || { echo "the replica node drain failed"; return 1; }
  old="$(primary_pod "${inst}")"
  pnode="$(node_of "${inst}" "${old}")"
  # With a replica away the operator waits for it before it switches: the primary's drain
  # waits too. The replica comes back, the switch happens, and the drain completes.
  kc drain "${pnode}" --ignore-daemonsets --delete-emptydir-data --timeout=900s >"${WORK}/drain-c.log" 2>&1 &
  DRAIN_PID=$!
  sleep 60
  [[ "$(primary_index "${inst}")" == "${old##*-}" ]] || { echo "the role moved while the replica was still away"; return 1; }
  returned="$(date +%s)"
  kc uncordon "${rnode}" >/dev/null
  wait "${DRAIN_PID}" || { echo "the primary's drain did not finish after the replica returned"; cat "${WORK}/drain-c.log"; return 1; }
  DRAIN_PID=""
  stop_sampler
  switched="$(awk -v old="${old}" '{ split($2, a, "="); if (prev != "" && a[2] != prev) { print $1; exit } prev = a[2] }' "${WORK}/${inst}-samples.log")"
  echo "  role moved at ${switched:-?}, replica returned at ${returned}"
  # The primary never leaves its node while it holds the role.
  check_role_moved_before_pod_deleted "${inst}" "${old}" || return 1
  canary_within "${inst}" "${LIMIT_SWITCHOVER}" || return 1
  kc uncordon "${pnode}" >/dev/null
  wait_ready "${inst}" 3
}

case_d_no_candidate_blocks() {
  local inst="$1" old node n pid blocked
  canary_reset "${inst}"
  old="$(primary_pod "${inst}")"
  node="$(node_of "${inst}" "${old}")"
  for n in $(class_nodes "$(kc -n "db-${inst}" get mariadb "${inst}" -o jsonpath='{.spec.nodeSelector.dbaas\.local/node-class}')"); do
    kc cordon "${n}" >/dev/null
  done
  kc drain "${node}" --ignore-daemonsets --delete-emptydir-data --timeout=600s >"${WORK}/drain-blocked.log" 2>&1 &
  DRAIN_PID=$!
  local deadline=$((SECONDS + 300))
  until blocked="$(guard_metric drain_guard_blocked_instances)" && [[ "${blocked%.*}" -ge 1 ]]; do
    ((SECONDS < deadline)) || { echo "drain_guard_blocked_instances never reached 1 (${blocked:-none})"; return 1; }
    sleep 10
  done
  [[ "$(primary_pod "${inst}")" == "${old}" ]] || { echo "the primary moved although no candidate exists"; return 1; }
  for n in $(class_nodes "$(kc -n "db-${inst}" get mariadb "${inst}" -o jsonpath='{.spec.nodeSelector.dbaas\.local/node-class}')"); do
    kc uncordon "${n}" >/dev/null
  done
  wait "${DRAIN_PID}" || { echo "the drain did not complete after the nodes came back"; cat "${WORK}/drain-blocked.log"; return 1; }
  DRAIN_PID=""
  wait_ready "${inst}" 3
}

# guard_serving: the drain-guard Service has ready endpoints. The guard's webhook is fail-closed,
# so a drain that calls it before a replica serves fails with a dial error, not a refusal.
guard_serving() {
  local i ready
  for _ in $(seq 1 60); do
    ready="$(kc -n dbaas-system get endpointslices -l kubernetes.io/service-name=drain-guard -o json |
      jq '[.items[].endpoints[]? | select(.conditions.ready == true)] | length')"
    if [[ "${ready}" -ge 1 ]]; then
      sleep 10 # kube-proxy programs the rules after the endpoints
      return 0
    fi
    sleep 2
  done
  return 1
}

case_e_guard_down_refuses_drains() {
  local inst="$1" node before after
  canary_reset "${inst}"
  node="$(node_of "${inst}" "$(primary_pod "${inst}")")"
  before="$(for p in $(pods_of "${inst}"); do kc -n "db-${inst}" get pod "${p}" -o jsonpath='{.metadata.uid}'; echo; done | sort | tr '\n' ' ')"
  kc -n dbaas-system scale deployment drain-guard --replicas=0 >/dev/null
  if drain "${node}" 120; then
    kc -n dbaas-system scale deployment drain-guard --replicas=2 >/dev/null
    echo "the drain finished with the guard down"
    return 1
  fi
  after="$(for p in $(pods_of "${inst}"); do kc -n "db-${inst}" get pod "${p}" -o jsonpath='{.metadata.uid}'; echo; done | sort | tr '\n' ' ')"
  kc -n dbaas-system scale deployment drain-guard --replicas=2 >/dev/null
  kc -n dbaas-system rollout status deployment drain-guard --timeout=300s >/dev/null
  guard_serving || { echo "the guard's webhook has no ready endpoint"; return 1; }
  [[ "${before}" == "${after}" ]] || { echo "a database pod was deleted while the guard was down"; return 1; }
  drain "${node}" 900 || { echo "a new drain did not finish after the guard came back"; cat "${WORK}/drain-${node}.log"; return 1; }
  kc uncordon "${node}" >/dev/null
  wait_ready "${inst}" 3
}

case_f_dry_run_eviction_of_primary() {
  local inst="$1" old answer
  old="$(primary_pod "${inst}")"
  answer="$(eviction "${inst}" "${old}" dry || true)"
  grep -qE 'holds the primary role|429|TooManyRequests' <<<"${answer}" ||
    { echo "the dry run of the primary's eviction was not refused: ${answer}"; return 1; }
  [[ "$(primary_pod "${inst}")" == "${old}" ]] || { echo "a dry run moved the primary"; return 1; }
}

case_h_image_roll() {
  local inst="$1" image="$2"
  canary_reset "${inst}"
  start_sampler "${inst}"
  helm --kube-context "${CONTEXT}" upgrade "${inst}" "${ROOT}/charts/mariadb-instance" \
    --namespace "db-${inst}" --reuse-values --set-json "images={\"11.8\":\"${image}\"}" --wait=false >/dev/null
  local deadline=$((SECONDS + 1200)) rolled
  until rolled="$(kc -n "db-${inst}" get pods -l "app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=${inst}" \
    -o jsonpath='{range .items[*]}{.spec.containers[?(@.name=="mariadb")].image}{"\n"}{end}' | grep -c -x "${image}")" &&
    [[ "${rolled}" == "3" ]]; do
    ((SECONDS < deadline)) || { echo "the rolling update did not finish (${rolled:-0} of 3 pods on the new image)"; return 1; }
    sleep 10
  done
  wait_ready "${inst}" 3 || return 1
  stop_sampler
  local changes
  changes="$(awk '{ split($2, a, "="); if (prev != "" && a[2] != prev) n++; prev = a[2] } END { print n + 0 }' "${WORK}/${inst}-samples.log")"
  echo "  the primary changed ${changes} time(s) during the roll"
  [[ "${changes}" -le 2 ]] || { echo "the primary changed ${changes} times"; return 1; }
  canary_within "${inst}" "${LIMIT_SWITCHOVER}"
}

case_g_two_primaries_on_one_node() {
  local inst="$1" pair="pair" node pairpod
  instance_up "${pair}" kind-pv2 small 2 >/dev/null
  node="$(node_of "${inst}" "$(primary_pod "${inst}")")"
  pairpod="$(for p in $(pods_of "${pair}"); do [[ "$(node_of "${pair}" "${p}")" == "${node}" ]] && { echo "${p}"; break; }; done)"
  if [[ -z "${pairpod}" ]]; then
    echo "no pod of ${pair} shares ${node}: the nodes of the class are too few for this case"
    instance_down "${pair}"
    return 1
  fi
  "${ROOT}/scripts/switchover.sh" "${pair}" "${pairpod##*-}" >/dev/null
  [[ "$(node_of "${pair}" "$(primary_pod "${pair}")")" == "${node}" ]] || { echo "could not put both primaries on ${node}"; instance_down "${pair}"; return 1; }
  canary_reset "${inst}"
  drain "${node}" 900 || { echo "the drain of the shared node did not finish"; cat "${WORK}/drain-${node}.log"; instance_down "${pair}"; return 1; }
  kc uncordon "${node}" >/dev/null
  [[ "$(node_of "${pair}" "$(primary_pod "${pair}")")" != "${node}" ]] || { echo "${pair}'s primary did not leave ${node}"; instance_down "${pair}"; return 1; }
  canary_within "${inst}" "${LIMIT_SWITCHOVER}" || { instance_down "${pair}"; return 1; }
  instance_down "${pair}"
}

case_i_nvme_primary_loses_its_volume() {
  local inst="$1" old node
  canary_reset "${inst}"
  start_sampler "${inst}"
  old="$(primary_pod "${inst}")"
  node="$(node_of "${inst}" "${old}")"
  drain "${node}" 1800 || { echo "the drain did not finish"; cat "${WORK}/drain-${node}.log"; return 1; }
  # The local disk of the node is gone with the node: delete the claim of the evicted primary.
  kc -n "db-${inst}" delete pvc "storage-${old}" --wait=false >/dev/null
  kc uncordon "${node}" >/dev/null
  # The old primary returns empty, re-seeds from the backup and rejoins by itself.
  local deadline=$((SECONDS + 1200))
  until [[ "$(replica_status_of "${inst}" "${old}")" == "Yes Yes" ]]; do
    ((SECONDS < deadline)) || { echo "${old} did not rejoin on an empty volume"; return 1; }
    sleep 10
  done
  wait_ready "${inst}" 3 || return 1
  stop_sampler
  check_role_moved_before_pod_deleted "${inst}" "${old}" || return 1
  canary_within "${inst}" "${LIMIT_SWITCHOVER}"
}

replica_status_of() { sql "$1" "$2" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E 'Slave_(IO|SQL)_Running:' | awk '{print $2}' | paste -sd' ' -; }

# ---------------------------------------------------------------- run

# settle <inst>: every node schedulable, every pod Ready, the secondary Service has an
# endpoint and the budget allows a disruption. Each case starts from here.
settle() {
  local inst="$1" n
  for n in $(kc get nodes -l 'dbaas.local/node-class' -o jsonpath='{.items[*].metadata.name}'); do
    kc uncordon "${n}" >/dev/null 2>&1 || true
  done
  wait_ready "${inst}" 3 || return 1
  local deadline=$((SECONDS + 600))
  until [[ "$(secondary_endpoints "${inst}")" -ge 1 ]] &&
    [[ "$(kc -n "db-${inst}" get pdb "${inst}" -o jsonpath='{.status.disruptionsAllowed}')" == "1" ]]; do
    ((SECONDS < deadline)) || { echo "${inst} did not settle before the case"; return 1; }
    sleep 5
  done
}

# want <letter>: true when ONLY is unset or lists the case (ONLY="c h"; INSTANCES="alpha" limits the instances).
want() { [[ -z "${ONLY:-}" || " ${ONLY} " == *" $1 "* ]]; }

# A second tag for the same server image: rolling to it changes the pod template only, and
# needs no pull. The tag is made inside each kind node's containerd, from the image the nodes
# already run; loading it from the host would need the host's copy to carry every platform blob.
ROLL_IMAGE="dbaas/mariadb-roll:e2e"
ROLL_READY=0
roll_image_tag() {
  local node tagged=0
  for node in $(docker ps --format '{{.Names}}' | grep "^${KIND_CLUSTER:-dbaas}-worker"); do
    if docker exec "${node}" ctr --namespace=k8s.io images ls -q 2>/dev/null | grep -qx 'docker.io/library/mariadb:11.8.9'; then
      docker exec "${node}" ctr --namespace=k8s.io images tag --force \
        docker.io/library/mariadb:11.8.9 "docker.io/${ROLL_IMAGE}" >/dev/null 2>&1 && tagged=$((tagged + 1))
    fi
  done
  ((tagged > 0))
}
if roll_image_tag; then
  ROLL_READY=1
fi

for inst in ${INSTANCES:-alpha beta}; do
  log "drain acceptance for ${inst} ($(kc -n "db-${inst}" get mariadb "${inst}" -o jsonpath='{.spec.nodeSelector.dbaas\.local/node-class}'))"
  if want a; then
    settle "${inst}" || { FAILURES=$((FAILURES + 1)); echo "  FAIL  [${inst}] settle"; }
    check "[${inst}] a: a replica's node drains with no failed write; the secondary keeps an endpoint" case_a_replica_drained "${inst}"
  fi
  if want b; then
    settle "${inst}" || { FAILURES=$((FAILURES + 1)); echo "  FAIL  [${inst}] settle"; }
    check "[${inst}] b: the primary's node drains by itself; the role moves before the pod goes; outage within the limit" case_b_primary_node_drained "${inst}"
  fi
  if want c; then
    settle "${inst}" || { FAILURES=$((FAILURES + 1)); echo "  FAIL  [${inst}] settle"; }
    check "[${inst}] c: a replica away, then the primary's node drains; the primary is never evicted while it holds the role" case_c_replica_away_then_primary_drained "${inst}"
  fi
  if want d; then
    settle "${inst}" || { FAILURES=$((FAILURES + 1)); echo "  FAIL  [${inst}] settle"; }
    check "[${inst}] d: no candidate: the drain blocks, nothing switches, the blocked gauge is 1; it completes after uncordon" case_d_no_candidate_blocks "${inst}"
  fi
  if want e; then
    settle "${inst}" || { FAILURES=$((FAILURES + 1)); echo "  FAIL  [${inst}] settle"; }
    check "[${inst}] e: with the guard down, a drain fails and no database pod is deleted; after it returns the drain completes" case_e_guard_down_refuses_drains "${inst}"
  fi
  if want f; then
    settle "${inst}" || { FAILURES=$((FAILURES + 1)); echo "  FAIL  [${inst}] settle"; }
    check "[${inst}] f: a dry run of the primary's eviction is refused and moves nothing" case_f_dry_run_eviction_of_primary "${inst}"
  fi
  if [[ "${ROLL_READY}" == "1" ]]; then
    if want h; then
      settle "${inst}" || { FAILURES=$((FAILURES + 1)); echo "  FAIL  [${inst}] settle"; }
      check "[${inst}] h: a rolling image change: replicas first, one planned switchover, then the old primary" case_h_image_roll "${inst}" "${ROLL_IMAGE}"
    fi
  fi
  if [[ "${inst}" == "beta" ]]; then
    if want i; then
      settle "${inst}" || { FAILURES=$((FAILURES + 1)); echo "  FAIL  [${inst}] settle"; }
      check "[${inst}] i: the primary's node drains and its volume is discarded; the old primary re-seeds and rejoins by itself" case_i_nvme_primary_loses_its_volume "${inst}"
    fi
  fi
done

if want g; then
  check "g: two primaries on one node both move when the node drains" case_g_two_primaries_on_one_node alpha
fi

summary
