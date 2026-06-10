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
- [Certifier API service (Dockerized)](#certifier-api-service-dockerized)
- [Certifier Dev Tools](#certifier-dev-tools)
  - [Dump a Langfuse trace into pipeline-compatible JSON](#dump-a-langfuse-trace-into-pipeline-compatible-json)
  - [Run the full certification end-to-end](#run-the-full-certification-end-to-end)
  - [Render a certification report to PDF](#render-a-certification-report-to-pdf)
- [Admin Actions](#admin-actions)
  - [Build & push all Docker images to Docker Hub](#build--push-all-docker-images-to-docker-hub)
- [Community & Contributing](#community--contributing)
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
> Once `.env` is filled in, bring up **MongoDB + Langfuse + LiteLLM + the Certifier API** with a single script:
>
> ```bash
> ./scripts/start-local-services.sh
> ```
>
> Idempotent — re-run anytime. Scope it with `--only-mongo` / `--only-langfuse` / `--only-litellm` / `--only-certifier` (or the matching `--skip-*` flags). Add `--restart` to recreate already-running services.
>
> **What each step brings up**
>
> | Step | What it does | Reachable at |
> |---|---|---|
> | `mongo` | `mongo:5` single-node replica set (`rs0`) with `admin`/`1234` auth, keyFile, and a persistent named volume. The replica set is initialised on first run. | `mongodb://admin:1234@localhost:27017/?authSource=admin` |
> | `langfuse` | Upstream Langfuse compose stack (clones to `.tmp/langfuse` if not already on disk at `/opt/langfuse` or `~/langfuse`). | http://localhost:4000 |
> | `litellm` | LiteLLM proxy compose stack from `agentcert-stack/litellm-setup/`. | http://localhost:14000 |
> | `certifier` | Builds (if needed) and runs the `certifier:latest` image as `certifier_app`, sharing the script's MongoDB via `host.docker.internal` + `directConnection=true`. Implicitly starts MongoDB first when not already running. | Swagger: http://localhost:8000/docs — OpenAPI: http://localhost:8000/openapi.json |
>
> The certifier reads every env var from the monorepo-root `.env` via `env_file: ../.env` in `certifier/docker-compose.yml` — there is no separate `.env` inside `certifier/`.
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

## Certifier API service (Dockerized)

The full FastAPI certifier — Phase 0 (fault bucketing) → Phase 1 (metrics extraction) → Phase 2 (aggregation) → Phase 3 (12-section certification report) → HTML + PDF rendering via playwright — runs as a single container tagged `certifier:latest` (local) or `agentcert/certifier:latest` (pushed to Docker Hub). The image, compose stack, and start script are designed to share the monorepo's MongoDB rather than ship their own.

### Build locally (default — for developers)

```bash
./scripts/start-local-services.sh --only-certifier            # builds if no image yet
./scripts/start-local-services.sh --only-certifier --restart  # force-recreate after a rebuild
```

The script invokes `docker compose build app` on first use, then runs the
container. The image is tagged `certifier:latest` and is **not** pushed
anywhere.

### Pull from Docker Hub (no build toolchain on target host)

The certifier image is published at **[`docker.io/agentcert/certifier:latest`](https://hub.docker.com/r/agentcert/certifier)**:

| | |
|---|---|
| Repository | `agentcert/certifier` |
| Tag | `latest` |
| Latest digest | `sha256:63e6604bac5ffba71372da37fc761bfaeca664871d6516668801c78d551db7d8` |
| Compressed size | ~685 MB (11 layers) |
| Pulled by | `./scripts/start-local-services.sh --only-certifier --pull-certifier` |

```bash
./scripts/start-local-services.sh --only-certifier --pull-certifier
```

Pulls `agentcert/certifier:latest` from Docker Hub (default tag), then runs.
Override the tag by setting `CERTIFIER_IMAGE` in `.env`, for example:

```bash
# .env
CERTIFIER_IMAGE=agentcert/certifier:latest                 # default
# CERTIFIER_IMAGE=registry.acme.com/certifier:v2.1.0       # private registry
# CERTIFIER_IMAGE=agentcert/certifier@sha256:abcd1234...   # pin by digest
```

`CERTIFIER_IMAGE` is also honoured directly by `certifier/docker-compose.yml`,
so plain `docker compose --env-file ../.env up -d` will pull the same tag if
you've set it.

To publish a new build to Docker Hub, use:

```bash
./scripts/build-and-push.sh
# pushes agentcert/certifier:latest (and the other monorepo images)
```

### Running on a different machine — env handling

The certifier reads **every** env var from a single `.env` at the monorepo
root (or whatever you pass to `--env-file`). On a new host:

1. `git clone` the repo (or copy `certifier/` + `scripts/` + `.env.example`).
2. `cp .env.example .env` and fill in the placeholders (`AZURE_OPENAI_*`,
   `LANGFUSE_*`, `MONGODB_*`, `DOCKERHUB_*`, etc.). `.env` is gitignored.
3. Run the certifier with one of:
   ```bash
   # Pull-mode (no build deps required):
   ./scripts/start-local-services.sh --only-certifier --pull-certifier
   # Build-mode (needs docker + git + ~3 GB of pip cache):
   ./scripts/start-local-services.sh --only-certifier
   ```

The compose file references the env file as `env_file: ../.env`, and every
variable is injected into the container's process environment at startup —
the container itself contains no `.env` file (the `.dockerignore` excludes
it). Compose `environment:` overrides apply on top, notably
`MONGODB_CONNECTION_STRING` which is rewritten to talk to the shared monorepo
mongo via `host.docker.internal` + `directConnection=true`.

### Quick command reference

After `--only-certifier` reports `[OK] Certifier up.`, open
`http://localhost:8000/docs`. The endpoints are:

| Method | Path | What it does |
|---|---|---|
| `POST` | `/api/v1/bucketing-extraction` | Phase 0+1: fetch a trace (Langfuse or file), classify events into per-fault buckets, extract per-fault metrics. Returns `task_id`. |
| `POST` | `/api/v1/aggregation-certification` | Phase 2+3: aggregate every `*_metrics.json` under the experiment's fault-bucketing tree, build a 12-section certification report, render HTML + PDF. Returns `cert_task_id`. |
| `GET`  | `/api/v1/tasks` | Poll a bucketing/extraction task by `experiment_id` + `experiment_run_id`. |
| `GET`  | `/api/v1/cert-tasks` | Poll a certification task by `experiment_id`. |

Outputs land under `certifier/workspace/{agent_id}/{experiment_id}/`:

```
fault-bucketing/{run_id}/
  traces/raw_trace.json
  fault_buckets/{raw_trace_bucket_*.json, bucketing_manifest.json, batch_classification_trace.json}
  ground_truth/*.json
  metrics/*_metrics.json          ← input to Phase 2
  pipeline_summary.json
aggregation/aggregation.json
cert-builder/certification.json
certification/
  cert-{agent_id}-YYYY-MM-DD.html
  cert-{agent_id}-YYYY-MM-DD.pdf
```

End-to-end smoke test (one Langfuse run, ~10 min wall-clock):

```bash
AGENT="<agent_id>"; EXP="<experiment_id>"; RID="<experiment_run_id>"

# Phase 0+1
curl -s -X POST -H "Content-Type: application/json" -d "$(cat <<EOF
{"agent_id":"${AGENT}","experiment_id":"${EXP}","run_id":"${RID}",
 "trace_source":{"type":"langfuse"},"storage_config":{"type":"local"}}
EOF
)" http://localhost:8000/api/v1/bucketing-extraction

# Poll
curl -s "http://localhost:8000/api/v1/tasks?experiment_id=${EXP}&experiment_run_id=${RID}"

# Phase 2+3 (consumes every metrics.json under the experiment)
curl -s -X POST -H "Content-Type: application/json" -d "$(cat <<EOF
{"agent_id":"${AGENT}","agent_name":"vaya","experiment_id":"${EXP}",
 "runs_per_fault":5,"storage_config":{"type":"local"}}
EOF
)" http://localhost:8000/api/v1/aggregation-certification

# Poll
curl -s "http://localhost:8000/api/v1/cert-tasks?experiment_id=${EXP}"
```

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

## Community & Contributing

Questions, ideas, or want to help build ACE? Join us on Slack:

**[👉 AgentCert Slack workspace](https://join.slack.com/t/agentcertific-evj3152/shared_invite/zt-4066ekqer-uIT~K_URfwiC15KlwT5Pjw)**

See [CONTRIBUTING.md](./CONTRIBUTING.md) for setup, branching, commit, issue, and pull-request guidelines.

---

## License

Released under the [MIT License](./LICENSE).
