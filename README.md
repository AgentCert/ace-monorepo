
<div align="center">

# ACE Monorepo

#### Agent Certification Engine

<p>
  <a href="./LICENSE"><img alt="License" src="https://img.shields.io/badge/License-Apache%202.0-blue.svg"></a>
  <img alt="Go" src="https://img.shields.io/badge/Go-1.24+-00ADD8.svg?logo=go&logoColor=white">
  <img alt="Kubernetes" src="https://img.shields.io/badge/Kubernetes-326CE5.svg?logo=kubernetes&logoColor=white">
  <img alt="Kubernetes" src="https://img.shields.io/badge/kind-local%20cluster-326CE5.svg?logo=kubernetes&logoColor=white">
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
- [Quick Start (Kubernetes)](#quick-start-kubernetes)
  - [1. Prerequisites](#1-prerequisites)
  - [2. Run the setup wizard](#2-run-the-setup-wizard)
  - [3. Services](#3-services)
  - [4. Day-to-day operations](#4-day-to-day-operations)
  - [📚 Detailed setup guides (docs/setup/)](#-detailed-setup-guides--docssetup)
- [Legacy script-based setup](#legacy-script-based-setup)
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

## Quick Start (Kubernetes)

Everything — MongoDB, the AgentCert control plane (auth + GraphQL + UI), LiteLLM,
Langfuse, and the Certifier — runs inside a local [kind](https://kind.sigs.k8s.io)
Kubernetes cluster managed by `scripts/setup.sh`:

```bash
git clone --recurse-submodules <repo-url>
cd ace-monorepo
./scripts/setup.sh          # wizard: creates .env, creates kind cluster, deploys to K8s
```

The wizard prompts for your Azure OpenAI credentials, defaults everything else, and
asks at the end whether to deploy. Answer **Y** and the cluster is up in ~5 minutes.

After answering Y the wizard asks *how* to deploy: **`k`** for `kubectl apply`
(default) or **`h`** for `helm upgrade --install`. Both install the same stack —
Helm adds release tracking (`helm history`, `helm rollback`) and lets you upgrade
later without re-running the full wizard.

> ### 📚 Detailed setup guides — [`docs/setup/`](./docs/setup/)
> - **[Setup overview & prerequisites](./docs/setup/README.md)**
> - **[Configuration & changing ports](./docs/setup/configuration.md)** — every `.env` switch + how to move busy ports
> - **[Route 2 — fresh VM with kind](./docs/setup/route-2-fresh-kind.md)**
> - **[Route 3 — cloud Kubernetes (AKS/EKS/GKE)](./docs/setup/route-3-cloud-aks.md)**
> - **[Local development (host processes)](./docs/setup/local-dev.md)** — Go/Node on the host, Docker for infra
> - **[Running your first experiment](./docs/setup/running-an-experiment.md)** — create infra → enable chaos → apply YAML → run → certify

### 1. Prerequisites

| Tool | Min version | Install |
|------|-------------|---------|
| Docker | 28+ | `sudo apt-get install docker.io` — user must be in `docker` group |
| kind | v0.20+ | `go install sigs.k8s.io/kind@latest` or [kind releases](https://github.com/kubernetes-sigs/kind/releases) |
| kubectl | v1.27+ | `sudo snap install kubectl --classic` or [kubectl install](https://kubernetes.io/docs/tasks/tools/) |
| git | any | `sudo apt-get install git` |

### 2. Run the setup wizard

```bash
./scripts/setup.sh
```

It creates `.env` from `.env.example`, patches it with K8s-specific service DNS
names, and prompts only for the values that matter (Azure OpenAI credentials plus
the flash-agent model). Everything else is defaulted. Re-run any time — pressing
Enter at each prompt keeps the current value. At the end it asks:

```
Deploy the stack to the Kubernetes cluster now? [y/N]:
```

Answer **Y**. The wizard will:
1. Create the kind cluster `agentcert` with all required port mappings
2. Create the `ace-env` Kubernetes Secret from `.env`
3. Apply all manifests in `deploy/k8s/`
4. Wait for MongoDB, auth, graphql, web, and certifier to be ready

### 3. Services

**Reachable at**

| Service | URL | Default login |
|---|---|---|
| AgentCert UI | http://localhost:2001 | `admin` / `litmus` |
| GraphQL (REST/WS) | http://localhost:8081 | — |
| Auth (REST) | http://localhost:3000 | — |
| Certifier (Swagger) | http://localhost:18000/docs | — |
| LiteLLM proxy | http://localhost:14000 | — |
| Langfuse | http://localhost:4000 | `admin@agentcert.local` / `agentcert-admin` |
| MongoDB | `mongodb://admin:1234@localhost:27017/?replicaSet=rs0&authSource=admin` | — |

### 4. Day-to-day operations

```bash
kubectl get pods -n ace                         # health check
kubectl logs -n ace deploy/graphql -f           # tail the control plane
kubectl rollout restart -n ace deploy/graphql   # restart one service
kubectl apply -f deploy/k8s/                    # re-apply after manifest changes
kind delete cluster --name agentcert            # tear down everything
```

To apply a `.env` change, re-run the wizard (it updates the `ace-env` Secret and
restarts affected pods):

```bash
./scripts/setup.sh   # answer Y to deploy at the end
```

---

## Local Development (host processes)

For developing the Go backend or React frontend with hot-reload, the original
host-process flow is fully documented at
**[`docs/setup/local-dev.md`](./docs/setup/local-dev.md)**. Quick reference:

```bash
cp .env.example .env
cp build-paths.env.example build-paths.env
./scripts/start-local-services.sh          # MongoDB + Langfuse + LiteLLM + Certifier (Docker)
bash scripts/azure_build/start-agentcert-v2.sh \
    --env-file   $(pwd)/.env \
    --paths-file $(pwd)/build-paths.env     # auth + GraphQL + frontend on the host
bash AgentCert/stop-agentcert.sh           # stop the host processes
```


## Certifier API service (Dockerized)

The full FastAPI certifier — Phase 0 (fault bucketing) → Phase 1 (metrics extraction) → Phase 2 (aggregation) → Phase 3 (12-section certification report) → HTML + PDF rendering via playwright — runs as the `certifier` deployment in the `ace` namespace and is **deployed automatically by `scripts/setup.sh`** at `http://localhost:18000/docs`. It shares the monorepo's MongoDB rather than shipping its own.

The certifier image is published at **[`docker.io/agentcert/certifier:latest`](https://hub.docker.com/r/agentcert/certifier)** and pulled automatically by Kubernetes (`imagePullPolicy: IfNotPresent`).

To restart or check the certifier in Kubernetes:

```bash
kubectl get pods -n ace -l app=certifier
kubectl logs -n ace deploy/certifier -f
kubectl rollout restart -n ace deploy/certifier
```

All credentials are injected from the `ace-env` Secret (created from `.env` by `scripts/setup.sh`). On a new host: clone, run `./scripts/setup.sh`, answer Y to deploy — the certifier comes up alongside every other service.

### Quick command reference

Once `kubectl get pods -n ace -l app=certifier` shows `Running`, open
`http://localhost:18000/docs`. The endpoints are:

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
)" http://localhost:18000/api/v1/bucketing-extraction

# Poll
curl -s "http://localhost:18000/api/v1/tasks?experiment_id=${EXP}&experiment_run_id=${RID}"

# Phase 2+3 (consumes every metrics.json under the experiment)
curl -s -X POST -H "Content-Type: application/json" -d "$(cat <<EOF
{"agent_id":"${AGENT}","agent_name":"vaya","experiment_id":"${EXP}",
 "runs_per_fault":5,"storage_config":{"type":"local"}}
EOF
)" http://localhost:18000/api/v1/aggregation-certification

# Poll
curl -s "http://localhost:18000/api/v1/cert-tasks?experiment_id=${EXP}"
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
