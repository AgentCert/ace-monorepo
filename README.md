<div align="center">

# ACE Monorepo

#### Agent Certification Engine

<p>
  <a href="./LICENSE"><img alt="License" src="https://img.shields.io/badge/License-MIT-blue.svg"></a>
  <img alt="Go" src="https://img.shields.io/badge/Go-1.21+-00ADD8.svg?logo=go&logoColor=white">
  <img alt="Kubernetes" src="https://img.shields.io/badge/Kubernetes-326CE5.svg?logo=kubernetes&logoColor=white">
  <img alt="Docker" src="https://img.shields.io/badge/Docker-2496ED.svg?logo=docker&logoColor=white">
  <img alt="MongoDB" src="https://img.shields.io/badge/MongoDB-4.2-47A248.svg?logo=mongodb&logoColor=white">
  <img alt="Langfuse" src="https://img.shields.io/badge/Tracing-Langfuse-1F5BFF.svg">
  <img alt="LiteLLM" src="https://img.shields.io/badge/Gateway-LiteLLM-6F42C1.svg">
</p>

</div>

---

## Table of Contents

- [About ACE](#about-ace)
- [Submodules](#submodules)
- [Getting the Code](#getting-the-code)
- [Setup](#setup)
  - [1. Configuration files](#1-configuration-files)
  - [2. Prerequisites](#2-prerequisites)
  - [3. MongoDB](#3-mongodb)
  - [4. Langfuse](#4-langfuse)
  - [5. LiteLLM](#5-litellm)
  - [6. Kubernetes cluster access](#6-kubernetes-cluster-access)
  - [7. Start AgentCert](#7-start-agentcert)
- [Certifier Dev Tools](#certifier-dev-tools)
  - [Dump a Langfuse trace into pipeline-compatible JSON](#dump-a-langfuse-trace-into-pipeline-compatible-json)
  - [Run the full certification end-to-end](#run-the-full-certification-end-to-end)
  - [Render a certification report to PDF](#render-a-certification-report-to-pdf)
- [Admin Actions](#admin-actions)
  - [Build & push all Docker images to Docker Hub](#build--push-all-docker-images-to-docker-hub)
- [License](#license)

---

## About ACE

**ACE** stands for **Agent Certification Engine** — a platform for evaluating, fault-injecting, and certifying autonomous agents under controlled chaos conditions. This monorepo aggregates every component required to run the platform end-to-end.

- **Purpose.** Produce reproducible certification reports that quantify how an agent behaves under faults, with evidence (traces, metrics, ground truth) preserved at every phase.
- **Architecture.** A GraphQL control plane (AgentCert) drives chaos experiments on Kubernetes; the certifier consumes the resulting Langfuse traces and emits a multi-phase certification artifact (JSON + PDF).
- **Pipeline.** Phase 0 (trace ingest) → Phase 1 (fault bucketing) → Phase 2 (statistical aggregation) → Phase 3 (certificate build).
- **Local stack.** MongoDB for persistence, Langfuse for OTEL trace storage, LiteLLM as the unified LLM gateway in front of Azure OpenAI.
- **Layout.** Each concern lives in its own submodule (see [Submodules](#submodules)) so components can be versioned, built, and released independently.

---

## Submodules

| Module | Description |
|--------|-------------|
| [AgentCert](./AgentCert) | Core AgentCert platform |
| [app-charts](./app-charts) | Application Helm charts |
| [agent-charts](./agent-charts) | Agent Helm charts |
| [certifier](./certifier) | Certification engine |
| [flash-agent](./flash-agent) | Flash agent implementation |
| [agentcert-stack](./agentcert-stack) | Full stack deployment |
| [chaos-charts](./chaos-charts) | Chaos engineering charts |

---

## Getting the Code

**Clone with submodules**

```bash
git clone --recurse-submodules <repo-url>
```

**Initialize submodules** (if already cloned)

```bash
git submodule update --init --recursive
```

**Update all submodules to latest**

```bash
git submodule update --remote --merge
```

---

## Setup

End-to-end bring-up: configure env files → install MongoDB / Langfuse / LiteLLM → configure `kubectl` → run [`start-agentcert-v2.sh`](./scripts/azure_build/start-agentcert-v2.sh).

### 1. Configuration files

Copy the two example files at the repo root and fill them in:

```bash
cp .env.example .env
cp build-paths.env.example build-paths.env
```

- [`.env.example`](./.env.example) — secrets, image tags, ports, MongoDB / Langfuse / LiteLLM / Azure OpenAI endpoints. Replace every `CHANGE_ME` and `REPLACE_ME` placeholder.
- [`build-paths.env.example`](./build-paths.env.example) — submodule checkout paths and git URLs. Paths are resolved relative to the file's own location, so no editing is required — copy (or symlink) it to `build-paths.env` and the configuration is complete.

> **Note** &nbsp;`.env` is gitignored — never commit secrets. `build-paths.env` carries no machine-specific state and is safe to commit if you prefer to skip the copy step.

> **Tip** &nbsp;The bridge IP `172.26.0.1` in the examples is the docker bridge gateway. Locate yours with `ip -4 addr show docker0 | grep inet` and replace it everywhere.

### 2. Prerequisites

| Tool | Install |
|------|---------|
| Docker | `sudo apt-get install docker.io` |
| Go 1.21+ | `sudo apt-get install golang-go` |
| Node.js + yarn | `sudo apt-get install nodejs npm && npm install -g yarn` |
| kubectl | `sudo snap install kubectl --classic` |
| git | `sudo apt-get install git` |

> [!IMPORTANT]
> ### ⭐ Recommended path — one command for all local services
>
> Once `.env` is filled in, bring up **MongoDB + Langfuse + LiteLLM** with a single script:
>
> ```bash
> ./scripts/start-local-services.sh
> ```
>
> Idempotent — re-run anytime. Scope it with `--only-mongo` / `--only-langfuse` / `--only-litellm` (or the matching `--skip-*` flags).
>
> **➡ If you run this, skip sections 3–5 and jump straight to [§6 Kubernetes cluster access](#6-kubernetes-cluster-access).**

<details>
<summary><b>Sections 3–5 — manual alternatives</b> (only needed if you want to inspect each step or run a service against a non-default config)</summary>

### 3. MongoDB

The startup script will start a `mongo:4.2` container automatically (`agentcert-mongo`, port `27017`). To start one manually:

```bash
docker run -d --name agentcert-mongo -p 27017:27017 \
  -e MONGO_INITDB_ROOT_USERNAME=admin \
  -e MONGO_INITDB_ROOT_PASSWORD=CHANGE_ME \
  mongo:4.2
```

Update `MONGODB_USERNAME`, `MONGODB_PASSWORD`, and `DB_SERVER` in `.env` to match.

### 4. Langfuse

Langfuse is the OTEL backend for agent traces. Run a local instance via the official Langfuse compose stack:

```bash
git clone https://github.com/langfuse/langfuse.git /tmp/langfuse
cd /tmp/langfuse
docker compose up -d
```

Then, in the Langfuse UI (default `http://localhost:3000`):

1. Create an organization + project.
2. Settings → API Keys → create a key pair.
3. Put the public/secret keys into `.env` as `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY`.
4. Set `LANGFUSE_HOST` to a URL reachable from BOTH the host and any in-cluster pod (use the docker-bridge IP, not `localhost`).

### 5. LiteLLM

LiteLLM is a unified LLM gateway in front of Azure OpenAI. Two deployment modes:

**a) Local (Docker Compose)** — recommended for local development:

```bash
cd agentcert-stack/litellm-setup
docker compose -f docker-compose-litellm.yml up -d
# Proxy is now at http://localhost:4000
```

Set `LITELLM_HOST=http://<docker-bridge-ip>:4000` in `.env`.

**b) In-cluster (Kubernetes)**:

```bash
kubectl apply -f agent-charts/litellm/namespace.yaml
kubectl apply -f agent-charts/litellm/secret.yaml      # edit first with your keys
kubectl apply -f agent-charts/litellm/configmap.yaml
kubectl apply -f agent-charts/litellm/deployment.yaml
# Port-forward so the host process can reach it:
kubectl port-forward -n litellm svc/litellm-proxy 14000:4000
```

Set `LITELLM_HOST=http://<docker-bridge-ip>:14000` in `.env`.

In either mode, `LITELLM_MASTER_KEY` in `.env` must match the value compiled into the LiteLLM config / secret.

</details>

### 6. Kubernetes cluster access

The GraphQL server launches chaos experiments and install jobs as Kubernetes resources, so it needs a working `kubectl` context.

```bash
# Check current context
kubectl config current-context
kubectl get nodes

# Common ways to wire it up:
# - AKS:        az aks get-credentials --resource-group <rg> --name <cluster>
# - GKE:        gcloud container clusters get-credentials <cluster> --zone <zone>
# - EKS:        aws eks update-kubeconfig --name <cluster> --region <region>
# - Local kind: kind create cluster --name agentcert
# - Existing kubeconfig: export KUBECONFIG=/path/to/kubeconfig
```

The startup script reads the active context from `~/.kube/config` (override with `KUBECONFIG`). Required namespaces — `litmus`, `litellm`, and the application namespace (`sock-shop` by default for MCP URLs in `.env`) — are created on demand by the install jobs.

> **Note** &nbsp;If you don't have a cluster yet and just want the local services up, pass `--skip-litellm` to the startup script.

### 7. Start AgentCert

Once `.env`, `build-paths.env`, MongoDB, Langfuse, LiteLLM, and `kubectl` are all set up:

```bash
bash scripts/azure_build/start-agentcert-v2.sh \
  --env-file   $(pwd)/.env \
  --paths-file $(pwd)/build-paths.env
```

**What it does**

1. Frees ports `3000`, `3030`, `8081`, `8082`, `2001` (prompts before killing).
2. Ensures MongoDB is running (skip with `--skip-mongo`).
3. Exports every variable from `.env` and starts:
   - **Auth service** (`go run`) on `:3000` (REST) / `:3030` (gRPC)
   - **GraphQL server** (built binary) on `:8081`
   - **Frontend** (`yarn dev`) on `https://localhost:2001` (skip with `--skip-frontend`)
4. Logs go to `/tmp/agentcert-runtime/.{auth,graphql,frontend}.log`.

Login with `ADMIN_USERNAME` / `ADMIN_PASSWORD` from `.env` (defaults: `admin` / `litmus`).

**Stop everything**

```bash
bash AgentCert/stop-agentcert.sh
```

For a deeper walk-through of the build pipeline (image builds, Docker Hub pushes, the `--llm` flag), see [`scripts/azure_build/AZURE_BUILD_GUIDE.md`](./scripts/azure_build/AZURE_BUILD_GUIDE.md).

---

## Certifier Dev Tools

Two helper scripts in `scripts/` run the certifier pipeline locally without starting the FastAPI service. Both invoke the same `TraceService` / `BucketPipelineService` / `CertPipelineService` code paths used by the running service, and read `LANGFUSE_*` / `AZURE_OPENAI_*` from the root `.env`.

### Dump a Langfuse trace into pipeline-compatible JSON

`scripts/dump_langfuse_trace.py` fetches a single trace from Langfuse and writes `raw_trace.json` plus a `trace_meta.json` summary. This is useful for collecting offline samples that the certifier can later consume via a `FileTraceSource`.

```bash
./scripts/dump_langfuse_trace.py \
  --experiment-id <UUID> \
  --run-id        <UUID>

# or override the dump dir
./scripts/dump_langfuse_trace.py \
  --experiment-id <UUID> --run-id <UUID> \
  --output-dir ./.tmp/sample-001
```

### Run the full certification end-to-end

`scripts/run_certification.py` runs Phase 0+1+2+3 against one trace and writes outputs into `.tmp/` (gitignored) using the same on-disk layout the production API workers create:

```
.tmp/{agent_id}/{experiment_id}/
  fault-bucketing/{run_id}/
    traces/raw_trace.json
    fault_buckets/*.json
    metrics/*_metrics.json
    ground_truth/*.json
    pipeline_summary.json
  aggregation/aggregation.json
  cert-builder/certification.json   ← final certificate (JSON)
  cert-builder/certification.pdf    ← rendered PDF (auto-generated)
```

```bash
# Look up agent/experiment/run IDs automatically from a Langfuse trace ID
./scripts/run_certification.py --trace-id <LANGFUSE_TRACE_UUID>

# Or pass the IDs directly (no metadata lookup)
./scripts/run_certification.py \
  --agent-id      <UUID> \
  --experiment-id <UUID> \
  --run-id        <UUID> \
  --agent-name    vaya

# Stop after Phase 0+1 (skip aggregation + cert builder)
./scripts/run_certification.py --trace-id <UUID> --skip-cert
```

Optional flags: `--workspace <dir>` (default `.tmp/`), `--batch-size` (LLM classification batch size, default 10), `--runs-per-fault` (default 1, used for Phase 2 statistical-significance checks), `--no-pdf` (skip the PDF render step), and `--debug` (retain Phase 3 intermediates).

### Render a certification report to PDF

The `run_certification.py` script renders the PDF automatically. To re-render an existing `certification.json` (or one produced by the running service), use `scripts/render_certification_pdf.py`:

```bash
pip install --user reportlab    # one-time, only needed for PDF output

./scripts/render_certification_pdf.py \
  --input  .tmp/<agent_id>/<exp_id>/cert-builder/certification.json
# → writes certification.pdf next to the input

# or pick a custom output path
./scripts/render_certification_pdf.py \
  --input  certification.json \
  --output ./out/agent-cert.pdf
```

---

## Admin Actions

### Build & push all Docker images to Docker Hub

Builds all component images and pushes them to `docker.io/agentcert/*`. Requires `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` in the root `.env`.

```bash
./scripts/build-and-push.sh
```

**Images pushed**

- `agentcert/agentcert-flash-agent:latest`
- `agentcert/agent-sidecar:latest`
- `agentcert/agentcert-install-agent:latest`
- `agentcert/agentcert-install-app:latest`
- `agentcert/certifier:latest`

To use a different env file:

```bash
./scripts/build-and-push.sh --env-file /path/to/.env
```

---

## License

Released under the [MIT License](./LICENSE).
