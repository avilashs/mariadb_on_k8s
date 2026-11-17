#!/usr/bin/env bash
# Shared helpers for the scripts in hack/. Source this file; do not execute it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.bin"
CACHE="${ROOT}/.cache"
export ROOT BIN CACHE
export PATH="${BIN}:${PATH}"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# tool_pin <name>
# Prints the pinned version of a tool from the flat `tools:` block of
# versions.yaml. Parsed with awk so it works before yq is installed.
tool_pin() {
  awk -v want="$1:" '
    /^tools:[[:space:]]*$/       { in_tools = 1; next }
    in_tools && /^[^[:space:]#]/ { in_tools = 0 }
    in_tools && $1 == want       { print $2; found = 1; exit }
    END                          { if (!found) exit 1 }
  ' "${ROOT}/versions.yaml" || die "no pin for tool '$1' in versions.yaml"
}

# pin <yq-path>
# Prints any other value from versions.yaml. Needs yq (installed by `make tools`).
pin() {
  local value
  value="$(yq -r "$1" "${ROOT}/versions.yaml")"
  [[ -n "${value}" && "${value}" != "null" ]] || die "no value at '$1' in versions.yaml"
  printf '%s\n' "${value}"
}

# chart_dirs
# Prints every chart directory under charts/, one per line. Prints nothing if
# there are none yet.
chart_dirs() {
  local chart_yaml
  for chart_yaml in "${ROOT}"/charts/*/Chart.yaml; do
    [[ -f "${chart_yaml}" ]] || continue
    dirname "${chart_yaml}"
  done
}

# is_library_chart <chart-dir>
is_library_chart() {
  [[ "$(yq -r '.type // "application"' "$1/Chart.yaml")" == "library" ]]
}
