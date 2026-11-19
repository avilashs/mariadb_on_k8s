#!/usr/bin/env bash
# Creates the image pull secret "dbaas-registry" in the given namespaces, from environment variables.
# For a private registry (the AKS rehearsal). The credential is never written to the repository.
#
#   REGISTRY_SERVER=<name>.azurecr.io REGISTRY_USER=... REGISTRY_PASSWORD=... \
#     CONTEXT=dbaas-aks scripts/ensure-registry-secret.sh dbaas-system db-alpha
set -euo pipefail

: "${REGISTRY_SERVER:?set REGISTRY_SERVER}"
: "${REGISTRY_USER:?set REGISTRY_USER}"
: "${REGISTRY_PASSWORD:?set REGISTRY_PASSWORD}"
CONTEXT="${CONTEXT:-}"
SECRET="${SECRET_NAME:-dbaas-registry}"
(($# > 0)) || { echo "usage: ensure-registry-secret.sh <namespace>..." >&2; exit 2; }

kc() { kubectl ${CONTEXT:+--context "${CONTEXT}"} "$@"; }

for ns in "$@"; do
  kc get namespace "${ns}" >/dev/null 2>&1 || kc create namespace "${ns}" >/dev/null
  # Apply is idempotent: the credential can be rotated by running the script again.
  kc -n "${ns}" create secret docker-registry "${SECRET}" \
    --docker-server="${REGISTRY_SERVER}" --docker-username="${REGISTRY_USER}" \
    --docker-password="${REGISTRY_PASSWORD}" --dry-run=client -o yaml | kc apply -f - >/dev/null
  echo "secret ${SECRET} in ${ns}"
done
