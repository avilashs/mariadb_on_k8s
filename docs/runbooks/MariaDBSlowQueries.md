# MariaDBSlowQueries

**Meaning.** The slow query rate is above the threshold for 15 minutes.

**Impact.** Latency for applications.

**First three commands.**

1. `kubectl -n db-<name> logs <pod> -c mariadb --tail=200 | grep -i 'query_time' `

**Likely causes.**

- A new query without an index
- Table growth

**Fix.** Find the statement in the slow log and fix the query or the index.

**Escalate when.** Not explained in one working day.

Dashboards and rule: see the labels of the alert; the rule is in `charts/db-alerts/rules/`.
