# DbOperatorDown

**Meaning.** The MariaDB operator has no Ready replica.

**Impact.** No failover is possible while the operator is down. Databases keep serving.

**First three commands.**

1. `kubectl -n mariadb-system get pods`
2. `kubectl -n mariadb-system logs deploy/mariadb-operator --tail=50`

**Likely causes.**

- Webhook certificate expired
- Crash loop after an upgrade

**Fix.** Read the log. For a failed upgrade, roll back the operator (docs/kubernetes-upgrade.md).

**Escalate when.** Not Ready after 15 minutes.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
