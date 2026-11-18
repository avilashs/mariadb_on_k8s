{{- define "dbaas.instanceName" -}}
{{- $name := required "name is required" .Values.name -}}
{{- if not (regexMatch "^[a-z][a-z0-9-]{1,28}[a-z0-9]$" $name) -}}
{{- fail (printf "instance name %q must match ^[a-z][a-z0-9-]{1,28}[a-z0-9]$" $name) -}}
{{- end -}}
{{- $name -}}
{{- end -}}

{{- define "dbaas.nodeClass" -}}
{{- $nc := required (printf "nodeClass is required (one of: %s)" (keys .Values.catalogue.nodeClasses | sortAlpha | join ", ")) .Values.nodeClass -}}
{{- $_ := required (printf "nodeClass %q is not in catalogue.nodeClasses" $nc) (index .Values.catalogue.nodeClasses $nc) -}}
{{- $nc -}}
{{- end -}}

{{/* The storage tier of the node class; the local-nvme rules of PLAN.md 7.5 apply here too. */}}
{{- define "dbaas.tier" -}}
{{- $nc := index .Values.catalogue.nodeClasses (include "dbaas.nodeClass" .) -}}
{{- $tier := $nc.storageTier -}}
{{- if eq $tier "local-nvme" -}}
{{- if lt (int .Values.replicas) 2 -}}{{- fail "the local-nvme tier needs at least two replicas (PLAN.md 7.5)" -}}{{- end -}}
{{- if not .Values.backup.enabled -}}{{- fail "the local-nvme tier needs backups enabled (PLAN.md 7.5)" -}}{{- end -}}
{{- end -}}
{{- $tier -}}
{{- end -}}

{{- define "dbaas.storageClass" -}}
{{- $nc := index .Values.catalogue.nodeClasses (include "dbaas.nodeClass" .) -}}
{{- $scName := .Values.storage.className | default $nc.storageClassName -}}
{{- $sc := required (printf "storage class %q is not in catalogue.storageClasses" $scName) (index .Values.catalogue.storageClasses $scName) -}}
{{- if ne $sc.tier $nc.storageTier -}}{{- fail (printf "storage class %q is on tier %q but node class is on tier %q" $scName $sc.tier $nc.storageTier) -}}{{- end -}}
{{- $scName -}}
{{- end -}}

{{- define "dbaas.preset" -}}
{{- $preset := required (printf "size %q is not a preset (small, medium, large)" .Values.size) (index .Values.presets .Values.size) -}}
{{- toYaml $preset -}}
{{- end -}}

{{- define "dbaas.image" -}}
{{- required (printf "version %q has no image in images" .Values.version) (index .Values.images .Values.version) -}}
{{- end -}}
