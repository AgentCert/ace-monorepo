{{/*
Namespace — always "ace"; kept as a helper so it can be overridden if needed.
*/}}
{{- define "ace.namespace" -}}
{{- "ace" -}}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ace.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Pull policy for agentcert/* images (:latest → Always)
*/}}
{{- define "ace.pullPolicy" -}}
{{- .Values.imagePullPolicy | default "Always" -}}
{{- end }}

{{/*
Pull policy for pinned infra images (mongo:5, postgres:17, etc. → IfNotPresent)
*/}}
{{- define "ace.infraPullPolicy" -}}
{{- .Values.infraImagePullPolicy | default "IfNotPresent" -}}
{{- end }}

{{/*
Prefix an image with the imageRegistry if set.
Usage: {{ include "ace.image" (dict "img" .Values.images.graphql "reg" .Values.imageRegistry) }}
*/}}
{{- define "ace.image" -}}
{{- if .reg -}}
{{- printf "%s/%s" .reg .img -}}
{{- else -}}
{{- .img -}}
{{- end -}}
{{- end }}
