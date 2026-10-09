{{/*
Namespace — always "ace"; kept as a helper so it can be overridden if needed.
*/}}
{{- define "ace.namespace" -}}
{{- "ace" -}}
{{- end }}

{{/*
Namespace for the cluster-singleton metrics-server. Defaults to the platform's
own namespace so it never contends with the app charts over `monitoring`.
*/}}
{{- define "ace.metricsServerNamespace" -}}
{{- .Values.metricsServer.namespace | default (include "ace.namespace" .) -}}
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

{{/*
ace.image — where an image is pulled from (docs/setup/registry-migration-plan.md).
Same naming rule as scripts/lib/registry.sh and graphql's pkg/imageref; the
values are set by setup.sh from .env:
  imageRegistry set     -> <imageRegistry>/<imageMirrorNamespace>/<public name>
                           ("none": <imageRegistry>/<public name>)
  imageRegistry empty   -> <imageMirrorNamespace>/<flat name> (frozen Docker Hub
                           copy; "/" -> "-", registry host dropped) for images
                           listed in _mirrored.tpl; any other image, or every
                           image when imageMirrorNamespace is "none", keeps its
                           public name
  local=true            -> the public name as-is (image built and side-loaded
                           into the cluster by setup.sh)
ACE's own agentcert/x images do not repeat the namespace
(.../docker-local + agentcert/certifier -> .../docker-local/agentcert/certifier).
aceImageTag (ACE_IMAGE_TAG, e.g. RELEASE-3) replaces the tag of the images ACE
builds itself (_mirrored.tpl "ace.aceImages"), unless local=true.
Usage: {{ include "ace.image" (dict "root" $ "image" .Values.images.mongodb "local" false) }}
*/}}
{{- define "ace.image" -}}
{{- $v := .root.Values -}}
{{- $ref := trim .image -}}
{{- if .local -}}
{{- $ref -}}
{{- else -}}
{{- $c := $ref | trimPrefix "docker.io/" | trimPrefix "index.docker.io/" | trimPrefix "registry-1.docker.io/" | trimPrefix "library/" -}}
{{- if and (not (contains ":" (last (splitList "/" $c)))) (not (contains "@" $c)) -}}
{{- $c = printf "%s:latest" $c -}}
{{- end -}}
{{- $aceTag := ($v.aceImageTag | default "") | toString | trim -}}
{{- if and $aceTag (not (contains "@" $c)) (has (regexReplaceAll ":[^:/]*$" $c "") (include "ace.aceImages" .root | fromJsonArray)) -}}
{{- $c = printf "%s:%s" (regexReplaceAll ":[^:/]*$" $c "") $aceTag -}}
{{- end -}}
{{- $reg := ($v.imageRegistry | default "") | trim | trimPrefix "https://" | trimPrefix "http://" | replace "/ui/native/" "/" | trimSuffix "/" -}}
{{- $ns := ($v.imageMirrorNamespace | default "agentcert") | trim -}}
{{- if $reg -}}
{{- $base := $reg -}}
{{- if and (ne $ns "none") (not (hasSuffix (printf "/%s" $ns) (printf "/%s" $reg))) -}}{{- $base = printf "%s/%s" $reg $ns -}}{{- end -}}
{{- $seg := last (splitList "/" $base) -}}
{{- if hasPrefix (printf "%s/" $reg) $ref -}}{{ $ref }}{{- else if and (contains "/" $base) (hasPrefix (printf "%s/" $seg) $c) -}}{{ $base }}/{{ trimPrefix (printf "%s/" $seg) $c }}{{- else -}}{{ $base }}/{{ $c }}{{- end -}}
{{- else if and (ne $ns "none") (has $c (include "ace.mirroredImages" .root | fromJsonArray)) -}}
{{- if hasPrefix (printf "%s/" $ns) $c -}}
{{- $c -}}
{{- else -}}
{{- $tag := regexFind ":[^:/]*$" $c -}}
{{- $name := trimSuffix $tag $c -}}
{{- $parts := splitList "/" $name -}}
{{- $first := first $parts -}}
{{- if and (gt (len $parts) 1) (or (contains "." $first) (contains ":" $first) (eq $first "localhost")) -}}
{{- $name = join "/" (rest $parts) -}}
{{- end -}}
{{- printf "%s/%s%s" $ns (replace "/" "-" $name) $tag -}}
{{- end -}}
{{- else -}}
{{- $c -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
ace.imagePullSecrets — the registry pull Secret, only when a private registry
is configured (public images need no login). Usage, inside a pod spec:
  {{- include "ace.imagePullSecrets" $ | nindent 6 }}
*/}}
{{- define "ace.imagePullSecrets" -}}
{{- if and .Values.imageRegistry .Values.imagePullSecretName -}}
imagePullSecrets:
  - name: {{ .Values.imagePullSecretName }}
{{- end -}}
{{- end -}}
