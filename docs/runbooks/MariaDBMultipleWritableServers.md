# MariaDBMultipleWritableServers

**Meaning.** Two servers of one instance accept writes (split brain).

**Impact.** Data can diverge. Writes must stop.

**First three commands.**

1. `kubectl -n db-<name> get pods -o wide`
2. `kubectl -n db-<name> get mariadb <name> -o yaml`

**Likely causes.**

- A network partition during failover
- read_only changed by hand

**Fix.** Stop writes first (scale the application to zero). Decide which server holds the newest data with the canary and the binlog positions, then rebuild the others from backup.

**Escalate when.** Always.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
