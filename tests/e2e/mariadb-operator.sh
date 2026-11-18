#!/usr/bin/env bash
# Phase 2 acceptance (PLAN.md phase 2): the MariaDB operator is highly available,
# its webhook answers, and losing the leader does not stop it working.
#
# Engine-specific: it only applies to ENGINE=mariadb, and is skipped otherwise.
# Needs a running cluster from `make kind-up platform-up`.

set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${ENGINE}" != "mariadb" ]]; then
  log "mariadb-operator acceptance skipped for ENGINE=${ENGINE}"
  exit 0
fi

NS=mariadb-system
COMPONENTS="mariadb-operator mariadb-operator-webhook mariadb-operator-cert-controller"
VALID_MANIFEST="${ROOT}/hack/testdata/manifests/valid/mariadb-premium-ssd-v2.yaml"

log "mariadb-operator acceptance (context ${CONTEXT})"

# dry_run_mariadb <manifest>: server-side dry run in namespace default. Goes
# through the operator's admission webhook, and writes nothing.
dry_run_mariadb() {
  yq '.metadata.namespace = "default"' "$1" | kc create --dry-run=server -f - -o name >/dev/null
}

check_crds_established() {
  local crd
  for crd in mariadbs physicalbackups pointintimerecoveries databases users grants; do
    kc get crd "${crd}.k8s.mariadb.com" -o json |
      jq -e '.status.conditions[] | select(.type == "Established") | .status == "True"' >/dev/null ||
      { echo "CRD ${crd}.k8s.mariadb.com is not established"; return 1; }
  done
}

check_components_ready_on_distinct_nodes() {
  local deploy ready nodes pods
  for deploy in ${COMPONENTS}; do
    ready="$(kc -n "${NS}" get deployment "${deploy}" -o jsonpath='{.status.readyReplicas}')"
    [[ "${ready:-0}" -ge 2 ]] || { echo "${deploy}: ${ready:-0} ready replicas, want at least 2"; return 1; }
    pods="$(kc -n "${NS}" get pods -l "app.kubernetes.io/name=${deploy}" -o json)"
    nodes="$(jq -r '.items[] | select(.status.phase == "Running") | .spec.nodeName' <<<"${pods}" | sort)"
    [[ "$(echo "${nodes}" | wc -l)" == "$(echo "${nodes}" | sort -u | wc -l)" ]] ||
      { echo "${deploy}: two replicas share a node"; return 1; }
    local node
    for node in $(echo "${nodes}" | sort -u); do
      kc get node "${node}" -o json | jq -e '.metadata.labels["pool"] == "system"' >/dev/null ||
        { echo "${deploy}: replica on ${node}, which is not a system node"; return 1; }
    done
  done
}

check_pdbs() {
  local deploy
  for deploy in ${COMPONENTS}; do
    kc -n "${NS}" get pdb -o json | jq -e --arg d "${deploy}" '
      [.items[] | select(.spec.selector.matchLabels["app.kubernetes.io/name"] == $d and .spec.maxUnavailable == 1)] | length == 1
    ' >/dev/null || { echo "no PodDisruptionBudget with maxUnavailable 1 for ${deploy}"; return 1; }
  done
}

check_webhook_accepts_valid_mariadb() {
  dry_run_mariadb "${VALID_MANIFEST}"
}

check_webhook_rejects_invalid_mariadb() {
  # An invalid spec must be refused by the webhook, not silently accepted.
  local bad="${CACHE}/invalid-mariadb.yaml"
  mkdir -p "${CACHE}"
  cat >"${bad}" <<'YAML'
apiVersion: k8s.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: rejected
spec:
  replicas: 0
YAML
  if dry_run_mariadb "${bad}" 2>/dev/null; then
    echo "webhook accepted a MariaDB with replicas: 0"
    return 1
  fi
}

# lease_holder_pod <lease>: the pod named in a lease's holderIdentity. controller-runtime
# writes "<pod name>_<uuid>".
lease_holder_pod() {
  kc -n "${NS}" get lease "$1" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null | sed 's/_.*//'
}

check_leader_loss_recovers_within_30s() {
  # Find the controller's lease: the one whose holder is a mariadb-operator pod
  # (not a webhook or cert-controller pod).
  local lease holder start elapsed new_holder
  lease=""
  for candidate in $(kc -n "${NS}" get lease -o jsonpath='{.items[*].metadata.name}'); do
    holder="$(lease_holder_pod "${candidate}")"
    if [[ "${holder}" == mariadb-operator-* && "${holder}" != mariadb-operator-webhook-* && "${holder}" != mariadb-operator-cert-controller-* ]]; then
      lease="${candidate}"
      break
    fi
  done
  [[ -n "${lease}" ]] || { echo "no leader lease held by a mariadb-operator pod"; return 1; }
  holder="$(lease_holder_pod "${lease}")"
  log "deleting leader ${holder} (lease ${lease})"
  start=${SECONDS}
  kc -n "${NS}" delete pod "${holder}" --wait=false >/dev/null
  while :; do
    new_holder="$(lease_holder_pod "${lease}" || true)"
    if [[ -n "${new_holder}" && "${new_holder}" != "${holder}" ]] && dry_run_mariadb "${VALID_MANIFEST}" 2>/dev/null; then
      elapsed=$((SECONDS - start))
      log "new leader ${new_holder} after ${elapsed}s; webhook answers"
      ((elapsed <= 30)) || { echo "leadership took ${elapsed}s, limit is 30s"; return 1; }
      return 0
    fi
    ((SECONDS - start < 60)) || { echo "no new leader within 60s (holder: ${new_holder:-none})"; return 1; }
    sleep 1
  done
}

check_deployments_return_to_full_strength() {
  local deploy
  for deploy in ${COMPONENTS}; do
    kc -n "${NS}" rollout status deployment "${deploy}" --timeout=180s >/dev/null ||
      { echo "${deploy} did not return to full strength after the leader was lost"; return 1; }
  done
}

check "CRDs for MariaDB resources are established" check_crds_established
check "controller, webhook and cert-controller each have two ready replicas on different system nodes" check_components_ready_on_distinct_nodes
check "each component has a PodDisruptionBudget allowing one disruption" check_pdbs
check "webhook accepts a valid MariaDB (server dry run)" check_webhook_accepts_valid_mariadb
check "webhook rejects an invalid MariaDB (replicas: 0)" check_webhook_rejects_invalid_mariadb
check "losing the leader: a new leader within 30s, and the webhook keeps answering" check_leader_loss_recovers_within_30s
check "all components return to full strength after the leader is lost" check_deployments_return_to_full_strength

summary
