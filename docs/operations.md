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
