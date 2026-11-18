# MariaDBSemiSyncOff

**Meaning.** The primary has run without semi-sync for 10 minutes.

**Impact.** A failover now could lose acknowledged writes.

**First three commands.**

1. `kubectl -n db-<name> exec <primary> -c mariadb -- mariadb --ssl -uroot -e "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_master_status'"`

**Likely causes.**

- No replica is connected (semi-sync needs one)
- Ack timeout reached and semi-sync fell back

**Fix.** Restore the replicas first. Semi-sync resumes when a replica acknowledges.

**Escalate when.** Off for more than 30 minutes.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
