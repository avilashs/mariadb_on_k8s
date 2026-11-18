# DrainGuardDown

**Meaning.** drain-guard has no Ready replica.

**Impact.** Evictions of database pods are refused, so drains stop. Nothing is harmed, but maintenance halts.

**First three commands.**

1. `kubectl -n dbaas-system get pods -l app.kubernetes.io/name=drain-guard`
2. `kubectl -n dbaas-system logs deploy/drain-guard --tail=50`
3. `kubectl -n dbaas-system get certificate drain-guard-tls`

**Likely causes.**

- Certificate not issued (cert-manager)
- Leader lease cannot be acquired
- Image pull failure

**Fix.** Fix the cause shown by the logs. Restart the Deployment if the pods are stuck.

**Escalate when.** Not Ready after 15 minutes.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
