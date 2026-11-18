# Node rotation

The monthly rotation replaces the node image of every node, one pool at a time, while every
database keeps serving. The rules are in PLAN.md section 9. This page is the operator's guide.

## Node pools on AKS

One node pool per node class per availability zone. Pool names are 1 to 12 lowercase
alphanumerics, for example `pv2e8z1` (Premium SSD v2, zone 1) and `nvl8z1` (local NVMe, zone 1).

| Setting | Value | Why |
|---|---|---|
| Labels | `workload=database`, `dbaas.local/node-class=<class>`, `dbaas.local/storage-tier=<tier>` | Placement of database pods |
| Taint | `workload=database:NoSchedule` | Only database pods land here |
| Autoscaler | `balance-similar-node-groups` on | Keeps the zones level |
| Node image upgrade | `--node-image-only`, `--max-surge 1` | One new node per pool at a time |
| Undrainable nodes | `--undrainable-node-behavior Cordon` | A node that cannot drain is cordoned, not forced |
| Soak | `--node-soak-duration 5` (minutes) | Lets the rebuilt pod settle before the next node |
| Drain timeout | `--drain-timeout 60` (premium classes); longer on local NVMe than the largest re-seed | The default of 30 minutes is too short for local NVMe |
| Blocked nodes | `--max-blocked-nodes 1` (aks-preview extension only) | Stops after one blocked drain |
| Never | `--enable-force-upgrade`, spot pools for databases, stopping a cluster with local NVMe instances | Force bypasses the budgets; stopping loses every copy of local data |

Flags were checked against Microsoft Learn for the current CLI (`az aks nodepool upgrade`).
`--max-blocked-nodes` is in the `aks-preview` extension only, and it needs
`--undrainable-node-behavior` set.

### Worked example: create the pools of one zone

```bash
az aks nodepool add --resource-group "$RG" --cluster-name "$CLUSTER" \
  --name pv2e8z1 --zones 1 --node-vm-size "$PV2_VM" \
  --labels workload=database dbaas.local/node-class=<node-class> dbaas.local/storage-tier=premium-ssd-v2 \
  --node-taints workload=database:NoSchedule \
  --enable-cluster-autoscaler --min-count 1 --max-count 4 \
  --max-surge 1 --mode User
```

Replace the placeholders with the node class of `environments/<env>/platform.yaml`. The `local-nvme`
pool is created the same way, with its own VM size (one that has local NVMe) and the local-nvme tier label.
Re-check every flag against `az aks nodepool add --help` before use: the CLI changes.

## Monthly rotation

Two ways. The first is the default.

1. **Gated pipeline.** Node OS upgrade channel `None`. A monthly pipeline runs
   `scripts/preflight.sh`, then `scripts/aks-rotate-pools.sh <pool>...`, which upgrades one pool at
   a time and runs `scripts/postflight.sh` after each. Start with `--dry-run` to see the commands.
2. **AKS-managed.** Channel `NodeImage` with an `aksManagedNodeOSUpgradeSchedule` window, monthly, at least
   four hours, long enough for every database pool at one node at a time. A pre-flight job runs before
   the window and pages if it fails. The platform is safe without the gate; the gate only stops a rotation
   from starting on a degraded fleet.

## The capacity rule

> In every zone, a displaced database pod must find a schedulable node of its node class before its old
> node is gone.

With one pool per zone and surge 1, AKS adds the new node in the right zone first, so the rule holds as
long as the VM size can be allocated in that zone and the pool is below its autoscaler maximum. The
pre-flight checks that every class has at least two schedulable nodes in each zone. A pod that cannot be
placed shows as Pending and fires `DbPodPending`.

## Scripts

- `scripts/preflight.sh`: refuses to start unless every instance is Ready with one primary, budgets
  allow a disruption, both operators and drain-guard have two Ready replicas, the webhook answers, the
  replica delay is at most 5 s, the newest backup is under 26 h old, the archive is current, no database
  pod is Pending, the capacity rule holds, and no critical alert fires.
- `scripts/postflight.sh <report>`: repeats the checks that must hold afterwards, checks placement
  (distinct nodes, two or more zones per instance), and writes the canary numbers of the window to a JSON
  report. The report is the record of the change.
- `scripts/rotate-nodes.sh --classes ... [--system]`: the kind implementation. Pre-flight, nodes in order
  (those holding primaries last), cordon, plain drain (retried while the webhook is unavailable), replace,
  wait for every instance, post-flight. The NVMe volumes of evicted pods are discarded, as on a new node.
- `scripts/aks-rotate-pools.sh`: the AKS wrapper. Same gates around `az aks nodepool upgrade`.

## Local NVMe

A pod that moves to a new node on this tier comes back on an empty volume and re-seeds from the newest
backup, then catches up through GTID. Re-seed time depends on the data size: measure it per class in
staging (docs/rollout-checklist.md) and set the drain timeout above it. The pre-flight does not yet check
that an instance's volume request fits the node's NVMe capacity: AKS-only, and recorded in
docs/deviations.md.

## After a rotation

Read the post-flight report. Compare its longest write outage with the limits of PLAN.md section 7.3 and
keep the report with the change record. A planned switchover per instance should not exceed the number of
nodes in its class.
