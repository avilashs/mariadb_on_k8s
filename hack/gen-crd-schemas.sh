#!/usr/bin/env bash
# Generates strict JSON Schemas for the custom resources this repository
# renders, from the CRDs listed under `crdSources` in versions.yaml.
# kubeconform uses them, so custom resources are validated instead of skipped.
#
# Output: .cache/schemas/<group>/<kind>_<version>.json
# Regenerated only when a source or this generator changes. FORCE=1 overrides.

set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUT="${CACHE}/schemas"
here="$(dirname "${BASH_SOURCE[0]}")"

# Resolve every source URL from versions.yaml.
urls=()
while IFS= read -r source; do
  version_path="$(jq -r .versionFrom <<<"${source}")"
  version="$(pin "${version_path}")"
  minor="$(cut -d. -f1,2 <<<"${version}")"
  while IFS= read -r url; do
    url="${url//\{version\}/${version}}"
    url="${url//\{minor\}/${minor}}"
    urls+=("${url}")
  done < <(jq -r '.urls[]' <<<"${source}")
done < <(yq --output-format=json --indent=0 '.crdSources[]' "${ROOT}/versions.yaml")
((${#urls[@]} > 0)) || die "versions.yaml lists no crdSources"

fingerprint="$(
  {
    printf '%s\n' "${urls[@]}"
    cat "${here}/crd-schema.jq" "${BASH_SOURCE[0]}"
  } | sha256sum | cut -d' ' -f1
)"
if [[ "${FORCE:-0}" != "1" && "$(cat "${OUT}/.fingerprint" 2>/dev/null)" == "${fingerprint}" ]]; then
  log "CRD schemas are up to date"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

rm -rf "${OUT}"
mkdir -p "${OUT}"
count=0
index=0
for url in "${urls[@]}"; do
  index=$((index + 1))
  log "fetching ${url}"
  curl -fsSL --retry 3 -o "${work}/${index}.yaml" "${url}"

  found=0
  while IFS= read -r record; do
    group="$(jq -r .group <<<"${record}")"
    kind="$(jq -r .kind <<<"${record}")"
    version="$(jq -r .version <<<"${record}")"
    mkdir -p "${OUT}/${group}"
    jq .schema <<<"${record}" >"${OUT}/${group}/${kind}_${version}.json"
    found=$((found + 1))
  done < <(yq eval-all --output-format=json --indent=0 '.' "${work}/${index}.yaml" |
    jq --compact-output --from-file "${here}/crd-schema.jq")
  ((found > 0)) || die "no CustomResourceDefinition found at ${url}"
  count=$((count + found))
done

printf '%s\n' "${fingerprint}" >"${OUT}/.fingerprint"
log "wrote ${count} schemas to ${OUT}"
