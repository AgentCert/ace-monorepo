---
title: "Local Development (host processes)"
parent: "Setup"
nav_order: 7
---

# Local Development — Host Processes

<div class="callout callout-info">
<span class="callout-title">Use this route when…</span>
You are actively developing the Go backend (auth / GraphQL) or the React frontend
and want to run them directly on the host — hot-reload, <code>go run</code>, debugger
attached — rather than inside Kubernetes. MongoDB, Langfuse, LiteLLM, and the
Certifier still run in Docker; only the control-plane processes run on the host.
</div>

This is the original bring-up path and requires the full host toolchain (Go, Node/yarn).
For production-like deployments use [Route 2 (kind)]({{ "/setup/route-2-fresh-kind.html" | relative_url }}) instead.

---

## 1. Configuration Files

Copy the two example files at the repo root and fill them in:

```bash
cp .env.example .env
cp build-paths.env.example build-paths.env
```

- **`.env`** — secrets, image tags, ports, MongoDB / Langfuse / LiteLLM / Azure OpenAI endpoints. Replace every `CHANGE_ME` and `REPLACE_ME` placeholder.
- **`build-paths.env`** — submodule checkout paths and git URLs. Paths are resolved relative to the file's own location, so no editing is required — copy it and the configuration is complete.

> **Tip** — the bridge IP `172.26.0.1` in the examples is the Docker bridge gateway. Find yours with `ip -4 addr show docker0 | grep inet` and replace it everywhere.

---

## 2. Prerequisites

| Tool | Install |
|------|---------|
| Docker | `sudo apt-get install docker.io` |
| Go 1.21+ | `sudo apt-get install golang-go` |
| Node.js + yarn | `sudo apt-get install nodejs npm && npm install -g yarn` |
| kubectl | `sudo snap install kubectl --classic` |
| git | `sudo apt-get install git` |

---

## 3. Start Local Services (MongoDB + Langfuse + LiteLLM + Certifier)

> **Recommended — one command for all local services**

Once `.env` is filled in, bring up MongoDB, Langfuse, LiteLLM, and the Certifier API with a single script:

```bash
./scripts/start-local-services.sh
```

Idempotent — re-run anytime. Scope it with `--only-mongo` / `--only-langfuse` /
`--only-litellm` / `--only-certifier` (or the matching `--skip-*` flags). Add
`--restart` to recreate already-running services.

| Step | What it does | Reachable at |
|---|---|---|
| `mongo` | `mongo:5` single-node replica set (`rs0`) with `admin`/`1234` auth and a persistent named volume | `mongodb://admin:1234@localhost:27017/?authSource=admin` |
| `langfuse` | Upstream Langfuse compose stack | http://localhost:4000 |
| `litellm` | LiteLLM proxy from `agentcert-stack/litellm-setup/` | http://localhost:14000 |
| `certifier` | Builds (if needed) and runs the `certifier:latest` image, sharing MongoDB via `host.docker.internal` | Swagger: http://localhost:8000/docs |

The certifier reads every env var from the monorepo-root `.env` — there is no
separate `.env` inside `certifier/`.

**If you run this, skip sections 3a–3c and jump straight to [§4 Kubernetes cluster access](#4-kubernetes-cluster-access).**

<details>
<summary><b>3a–3c — manual alternatives</b> (only if you need a non-default config)</summary>

### 3a. MongoDB

```bash
docker run -d --name agentcert-mongo -p 27017:27017 \
  -e MONGO_INITDB_ROOT_USERNAME=admin \
  -e MONGO_INITDB_ROOT_PASSWORD=CHANGE_ME \
  mongo:5
```

Update `MONGODB_USERNAME`, `MONGODB_PASSWORD`, and `DB_SERVER` in `.env` to match.

### 3b. Langfuse

```bash
git clone https://github.com/langfuse/langfuse.git /tmp/langfuse
cd /tmp/langfuse
docker compose up -d
```

In the Langfuse UI (default `http://localhost:3000`):
1. Create an organization + project.
2. Settings → API Keys → create a key pair.
3. Put the public/secret keys into `.env` as `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY`.
4. Set `LANGFUSE_HOST` to a URL reachable from both the host and any in-cluster pod (use the docker-bridge IP, not `localhost`).

### 3c. LiteLLM

**Local (Docker Compose):**

```bash
cd agentcert-stack/litellm-setup
docker compose -f docker-compose-litellm.yml up -d
```

Set `LITELLM_HOST=http://<docker-bridge-ip>:14000` in `.env`.

**In-cluster (Kubernetes):**

```bash
kubectl apply -f agent-charts/litellm/namespace.yaml
kubectl apply -f agent-charts/litellm/secret.yaml      # edit first with your keys
kubectl apply -f agent-charts/litellm/configmap.yaml
kubectl apply -f agent-charts/litellm/deployment.yaml
kubectl port-forward -n litellm svc/litellm-proxy 14000:4000
```

</details>

---

## 4. Kubernetes Cluster Access

The GraphQL server launches chaos experiments and install jobs as Kubernetes resources.

```bash
kubectl config current-context
kubectl get nodes

# Common ways to wire it up:
# kind (local):   kind create cluster --name agentcert
# AKS:            az aks get-credentials --resource-group <rg> --name <cluster>
# GKE:            gcloud container clusters get-credentials <cluster> --zone <zone>
# EKS:            aws eks update-kubeconfig --name <cluster> --region <region>
```

Required namespaces (`litmus`, `litellm`, `sock-shop`) are created on demand by
the install jobs.

---

## 5. Start AgentCert

Once `.env`, `build-paths.env`, MongoDB, Langfuse, LiteLLM, and `kubectl` are all
set up:

```bash
bash scripts/azure_build/start-agentcert-v2.sh \
  --env-file   $(pwd)/.env \
  --paths-file $(pwd)/build-paths.env
```

**What it does:**

1. Frees ports `3000`, `3030`, `8081`, `8082`, `2001` (prompts before killing).
2. Ensures MongoDB is running (skip with `--skip-mongo`).
3. Exports every variable from `.env` and starts:
   - **Auth service** (`go run`) on `:3000` (REST) / `:3030` (gRPC)
   - **GraphQL server** (built binary) on `:8081`
   - **Frontend** (`yarn dev`) on `https://localhost:2001` (skip with `--skip-frontend`)
4. Logs go to `/tmp/agentcert-runtime/.{auth,graphql,frontend}.log`.

Login with `ADMIN_USERNAME` / `ADMIN_PASSWORD` from `.env` (defaults `admin` / `litmus`).

**Stop everything:**

```bash
bash AgentCert/stop-agentcert.sh
```

For a deeper walk-through of the build pipeline (image builds, Docker Hub pushes,
the `--llm` flag), see [`scripts/azure_build/AZURE_BUILD_GUIDE.md`](../../scripts/azure_build/AZURE_BUILD_GUIDE.md).

---

## Certifier in Local Dev Mode

In this path the certifier runs at **`http://localhost:8000/docs`** (not `:18000`
— that port is only used in the Kubernetes setup to avoid conflicts).

### Build locally

```bash
./scripts/start-local-services.sh --only-certifier            # builds if no image yet
./scripts/start-local-services.sh --only-certifier --restart  # force-recreate after a rebuild
```

### Pull from Docker Hub (no build toolchain)

```bash
./scripts/start-local-services.sh --only-certifier --pull-certifier
```

Override the image tag via `CERTIFIER_IMAGE` in `.env`:

```bash
CERTIFIER_IMAGE=agentcert/certifier:latest
# CERTIFIER_IMAGE=agentcert/certifier@sha256:<digest>
```

### Quick command reference

| Method | Path | What it does |
|---|---|---|
| `POST` | `/api/v1/bucketing-extraction` | Phase 0+1: fetch trace, classify events, extract metrics. Returns `task_id`. |
| `POST` | `/api/v1/aggregation-certification` | Phase 2+3: aggregate metrics, build 12-section report, render PDF. Returns `cert_task_id`. |
| `GET`  | `/api/v1/tasks` | Poll by `experiment_id` + `experiment_run_id`. |
| `GET`  | `/api/v1/cert-tasks` | Poll by `experiment_id`. |

End-to-end smoke test:

```bash
AGENT="<agent_id>"; EXP="<experiment_id>"; RID="<experiment_run_id>"

curl -s -X POST -H "Content-Type: application/json" -d "$(cat <<EOF
{"agent_id":"${AGENT}","experiment_id":"${EXP}","run_id":"${RID}",
 "trace_source":{"type":"langfuse"},"storage_config":{"type":"local"}}
EOF
)" http://localhost:8000/api/v1/bucketing-extraction

curl -s "http://localhost:8000/api/v1/tasks?experiment_id=${EXP}&experiment_run_id=${RID}"

curl -s -X POST -H "Content-Type: application/json" -d "$(cat <<EOF
{"agent_id":"${AGENT}","agent_name":"vaya","experiment_id":"${EXP}",
 "runs_per_fault":5,"storage_config":{"type":"local"}}
EOF
)" http://localhost:8000/api/v1/aggregation-certification

curl -s "http://localhost:8000/api/v1/cert-tasks?experiment_id=${EXP}"
```

---

## Service Ports (local dev)

| Service | Port | Notes |
|---|---|---|
| AgentCert UI | https://localhost:2001 | `yarn dev` — self-signed cert |
| GraphQL REST | http://localhost:8081 | host Go process |
| Auth REST | http://localhost:3000 | host Go process |
| Auth gRPC | localhost:3030 | host Go process |
| Certifier | http://localhost:8000/docs | Docker container |
| LiteLLM | http://localhost:14000 | Docker container |
| Langfuse | http://localhost:4000 | Docker container |
| MongoDB | localhost:27017 | Docker container |
