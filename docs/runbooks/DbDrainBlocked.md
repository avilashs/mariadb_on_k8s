# DbDrainBlocked

**Meaning.** A draining node still holds a primary that cannot move: no replica can take the role.

**Impact.** The drain waits. A node rotation stops here.

**First three commands.**

1. `kubectl get events -A --field-selector reason=EvacuationBlocked`
2. `kubectl get nodes`
3. `kubectl -n db-<name> get pods -o wide`

**Likely causes.**

- Every other node of the class is cordoned or draining
- A replica is not Ready, so no candidate exists

**Fix.** Uncordon a node of the class, or make the replica Ready. The drain completes by itself once a candidate exists.

**Escalate when.** Blocked for 45 minutes (critical).

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
