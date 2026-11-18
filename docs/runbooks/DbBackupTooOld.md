# DbBackupTooOld

**Meaning.** The newest backup of an instance is older than 26 hours.

**Impact.** Point in time recovery rests on an old base backup.

**First three commands.**

1. `kubectl -n db-<name> get physicalbackup`
2. `kubectl -n db-<name> get cronjob <name>-backup -o wide`
3. `kubectl -n db-<name> get jobs | grep backup`

**Likely causes.**

- The backup Job cannot be scheduled (tolerations or capacity)
- The object store refuses the upload
- Credentials were rotated and the copy is stale

**Fix.** Trigger one by hand (docs/operations.md, Change the backup schedule). Check its Job and the object store.

**Escalate when.** Still old after two manual attempts.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
