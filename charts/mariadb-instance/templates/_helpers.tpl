{{/*
Validation and derived values. Every rule of PLAN.md section 7.5 that a
values file could break is checked here, so a bad instance fails to render
instead of failing in the cluster.
*/}}

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

{{- define "dbaas.preset" -}}
{{- $preset := required (printf "size %q is not a preset (small, medium, large)" .Values.size) (index .Values.presets .Values.size) -}}
{{- toYaml $preset -}}
{{- end -}}

{{/* The storage class of the instance, checked against its node class's tier. */}}
{{- define "dbaas.storageClass" -}}
{{- $nc := index .Values.catalogue.nodeClasses (include "dbaas.nodeClass" .) -}}
{{- $scName := .Values.storage.className | default $nc.storageClassName -}}
{{- $sc := required (printf "storage class %q is not in catalogue.storageClasses" $scName) (index .Values.catalogue.storageClasses $scName) -}}
{{- if ne $sc.tier $nc.storageTier -}}
{{- fail (printf "storage class %q is on tier %q but node class %q is on tier %q" $scName $sc.tier (include "dbaas.nodeClass" .) $nc.storageTier) -}}
{{- end -}}
{{- $scName -}}
{{- end -}}

{{/* The storage tier, after the rules that depend on it. */}}
{{- define "dbaas.tier" -}}
{{- $nc := index .Values.catalogue.nodeClasses (include "dbaas.nodeClass" .) -}}
{{- $tier := $nc.storageTier -}}
{{- if eq $tier "local-nvme" -}}
{{- if lt (int .Values.replicas) 2 -}}
{{- fail "the local-nvme tier needs at least two replicas (PLAN.md 7.5)" -}}
{{- end -}}
{{- if not .Values.backup.enabled -}}
{{- fail "the local-nvme tier needs backups enabled: a pod that moves to a new node restores from backup (PLAN.md 7.5)" -}}
{{- end -}}
{{- if not .Values.durability.sync -}}
{{- fail "the local-nvme tier needs semi-synchronous replication (PLAN.md 7.5)" -}}
{{- end -}}
{{- end -}}
{{- $tier -}}
{{- end -}}

{{- define "dbaas.image" -}}
{{- required (printf "version %q has no image in images" .Values.version) (index .Values.images .Values.version) -}}
{{- end -}}

{{/* The baseline my.cnf of PLAN.md 7.4 with the size preset and parameters applied. */}}
{{- define "dbaas.myCnf" -}}
{{- $preset := fromYaml (include "dbaas.preset" .) -}}
{{- $baseline := dict
    "binlog_format" "ROW"
    "innodb_flush_log_at_trx_commit" "1"
    "innodb_flush_method" "O_DIRECT"
    "innodb_buffer_pool_dump_at_shutdown" "ON"
    "innodb_buffer_pool_load_at_startup" "ON"
    "innodb_buffer_pool_size" $preset.bufferPoolSize
    "max_connections" (toString $preset.maxConnections)
    "max_statement_time" (toString .Values.maxStatementTimeSeconds)
    "slave_parallel_threads" "4"
    "slave_parallel_mode" "optimistic"
    "binlog_expire_logs_seconds" "604800"
    "slow_query_log" "ON"
    "long_query_time" "1"
    "performance_schema" "ON"
    "skip_name_resolve" "ON"
    "character_set_server" "utf8mb4"
-}}
{{- $merged := mergeOverwrite $baseline (.Values.parameters | default dict) -}}
[mariadb]
{{- range $key := keys $merged | sortAlpha }}
{{ $key }}={{ index $merged $key }}
{{- end }}
{{- end -}}
