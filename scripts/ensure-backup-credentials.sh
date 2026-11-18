#!/usr/bin/env bash
# Copies the object store credentials of the platform into one instance namespace, as
# the Secret the backup objects reference (dbaas-backup-store). Idempotent: an existing
# Secret is left alone, so rotating the source does not silently change a running
# instance. Rotation: delete the copy, then run this script again (docs/operations.md).
#
#   scripts/ensure-backup-credentials.sh <context> <namespace> <platform-values-file>
set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../hack/lib.sh"

context="$1"
namespace="$2"
platform="$3"
target="dbaas-backup-store"

if kubectl --context "${context}" -n "${namespace}" get secret "${target}" >/dev/null 2>&1; then
  exit 0
fi

source_ns="$(yq -r '.backupStore.credentialsNamespace' "${platform}")"
source_name="$(yq -r '.backupStore.credentialsSecret' "${platform}")"
[[ -n "${source_ns}" && "${source_ns}" != "null" ]] || die "backupStore.credentialsNamespace is not set in ${platform}"

kubectl --context "${context}" -n "${source_ns}" get secret "${source_name}" -o json |
  jq --arg ns "${namespace}" --arg name "${target}" '
    {apiVersion: "v1", kind: "Secret", type: "Opaque",
     metadata: {name: $name, namespace: $ns,
                labels: {"app.kubernetes.io/part-of": "dbaas"}},
     data: {"access-key-id": .data["access-key-id"], "secret-access-key": .data["secret-access-key"]}}' |
  kubectl --context "${context}" apply -f - >/dev/null
log "backup credentials copied into ${namespace}"
