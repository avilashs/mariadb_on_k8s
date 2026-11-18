# DbPodRestartLoop

**Meaning.** A database pod restarted more than three times in an hour.

**Impact.** Repeated restarts reduce redundancy and can end in data loss if they happen during a write.

**First three commands.**

1. `kubectl -n db-<name> get pod <pod> -o jsonpath='{.status.containerStatuses[*].lastState}'`
2. `kubectl -n db-<name> logs <pod> -c mariadb --previous --tail=100`

**Likely causes.**

- Out of memory (the limit equals the request)
- Corrupt redo or binlog after a crash
- Probe too strict on a slow start

**Fix.** Read the previous container's log. OOM: raise the size preset, do not raise the limit alone.

**Escalate when.** Crash loop continues after one change.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
