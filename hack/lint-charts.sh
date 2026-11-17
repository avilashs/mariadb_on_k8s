#!/usr/bin/env bash
# Lints every chart under charts/ and validates what it renders.
#
# For each chart:
#   1. helm lint --strict (once per example values file for application charts).
#   2. Application charts only: helm template with every example values file,
#      piped through kubeconform (strict; custom resources included).
#
# Example values files live in <chart>/ci/*.yaml. An application chart without
# at least one is an error: a chart that is never rendered is never checked.

set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export HELM_CACHE_HOME="${CACHE}/helm/cache"
export HELM_CONFIG_HOME="${CACHE}/helm/config"
export HELM_DATA_HOME="${CACHE}/helm/data"

mapfile -t charts < <(chart_dirs)
if ((${#charts[@]} == 0)); then
  log "no charts yet: nothing to lint"
  exit 0
fi

for chart in "${charts[@]}"; do
  name="$(basename "${chart}")"

  if [[ "$(yq -r '.dependencies | length' "${chart}/Chart.yaml")" != "0" ]]; then
    helm dependency build "${chart}" >/dev/null
  fi

  if is_library_chart "${chart}"; then
    log "helm lint ${name} (library)"
    helm lint --strict "${chart}"
    continue
  fi

  mapfile -t examples < <(find "${chart}/ci" -maxdepth 1 -name '*.yaml' 2>/dev/null | sort)
  ((${#examples[@]} > 0)) || die "chart ${name} has no example values in ${name}/ci/*.yaml"

  for values in "${examples[@]}"; do
    example="$(basename "${values}")"
    log "helm lint ${name} with ${example}"
    helm lint --strict "${chart}" --values "${values}"
    log "render and validate ${name} with ${example}"
    helm template lint "${chart}" --namespace lint --values "${values}" |
      "$(dirname "${BASH_SOURCE[0]}")/kubeconform.sh" -summary -
  done
done
