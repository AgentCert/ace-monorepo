# Private Registry Migration — Complete Change Log

All code changes made to support pulling container images from a private registry
instead of Docker Hub. Changes are relative to the `main` branch.

---

## Summary

| Repository | Branch | New Files | Modified Files |
|-----------|--------|:---------:|:--------------:|
| `ace-monorepo` | `feature/setup-bug-fixes` | 4 | 15 |
| `AgentCert` (submodule) | `feature/docker-images-repository` | 0 | 20 |
| `agent-charts` (submodule) | `feature/docker-images-repository` | 0 | ~8 |
| `app-charts` (submodule) | `feature/docker-images-repository` | 0 | ~23 |
| `chaos-charts` (submodule) | `feature/docker-images-repository` | 0 | ~50 |
| `certifier` (submodule) | `feature/docker-images-repository` | 0 | 1 |

---

## 1. ace-monorepo — New Files

### `scripts/apply-cluster-prereqs.sh`

**Purpose:** One-time cluster preparation for private registry access.

What it does:
- Reads `IMAGE_REGISTRY` from `.env` → auto-derives `DOCKER_SERVER` (host part)
- Reads `IMAGE_PULL_SECRET_NAME` from `.env` (default: `jfrog-registry`)
- Prompts for registry credentials (or reads from `JFROG_USER`/`JFROG_TOKEN` env vars)
- Creates docker-registry secret in: ace, kube-system, litmus, sock-shop, litellm namespaces
- Patches all ServiceAccounts with `imagePullSecrets`
- Creates CA certificates ConfigMap (for corporate proxy)
- Deploys `jfrog-secret-sync` (auto-replicates secret to new namespaces)

### `deploy/jfrog-secret-sync.yaml`

**Purpose:** Kubernetes Deployment (in kube-system) that watches namespace events.

What it does:
- When a new namespace is created → copies registry secret from kube-system within 5 seconds
- Reconciles all namespaces every 60 seconds (safety net)
- Patches all ServiceAccounts with `imagePullSecrets`

### `scripts/update-all-registries.sh`

**Purpose:** Bulk-updates image references in chaos-charts and agent-charts YAML files.

What it does:
- Reads `IMAGE_REGISTRY` from `.env`
- Replaces `docker.io` / `litmuschaos` / `weaveworksdemos` image prefixes with registry path in:
  - `chaos-charts/faults/*/fault.yaml` (36+ files)
  - `chaos-charts/experiments/*/experiment*.yaml` (7 files)
  - `agent-charts/litellm/deployment.yaml`

### `scripts/fix-namespace-pull-secrets.sh`

**Purpose:** Emergency fix script — patches all SAs in litmus + sock-shop and restarts failing pods.

---

## 2. ace-monorepo — Modified Files

### `deploy/helm/ace/values.yaml`

Added fields (not in main):
```yaml
chartsBranch: "main"                    # Git branch for chart clone
imageRegistry: ""                        # Registry prefix (from .env)
staticIP:                                # Static LoadBalancer IPs
  web: "100.78.201.16"
  langfuse: "100.78.201.15"
  certifier: "100.78.201.14"
imagePullSecretName: "jfrog-registry"   # K8s secret name (from .env)
images:
  alpineGit: alpine/git                  # New: for init container
```

### `deploy/helm/ace/templates/_helpers.tpl`

Added `ace.image` helper template that prefixes `imageRegistry` to any image path.

### `deploy/helm/ace/templates/graphql.yaml`

Changes vs main:
- Added `imagePullSecrets: [{name: {{ .Values.imagePullSecretName }}}]`
- Init container uses `ace.image` helper + CA cert mount + `chartsBranch`
- Added env vars: `IMAGE_REGISTRY`, `IMAGE_PULL_SECRET_NAME`
- CA cert mounted at `/certs` (main had `/etc/ssl/certs/...`)

### `deploy/helm/ace/templates/auth.yaml`

Added `imagePullSecrets` to pod spec.

### `deploy/helm/ace/templates/web.yaml`

- Added `imagePullSecrets`
- Changed service type: `NodePort` → `LoadBalancer` (with azure internal annotation)
- Added `staticIP` conditional
- Image uses `ace.image` helper

### `deploy/helm/ace/templates/certifier.yaml`

- Changed service type: `NodePort` → `LoadBalancer` (with azure internal annotation)
- Added `imagePullSecrets`
- Added `staticIP` conditional

### `deploy/helm/ace/templates/mongodb.yaml`

Added `imagePullSecrets` to pod spec.

### `deploy/helm/ace/templates/litellm.yaml`

Added `imagePullSecrets` to pod spec.

### `deploy/helm/ace/templates/langfuse.yaml`

- Added `imagePullSecrets` to all 6 deployments (web, worker, postgres, redis, clickhouse, minio)
- Changed service type: `NodePort` → `LoadBalancer` (with azure internal annotation)
- Added `staticIP` conditional

### `scripts/setup.sh`

Changes vs main:
- Added Section 4: reads `JFROG_USER`/`JFROG_TOKEN` from env silently (no interactive prompt — delegates credential handling to `apply-cluster-prereqs.sh`)
- Skips `apply-cluster-prereqs.sh` if registry secret already exists
- `generate_helm_values_env()` injects `imageRegistry`, `imagePullSecretName`, `chartsBranch` into `values-env.yaml`
- Requires `.env` to exist (user creates via `cp .env.example .env` before running)

### `scripts/azure_build/run.sh`

All image exports prefixed with `${IMAGE_REGISTRY}`.

### `scripts/azure_build/start-agentcert-v2.sh`

`env_val` defaults include registry prefix. Image tags updated to versioned builds.

### `.env.example`

Added: `IMAGE_REGISTRY`, `IMAGE_PULL_SECRET_NAME`, `CHARTS_BRANCH`, all chaos infra image vars, MCP server images, `CERTIFIER_IMAGE`, `CUSTOM_CA_CERT_PATH`.

### `docker-compose.yml`

Updated graphql image tag.

### `deploy/k8s/graphql.yaml`

Updated graphql image tag.

---

## 3. AgentCert Submodule Changes

### Go Code

| File | Change |
|------|--------|
| `utils/variables.go` | Added `ImagePullSecretName` config field (reads `IMAGE_PULL_SECRET_NAME` env, default `jfrog-registry`) |
| `pkg/chaos_infrastructure/infra_utils.go` | SA YAML uses `utils.Config.ImagePullSecretName` instead of hardcoded string. ManifestParser replaces `#{IMAGE_PULL_SECRET_NAME}` in templates. |
| `pkg/chaos_experiment/ops/service.go` | Injects `--set=global.imageRegistry=...` into install-application workflow args |
| `pkg/helm/service.go` | Adds `--set global.imageRegistry=...` to helm install args |
| `pkg/projects/project_handler.go` | Sets default image registry for new projects from `IMAGE_REGISTRY` env |
| `pkg/agent_registry/helm.go` | Passes registry/sidecar image overrides to flash-agent helm install |

### Manifest YAML Files (14 files)

All `cluster/` and `namespace/` manifests: replaced hardcoded `jfrog-registry` with `#{IMAGE_PULL_SECRET_NAME}` placeholder (resolved at runtime).

Files: `1b_argo_rbac`, `1c_argo_deployment`, `2b_litmus_admin_rbac`, `2c_litmus_deployment`, `3b_agents_deployment`, `4a_mcp_tools_rbac`, `4b_mcp_tools_deployment` (×2 for cluster + namespace scope).

---

## 4. agent-charts Submodule Changes

| File | Change |
|------|--------|
| `charts/flash-agent/templates/deployment.yaml` | `{{- if .Values.registry }}` conditional (prevents double-prefix) |
| `charts/flash-agent/values.yaml` | Added `registry` field |
| `charts/k8s-agent/templates/deployment.yaml` | Added `imagePullSecrets` |
| `charts/k8s-agent/values.yaml` | Added `registry` field |
| `install-agent/main.go` | Added `ensureImagePullSecret()` — copies secret before helm install |
| `litellm/deployment.yaml` | Added `imagePullSecrets` |

---

## 5. app-charts Submodule Changes

| File | Change |
|------|--------|
| `charts/sock-shop/values.yaml` | Added `global.imageRegistry` |
| `charts/sock-shop/templates/_helpers.tpl` | Added image helper that prefixes registry |
| 13 sock-shop deployment templates | Added `imagePullSecrets` |
| `templates/mcptools/*.yaml` | Added `imagePullSecrets` |
| `install-app/main.go` | Added `ensureImagePullSecret()` + `ensureNamespace()` |

---

## 6. chaos-charts Submodule Changes

| Category | Files | Change |
|----------|:---:|--------|
| Faults | 36+ | `spec.definition.image`, `LIB_IMAGE`, `STRESS_IMAGE`, `TC_IMAGE` → registry-prefixed |
| Experiments | 7 | `install-application` and `install-agent` images → versioned tags |

---

## 7. certifier Submodule Changes

| File | Change |
|------|--------|
| `docker-compose.yml` | Image path uses `${IMAGE_REGISTRY}` variable |

---

## Docker Images Built & Pushed

| Image | Tag | Key feature |
|-------|-----|-------------|
| `agentcert/agentcert-graphql` | `v6-dynamic-secret` | Dynamic `IMAGE_PULL_SECRET_NAME` from env |
| `agentcert/agentcert-install-app` | `v3-secret-fix` | Creates secret before helm install |
| `agentcert/agentcert-install-agent` | `v3-template-fix` | Fixed registry prefix template |

---

## Design Principles

1. **Single source of truth** — `.env` file. Change `IMAGE_REGISTRY` once, everything updates.
2. **Credentials never stored in files** — only in K8s secrets (provided via env vars or prompt).
3. **`setup.sh` never prompts for credentials** — delegates to `apply-cluster-prereqs.sh`.
4. **Dynamic secret name** — `IMAGE_PULL_SECRET_NAME` flows from `.env` → Helm → Go code → manifest templates.
5. **Auto-replication** — `jfrog-secret-sync` ensures new namespaces get the secret automatically.
6. **Belt + suspenders** — `install-app`/`install-agent` also create secrets before helm install (race condition fix).
