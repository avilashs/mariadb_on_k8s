# shellcheck shell=bash
# Helpers for the e2e suites. Sourced, never executed.
#
# Suites must stay engine-neutral: anything that differs between MariaDB and
# PostgreSQL goes into a helper here, with one branch per engine.

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${E2E_DIR}/../.." && pwd)"
# shellcheck source=hack/lib.sh
source "${ROOT}/hack/lib.sh"

ENV="${ENV:-kind}"
ENGINE="${ENGINE:-mariadb}"
PLATFORM_FILE="${ROOT}/environments/${ENV}/platform.yaml"
CONTEXT="$(yq -r '.kubeContext' "${PLATFORM_FILE}")"

FAILURES=0
CHECKS=0

check() {
  # check <description> <command...>
  local description="$1"
  shift
  CHECKS=$((CHECKS + 1))
  if output="$("$@" 2>&1)"; then
    printf '  ok    %s\n' "${description}"
  else
    FAILURES=$((FAILURES + 1))
    printf '  FAIL  %s\n' "${description}"
    [[ -n "${output}" ]] && printf '%s\n' "${output}" | sed 's/^/          /' | head -20
  fi
}

# kc <kubectl args...>: kubectl against the environment's context.
kc() { kubectl --context "${CONTEXT}" "$@"; }

# platform_value <yq path>: a value from environments/$ENV/platform.yaml.
platform_value() { yq -r "$1" "${PLATFORM_FILE}"; }

summary() {
  printf '\n%d check(s), %d failed\n' "${CHECKS}" "${FAILURES}"
  ((FAILURES == 0))
}

# ------------------------------------------------------------------ instances
# Phase 3 helpers. Phase 4 replaces these with the helmfile instance loop.

# instance_values <name> <node-class> <size> <replicas>: the values file of a
# test instance, with the environment's catalogue copied in as the chart expects.
instance_values() {
  local out="${CACHE}/e2e/$1.yaml"
  mkdir -p "$(dirname "${out}")"
  yq -n "
    .name = \"$1\" |
    .nodeClass = \"$2\" |
    .size = \"$3\" |
    .replicas = $4 |
    .catalogue.storageTiers = load(\"${PLATFORM_FILE}\").storageTiers |
    .catalogue.storageClasses = load(\"${PLATFORM_FILE}\").storageClasses |
    .catalogue.nodeClasses = load(\"${PLATFORM_FILE}\").nodeClasses |
    .catalogue.backupStore = load(\"${PLATFORM_FILE}\").backupStore |
    .access.databases = [{\"name\": \"orders\", \"owner\": \"orders_app\"}]
  " >"${out}"
  printf '%s\n' "${out}"
}

# instance_up <name> <node-class> <size> <replicas>: installs the namespace and
# the instance, and waits until the operator reports the instance Ready.
instance_up() {
  local name="$1" values ns="db-$1"
  values="$(instance_values "$@")"
  helm --kube-context "${CONTEXT}" upgrade --install "ns-$name" "${ROOT}/charts/db-namespace" \
    --set "name=${name}" --set "engine=mariadb" >/dev/null
  # The owner's credentials exist before the User that references them.
  "${ROOT}/scripts/ensure-secret.sh" "${CONTEXT}" "${ns}" "${name}-orders-app-credentials" password >/dev/null
  helm --kube-context "${CONTEXT}" upgrade --install "${name}" "${ROOT}/charts/mariadb-instance" \
    --namespace "${ns}" --values "${values}" --wait=false >/dev/null
  kc -n "${ns}" wait "mariadb/${name}" --for=condition=Ready --timeout=900s >/dev/null
  access_up "${name}" "${values}"
}

# access_up <name> <values-file>: databases, users, then grants, as the helmfile does.
access_up() {
  local name="$1" values="$2" stage out
  [[ "$(yq -r '.access.databases | length' "${values}")" == "0" ]] && return 0
  for stage in users grants; do
    out="${CACHE}/e2e/${name}-${stage}.yaml"
    yq -n ".name = \"${name}\" | .stage = \"${stage}\" | .databases = load(\"${values}\").access.databases" >"${out}"
    helm --kube-context "${CONTEXT}" upgrade --install "${name}-${stage}" "${ROOT}/charts/db-access" \
      --namespace "db-${name}" --values "${out}" >/dev/null
  done
  # Helm does not hold custom resources that have no status yet, so wait explicitly.
  kc -n "db-${name}" wait user --all --for=condition=Ready --timeout=600s >/dev/null
  kc -n "db-${name}" wait grant --all --for=condition=Ready --timeout=600s >/dev/null
}

# instance_down <name>: removes an instance. Deletion protection keeps the MariaDB
# resource through helm uninstall, so it is deleted explicitly first.
instance_down() {
  local name="$1" ns="db-$1"
  kc -n "${ns}" delete mariadb "${name}" --wait=true --timeout=600s >/dev/null 2>&1 || true
  helm --kube-context "${CONTEXT}" uninstall "${name}-grants" --namespace "${ns}" >/dev/null 2>&1 || true
  helm --kube-context "${CONTEXT}" uninstall "${name}-users" --namespace "${ns}" >/dev/null 2>&1 || true
  helm --kube-context "${CONTEXT}" uninstall "${name}" --namespace "${ns}" >/dev/null 2>&1 || true
  helm --kube-context "${CONTEXT}" uninstall "ns-${name}" >/dev/null 2>&1 || true
  kc delete namespace "${ns}" --wait=false >/dev/null 2>&1 || true
}

# sql <instance> <pod> <args...>: runs the mariadb client as root inside a pod, over TLS.
sql() {
  local name="$1" pod="$2"
  shift 2
  local password
  password="$(kc -n "db-${name}" get secret "${name}-root" -o jsonpath='{.data.password}' | base64 -d)"
  kc -n "db-${name}" exec "${pod}" -c mariadb -- mariadb --ssl -uroot -p"${password}" "$@"
}

# s3_objects <prefix>: lists the kind test bucket under a prefix, with the AWS CLI run
# as a Job-free pod in the object store namespace, reading the test credentials.
s3_objects() {
  local prefix="$1" image pod overrides
  image="$(yq -r '.platform.testObjectStore.awsCliImage' "${ROOT}/versions.yaml")"
  pod="s3-list-$(date +%s%N | tail -c 7)"
  overrides="$(jq -n --arg img "${image}" --arg cmd "aws --endpoint-url http://test-object-store.object-store.svc:8333 s3 ls s3://dbaas-test/${prefix} --recursive" '
    {spec: {containers: [{name: "s3", image: $img, command: ["sh", "-c", $cmd],
      env: [
        {name: "AWS_ACCESS_KEY_ID", valueFrom: {secretKeyRef: {name: "test-object-store-credentials", key: "access-key-id"}}},
        {name: "AWS_SECRET_ACCESS_KEY", valueFrom: {secretKeyRef: {name: "test-object-store-credentials", key: "secret-access-key"}}},
        {name: "AWS_DEFAULT_REGION", value: "us-east-1"}]}]}}')"
  kc -n object-store run "${pod}" --rm -i --restart=Never --quiet --image="${image}" --overrides="${overrides}" 2>/dev/null
}

# replica_status <instance> <pod>: prints the replication threads of a replica.
replica_status() {
  sql "$1" "$2" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E 'Slave_(IO|SQL)_Running:' | awk '{print $2}' | paste -sd' ' -
}

# marker_write <instance> <pod> <label>: writes one row to dbaas_marker.markers on the primary.
marker_write() {
  sql "$1" "$2" -e "CREATE DATABASE IF NOT EXISTS dbaas_marker; CREATE TABLE IF NOT EXISTS dbaas_marker.markers (label VARCHAR(64) PRIMARY KEY, written_at DATETIME(6)); INSERT INTO dbaas_marker.markers VALUES ('$3', NOW(6));"
}

# marker_present <instance> <pod> <label>: exits 0 when the row is on that pod.
marker_present() {
  [[ "$(sql "$1" "$2" -N -B -e "SELECT COUNT(*) FROM dbaas_marker.markers WHERE label = '$3'" 2>/dev/null)" == "1" ]]
}

# primary_pod <instance>: the pod the operator reports as primary.
primary_pod() {
  kc -n "db-$1" get mariadb "$1" -o jsonpath='{.status.currentPrimary}'
}

# canary_pods <instance>: the canary pods of an instance.
canary_pods() {
  kc -n "db-$1" get pods -l "app.kubernetes.io/name=db-canary,app.kubernetes.io/instance=$1" \
    -o jsonpath='{.items[*].metadata.name}'
}

# canary_call <namespace> <pod> <method> <path>: one request to a canary through a short
# port-forward (the canary image has no shell, so exec is not an option).
canary_call() {
  local ns="$1" pod="$2" method="$3" path="$4" port pid out
  port=$((18080 + RANDOM % 1000))
  kc -n "${ns}" port-forward "pod/${pod}" "${port}:8080" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do
    curl -fsS -o /dev/null "http://127.0.0.1:${port}/healthz" 2>/dev/null && break
    sleep 0.2
  done
  out="$(curl -fsS -X "${method}" "http://127.0.0.1:${port}${path}")" || out=""
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  printf '%s' "${out}"
}

# canary_reset <instance>: starts a new measurement window on every canary of the instance.
canary_reset() {
  local pod
  for pod in $(canary_pods "$1"); do
    canary_call "db-$1" "${pod}" POST /reset >/dev/null
  done
}

# canary_reports <instance>: one JSON report per canary pod, one per line.
canary_reports() {
  local pod
  for pod in $(canary_pods "$1"); do
    canary_call "db-$1" "${pod}" GET /report | jq -c .
  done
}
