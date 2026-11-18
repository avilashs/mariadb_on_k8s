# MariaDBReplicationStopped

**Meaning.** A replica's I/O or SQL thread has stopped for five minutes.

**Impact.** The replica falls behind and cannot take the primary role safely.

**First three commands.**

1. `kubectl -n db-<name> exec <replica> -c mariadb -- mariadb --ssl -uroot -e 'SHOW SLAVE STATUS\G'`
2. `kubectl -n db-<name> logs <replica> -c mariadb --tail=100`

**Likely causes.**

- A conflicting write on the replica
- Lost connection to the primary (TLS or network)

**Fix.** Read Last_SQL_Error. After errorDurationThreshold the operator rebuilds the replica; to force it, follow docs/operations.md, Rebuild one replica.

**Escalate when.** Not recovered after the rebuild.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
