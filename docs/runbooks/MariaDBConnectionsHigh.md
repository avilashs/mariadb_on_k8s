# MariaDBConnectionsHigh

**Meaning.** Connections are above 80 percent of max_connections.

**Impact.** Applications may be refused soon.

**First three commands.**

1. `kubectl -n db-<name> exec <pod> -c mariadb -- mariadb --ssl -uroot -e 'SHOW PROCESSLIST'`

**Likely causes.**

- Application pools too large
- Connection leaks

**Fix.** Ask the application team to check its pool size. Raising max_connections needs a memory check.

**Escalate when.** Above 95 percent for more than five minutes.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
