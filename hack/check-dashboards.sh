#!/usr/bin/env bash
# Runs every query of every dashboard against a live Prometheus (PLAN.md phase 8 acceptance).
# The $namespace variable is replaced by the namespace of a real instance. A query that
# Prometheus rejects fails the check. A query that returns no series is reported: the
# exporter-based panels stay empty until the mysqld exporter works (docs/deviations.md).
set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ENV="${ENV:-kind}"
context="$(yq -r '.kubeContext' "${ROOT}/environments/${ENV}/platform.yaml")"
namespace="${CHECK_NAMESPACE:-db-alpha}"
port=$((29000 + RANDOM % 1000))
kubectl --context "${context}" -n monitoring port-forward svc/kube-prometheus-stack-prometheus "${port}:9090" >/dev/null 2>&1 &
pf=$!
trap 'kill "${pf}" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -fsS -o /dev/null "http://127.0.0.1:${port}/-/ready" 2>/dev/null && break; sleep 0.2; done

failures=0
empty=0
total=0
for dash in "${ROOT}"/charts/db-dashboards/dashboards/*.json; do
  while IFS= read -r expr; do
    total=$((total + 1))
    expr="${expr//\$namespace/${namespace}}"
    expr="${expr//\$\{namespace\}/${namespace}}"
    resp="$(curl -fsS -G "http://127.0.0.1:${port}/api/v1/query" --data-urlencode "query=${expr}" 2>/dev/null || true)"
    status="$(jq -r '.status // "error"' <<<"${resp:-{\}}")"
    if [[ "${status}" != "success" ]]; then
      failures=$((failures + 1))
      printf 'ERROR %s: %s\n  %s\n' "$(basename "${dash}")" "$(jq -r '.error // "no response"' <<<"${resp:-{\}}")" "${expr}" >&2
      continue
    fi
    if [[ "$(jq '.data.result | length' <<<"${resp}")" == "0" ]]; then
      empty=$((empty + 1))
      printf 'empty %s: %s\n' "$(basename "${dash}")" "${expr:0:110}"
    fi
  done < <(jq -r '.panels[].targets[]?.expr' "${dash}")
done

log "${total} queries, ${failures} rejected, ${empty} without data"
((failures == 0)) || die "${failures} dashboard quer(ies) rejected by Prometheus"
