# DbCertificateExpiring

**Meaning.** A certificate expires within 14 days and was not renewed.

**Impact.** A connection or webhook will fail when it expires.

**First three commands.**

1. `kubectl get certificates -A`
2. `kubectl describe certificate <name> -n <ns>`

**Likely causes.**

- The Issuer cannot sign
- cert-manager is down

**Fix.** Read the Certificate's conditions and its Issuer. Fix the issuer, the renewal follows.

**Escalate when.** Within 3 days and not renewed.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
