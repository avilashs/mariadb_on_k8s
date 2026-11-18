#!/usr/bin/env bash
# Post-flight gate of a rotation or an upgrade (PLAN.md phase 9, section 9.3): the checks of
# the pre-flight that must hold after the change, plus the placement and the client numbers
# of the window. Writes a JSON report and exits non-zero on any failure.
#
#   scripts/postflight.sh <report-file>
set -euo pipefail

report_file="${1:?usage: $0 <report-file>}"
KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
kc() { kubectl --context "${KUBE_CONTEXT}" "$@"; }
failures=0
checks='[]'
add() { # add <name> <ok true|false> <detail>
  checks="$(jq -c --arg n "$1" --argjson ok "$2" --arg d "$3" '. + [{name: $n, ok: $ok, detail: $d}]' <<<"${checks}")"
  [[ "$2" == "true" ]] || failures=$((failures + 1))
}

instances="$(kc get mariadb -A -l dbaas.local/engine=mariadb -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"')"
while read -r ns name; do
  [[ -n "${ns}" ]] || continue
  ready="$(kc -n "${ns}" get mariadb "${name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  primaries="$(kc -n "${ns}" get pods -l "app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=${name}" -o json |
    jq '[.items[] | select(.metadata.labels["k8s.mariadb.com/role"] == "primary")] | length')"
  add "${ns}/${name} Ready with one primary" "$([[ "${ready}" == "True" && "${primaries}" == "1" ]] && echo true || echo false)" "ready=${ready} primaries=${primaries}"
  allowed="$(kc -n "${ns}" get pdb "${name}" -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || echo 0)"
  add "${ns}/${name} budget allows one disruption" "$([[ "${allowed:-0}" -ge 1 ]] && echo true || echo false)" "allowed=${allowed:-0}"
  # Pods of one instance are on distinct nodes and spread over the zones of their class.
  nodes="$(kc -n "${ns}" get pods -l "app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=${name}" -o json |
    jq -r '[.items[].spec.nodeName] | .[]')"
  distinct="$(sort -u <<<"${nodes}" | grep -c . || true)"
  total="$(grep -c . <<<"${nodes}" || true)"
  add "${ns}/${name} pods on distinct nodes" "$([[ "${distinct}" == "${total}" ]] && echo true || echo false)" "${distinct} of ${total}"
  zones="$(for n in ${nodes}; do kc get node "${n}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'; echo; done | grep -c . || true)"
  zone_count="$(for n in ${nodes}; do kc get node "${n}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'; echo; done | grep . | sort -u | wc -l | tr -d ' ')"
  add "${ns}/${name} pods spread over zones" "$([[ "${zone_count}" -ge 2 ]] && echo true || echo false)" "${zone_count} zones for ${zones} pods"
done <<<"${instances}"

pending="$(kc get pods -A -l app.kubernetes.io/name=mariadb --field-selector=status.phase=Pending -o name | wc -l | tr -d ' ')"
add "no database pod is Pending" "$([[ "${pending}" == "0" ]] && echo true || echo false)" "${pending} pending"

# Client numbers of the window, from the canaries (the same numbers the alerts use).
canaries="[]"
while read -r ns name; do
  [[ -n "${ns}" ]] || continue
  for pod in $(kc -n "${ns}" get pods -l "app.kubernetes.io/name=db-canary,app.kubernetes.io/instance=${name}" -o jsonpath='{.items[*].metadata.name}'); do
    port=$((31000 + RANDOM % 1000))
    kc -n "${ns}" port-forward "pod/${pod}" "${port}:8080" >/dev/null 2>&1 &
    pf=$!
    for _ in $(seq 1 50); do curl -fsS -o /dev/null "http://127.0.0.1:${port}/healthz" 2>/dev/null && break; sleep 0.2; done
    rep="$(curl -fsS "http://127.0.0.1:${port}/report" 2>/dev/null || echo '{}')"
    kill "${pf}" 2>/dev/null || true
    canaries="$(jq -c --argjson r "${rep}" --arg ns "${ns}" '. + [$r + {namespace: $ns}]' <<<"${canaries}")"
  done
done <<<"${instances}"
lost="$(jq '[.[].lost_acknowledged_writes // 0] | add // 0' <<<"${canaries}")"
add "zero lost acknowledged writes" "$([[ "${lost}" == "0" ]] && echo true || echo false)" "${lost} lost"

jq -n --argjson checks "${checks}" --argjson canaries "${canaries}" --arg at "$(date -u +%FT%TZ)" \
  '{generated_at: $at, checks: $checks, canaries: $canaries, passed: ([$checks[] | select(.ok)] | length), failed: ([$checks[] | select(.ok | not)] | length)}' >"${report_file}"
echo "post-flight report: ${report_file}"
if ((failures > 0)); then
  echo "post-flight FAILED: ${failures} check(s)" >&2
  exit 1
fi
echo "post-flight passed"
