#!/usr/bin/env bash
# Self-test of the lint tooling. Run by `make unit`.
#
# Proves that the checks can fail: a linter that passes everything is worse
# than no linter. It also pins the plan's reference manifests to the CRD
# schemas of the operator versions in versions.yaml.
#
#   1. The versions.yaml parser returns pins and rejects unknown tools.
#   2. Every manifest in hack/testdata/manifests/valid passes validation.
#   3. Every manifest in hack/testdata/manifests/invalid fails validation, and
#      the failure mentions the text on its first line (`# expect: <text>`).

set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

here="$(dirname "${BASH_SOURCE[0]}")"
failures=0
pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  failures=$((failures + 1))
}

log "versions.yaml parser"
if [[ "$(tool_pin helm)" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pass "tool_pin returns a version for a pinned tool"
else
  fail "tool_pin did not return a version for helm"
fi
if (tool_pin no-such-tool) >/dev/null 2>&1; then
  fail "tool_pin accepted a tool that is not pinned"
else
  pass "tool_pin rejects a tool that is not pinned"
fi
if [[ "$(tool_pin kubectl)" == "$(pin .kubernetes)" ]]; then
  pass "kubectl is pinned to the test cluster's Kubernetes version"
else
  fail "kubectl pin $(tool_pin kubectl) differs from kubernetes pin $(pin .kubernetes)"
fi

log "manifests that must pass"
for manifest in "${here}"/testdata/manifests/valid/*.yaml; do
  name="$(basename "${manifest}")"
  if output="$("${here}/kubeconform.sh" "${manifest}" 2>&1)"; then
    pass "${name}"
  else
    fail "${name} was rejected:"
    printf '%s\n' "${output}" | sed 's/^/          /'
  fi
done

log "manifests that must fail"
for manifest in "${here}"/testdata/manifests/invalid/*.yaml; do
  name="$(basename "${manifest}")"
  expect="$(sed -n '1s/^# expect: //p' "${manifest}")"
  [[ -n "${expect}" ]] || die "${name} has no '# expect: <text>' first line"
  if output="$("${here}/kubeconform.sh" "${manifest}" 2>&1)"; then
    fail "${name} passed validation but must be rejected"
  elif grep -qF -- "${expect}" <<<"${output}"; then
    pass "${name} (rejected: mentions '${expect}')"
  else
    fail "${name} was rejected, but not because of '${expect}':"
    printf '%s\n' "${output}" | sed 's/^/          /'
  fi
done

if ((failures > 0)); then
  die "${failures} self-test check(s) failed"
fi
log "lint tooling self-test passed"
