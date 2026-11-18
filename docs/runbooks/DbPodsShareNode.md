# DbPodsShareNode

**Meaning.** Two pods of one instance run on one node.

**Impact.** Anti-affinity is violated: one node failure takes two pods.

**First three commands.**

1. `kubectl -n db-<name> get pods -o wide`
2. `kubectl -n db-<name> get mariadb <name> -o jsonpath='{.spec.affinity}'`

**Likely causes.**

- The anti-affinity was removed from the MariaDB resource by hand
- Scheduling bypassed by a manual pod move

**Fix.** Restore the instance's spec from its chart (make instances-up). Move the pod off the node by deleting it, one at a time.

**Escalate when.** Always. This alert must never fire.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
