# Rollout checklist

PLAN.md phase 12. The agent prepared the platform; humans execute and sign off each gate. A gate is
passed only when its evidence is attached to the change record. Nothing here is passed in kind.

## 1. Staging values (human)

- [ ] `environments/staging/platform.yaml` filled in: the node class catalogue with the real VM sizes, the
      object store (`backupStore`), the alert receivers, the registry.
- [ ] Node pools created per `docs/node-rotation.md`, one per class per zone, with the labels and the taint.
- [ ] Image digests pinned in the environment (MariaDB `images`, PostgreSQL `images`, `drainGuard.image`,
      `CANARY_IMAGE`). No tag-only references in staging or production.
- [ ] Secrets: backup credentials and the receiver credentials come from the secret store, not from the repo.

## 2. Staging proofs that kind cannot give

- [ ] **Premium SSD v2:** a drained pod re-attaches its volume on another node in the same zone. Record the time.
- [ ] **Local NVMe:** a drained pod starts on an empty volume on another node and re-seeds by itself. Record
      minutes per 100 GB. This sets the drain timeout of that class.
- [ ] **Local NVMe:** find out whether an AKS node image upgrade keeps or wipes the NVMe data of a reimaged
      node. The design assumes it is wiped.
- [ ] **Local NVMe (PostgreSQL):** the claim annotation through `inheritedMetadata` reaches the volume claims,
      and CloudNativePG recovers an instance on an empty volume by itself.
- [ ] AKS's pre-upgrade budget validation accepts the budgets the operators create. CloudNativePG's primary
      budget allows zero disruptions by design, which must not block the upgrade.
- [ ] A real node image upgrade of one pool of each tier, with `scripts/preflight.sh` and
      `scripts/postflight.sh` around it, and `--undrainable-node-behavior Cordon` set.
- [ ] A restore drill on a production-sized data set (`make restore-drill`). Record the duration: it is the
      recovery time to promise.
- [ ] A load test at the expected peak while one node is drained. The canary report must stay within PLAN.md 7.3.
- [ ] A test alert reaches the real pager and the chat channel.
- [ ] The switchover stall found in kind (docs/deviations.md, phase 7): a replica behind in GTID, not in seconds,
      delayed a planned switchover for minutes. Reproduce at production load and decide the operator setting
      or the fix before production.
- [ ] The MariaDB exporter path (docs/deviations.md, phase 8): `mysql_up` reports 1 for every instance, and the
      replication and connection alerts see data.

- [~] PostgreSQL primary drain on real nodes (rehearsal 2 passed on AKS, evidence in docs/deviations.md; repeat in staging): `tests/e2e/drain.sh` case j equivalent. The drain-guard switchover
      happens before the pod is evicted and the canary stays within PLAN.md 7.3.
- [ ] Query optimizer (optional add-on): real model key in a Secret, stage 0-2 of `docs/query-optimizer.md` on one
      instance; god mode only after a reviewer has read the reports. On PostgreSQL confirm `pg_stat_statements` exists
      in the database after the first rolling restart (kind showed the Database object claiming it did while it did not).
- [ ] Run the e2e drain case for the drain-guard with two replicas during the AKS system-pool upgrade (a single
      replica fails the upgrade: the webhook is fail-closed).

## 3. Production

- [ ] Platform first, with the same pins as staging.
- [ ] One low-risk instance for two weeks, including one node rotation, before the rest.
- [ ] Then the remaining instances, in groups, each with its own restore drill passing first.

## 4. Review after the first production rotation

- [ ] Compare the post-flight report with PLAN.md 7.3. Adjust the limits or the sizing, and record the change
      in `docs/deviations.md`.
- [ ] Review the alert log of the rotation: no `critical` alert must have fired during a healthy drain.

## Sign-off

| Gate | Owner | Evidence (link) | Date |
|---|---|---|---|
| 1. Staging values | | | |
| 2. Staging proofs | | | |
| 3. Production, low-risk instance | | | |
| 4. First rotation review | | | |
