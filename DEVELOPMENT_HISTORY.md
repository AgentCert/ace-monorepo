# ACE Monorepo — Development History & Key Changes

This document summarises the major development stages of the **Agent Certification Engine (ACE)** project and the most significant changes made at each stage.

---

## Development Stages

### Stage 1 — Foundation (Initial Commit)

**Goal:** Establish the monorepo skeleton and wire up submodules.

- Created the top-level git monorepo (`ace-monorepo`) with all submodules declared in `.gitmodules`.
- Submodules introduced: `AgentCert` (control plane), `certifier`, `flash-agent`, `agent-sidecar`, `agent-charts`, `app-charts`, `chaos-charts`, `agentcert-stack`, `litmus-go`.
- Added `build-all.sh` and `deploy-from-dockerhub.sh` as initial CI entry points.
- Moved `azure_build/` scripts from the `AgentCert` submodule into the monorepo's own `scripts/` folder.
- Published all five Docker images to Docker Hub under `agentcert/*`.

**Key commits:** `ce95a09`, `5338151`, `3e2f244`, `2578cfa`, `6a2ab1c`

---

### Stage 2 — Local Dev Stack & Certifier Tooling

**Goal:** Make it possible to run the full pipeline on a single developer machine with one command.

- Added `scripts/start-local-services.sh` — idempotent bringup for MongoDB (replica set), Langfuse, LiteLLM, and the Certifier via Docker Compose.
- Added `scripts/run_certification.py` — runs all four certifier phases locally without starting the FastAPI service.
- Added `scripts/dump_langfuse_trace.py` — fetches a Langfuse trace to a local JSON file for offline replay.
- Added `scripts/render_certification_pdf.py` — standalone re-render of an existing `certification.json` to PDF.
- One-command Docker Compose wizard (`compose/`) for the full control-plane stack.
- MongoDB replica set (`rs0`) init container added to the Compose stack.
- Langfuse compose services extracted to `compose/langfuse/`.

**Key commits:** `c8e96b3`, `aa16050`, `658ee58`, `63d2098`, `644289e`

---

### Stage 3 — Kubernetes & Cloud Deployment

**Goal:** Move from Docker Compose to a production-ready Kubernetes deployment path.

- Added flat `kubectl apply` manifests under `deploy/k8s/` as an alternative to Helm.
- Created the full ACE Platform Helm chart at `deploy/helm/ace/` covering all services (MongoDB, AgentCert control plane, LiteLLM, Langfuse, Certifier).
- Added `deploy/kind/kind-agentcert.yaml` so fresh clones get the exact KinD port mappings without manual configuration.
- Rewrote `scripts/setup.sh` as an interactive wizard that creates `.env` from `.env.example`, generates `values-env.yaml` for Helm, creates the KinD cluster, and deploys — all in one run.
- Added `--restart` flag to `setup.sh` so re-runs skip prompts and redeploy in place.
- Added cloud Kubernetes support (AKS/EKS/GKE) via `CLUSTER_MODE=cloud` and exec-auth in the MongoDB cluster-init container.
- Added static IP / `LoadBalancer` service support for web, Langfuse, and certifier.
- Added CA cert injection and dynamic `ALLOWED_ORIGINS` for cross-origin deployments.
- Fixed AKS-specific issues: `graphql` `hostPath` mount, PostgreSQL `PGDATA` permissions, MinIO permissions.
- Auto-restart of LiteLLM pod when its config changes via a `checksum/config` annotation.

**Key commits:** `0c9e563`, `ad66766`, `b1dce5e`, `72f0dd1`, `0bbc1e5`, `a194aee`

---

### Stage 4 — ITBench Integration & Fault Taxonomy

**Goal:** Make ACE compatible with IBM's ITBench benchmark framework for SRE, CISO, and FinOps scenarios.

- Pointed `chaos-charts` at the `Warsea12-ai` fork and introduced 30 ITBench SRE fault bundles under `chaos-charts/faults/itbench/`.
- Registered 50+ ITBench fault names in the fault taxonomy (`certifier/configs/fault_categories.json`), including a new `scheduling_fault` top-level category.
- Split the ChaosHub catalog into separate fault categories so ITBench experiments appear correctly in the certifier's Phase 0 bucketing.
- Added `certifier/metrics_extractor/scripts/ciso_metrics_adapter.py` — adapts ITBench CISO evaluation output into the standard per-run metrics document shape.
- Added CISO/FinOps numeric-aggregation functions to `certifier/aggregator/scripts/numeric_aggregation.py`.
- Added `--include-ciso-finops` flag to the Phase 2+3 CLI (default `false` = SRE-only scope).
- Added `app-charts` entries for `bookinfo` and `otel-demo` (the ITBench SRE target application).

**Key commits:** `fceec3b`, `310bb41`, `31fe975`, `b5c9266`, `e545a3a`, `3cd3262`

---

### Stage 5 — Open-Weight Model Certification (SRE & CISO)

**Goal:** Run a full end-to-end certification of `qwen2.5:7b-instruct` (open-weight, local GPU) against real ITBench scenarios.

#### Environment setup
- Discovered NVIDIA RTX A6000 (49 GB VRAM) on the host and switched Ollama to GPU mode — ~20–40× faster inference.
- Corrected Docker-bridge IP (`172.17.0.1`) in `.env` and `litellm_config.yaml`.
- Added `qwen2.5-7b-instruct` as the `default_model` in `agentcert-stack/litellm-setup/litellm_config.yaml` with `num_ctx: 16384`.

#### Bug fixes (pre-mass-execution)
Several real bugs were found and fixed across submodules:

| # | Bug | Fix location | Commit |
|---|-----|-------------|--------|
| 1 | Langfuse `LANGFUSE_INIT_*` vars never reached the container because `--env-file` was missing from `docker compose up` | `scripts/start-local-services.sh` | `d1bf6dc` |
| 2 | LiteLLM router timeout too short (default 60s) for long open-weight inference — all requests timed out | `agentcert-stack/litellm-setup/litellm_config.yaml` — raised to 600s | `8f46515` |
| 3 | `AZURE_OPENAI_DEPLOYMENT` and related vars not forwarded into LiteLLM container — crashed on startup | `agentcert-stack/litellm-setup/docker-compose-litellm.yml` | submodule bump `ddaf148` |
| 4 | `chaos-charts` ChaosEngine `TARGETS` field parsing bug — experiments never started | `chaos-charts` (upstream fix, `Warsea12-ai/chaos-charts`) | `9e0fbb2` |
| 5 | `flash-agent` analysis-type validation rejected valid structured outputs from open-weight models | `flash-agent` | `877eceb` |
| 6 | `certifier` `fault_name` metadata missing from Phase 0 output — broke Phase 1 extraction | `certifier` | `ee42826` |
| 7 | PDF renderer (`cert_reporter`) missing handlers for `HeadingBlock`, `CardBlock`, and `AssessmentBlock` — rendered blank pages | `certifier/cert_reporter/` | `63bf187` |
| 8 | Certifier premature-cleanup bug caused workspace files to be deleted before Phase 1 finished — lost runs | `certifier/main/workers/` | `a27e264` |
| 9 | CISO agent `LLM` class requires `openai/<model>` provider prefix for CrewAI path but NOT for the bare LangChain `ChatOpenAI` path — using the same value for both broke one side | `agents/ciso-agent/src/ciso_agent/llm.py` | submodule bump |

#### Mass execution
- Ran **137/137 SRE runs** (7 fault types × ~20 runs each) end-to-end against the live k3s cluster.
- Produced the **first full Phase 0–4 SRE certification report** (JSON + HTML + PDF) from real open-weight agent traces.
- Ran **5 CISO runs** (3 scenario types) and produced the **first real CISO certification report**.

**Key commits:** `2b37360`, `4d5fd5b`, `f02855c`, `11cdb50`, `63bf187`, `a27e264`, `f55d8ed`

---

### Stage 6 — Agent Harnesses, Benchmark Pipeline & SRE Variants

**Goal:** Formalise the agent evaluation workflow and add more agent implementations.

- Added `agents/` directory collecting every agent implementation evaluated by ACE:
  - `agents/flash-agent/` — plain-code snapshot of the primary SRE agent.
  - `agents/ciso-agent/` — `aruscher-dev/ITBench-CISO-CAA-Agent` fork (CrewAI + LangGraph).
  - `agents/sre-agent/` — upstream ITBench "Zero" Codex-CLI wrapper (read-only, unmodified).
  - `agents/sre-agent-crewai/` — ACE-built CrewAI SRE agent for live Kubernetes benchmarking using MCP streamable-HTTP.
  - `agents/harness/a2a-mcp-agent/` — universal A2A JSON-RPC 2.0 bridge for any A2A-compatible agent.
- Added `agents/harness/<agent>/` subdirectories with `bench.yaml`, `agent-harness.yaml`, and `setup.sh` for each agent following the ITBench harness contract.
- Added `scripts/ace-bench.py` — full benchmarking pipeline orchestrator: reads `bench.yaml`, launches the agent harness, polls for completion, and optionally triggers the certifier.
- Added CISO retry logic to handle intermittent LLM failures in multi-run mass executions.
- Improved trace robustness in the certifier — spans with missing metadata no longer abort the pipeline.
- Documented SRE agent live-mode compatibility with chaos-charts faults (including which fault types the "Zero" agent handles).

**Key commits:** `fdf6f66`, `3b8e0b3`, `0c88d60`, `494ced4`, `3dafd4c`

---

## Summary of Key Technical Changes

| Area | What changed | Why |
|------|-------------|-----|
| **LiteLLM timeout** | Raised `router_settings.timeout` from 60s → 600s | Open-weight models (7B+ params) take 30–120s per call; default caused universal failure |
| **Langfuse env vars** | Added `--env-file` to `docker compose up` in `start-local-services.sh` | Init credentials never reached the container without it |
| **PDF renderer** | Added missing block-type handlers (`HeadingBlock`, `CardBlock`, `AssessmentBlock`) | Rendered blank pages whenever these block types appeared in a section |
| **Fault taxonomy** | Added `scheduling_fault` + 50 ITBench fault names | Certifier Phase 0 bucket matching requires explicit registration |
| **CISO LLM prefix** | `openai/<model>` prefix added only on the CrewAI path | CrewAI's `LLM` class and bare `ChatOpenAI` resolve provider differently; one value can't serve both |
| **Certifier OpenAI-compat** | Added `openai_compatible` provider support in `configs/configs.json` | Enables local Ollama / LiteLLM as a drop-in backend for all pipeline LLM judges |
| **KinD config in repo** | Shipped `deploy/kind/kind-agentcert.yaml` in-tree | Fresh clones previously had no port mappings; first-time setup silently failed |
| **Helm chart** | Full ACE Helm chart at `deploy/helm/ace/` | Adds release tracking (`helm history`, `helm rollback`) and enables cloud upgrades without re-running the wizard |
| **ace-bench.py** | New orchestrator script replacing manual per-agent commands | Single command drives the full scenario→agent→certify loop for any registered agent |
| **Premature-cleanup fix** | Background workers now wait for all Phase 1 tasks to complete before cleanup | Lost workspace files caused silent data loss in multi-fault, multi-run executions |

---

## Repository Topology

```
ace-monorepo (orchestration, scripts, deploy)
├── AgentCert/          ← LitmusChaos ChaosCenter fork (control plane + UI)
├── certifier/          ← 4-phase certification pipeline
├── flash-agent/        ← Primary SRE agent under test
├── agents/             ← All agent implementations + harnesses
├── agent-sidecar/      ← LLM call interceptor sidecar
├── agent-charts/       ← Helm charts for agent deployment
├── app-charts/         ← Helm charts for target apps (sock-shop, otel-demo)
├── chaos-charts/       ← LitmusChaos fault experiment definitions
├── agentcert-stack/    ← LiteLLM + Langfuse compose stack
└── litmus-go/          ← LitmusChaos fault injector implementations (Go)
```

Each submodule is versioned independently. The monorepo tracks a specific commit pointer per submodule; use `git submodule update --remote --merge` to pull the latest from all tracked branches.
