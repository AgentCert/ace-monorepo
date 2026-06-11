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
- [Quick Start (Docker Compose)](#quick-start-docker-compose)
  - [1. Configuration files](#1-configuration-files)
  - [2. Prerequisites](#2-prerequisites)
  - [3. Bring everything up](#3-bring-everything-up)
  - [4. Cluster scenarios (`CLUSTER_MODE`)](#4-cluster-scenarios-cluster_mode)
  - [5. Langfuse & LiteLLM toggles](#5-langfuse--litellm-toggles)
  - [6. Operating the stack](#6-operating-the-stack)
  - [📚 Detailed setup guides (docs/setup/)](#-detailed-setup-guides--docssetup)
- [Legacy script-based setup](#legacy-script-based-setup)
- [Certifier API service (Dockerized)](#certifier-api-service-dockerized)
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

## Quick Start (Docker Compose)

Everything — the Kubernetes cluster, MongoDB, the AgentCert control plane (auth +
GraphQL + UI), LiteLLM, Langfuse, and the Certifier — comes up with **one command**:

```bash
cp .env.example .env        # then fill in the placeholders (Azure keys etc.)
docker compose up -d
```

No host-side Go/Node/kubectl toolchain is required — the only prerequisites are
**Docker** and the **docker compose** plugin. The stack builds its own images,
provisions a Kubernetes cluster if you don't have one, and wires every service
together from a single `.env`.

> ### 📚 Detailed setup guides — [`docs/setup/`](./docs/setup/)
> Step-by-step, user-friendly docs for every scenario:
> - **[Setup overview & prerequisites](./docs/setup/README.md)**
> - **[Configuration & changing ports](./docs/setup/configuration.md)** — every `.env` switch + how to move busy ports
> - **[Route 1 — reuse an existing local cluster](./docs/setup/route-1-existing-cluster.md)**
> - **[Route 2 — fresh machine (compose creates kind)](./docs/setup/route-2-fresh-kind.md)**
> - **[Route 3 — cloud Kubernetes (AKS/EKS/GKE)](./docs/setup/route-3-cloud-aks.md)**
> - **[Running your first experiment](./docs/setup/running-an-experiment.md)** — create infra → enable chaos → apply YAML → run → certify

### 1. Configuration files

```bash
cp .env.example .env
```

Fill in `.env` — at minimum the `AZURE_OPENAI_*` keys. The compose-specific
switches live in the **"Docker Compose one-command bring-up"** block at the
bottom of `.env`:

| Variable | Default | Purpose |
|---|---|---|
| `CLUSTER_MODE` | `auto` | How the Kubernetes cluster is sourced — see [§4](#4-cluster-scenarios-cluster_mode). |
| `KIND_CLUSTER_NAME` | `agentcert` | Name of the kind cluster created/reused. |
| `HOST_KUBE_DIR` | `~/.kube` | Host kube dir mounted into the control plane. |
| `HOST_PUBLIC_IP` | _(empty)_ | Required only for `CLUSTER_MODE=cloud` (pod call-backs). |
| `LANGFUSE_MODE` | `local` | `local` runs Langfuse in-stack; `external` uses `LANGFUSE_HOST`. |
| `LITELLM_MODE` | `local` | `local` runs the LiteLLM proxy; `external` uses `LITELLM_HOST`. |
| `COMPOSE_PROFILES` | `langfuse,litellm` | Profiles activated (derive from the two `*_MODE` switches). |

> **Note** &nbsp;`build-paths.env` is no longer needed for the compose flow — it
> is only used by the [legacy scripts](#legacy-script-based-setup).

### 2. Prerequisites

| Tool | Install |
|------|---------|
| Docker (28+) | `sudo apt-get install docker.io` |
| docker compose plugin (v2.20+) | bundled with recent Docker; `docker compose version` to check |

For `CLUSTER_MODE` `fresh`/`auto`, the one-shot `cluster-init` container uses the
mounted docker socket to create a [kind](https://kind.sigs.k8s.io) cluster — no
host install of kind/kubectl is required.

### 3. Bring everything up

```bash
docker compose up -d          # build images + start the full stack
docker compose ps             # watch services become healthy
docker compose logs -f graphql
```

Order is enforced by `depends_on`: `cluster-init` resolves Kubernetes →
`mongo`/`mongo-init` initialise the replica set → `auth`, then `graphql`, then
`web` start; `litellm`, `langfuse`, and the `certifier` come up alongside.

**Reachable at**

| Service | URL |
|---|---|
| AgentCert UI | http://localhost:2001 |
| GraphQL (REST/WS) | http://localhost:8081 |
| Auth (REST) | http://localhost:3000 |
| Certifier (Swagger) | http://localhost:8000/docs |
| LiteLLM proxy | http://localhost:14000 |
| Langfuse | http://localhost:4000 |
| MongoDB | `mongodb://admin:1234@localhost:27017/?replicaSet=rs0&authSource=admin` |

Login with `ADMIN_USERNAME` / `ADMIN_PASSWORD` from `.env` (defaults `admin` /
`litmus`).

> The UI now serves over **HTTP on :2001** (prod nginx image), replacing the old
> dev server's self-signed HTTPS.

### 4. Cluster scenarios (`CLUSTER_MODE`)

The one-shot `cluster-init` service resolves a working Kubernetes context before
the control plane starts. Pick the value that matches your environment:

| `CLUSTER_MODE` | Scenario | Behaviour |
|---|---|---|
| `auto` _(default)_ | "just work" | Probe the mounted kubeconfig — **reuse it if it works** (covers both cloud and local), **otherwise create a kind cluster**. |
| `cloud` | **K8s on cloud, VM logged in** (AKS/EKS/GKE) | Reuse the existing cloud context. Set `HOST_PUBLIC_IP` so in-cluster pods can call back to this VM. Exec-auth kubeconfigs (`az`/`aws`/`gcloud`) need the cloud CLI + creds mounted — see the override snippet below. |
| `local` | **Existing local cluster** (kind/minikube/k3s) | Reuse the existing local context; fail fast if none is reachable. |
| `fresh` / `kind` | **Starting from scratch** | Always ensure a local kind cluster named `KIND_CLUSTER_NAME` (reusing `local-personal-workspace/kind-agentcert.yaml` if present). |

The control-plane containers run on the **host network**, so they bind the same
ports the old scripts did and the `.env` contract (`172.26.0.1` = the kind
network gateway / `localhost`) keeps working unchanged across all four cases.

**Cloud exec-auth override** — for `CLUSTER_MODE=cloud` when your kubeconfig uses
a CLI auth plugin, drop a `docker-compose.override.yml` next to the root compose:

```yaml
services:
  cluster-init:
    volumes:
      - ${HOME}/.azure:/root/.azure          # or ~/.aws, ~/.config/gcloud
  graphql:
    volumes:
      - ${HOME}/.azure:/root/.azure
```

(and bake the relevant CLI into the `graphql` image, or generate a token-based
kubeconfig). For most demos, `auto` against a local kind cluster is simplest.

### 5. Langfuse & LiteLLM toggles

- **`LANGFUSE_MODE=local`** (default) brings up the vendored Langfuse stack
  (`compose/langfuse/`) under the `langfuse` profile and **auto-provisions** the
  org/project/API keys from `.env` (`LANGFUSE_*`) on first boot — no manual UI
  setup. Set **`LANGFUSE_MODE=external`** and remove `langfuse` from
  `COMPOSE_PROFILES` to point at a hosted Langfuse via `LANGFUSE_HOST`.
- **`LITELLM_MODE=local`** (default) runs the LiteLLM proxy under the `litellm`
  profile. Set **`external`** and drop `litellm` from `COMPOSE_PROFILES` to use a
  remote gateway via `LITELLM_HOST`.

`COMPOSE_PROFILES` is what compose actually reads; keep it in sync with the two
`*_MODE` switches (both local → `langfuse,litellm`).

### 6. Operating the stack

```bash
docker compose up -d --build       # rebuild after code changes
docker compose ps                  # status / health
docker compose logs -f graphql     # tail a service
docker compose restart graphql     # restart one service
docker compose down                # stop everything (keeps volumes/data)
docker compose down -v             # stop + wipe mongo/langfuse/litellm volumes
```

The kind cluster created by `cluster-init` is **not** removed by
`docker compose down` (it lives outside compose). Remove it explicitly with
`kind delete cluster --name agentcert`.

---

## Legacy script-based setup

The original shell-script flow still works and is kept for development against
host-run Go/Node processes. It requires the host toolchain (Go, Node/yarn,
kubectl) and both config files (`.env` + `build-paths.env`):

```bash
cp .env.example .env
cp build-paths.env.example build-paths.env
./scripts/start-local-services.sh          # MongoDB + Langfuse + LiteLLM + Certifier
bash scripts/azure_build/start-agentcert-v2.sh \
    --env-file   $(pwd)/.env \
    --paths-file $(pwd)/build-paths.env     # auth + GraphQL + frontend on the host
bash AgentCert/stop-agentcert.sh           # stop the host processes
```

See [`scripts/azure_build/AZURE_BUILD_GUIDE.md`](./scripts/azure_build/AZURE_BUILD_GUIDE.md)
for the build-pipeline walk-through (image builds, Docker Hub pushes, the
`--llm` flag).


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

## License

Released under the [MIT License](./LICENSE).
