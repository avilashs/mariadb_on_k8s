# Stress test report: MariaDB `testdb` on AKS, 100 concurrent users

Run on 2026-11-22, Sweden Central, against the rehearsal cluster described in `docs/aks-rehearsal-report.md`.
Raw per-window output of every run is summarised below; the narrative rows are also in `docs/deviations.md`.

## 1. What was tested

| Item | Value |
|---|---|
| Database | MariaDB 11.8.9, one instance `testdb`: 1 primary + 2 replicas, one pod per zone, semi-sync replication, TLS required |
| Pod size | 3 CPU requested (no limit), 8 GiB memory, InnoDB buffer pool 2 GiB (preset `medium`, resources overridden) |
| Nodes / disks | Standard_D4s_v5 (4 vCPU, 16 GiB); data volume Premium SSD v2, 50 GiB; IOPS and throughput are stated per run |
| Settings that matter | `max_connections` 1500, `innodb_flush_log_at_trx_commit=1`, `sync_binlog=1`, `log_slave_updates` on, `slave_parallel_threads` varied (see section 5) |
| Load generator | `tools/loadgen` (Go, this repository): one pod in the cluster on the system node, one connection per simulated user, single-statement autocommit over TLS (certificate not verified), per-statement latency, per-interval windows |
| Data | table `lg_t`, 500,000 rows (about 130 MB: the working set fits in the buffer pool) |
| Workloads | read = `SELECT c ... WHERE id=?`; write = `UPDATE ... SET k=k+1 WHERE id=?`; mixed = 80% read, 20% write; keys uniformly random |
| Mode | closed loop (each user sends the next statement as soon as the last returns) unless marked open loop |
| Measurement | 5 to 10 s warm-up not counted, then 30 s to 10 min measured; p50, p95, p99 and max from every statement (no sampling) |
| Observed alongside | primary CPU and memory (`kubectl top`), `Threads_running`, aborted connects, replica `Seconds_Behind_Master`, and the platform's own canary (write outage, failed and lost writes) |

## 2. Headline result: 100 users, 10 minutes, mixed 80/20

| | Run 1 (4 apply threads) | Run 2 (16) | Run 3 (32) |
|---|---|---|---|
| Statements | 10,431,888 | 12,881,893 | 12,520,434 |
| Errors | 0 | 0 | 0 |
| Throughput | 17,386 QPS | 21,470 QPS | 20,867 QPS |
| p50 | 3.48 ms | 1.98 ms | 1.98 ms |
| p95 | 17.39 ms | 17.07 ms | 17.78 ms |
| p99 | 21.68 ms | 20.88 ms | 21.88 ms |
| Max | 61 ms | 208 ms | 363 ms |
| Canary: longest write outage / failed / lost | 1.03 s / 0 / 0 | 1.06 s / 0 / 0 | 1.03 s / 0 / 0 |
| Replica lag at the end | **998 s** (still growing) | **245 s** | **0 s** |

Stability: in the 20 half-minute windows of run 2, throughput stayed between 20.9k and 22.1k QPS and p95 between
16.5 and 17.5 ms; there was no drift, no error and no memory growth beyond the buffer pool filling (primary memory
0.5 GiB to 2.1 GiB, then 3.6 GiB in run 3 with a longer-lived buffer pool). `Threads_connected` stayed at 104 to 106
and `Aborted_connects` at 0 in every run. The primary used 3.5 to 3.8 cores of its 4: it is CPU bound at this load.
The throughput difference between run 1 and the other two is a warmer buffer pool and fresh pod, not the thread setting.

## 3. Write-only follow-up, 100 users, 3 minutes

| | Run 1 (4 threads) | Run 2 (16) | Run 3 (32) |
|---|---|---|---|
| Throughput | 8,969 QPS | 8,703 QPS | 9,148 QPS |
| p50 / p95 / p99 | 10.7 / 14.8 / 19.0 ms | 10.7 / 15.0 / 23.1 ms | 10.6 / 14.4 / 17.2 ms |
| Max | 1,065 ms (first window) | 459 ms | 194 ms |
| Errors / lost writes | 0 / 0 | 0 / 0 | 0 / 0 |
| Canary longest outage | 1.83 s | 1.06 s | 1.09 s |

The 10 to 15 ms write latency is the cost of a commit: semi-sync acknowledgement from a replica in another zone plus the
Premium SSD v2 fsync, both with `sync_binlog=1` and `innodb_flush_log_at_trx_commit=1`.

## 4. Concurrency curve (how many users)

Closed loop, 30 s measured, same instance and table size.

| Workload | Users | QPS | p50 | p95 | p99 | Peak Threads_running |
|---|---|---|---|---|---|---|
| Read | 100 | 21,639 | 4.4 ms | 6.4 ms | 9.8 ms | 7 |
| Read | 250 | 21,425 | 11.1 ms | 16.4 ms | 32.5 ms | 8 |
| Read | 500 | 20,662 | 21.7 ms | 40.0 ms | 121.7 ms | 14 |
| Read | 1,000 | 19,006 | 39.4 ms | 168.1 ms | 356.7 ms | 938 |
| Mixed | 100 | 17,659 | 3.3 ms | 17.4 ms | 21.4 ms | 36 |
| Mixed | 250 | 17,455 | 6.0 ms | 55.9 ms | 66.6 ms | 157 |
| Mixed | 500 | 16,274 | 8.0 ms | 134.0 ms | 160.9 ms | 419 |
| Mixed | 1,000 | 15,542 | 10.1 ms | 299.0 ms | 325.1 ms | 936 |
| Write | 100 | 9,352 | 10.5 ms | 14.0 ms | 16.9 ms | 96 |
| Write | 250 | 11,174 | 21.9 ms | 30.1 ms | 36.6 ms | 236 |
| Write | 500 | 11,039 | 44.2 ms | 59.8 ms | 77.5 ms | 459 |
| Write | 1,000 | 11,151 | 88.3 ms | 111.9 ms | 130.2 ms | 1,003 |

Zero errors and zero refused connections at every level (peak `Threads_connected` 1,008 of 1,500). Throughput is
flat from about 100 users upward, so latency grows in proportion to users (Little's law): more connections only
queue. A pooler in front is the lever, not a bigger `max_connections`. This test needed the application user's cap
raised from 100 to 1,500 and 8 GiB of memory; memory use stayed below 2 GiB at 1,000 connections.

Lower-concurrency baseline on the smaller preset (3 pods, 100,000 rows): reads 9.7k QPS at 8 users and 29.1k at 32 users
(p95 0.97 and 1.52 ms); writes 1.3k and 4.2k QPS (p95 7.8 and 9.5 ms); mixed 4.2k and 14.2k QPS (p95 6.7 and 8.2 ms).
Open loop (latency counted from the scheduled start, no coordinated omission), mixed, 32 users: 2,000 per second
p95 6.5 ms, 5,000 per second p95 7.3 ms, p99 12.6 ms.

## 5. The defect the stress test found: replicas fall behind

During run 1 both replicas fell further behind every second while the primary stayed healthy.

| Minutes into the run | Replica lag, 4 threads (run 1) | 16 threads (run 2) | 32 threads (run 3) |
|---|---|---|---|
| 0.5 | 327 s (left from preparing the table) | 7 to 9 s | 0 s |
| 3 | 405 s | 51 to 71 s | 0 s |
| 6 | 599 s | 119 to 164 s | 0 s |
| 9 | 792 s | 165 to 235 s | 0 s |
| 13 | 998 s | 245 s | 0 s (mixed phase) |

Run 1's lag did not fall after the load stopped: it still grew about 0.93 s per second for minutes, and needed about 27
minutes to reach 0 once the thread count was raised. Why:
- The four replication workers all sat in `Commit` (replica commits are synced twice, redo log and binary log). The
  primary groups its commits under 100 users; the replica applies with only four parallel workers.
- Semi-sync only waits until a replica has *received* the transaction, so the primary was never slowed down by it.

Isolating the cause (3-minute mixed runs at 100 users):

| Apply threads | Data disk | Result |
|---|---|---|
| 32 | 3,000 IOPS / 125 MB/s (default) | lag 0 s (run interrupted at 1.5 minutes by a dropped connection: indicative) |
| 32 | 10,000 IOPS / 250 MB/s | lag 0 s, 16.5k QPS, p95 18.4 ms |
| 4 | 10,000 IOPS / 250 MB/s | lag grows about 0.75 s per second (161 s after 3 minutes) |

The thread count is the lever; faster disks did not help and did not change primary throughput. The instance chart
default `slave_parallel_threads` is now 32.

With 32 threads, the write-only phase (about 9,000 writes per second) still pushed lag to 65 s (testdb-1) and 81 s
(testdb-2) after 3 minutes, about 0.4 s per second, and it fell back to 9 to 12 s within 30 s of the load stopping. A
sustained pure-write load above about 5,000 writes per second therefore outruns the replicas even at 32 threads.

## 6. What this does and does not show

Shown: the primary sustains 100 users for 10 minutes without errors, drift or connection problems; 1,000 connections
are accepted and served; the canary saw no failed and no lost write in any run; replica lag is controllable and
the cause is understood and fixed in the chart.

Not shown, and needed before relying on these numbers:
- Behaviour during a failover or a node drain **under** this load (the drain suite and the 1.37 upgrade ran at
  low load; the earlier "switchover stall" must be re-run with the new default, see `docs/rollout-checklist.md`).
- Reads sent to replicas (all load went to the primary), and read-your-writes with replica lag.
- A dataset larger than memory (500,000 rows fit in the buffer pool; real workloads will hit the disk).
- A separate load node: the load pod shared a 4-vCPU system node with other pods, so the highest rates (1,000 users)
  may be slightly client-limited. No load-generator error or timeout was observed.
- Skewed or hot-key access, long transactions, large rows and secondary indexes (all statements are single-row by key).
- TLS with certificate verification (the generator skips verification, the server requires TLS).
- Another VM size, another storage tier, or the PostgreSQL instance (`ledger`).
- Percentiles beyond p99, and run-to-run variance (each configuration ran once).

## 7. Recommendations

1. Keep `slave_parallel_threads` at 32 (chart default) and alert on replica lag; treat sustained lag growth as an incident.
2. Put a pooler (ProxySQL or MaxScale) in front for many-connection clients; size on running threads, not connections.
3. For write-heavy workloads above about 5,000 writes per second, test, one at a time, more apply threads, a wider
   group commit on the primary (`binlog_commit_wait_count`), relaxed durability on replicas only
   (`sync_binlog`, `innodb_flush_log_at_trx_commit=2`), or more CPU.
4. Return the data disks to 3,000 IOPS / 125 MB/s: 10,000 IOPS made no difference and costs about 0.17 USD per hour.
5. Repeat this test in staging on the target VM size, with a larger-than-memory dataset, a separate load node, and
   a node drain and a switchover during the run. Add it to the rollout checklist as a gate.

## 8. How to repeat it

```bash
cd tools && CGO_ENABLED=0 go build -o loadgen ./loadgen
# in a pod labelled dbaas.local/instance=<instance> (the isolation policy admits that label), PW set to the password:
./loadgen -host <instance>-primary -user <user> -db <db> -rows 500000 -prepare -clients 4 -duration 2s
./loadgen -host <instance>-primary -user <user> -db <db> -rows 500000 -clients 100 -duration 10m -warmup 10s -workload mixed -interval 30s
```
Use `-rate N` for open loop. The application user's `maxUserConnections` and the instance's `max_connections` must be
at least the number of users.
