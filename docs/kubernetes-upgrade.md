# Kubernetes upgrade procedure

PLAN.md section 9.4. One minor version at a time. Every step is a gate: the next one starts only when the
previous one passed.

1. **Choose the target.** One minor version above the current one. Read `docs/compat-matrix.md`. If a
   pinned operator does not support the target, upgrade that operator first, through this repository, with
   the full e2e suite (`make verify e2e`).
2. **Pre-flight.** `scripts/preflight.sh` with `TARGET_KUBERNETES=v1.xx.y` set. It checks the compatibility
   matrix and runs `pluto` over the rendered manifests (set `RENDERED_DIR` to the output of
   `make lint-platform`'s render). No removed API may remain.
3. **Control plane.** While the API server is unavailable, operators cannot fail over. Databases keep
   serving. Do not touch nodes in the same window.
4. **System pool.** The operators, drain-guard and the monitoring stack ride through on their own replicas
   and budgets. Upgrade it one node at a time.
5. **Database pool.** One node at a time, through `scripts/aks-rotate-pools.sh` (the same gates as a monthly
   rotation).
6. **Post-flight.** `scripts/postflight.sh <report>`. Attach the report to the change record.

If a step fails, stop. Do not start the next pool. The state is safe: every instance is either Ready with
one primary or waiting for its budget, and the post-flight report says which.
