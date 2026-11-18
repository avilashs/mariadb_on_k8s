#!/usr/bin/env bash
# Generates strict JSON Schemas for the custom resources this repository
# renders, from the CRDs listed under `crdSources` in versions.yaml.
# kubeconform uses them, so custom resources are validated instead of skipped.
#
# A source is either a list of raw CRD URLs, or a Helm chart whose rendered
# output contains the CRDs (`helmSet` is passed to `helm template`).
#
# Output: .cache/schemas/<group>/<kind>_<version>.json
# Regenerated only when a source or this generator changes. FORCE=1 overrides.

set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUT="${CACHE}/schemas"
here="$(dirname "${BASH_SOURCE[0]}")"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export HELM_CACHE_HOME="${CACHE}/helm/cache"
export HELM_CONFIG_HOME="${CACHE}/helm/config"
export HELM_DATA_HOME="${CACHE}/helm/data"

# Each source becomes one YAML file in $work, in order.
inputs=()
index=0
# The CRD kind itself: a hand-written strict schema (see that file).
cp "${here}/schemas/apiextensions.k8s.io_CustomResourceDefinition_v1.json" "${work}/crd-kind-schema.json"
while IFS= read -r source; do
  version_path="$(jq -r .versionFrom <<<"${source}")"
  version="$(pin "${version_path}")"
  minor="$(cut -d. -f1,2 <<<"${version}")"
  chart_path="$(jq -r '.chart // empty' <<<"${source}")"
  index=$((index + 1))
  if [[ -n "${chart_path}" ]]; then
    chart="$(pin "${chart_path}")"
    helm_set="$(jq -r '.helmSet // empty' <<<"${source}")"
    log "rendering CRDs of ${chart} ${version}"
    helm_args=(template crds "${chart}" --version "${version}" --include-crds)
    [[ -n "${helm_set}" ]] && helm_args+=(--set "${helm_set}")
    # Charts that ship CRDs in templates need installCRDs; the flag is ignored
    # by charts that do not know it, so it is always passed.
    helm_args+=(--set installCRDs=true)
    helm "${helm_args[@]}" >"${work}/${index}.yaml"
    inputs+=("${work}/${index}.yaml")
    continue
  fi
  while IFS= read -r url; do
    url="${url//\{version\}/${version}}"
    url="${url//\{minor\}/${minor}}"
    index=$((index + 1))
    log "fetching ${url}"
    curl -fsSL --retry 3 -o "${work}/${index}.yaml" "${url}"
    inputs+=("${work}/${index}.yaml")
  done < <(jq -r '.urls[]' <<<"${source}")
done < <(yq --output-format=json --indent=0 '.crdSources[]' "${ROOT}/versions.yaml")
((${#inputs[@]} > 0)) || die "versions.yaml lists no crdSources"

fingerprint="$(
  {
    yq --output-format=json --indent=0 '.crdSources' "${ROOT}/versions.yaml"
    cat "${here}/crd-schema.jq" "${BASH_SOURCE[0]}" "${here}/schemas/apiextensions.k8s.io_CustomResourceDefinition_v1.json"
  } | sha256sum | cut -d' ' -f1
)"
if [[ "${FORCE:-0}" != "1" && "$(cat "${OUT}/.fingerprint" 2>/dev/null)" == "${fingerprint}" ]]; then
  log "CRD schemas are up to date"
  exit 0
fi

rm -rf "${OUT}"
mkdir -p "${OUT}/apiextensions.k8s.io"
cp "${here}/schemas/apiextensions.k8s.io_CustomResourceDefinition_v1.json" "${OUT}/apiextensions.k8s.io/customresourcedefinition_v1.json"
count=1
for input in "${inputs[@]}"; do
  found=0
  while IFS= read -r record; do
    group="$(jq -r .group <<<"${record}")"
    kind="$(jq -r .kind <<<"${record}")"
    version="$(jq -r .version <<<"${record}")"
    mkdir -p "${OUT}/${group}"
    jq .schema <<<"${record}" >"${OUT}/${group}/${kind}_${version}.json"
    found=$((found + 1))
  done < <(yq eval-all --output-format=json --indent=0 '.' "${input}" |
    jq --compact-output --from-file "${here}/crd-schema.jq")
  ((found > 0)) || die "no CustomResourceDefinition found in $(basename "${input}")"
  count=$((count + found))
done

printf '%s\n' "${fingerprint}" >"${OUT}/.fingerprint"
log "wrote ${count} schemas to ${OUT}"
