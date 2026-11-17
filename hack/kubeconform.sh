#!/usr/bin/env bash
# Validates Kubernetes manifests, strictly, against the pinned Kubernetes
# version and the generated CRD schemas. A kind without a schema is an error.
#
# Usage: hack/kubeconform.sh <file>...     or     ... | hack/kubeconform.sh -

set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ -f "${CACHE}/schemas/.fingerprint" ]] || die "CRD schemas are missing. Run 'make schemas'."
mkdir -p "${CACHE}/kubeconform"

kubernetes_version="$(pin .kubernetes)"

exec kubeconform \
  -strict \
  -kubernetes-version "${kubernetes_version#v}" \
  -schema-location default \
  -schema-location "${CACHE}/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  -cache "${CACHE}/kubeconform" \
  "$@"
