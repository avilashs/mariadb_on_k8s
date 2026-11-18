# DbReadUnavailable

**Meaning.** No canary read through the secondary Service for two minutes.

**Impact.** Readers cannot read from a replica.

**First three commands.**

1. `kubectl -n db-<name> get endpoints <name>-secondary`
2. `kubectl -n db-<name> get pods -l app.kubernetes.io/name=mariadb -o wide`
3. `kubectl -n db-<name> logs <pod> -c mariadb --tail=50`

**Likely causes.**

- No replica is Ready
- Replicas are not replicating and have fallen behind the readiness threshold
- Canary read account broken

**Fix.** Make a replica Ready: check its replication threads and its disk. A replica with an unrecoverable error is rebuilt after errorDurationThreshold.

**Escalate when.** Both replicas are down for more than 15 minutes.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
