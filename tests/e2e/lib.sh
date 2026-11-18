# shellcheck shell=bash
# Helpers for the e2e suites. Sourced, never executed.
#
# Suites must stay engine-neutral: anything that differs between MariaDB and
# PostgreSQL goes into a helper here, with one branch per engine.

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${E2E_DIR}/../.." && pwd)"
# shellcheck source=hack/lib.sh
source "${ROOT}/hack/lib.sh"

ENV="${ENV:-kind}"
ENGINE="${ENGINE:-mariadb}"
PLATFORM_FILE="${ROOT}/environments/${ENV}/platform.yaml"
CONTEXT="$(yq -r '.kubeContext' "${PLATFORM_FILE}")"

FAILURES=0
CHECKS=0

check() {
  # check <description> <command...>
  local description="$1"
  shift
  CHECKS=$((CHECKS + 1))
  if output="$("$@" 2>&1)"; then
    printf '  ok    %s\n' "${description}"
  else
    FAILURES=$((FAILURES + 1))
    printf '  FAIL  %s\n' "${description}"
    [[ -n "${output}" ]] && printf '%s\n' "${output}" | sed 's/^/          /' | head -20
  fi
}

# kc <kubectl args...>: kubectl against the environment's context.
kc() { kubectl --context "${CONTEXT}" "$@"; }

# platform_value <yq path>: a value from environments/$ENV/platform.yaml.
platform_value() { yq -r "$1" "${PLATFORM_FILE}"; }

summary() {
  printf '\n%d check(s), %d failed\n' "${CHECKS}" "${FAILURES}"
  ((FAILURES == 0))
}
