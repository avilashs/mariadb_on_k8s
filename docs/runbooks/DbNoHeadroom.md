# DbNoHeadroom

**Meaning.** A zone has fewer database nodes of a class than the capacity rule needs.

**Impact.** A rotation in that zone cannot place a displaced pod.

**First three commands.**

1. `kubectl get nodes -l dbaas.local/node-class=<class> -L topology.kubernetes.io/zone`
2. `az aks nodepool show (see docs/node-rotation.md)`

**Likely causes.**

- A pool was scaled down
- The VM size is not available in the zone

**Fix.** Scale the node pool of the zone up, or add a pool.

**Escalate when.** Not fixed before the next rotation.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
