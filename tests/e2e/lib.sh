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
      --namespace "db-${name}" --values "${out}" --wait --timeout 600s >/dev/null
  done
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
