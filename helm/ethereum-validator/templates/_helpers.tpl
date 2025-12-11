{{/*
Expand the name of the chart.
*/}}
{{- define "ethereum-validator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "ethereum-validator.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "ethereum-validator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ethereum-validator.labels" -}}
helm.sh/chart: {{ include "ethereum-validator.chart" . }}
{{ include "ethereum-validator.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
network: {{ .Values.global.network }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ethereum-validator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ethereum-validator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "ethereum-validator.serviceAccountName" -}}
{{- if .Values.rbac.serviceAccount.create }}
{{- default (include "ethereum-validator.fullname" .) .Values.rbac.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.rbac.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Storage class for execution client
*/}}
{{- define "ethereum-validator.storageClass.execution" -}}
{{- if .Values.storage.execution.storageClass }}
{{- .Values.storage.execution.storageClass }}
{{- else }}
{{- .Values.storage.storageClass }}
{{- end }}
{{- end }}

{{/*
Storage class for consensus client
*/}}
{{- define "ethereum-validator.storageClass.consensus" -}}
{{- if .Values.storage.consensus.storageClass }}
{{- .Values.storage.consensus.storageClass }}
{{- else }}
{{- .Values.storage.storageClass }}
{{- end }}
{{- end }}

{{/*
Storage class for validator
*/}}
{{- define "ethereum-validator.storageClass.validator" -}}
{{- if .Values.storage.validator.storageClass }}
{{- .Values.storage.validator.storageClass }}
{{- else }}
{{- .Values.storage.storageClass }}
{{- end }}
{{- end }}

{{/*
Network config value for Nethermind
*/}}
{{- define "ethereum-validator.nethermind.network" -}}
{{- .Values.global.network -}}
{{- end }}

{{/*
Network value for Lighthouse
*/}}
{{- define "ethereum-validator.lighthouse.network" -}}
{{- .Values.global.network -}}
{{- end }}

{{/*
JWT secret volume mounts
*/}}
{{- define "ethereum-validator.jwtSecretVolume" -}}
- name: jwt-secret
  secret:
    secretName: {{ include "ethereum-validator.fullname" . }}-jwt
{{- end }}

{{/*
JWT secret volume mount
*/}}
{{- define "ethereum-validator.jwtSecretVolumeMount" -}}
- name: jwt-secret
  mountPath: /secrets
  readOnly: true
{{- end }}

{{/*
Validator keys volume
*/}}
{{- define "ethereum-validator.validatorKeysVolume" -}}
- name: validator-keys
  secret:
    secretName: {{ include "ethereum-validator.fullname" . }}-validator-keys
{{- end }}

{{/*
Validator keys volume mount
*/}}
{{- define "ethereum-validator.validatorKeysVolumeMount" -}}
- name: validator-keys
  mountPath: /validator-keys
  readOnly: true
{{- end }}

{{/*
Common pod security context
*/}}
{{- define "ethereum-validator.podSecurityContext" -}}
runAsNonRoot: {{ .Values.podSecurityContext.runAsNonRoot }}
runAsUser: {{ .Values.podSecurityContext.runAsUser }}
fsGroup: {{ .Values.podSecurityContext.fsGroup }}
{{- end }}

{{/*
Common container security context
*/}}
{{- define "ethereum-validator.securityContext" -}}
allowPrivilegeEscalation: {{ .Values.securityContext.allowPrivilegeEscalation }}
capabilities:
  drop:
  {{- range .Values.securityContext.capabilities.drop }}
  - {{ . }}
  {{- end }}
readOnlyRootFilesystem: {{ .Values.securityContext.readOnlyRootFilesystem }}
{{- end }}
