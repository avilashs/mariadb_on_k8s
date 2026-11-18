# Connecting an application to a database instance

Each database instance has two stable endpoints. Use them; never a pod name.

| Endpoint | Host (inside the cluster) | Use for |
|---|---|---|
| Primary | `<instance>-primary.db-<instance>.svc` | every write, and reads that must see the latest data |
| Secondary | `<instance>-secondary.db-<instance>.svc` | reads that may lag the primary slightly |

The port is 3306. The operator moves these Services when the primary changes, so
a failover needs no change in the application. A failover does close the
connections to the old primary, so the application must reconnect.

## Requirements every client must meet

- **TLS.** The server refuses plain connections. Use TLS with the server
  certificate the operator issues. Certificate verification is strongly
  recommended; the operator's CA is in the `<instance>-ca` Secret.
- **Retry on connection loss.** A planned switchover or a failover drops
  connections to the old primary. Retry the failed statement on a new
  connection. Do not retry a write whose result is unknown without checking
  whether it was applied.
- **Bounded connection pools.** Set a maximum pool size below the instance's
  `max_connections` divided by the number of application replicas. The size preset
  sets `max_connections` (small: 100, medium: 300, large: 1000).
- **Statement timeouts.** The server aborts statements longer than
  `maxStatementTimeSeconds` (300 by default). Set a client-side timeout below
  that, so the client gives up before the server does.

## Credentials

Each application has its own database user, created by the platform. Its password
lives in the Secret `<instance>-<owner>-credentials`, key `password`, in the
`db-<instance>` namespace. Mount that Secret into the application. Never copy the
password into a chart, an image or a values file.

**Never give an application the `root` account.** The `root` password is in
`<instance>-root`, for operators only. This matters on replicas: MariaDB has no
`super_read_only`, so an account with the SUPER privilege, including `root`, can
write to a replica even though the replica is read-only. Application accounts are
refused on a replica with `ERROR 1290 ... read-only`.

## Choosing primary or secondary

- A read that follows a write made by the same request must use the primary.
- Reporting and search reads may use the secondary. They can be behind the
  primary by the replication lag, which the platform alerts on when it grows.
- Writes through the secondary are always refused.

## Example

```bash
mariadb --ssl -h orders-primary.db-orders.svc -P 3306 -u orders_app -p orders
```

`--ssl` requires TLS. Add `--ssl-ca` with the CA from the `<instance>-ca` Secret to
verify the server.
