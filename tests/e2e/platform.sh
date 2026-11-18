#!/usr/bin/env bash
# Phase 1 acceptance (PLAN.md phase 1). Engine-neutral: it checks the platform
# every database instance depends on, not any database.
#
# Needs a running cluster from `make kind-up platform-up`.

set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "platform acceptance for ENV=${ENV} (context ${CONTEXT})"

# ---------------------------------------------------------------- nodes

node_labels() { kc get nodes -o json; }

check_node_classes() {
  local nodes="$1" class tier zones count
  # Every node class in platform.yaml must have one database node per zone, with
  # the class and tier labels and the database taint.
  while IFS=$'\t' read -r class tier; do
    zones="$(jq -r --arg c "${class}" '.items[] | select(.metadata.labels["dbaas.local/node-class"] == $c) | .metadata.labels["topology.kubernetes.io/zone"]' <<<"${nodes}" | sort | tr '\n' ' ')"
    count="$(jq -r --arg c "${class}" '[.items[] | select(.metadata.labels["dbaas.local/node-class"] == $c)] | length' <<<"${nodes}")"
    [[ "${zones}" == "zone-a zone-b zone-c " ]] || { echo "class ${class}: zones '${zones}'"; return 1; }
    [[ "${count}" == "3" ]] || { echo "class ${class}: ${count} nodes, want 3"; return 1; }
    jq -e --arg c "${class}" --arg t "${tier}" '
      [.items[] | select(.metadata.labels["dbaas.local/node-class"] == $c)]
      | all(.metadata.labels["dbaas.local/storage-tier"] == $t
            and (.spec.taints // [] | any(.key == "workload" and .value == "database" and .effect == "NoSchedule")))
    ' <<<"${nodes}" >/dev/null || { echo "class ${class}: wrong tier label or missing taint"; return 1; }
  done < <(yq -r '.nodeClasses | to_entries[] | [.key, .value.storageTier] | @tsv' "${PLATFORM_FILE}")
}

check_system_nodes() {
  local nodes="$1"
  jq -e '[.items[] | select(.metadata.labels["pool"] == "system")] | length == 2' <<<"${nodes}" >/dev/null ||
    { echo "expected 2 nodes labelled pool=system"; return 1; }
}

check_no_platform_pod_on_database_nodes() {
  local nodes pods
  nodes="$(node_labels)"
  pods="$(kc get pods -A -o json)"
  jq -e --argjson nodes "${nodes}" '
    [.items[] | select(.metadata.namespace | IN("cert-manager", "monitoring", "dbaas-system", "object-store"))
     | . as $p | select($nodes.items[] | select(.metadata.name == $p.spec.nodeName and .metadata.labels["workload"] == "database"))]
    | length == 0
  ' <<<"${pods}" >/dev/null || { echo "a platform pod runs on a database node"; return 1; }
}

# ---------------------------------------------------------------- storage

check_storage_classes() {
  local name tier
  while IFS=$'\t' read -r name tier; do
    kc get storageclass "${name}" -o json | jq -e --arg t "${tier}" '
      .volumeBindingMode == "WaitForFirstConsumer"
      and .reclaimPolicy == "Retain"
      and .allowVolumeExpansion == true
      and .metadata.labels["dbaas.local/storage-tier"] == $t
    ' >/dev/null || { echo "storage class ${name} does not match the plan"; return 1; }
  done < <(yq -r '.storageClasses | to_entries[] | [.key, .value.tier] | @tsv' "${PLATFORM_FILE}")
}

check_node_class_storage_defaults() {
  # Every node class must point at a storage class of its own tier. The chart
  # enforces this at render time; this checks the rendered cluster too.
  local class sc
  while IFS=$'\t' read -r class sc; do
    kc get storageclass "${sc}" >/dev/null || { echo "node class ${class}: storage class ${sc} missing"; return 1; }
  done < <(yq -r '.nodeClasses | to_entries[] | [.key, .value.storageClassName] | @tsv' "${PLATFORM_FILE}")
}

# ---------------------------------------------------------------- platform objects

check_priority_classes() {
  kc get priorityclass dbaas-database -o json | jq -e '.value == 1000000 and .globalDefault != true' >/dev/null &&
    kc get priorityclass dbaas-platform -o json | jq -e '.value == 900000 and .globalDefault != true' >/dev/null
}

check_namespaces() {
  kc get namespace dbaas-system -o json | jq -e '.metadata.labels["pod-security.kubernetes.io/enforce"] == "baseline"' >/dev/null &&
    kc get namespace monitoring -o json | jq -e '.metadata.labels["pod-security.kubernetes.io/enforce"] == "privileged"' >/dev/null
}

# platform_settled: every pod in the platform namespaces is Running with all
# containers ready, or Succeeded. Returns non-zero while anything still starts.
platform_settled() {
  local ns
  for ns in cert-manager monitoring object-store; do
    kc get pods -n "${ns}" -o json | jq -e '
      [.items[] | select(.status.phase != "Succeeded")
        | select((.status.phase != "Running") or ([.status.containerStatuses[]? | .ready] | all | not))]
      | length == 0' >/dev/null || return 1
  done
}

# wait_for_platform: a fresh install is still starting when the suite begins.
# Checks run on a settled platform, so startup is not mistaken for a fault.
wait_for_platform() {
  local deadline=$((SECONDS + 300))
  until platform_settled; do
    ((SECONDS < deadline)) || { echo "platform did not settle within 5 minutes"; return 1; }
    sleep 5
  done
}

check_pods_ready() {
  # Every pod in the platform namespaces is Running with all containers ready, or
  # Succeeded (the bucket Job). Nothing is pending or crash-looping.
  local ns bad
  for ns in cert-manager monitoring object-store; do
    bad="$(kc get pods -n "${ns}" -o json | jq -r '
      .items[] | select(.status.phase != "Succeeded")
      | select((.status.phase != "Running") or ([.status.containerStatuses[]? | .ready] | all | not))
      | .metadata.name')"
    [[ -z "${bad}" ]] || { echo "not ready in ${ns}: ${bad}"; return 1; }
  done
}

check_platform_pods_use_priority() {
  local ns bad
  for ns in cert-manager monitoring object-store; do
    bad="$(kc get pods -n "${ns}" -o json | jq -r '.items[] | select(.spec.priorityClassName != "dbaas-platform") | .metadata.name')"
    [[ -z "${bad}" ]] || { echo "pods without dbaas-platform priority in ${ns}: ${bad}"; return 1; }
  done
}

check_bucket() {
  local bucket output
  bucket="$(platform_value '.testObjectStore.bucket')"
  output="$(kc run bucket-check --rm -i --restart=Never --quiet --image="$(pin .platform.testObjectStore.awsCliImage)" \
    --overrides="$(jq -nc --arg bucket "${bucket}" '{
      spec: {
        nodeSelector: {pool: "system"},
        priorityClassName: "dbaas-platform",
        containers: [{
          name: "bucket-check", image: "'"$(pin .platform.testObjectStore.awsCliImage)"'",
          command: ["sh", "-c", ("aws --endpoint-url http://test-object-store.object-store.svc:8333 s3api head-bucket --bucket " + $bucket + " && echo bucket-present")],
          env: [
            {name: "AWS_ACCESS_KEY_ID", valueFrom: {secretKeyRef: {name: "test-object-store-credentials", key: "access-key-id"}}},
            {name: "AWS_SECRET_ACCESS_KEY", valueFrom: {secretKeyRef: {name: "test-object-store-credentials", key: "secret-access-key"}}},
            {name: "AWS_DEFAULT_REGION", value: "us-east-1"}
          ]
        }]
      }
    }')" \
    --namespace=object-store -- true 2>&1)" || true
  grep -q bucket-present <<<"${output}" || { echo "bucket ${bucket} is not reachable:"; echo "${output}" | tail -3; return 1; }
}

# ---------------------------------------------------------------- monitoring

check_prometheus_targets() {
  # Prometheus needs a scrape cycle or two after it starts, so poll for up to
  # three minutes for every active target to be up, rather than sampling once.
  local release port pf_pid targets down deadline
  release="$(platform_value '.monitoring.prometheusRelease')"
  port=19090
  kc -n monitoring port-forward "svc/${release}-prometheus" "${port}:9090" >/dev/null 2>&1 &
  pf_pid=$!
  # shellcheck disable=SC2064
  trap "kill ${pf_pid} 2>/dev/null || true" RETURN
  for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:${port}/-/ready" >/dev/null 2>&1 && break
    sleep 1
  done
  deadline=$((SECONDS + 180))
  while :; do
    targets="$(curl -fsS "http://127.0.0.1:${port}/api/v1/targets?state=active" || echo '{}')"
    down="$(jq -r '.data.activeTargets[]? | select(.health != "up") | "\(.labels.job)/\(.scrapeUrl): \(.lastError)"' <<<"${targets}")"
    if jq -e '.data.activeTargets | length > 0' <<<"${targets}" >/dev/null && [[ -z "${down}" ]]; then
      return 0
    fi
    ((SECONDS < deadline)) || break
    sleep 10
  done
  jq -e '.data.activeTargets | length > 0' <<<"${targets}" >/dev/null || { echo "Prometheus has no targets"; return 1; }
  echo "targets not up after 3 minutes:"
  echo "${down}"
  return 1
}

check_grafana() {
  local release port pf_pid health
  release="$(platform_value '.monitoring.prometheusRelease')"
  port=13000
  kc -n monitoring port-forward "svc/${release}-grafana" "${port}:80" >/dev/null 2>&1 &
  pf_pid=$!
  # shellcheck disable=SC2064
  trap "kill ${pf_pid} 2>/dev/null || true" RETURN
  for _ in $(seq 1 30); do
    health="$(curl -fsS "http://127.0.0.1:${port}/api/health" 2>/dev/null || true)"
    [[ -n "${health}" ]] && break
    sleep 1
  done
  jq -e '.database == "ok"' <<<"${health:-"{}"}" >/dev/null || { echo "Grafana health: ${health:-no answer}"; return 1; }
}

# ---------------------------------------------------------------- idempotency

# Declared state of every object the platform owns: spec, labels and annotations,
# and generation. Runtime status, resourceVersion and managedFields are excluded,
# because controllers update those on their own schedules.
declared_state() {
  local namespaces="cert-manager monitoring object-store dbaas-system"
  local kinds="deployments statefulsets daemonsets services configmaps serviceaccounts roles rolebindings clusterroles clusterrolebindings jobs ingresses prometheuses alertmanagers servicemonitors podmonitors prometheusrules certificates issuers"
  local ns kind
  for ns in ${namespaces}; do
    for kind in ${kinds}; do
      kc get "${kind}" -n "${ns}" -o json 2>/dev/null | jq -c '.items[]?' || true
    done
  done
  kc get storageclass,priorityclass,namespace -o json | jq -c '.items[]'
  # Secrets are compared by name only: their values are generated once and kept.
  for ns in ${namespaces}; do
    kc get secrets -n "${ns}" -o json | jq -c '.items[] | select(.type != "helm.sh/release.v1") | {kind:"Secret", ns: .metadata.namespace, name: .metadata.name}'
  done
}

normalise() {
  jq -c '{
    kind, namespace: .metadata.namespace, name: .metadata.name,
    labels: .metadata.labels, annotations: ((.metadata.annotations // {}) | with_entries(select(.key | startswith("meta.helm.sh") | not))),
    generation: .metadata.generation, spec: .spec, data: .data, rules: .rules, subjects: .subjects, roleRef: .roleRef
  } | del(.. | nulls)' | sort
}

check_second_run_changes_nothing() {
  local before="${ROOT}/.cache/platform-state-before.json"
  local after="${ROOT}/.cache/platform-state-after.json"
  declared_state | normalise >"${before}"
  ENV="${ENV}" "${ROOT}/hack/platform-up.sh" >"${ROOT}/.cache/platform-second-run.log" 2>&1 || {
    echo "second platform-up failed; see .cache/platform-second-run.log"
    return 1
  }
  declared_state | normalise >"${after}"
  if ! cmp -s "${before}" "${after}"; then
    echo "declared state changed on the second run:"
    diff "${before}" "${after}" | cut -c1-300 | head -40
    return 1
  fi
}

# ---------------------------------------------------------------- run

wait_for_platform || { echo "ERROR: platform not settled; see the pod list above"; kc get pods -A | grep -vE "Running|Completed" | head -20; exit 1; }

NODES="$(node_labels)"
check "database nodes match the node-class catalogue (labels and taints)" check_node_classes "${NODES}"
check "system nodes are labelled pool=system (two of them)" check_system_nodes "${NODES}"
check "no platform pod runs on a database node" check_no_platform_pod_on_database_nodes
check "storage classes match platform.yaml (WaitForFirstConsumer, Retain, expandable)" check_storage_classes
check "every node class points at an existing storage class" check_node_class_storage_defaults
check "priority classes dbaas-database and dbaas-platform exist and are not the default" check_priority_classes
check "namespaces carry their pod security levels" check_namespaces
check "every platform pod is Running and ready (or completed, for the bucket job)" check_pods_ready
check "every platform pod uses the dbaas-platform priority class" check_platform_pods_use_priority
check "the test bucket exists in the object store" check_bucket
check "Prometheus has targets, and every active target is up" check_prometheus_targets
check "Grafana answers /api/health with database ok" check_grafana
check "a second platform-up changes no declared state" check_second_run_changes_nothing

summary
