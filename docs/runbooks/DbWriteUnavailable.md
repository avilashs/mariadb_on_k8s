# DbWriteUnavailable

**Meaning.** The canary has not had a successful write for over a minute.

**Impact.** Clients cannot write to the instance. This is client-visible.

**First three commands.**

1. `kubectl -n db-<name> get mariadb <name>`
2. `kubectl -n db-<name> get pods -o wide`
3. `kubectl -n db-<name> get endpoints <name>-primary`

**Likely causes.**

- Primary pod down or not Ready; failover in progress (normal for up to 60 seconds)
- Primary Service has no endpoint
- Canary cannot authenticate (its user or password changed)

**Fix.** If a failover is running, wait: it resolves within 60 seconds. If the primary is down and no new primary appears, read the MariaDB conditions and the operator log. For a canary auth error, check the canary logs and the Secret <name>-canary-credentials.

**Escalate when.** Not resolved in 10 minutes, or any lost acknowledged write.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
