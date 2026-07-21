{{/*
Build a full image reference, optionally prefixed with global.imageRegistry.
Fully-qualified repositories (registry host contains "." or ":" or is
"localhost") bypass the global prefix.
Usage: include "octo.image" (dict "repo" .Values.foo.image.repository "tag" .Values.foo.image.tag "ctx" .)
*/}}
{{- define "octo.image" -}}
{{- $reg := .ctx.Values.global.imageRegistry | default "" -}}
{{- $repo := .repo | default "" -}}
{{- $tag := .tag | default "" -}}
{{- $repoParts := splitList "/" $repo -}}
{{- $repoHost := first $repoParts | default "" -}}
{{- $qualified := or (contains "." $repoHost) (contains ":" $repoHost) (eq $repoHost "localhost") -}}
{{- if and $reg (not $qualified) -}}
{{- printf "%v/%v:%v" ($reg | trimSuffix "/") $repo $tag -}}
{{- else -}}
{{- printf "%v:%v" $repo $tag -}}
{{- end -}}
{{- end -}}

{{/*
imagePullSecrets block. Renders nothing when the list is empty.
Indent the output to match the surrounding pod spec (typically nindent 6).
*/}}
{{- define "octo.imagePullSecrets" -}}
{{- $hasTCR := .Values.tcrImageCredentials.registry -}}
{{- $hasGlobal := .Values.global.imagePullSecrets -}}
{{- if or $hasGlobal $hasTCR -}}
imagePullSecrets:
  {{- if $hasTCR }}
  - name: tcr-registry-key
  {{- end }}
  {{- with $hasGlobal }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end -}}
{{- end -}}

{{/*
Expand the name of the chart.
*/}}
{{- define "octo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Truncate at 63 chars because some Kubernetes name fields are limited to this.
*/}}
{{- define "octo.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart label value.
*/}}
{{- define "octo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "octo.labels" -}}
helm.sh/chart: {{ include "octo.chart" . }}
{{ include "octo.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels (immutable after initial deploy).
*/}}
{{- define "octo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "octo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* ── Component fully-qualified names ─────────────────────────────────────── */}}

{{- define "octo.mysql.fullname" -}}
{{- printf "%s-mysql" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.redis.fullname" -}}
{{- printf "%s-redis" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.minio.fullname" -}}
{{- printf "%s-minio" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.wukongim.fullname" -}}
{{- printf "%s-wukongim" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.server.fullname" -}}
{{- printf "%s-server" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.web.fullname" -}}
{{- printf "%s-web" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.admin.fullname" -}}
{{- printf "%s-admin" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.matter.fullname" -}}
{{- printf "%s-matter" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.summaryApi.fullname" -}}
{{- printf "%s-summary-api" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.summaryWorker.fullname" -}}
{{- printf "%s-summary-worker" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.speech.fullname" -}}
{{- printf "%s-speech" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.speechAdmin.fullname" -}}
{{- printf "%s-speech-admin" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.fleet.fullname" -}}
{{- printf "%s-fleet" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.nginx.fullname" -}}
{{- printf "%s-nginx" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.searchOpensearch.fullname" -}}
{{- printf "%s-search-opensearch" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.searchKafka.fullname" -}}
{{- printf "%s-search-kafka" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.searchKafkaInit.fullname" -}}
{{- printf "%s-search-kafka-init" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.esIndexer.fullname" -}}
{{- printf "%s-es-indexer" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.searchetlProducer.fullname" -}}
{{- printf "%s-searchetl-producer" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.secretName" -}}
{{- printf "%s-secrets" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.ingress.tlsSecretName" -}}
{{- .Values.ingress.tls.secretName | default (printf "%s-qcloud-cert" (include "octo.fullname" .) | trunc 63 | trimSuffix "-") }}
{{- end }}

{{/* ── Inline resource names (ConfigMap, ServiceAccount, PVC, etc.) ─────────── */}}

{{- define "octo.configMap.misc" -}}
{{- printf "%s-misc" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.configMap.nginx" -}}
{{- printf "%s-nginx-config" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.configMap.server" -}}
{{- printf "%s-server-config" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.configMap.wukongim" -}}
{{- printf "%s-wukongim-config" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.configMap.fleet" -}}
{{- printf "%s-fleet-config" (include "octo.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "octo.speech.pvc" -}}
{{- printf "%s-logs" (include "octo.speech.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* ── Connection helpers ────────────────────────────────────────────────────── */}}

{{/*
MySQL hostname (bundled or external).
*/}}
{{- define "octo.mysql.host" -}}
{{- if .Values.mysql.enabled }}
{{- include "octo.mysql.fullname" . }}
{{- else }}
{{- required "externalMySQL.host is required when mysql.enabled=false" .Values.externalMySQL.host }}
{{- end }}
{{- end }}

{{/*
MySQL port.
*/}}
{{- define "octo.mysql.port" -}}
{{- if .Values.mysql.enabled }}
{{- .Values.mysql.service.port | default 3306 }}
{{- else }}
{{- .Values.externalMySQL.port | default 3306 }}
{{- end }}
{{- end }}

{{/*
MySQL database name.
*/}}
{{- define "octo.mysql.database" -}}
{{- if .Values.mysql.enabled }}
{{- .Values.mysql.auth.database | default "octo" }}
{{- else }}
{{- .Values.externalMySQL.database | default "octo" }}
{{- end }}
{{- end }}

{{/*
Redis addr (host:port).
*/}}
{{- define "octo.redis.addr" -}}
{{- if .Values.redis.enabled }}
{{- printf "%s:%v" (include "octo.redis.fullname" .) (.Values.redis.service.port | default 6379) }}
{{- else }}
{{- required "externalRedis.addr is required when redis.enabled=false" .Values.externalRedis.addr }}
{{- end }}
{{- end }}

{{- define "octo.redis.host" -}}
{{- if .Values.redis.enabled }}
{{- include "octo.redis.fullname" . }}
{{- else }}
{{- (split ":" (required "externalRedis.addr is required when redis.enabled=false" .Values.externalRedis.addr))._0 }}
{{- end }}
{{- end }}

{{- define "octo.redis.port" -}}
{{- if .Values.redis.enabled }}
{{- .Values.redis.service.port | default 6379 }}
{{- else }}
{{- (split ":" (required "externalRedis.addr is required when redis.enabled=false" .Values.externalRedis.addr))._1 | default "6379" }}
{{- end }}
{{- end }}

{{/*
MinIO internal endpoint (host:port) used by server-side calls.
Returns empty when cloud storage is active (endpoint is irrelevant).
*/}}
{{- define "octo.minio.endpoint" -}}
{{- if include "octo.isCloudStorage" . }}
{{- "" }}
{{- else if .Values.minio.enabled }}
{{- printf "%s:%v" (include "octo.minio.fullname" .) (.Values.minio.service.apiPort | default 9000) }}
{{- else }}
{{- required "externalMinio.endpoint is required when minio.enabled=false" .Values.externalMinio.endpoint }}
{{- end }}
{{- end }}

{{/*
MinIO internal URL (http://host:port). Returns empty when endpoint is empty (cloud storage mode).
*/}}
{{- define "octo.minio.url" -}}
{{- $ep := include "octo.minio.endpoint" . -}}
{{- if $ep -}}{{- printf "http://%s" $ep -}}{{- end -}}
{{- end }}

{{/*
MinIO app user (IAM). Only meaningful when fileService=minio.
Returns empty string in cloud storage mode — callers are already guarded by octo.isCloudStorage.
*/}}
{{- define "octo.minio.appUser" -}}
{{- if .Values.minio.enabled }}
{{- .Values.minio.auth.appUser | default "octo-app" }}
{{- else if include "octo.isCloudStorage" . }}
{{- "" }}
{{- else }}
{{- .Values.externalMinio.appUser | default "octo-app" }}
{{- end }}
{{- end }}

{{/*
WuKongIM API URL.
*/}}
{{- define "octo.wukongim.apiURL" -}}
{{- if .Values.wukongim.enabled }}
{{- printf "http://%s:%v" (include "octo.wukongim.fullname" .) (.Values.wukongim.service.apiPort | default 5001) }}
{{- else }}
{{- required "externalWukongim.apiURL is required when wukongim.enabled=false" .Values.externalWukongim.apiURL }}
{{- end }}
{{- end }}

{{- define "octo.wukongim.wsEndpoint" -}}
{{- if .Values.wukongim.enabled }}
{{- printf "%s:%v" (include "octo.wukongim.fullname" .) (.Values.wukongim.service.wsPort | default 5200) }}
{{- else }}
{{- required "externalWukongim.wsEndpoint is required when wukongim.enabled=false" .Values.externalWukongim.wsEndpoint }}
{{- end }}
{{- end }}

{{/*
nginx HTTP port (the public port exposed by the nginx Service).
*/}}
{{- define "octo.nginx.port" -}}
{{- .Values.nginx.service.port | default 80 }}
{{- end }}

{{/*
External base URL (used for presigned URLs and OIDC callbacks).
*/}}
{{- define "octo.externalBaseURL" -}}
{{- if .Values.externalBaseURL }}
{{- .Values.externalBaseURL }}
{{- else if .Values.domain }}
{{- if eq (include "octo.nginx.port" .) "80" -}}
{{- printf "http://%s" .Values.domain }}
{{- else -}}
{{- printf "http://%s:%v" .Values.domain (include "octo.nginx.port" .) }}
{{- end -}}
{{- else }}
{{- "" }}
{{- end }}
{{- end }}

{{/*
MinIO public S3 server URL (MINIO_SERVER_URL + TS_MINIO_DOWNLOADURL).
*/}}
{{- define "octo.minio.serverURL" -}}
{{- if .Values.minio.serverURL }}
{{- .Values.minio.serverURL }}
{{- else }}
{{- include "octo.externalBaseURL" . }}
{{- end }}
{{- end }}

{{/*
WuKongIM external WebSocket address.
*/}}
{{- define "octo.wukongim.wsAddr" -}}
{{- if .Values.wukongim.wsAddr }}
{{- .Values.wukongim.wsAddr }}
{{- else if or .Values.externalBaseURL .Values.domain }}
{{- $base := include "octo.externalBaseURL" . }}
{{- $base | replace "https://" "wss://" | replace "http://" "ws://" }}/ws
{{- else }}
{{- "" }}
{{- end }}
{{- end }}

{{/*
Returns "true" when the bundled MinIO StatefulSet is active.
True only when minio.enabled=true AND fileService=minio.
When fileService is set to a cloud provider, users must also explicitly
set minio.enabled=false in their values to avoid confusion.
*/}}
{{- define "octo.minio.active" -}}
{{- if and (not (include "octo.isCloudStorage" .)) .Values.minio.enabled -}}true{{- end -}}
{{- end -}}

{{/*
Returns "true" when server.config.fileService is a cloud provider (not "minio").
Use with: {{- if include "octo.isCloudStorage" . }}
*/}}
{{- define "octo.isCloudStorage" -}}
{{- $fs := (.Values.server.config | default dict).fileService | default "minio" -}}
{{- if ne $fs "minio" -}}true{{- end -}}
{{- end -}}

{{/*
TCR (Tencent Cloud Registry) image pull secret generator.
Generates a base64-encoded dockerconfigjson for authenticating with TCR.
Used by secret-registry.yaml to create the tcr-registry-key Secret.
*/}}
{{- define "octo.tcrImagePullSecret" }}
{{- with .Values.tcrImageCredentials }}
{{- $_ := required "tcrImageCredentials.username is required when tcrImageCredentials.registry is set" .username }}
{{- $_ := required "tcrImageCredentials.password is required when tcrImageCredentials.registry is set" .password }}
{{- $auth := printf "%s:%s" .username .password | b64enc }}
{{- $cred := dict "username" .username "password" .password "auth" $auth }}
{{- $auths := dict .registry $cred }}
{{- dict "auths" $auths | toJson | b64enc }}
{{- end }}
{{- end }}
