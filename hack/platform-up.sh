#!/usr/bin/env bash
# Installs or updates the platform components for ENV (default: kind).
#
# Idempotent. Re-running it re-applies the same declared state, so objects whose
# spec did not change are not written again. tests/e2e/platform.sh checks this.
#
# Requires the kube context named in environments/$ENV/platform.yaml to exist.

set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV="${ENV:-kind}"
export ENV
platform_file="${ROOT}/environments/${ENV}/platform.yaml"
[[ -f "${platform_file}" ]] || die "no platform values for ENV=${ENV} at ${platform_file}"
[[ -f "${ROOT}/environments/${ENV}/kube-prometheus-stack.yaml" ]] ||
  die "environments/${ENV}/kube-prometheus-stack.yaml is required (it may be empty)"

context="$(yq -r '.kubeContext' "${platform_file}")"
kubectl config get-contexts -o name | grep -qx "${context}" ||
  die "kube context '${context}' does not exist. For kind, run 'make kind-up' first."
kubectl --context "${context}" get nodes >/dev/null ||
  die "cannot reach the API server of context '${context}'"

export HELM_CACHE_HOME="${CACHE}/helm/cache"
export HELM_CONFIG_HOME="${CACHE}/helm/config"
export HELM_DATA_HOME="${CACHE}/helm/data"

# ensure_grafana_admin_secret: Grafana's admin credentials are created once and
# never regenerated. The chart would otherwise pick a new password on every apply.
ensure_grafana_admin_secret() {
  local name="dbaas-grafana-admin"
  if [[ "$(yq -r '.monitoring.install' "${platform_file}")" != "true" ]]; then
    return 0
  fi
  if kubectl --context "${context}" -n monitoring get secret "${name}" >/dev/null 2>&1; then
    return 0
  fi
  log "creating ${name} (generated once)"
  kubectl --context "${context}" -n monitoring create secret generic "${name}" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | cut -c1-32)" >/dev/null
}

# HELM_EXTRA_ARGS: extra helm flags for every release, e.g. --force-conflicts after another
# controller (the AKS admissions enforcer) took ownership of a field the chart also sets.
helmfile_sync() {
  (cd "${ROOT}" && helmfile -f helmfile.d/00-platform.yaml.gotmpl sync --skip-deps ${HELM_EXTRA_ARGS:+--args "${HELM_EXTRA_ARGS}"} "$@")
}

log "syncing the platform base for ENV=${ENV} into context ${context}"
helmfile_sync --selector name=db-platform-base
# The base creates the monitoring namespace, which must exist before its secret.
ensure_grafana_admin_secret
log "syncing the rest of the platform for ENV=${ENV}"
helmfile_sync
log "platform for ENV=${ENV} is in place"
