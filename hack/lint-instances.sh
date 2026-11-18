#!/usr/bin/env bash
# Validates instance values files against the mariadb-instance chart, with the
# catalogue of the environment they belong to. Renders each one and checks the
# result strictly: schema, placement and tier rules, and every object.
#
#   hack/lint-instances.sh                 all files under environments/*/instances/
#   hack/lint-instances.sh <file> ...      the given files (env taken from the path)

set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export HELM_CACHE_HOME="${CACHE}/helm/cache"
export HELM_CONFIG_HOME="${CACHE}/helm/config"
export HELM_DATA_HOME="${CACHE}/helm/data"

if (($# == 0)); then
  mapfile -t files < <(find "${ROOT}/environments" -path '*/instances/*.yaml' | sort)
else
  files=("$@")
fi
if ((${#files[@]} == 0)); then
  log "no instances to validate"
  exit 0
fi

failures=0
for file in "${files[@]}"; do
  env_dir="$(sed -n 's|.*/environments/\([^/]*\)/instances/.*|\1|p' <<<"${file}")"
  [[ -n "${env_dir}" ]] || die "${file} is not under environments/<env>/instances/"
  platform="${ROOT}/environments/${env_dir}/platform.yaml"
  rendered="${CACHE}/instance-lint/$(basename "${file}")"
  mkdir -p "$(dirname "${rendered}")"
  merged="${rendered}.values.yaml"
  yq -n "load(\"${file}\") * {\"catalogue\": {
    \"storageTiers\": load(\"${platform}\").storageTiers,
    \"storageClasses\": load(\"${platform}\").storageClasses,
    \"nodeClasses\": load(\"${platform}\").nodeClasses}}" >"${merged}"
  name="$(yq -r '.name' "${file}")"
  access="${rendered}.access.yaml"
  : >"${access}"
  access_ok=1
  if [[ "$(yq -r '.access.databases | length' "${file}")" != "0" ]]; then
    for stage in users grants; do
      yq -n ".name = \"${name}\" | .stage = \"${stage}\" | .databases = load(\"${file}\").access.databases" >"${merged}.${stage}"
      helm template "${name}-${stage}" "${ROOT}/charts/db-access" --namespace "db-${name}" \
        --values "${merged}.${stage}" >>"${access}" 2>>"${rendered}.err" || access_ok=0
    done
  fi
  if ((access_ok == 1)) && helm template "${name}" "${ROOT}/charts/mariadb-instance" --namespace "db-${name}" \
      --values "${merged}" >"${rendered}" 2>"${rendered}.err" &&
    cat "${access}" >>"${rendered}" &&
    "${ROOT}/hack/kubeconform.sh" -summary "${rendered}" >/dev/null 2>&1; then
    printf '  ok    %s\n' "${file#"${ROOT}"/}"
  else
    failures=$((failures + 1))
    printf '  FAIL  %s\n' "${file#"${ROOT}"/}"
    sed 's/^/          /' "${rendered}.err" | head -5
    "${ROOT}/hack/kubeconform.sh" "${rendered}" 2>&1 | sed 's/^/          /' | head -5 || true
  fi
done

((failures == 0)) || die "${failures} instance file(s) failed validation"
log "all instance files are valid"
