# MariaDBPrimaryDown

**Meaning.** The exporter cannot reach the primary for one minute.

**Impact.** Possible write failure; the canary shows what clients see.

**First three commands.**

1. `kubectl -n db-<name> get mariadb <name>`
2. `kubectl -n db-<name> get pods -o wide`
3. `kubectl -n db-<name> logs deploy/<name>-metrics --tail=20`

**Likely causes.**

- Primary pod down (failover)
- The exporter's own account or certificate is broken

**Fix.** If a failover is complete, the alert clears. If the exporter cannot reach the primary, check its account.

**Escalate when.** Primary unreachable for more than five minutes.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
