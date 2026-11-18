#!/usr/bin/env python3
"""Writes the Grafana dashboards of PLAN.md phase 8 into charts/db-dashboards/dashboards/.

The JSON files are generated from the panel definitions below, so every query is reviewed
in one place. `hack/check-dashboards.sh` runs every expression against a live Prometheus.
"""
import json, os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "charts", "db-dashboards", "dashboards")
DS = {"type": "prometheus", "uid": "${datasource}"}
NS_VAR = {"name": "namespace", "label": "Instance namespace", "type": "query", "datasource": DS,
          "query": {"query": "label_values(db_canary_write_total, namespace)", "refId": "ns"},
          "refresh": 2, "includeAll": True, "multi": True, "current": {"text": "All", "value": "$__all"},
          "definition": "label_values(db_canary_write_total, namespace)"}
DS_VAR = {"name": "datasource", "type": "datasource", "query": "prometheus", "current": {}}

def target(expr, legend=""):
    return {"datasource": DS, "expr": expr, "legendFormat": legend, "refId": "A"}

def panel(pid, title, kind, x, y, w, h, exprs, unit="short", desc=""):
    return {"id": pid, "title": title, "type": kind, "description": desc,
            "gridPos": {"x": x, "y": y, "w": w, "h": h}, "datasource": DS,
            "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
            "options": {}, "targets": [target(e, l) for e, l in exprs]}

def dashboard(uid, title, panels, variables, description):
    return {"uid": uid, "title": title, "description": description, "tags": ["dbaas"],
            "timezone": "utc", "schemaVersion": 39, "version": 1, "refresh": "30s",
            "time": {"from": "now-6h", "to": "now"}, "editable": False,
            "templating": {"list": [DS_VAR] + variables}, "panels": panels,
            "links": [], "annotations": {"list": []}}

NSF = 'namespace=~"$namespace"'

fleet = dashboard("dbaas-fleet", "Fleet overview", [
    panel(1, "Write availability per instance", "timeseries", 0, 0, 12, 8,
          [(f'sum by (namespace) (rate(db_canary_write_total{{result="ok",{NSF}}}[5m])) / sum by (namespace) (rate(db_canary_write_total{{{NSF}}}[5m]))', "{{namespace}}")],
          unit="percentunit", desc="Share of canary writes that succeed, per instance."),
    panel(2, "Replica delay (worst)", "timeseries", 12, 0, 12, 8,
          [(f'max by (namespace) (db_canary_replica_delay_seconds{{{NSF}}})', "{{namespace}}")], unit="s"),
    panel(3, "Firing alerts", "stat", 0, 8, 6, 4,
          [('sum(ALERTS{alertstate="firing", alertname=~"Db.*|MariaDB.*|DrainGuard.*"})', "firing")]),
    panel(4, "Pods ready of desired", "stat", 6, 8, 6, 4,
          [(f'sum(kube_pod_status_ready{{condition="true", namespace=~"db-.*", pod=~"[a-z0-9-]+-[0-9]+"}})', "ready")]),
    panel(5, "Backup age (worst)", "timeseries", 12, 8, 12, 4,
          [(f'time() - max by (namespace) (kube_job_status_completion_time{{job_name=~".*-backup-[0-9]+", {NSF}}})', "{{namespace}}")], unit="s"),
    panel(6, "Lost acknowledged writes", "stat", 0, 12, 24, 4,
          [(f'sum by (namespace) (db_canary_lost_acked_writes{{{NSF}}})', "{{namespace}}")]),
], [NS_VAR], "One row per instance: availability, lag, alerts, backups and lost writes.")

instance = dashboard("dbaas-instance", "MariaDB instance", [
    panel(1, "Canary write latency p99", "timeseries", 0, 0, 12, 8,
          [(f'histogram_quantile(0.99, sum by (le, namespace) (rate(db_canary_write_duration_seconds_bucket{{{NSF}}}[5m])))', "{{namespace}}")], unit="s"),
    panel(2, "Canary write rate", "timeseries", 12, 0, 12, 8,
          [(f'sum by (namespace, result) (rate(db_canary_write_total{{{NSF}}}[1m]))', "{{namespace}} {{result}}")], unit="ops"),
    panel(3, "Replica delay", "timeseries", 0, 8, 12, 8,
          [(f'max by (namespace) (db_canary_replica_delay_seconds{{{NSF}}})', "{{namespace}}")], unit="s"),
    panel(4, "Connections used", "timeseries", 12, 8, 12, 8,
          [(f'max by (namespace) (mysql_global_status_threads_connected{{{NSF}}}) / max by (namespace) (mysql_global_variables_max_connections{{{NSF}}})', "{{namespace}}")], unit="percentunit",
          desc="Needs the mysqld exporter (see docs/deviations.md, phase 8)."),
    panel(5, "Volume used", "timeseries", 0, 16, 12, 8,
          [(f'1 - (kubelet_volume_stats_available_bytes{{{NSF}}} / kubelet_volume_stats_capacity_bytes{{{NSF}}})', "{{persistentvolumeclaim}}")], unit="percentunit"),
    panel(6, "Pod restarts (1h)", "timeseries", 12, 16, 12, 8,
          [(f'sum by (pod) (increase(kube_pod_container_status_restarts_total{{{NSF}}}[1h]))', "{{pod}}")]),
    panel(7, "Instance Ready", "stat", 0, 24, 12, 4,
          [(f'max by (namespace) (dbaas_mariadb_ready{{ready_status="True", {NSF}}})', "{{namespace}}")]),
], [NS_VAR], "One instance: canary latency, replica delay, connections, volumes, restarts.")

maintenance = dashboard("dbaas-maintenance", "Maintenance", [
    panel(1, "Cordoned nodes", "timeseries", 0, 0, 12, 8,
          [('sum by (label_dbaas_local_node_class) (kube_node_spec_unschedulable)', "{{label_dbaas_local_node_class}}")]),
    panel(2, "Kubelet version per node", "table", 12, 0, 12, 8,
          [('kube_node_info', "{{node}}")]),
    panel(3, "Instances with a blocked drain", "timeseries", 0, 8, 12, 8,
          [('drain_guard_blocked_instances', "blocked")]),
    panel(4, "Evacuations and refused evictions", "timeseries", 12, 8, 12, 8,
          [('sum by (result) (rate(drain_guard_evacuations_total[5m]))', "{{result}}"),
           ('sum by (reason) (rate(drain_guard_evictions_denied_total[5m]))', "denied {{reason}}")], unit="ops"),
    panel(5, "Allowed disruptions per instance", "timeseries", 0, 16, 12, 8,
          [(f'kube_poddisruptionbudget_status_pod_disruptions_allowed{{namespace=~"db-.*"}}', "{{namespace}}")]),
    panel(6, "Canary write failures during maintenance", "timeseries", 12, 16, 12, 8,
          [(f'sum by (namespace) (increase(db_canary_write_total{{result="error",{NSF}}}[5m]))', "{{namespace}}")]),
], [NS_VAR], "Watch this during a rotation: cordons, kubelet versions, switchovers, refusals, canary failures.")

backup = dashboard("dbaas-backup", "Backup and recovery", [
    panel(1, "Backup age", "timeseries", 0, 0, 12, 8,
          [(f'time() - max by (namespace) (kube_job_status_completion_time{{job_name=~".*-backup-[0-9]+", {NSF}}})', "{{namespace}}")], unit="s"),
    panel(2, "Recoverable point age", "timeseries", 12, 0, 12, 8,
          [(f'time() - max by (namespace) (dbaas_pitr_last_recoverable_time_seconds{{{NSF}}})', "{{namespace}}")], unit="s"),
    panel(3, "Restore drill: last success age", "stat", 0, 8, 24, 4,
          [('time() - max(kube_cronjob_status_last_successful_time{namespace="dbaas-system", cronjob="db-restore-drill"})', "drill")], unit="s"),
], [NS_VAR], "Backups, binlog archive and the weekly restore drill.")

service = dashboard("dbaas-service", "Service level", [
    panel(1, "Write success ratio", "timeseries", 0, 0, 12, 8,
          [(f'sum by (namespace) (rate(db_canary_write_total{{result="ok",{NSF}}}[5m])) / sum by (namespace) (rate(db_canary_write_total{{{NSF}}}[5m]))', "{{namespace}}")], unit="percentunit"),
    panel(2, "Read success ratio", "timeseries", 12, 0, 12, 8,
          [(f'sum by (namespace) (rate(db_canary_read_total{{result="ok",{NSF}}}[5m])) / sum by (namespace) (rate(db_canary_read_total{{{NSF}}}[5m]))', "{{namespace}}")], unit="percentunit"),
    panel(3, "Error budget burn, 1h", "timeseries", 0, 8, 24, 8,
          [(f'(sum by (namespace) (rate(db_canary_write_total{{result="error",{NSF}}}[1h])) / clamp_min(sum by (namespace) (rate(db_canary_write_total{{{NSF}}}[1h])), 1e-9)) / 0.0005', "{{namespace}}")],
          desc="1 means the 99.95 percent objective is spent exactly at the pace it allows."),
], [NS_VAR], "Client-side availability and error budget per instance.")

DASHES = {"fleet.json": fleet, "instance.json": instance, "maintenance.json": maintenance,
          "backup.json": backup, "service.json": service}
os.makedirs(OUT, exist_ok=True)
for name, d in DASHES.items():
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
print("wrote", len(DASHES), "dashboards to", os.path.normpath(OUT))
