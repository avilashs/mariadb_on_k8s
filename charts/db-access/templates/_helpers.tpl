{{- define "dbaas.accessName" -}}
{{- $name := required "name is required" .Values.name -}}
{{- if not (regexMatch "^[a-z][a-z0-9-]{1,28}[a-z0-9]$" $name) -}}
{{- fail (printf "instance name %q must match ^[a-z][a-z0-9-]{1,28}[a-z0-9]$" $name) -}}
{{- end -}}
{{- if not (has .Values.stage (list "users" "grants")) -}}
{{- fail (printf "stage must be users or grants, got %q" .Values.stage) -}}
{{- end -}}
{{- $name -}}
{{- end -}}

{{- define "dbaas.ident" -}}
{{- . | replace "_" "-" -}}
{{- end -}}
