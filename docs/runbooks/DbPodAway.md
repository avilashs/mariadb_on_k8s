# DbPodAway

**Meaning.** A database pod has not been Ready for 20 minutes, longer than a drain cycle.

**Impact.** Redundancy is lost for longer than a normal maintenance.

**First three commands.**

1. `kubectl -n db-<name> describe pod <pod>`
2. `kubectl -n db-<name> logs <pod> -c mariadb --tail=100`
3. `kubectl get node <node>`

**Likely causes.**

- Node drained and the pod cannot be placed (see DbPodPending)
- Volume not attached
- Replica cannot catch up

**Fix.** A drained node that is back: uncordon it. A pod on a lost node: follow docs/operations.md, Non-graceful cases.

**Escalate when.** Redundancy has been lost for more than an hour.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
