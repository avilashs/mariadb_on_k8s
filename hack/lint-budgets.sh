#!/usr/bin/env bash
# Fails when a chart of this repository renders a PodDisruptionBudget that selects database
# pods (PLAN.md phase 7, step 1, rule D6). The operator creates the one budget per instance;
# a second one would make every eviction of a database pod fail.
#
# Database pods carry app.kubernetes.io/name=mariadb (or postgres, phase 10). A budget is
# allowed for other workloads only.
set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export HELM_CACHE_HOME="${CACHE}/helm/cache"
export HELM_CONFIG_HOME="${CACHE}/helm/config"
export HELM_DATA_HOME="${CACHE}/helm/data"

failures=0
mapfile -t charts < <(chart_dirs)
for chart in "${charts[@]}"; do
  is_library_chart "${chart}" && continue
  name="$(basename "${chart}")"
  mapfile -t examples < <(find "${chart}/ci" -maxdepth 1 -name '*.yaml' 2>/dev/null | sort)
  for values in "${examples[@]}"; do
    rendered="$(helm template lint "${chart}" --namespace lint --values "${values}")"
    bad="$(yq eval-all -r 'select(.kind == "PodDisruptionBudget") |
      select((.spec.selector.matchLabels["app.kubernetes.io/name"] // "") | test("^(mariadb|postgres)$")) |
      .metadata.name' - <<<"${rendered}" || true)"
    if [[ -n "${bad}" ]]; then
      printf 'ERROR: %s (%s) renders a budget over database pods: %s\n' "${name}" "$(basename "${values}")" "${bad}" >&2
      failures=$((failures + 1))
    fi
  done
done

((failures == 0)) || die "${failures} chart(s) render a second budget over database pods"
log "no chart renders a budget over database pods"
