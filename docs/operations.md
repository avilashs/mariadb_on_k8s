# Operations

Procedures for running the platform and its instances. Every step below is a
change to files in `environments/<env>/` followed by a sync, or a documented
two-step removal. Nothing is changed by hand in the cluster.

## Instance lifecycle

An instance is a file: `environments/<env>/instances/<name>.yaml`.

| Task | Steps |
|---|---|
| Create | `ENV=<env> make instance-new NAME=<name> ENGINE=mariadb SIZE=small NODE_CLASS=<class>`, then review the file, then `ENV=<env> make instances-up`. The new file is validated before it is written. |
| Change size, replicas or databases | Edit the file, then `ENV=<env> make instances-up`. |
| Validate without syncing | `make lint-instances`. |
| Remove | Step one: delete the file, then `ENV=<env> make instances-up`. This leaves the instance in place: its MariaDB resource, volumes and data are untouched. Step two: `ENV=<env> make instance-remove NAME=<name>`. It refuses to run while the file exists. |

Deleting a file never deletes an instance on its own. Helmfile does not remove a
release it no longer sees, and the MariaDB resource carries the
`helm.sh/resource-policy: keep` annotation, so `helm uninstall` keeps it too. The
two steps are the only path to removal, and they are deliberate.

## Scaling

Changing `replicas` rolls the instance one pod at a time. A new replica is seeded
from a backup. Scale-out of a replication topology therefore needs the backup
datasource, which phase 5 provides. Until then the operator refuses to add
replicas.

## Application accounts and root

Applications connect as their own user, never as `root`. The root password is in
`<instance>-root`, for operators only.

MariaDB has no `super_read_only`. An account with SUPER, including `root`, can
write to a replica even though the replica reports `read_only`. Application
accounts are refused on replicas with `ERROR 1290 ... read-only`.

See `docs/app-developer-guide.md` for the client side.

## Passwords

The platform creates each credential once, with a random value, and never
overwrites it:

- `scripts/ensure-secret.sh` creates `<instance>-<owner>-credentials` and the
  Grafana admin Secret.
- The operator creates `<instance>-root`.

Rotation is a deliberate action: delete the Secret and sync, or change the
password through the database. Changing a value in a file does nothing.

## Platform upgrades

Upgrade one component at a time, with the e2e suites green before and after. See
`docs/compat-matrix.md` for the versions each component supports. The operator is
upgraded one release at a time, never skipping one.

## Admission

The `dbaas-mariadb-guarantees` ValidatingAdmissionPolicy applies to every namespace
labelled `dbaas.local/managed=true`. It refuses a MariaDB that does not run
replication, has fewer than two pods, or has no required anti-affinity per node.
It runs in the API server, so it also applies to a resource applied with kubectl.

## Backups and restore

Every instance with `backup.enabled: true` gets three objects (`charts/mariadb-instance/templates/backup.yaml`):
a scheduled `PhysicalBackup` (`<name>-backup`), a suspended one that names where replicas restore from
(`<name>-backup-template`), and a `PointInTimeRecovery` (`<name>`) that archives binary logs. Backups and
binlogs go to the bucket in `catalogue.backupStore` (platform file), under `<name>/physical/` and
`<name>/binlog/`. The bucket credentials are copied into the instance namespace as `dbaas-backup-store` by
`scripts/ensure-backup-credentials.sh`, which `make instances-up` runs. The copy is never overwritten.

Backups are required on the `local-nvme` tier: a pod that moves to a new node comes back empty and rebuilds
itself from the newest backup, then catches up through GTID.

Recovery objective, as measured by the e2e suites on kind (not a production promise): replicas rebuild
automatically; point in time restore reaches any time up to the archive's newest position. That position
trails the present by at most `backup.binlogFlushMinutes` (5 by default) plus the operator agent's fixed
10 minute archive cycle, so about 15 minutes. Why: the agent archives only CLOSED binary logs and never
closes the active one, so a CronJob (`<name>-binlog-flush`, as a role that holds only `RELOAD`) closes it
on the schedule. `backup.binlogArchiveTimeout` is only the longest one archival run may take, not a
cadence. Archival is also skipped while the instance is switching primary, updating or recovering a
replica, so the position can pause during a rotation or a drain. A production promise comes from
`make restore-drill` on a production-sized data set (phase 12 gate).

### Check that backups are current

```bash
kubectl -n db-<name> get physicalbackup,pointintimerecovery
kubectl -n db-<name> get pointintimerecovery <name> -o jsonpath='{.status.lastRecoverableTime}{"\n"}'
```

`lastRecoverableTime` should be within about 15 minutes of now (see the recovery objective above). A stale
value means the binlog archive is stuck, or the flush job is not running (`kubectl -n db-<name> get cronjob,jobs`);
the `DbLogArchiveStalled` alert (phase 8) fires after two hours.

### Restore to a point in time

```bash
scripts/restore-instance.sh <name> 2026-11-18T10:15:00Z <name>-restore
```

The script waits until the archive covers the target time, then creates `<name>-restore` in the same
namespace from the source object (same image, storage class, node class; two replicas) and waits for Ready.
It refuses a future time. The restored instance has no backups of its own and never writes to the source's
prefixes. Check the data, then either promote it (move the application's connection, which is an
application change, not a platform one) or delete it:

```bash
kubectl -n db-<name> delete mariadb <name>-restore
kubectl -n db-<name> delete pvc -l app.kubernetes.io/instance=<name>-restore
kubectl -n db-<name> delete secret <name>-restore-root
```

### Rebuild one replica

Normally nothing is needed: a replica with an error it cannot fix recovers after `errorDurationThreshold` (5 minutes).
To force it, delete its volume claim and its pod. The operator restores the newest backup into a new volume and
the replica catches up. Delete the claim first, or the pod comes back on the old volume.

```bash
pod=<name>-1                                   # never the current primary
pvc=$(kubectl -n db-<name> get pod "$pod" -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}')
kubectl -n db-<name> delete pvc "$pvc" --wait=false
kubectl -n db-<name> delete pod "$pod"
```

### Change the backup schedule or retention

Edit `backup.schedule` (cron, UTC) or `backup.retention` in the instance file, then `make instances-up`.
Changing the schedule does not start a backup; to take one now, change `schedule.onDemand` on
`<name>-backup` to a value no backup has used:

```bash
kubectl -n db-<name> patch physicalbackup <name>-backup --type merge \
  -p "{\"spec\":{\"schedule\":{\"onDemand\":\"manual-$(date +%s)\"}}}"
```

### Restore drill

`make restore-drill NAME=<name> [TIME=<RFC 3339 UTC>]` restores to `TIME` (default: the newest recoverable time)
into `<name>-drill`, counts the rows of the marker table `dbaas_drill.marker`, deletes the throwaway and exits 0.
A failed drill leaves the throwaway in place. The weekly CronJob `db-restore-drill` in `dbaas-system` runs the same
check for every instance with point in time recovery; its last successful run is what the `DbRestoreDrillStale`
alert watches. The marker table is created by the application team that owns the instance.

### Rotate the backup credentials

Rotate in the object store first, then replace the copy in each instance namespace and let the next backup use it:

```bash
kubectl -n db-<name> delete secret dbaas-backup-store
scripts/ensure-backup-credentials.sh <context> db-<name> environments/<env>/platform.yaml
```

The operator reads the Secret when a Job starts; a running backup keeps the old values until it ends.

## The canary

Every instance has a `<name>-canary` Deployment (two pods, on the `system` pool) that writes one row per second
through `<name>-primary` and reads the newest row through `<name>-secondary`. It uses its own least-privilege
account, `canary`, which can use only the `dbaas_canary` database. It measures what a client sees; it has no
failover logic of its own. The image is `dbaas/db-canary` (`tools/db-canary`).

Read the numbers of one canary pod (port-forward; the image has no shell):

```bash
kubectl -n db-<name> port-forward pod/<name>-canary-<hash> 18080:8080 &
curl -s localhost:18080/report | jq .
```

`longest_write_outage_seconds` is the longest gap between two acknowledged writes since the last reset. Normal
operation shows about one second. `lost_acknowledged_writes` must be zero; anything else is a data-loss incident.
`POST /reset` starts a new measurement window (`curl -X POST localhost:18080/reset`).

Metrics for Prometheus are `db_canary_*`, listed in `docs/architecture.md` and used by the alerts of phase 8.
