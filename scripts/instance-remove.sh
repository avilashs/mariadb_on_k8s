#!/usr/bin/env bash
# Step two of removing an instance (docs/operations.md). Step one is deleting its
# values file and running `make instances-up`, which leaves the instance in place.
# This script refuses to run while the file still exists.
#
#   ENV=kind scripts/instance-remove.sh <name>
# INSTANCES_DIR overrides the directory, as it does for make instances-up.
set -euo pipefail

if (($# != 1)); then
  echo "usage: ENV=<env> $0 <name>" >&2
  exit 2
fi
name="$1"
env="${ENV:-kind}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
context="$(yq -r '.kubeContext' "${root}/environments/${env}/platform.yaml")"
dir="${INSTANCES_DIR:-${root}/environments/${env}/instances}"
file="${dir}/${name}.yaml"

if [[ -e "${file}" ]]; then
  echo "${file#"${root}"/} still exists. Delete it first, then sync, then run this script." >&2
  exit 1
fi

echo "deleting the MariaDB resource of ${name} (deletion protection keeps it through helm)"
kubectl --context "${context}" -n "db-${name}" delete mariadb "${name}" --wait=true --timeout=900s || true
helm --kube-context "${context}" -n "db-${name}" uninstall "${name}-grants" >/dev/null 2>&1 || true
helm --kube-context "${context}" -n "db-${name}" uninstall "${name}-users" >/dev/null 2>&1 || true
helm --kube-context "${context}" -n "db-${name}" uninstall "${name}" >/dev/null 2>&1 || true
helm --kube-context "${context}" uninstall "ns-${name}" >/dev/null 2>&1 || true
kubectl --context "${context}" delete namespace "db-${name}" --wait=false >/dev/null 2>&1 || true
echo "instance ${name} removed"
