#!/usr/bin/env bash
# Creates environments/<env>/instances/<name>.yaml from a template, and validates it.
# A file that fails validation is removed again, so the tree never holds a broken one.
#
#   ENV=kind scripts/instance-new.sh <name> <engine> <size> <node-class>
set -euo pipefail

if (($# != 4)); then
  echo "usage: ENV=<env> $0 <name> <engine> <size> <node-class>" >&2
  exit 2
fi
name="$1" engine="$2" size="$3" node_class="$4"
env="${ENV:-kind}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
file="${root}/environments/${env}/instances/${name}.yaml"

[[ "${engine}" == "mariadb" ]] || { echo "engine ${engine} is not available yet (postgres arrives with phase 10)" >&2; exit 1; }
[[ ! -e "${file}" ]] || { echo "${file} already exists; edit it instead" >&2; exit 1; }
[[ "${size}" =~ ^(small|medium|large)$ ]] || { echo "size must be small, medium or large" >&2; exit 1; }

cat >"${file}" <<YAML
# Instance ${name}: ${size} on ${node_class} (created by scripts/instance-new.sh).
name: ${name}
engine: ${engine}
size: ${size}
replicas: 2
nodeClass: ${node_class}
YAML

if ! "${root}/hack/lint-instances.sh" "${file}" >/dev/null 2>&1; then
  rm -f "${file}"
  echo "the instance does not validate for ${env}; run hack/lint-instances.sh on a copy to see why" >&2
  exit 1
fi
echo "created ${file#"${root}"/}; sync with: make instances-up ENV=${env}"
