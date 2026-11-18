#!/usr/bin/env bash
# Syncs every instance under environments/$ENV/instances/. Idempotent. Needs the
# platform installed (make platform-up) for the same ENV.
set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV="${ENV:-kind}"
export ENV
context="$(yq -r '.kubeContext' "${ROOT}/environments/${ENV}/platform.yaml")"
kubectl --context "${context}" get priorityclass dbaas-database >/dev/null 2>&1 ||
  die "the platform is not installed in ${context}. Run 'make platform-up ENV=${ENV}' first."
kubectl --context "${context}" get crd mariadbs.k8s.mariadb.com >/dev/null 2>&1 ||
  die "the MariaDB CRDs are missing in ${context}. Run 'make platform-up ENV=${ENV}' first."

export HELM_CACHE_HOME="${CACHE}/helm/cache"
export HELM_CONFIG_HOME="${CACHE}/helm/config"
export HELM_DATA_HOME="${CACHE}/helm/data"
instances_dir="${INSTANCES_DIR:-${ROOT}/environments/${ENV}/instances}"
helmfile_sync() {
  (cd "${ROOT}" && helmfile -f helmfile.d/10-instances.yaml.gotmpl sync --skip-deps "$@")
}

log "syncing the namespaces of the instances for ENV=${ENV} (directory: ${instances_dir})"
helmfile_sync --selector stage=namespace

# The Users reference a credentials Secret per owner. It must exist before the Users
# do, and it is created once, never overwritten.
for file in "${instances_dir}"/*.yaml; do
  [[ -e "${file}" ]] || continue
  name="$(yq -r '.name' "${file}")"
  while IFS= read -r owner; do
    secret="${name}-$(tr '_' '-' <<<"${owner}")-credentials"
    "${ROOT}/scripts/ensure-secret.sh" "${context}" "db-${name}" "${secret}" password >/dev/null
  done < <(yq -r '.access.databases[]?.owner' "${file}")
done

# Helm's --wait does not hold a custom resource that has no status yet, so each stage
# is waited on explicitly, before the next one starts.
wait_instances() {
  local kind="$1" file name
  for file in "${instances_dir}"/*.yaml; do
    [[ -e "${file}" ]] || continue
    name="$(yq -r '.name' "${file}")"
    if [[ "${kind}" == "mariadb" ]]; then
      kubectl --context "${context}" -n "db-${name}" wait "mariadb/${name}" --for=condition=Ready --timeout=900s >/dev/null
    elif [[ -n "$(yq -r '.access.databases[]?.name' "${file}")" ]]; then
      kubectl --context "${context}" -n "db-${name}" wait "${kind}" --all --for=condition=Ready --timeout=600s >/dev/null
    fi
  done
}

log "syncing the instances for ENV=${ENV}"
helmfile_sync --selector stage=instance
wait_instances mariadb
log "syncing the users for ENV=${ENV}"
helmfile_sync --selector stage=users
wait_instances user
log "syncing the grants for ENV=${ENV}"
helmfile_sync --selector stage=grants
wait_instances grant
log "instances for ENV=${ENV} are in place"
