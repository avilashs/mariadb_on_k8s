#!/usr/bin/env bash
# Deletes the kind test cluster and stops its proxy relay. Idempotent.
set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLUSTER="${KIND_CLUSTER_NAME:-dbaas}"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  log "deleting kind cluster '${CLUSTER}'"
  kind delete cluster --name "${CLUSTER}"
else
  log "kind cluster '${CLUSTER}' does not exist"
fi
pkill -f "hack/proxy-relay.py" 2>/dev/null || true
