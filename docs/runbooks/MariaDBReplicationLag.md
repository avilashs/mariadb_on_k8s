# MariaDBReplicationLag

**Meaning.** A replica is more than 30 seconds behind.

**Impact.** Reads from that replica are stale.

**First three commands.**

1. `kubectl -n db-<name> exec <replica> -c mariadb -- mariadb --ssl -uroot -e 'SHOW SLAVE STATUS\G'`
2. `kubectl top pod -n db-<name>`

**Likely causes.**

- Slow disk on the replica
- A long transaction
- CPU throttling

**Fix.** Check the disk and the largest transactions. Parallel replication is on (slave_parallel_threads).

**Escalate when.** More than 5 minutes behind (critical).

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
