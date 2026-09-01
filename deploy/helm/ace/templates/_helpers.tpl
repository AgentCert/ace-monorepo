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
Langfuse Postgres connection env.

Shared verbatim by langfuse-worker, langfuse-web, and langfuse-web's wait-for-db
init container so the database host/port is written in exactly ONE place — the
DATABASE_URL below. The init container derives what it polls straight from this
same DATABASE_URL (pg_isready -d "$DATABASE_URL"), so it always waits on whatever
the app is actually configured to connect to, with nothing hardcoded twice.
*/}}
{{- define "ace.langfuse.dbEnv" -}}
- name: POSTGRES_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secretName }}
      key: POSTGRES_USER
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secretName }}
      key: POSTGRES_PASSWORD
- name: POSTGRES_DB
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secretName }}
      key: POSTGRES_DB
      optional: true
- name: DATABASE_URL
  value: "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres:5432/$(POSTGRES_DB)"
{{- end }}
