#!/usr/bin/env bash
# Creates a Secret holding a random value, once. Re-running it changes nothing.
#
#   scripts/ensure-secret.sh <context> <namespace> <secret-name> <key>
#
# Used for values the platform must hold but must never write into a chart or a
# values file: application passwords and the Grafana admin password. The value is
# generated only when the Secret is absent, so rotation is always deliberate.
set -euo pipefail

if (($# != 4)); then
  echo "usage: $0 <context> <namespace> <secret-name> <key>" >&2
  exit 2
fi
context="$1"
namespace="$2"
name="$3"
key="$4"

if kubectl --context "${context}" -n "${namespace}" get secret "${name}" >/dev/null 2>&1; then
  exit 0
fi
value="$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | cut -c1-32)"
kubectl --context "${context}" -n "${namespace}" create secret generic "${name}" \
  --from-literal="${key}=${value}" >/dev/null
echo "created secret ${namespace}/${name}"
