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
  engine="$(yq -r '.engine' "${file}")"
  # PostgreSQL roles are basic-auth Secrets (username and password), read by CloudNativePG.
  role_secret() {
    if [[ "${engine}" == "postgres" ]]; then
      "${ROOT}/scripts/ensure-pg-role-secret.sh" "${context}" "db-${name}" "$1" "$2" >/dev/null
    else
      "${ROOT}/scripts/ensure-secret.sh" "${context}" "db-${name}" "$1" password >/dev/null
    fi
  }
  while IFS= read -r owner; do
    role_secret "${name}-$(tr '_' '-' <<<"${owner}")-credentials" "${owner}"
  done < <(yq -r '.access.databases[]?.owner' "${file}")
  # The canary's role is on every instance (PLAN.md phase 6), so its Secret always exists.
  role_secret "${name}-canary-credentials" canary
done

# Instances with backups need the object store credentials in their namespace.
for file in "${instances_dir}"/*.yaml; do
  [[ -e "${file}" ]] || continue
  if [[ "$(yq -r '.backup.enabled // false' "${file}")" == "true" ]]; then
    "${ROOT}/scripts/ensure-backup-credentials.sh" "${context}" "db-$(yq -r '.name' "${file}")" \
      "${ROOT}/environments/${ENV}/platform.yaml"
    # MariaDB only: the role that closes the active binary log for point in time recovery.
    if [[ "$(yq -r '.engine' "${file}")" == "mariadb" ]]; then
      "${ROOT}/scripts/ensure-secret.sh" "${context}" "db-$(yq -r '.name' "${file}")" \
        "$(yq -r '.name' "${file}")-binlog-flush-credentials" password >/dev/null
    fi
  fi
done

# Helm's --wait does not hold a custom resource that has no status yet, so each stage
# is waited on explicitly, before the next one starts.
wait_instances() {
  local kind="$1" file name
  for file in "${instances_dir}"/*.yaml; do
    [[ -e "${file}" ]] || continue
    name="$(yq -r '.name' "${file}")"
    if [[ "$(yq -r '.engine' "${file}")" == "postgres" ]]; then
      # PostgreSQL has one Cluster; its roles and databases are reconciled by the operator.
      [[ "${kind}" == "mariadb" ]] || continue
      kubectl --context "${context}" -n "db-${name}" wait "cluster/${name}" --for=condition=Ready --timeout=900s >/dev/null
    elif [[ "${kind}" == "mariadb" ]]; then
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
log "syncing the canaries for ENV=${ENV}"
helmfile_sync --selector stage=canary
log "instances for ENV=${ENV} are in place"
