# JFrog Migration — Complete Change Log

All code changes made across the ace-monorepo to migrate from Docker Hub to a private container registry (JFrog Artifactory).

---

## Summary

| Repository | Branch | Files Changed |
|-----------|--------|:---:|
| `ace-monorepo` | `feature/setup-bug-fixes` | 25 |
| `AgentCert` (submodule) | `feature/docker-images-repository` | 20 |
| `agent-charts` (submodule) | `feature/docker-images-repository` | ~8 |
| `app-charts` (submodule) | `feature/docker-images-repository` | ~23 |
| `chaos-charts` (submodule) | `feature/docker-images-repository` | ~50 |
| `certifier` (submodule) | `feature/docker-images-repository` | 1 |

---

## 1. ace-monorepo Changes

### 1.1 Scripts (New)

| File | Purpose |
|------|---------|
| `scripts/apply-cluster-prereqs.sh` | Creates registry secrets in all namespaces, patches SAs, deploys jfrog-secret-sync, creates CA cert ConfigMap. Reads creds from env vars or prompts interactively. |
| `scripts/update-all-registries.sh` | Bulk sed replacement of Docker Hub image refs → private registry across all fault.yaml, experiment.yaml, and chart values. Reads `IMAGE_REGISTRY` from `.env`. |
| `scripts/fix-namespace-pull-secrets.sh` | Patches ALL ServiceAccounts in litmus + sock-shop with `imagePullSecrets` and restarts failing pods. |

### 1.2 Scripts (Modified)

| File | Change |
|------|--------|
| `scripts/setup.sh` | Removed JFrog credential prompts (delegated to `apply-cluster-prereqs.sh`). Skips prereqs if secret already exists. Generates `values-env.yaml` with `imageRegistry`, `imagePullSecretName`, `chartsBranch` from `.env`. |
| `scripts/azure_build/run.sh` | All image exports prefixed with `${IMAGE_REGISTRY}`. |
| `scripts/azure_build/start-agentcert-v2.sh` | Same — `env_val` defaults include registry prefix. Install-app/agent tags updated to versioned builds. |

### 1.3 Helm Chart (`deploy/helm/ace/`)

| File | Change | Why |
|------|--------|-----|
| `templates/_helpers.tpl` | Added `ace.image` helper that prefixes `imageRegistry` to image path | DRY — all templates use `{{ include "ace.image" ... }}` |
| `templates/graphql.yaml` | Added: `imagePullSecrets`, `IMAGE_REGISTRY` env var, `IMAGE_PULL_SECRET_NAME` env var, `alpine/git` init container with CA cert + chartsBranch, volume mounts for CA certs | GraphQL needs registry info to deploy chaos infra + clone charts from GitHub |
| `templates/auth.yaml` | Added `imagePullSecrets: [{name: {{ .Values.imagePullSecretName }}}]` | Auth pod pulls from private registry |
| `templates/web.yaml` | Added `imagePullSecrets`, changed to LoadBalancer with `staticIP` support, azure internal annotation | Web pod + external access |
| `templates/certifier.yaml` | Changed from NodePort to LoadBalancer, added `imagePullSecrets`, `staticIP` support | Certifier needs external access for PDF downloads |
| `templates/mongodb.yaml` | Added `imagePullSecrets` | MongoDB pulls from private registry |
| `templates/litellm.yaml` | Added `imagePullSecrets` | LiteLLM pulls from private registry |
| `templates/langfuse.yaml` | Added `imagePullSecrets` to all 6 deployments, LoadBalancer with `staticIP` | Langfuse stack (web, worker, postgres, redis, clickhouse, minio) |
| `values.yaml` | Added: `imageRegistry: ""`, `imagePullSecretName`, `chartsBranch`, `staticIP` (web/langfuse/certifier), `images.alpineGit` | Central configuration — all overridden from `.env` via `values-env.yaml` |

### 1.4 Infrastructure (`deploy/`)

| File | Change |
|------|--------|
| `deploy/jfrog-secret-sync.yaml` | **NEW** — Kubernetes Deployment in kube-system that watches namespace events and replicates the registry secret + patches SAs cluster-wide. Reconciles every 60s. |
| `deploy/k8s/graphql.yaml` | Updated image tag to `v6-dynamic-secret` |

### 1.5 Configuration

| File | Change |
|------|--------|
| `.env.example` | Added `IMAGE_REGISTRY`, `IMAGE_PULL_SECRET_NAME`, `CHARTS_BRANCH`, chaos infra image vars (`SUBSCRIBER_IMAGE`, `CHAOS_OPERATOR_IMAGE`, etc.), MCP server images, `CERTIFIER_IMAGE` |
| `docker-compose.yml` | Updated graphql image tag |
| `.gitignore` | Added submodule directories |

---

## 2. AgentCert Submodule Changes

### 2.1 Go Code

| File | Change | Why |
|------|--------|-----|
| `utils/variables.go` | Added `ImagePullSecretName` field (reads `IMAGE_PULL_SECRET_NAME` env var, default `jfrog-registry`) | Config struct for dynamic secret name |
| `pkg/chaos_infrastructure/infra_utils.go` | Changed hardcoded `jfrog-registry` → `utils.Config.ImagePullSecretName`. Added `#{IMAGE_PULL_SECRET_NAME}` replacement in ManifestParser. | SA YAML and manifest templates now use dynamic secret name |
| `pkg/chaos_experiment/ops/service.go` | Added `--set=global.imageRegistry=...` injection into install-application workflow template args | Sock-shop chart needs registry prefix for all images |
| `pkg/helm/service.go` | Added `--set global.imageRegistry=...` to helm install args | Charts installed by graphql get correct registry |
| `pkg/projects/project_handler.go` | Reads `IMAGE_REGISTRY` env var to set default image registry for new projects | UI projects use private registry by default |
| `pkg/agent_registry/helm.go` | Passes registry/sidecar image overrides to flash-agent helm install | Flash-agent gets correct registry-prefixed images |

### 2.2 Manifest YAML Files (cluster/ and namespace/)

All manifest files had hardcoded `jfrog-registry` replaced with `#{IMAGE_PULL_SECRET_NAME}` placeholder (resolved at runtime by ManifestParser):

| File | Change |
|------|--------|
| `cluster/1b_argo_rbac.yaml` | `imagePullSecrets: [{name: #{IMAGE_PULL_SECRET_NAME}}]` on argo-chaos SA |
| `cluster/1c_argo_deployment.yaml` | `imagePullSecrets` on workflow-controller pod |
| `cluster/2b_litmus_admin_rbac.yaml` | `imagePullSecrets` on litmus-admin SA, fixed indentation |
| `cluster/2c_litmus_deployment.yaml` | `imagePullSecrets` on chaos-operator + chaos-exporter pods |
| `cluster/3b_agents_deployment.yaml` | `imagePullSecrets` on subscriber + event-tracker pods |
| `cluster/4a_mcp_tools_rbac.yaml` | `imagePullSecrets` on mcp-server SAs |
| `cluster/4b_mcp_tools_deployment.yaml` | `imagePullSecrets` on MCP deployment pods |
| `namespace/` (same 7 files) | Same changes for namespace-scoped deployments |

---

## 3. agent-charts Submodule Changes

| File | Change | Why |
|------|--------|-----|
| `charts/flash-agent/templates/deployment.yaml` | Changed `{{ .Values.registry \| default "..." }}/` → `{{- if .Values.registry }}{{ .Values.registry }}/{{- end }}` | Prevents double-prefix or leading `/` when registry is empty |
| `charts/flash-agent/values.yaml` | `registry: infyartifactory.jfrog.io/docker-local` | Default registry for helm installs |
| `charts/k8s-agent/templates/deployment.yaml` | Added `imagePullSecrets` | K8s-agent pod needs registry credentials |
| `charts/k8s-agent/values.yaml` | `registry: infyartifactory.jfrog.io/docker-local` | Default registry |
| `install-agent/main.go` | Added `ensureImagePullSecret()` — copies secret from kube-system before helm install | Prevents 401 race condition |
| `litellm/deployment.yaml` | Added `imagePullSecrets`, updated image to use registry | LiteLLM pod in litellm namespace |

---

## 4. app-charts Submodule Changes

| File | Change | Why |
|------|--------|-----|
| `charts/sock-shop/values.yaml` | Added `global.imageRegistry` | Central registry for all sock-shop images |
| `charts/sock-shop/templates/_helpers.tpl` | Added `sock-shop-litmus.image` helper that prefixes `global.imageRegistry` | DRY — all templates use helper |
| 13 sock-shop deployment templates | Added `imagePullSecrets: [{name: jfrog-registry}]` | Each pod needs credentials |
| `templates/mcptools/kubernetes-mcp-server.yaml` | Added `imagePullSecrets` | MCP pod |
| `templates/mcptools/prometheus-mcp-server.yaml` | Added `imagePullSecrets` | MCP pod |
| `install-app/main.go` | Added `ensureImagePullSecret()` + `ensureNamespace()` | Creates secret in target namespace before helm install |

---

## 5. chaos-charts Submodule Changes (~50 files)

| Category | Change |
|----------|--------|
| **Faults** (36+ `fault.yaml`) | `spec.definition.image` → `$REGISTRY/litmuschaos/go-runner:latest`; `LIB_IMAGE`, `STRESS_IMAGE`, `TC_IMAGE` env vars → registry-prefixed |
| **Experiments** (7 files) | `install-application` image → versioned tag; `install-agent` image → versioned tag |

---

## 6. certifier Submodule Changes

| File | Change |
|------|--------|
| `docker-compose.yml` | Image path uses `${IMAGE_REGISTRY}` variable |

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Single source of truth (`.env`) | Change `IMAGE_REGISTRY` in one place → all scripts/charts/code use it |
| `IMAGE_PULL_SECRET_NAME` dynamic | Secret name configurable from `.env` → Go code reads it → manifest templates use placeholder |
| `jfrog-secret-sync` Deployment | Auto-replicates secret to new namespaces created by experiments (race condition fix) |
| `ensureImagePullSecret()` in Go | install-app/install-agent create secret before helm install (belt + suspenders) |
| Credentials NOT in `.env` | Security — only in K8s secrets; provided via env vars or interactive prompt |
| LoadBalancer with static IPs | Certifier/web/langfuse accessible externally; IPs persist across redeployments |
| `--force` on kubectl apply | Prevents "AlreadyExists" error when jfrog-secret-sync creates secret before the script |

---

## Docker Images Built

| Image | Tag | What's inside |
|-------|-----|---------------|
| `agentcert/agentcert-graphql` | `v6-dynamic-secret` | Dynamic `IMAGE_PULL_SECRET_NAME` + all registry injection logic |
| `agentcert/agentcert-install-app` | `v3-secret-fix` | `ensureImagePullSecret()` + charts with `global.imageRegistry` |
| `agentcert/agentcert-install-agent` | `v3-template-fix` | Fixed `{{- if .Registry }}` template (no leading `/`) |
