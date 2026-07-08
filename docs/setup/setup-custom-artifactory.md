---
title: "Private Container Registry"
parent: "Setup"
nav_order: 6
---

# Private Container Registry Setup

<div class="callout callout-info">
<span class="callout-title">When to use this guide</span>
Your AKS/K8s cluster cannot pull images from Docker Hub directly (corporate
proxy, firewall, air-gapped environment). All images must come from a private
registry — JFrog Artifactory, Harbor, ECR, ACR, or any Docker-compatible registry.
</div>

---

## Section 1: JFrog Artifactory (Images Already Pushed)

> **Use this if:** Images are already available in `infyartifactory.jfrog.io/docker-local`
> (the default ACE registry). You just need to deploy the platform.

### Steps

```bash
# 1. Clone & checkout
git clone https://github.com/AgentCert/ace-monorepo.git
cd ace-monorepo && git checkout feature/setup-bug-fixes
git submodule update --init --recursive
cd AgentCert && git checkout feature/docker-images-repository && cd ..
cd agent-charts && git checkout feature/docker-images-repository && cd ..
cd app-charts && git checkout feature/docker-images-repository && cd ..
cd chaos-charts && git checkout feature/docker-images-repository && cd ..
cd certifier && git checkout feature/docker-images-repository && cd ..

# 2. Create .env
cp .env.example .env
# Edit .env — set AZURE_OPENAI_KEY, AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_CHAT_DEPLOYMENT_NAME
# IMAGE_REGISTRY is already set to infyartifactory.jfrog.io/docker-local in .env.example

# 3. Create secrets & namespaces (will prompt for JFrog username/password)
./scripts/apply-cluster-prereqs.sh

# 4. Deploy platform
./scripts/setup.sh

# 5. Done — check services
kubectl get svc -n ace -o custom-columns="SERVICE:.metadata.name,IP:.status.loadBalancer.ingress[0].ip,PORT:.spec.ports[0].port" | grep -E "web|langfuse|certifier"
```

### What `apply-cluster-prereqs.sh` does:

| Action | Details |
|--------|---------|
| Prompts for credentials | Username + token (only if not exported as `JFROG_USER`/`JFROG_TOKEN`) |
| Creates K8s secret | `jfrog-registry` (type: docker-registry) in ace, litmus, sock-shop, litellm, kube-system |
| Patches ServiceAccounts | Adds `imagePullSecrets` to default SA in all namespaces |
| Deploys jfrog-secret-sync | Auto-replicates secret to any new namespace created later |
| Creates CA ConfigMap | Corporate proxy certs from `/usr/local/share/ca-certificates/` |

### What `setup.sh` does (no credentials needed):

| Action | Details |
|--------|---------|
| Generates `values-env.yaml` | From `.env` → Helm values (imageRegistry, imagePullSecretName, chartsBranch) |
| `helm install ace` | Deploys graphql, auth, web, certifier, mongodb, langfuse, litellm |
| Initializes MongoDB | Replica set + admin user |
| Prepares namespaces | litmus, sock-shop, litellm (secrets only — no pods yet) |
| Updates fault registries | Runs `update-all-registries.sh` to set image paths in chaos-charts |

### To skip credential prompts:

```bash
export JFROG_USER="your.email@company.com"
export JFROG_TOKEN="your-api-token"
./scripts/apply-cluster-prereqs.sh
```

---

## Section 2: Custom Registry (New Setup from Scratch)

> **Use this if:** You're using a different registry (Harbor, ECR, ACR, self-hosted)
> and need to push all images yourself before deploying.

### Step 1: Clone & Checkout

Same as Section 1 above.

### Step 2: Configure `.env`

```bash
cp .env.example .env
```

Edit these variables:

```bash
# Your registry (replace with your actual registry path)
IMAGE_REGISTRY=myregistry.example.com/my-repo

# Secret name (any name you choose — used by all pods)
IMAGE_PULL_SECRET_NAME=my-registry-secret

# Git branch for chart repos
CHARTS_BRANCH=feature/docker-images-repository

# Azure OpenAI (required for certifier + flash-agent)
AZURE_OPENAI_KEY=your-key
AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com/
AZURE_OPENAI_CHAT_DEPLOYMENT_NAME=gpt4o
```

> **Note:** Registry credentials (username/password) are NOT stored in `.env`.
> They are provided when running `apply-cluster-prereqs.sh` — either via
> `export JFROG_USER=... JFROG_TOKEN=...` or entered interactively.

### Step 3: Push Images to Your Registry

Run this on a machine with Docker + internet access:

```bash
REG="myregistry.example.com/my-repo"
docker login myregistry.example.com
```

**Custom-built images** (build from source):

| Image | Build command |
|-------|---------------|
| `$REG/agentcert/agentcert-graphql:v6-dynamic-secret` | `docker build -f AgentCert/chaoscenter/graphql/server/Dockerfile AgentCert/chaoscenter/graphql/` |
| `$REG/agentcert/agentcert-auth:latest` | `docker build -f AgentCert/chaoscenter/authentication/Dockerfile AgentCert/chaoscenter/authentication/` |
| `$REG/agentcert/agentcert-web:latest` | `docker build -f AgentCert/chaoscenter/web/Dockerfile AgentCert/chaoscenter/web/` |
| `$REG/agentcert/certifier:latest` | `docker build -f certifier/Dockerfile certifier/` |
| `$REG/agentcert/agentcert-install-app:v3-secret-fix` | `docker build -f app-charts/install-app/Dockerfile app-charts/` |
| `$REG/agentcert/agentcert-install-agent:v3-template-fix` | `docker build -f agent-charts/install-agent/Dockerfile agent-charts/` |
| `$REG/agentcert/agentcert-flash-agent:latest` | `docker build -f flash-agent/Dockerfile flash-agent/` |
| `$REG/agentcert/agent-sidecar:latest` | `docker build -f agent-sidecar/Dockerfile agent-sidecar/` |

**Third-party images** (mirror from Docker Hub):

```bash
# Chaos infrastructure
for img in "litmuschaos/chaos-operator:3.0.0" "litmuschaos/chaos-runner:3.0.0" \
  "litmuschaos/chaos-exporter:3.0.0" "litmuschaos/go-runner:latest" \
  "litmuschaos/litmusportal-event-tracker:3.0.0" \
  "litmuschaos/workflow-controller:v3.3.1" "litmuschaos/argoexec:v3.3.1" \
  "litmuschaos/k8s:latest"; do
    docker pull "docker.io/$img" && docker tag "docker.io/$img" "$REG/$img" && docker push "$REG/$img"
done

# Platform services
for img in "mongo:5" "postgres:17" "redis:7" "litellm/litellm:v1.82.0-stable" \
  "langfuse/langfuse:3" "langfuse/langfuse-worker:3" \
  "clickhouse/clickhouse-server" "minio" "busybox:1.36" "alpine/git"; do
    docker pull "docker.io/$img" && docker tag "docker.io/$img" "$REG/$img" && docker push "$REG/$img"
done

# Sock-shop (test application)
for img in "weaveworksdemos/carts:0.4.8" "weaveworksdemos/catalogue:0.3.5" \
  "weaveworksdemos/front-end:0.3.12" "weaveworksdemos/orders:0.4.7" \
  "weaveworksdemos/payment:0.4.3" "weaveworksdemos/queue-master:0.3.1" \
  "weaveworksdemos/shipping:0.4.8" "weaveworksdemos/user:0.4.7" \
  "weaveworksdemos/user-db:0.3.0" "weaveworksdemos/catalogue-db:0.3.0" \
  "rabbitmq:3.6.8-management" "mongo:3.4" "redis:alpine"; do
    docker pull "docker.io/$img" && docker tag "docker.io/$img" "$REG/$img" && docker push "$REG/$img"
done
```

### Step 4: Create Secrets & Deploy

```bash
# Create secrets (will prompt for registry username/password)
./scripts/apply-cluster-prereqs.sh

# Deploy platform
./scripts/setup.sh
```

### Step 5: Verify

```bash
# All pods running
kubectl get pods -n ace

# Services accessible
kubectl get svc -n ace -o custom-columns="SERVICE:.metadata.name,IP:.status.loadBalancer.ingress[0].ip,PORT:.spec.ports[0].port" | grep -E "web|langfuse|certifier"
```

---

## How It Works

```
.env
 ├── IMAGE_REGISTRY=myregistry.example.com/my-repo
 └── IMAGE_PULL_SECRET_NAME=my-registry-secret
         │
         ├─→ apply-cluster-prereqs.sh (run first)
         │     • Prompts for credentials (once)
         │     • DOCKER_SERVER auto-derived from IMAGE_REGISTRY host
         │     • Creates K8s secret in all namespaces
         │     • Deploys jfrog-secret-sync (auto-replicates to new namespaces)
         │     • Patches ServiceAccounts
         │
         ├─→ setup.sh → helm install (run second)
         │     • Reads IMAGE_REGISTRY → imageRegistry in Helm values
         │     • Reads IMAGE_PULL_SECRET_NAME → imagePullSecretName in Helm values
         │     • All pod templates use {{ .Values.imagePullSecretName }}
         │     • All images use {{ imageRegistry }}/image:tag
         │
         └─→ GraphQL pod (runtime)
               • IMAGE_PULL_SECRET_NAME env var → chaos infra manifests
               • #{IMAGE_PULL_SECRET_NAME} placeholder replaced in all YAML templates
               • New namespaces auto-get secret via jfrog-secret-sync
```

---

## Changing Registry Later

```bash
# 1. Update .env
IMAGE_REGISTRY=newregistry.example.com/new-repo

# 2. Push images to new registry (see Step 3 above)

# 3. Re-run prereqs (prompts for new credentials)
./scripts/apply-cluster-prereqs.sh

# 4. Update fault YAMLs
./scripts/update-all-registries.sh

# 5. Upgrade Helm
helm upgrade ace deploy/helm/ace -n ace -f deploy/helm/ace/values-env.yaml --timeout 10m
```

---

## `.env` Variables Reference

| Variable | Purpose | Default |
|----------|---------|---------|
| `IMAGE_REGISTRY` | Registry prefix for all images | `infyartifactory.jfrog.io/docker-local` |
| `IMAGE_PULL_SECRET_NAME` | K8s secret name for image pulls | `jfrog-registry` |
| `CHARTS_BRANCH` | Git branch for chart repos | `main` |
| `CORPORATE_CA_CERT_DIR` | Directory with `.crt` files (proxy CA) | `/usr/local/share/ca-certificates` |
| `CUSTOM_CA_CERT_PATH` | Single CA cert file path | (empty) |

> Registry credentials (`JFROG_USER`/`JFROG_TOKEN`) are environment variables
> passed to `apply-cluster-prereqs.sh` — they are stored only as a K8s secret,
> never written to any file.

---

## Troubleshooting

### ImagePullBackOff

```bash
kubectl describe pod <pod> -n <ns> | grep -A3 "Error\|Failed"
kubectl get secret $IMAGE_PULL_SECRET_NAME -n <ns>  # verify secret exists
kubectl get sa default -n <ns> -o jsonpath='{.imagePullSecrets}'  # verify SA patched
```

### Pods Pending (OutOfpods)

```bash
# Check node capacity
for node in $(kubectl get nodes --no-headers -o custom-columns=":metadata.name"); do
  cap=$(kubectl get node $node -o jsonpath='{.status.allocatable.pods}')
  running=$(kubectl get pods -A --field-selector=spec.nodeName=$node --no-headers | wc -l)
  echo "$node  capacity=$cap  running=$running  free=$((cap-running))"
done
```

> **Fix:** Use node pools with `--max-pods 110` (AKS default of 30 is too low).

### Certificate Not Generating

```bash
kubectl logs deployment/certifier -n ace --tail=50
kubectl exec -n ace mongodb-0 -- mongosh "mongodb://admin:1234@localhost:27017/agentcert?authSource=admin" \
  --eval 'db.certification_tasks.find({},{status:1}).sort({created_at:-1}).limit(3).pretty()'
```

### Service IPs

```bash
kubectl get svc -n ace -o custom-columns="SERVICE:.metadata.name,TYPE:.spec.type,IP:.status.loadBalancer.ingress[0].ip,PORT:.spec.ports[0].port" | grep -E "web|langfuse|certifier"
```

---

## AKS-Specific Notes

- **Azure Policy:** Requires `service.beta.kubernetes.io/azure-load-balancer-internal: "true"` (already in Helm templates)
- **Max-pods:** Create node pools with `az aks nodepool add --max-pods 110` (30 is too low)
- **Static IPs:** Configure in `deploy/helm/ace/values.yaml` → `staticIP.web`, `staticIP.langfuse`, `staticIP.certifier`
- **Zscaler proxy:** Set `CORPORATE_CA_CERT_DIR` to your cert directory — `apply-cluster-prereqs.sh` creates a ConfigMap mounted into all pods
