#!/usr/bin/env bash
# Phase 3 acceptance (PLAN.md phase 3, e2e/anti-affinity): no two pods of one
# instance share a node, the pods spread across zones, and an instance that needs
# more nodes than its node class has stays Pending instead of doubling up.
#
# Engine-specific: ENGINE=mariadb only.

set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${ENGINE}" != "mariadb" ]]; then
  log "anti-affinity suite skipped for ENGINE=${ENGINE}"
  exit 0
fi

NAME=spread
NS="db-${NAME}"
CLASS_NODES=3   # the kind-pv2 node class has one node per zone

# Five pods (replicas 4) on three nodes: three fit, two cannot be placed.
# The operator refuses to scale out a replication topology without a datasource
# for the new replicas (replication.replica.bootstrapFrom, phase 5), so the extra
# pods are created by the initial bootstrap instead.
log "anti-affinity acceptance: instance ${NAME} on kind-pv2, five pods on ${CLASS_NODES} nodes"
trap 'instance_down "${NAME}"' EXIT
values="$(instance_values "${NAME}" kind-pv2 small 4)"
helm --kube-context "${CONTEXT}" upgrade --install "ns-${NAME}" "${ROOT}/charts/db-namespace" \
  --set "name=${NAME}" --set "engine=mariadb" >/dev/null
"${ROOT}/scripts/ensure-secret.sh" "${CONTEXT}" "${NS}" "${NAME}-orders-app-credentials" password >/dev/null
helm --kube-context "${CONTEXT}" upgrade --install "${NAME}" "${ROOT}/charts/mariadb-instance" \
  --namespace "${NS}" --values "${values}" --wait=false >/dev/null 2>&1

pods_json() { kc -n "${NS}" get pods -l "app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=${NAME}" -o json; }
running_json() { pods_json | jq '[.items[] | select(.status.phase == "Running" and ([.status.containerStatuses[]? | .ready] | all))]'; }

# Wait for the pods that fit to be running, and for the extra pod to be Pending.
deadline=$((SECONDS + 900))
until [[ "$(running_json | jq 'length')" == "${CLASS_NODES}" ]] &&
  [[ "$(pods_json | jq '[.items[] | select(.status.phase == "Pending")] | length')" -ge 1 ]]; do
  ((SECONDS < deadline)) || { echo "instance did not settle: running $(running_json | jq 'length'), pending $(pods_json | jq '[.items[] | select(.status.phase == "Pending")] | length')"; exit 1; }
  sleep 10
done

check_one_pod_per_node() {
  local nodes unique
  nodes="$(running_json | jq -r '.[] | .spec.nodeName')"
  unique="$(sort -u <<<"${nodes}" | wc -l | tr -d ' ')"
  [[ "$(wc -l <<<"${nodes}" | tr -d ' ')" == "${unique}" ]] || { echo "two running pods share a node: ${nodes}"; return 1; }
}

check_pods_spread_across_zones_and_class() {
  local node zones
  zones="$(for node in $(running_json | jq -r '.[].spec.nodeName'); do
    kc get node "${node}" -o json | jq -r '.metadata.labels as $l |
      if $l["dbaas.local/node-class"] == "kind-pv2" then $l["topology.kubernetes.io/zone"] else "WRONG-CLASS" end'
  done | sort)"
  grep -q WRONG-CLASS <<<"${zones}" && { echo "a pod landed outside its node class"; return 1; }
  [[ "$(sort -u <<<"${zones}" | wc -l | tr -d ' ')" == "3" ]] || { echo "pods are not spread over three zones: ${zones}"; return 1; }
}

check_extra_pod_pending_with_anti_affinity_reason() {
  kc -n "${NS}" get events --field-selector reason=FailedScheduling -o json |
    jq -e '[.items[].message] | any(test("anti-affinity"))' >/dev/null ||
    { echo "no FailedScheduling event mentions anti-affinity"; return 1; }
}

check_scale_in_removes_only_the_pending_pod() {
  local before after
  before="$(running_json | jq -r '[.[] | .metadata.uid] | sort | join(" ")')"
  helm --kube-context "${CONTEXT}" upgrade "${NAME}" "${ROOT}/charts/mariadb-instance" \
    --namespace "${NS}" --reuse-values --set replicas=2 --wait=false >/dev/null 2>&1
  local deadline=$((SECONDS + 600))
  until [[ "$(pods_json | jq '.items | length')" == "3" ]]; do
    ((SECONDS < deadline)) || { echo "the pending pod was not removed"; return 1; }
    sleep 5
  done
  after="$(running_json | jq -r '[.[] | .metadata.uid] | sort | join(" ")')"
  [[ -n "${before}" && "${before}" == "${after}" ]] || { echo "a running pod was replaced during scale-in"; return 1; }
}

check "one pod per node within the instance" check_one_pod_per_node
check "pods spread over three zones, all in the node class" check_pods_spread_across_zones_and_class
check "the pod beyond the node class's nodes stays Pending, with an anti-affinity reason" check_extra_pod_pending_with_anti_affinity_reason
check "scaling in removes only the pending pod; the running pods are untouched" check_scale_in_removes_only_the_pending_pod

summary
