# DbVolumeFillingUp

**Meaning.** A volume has under 20 percent free.

**Impact.** Writes fail when the disk is full.

**First three commands.**

1. `kubectl -n db-<name> get pvc`
2. `kubectl -n db-<name> exec <pod> -c mariadb -- df -h /var/lib/mysql`
3. `kubectl -n db-<name> get mariadb <name> -o jsonpath='{.spec.storage}'`

**Likely causes.**

- Binlog volume growth (binlog_expire_logs_seconds is 7 days)
- Data growth beyond plan
- Backup staging

**Fix.** Expand the volume (docs/operations.md, resize). Do not delete binlogs by hand: the archive depends on them.

**Escalate when.** Under 10 percent free, or a volume that cannot expand.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
