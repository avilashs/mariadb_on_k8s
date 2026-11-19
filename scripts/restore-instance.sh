#!/usr/bin/env bash
# Restores an instance to a point in time, as a NEW instance next to the original.
#
#   scripts/restore-instance.sh <instance> <target-time> <restore-name>
#
#   <target-time>   RFC 3339 UTC, for example 2026-11-18T10:15:00Z. Must not be in the
#                   future, and must be covered by the archived binary logs (the script
#                   waits until status.lastRecoverableTime reaches it).
#   <restore-name>  Name of the new instance, in the namespace db-<instance>.
#
# The new instance is the source object with its identity changed: same image, storage,
# node class and pod shape, two replicas (the admission policy needs at least two), and
# bootstrapFrom pointing at the source's point in time recovery. It has no backups of its
# own and never writes to the source's backup prefixes. Delete it when done:
#   kubectl -n db-<instance> delete mariadb <restore-name>
#
# Environment: KUBE_CONTEXT selects a context (default: the current one).
# Needs kubectl and jq only, so it runs in the restore-drill CronJob image as well.
set -euo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 3 ]]; then
  die "usage: $0 <instance> <target-time> <restore-name>"
fi
instance="$1"
target="$2"
restore="$3"

[[ "${instance}" =~ ^[a-z][a-z0-9-]{1,28}[a-z0-9]$ ]] || die "invalid instance name '${instance}'"
[[ "${restore}" =~ ^[a-z][a-z0-9-]{1,28}[a-z0-9]$ ]] || die "invalid restore name '${restore}'"
[[ "${restore}" != "${instance}" ]] || die "the restore needs a name of its own"
target_epoch="$(date -u -d "${target}" +%s 2>/dev/null)" || die "target time '${target}' is not a time"
now_epoch="$(date -u +%s)"
((target_epoch <= now_epoch)) || die "target time '${target}' is in the future"

kc() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    kubectl --context "${KUBE_CONTEXT}" "$@"
  else
    kubectl "$@"
  fi
}

ns="db-${instance}"
kc -n "${ns}" get mariadb "${instance}" >/dev/null || die "no instance '${instance}' in ${ns}"
kc -n "${ns}" get pointintimerecovery "${instance}" >/dev/null ||
  die "instance '${instance}' has no point in time recovery: backups are not enabled"

# The archive must reach the target before the restore can use it.
deadline=$((SECONDS + 900))
while :; do
  last="$(kc -n "${ns}" get pointintimerecovery "${instance}" -o jsonpath='{.status.lastRecoverableTime}')"
  if [[ -n "${last}" ]] && (($(date -u -d "${last}" +%s) >= target_epoch)); then
    break
  fi
  ((SECONDS < deadline)) || die "the binary log archive has not reached ${target} (last recoverable: ${last:-none})"
  sleep 10
done

# The source object, with its identity replaced. Everything else is copied as it is.
manifest="$(kc -n "${ns}" get mariadb "${instance}" -o json | jq \
  --arg name "${restore}" --arg target "${target}" --arg source "${instance}" '
  del(.metadata.uid, .metadata.resourceVersion, .metadata.generation, .metadata.creationTimestamp,
      .metadata.annotations, .metadata.managedFields, .metadata.finalizers, .metadata.ownerReferences, .status)
  | .metadata.name = $name
  | .metadata.labels["app.kubernetes.io/part-of"] = "dbaas"
  | .metadata.labels["app.kubernetes.io/instance"] = $name
  | .metadata.labels["dbaas.local/restore-of"] = $source
  | .spec.replicas = 2
  | .spec.rootPasswordSecretKeyRef.name = ($name + "-root")
  | .spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].labelSelector.matchLabels["app.kubernetes.io/instance"] = $name
  | .spec.topologySpreadConstraints[]?.labelSelector.matchLabels["app.kubernetes.io/instance"] = $name
  | del(.spec.pointInTimeRecoveryRef)
  | del(.spec.replication.replica.bootstrapFrom)
  | del(.spec.replication.replica.recovery)
  | .spec.bootstrapFrom = {pointInTimeRecoveryRef: {name: $source}, targetRecoveryTime: $target}
')"

if kc -n "${ns}" get mariadb "${restore}" >/dev/null 2>&1; then
  die "${ns}/${restore} already exists: delete it or choose another name"
fi

# The restored data carries the source's root account, so the new instance must use the same root
# password. A freshly generated one does not match: the operator and the agent cannot log in, the
# liveness probe fails and the pods crash-loop. Copy the source's Secret under the new name; the
# operator does not regenerate a Secret that exists. Applying again refreshes it after a rotation.
src_secret="$(kc -n "${ns}" get mariadb "${instance}" -o jsonpath='{.spec.rootPasswordSecretKeyRef.name}')"
[[ -n "${src_secret}" ]] || die "${ns}/${instance} has no rootPasswordSecretKeyRef"
kc -n "${ns}" get secret "${src_secret}" -o json | jq --arg name "${restore}-root" --arg source "${instance}" '
  {apiVersion: "v1", kind: "Secret", type: .type, data: .data,
   metadata: {name: $name, labels: {"app.kubernetes.io/part-of": "dbaas", "dbaas.local/restore-of": $source}}}' |
  kc -n "${ns}" apply -f - >/dev/null
printf '%s\n' "${manifest}" | kc -n "${ns}" apply -f - >/dev/null
echo "restoring ${ns}/${instance} to ${target} into ${restore}"

kc -n "${ns}" wait "mariadb/${restore}" --for=condition=Ready --timeout=1500s >/dev/null
echo "restored: ${ns}/${restore} is Ready at ${target}"
