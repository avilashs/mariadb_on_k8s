#!/usr/bin/env bash
# Creates the basic-auth Secret of one PostgreSQL role (PLAN.md phase 10): username and password.
# CloudNativePG reads the role's password from it. Idempotent: an existing Secret is kept.
#
#   scripts/ensure-pg-role-secret.sh <context> <namespace> <secret-name> <role>
set -euo pipefail
context="$1" namespace="$2" secret="$3" role="$4"
if kubectl --context "${context}" -n "${namespace}" get secret "${secret}" >/dev/null 2>&1; then
  exit 0
fi
password="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
kubectl --context "${context}" -n "${namespace}" create secret generic "${secret}" \
  --type=kubernetes.io/basic-auth --from-literal=username="${role}" --from-literal=password="${password}" >/dev/null
echo "created ${namespace}/${secret}"
