
<div align="center">

# ACE Monorepo

#### Agent Certification Engine

<p>
  <a href="./LICENSE"><img alt="License" src="https://img.shields.io/badge/License-Apache%202.0-blue.svg"></a>
  <img alt="Go" src="https://img.shields.io/badge/Go-1.24+-00ADD8.svg?logo=go&logoColor=white">
  <img alt="Kubernetes" src="https://img.shields.io/badge/Kubernetes-326CE5.svg?logo=kubernetes&logoColor=white">
  <img alt="Docker Compose" src="https://img.shields.io/badge/Docker%20Compose-one--command-2496ED.svg?logo=docker&logoColor=white">
  <img alt="MongoDB" src="https://img.shields.io/badge/MongoDB-5.0-47A248.svg?logo=mongodb&logoColor=white">
  <img alt="Langfuse" src="https://img.shields.io/badge/Tracing-Langfuse-1F5BFF.svg">
  <img alt="LiteLLM" src="https://img.shields.io/badge/Gateway-LiteLLM-6F42C1.svg">
</p>

</div>

---

## Table of Contents

- [About ACE](#about-ace)
- [Documentation](#documentation)
- [Submodules](#submodules)
- [Getting the Code](#getting-the-code)
- [Quick Start (Docker Compose)](#quick-start-docker-compose)
  - [1. Configuration files](#1-configuration-files)
  - [2. Prerequisites](#2-prerequisites)
  - [3. Bring everything up](#3-bring-everything-up)
  - [4. Cluster scenarios (`CLUSTER_MODE`)](#4-cluster-scenarios-cluster_mode)
  - [5. MongoDB / Langfuse / LiteLLM toggles](#5-mongodb--langfuse--litellm-toggles)
  - [6. Operating the stack](#6-operating-the-stack)
  - [📚 Detailed setup guides (docs/setup/)](#-detailed-setup-guides--docssetup)
- [Legacy script-based setup](#legacy-script-based-setup)
- [Certifier API service (Dockerized)](#certifier-api-service-dockerized)
- [Certifier endpoint configuration (for AgentCert integration)](#certifier-endpoint-configuration-for-agentcert-integration)
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

## Documentation

All project documentation lives in **[`docs/`](./docs)**:

| Area | Where | What's inside |
|---|---|---|
| **Setup & operations** | [`docs/setup/`](./docs/setup/) | One-command bring-up, the three cluster routes, configuration & port reference, and the full experiment walkthrough. **Start here** to run the platform. |
| **Architecture** | [`docs/architecture.md`](./docs/architecture.md) | End-to-end system architecture of the control plane + certifier. |
| **Workflow animation** | [`docs/animated_archiecture/`](./docs/animated_archiecture/agentcert_workflow_animation.html) | Self-contained HTML animation of the AgentCert workflow (open in a browser). |
| **Methodology** | [`docs/Methodologies/`](./docs/Methodologies/) | The certification methodology: [introduction](./docs/Methodologies/01-Introduction.md), [experiment design](./docs/Methodologies/02-Experiment-Design.md), [metrics](./docs/Methodologies/03-Metrics.md), [pipeline](./docs/Methodologies/04-Pipeline.md), [certification](./docs/Methodologies/05-Certification.md), [observations](./docs/Methodologies/06-Observations.md). |
| **API** | [`docs/api.md`](./docs/api.md) · [`docs/api-changes-features-api-fixes.md`](./docs/api-changes-features-api-fixes.md) · [`docs/polling-api-redesign.md`](./docs/polling-api-redesign.md) | API reference, change log, and the polling-API redesign. |
| **Storage** | [`docs/mongodb-storage.md`](./docs/mongodb-storage.md) | MongoDB storage model. |
| **Compliance** | [`docs/rai-compliance-workflow.md`](./docs/rai-compliance-workflow.md) | Responsible-AI compliance workflow. |
| **Testing & coverage** | [`docs/testing.md`](./docs/testing.md) | Running the test suites (Python/Go/TS), generating coverage, and the SonarQube dashboard. |

> New to the platform? Go straight to **[`docs/setup/`](./docs/setup/)** and the [Quick Start](#quick-start-docker-compose) below.

---

## Submodules

| Module | Description |
|--------|-------------|
| [AgentCert](./AgentCert) | Core AgentCert platform — GraphQL control plane, auth, web UI |
| [app-charts](./app-charts) | Application Helm charts (e.g. sock-shop) + the install-app image |
| [agent-charts](./agent-charts) | Agent Helm charts + the install-agent image |
| [certifier](./certifier) | Certification engine (FastAPI pipeline → JSON + PDF report) |
| [flash-agent](./flash-agent) | Flash agent implementation (the agent under test) |
| [agent-sidecar](./agent-sidecar) | Sidecar that proxies the agent's LLM/MCP traffic |
| [agentcert-stack](./agentcert-stack) | Full-stack deployment assets (LiteLLM setup, etc.) |
| [chaos-charts](./chaos-charts) | Chaos experiment & fault definitions (tracks `master`) |
| [litmus-go](./litmus-go) | Litmus chaos experiment executors (Go) |

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
./scripts/setup.sh          # interactive: creates .env, asks only what matters
docker compose up -d
```

> First time? **[`./scripts/setup.sh`](./scripts/setup.sh)** is the easy path — it
> creates `.env` and prompts only for the few values that actually matter (Azure
> OpenAI), defaulting everything else. Prefer manual? `cp .env.example .env` and
> fill just the `AZURE_OPENAI_*` block — see [§1](#1-configuration-files).

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

**Easiest — the setup wizard:**

```bash
./scripts/setup.sh
```

It creates `.env` from `.env.example`, asks only for the **Azure OpenAI**
credentials (the one thing that's truly required) plus your `CLUSTER_MODE`, and
defaults everything else. It's idempotent — re-run any time; Enter keeps current
values. It can also bring the stack up for you at the end.

**Manual alternative:**

```bash
cp .env.example .env
```

For the default all-local flow you only need to fill the **`AZURE_OPENAI_*`**
block (key, endpoint, chat deployment) — MongoDB creds, the LiteLLM key, and the
Langfuse keys are all defaulted (Langfuse keys are auto-provisioned for the local
stack). The compose-specific switches live in the **"Docker Compose one-command
bring-up"** block at the bottom of `.env`:

| Variable | Default | Purpose |
|---|---|---|
| `CLUSTER_MODE` | `auto` | How the Kubernetes cluster is sourced — see [§4](#4-cluster-scenarios-cluster_mode). |
| `KIND_CLUSTER_NAME` | `agentcert` | Name of the kind cluster created/reused. |
| `HOST_KUBE_DIR` | `~/.kube` | Host kube dir mounted into the control plane. |
| `HOST_PUBLIC_IP` | _(empty)_ | Required only for `CLUSTER_MODE=cloud` (pod call-backs). |
| `MONGO_MODE` | `local` | `local` runs MongoDB in-stack; `external` reuses one via `DB_SERVER`. |
| `LANGFUSE_MODE` | `local` | `local` runs Langfuse in-stack; `external` uses `LANGFUSE_HOST`. |
| `LITELLM_MODE` | `local` | `local` runs the LiteLLM proxy; `external` uses `LITELLM_HOST`. |
| `COMPOSE_PROFILES` | `mongo,langfuse,litellm` | Profiles compose actually reads — one token per `*_MODE=local`. |
| `LANGFUSE_HOST_COMPOSE` | `http://langfuse-web:3000` | Langfuse URL for compose-bridge services (litellm, certifier); they reach it by service name, not the kind-gateway IP. |

> **Note** &nbsp;`build-paths.env` is no longer needed for the compose flow — it
> is only used by the [legacy scripts](#legacy-script-based-setup). Full
> reference incl. **changing busy ports**: [`docs/setup/configuration.md`](./docs/setup/configuration.md).

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
| `cloud` | **K8s on cloud, VM logged in** (AKS/EKS/GKE) | Reuse the existing cloud context. Repoint the host endpoints (`SERVER_ADDR`, `SUBSCRIBER_CALLBACK_URL`, `LANGFUSE_HOST`, `LITELLM_HOST`) at `HOST_PUBLIC_IP` so remote pods can reach the VM. Use a cert-based kubeconfig (`az aks get-credentials --admin`). See [route 3](./docs/setup/route-3-cloud-aks.md). |
| `local` | **Existing local cluster** (kind/minikube/k3s) | Reuse the existing local context; fail fast if none is reachable. |
| `fresh` / `kind` | **Starting from scratch** | Always ensure a local kind cluster named `KIND_CLUSTER_NAME` (reusing `local-personal-workspace/kind-agentcert.yaml` if present). |

The control-plane containers run on the **host network**, so they bind the same
ports the old scripts did and the `.env` contract (`172.26.0.1` = the kind
network gateway / `localhost`) keeps working unchanged across all four cases.

> **Cloud (route 3) note.** Prefer a **certificate-based** kubeconfig
> (`az aks get-credentials --admin`) — it works with the stock images. An
> exec-auth kubeconfig (Azure AD / `kubelogin`, `aws`, `gcloud`) needs the auth
> plugin baked into **both** the `cluster-init` and `graphql` images, since
> `cluster-init` runs `kubectl cluster-info` first. Full details, the
> `docker-compose.override.yml`, and the firewall/endpoint checklist are in
> [`docs/setup/route-3-cloud-aks.md`](./docs/setup/route-3-cloud-aks.md). For
> most demos, `auto` against a local kind cluster is simplest.

### 5. MongoDB / Langfuse / LiteLLM toggles

Each supporting service can run **in the stack** (`local`) or point at an
**existing** instance (`external`). The `*_MODE` switch decides; `COMPOSE_PROFILES`
must carry the matching token (`mongo` / `langfuse` / `litellm`) for each `local`.

- **`MONGO_MODE=local`** (default) runs `mongo:5` (replSet `rs0` + auth) under the
  `mongo` profile. Set **`external`** + drop `mongo` from `COMPOSE_PROFILES` to
  reuse an existing MongoDB via `DB_SERVER` / `MONGODB_CONNECTION_STRING`.
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

The full FastAPI certifier — Phase 0 (fault bucketing) → Phase 1 (metrics extraction) → Phase 2 (aggregation) → Phase 3 (12-section certification report) → HTML + PDF rendering via playwright — runs as the **`app`** service (container `certifier_app`) and **comes up automatically with `docker compose up -d`** at `http://localhost:8000/docs`. It shares the monorepo's MongoDB rather than shipping its own.

### Build / run just the certifier

```bash
docker compose up -d --build app          # build + run only the certifier
docker compose up -d --force-recreate app # recreate after a rebuild
docker compose logs -f app                # tail it
```

### Use a prebuilt image instead of building

The certifier image is published at **[`docker.io/agentcert/certifier:latest`](https://hub.docker.com/r/agentcert/certifier)**. To pull it instead of building from source, set `CERTIFIER_IMAGE` in `.env`, then bring the service up:

```bash
# .env
CERTIFIER_IMAGE=agentcert/certifier:latest                 # default published tag
# CERTIFIER_IMAGE=registry.acme.com/certifier:v2.1.0       # private registry
# CERTIFIER_IMAGE=agentcert/certifier@sha256:<digest>      # pin by digest
```

```bash
docker compose pull app && docker compose up -d app
```

To publish a new build (plus the other release images) to Docker Hub, use
[`./scripts/build-and-push.sh`](#build--push-all-docker-images-to-docker-hub).

### Env handling

The certifier reads **every** env var from the monorepo-root `.env` (referenced as `env_file: ../.env` in `certifier/docker-compose.yml`); the container ships no `.env` of its own (`.dockerignore` excludes it). The root compose layers `environment:` overrides on top — notably `MONGODB_CONNECTION_STRING` (the shared mongo via `host.docker.internal` + `directConnection=true`) and `LANGFUSE_HOST` (the in-network `langfuse-web` service name, so trace reads aren't blocked by the host firewall). On a new host: `git clone`, `cp .env.example .env`, fill the placeholders (`AZURE_OPENAI_*`, `LANGFUSE_*`, `MONGODB_*`, …), then `docker compose up -d`.

### Quick command reference

Once `docker compose ps` shows `certifier_app` healthy, open
`http://localhost:8000/docs`. The endpoints are:

| Method | Path | What it does |
|---|---|---|
| `POST` | `/api/v1/bucketing-extraction` | Phase 0+1: fetch a trace (Langfuse or file), classify events into per-fault buckets, extract per-fault metrics. Returns `task_id`. |
| `POST` | `/api/v1/aggregation-certification` | Phase 2+3: aggregate every `*_metrics.json` under the experiment's fault-bucketing tree, build a 12-section certification report, render HTML + PDF. Returns `cert_task_id`. |
| `GET`  | `/api/v1/tasks` | Poll a bucketing/extraction task by `experiment_id` + `experiment_run_id`. |
| `GET`  | `/api/v1/cert-tasks` | Poll a certification task by `experiment_id`. |

### Certifier endpoint configuration (for AgentCert integration)

To connect AgentCert GraphQL to the Certifier APIs above and the certificate PDF endpoint, set these variables:

- `CERTIFIER_BASE_URL` - base URL used for `/api/v1/bucketing-extraction`, `/api/v1/tasks`, `/api/v1/aggregation-certification`, and `/api/v1/cert-tasks`
- `CERTIFICATE_PDF_BASE_URL` - base URL used by AgentCert's PDF proxy endpoint

Example (Azure):

```bash
CERTIFIER_BASE_URL=https://your-azure-certifier-host
CERTIFICATE_PDF_BASE_URL=https://your-azure-pdf-host
```

Where to update:

1. Local/scripted startup (primary path)
  - Update root `.env` and run `scripts/azure_build/start-agentcert-v2.sh --env-file ...`

2. Kubernetes deployment manifests
  - Update both keys in:
    - `AgentCert/chaoscenter/manifests/litmus-getting-started.yaml`
    - `AgentCert/chaoscenter/manifests/litmus-installation.yaml`
    - `AgentCert/chaoscenter/manifests/litmus-without-resources.yaml`

3. Direct GraphQL local run (advanced/dev-only path)
  - Update `AgentCert/chaoscenter/graphql/server/.env`

> Note:
> Use `start-agentcert-v2.sh` as the startup entrypoint. If you see old references to `start-agentcert.sh`, treat them as outdated.

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

Released under the [Apache License 2.0](./LICENSE).
