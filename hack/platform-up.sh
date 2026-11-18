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

log "syncing platform for ENV=${ENV} into context ${context}"
(cd "${ROOT}" && helmfile -f helmfile.d/00-platform.yaml.gotmpl sync --skip-deps)
log "platform for ENV=${ENV} is in place"
