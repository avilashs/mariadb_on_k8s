# Query optimizer

The platform runs the multi-LLM query optimizer ([avilashs/query_optimizer](https://github.com/avilashs/query_optimizer),
pinned by commit in `versions.yaml`) as an opt-in add-on of each instance. It finds the statements that cost the
most CPU, time or memory, asks several language models for an index or a rewrite, has a judge rank the answers,
and reports them. It can apply the winning index itself ("god mode"). On this platform that is **off** unless you
turn it on, and it is turned on in stages.

## What runs

For an instance that enables it, the helmfile adds one release, `<name>-qopt`, in the instance's namespace:

| Object | What it is |
|---|---|
| CronJob `<name>-query-optimizer` | Runs `qopt run` on a schedule (hourly by default). Never overlaps itself, is not retried blindly, runs as an unprivileged user on the system pool. |
| ConfigMap `<name>-query-optimizer` | The configuration, rendered from the chart values. It holds a `${QO_DB_PASSWORD}` placeholder, never a password. |
| PersistentVolumeClaim `<name>-query-optimizer-data` | The optimizer's state (audit log and de-duplication) and its reports under `reports/`. |

It connects to the instance's primary Service (`<name>-primary` for MariaDB, `<name>-rw` for PostgreSQL, the name the
server certificate covers), with the server verified against the instance's CA. It reads the primary because statement
statistics exist only on the server that ran the statements.

## Turn it on for an instance

In the instance file (`environments/<env>/instances/<name>.yaml`):

```yaml
queryOptimizer:
  enabled: true
  database: orders        # the database to analyse; default: the first entry of access.databases
  schedule: "17 * * * *"  # optional; any value of charts/db-query-optimizer/values.yaml can go here
```

`make instances-up` then:

1. creates the read-only account's Secret once (`<name>-qopt-credentials`, `scripts/ensure-secret.sh`);
2. creates the account: **MariaDB** `qopt_reader` with `SELECT` on `performance_schema` and on the named database and
   nothing else (`charts/db-access`, `readers`); **PostgreSQL** the managed role `qopt_reader` in the `pg_read_all_stats`
   and `pg_read_all_data` roles, with `pg_stat_statements` loaded and created in each database;
3. on MariaDB, turns on the statement history consumers (`performance_schema_consumer_events_statements_history` and
   `_history_long`) so real statements can be `EXPLAIN`ed. The digest table holds only the statement with `?` for values.
   On PostgreSQL, `shared_preload_libraries` changes, which is a rolling restart of the cluster;
4. deploys the CronJob.

Enabling it on a running MariaDB instance changes its configuration, so the operator rolls the pods one at a time.

## Models and keys

The default is the offline `mock` provider: it returns "no change", costs nothing and proves the wiring. For real
recommendations list real providers in the block (any provider of the optimizer: `anthropic`, `azure_foundry`, `openai`,
`gemini`, `cohere`, `grok`, `openai_compatible`):

```yaml
queryOptimizer:
  enabled: true
  llms:
    - {name: claude, provider: anthropic, api_key: "${ANTHROPIC_API_KEY}", model: claude-sonnet-5-5}
    - {name: foundry-gpt, provider: azure_foundry, endpoint: "${AZURE_AI_ENDPOINT}", api_key: "${AZURE_AI_API_KEY}", model: gpt-4o}
  ranker:
    strategy: llm
    llm: {name: judge, provider: anthropic, api_key: "${ANTHROPIC_API_KEY}", model: claude-sonnet-5-5}
  llmSecret: alpha-qopt-llm
```

The keys live in a Secret that you create by hand and never commit; the CronJob reads it as environment variables:

```bash
kubectl -n db-alpha create secret generic alpha-qopt-llm --from-literal=ANTHROPIC_API_KEY=...
```

`privacy.redact_literals` is **true** by default: string literals become `?` before a statement reaches any model, so
customer data in `WHERE` clauses is not sent out. The schema (table and column names) still is. Turn it off only if
that is acceptable for the instance.

## The staged rollout to god mode

Never skip a stage. The reader account physically cannot change anything, so stages 0 and 1 cannot hurt.

| Stage | `godMode` | `dryRun` | What it does | Move on when |
|---|---|---|---|---|
| 0 Smoke | false | | `mock` provider: the run works end to end | the CronJob completes |
| 1 Pilot | false | | real models; recommendations are only reported | a DBA has read a week of reports and judges them sensible |
| 2 Shadow | true | true | the whole decision path runs and nothing executes | the logged decisions match what the DBA would approve |
| 3 Live | true | false | winning indexes are created online, measured, and rolled back if they do not help | start with `apply.max_actions_per_run: 1` |

Stages 2 and 3 need a **second, writer account** with `INDEX` (MariaDB) or ownership of the tables (PostgreSQL). The
reader that the platform creates cannot do it by design; create the writer by hand, put its password in a Secret and
point `user` and `passwordSecret` at it for the instance only when you reach stage 2.

What god mode may do is limited by the optimizer itself: additive actions only (`create_index`, `analyze`,
`create_statistics`), never a lock or an unrecoverable option, only when the plan cost can be measured, at most
`max_actions_per_run` statements, and automatic rollback if the cost rises or the index goes unused. Rewrites are never
executed; they are reported for the application team.

## Reading the results

```bash
kubectl -n db-alpha get cronjob,jobs -l app.kubernetes.io/name=db-query-optimizer
kubectl -n db-alpha logs job/<job>                       # the console report
kubectl -n db-alpha create job --from=cronjob/alpha-query-optimizer try-now   # run it now
kubectl -n db-alpha exec <pod> -- qopt history -c /config/config.yaml        # the audit log (needs a running pod)
```

Reports are also written to the claim, under `reports/`, as JSON and markdown (`latest.*`). Add a `notifiers` entry
(`slack`, `teams`, `webhook`, `email`) to be told when something is found.

## Limits

* MariaDB's digest table has no CPU or memory columns, so "CPU" is wait time minus lock time and "memory" is a proxy
  built from temporary tables and sort rows (the optimizer's own note). The history consumers are what make a statement
  explainable; without them it is reported but never applied.
* A statement that the server cannot `EXPLAIN` (for example a normalized `$1` statement on PostgreSQL before 16) is
  reported and never applied.
* It reads the primary. On a very busy primary keep `collection.top_n` small and the schedule sparse.
* It is an add-on, not part of the platform's availability promise: a failed run does not affect any database.
