#!/usr/bin/env bash
# Phase 4 acceptance (PLAN.md phase 4, e2e/multi-instance). Instances are files:
# alpha (premium-ssd-v2) and beta (local-nvme) live in environments/kind/instances/.
#
# Checks: both instances pass the topology suite; within each instance the nodes
# differ; beta stays on its node class and tier; the admission policy refuses a
# hand-written MariaDB; deleting a file leaves its instance in place; the two-step
# removal deletes it; a file with replicas: 0 fails validation.
#
# Engine-specific: ENGINE=mariadb only. Runs against the kind environment.

set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${ENGINE}" != "mariadb" ]]; then
  log "multi-instance suite skipped for ENGINE=${ENGINE}"
  exit 0
fi

INSTANCES="${ROOT}/environments/${ENV}/instances"
WORK="${CACHE}/e2e/multi-instance"
rm -rf "${WORK}"
mkdir -p "${WORK}"

log "multi-instance acceptance (ENV=${ENV}, context ${CONTEXT})"
"${ROOT}/hack/instances-up.sh" >"${WORK}/sync.log" 2>&1 || { echo "instances-up failed; see ${WORK}/sync.log"; exit 1; }

wait_ready() {
  kc -n "db-$1" wait "mariadb/$1" --for=condition=Ready --timeout=900s >/dev/null
}
wait_ready alpha
wait_ready beta

pods_of() { kc -n "db-$1" get pods -l "app.kubernetes.io/instance=$1" -o json; }

check_both_pass_topology() {
  TOPOLOGY_INSTANCE=alpha TOPOLOGY_INSTALL=0 TOPOLOGY_DATABASE=orders TOPOLOGY_OWNER=orders_app \
    ENGINE=mariadb ENV="${ENV}" "${ROOT}/tests/e2e/topology.sh" >"${WORK}/topology-alpha.log" 2>&1 ||
    { echo "alpha failed topology; see ${WORK}/topology-alpha.log"; return 1; }
  TOPOLOGY_INSTANCE=beta TOPOLOGY_INSTALL=0 TOPOLOGY_DATABASE=ledger TOPOLOGY_OWNER=ledger_app \
    ENGINE=mariadb ENV="${ENV}" "${ROOT}/tests/e2e/topology.sh" >"${WORK}/topology-beta.log" 2>&1 ||
    { echo "beta failed topology; see ${WORK}/topology-beta.log"; return 1; }
}

check_nodes_differ_within_each_instance() {
  local name nodes unique
  for name in alpha beta; do
    nodes="$(pods_of "${name}" | jq -r '.items[].spec.nodeName')"
    unique="$(sort -u <<<"${nodes}" | wc -l | tr -d ' ')"
    [[ "$(wc -l <<<"${nodes}" | tr -d ' ')" == "${unique}" ]] || { echo "${name}: two pods share a node"; return 1; }
  done
}

check_nvme_instance_stays_on_its_class() {
  local node klass
  for node in $(pods_of beta | jq -r '.items[].spec.nodeName'); do
    klass="$(kc get node "${node}" -o jsonpath='{.metadata.labels.dbaas\.local/node-class}')"
    [[ "${klass}" == "kind-nvme" ]] || { echo "beta pod on ${node} is on class ${klass}, want kind-nvme"; return 1; }
  done
  kc -n db-beta get pvc -o json | jq -e '[.items[].spec.storageClassName] | all(. == "db-nvme")' >/dev/null ||
    { echo "beta does not use the db-nvme storage class"; return 1; }
}

check_admission_refuses_hand_written_mariadb() {
  # One pod, no replication, no anti-affinity: all three guarantees are violated.
  local output
  output="$(kc -n db-alpha create --dry-run=server -f - 2>&1 <<'YAML' || true
apiVersion: k8s.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: handmade
spec:
  replicas: 1
  storage:
    size: 1Gi
YAML
)"
  grep -q "dbaas-mariadb-guarantees" <<<"${output}" || { echo "admission did not refuse the hand-written MariaDB: ${output}"; return 1; }
  grep -q "replication" <<<"${output}" || { echo "the refusal does not name the missing replication"; return 1; }
}

check_deleted_file_leaves_instance_in_place() {
  # Remove alpha from the directory (in a copy) and sync. Alpha must remain: helmfile
  # never removes a release it no longer sees. Beta must not change.
  local removed="${WORK}/removed" before_beta after_beta
  mkdir -p "${removed}"
  cp "${INSTANCES}/beta.yaml" "${removed}/"
  before_beta="$(pods_of beta | jq -r '[.items[].metadata.uid] | sort | join(" ")')"
  INSTANCES_DIR="${removed}" ENV="${ENV}" "${ROOT}/hack/instances-up.sh" >"${WORK}/removed-sync.log" 2>&1 ||
    { echo "sync without alpha failed; see ${WORK}/removed-sync.log"; return 1; }
  kc -n db-alpha get mariadb alpha >/dev/null || { echo "alpha's MariaDB resource was removed"; return 1; }
  [[ "$(kc -n db-alpha get pvc --no-headers | wc -l | tr -d ' ')" -ge 3 ]] || { echo "alpha's volumes were removed"; return 1; }
  kc -n db-alpha get mariadb alpha -o json | jq -e '.metadata.annotations["helm.sh/resource-policy"] == "keep"' >/dev/null ||
    { echo "alpha has no deletion protection annotation"; return 1; }
  after_beta="$(pods_of beta | jq -r '[.items[].metadata.uid] | sort | join(" ")')"
  [[ "${before_beta}" == "${after_beta}" ]] || { echo "beta changed during the sync"; return 1; }
}

check_two_step_removal_deletes_instance() {
  # Step two. The file must be absent from the directory the script reads.
  local removed="${WORK}/removed"
  INSTANCES_DIR="${removed}" ENV="${ENV}" "${ROOT}/scripts/instance-remove.sh" alpha >"${WORK}/remove.log" 2>&1 ||
    { echo "removal failed; see ${WORK}/remove.log"; return 1; }
  local deadline=$((SECONDS + 300))
  until ! kc get namespace db-alpha >/dev/null 2>&1; do
    ((SECONDS < deadline)) || { echo "namespace db-alpha still exists"; return 1; }
    sleep 5
  done
}

check_removal_refused_while_file_exists() {
  if INSTANCES_DIR="${INSTANCES}" ENV="${ENV}" "${ROOT}/scripts/instance-remove.sh" beta >/dev/null 2>&1; then
    echo "removal ran while beta's file still exists"
    return 1
  fi
  kc -n db-beta get mariadb beta >/dev/null || { echo "beta was touched by a refused removal"; return 1; }
}

check_invalid_file_fails_lint() {
  local bad="${WORK}/replicas-zero.yaml"
  cat >"${bad}" <<'YAML'
name: zero
engine: mariadb
size: small
replicas: 0
nodeClass: kind-pv2
YAML
  if "${ROOT}/hack/lint-instances.sh" "${bad}" >/dev/null 2>&1; then
    echo "a file with replicas: 0 passed validation"
    return 1
  fi
}

check "alpha and beta each pass the topology suite" check_both_pass_topology
check "within each instance, no two pods share a node" check_nodes_differ_within_each_instance
check "beta stays on its node class and uses the local-nvme storage class" check_nvme_instance_stays_on_its_class
check "admission refuses a hand-written MariaDB in a managed namespace" check_admission_refuses_hand_written_mariadb
check "deleting a file leaves its instance, volumes and beta untouched" check_deleted_file_leaves_instance_in_place
check "the two-step removal deletes the instance" check_two_step_removal_deletes_instance
check "removal refuses to run while the file still exists" check_removal_refused_while_file_exists
check "a file with replicas: 0 fails validation" check_invalid_file_fails_lint

# Put alpha back: the environment is expected to hold both instances afterwards.
"${ROOT}/hack/instances-up.sh" >"${WORK}/restore.log" 2>&1 || true
summary
