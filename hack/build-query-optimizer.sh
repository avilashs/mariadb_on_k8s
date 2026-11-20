#!/usr/bin/env bash
# Builds the query optimizer image (dbaas/query-optimizer:dev) from the commit pinned in versions.yaml and,
# with --load, loads it into the kind cluster.
#
#   hack/build-query-optimizer.sh [--load]
#
# The image is built offline: the optimizer's wheel and the wheels of its dependencies for the base image's
# Python are fetched on the host (so the build container needs no network) and installed with --no-index.
# Needs git, pip, docker. Behind a TLS-intercepting proxy set PIP_CERT to its CA bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${ROOT}/.cache/query-optimizer"
IMAGE="${QOPT_IMAGE:-dbaas/query-optimizer:dev}"
KIND_CLUSTER="${KIND_CLUSTER:-dbaas}"

pin() { awk -v key="$1" '/^queryOptimizer:/{f=1; next} f && /^[^ #]/{f=0} f && $1==key":"{gsub(/"/,"",$2); print $2; exit}' "${ROOT}/versions.yaml"; }
repo="$(pin repository)"
commit="$(pin commit)"
py="$(pin python)"
[[ -n "${repo}" && -n "${commit}" && -n "${py}" ]] || { echo "versions.yaml has no queryOptimizer pin" >&2; exit 1; }

src="${CACHE}/src"
ctx="${CACHE}/context"
rm -rf "${ctx}"
mkdir -p "${src}" "${ctx}/wheels"

# The pinned commit, shallow. GitHub serves a fetch by full SHA.
if [[ "$(git -C "${src}" rev-parse HEAD 2>/dev/null || true)" != "${commit}" ]]; then
  rm -rf "${src}" && mkdir -p "${src}"
  git -C "${src}" init -q
  git -C "${src}" fetch -q --depth 1 "${repo}" "${commit}"
  git -C "${src}" checkout -q FETCH_HEAD
fi
[[ "$(git -C "${src}" rev-parse HEAD)" == "${commit}" ]] || { echo "checked out the wrong commit" >&2; exit 1; }

# 1. the optimizer itself (pure Python: one wheel for every platform)
python3 -m pip wheel --quiet --no-deps --wheel-dir "${ctx}/wheels" "${src}"
# 2. its dependencies, binary wheels only, for the base image (Linux, x86-64, the pinned Python)
python3 -m pip download --quiet --dest "${ctx}/wheels" --only-binary=:all: \
  --python-version "${py}" --platform manylinux2014_x86_64 --platform manylinux_2_28_x86_64 --platform any \
  'pydantic>=2.0' 'PyYAML>=6.0' 'requests>=2.28' 'psycopg[binary]>=3.1' 'PyMySQL>=1.0'
cp "${ROOT}/tools/query-optimizer/Dockerfile" "${ctx}/Dockerfile"

docker build --quiet -t "${IMAGE}" "${ctx}" >/dev/null
echo "built ${IMAGE} from ${repo}@${commit:0:12} ($(docker image inspect "${IMAGE}" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1048576}'))"

if [[ "${1:-}" == "--load" ]]; then
  kind load docker-image "${IMAGE}" --name "${KIND_CLUSTER}"
fi
