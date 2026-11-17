#!/usr/bin/env bash
# Installs every pinned tool from versions.yaml into ./.bin.
#
# Idempotent: a tool that is already at its pin is skipped.
#
# How tools are obtained:
#   - Go tools are built from their pinned module version through the Go module
#     proxy, which verifies every download against the Go checksum database.
#     Needs only a Go toolchain; newer toolchains are fetched on demand.
#   - yamllint and shellcheck come from PyPI into a private virtualenv.
#   - kubectl comes from dl.k8s.io and is verified against its published SHA-256.
#
# Host prerequisites (not installed here): go, python3, curl, git, make, jq.

set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STAMPS="${BIN}/.stamps"
mkdir -p "${BIN}" "${STAMPS}" "${CACHE}"

for prerequisite in go python3 curl; do
  command -v "${prerequisite}" >/dev/null || die "host prerequisite '${prerequisite}' is missing"
done

# Let Go fetch the toolchain a module asks for, and never inherit a caller's flags.
export GOTOOLCHAIN=auto
export GOFLAGS=
export CGO_ENABLED=0

installed() { [[ -x "${BIN}/$1" && "$(cat "${STAMPS}/$1" 2>/dev/null)" == "$2" ]]; }
stamp() { printf '%s\n' "$2" >"${STAMPS}/$1"; }

# go_install <binary> <pin> <package>@<module-version>
# For modules whose go.mod has no replace or exclude directives.
go_install() {
  local binary="$1" pin="$2" target="$3"
  installed "${binary}" "${pin}" && return 0
  log "building ${binary} ${pin}"
  local out
  out="$(mktemp -d)"
  GOBIN="${out}" go install "${target}"
  mv "${out}"/* "${BIN}/${binary}"
  rm -rf "${out}"
  stamp "${binary}" "${pin}"
}

# go_build <binary> <pin> <module> <module-version> <package-dir> [ldflags]
# For modules that `go install` refuses because their go.mod carries replace or
# exclude directives. The module is downloaded (checksum-verified), copied out
# of the read-only module cache and built as the main module.
go_build() {
  local binary="$1" pin="$2" module="$3" version="$4" package="$5" ldflags="${6:-}"
  installed "${binary}" "${pin}" && return 0
  log "building ${binary} ${pin}"
  local work src
  work="$(mktemp -d)"
  # `go mod download` wants to run outside any module so it cannot touch one.
  src="$(cd "${work}" && go mod download -json "${module}@${version}" |
    awk -F'"' '$2 == "Dir" { print $4 }')"
  [[ -d "${src}" ]] || die "could not download ${module}@${version}"
  cp -r "${src}" "${work}/src"
  chmod -R u+w "${work}/src"
  # GOWORK=off: some modules ship a go.work that names sibling modules the
  # module proxy does not carry.
  (cd "${work}/src" && GOWORK=off go build -trimpath -ldflags "${ldflags}" -o "${BIN}/${binary}" "./${package}")
  rm -rf "${work}"
  stamp "${binary}" "${pin}"
}

# ---------------------------------------------------------------- Go tools

pin_helm="$(tool_pin helm)"
go_install helm "${pin_helm}" "helm.sh/helm/v4/cmd/helm@${pin_helm}"

pin_helmfile="$(tool_pin helmfile)"
go_build helmfile "${pin_helmfile}" \
  github.com/helmfile/helmfile "${pin_helmfile}" . \
  "-X go.szostok.io/version.version=${pin_helmfile}"

pin_kind="$(tool_pin kind)"
go_install kind "${pin_kind}" "sigs.k8s.io/kind@${pin_kind}"

pin_kubeconform="$(tool_pin kubeconform)"
go_install kubeconform "${pin_kubeconform}" "github.com/yannh/kubeconform/cmd/kubeconform@${pin_kubeconform}"

pin_yq="$(tool_pin yq)"
go_install yq "${pin_yq}" "github.com/mikefarah/yq/v4@${pin_yq}"

pin_pluto="$(tool_pin pluto)"
go_install pluto "${pin_pluto}" "github.com/fairwindsops/pluto/v5/cmd/pluto@${pin_pluto}"

pin_unittest="$(tool_pin helm-unittest)"
go_build helm-unittest "${pin_unittest}" \
  github.com/helm-unittest/helm-unittest "${pin_unittest}" cmd/helm-unittest

# Prometheus tags its Go module v0.<major><minor>.<patch> for release <major>.<minor>.<patch>.
pin_promtool="$(tool_pin promtool)"
IFS=. read -r prom_major prom_minor prom_patch <<<"${pin_promtool#v}"
prom_module_version="$(printf 'v0.%d%02d.%d' "${prom_major}" "${prom_minor}" "${prom_patch}")"
go_build promtool "${pin_promtool}" \
  github.com/prometheus/prometheus "${prom_module_version}" cmd/promtool \
  "-X github.com/prometheus/common/version.Version=${pin_promtool#v}"

# ---------------------------------------------------------------- kubectl

pin_kubectl="$(tool_pin kubectl)"
if ! installed kubectl "${pin_kubectl}"; then
  log "downloading kubectl ${pin_kubectl}"
  os="$(go env GOOS)"
  arch="$(go env GOARCH)"
  url="https://dl.k8s.io/release/${pin_kubectl}/bin/${os}/${arch}/kubectl"
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 -o "${tmp}/kubectl" "${url}"
  curl -fsSL --retry 3 -o "${tmp}/kubectl.sha256" "${url}.sha256"
  echo "$(cat "${tmp}/kubectl.sha256")  ${tmp}/kubectl" | sha256sum --check --quiet ||
    die "kubectl ${pin_kubectl} failed its checksum"
  install -m 0755 "${tmp}/kubectl" "${BIN}/kubectl"
  rm -rf "${tmp}"
  stamp kubectl "${pin_kubectl}"
fi

# ---------------------------------------------------------------- Python tools

pin_yamllint="$(tool_pin yamllint)"
pin_shellcheck="$(tool_pin shellcheck)"
if ! installed yamllint "${pin_yamllint}" || ! installed shellcheck "${pin_shellcheck}"; then
  log "installing yamllint ${pin_yamllint} and shellcheck ${pin_shellcheck}"
  venv="${CACHE}/venv"
  [[ -x "${venv}/bin/pip" ]] || python3 -m venv "${venv}"
  # The shellcheck-py wheel appends a packaging revision to the upstream version.
  "${venv}/bin/pip" install --quiet --disable-pip-version-check \
    "yamllint==${pin_yamllint#v}" "shellcheck-py==${pin_shellcheck#v}.*"
  ln -sf "${venv}/bin/yamllint" "${BIN}/yamllint"
  ln -sf "${venv}/bin/shellcheck" "${BIN}/shellcheck"
  stamp yamllint "${pin_yamllint}"
  stamp shellcheck "${pin_shellcheck}"
fi

log "all tools installed in ${BIN}"
