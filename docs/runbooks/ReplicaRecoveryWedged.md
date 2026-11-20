# Replica recovery wedged (MariaDB)

**Symptom:** a replica pod stays in init or not Ready for much longer than a re-seed takes (minutes per 100 GB),
and its `<name>-pb-recovery` PhysicalBackup/Job is missing, finished, or stuck. Seen on kind after a container
restart in the middle of a recovery.

1. Confirm the primary and the other replica are Ready and writes work. Nothing here is urgent for availability.
2. `kubectl -n db-<name> get pod,pvc,physicalbackup,job` and `logs <pod> -c init` for the stuck replica.
3. Try, in order, stopping when the replica recovers: delete the pod; delete the pod and its `<pvc>`; if the claim
   sticks in `Terminating`, delete the completed backup pods that still mount it first.
4. If it still does not recover, rebuild the instance from backup: `scripts/restore-instance.sh` (see
   `docs/operations.md`). On a test cluster, deleting the instance and its claims and re-running `make instances-up`
   also works.
5. Record what happened in `docs/deviations.md`.
