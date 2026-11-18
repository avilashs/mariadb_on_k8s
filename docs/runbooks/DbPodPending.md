# DbPodPending

**Meaning.** A database pod cannot be scheduled for ten minutes.

**Impact.** The instance has less redundancy, or none.

**First three commands.**

1. `kubectl -n db-<name> describe pod <pod> | tail -20`
2. `kubectl get nodes -l dbaas.local/node-class=<class> -o wide`
3. `kubectl get nodes -l dbaas.local/node-class=<class> -o jsonpath='{range .items[*]}{.metadata.name} {.spec.unschedulable}{"\n"}{end}'`

**Likely causes.**

- Not enough nodes of the class in the zone (anti-affinity)
- Nodes cordoned during a rotation
- Node class VM size cannot be allocated in the zone

**Fix.** Uncordon nodes that are free, or add capacity in the zone. The rotation capacity rule (docs/node-rotation.md) explains what must exist.

**Escalate when.** Pending for 30 minutes (this is then critical).

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
