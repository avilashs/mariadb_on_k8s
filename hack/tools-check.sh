#!/usr/bin/env bash
# Verifies that every tool pinned in versions.yaml is present and at its pin,
# and that the host prerequisites exist. Prints one line per tool and exits
# non-zero if any check fails.
#
# The version is taken from the binary itself wherever the binary can tell:
# the embedded Go module version for tools built with `go install`, the tool's
# own version output otherwise. helm-unittest is built from source without
# version metadata, so for it the install stamp is the only evidence.

set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

failures=0

report() {
  local tool="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    printf '  ok    %-14s %s\n' "${tool}" "${actual}"
  else
    printf '  FAIL  %-14s expected %s, found %s\n' "${tool}" "${expected}" "${actual:-nothing}"
    failures=$((failures + 1))
  fi
}

# Embedded module version of a binary built with `go install <pkg>@<version>`.
gomod_version() {
  go version -m "$(command -v "$1")" 2>/dev/null | awk '$1 == "mod" { print $3; exit }'
}

actual_version() {
  local tool="$1"
  command -v "${tool}" >/dev/null || return 0
  case "${tool}" in
    helm | kind | kubeconform | yq | pluto)
      gomod_version "${tool}"
      ;;
    helmfile)
      helmfile --version 2>/dev/null | awk '{ print $3 }'
      ;;
    kubectl)
      kubectl version --client 2>/dev/null | awk '/^Client Version:/ { print $3 }'
      ;;
    promtool)
      promtool --version 2>&1 | awk 'NR == 1 { print "v" $3 }'
      ;;
    yamllint)
      yamllint --version | awk '{ print "v" $2 }'
      ;;
    shellcheck)
      shellcheck --version | awk '/^version:/ { print "v" $2 }'
      ;;
    helm-unittest)
      helm-unittest --help >/dev/null 2>&1 && cat "${BIN}/.stamps/helm-unittest" 2>/dev/null
      ;;
  esac
}

log "pinned tools"
for tool in helm helmfile helm-unittest kubectl kind kubeconform promtool yq pluto yamllint shellcheck; do
  report "${tool}" "$(tool_pin "${tool}")" "$(actual_version "${tool}")"
done

log "host prerequisites"
for tool in go git make jq curl python3; do
  if command -v "${tool}" >/dev/null; then
    printf '  ok    %s\n' "${tool}"
  else
    printf '  FAIL  %s is missing\n' "${tool}"
    failures=$((failures + 1))
  fi
done

# Go: the pin is a minimum, because Go fetches newer toolchains on demand.
go_minimum="$(tool_pin go)"
go_actual="$(go env GOVERSION 2>/dev/null | sed 's/^go//')"
if [[ -n "${go_actual}" && "$(printf '%s\n%s\n' "${go_minimum}" "${go_actual}" | sort -V | head -n1)" == "${go_minimum}" ]]; then
  printf '  ok    go %s (minimum %s)\n' "${go_actual}" "${go_minimum}"
else
  printf '  FAIL  go %s is older than the minimum %s\n' "${go_actual:-missing}" "${go_minimum}"
  failures=$((failures + 1))
fi

# Docker is needed from phase 1 on (kind). Its absence does not fail phase 0 work.
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  printf '  ok    docker daemon reachable\n'
else
  warn "docker daemon not reachable: kind clusters (make kind-up, make e2e) will not work here"
fi

if ((failures > 0)); then
  die "${failures} tool check(s) failed. Run 'make tools' to install the pinned versions."
fi
log "all tools match versions.yaml"
