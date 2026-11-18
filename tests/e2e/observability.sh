#!/usr/bin/env bash
# Phase 8 acceptance (PLAN.md phase 8, e2e/observability), the parts that need no exporter:
#  - Prometheus loads every rule group of the alert catalogue
#  - the canary and drain-guard targets are up
#  - every dashboard is in Grafana's search, in the Databases folder
#  - an induced fault reaches Alertmanager: drain-guard scaled to zero fires DrainGuardDown
# Not covered: the MariaDB exporter rules (the exporter cannot reach the database in kind;
# see docs/deviations.md). Runs for both engines.
set -euo pipefail
# shellcheck source=tests/e2e/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

prom_port=$((29500 + RANDOM % 400))
grafana_port=$((29900 + RANDOM % 90))
kc -n monitoring port-forward svc/kube-prometheus-stack-prometheus "${prom_port}:9090" >/dev/null 2>&1 &
pf_prom=$!
kc -n monitoring port-forward svc/kube-prometheus-stack-grafana "${grafana_port}:80" >/dev/null 2>&1 &
pf_graf=$!
am_port=$((29990 + RANDOM % 9))
kc -n monitoring port-forward svc/kube-prometheus-stack-alertmanager "${am_port}:9093" >/dev/null 2>&1 &
pf_am=$!
trap 'kill ${pf_prom} ${pf_graf} ${pf_am} 2>/dev/null || true; kc -n dbaas-system scale deployment drain-guard --replicas=2 >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 50); do curl -fsS -o /dev/null "http://127.0.0.1:${prom_port}/-/ready" 2>/dev/null && break; sleep 0.2; done

prom_q() { curl -fsS -G "http://127.0.0.1:${prom_port}/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // empty'; }

check_rule_groups_loaded() {
  local groups
  groups="$(curl -fsS "http://127.0.0.1:${prom_port}/api/v1/rules" | jq -r '.data.groups[].name' | sort -u)"
  for g in dbaas-service dbaas-mariadb dbaas-state; do
    grep -qx "${g}" <<<"${groups}" || { echo "rule group ${g} is not loaded"; return 1; }
  done
}

check_canary_and_guard_targets_up() {
  [[ "$(prom_q 'count(up{pod=~".*-canary-.*"} == 1)')" -ge 2 ]] || { echo "fewer than two canary targets are up"; return 1; }
  [[ "$(prom_q 'count(up{pod=~"drain-guard-.*"} == 1)')" -ge 1 ]] || { echo "no drain-guard target is up"; return 1; }
}

check_dashboards_in_grafana() {
  local pass found dash
  pass="$(kc -n monitoring get secret dbaas-grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
  for dash in fleet instance maintenance backup service; do
    found="$(curl -fsS -u "admin:${pass}" "http://127.0.0.1:${grafana_port}/api/search?query=$(printf '%s' "${dash}")" |
      jq -r '[.[] | select(.type == "dash-db")] | length')" || found=0
    [[ "${found}" -ge 1 ]] || { echo "dashboard ${dash} is not in Grafana search"; return 1; }
  done
}

check_induced_fault_reaches_alertmanager() {
  kc -n dbaas-system scale deployment drain-guard --replicas=0 >/dev/null
  local deadline=$((SECONDS + 900)) alerts
  until alerts="$(curl -fsS "http://127.0.0.1:${am_port}/api/v2/alerts?active=true" |
      jq -r '[.[] | select(.labels.alertname == "DrainGuardDown")] | length')" && [[ "${alerts}" -ge 1 ]]; do
    ((SECONDS < deadline)) || { echo "DrainGuardDown did not reach Alertmanager"; return 1; }
    sleep 15
  done
  kc -n dbaas-system scale deployment drain-guard --replicas=2 >/dev/null
  kc -n dbaas-system rollout status deployment drain-guard --timeout=300s >/dev/null
}

check "Prometheus loads the three rule groups of the catalogue" check_rule_groups_loaded
check "the canary and drain-guard targets are up" check_canary_and_guard_targets_up
check "all five dashboards are in Grafana's search" check_dashboards_in_grafana
check "an induced fault (drain-guard down) reaches Alertmanager as DrainGuardDown" check_induced_fault_reaches_alertmanager

summary
