# DbErrorBudgetBurn

**Meaning.** Writes fail faster than the 99.95 percent objective allows, in both the fast and the short window.

**Impact.** The objective is being spent quickly.

**First three commands.**

1. `curl the canary /report of one pod (docs/operations.md, The canary)`
2. `kubectl -n db-<name> get events --sort-by=.lastTimestamp | tail -30`

**Likely causes.**

- A primary failover that keeps repeating
- Storage latency on the primary
- Connection exhaustion

**Fix.** Find the cause of the failed writes from the canary report and the events. Fix the cause, not the alert.

**Escalate when.** The budget is more than half spent in the window.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
