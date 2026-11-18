# MariaDBNoWritableServer

**Meaning.** No server of the instance accepts writes.

**Impact.** Writes fail.

**First three commands.**

1. `kubectl -n db-<name> get mariadb <name> -o jsonpath='{.status.conditions}'`
2. `kubectl -n db-<name> get pods`

**Likely causes.**

- Failover did not promote a replica
- read_only was set by hand

**Fix.** Follow the operator's status. Set the primary by patching spec.replication.primary.podIndex to a Ready replica.

**Escalate when.** Not writable after five minutes.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
