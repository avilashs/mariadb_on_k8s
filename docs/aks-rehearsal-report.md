# AKS rehearsal 2: cluster, nodes, disks, cost and performance

Measured on 2026-11-21 and 2026-11-22 in Sweden Central. Numbers come from the Azure resource APIs (cluster,
pools, disks), Azure's public retail price list (prices.azure.com) and the load tests recorded in
`docs/deviations.md`. Costs are list prices times measured uptime, **not** a bill: Cost Management lags by
many hours and was not queried. Items marked (assumed) had no price in the list lookup.

## 1. Cluster

| Item | Value |
|---|---|
| Region / zones | Sweden Central, zones 1, 2, 3 |
| AKS tier / version | Free tier (no uptime SLA), Kubernetes 1.36.5 (an earlier rehearsal also upgraded to 1.37.1) |
| Network | Azure CNI overlay, Cilium dataplane and network policy, Standard load balancer |
| Registry | Azure Container Registry, Basic, private, pull secret in the namespaces |
| Workloads | Platform (cert-manager, mariadb-operator, CloudNativePG, Barman plugin, drain-guard, test object store, monitoring) plus one MariaDB instance, `testdb` (3 pods) |
| Public endpoint | Standard static public IP + load balancer service on port 3306, source-restricted to one /32, TLS required |

## 2. Node pools

| Pool | Role | VM size | vCPU / RAM | Count | Zone | OS disk | Autoscaler |
|---|---|---|---|---|---|---|---|
| `sys` | system | Standard_D4s_v5 | 4 / 16 GiB | 1 | 1 | 64 GiB managed | off |
| `pv2d4z1` | database | Standard_D4s_v5 | 4 / 16 GiB | 1 | 1 | 64 GiB managed | on (1 to 2) |
| `pv2d4z2` | database | Standard_D4s_v5 | 4 / 16 GiB | 1 | 2 | 64 GiB managed | on (1 to 2) |
| `pv2d4z3` | database | Standard_D4s_v5 | 4 / 16 GiB | 1 | 3 | 64 GiB managed | on (1 to 2) |

Database pools are labelled `dbaas.local/node-class=aks-pv2` and tainted `workload=database:NoSchedule`; the
subscription's 20 vCPU regional quota allows five D4s_v5 at most, which is why each pool is capped at one node plus one
surge node. Local-NVMe (L-series) shapes start at 8 vCPU and did not fit; the tier is deferred to the next release.

## 3. Disks

| Disk | Type | Size | IOPS / MB/s now | Baseline included | Attached to |
|---|---|---|---|---|---|
| 3 data volumes (`storage-testdb-0/1/2`) | Premium SSD v2, LRS, one per zone | 50 GiB each | 10,000 / 250 (raised for a test) | 3,000 / 125 | MariaDB pods |
| 4 OS disks | managed, in the scale sets | 64 GiB each | default | n/a | nodes |

Premium SSD v2 bills capacity, IOPS above 3,000 and throughput above 125 MB/s separately. The raise to 10,000 IOPS did
not change primary throughput (17.4k QPS mixed at both settings) and did not fix replica lag (see section 5), so it
should go back to the default.

## 4. Cost

List prices, Sweden Central: Standard_D4s_v5 0.204 USD/h; Premium SSD v2 capacity 0.00011 USD/GiB/h, IOPS 0.000007 USD
per IOPS/h above 3,000, throughput 0.000055 USD per MB/s/h above 125; ACR Basic 0.1666 USD/day. Assumed: OS disk P6
about 0.0132 USD/h, Standard load balancer 0.025 USD/h, Standard public IPv4 0.005 USD/h each (two exist: outbound and
the database endpoint). The AKS Free tier has no cluster fee. No Traffic Manager profile was created.

**Spent so far (28.7 hours up at 17:59 UTC on 22 Nov): about 24 USD.**

| Component | Hours / basis | Cost |
|---|---|---|
| 4 VMs (104.2 VM-hours) | 28.7 h, 28.7 h, 23.4 h, 23.4 h | 21.25 |
| 4 OS disks | same hours | 1.38 |
| 3 data volumes, capacity | 13.7 h | 0.23 |
| IOPS and throughput uplift | about 1 h at 10,000 / 250 | 0.17 |
| Load balancer, 2 public IPs, ACR | 28.7 h | 1.21 |
| **Total** | | **about 24.2** |

An earlier statement in this session that the cluster had run "about 13 hours" was wrong: the sandbox clock pauses
between turns, the scale-set creation times say 28.7 hours.

**Run rate now: 1.10 USD/h, 26 USD/day, about 800 USD/month.** With the data disks back at the 3,000 / 125 baseline:
0.93 USD/h, about 680 USD/month. The VMs are 75% of it.

| Lever | Saving |
|---|---|
| Delete the resource group when done | stops all of it (first priority) |
| Data disks back to baseline IOPS | 0.17 USD/h |
| Stop the cluster when idle (compute stops; disks and IPs still bill) | about 0.82 USD/h |
| 3-year reservation for the 4 VMs (2,118 USD per VM) | 0.82 to 0.32 USD/h (about 60%) |
| 1-year reservation (1,103 USD per VM) | 0.82 to 0.50 USD/h (about 38%) |
| System node as D2s_v5 | about 0.10 USD/h (check platform memory first) |
| Run `replicas: 1` (two pods) where the workload allows | one node, 0.20 USD/h, less HA |

## 5. Performance (`testdb`: MariaDB 11.8.9, 3 pods in 3 zones, semi-sync, TLS, 3 CPU / 8 GiB each)

Load from one pod in the cluster over TLS (`tools/loadgen`, closed loop, 500k-row table).

| Test | Result |
|---|---|
| Point reads, 100 clients | 21.6k QPS, p95 6.4 ms |
| Point reads, 1,000 clients | 19.0k QPS, p95 168 ms (queueing; CPU bound at about 3.6 cores) |
| Mixed 80/20, 100 clients, 10 min | 17.4k to 21.5k QPS, p50 2 to 3.5 ms, p95 17 ms, p99 21 ms, 0 errors in 10 to 13 M statements, flat for 10 minutes |
| Write only, 100 clients | 8.7k to 9.1k QPS, p95 14 to 15 ms |
| 1,000 connections | no errors, no refused connections, memory under 2 GiB, but latency is queueing |
| Canary during all runs | longest write outage 1.0 to 1.8 s, 0 failed and 0 lost writes |
| Replica lag, 4 apply threads | grew to 1,031 s in 14 minutes and kept growing after the load stopped (bug) |
| Replica lag, 16 threads | still grew, to 245 s after 13 minutes |
| Replica lag, 32 threads (now the chart default) | 0 s through the mixed load; 65 to 81 s after 3 minutes of pure writes (about 9k writes/s) |

Findings behind these numbers: backups were blocked by the isolation policy under Cilium (fixed), and the
disk IOPS were not the replica bottleneck, the apply thread count was.

## 6. Performance per cost

Database tier only (3 database nodes + 3 data volumes), at list prices, steady use of the primary:

| Workload | Rate | Cost per million statements, disks at 10k IOPS | disks at baseline |
|---|---|---|---|
| Point reads | 21.6k QPS | 0.0102 USD | 0.0081 USD |
| Mixed 80/20 | 21k QPS | 0.0105 USD | 0.0083 USD |
| Writes | 9k QPS | 0.0246 USD | 0.0194 USD |

Reading it:
- The whole load ran on the primary. The two replicas, which cost two thirds of the database tier, served no
  traffic. That is the price of zone-level high availability with semi-sync (no lost acknowledged writes in the
  canary), not wasted spend, but it means the cost per query halves if reads are sent to the replicas (not tested here).
- A connection pooler in front, not more connections, is the lever for 1,000 concurrent users.
- The cheapest real saving is lifecycle: this rehearsal costs 26 USD per day and should exist only while testing.
- These are rehearsal numbers for the `small` to `medium` presets on D4s_v5; they are not a sizing for production.
  Staging (docs/rollout-checklist.md) must repeat the load test on the target VM size.

## 7. Monthly cost against Azure Database for MySQL Flexible Server

730 hours per month, Sweden Central, list prices from prices.azure.com, pay-as-you-go unless marked. Excluded on both
sides: network egress, monitoring ingestion, backup storage beyond the free allowance, support plans and the
engineering time to run it. The Flexible Server size is the nearest match to the tested primary:
General Purpose Ddsv5, 4 vCore, 16 GiB, 50 GiB storage, 0.09 USD per vCore-hour, storage 0.137 USD/GiB/month
(0.274 zone-redundant). It is MySQL, not MariaDB. Its performance was **not** measured here.

| Option | Per month |
|---|---|
| This rehearsal as it runs now (4 nodes, data disks at 10,000 IOPS) | 799 |
| Same, data disks at the default 3,000 IOPS | 677 |
| Database tier only: 3 database nodes + 3 volumes (one instance) | 488 |
| Production-style AKS: 3 database nodes, 2 system nodes (D2s_v5), AKS Standard SLA, load balancer, IPs, registry | 760 |
| The same with 3-year VM reservations | 399 |
| The same with 1-year VM reservations | 532 |
| Flexible Server, single zone, no HA | 270 |
| Flexible Server, zone-redundant HA (primary + standby) | 539 |
| Flexible Server, HA + 1 read replica | 809 |
| Flexible Server, HA + 2 read replicas | 1,079 |
| Flexible Server HA, 3-year reservation | 213 |
| Flexible Server HA + 2 read replicas, 3-year reservation | 427 |

How the two compare:
- One instance: Flexible Server with HA (539) is cheaper than production-style AKS (760), and it includes patching,
  backups, point in time recovery and the HA SLA. Our topology (one primary, two readable replicas) matches
  "HA + 2 read replicas" (1,079), where AKS is cheaper.
- Each further 4-vCore instance needs three more database nodes on AKS (about 488 pay-as-you-go, about 218 with
  3-year reservations) against about 539 (213 reserved) per Flexible Server. At that size the two are within a few
  percent of each other: the platform's cost advantage appears only when instances are smaller than a node (several
  small instances sharing nodes) or when the fixed AKS overhead is spread over many instances.
- Flexible Server charges for IOPS above the free allowance (0.06 USD per IOPS per month: 3,000 IOPS on 50 GiB is
  about 158 USD); Premium SSD v2 includes 3,000 IOPS and 125 MB/s.
- MariaDB: Flexible Server does not offer it. Moving to it means MySQL compatibility work.
