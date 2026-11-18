# DbLogArchiveStalled

**Meaning.** The binlog archive is more than two hours behind.

**Impact.** Point in time recovery cannot reach the newest changes.

**First three commands.**

1. `kubectl -n db-<name> get pointintimerecovery <name> -o yaml`
2. `kubectl -n db-<name> logs <primary> -c agent --tail=50`

**Likely causes.**

- The object store refuses the upload
- Credentials rotated and not copied

**Fix.** Fix the upload path. Binlogs are kept seven days locally, so the gap can still be closed.

**Escalate when.** Stalled for more than one day.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
