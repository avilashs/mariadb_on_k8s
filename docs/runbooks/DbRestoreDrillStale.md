# DbRestoreDrillStale

**Meaning.** No successful restore drill in eight days.

**Impact.** Restores are not proven.

**First three commands.**

1. `kubectl -n dbaas-system get cronjob db-restore-drill`
2. `kubectl -n dbaas-system get jobs -l app.kubernetes.io/name=db-restore-drill`

**Likely causes.**

- The drill Job failed (see its log)
- The CronJob is suspended

**Fix.** Run make restore-drill NAME=<name> and read its output. Fix the failure it shows.

**Escalate when.** The drill fails for two weeks.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
