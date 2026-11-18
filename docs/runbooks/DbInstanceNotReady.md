# DbInstanceNotReady

**Meaning.** The MariaDB resource has not been Ready for ten minutes (critical at thirty).

**Impact.** Writes or redundancy may be lost.

**First three commands.**

1. `kubectl -n db-<name> get mariadb <name> -o yaml | tail -40`
2. `kubectl -n db-<name> get pods -o wide`
3. `kubectl -n mariadb-system logs deploy/mariadb-operator --tail=50`

**Likely causes.**

- Replica not Ready
- Failover in progress
- Operator unhealthy

**Fix.** Read the conditions of the MariaDB resource. The message names the step that is waiting.

**Escalate when.** Not Ready for 30 minutes.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
