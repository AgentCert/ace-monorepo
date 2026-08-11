# CLAUDE.md — ACE Monorepo

Authoritative orientation document for Claude AI sessions. Read this before exploring individual files.
~5,000+ files exist in this repo; the majority are generated or vendored. This file tells you where everything is.

---

## 0. CRITICAL: This host is shared. Never touch another user's resources.

The dev/build host(s) this repo runs on are shared among multiple engineers, each with their **own independent checkout** of this monorepo (e.g. `/srv/projects/ace-monorepo` is a real, separate, actively-used checkout owned by other users — it is not yours to act on). This is not a hypothetical: an agent session working from a different checkout on this exact host once ran `docker compose up` without an explicit project name, and Docker Compose — which identifies "its" containers purely by a shared label, not by working directory — matched another user's already-running `litellm-proxy` and `certifier_app` containers as "stale instances of its own service" and **deleted and replaced them**, entirely silently, with no warning and no confirmation prompt. The owners never authorized this and were not touched, asked, or informed until after the fact.

**Rules, no exceptions:**

- Never stop, remove, restart, recreate, or otherwise mutate a Docker/Kubernetes resource (container, volume, network, image, Compose project, KinD cluster, namespace) that you did not create in the current session, unless **both** (a) the resource's owner has explicitly consented to the specific action, **and** (b) the user directing you in this session has explicitly authorized it. Either one alone is not enough — the owner's consent without your current user's explicit go-ahead is not sufficient grounds to act, and vice versa.
- Never run `docker compose` (or `docker run --name`, or anything that creates a named resource) without an explicit, checkout-unique project/instance identifier. Relying on Compose's default project-name-from-directory-basename behavior is what caused the incident above — two checkouts of this repo have submodule directories with identical basenames (`litellm-setup`, `certifier`, etc.), so implicit naming silently collides across users. See `ACE_INSTANCE_NAME` in `scripts/start-local-services.sh` for the pattern this repo now uses.
- Before creating or starting anything with a name/port/project you haven't verified is free, enumerate what already exists on the host (`docker ps -a`, `docker volume ls`, `docker network ls`, `kubectl get ns`) and check labels/working-directory ownership (`docker inspect ... com.docker.compose.project.working_dir`) for anything that looks like it might belong to someone else. Treat any ambiguity as a hard stop requiring the user's explicit confirmation — not something to route around or silently "fix" by adopting/recreating the resource.
- If you discover you have already affected another user's resource, stop immediately, do not attempt further remediation on it unilaterally, and disclose exactly what happened to the user in full, unhedged detail before doing anything else.
- This applies to every shared host referenced by this repo's tooling, not just the one where the incident happened — the same collision pattern (implicit Compose project names, shared container name conventions, shared KinD cluster names) can recur anywhere this repo is checked out more than once on the same machine.

---

## 1. Project Overview

**ACE (Agent Certification Engine)** is a git-submodule monorepo that aggregates every component required to evaluate, fault-inject, and certify autonomous AI agents under controlled Kubernetes chaos conditions.

**Core proposition:** Inject real infrastructure faults into a Kubernetes cluster N times (target: 30 per fault type), let an AI agent attempt autonomous remediation, collect its full LLM trace via Langfuse, run a 4-phase LLM+statistics pipeline, and emit a 12-section **certification report** (JSON + rendered HTML + paginated A4 PDF) that quantifies the agent's resilience, reasoning quality, and safety compliance.

**Why N=30?** Agent LLM calls are non-deterministic. A single run is not meaningful. Distributions across 30 runs expose variance, tail risk, and statistical significance.

**Primary agents under test:**
- `flash-agent` — FLASH-style SRE ITOps agent (custom Python ReAct loop + MCP)
- `ITBench-CISO-CAA-Agent` — CISO compliance agent (LangGraph + CrewAI)

**License:** Apache 2.0. Copyright 2026 AgentCert Authors.
**Default branch:** `main`. **Active feature branch:** `feature/itbench-scenarios` — all submodules currently tracking this branch. **Upstream org:** https://github.com/AgentCert
**Commit convention:** Conventional Commits (`feat/fix/chore/docs/refactor/test/build/ci/perf`)

**Rule, no exceptions: every submodule's `.gitmodules` URL must point at an `https://github.com/AgentCert/...` repository — never a personal fork or any other account/org.** This has broken things silently before: `chaos-charts`, `app-charts`, and `certifier` all drifted to point at a contributor's personal fork (e.g. `aruscher-dev/chaos-charts`), and in one case the *checked-out* remote didn't even match the drifted `.gitmodules` URL (it pointed at a third, different fork). The practical damage: the deployed ChaosCenter's default ChaosHub syncs from `DEFAULT_HUB_GIT_URL`/`DEFAULT_HUB_BRANCH_NAME` (AgentCert org, by design) — any submodule content that only exists in a personal fork is invisible to it, so features (e.g. ITBench fault/experiment definitions) can be present in your local checkout yet completely absent from the running UI, with no error anywhere. If you need to push work before it can land upstream, push it to a branch on the AgentCert-org repo itself — do not repoint `.gitmodules` at a personal account, even temporarily. Verify with `grep url .gitmodules` and `git -C <submodule> remote -v` (both must agree and both must be `AgentCert`) before trusting that submodule content will actually reach deployed services.

---

## 2. Repository Structure

```
ace-monorepo/
├── AgentCert/                   # Submodule: forked LitmusChaos ChaosCenter v3.0.0 (Go control plane + React UI)
│   └── chaoscenter/
│       ├── authentication/      # Auth service: Go, Gin REST :3000, gRPC :3030, MongoDB, JWT, Dex OIDC
│       ├── graphql/
│       │   ├── definitions/shared/  # .graphqls schema source files (gqlgen reads these)
│       │   └── server/              # Go GraphQL server (gqlgen v0.17.49, port 8081/8082)
│       ├── web/                 # React 17 + TypeScript SPA (port 2001 via nginx)
│       ├── event-tracker/       # Kubernetes operator: watches EventTrackerPolicy CRDs
│       └── dex-server/          # Dex OIDC provider (SSO/OAuth2)
├── certifier/                   # Python 4-phase certification pipeline — MOST CRITICAL SUBSYSTEM
│   ├── main/                    # FastAPI app, routers, background workers, CLI modules
│   │   ├── main.py              # App factory: Motor client, Semaphore caps, 3 routers
│   │   ├── config/settings.py   # Env-var dataclass; MONGODB_CONNECTION_STRING required
│   │   ├── routers/             # bucketing_extraction.py, aggregation_certification.py, certification_reports.py
│   │   ├── workers/             # bucket_task_runner.py, cert_task_runner.py (background coroutines)
│   │   └── cli/                 # CLI wrappers for both pipeline stages (no HTTP layer)
│   ├── fault_analyzer/          # Phase 0: LLM fault bucketing of interleaved trace events
│   ├── metrics_extractor/       # Phase 1: LLM + Python metrics extraction per fault bucket
│   ├── aggregator/              # Phase 2: deterministic Python stats + LLM Council narrative synthesis
│   │   └── prompt/prompt.yml    # LLM Council judge prompts
│   ├── cert_builder/            # Phase 3: 12-section CertificationReport assembly + Pydantic v2 validation
│   ├── cert_reporter/           # Phase 4: LangGraph pipeline → HTML (Jinja2) + PDF (Playwright/Chromium)
│   │   ├── pipeline/graph.py    # LangGraph StateGraph: preprocess→charts→[llm_enrich]→html_render→pdf_render
│   │   ├── templates/           # Jinja2 HTML templates (base, cover, sections, 19 block templates)
│   │   └── main.py              # CLI: `serve` (FastAPI) and `generate` subcommands
│   ├── hypothesis_framework/    # Phase E (optional, n≥30): H01-H09 statistical significance tests
│   ├── utils/                   # Shared: AzureLLMClient, MongoDBClient, ConfigLoader, logging
│   ├── configs/
│   │   ├── configs.json         # Model endpoints, MongoDB/Azure Blob config; ENV_* resolved at load time
│   │   └── fault_categories.json # 9 fault category → sub-fault name mappings
│   ├── run_bucketing_and_extraction_pipeline.py  # Phase 0+1 standalone CLI entry
│   ├── run_full_certification_pipeline.py        # Phase 2+3 standalone CLI entry
│   ├── CLAUDE.md                # Certifier-specific guidance (read alongside this file)
│   ├── requirements.txt
│   ├── pytest.ini               # asyncio_mode=auto
│   └── Makefile                 # build / push / kind-load Docker image
├── flash-agent/                 # Submodule: FLASH-style ITOps agent (pure Python, MCP + ReAct)
│   ├── flash_agent.py           # Core FlashAgent class (1170+ lines): full FLASH pipeline
│   ├── main.py                  # Entry point: AgentConfig.from_env(), SIGTERM/SIGINT, mode dispatch
│   ├── config.py                # AgentConfig dataclass from env; MCP_URLS parsing; Azure detection
│   ├── llm/hindsight.py         # HindsightBuilder: reflection at temperature=0.3, triggers on health<80
│   ├── llm/utils.py             # Token estimation, history trimming, history entry creation
│   ├── mcp/client.py            # MCPClient: JSON-RPC 2.0 over HTTP+SSE, 4-tier scope discovery
│   ├── Makefile                 # make build / make run
│   └── Dockerfile
├── agents/                      # All agent implementations evaluated by ACE
│   ├── ciso-agent/              # CISO compliance: LangGraph orchestrator + CrewAI sub-agents + LiteLLM
│   ├── sre-agent/               # SRE: "Zero" wrapper around OpenAI Codex CLI + MCP tools
│   ├── flash-agent/             # Mirror of flash-agent submodule for harness integration
│   ├── sre-agent-crewai/        # ACE-built CrewAI SRE agent for live K8s benchmarking
│   └── harness/                 # ITBench benchmark harness per agent
│       ├── flash-agent/         # bench.yaml, agent-harness.yaml, setup.sh
│       ├── ciso-agent/          # bench.yaml, agent-harness.yaml, setup.sh
│       ├── sre-agent/           # bench.yaml, agent-harness.yaml, setup.sh
│       ├── sre-agent-crewai/    # bench.yaml, agent-harness.yaml, setup.sh
│       └── a2a-mcp-agent/       # Universal A2A JSON-RPC 2.0 bridge for any A2A-compatible agent
├── agent-sidecar/               # Submodule: transparent HTTP proxy; stamps LLM calls with experiment metadata
├── agent-charts/                # Submodule: Helm charts for agents (flash-agent, k8s-agent, litellm-proxy)
├── app-charts/                  # Submodule: Helm charts for target apps (sock-shop, bookinfo, otel-demo)
├── chaos-charts/                # Submodule: LitmusChaos fault experiment YAML definitions (branch: master)
├── agentcert-stack/             # Submodule: LiteLLM config YAML, shared stack configuration
├── litmus-go/                   # Submodule: Go implementations of LitmusChaos fault injectors
├── deploy/
│   ├── helm/ace/                # Main ACE platform Helm chart (deploys all services to ace namespace)
│   ├── k8s/                     # Flat kubectl-apply manifests (Helm alternative)
│   └── kind/                    # KinD cluster config + tooling
│       ├── kind-agentcert.yaml  # Template KinD config (do not use directly on a shared host)
│       └── render-kind-config.sh  # Renders kind-agentcert.yaml with instance-scoped name + ports
├── compose/                     # Docker Compose configs for local dev bringup
│   ├── cluster-init/            # MongoDB replica set init container (entrypoint.sh: KinD ownership guards)
│   ├── langfuse/                # Langfuse compose services
│   ├── kind/                    # KinD-specific overrides
│   ├── langfuse.override.yml    # Port isolation override for upstream Langfuse clone (LANGFUSE_PORT, MINIO_API_PORT)
│   ├── litellm.override.yml     # Instance isolation override for agentcert-stack LiteLLM (LITELLM_PORT, container_name)
│   └── certifier.override.yml   # Instance isolation override for certifier submodule (container_name)
├── scripts/
│   ├── setup.sh                 # Interactive setup wizard: creates .env, generates Helm values, deploys; auto-sets ACE_INSTANCE_NAME + OLLAMA_PORT
│   ├── start-local-services.sh  # Idempotent local dev stack bringup (MongoDB, Langfuse, Ollama, LiteLLM, Certifier)
│   ├── compose-up-guard.sh      # Safety wrapper for `docker compose up` — refuses if any container already belongs to a different checkout
│   ├── build-and-push.sh        # Builds all 5 Docker images, pushes to Docker Hub
│   ├── prepare-images.sh        # Build/load/configure experiment workflow images per *_IMAGE_SOURCE in .env (dockerhub/jfrog/local); called by setup.sh
│   ├── ace-bench.py             # Dev-tool: trace_based pipeline only (flash-agent local dev). Production orchestration uses LitmusChaos Argo Workflow.
│   ├── run_certification.py     # End-to-end certifier runner (dev/CI, no FastAPI server needed)
│   ├── dump_langfuse_trace.py   # Fetches Langfuse trace → raw_trace.json + trace_meta.json
│   └── render_certification_pdf.py  # Standalone PDF render from existing certification.json
├── docs/                        # Architecture diagrams, API docs, methodology references
├── data/                        # Sample traces, ground truth data
├── docker-compose.yml           # Root compose file for full local stack; project name: ace-${ACE_INSTANCE_NAME:-unconfigured}; all container_names suffixed with ACE_INSTANCE_NAME; use via compose-up-guard.sh
├── .env.example                 # Template for required secrets (copy to .env; .env is gitignored)
├── build-paths.env              # Component source-path overrides for local dev builds
└── sonar-project.properties     # SonarQube: projectKey=ace-monorepo, Python 3.12, sources listed
```

---

## 3. Architecture

### System Interaction Map

```
Browser
  │
  ▼
Web UI (React, :2001)  ──Apollo/GraphQL──►  GraphQL API (:8081)
                                                │   │   │
                               gRPC (auth) ◄────┘   │   └──► MongoDB :27017 (replSet rs0)
                                                     │
                                        Experiment orchestration
                                                     │
                               ┌─────────────────────▼─────────────────────┐
                               │         Kubernetes Target Cluster           │
                               │                                             │
                               │  Argo Workflow (litmus ns):                 │
                               │    install-app → install-agent              │
                               │    → inject LitmusChaos faults              │
                               │    → cleanup                                │
                               │                                             │
                               │  Agent Pod ──MCP──► K8s MCP Server (:8081) │
                               │  (flash-agent) ────► Prometheus MCP (:8083)│
                               │       │                                     │
                               │  Agent Sidecar (stamps LLM calls with       │
                               │  EXPERIMENT_ID, RUN_ID, WORKFLOW_NAME)      │
                               └──────────────────────┬──────────────────────┘
                                                      │ LLM calls
                                                      ▼
                               ┌──────────────────────────────────────────────┐
                               │     LiteLLM Proxy (:14000)                   │
                               │  Routes to Azure OpenAI / Gemini /           │
                               │  OpenRouter / local Ollama                   │
                               │  Default model: qwen2.5-7b-instruct (Ollama) │
                               │  Emits OTEL spans ──► Langfuse (:4000)       │
                               └──────────────────────┬──────────────────────┘
                                                      │ raw trace JSON
                                                      ▼
                               ┌──────────────────────────────────────────────┐
                               │     Certifier FastAPI (:8000 / host :18000)  │
                               │                                              │
                               │  Phase 0: Fault Bucketing (LLM)              │
                               │  Phase 1: Metrics Extraction (LLM + Python)  │
                               │  Phase 2: Aggregation (Python + LLM Council) │
                               │  Phase 3: Cert Assembly (Pydantic validated)  │
                               │  Phase 4: HTML + PDF (Playwright Chromium)   │
                               │                                              │
                               │  workspace/{agent_id}/{experiment_id}/        │
                               └──────────────────────────────────────────────┘
```

### Certification Auto-Trigger Flow

When an experiment run reaches a terminal state, the GraphQL `chaos_experiment_run` package fires:
```
ChaosExperimentRunEvent (terminal) → certification pkg → POST /bucketing-extraction
  → poll COMPLETED → ALL_RUNS_COMPLETED gate check → POST /aggregation-certification
  → poll COMPLETED → final reports in MongoDB (GridFS) + workspace filesystem
```

---

## 4. Major Subsystems

### 4.1 Certifier (`certifier/`) — Most Critical Subsystem

A 4-phase (+ optional Phase E) Python analytical pipeline exposed as:
- **FastAPI REST service** at `/api/v1/` (Swagger at `:8000/docs`)
- **Standalone CLI** scripts (runnable without starting the HTTP server)

#### Pipeline Phases

| Phase | Module | Input | What it does | Output |
|-------|--------|-------|-------------|--------|
| 0 | `fault_analyzer/` | Raw Langfuse trace JSON | Reasoning LLM classifies interleaved spans into per-fault lifecycle buckets | `fault_buckets/*.json`, `*_bucketing_manifest.json` |
| 1 | `metrics_extractor/` | Per-fault bucket JSON | Extraction LLM pulls text observations; Python computes all arithmetic (TTD, TTR, hallucination_score, SLA norm) | `<fault_id>_metrics.json` per fault |
| 2 | `aggregator/` | All `*_metrics.json` across N runs | Pure-Python stats (mean/median/p95/stddev/success_rate); LLM Council (k judges + meta-judge) synthesizes qualitative narratives | `aggregation.json` (CertificationScorecard) |
| E | `hypothesis_framework/` | Aggregation data (n≥30) | H01-H09 statistical significance tests (statsmodels, scipy) | `statistical_hypothesis` block merged into aggregation |
| 3 | `cert_builder/` | `aggregation.json` | 5 concurrent + 1 sequential LLM narrative builders → ReportAssembler → Pydantic v2 validation (hard fail on schema violation) | `certification.json` (12-section CertificationReport) |
| 4 | `cert_reporter/` | `certification.json` | LangGraph: preprocess → Altair/Vega charts → Jinja2 HTML → Playwright A4 PDF | `<doc_id>.html`, `<doc_id>.pdf` |

**Critical design rules:**
- LLMs classify and observe; **Python does all arithmetic** — no LLM math
- `AzureLLMClient` auto-strips `temperature` for o-series reasoning models
- `ConfigLoader` resolves any JSON config value prefixed `ENV_` from environment at load time
- `DirectoryQueryService` and `MetricsQueryService` share the same interface — pipeline is storage-agnostic
- Pydantic v2 validation at Phase 3 boundary is a **hard gate** — malformed reports raise rather than emit

#### FastAPI Routers and Endpoints

| Router | Endpoint | Description |
|--------|----------|-------------|
| `bucketing_extraction.py` | `POST /api/v1/bucketing-extraction` | Submit Phase 0+1 job (202 Accepted); 409 if duplicate active task |
| `bucketing_extraction.py` | `GET /api/v1/tasks` | Poll Phase 0+1 status (params: `experiment_id`, `experiment_run_id`) |
| `aggregation_certification.py` | `POST /api/v1/aggregation-certification` | Submit Phase 2+3 job (202); 400 METRICS_NOT_FOUND, 409 duplicate |
| `aggregation_certification.py` | `GET /api/v1/cert-tasks` | Poll Phase 2+3 status (param: `experiment_id`) |
| `certification_reports.py` | `GET /api/v1/certification/html` | Serve HTML report (GridFS first, filesystem fallback) |
| `certification_reports.py` | `GET /api/v1/certification/pdf` | Serve PDF report (GridFS first, filesystem fallback) |

Task states: `PENDING → RUNNING → COMPLETED / FAILED`

Phase 0+1 stages: `pending → acquiring_trace → running_pipeline → done`

Phase 2+3 stages: `pending → fetching_metrics → running_pipeline → storing_metadata → done`

Error codes: `TASK_ALREADY_ACTIVE`, `TASK_NOT_FOUND`, `TRACE_NOT_FOUND`, `PIPELINE_FAILED`, `STORAGE_ERROR`, `METRICS_NOT_FOUND`, `AGGREGATION_FAILED`, `CERT_GENERATION_FAILED`, `INVALID_REQUEST`, `MONGODB_ERROR`

#### MongoDB Collections (certifier)

| Collection | Env var | Purpose |
|-----------|---------|---------|
| `pipeline_tasks` | `API_TASK_COLLECTION` | Phase 0+1 task state machine |
| `certification_tasks` | `CERT_TASK_COLLECTION` | Phase 2+3 task state machine |
| `agent_run_metrics` | — | Per-run metrics documents with Atlas Vector Search index |
| `certification_metadata` | `CERT_METADATA_COLLECTION` | Final report metadata |
| `aggregated_category_metadata` | `AGG_CATEGORY_COLLECTION` | Per-fault-category aggregated rows |

GridFS bucket `cert_reports` stores HTML/PDF when `storage_config.type=mongodb`.

#### Workspace Layout
```
workspace/                            # WORKSPACE_DIR env var (default: workspace)
└── {agent_id}/
    └── {experiment_id}/
        ├── fault-bucketing/
        │   └── {run_id}/
        │       ├── fault_buckets/         # Phase 0: one JSON per detected fault
        │       ├── metrics/               # Phase 1: <fault_id>_metrics.json per fault
        │       └── pipeline_summary.json
        ├── aggregation/                   # Phase 2: aggregation.json
        ├── cert-builder/                  # Phase 3: certification.json
        └── certification/                 # Phase 4: <doc_id>.html, <doc_id>.pdf

workspace/cert/                       # CERT_WORKSPACE_DIR env var (default: workspace/cert)
```

#### Fault Categories (`configs/fault_categories.json`)

Nine top-level fault categories (each maps to sub-fault names):
`application_fault`, `network_fault`, `resource_fault`, `database_storage_fault`, `security_fault`, `scheduling_fault`, `ciso_fault`, `finops_fault`, `sre_agent_fault`

#### Concurrency Limits
- Phase 0+1: `API_MAX_CONCURRENT_TASKS` (default 4) — asyncio.Semaphore
- Phase 2+3: `API_MAX_CONCURRENT_CERT_TASKS` (default 2) — asyncio.Semaphore

#### Key Modules Summary

| Module | Path | Purpose |
|--------|------|---------|
| FastAPI app | `main/main.py` | Creates app, Motor client, indexes, Semaphore caps, registers 3 routers |
| Settings | `main/config/settings.py` | Env-var dataclass; `MONGODB_CONNECTION_STRING` is fail-fast required |
| Bucket task runner | `main/workers/bucket_task_runner.py` | Async Phase 0+1 background worker; path-traversal guards; all exceptions → FAILED |
| Cert task runner | `main/workers/cert_task_runner.py` | Async Phase 2+3+4 worker; structured `error_code` on failure |
| Phase 0+1 CLI | `run_bucketing_and_extraction_pipeline.py` | Standalone: trace → fault_buckets + metrics + pipeline_summary |
| Phase 2+3 CLI | `run_full_certification_pipeline.py` | Standalone: metrics → aggregation → certification |
| LLM client | `utils/azure_openai_util.py` | Wraps agent_framework ChatAgent; strips temperature for reasoning models; exponential backoff on 429; singleton per model |
| Config loader | `utils/load_config.py` | Loads configs/configs.json; resolves `ENV_*` values from env at load time |
| MongoDB client | `utils/mongodb_util.py` | Sync PyMongo; cosine vector search via `$vectorSearch` aggregation |
| Aggregation | `aggregator/scripts/aggregation.py` | AggregationOrchestrator; storage-agnostic via DirectoryQueryService or MetricsQueryService |
| LLM Council | `aggregator/scripts/llm_council.py` | k-judge + meta-reconciliation; prompts from `aggregator/prompt/prompt.yml` |
| Cert pipeline | `cert_builder/scripts/certification_pipeline.py` | Phase 3 entry; 5 concurrent builders via asyncio.gather; sequential recommendations; strict Pydantic |
| LangGraph pipeline | `cert_reporter/pipeline/graph.py` | StateGraph nodes: preprocess → charts (Altair→SVG) → [llm_enrich] → html_render → pdf_render |
| Hypothesis runner | `hypothesis_framework/scripts/run_statistical_hypothesis.py` | H01-H09 tests (statsmodels, scipy, numpy) |
| Global config | `configs/configs.json` | MongoDB/Azure Blob/model endpoints; ENV_* values; currently points to local Ollama |

#### CertificationReport Schema (12 Sections)

Executive Summary, Methodology, Qualitative Findings, Detection & Response, Reasoning Quality, Safety & Security, Resource Efficiency, Fault Injection Analysis, Limitations, Recommendations, Pipeline Token Metrics, Appendix/Statistical Results.

Content blocks are a Pydantic v2 discriminated union on the `type` field: `TextBlock`, `HeadingBlock`, `TableBlock`, `CardBlock`, `ChartBlock`, `FindingsBlock`, `AssessmentBlock`.

---

### 4.2 Flash Agent (`flash-agent/` and `agents/flash-agent/`)

Implements Microsoft Research's **FLASH** (Feedback-guided Agentic Workflow) methodology for ITOps.

#### Two Operating Modes

**Scan mode** (default):
```
DISCOVER → REASON+ACT → ANALYZE → REFLECT
   │            │            │         │
   │       ReAct loop    Structured  Hindsight injected
   │       ≤10 tool-     JSON health into next scan's
   │       calling       analysis    system prompt
   │       iterations               (triggers when
   │                                health < 80 or
   │                                critical issues)
   ▼
MCPClient.discover_scope():
  1. Explicit override (AGENT_SCOPE_NAMESPACE)
  2. Agnostic check (zero-arg introspection tools)
  3. Introspection tool probe
  4. Namespace validation probe
```

**Watch mode** (`WATCH_MODE=true`):
```
LLM establishes baseline thresholds once
→ hot loop: poll MCP tools every WATCH_INTERVAL seconds (no LLM)
→ escalate to full scan only when threshold breached
```

#### Key Files

| File | Description |
|------|-------------|
| `flash-agent/main.py` | Entry point; loads `AgentConfig.from_env()`; registers SIGTERM/SIGINT; dispatches to scan or watch loop |
| `flash-agent/flash_agent.py` | `FlashAgent` class (1170+ lines); `scan()`, `establish_baseline()`, `watch()`; all scope-aware system prompt block renderers |
| `flash-agent/config.py` | `AgentConfig` dataclass; parses `MCP_URLS` as comma-separated; auto-detects Azure vs standard OpenAI |
| `flash-agent/llm/hindsight.py` | `HindsightBuilder`; summarizes up to 5 history entries; calls LLM at temperature=0.3; max 800 tokens |
| `flash-agent/llm/utils.py` | `estimate_tokens()` (4 chars/token), `trim_history_to_token_limit()`, `format_analysis_for_history()` |
| `flash-agent/mcp/client.py` | `MCPClient`: JSON-RPC 2.0 + SSE; `MCPScope` dataclass; `generate_fallback_data()` on unreachable MCP |

#### In-Cluster Configuration (via Helm flash-agent chart)

- LLM endpoint: `http://litellm.ace.svc.cluster.local:14000/v1`
- Model alias: `gpt-4o` (routes to whatever LiteLLM maps that alias to)
- MCP URLs: `kubernetes-mcp-server.sock-shop:8081`, `prometheus-mcp-server.sock-shop:8083`
- API key: `sk-agentcert-2026` (LiteLLM master key)

---

### 4.3 Agents Directory (`agents/`)

#### Agent Overview

| Agent | Framework | Pipeline type | Entry point |
|-------|-----------|---------------|-------------|
| `ciso-agent` | LangGraph + CrewAI + LiteLLM | `ciso` | `src/ciso_agent/main.py` |
| `sre-agent` | "Zero" Codex CLI wrapper + MCP | `sre` | `zero/__main__.py` |
| `flash-agent` | Custom ReAct + MCP | `trace_based`, `itbench_sre` | `main.py` |
| `sre-agent-crewai` | CrewAI + MCP streamable-HTTP | `itbench_sre` | `src/sre_crewai/__main__.py` |
| `a2a-mcp-agent` | A2A JSON-RPC 2.0 bridge | any | `a2a_bridge.py` |

#### ciso-agent (`agents/ciso-agent/`)

- LangGraph `CISOManager` routes tasks to 3 CrewAI sub-agents: `kubernetes_kyverno`, `kubernetes_kubectl_opa`, `rhel_playbook_opa`
- Generates Kyverno policies, OPA Rego rules, runs kubectl evaluations, executes Ansible on RHEL
- Reporter node generates Markdown summary
- **Do not modify upstream logic** (upstream: itbench-hub/ITBench-CISO-CAA-Agent)

#### sre-agent (`agents/sre-agent/`)

- "Zero" wrapper (`zero/`) manages workspace setup, prompt templating to `AGENTS.md`, MCP server lifecycle, retry logic
- Supports offline snapshot evaluation (ITBench-Lite datasets from Hugging Face) and live K8s investigation
- `sre_tools/offline_incident_analysis/tools.py` — MCP tools for offline analysis
- **Do not modify upstream logic** (upstream: itbench-hub/ITBench-CISO-SRE-FinOps-Agent)

#### sre-agent-crewai (`agents/sre-agent-crewai/`)

- ACE-built agent for the `itbench_sre` pipeline (live Kubernetes benchmarking)
- Single CrewAI Agent with an eight-step investigation protocol: list namespaces → pod health → events → NetworkPolicies → policy specs → Prometheus PromQL → delete faulty resources → verify recovery
- Connects to live K8s (:18081) and Prometheus (:31085) MCP servers via MCP streamable-HTTP (fresh session per tool call)
- Output: `agent_output.json` with JSON diagnosis (`entities` + `propagation_chain`)
- Runs with `--network=host` to reach sidecar LLM proxy, K8s MCP, Prometheus MCP simultaneously

#### a2a-mcp-agent (`agents/harness/a2a-mcp-agent/`)

- Not an LLM agent — a **harness-side adapter** for A2A-compatible agents
- Reads `scenario_data.json`, fetches Agent Card from `/.well-known/agent-card.json`, sends `tasks/send` JSON-RPC 2.0, polls `tasks/get` until terminal, packages result into `agent_data.tar`
- Uses httpx + tenacity for retry

#### Harness Convention

Every agent has under `agents/harness/<agent-name>/`:
- `bench.yaml` — ITBench pipeline config (scenario type, docker image, env vars)
- `agent-harness.yaml` — How the harness invokes the agent (command, volumes, ports)
- `setup.sh` — Per-agent environment setup (venv, pip deps, credentials)

For flash-agent local dev, invoke via:
```bash
python scripts/ace-bench.py flash-agent [--runs N] [--resume] [--skip-certifier]
```
For all other agents, benchmarking is driven by the LitmusChaos Argo Workflow registered in AgentCert (canonical orchestrator).

---

### 4.4 AgentCert Control Plane (`AgentCert/chaoscenter/`)

**Fork of LitmusChaos ChaosCenter v3.0.0.** ACE-added packages are in the `graphql/server/pkg/` directory.

#### Auth Service (`authentication/`)

- **Stack:** Go, Gin (REST :3000), gRPC (:3030), MongoDB, JWT (bcrypt), Dex OIDC/OAuth2, logrus
- **Entities:** User, Project, Member (Owner/Executor/Viewer roles), ApiToken, RevokedToken (TTL-indexed)
- **Default credentials:** admin / litmus
- **Key env vars:** `DB_SERVER`, `DB_USER`, `DB_PASSWORD`, `JWT_EXPIRY_MINS` (default 1440), `DEX_ENABLED` (default false), `REST_PORT`, `GRPC_PORT`, `ALLOWED_ORIGINS`

#### GraphQL Server (`graphql/server/`)

- **Stack:** Go 1.24, gqlgen v0.17.49, Gin v1.10, MongoDB go-driver v1.16.1, gRPC v1.68.1, gorilla/websocket v1.5.3, Argo Workflows v3.3.5
- **Ports:** :8081 (REST/GraphQL), :8082 (gRPC)
- **Schema source:** `definitions/shared/*.graphqls` → code-gen into `graph/generated/` and `graph/model/`
- **All three GraphQL operation types:** Queries, Mutations, Subscriptions (WebSocket, 10s keep-alive)
- **Security:** `@authorized` directive for JWT RBAC; configurable introspection (`ENABLE_GQL_INTROSPECTION`)

**ACE-specific packages (do not exist in upstream LitmusChaos):**

| Package | Path | Key responsibility |
|---------|------|-------------------|
| `agent_registry` | `pkg/agent_registry/` | Full CRUD for AI agents; state machine REGISTERED→VALIDATING→ACTIVE/INACTIVE→DELETED; async health checks; Helm deploy/uninstall; Langfuse sync |
| `agenthub` | `pkg/agenthub/` | Reads agent Helm chart metadata from git-cloned dir; enriches with live registry status; bg-syncs repo every 6h |
| `apphub` | `pkg/apphub/` | Same pattern as agenthub but for application templates (sock-shop, bookinfo, etc.) |
| `certification` | `pkg/certification/` | Long-running pipeline orchestrator; concurrency-safe (one goroutine per experiment-run key); drives certifier REST API; persists state in 3 MongoDB collections |
| `fault_studio` | `pkg/fault_studio/` | Per-project curated fault selections from ChaosHubs |
| `observability` | `pkg/observability/` | LangfuseTracer: deduplicates fault spans, streams trace events, flushes on SIGTERM |
| `apps_registry` | `pkg/apps_registry/` | HTTP API for registering target applications (Helm-deployed workloads) |
| `handlers` | `pkg/handlers/` | REST handlers: certification PDF/HTML proxy, Helm chart upload/install/list/cleanup, port-forward |

**Standard ChaosCenter packages (modified but not invented by ACE):**
`chaos_experiment`, `chaos_experiment_run`, `chaos_infrastructure`, `probe`, `environment`, `gitops`, `image_registry`, `chaoshub`, `data-store`, `authorization`, `database`, `grpc`, `helm`, `projects`

**MongoDB collections (GraphQL server):**
`agentRegistry`, `chaosExperiments`, `chaosExperimentRuns`, `chaosInfra`, `environments`, `probes`, `chaosHubs`, `imageRegistries`, `gitopsConfig`, `faultStudios`, `certificate_experiments`, `certificate_run_workflows`, `certificate_aggregation_workflows`

#### Web Frontend (`web/`)

- **Stack:** React 17, TypeScript 4.4 (strict), Webpack 5, Apollo Client (GraphQL), TanStack React Query v4 (REST), @harnessio/uicore component library, Monaco Editor, Highcharts 9.2
- **Port:** :2001 (served by nginx reverse proxy container)
- **Entry:** `bootstrap.tsx` — `/account/:accountID/*` → `AppWithAuthentication`; other paths → `AppWithoutAuthentication`
- **State:** `AppStoreContext` (global); localStorage (JWT/session); IndexedDB idb (in-progress experiment drafts)
- **Routes:** Centralized in `src/routes/RouteDefinitions.ts` (typed functions); mappings in `src/routes/RouteDestinations.tsx`
- **API integration:** GraphQL at `/api/query` (Apollo, ApolloLink injects Bearer token); REST at `/auth` (TanStack React Query + auto-generated hooks from OpenAPI via @harnessio/oats-cli)
- **Auth guard:** Checks JWT on mount; `forceLogout()` if absent/expired; redirects to password-reset on initial-login flag
- **Features:** Chaos Studio, ChaosHub marketplace, Agent Hub + Apps Hub, Infrastructure management, Probe builder, GitOps, Project RBAC, image registry config, API token management

#### Event Tracker (`event-tracker/`)

- **Stack:** Go, controller-runtime (kubebuilder), shared informers (Deployment, StatefulSet, DaemonSet), custom CRD `EventTrackerPolicy` (group: `eventtracker.litmuschaos.io/v1`)
- Watches resources with annotation `litmuschaos.io/gitops=true` + `litmuschaos.io/experimentId`
- Evaluates JMESPath conditions with operators (EqualTo, NotEqualTo, LessThan, GreaterThan, Change)
- Fires `gitopsNotifier` GraphQL mutation on condition pass → triggers chaos experiment run

#### Dex Server (`dex-server/`)

- Static web assets + `web.go` providing OIDC/OAuth2 login flows
- Enabled via `DEX_ENABLED=true` in auth service config

---

### 4.5 Deploy (`deploy/`)

#### KinD Local Cluster

```bash
# On a shared host, NEVER use the template config directly — cluster name and all hostPorts
# are host-wide unique resources; two checkouts collide by default.
# Render an instance-scoped config first (sets KIND_CLUSTER_NAME + unique ports from .env):
deploy/kind/render-kind-config.sh --personal-workspace

# Then the cluster-init container picks it up automatically via docker-compose.yml, or run directly:
kind create cluster --config .tmp/kind-agentcert.rendered.yaml
# Single control-plane node with explicit NodePort-to-host mappings for all services
```

**KinD eviction thresholds (this host):** The host's Docker data-root (`/Innovation/docker`) sits on a large volume that appears nearly full by percentage (~2.6% free) even though tens of GB remain in absolute terms. Kubelet's default thresholds (`nodefs.available<10%`, `imagefs.available<15%`) fire on percentage alone and immediately evict pods. The checked-in `kind-agentcert.yaml` (and `compose/kind/kind-fresh.yaml`) override these with **absolute floors** (`nodefs.available<5Gi,imagefs.available<5Gi`) so pods are not spuriously evicted. Do not remove these overrides on this host.

**KinD cluster ownership:** `cluster-init/entrypoint.sh` marks every cluster it creates with a Docker volume (`ace-kind-owner-<name>`) labelled with this checkout's host path. Before reusing or deleting a cluster it checks this marker — clusters owned by other checkouts are refused. To manually claim a cluster you know is yours:
```bash
docker volume create --label ace.kind.owner=${PWD} ace-kind-owner-agentcert-<ACE_INSTANCE_NAME>
```

#### ACE Platform Helm Chart (`deploy/helm/ace/`)

**Setup first (generates values-env.yaml from .env):**
```bash
./scripts/setup.sh
```

**Install:**
```bash
helm install ace deploy/helm/ace -n ace --create-namespace \
  -f deploy/helm/ace/values.yaml \
  -f deploy/helm/ace/values-env.yaml
```

**Post-install hook:** `mongodb-rs-init` Job (backoffLimit=10, ttl=600s) initializes rs0.

**Key Helm values:**
- `web.serviceType`: NodePort (local) or LoadBalancer (cloud)
- `images.*`: All `agentcert/*` images use `imagePullPolicy: Always`; infra images use `IfNotPresent`
- `litellm.config`: Multi-provider config (Gemini, Azure OpenAI, OpenRouter, Ollama)

**Storage (all PVCs, ReadWriteOnce):**
mongodb 5Gi, certifier-workspace 2Gi, litellm 1Gi, langfuse-postgres 5Gi, langfuse-redis 1Gi, langfuse-clickhouse 10Gi + 2Gi logs, langfuse-minio 10Gi — **~36 Gi minimum**

**Service ports (host → container):**

| Service | Host | NodePort | Container |
|---------|------|----------|-----------|
| Web UI | 2001 | 32001 | 2001 |
| Auth REST | 3000 | 32003 | 3000 |
| Auth gRPC | 3030 | 32030 | 3030 |
| GraphQL REST | 8081 | 32081 | 8081 |
| GraphQL gRPC | 8082 | 32082 | 8082 |
| Certifier API | 18000 | 32080 | 8000 |
| LiteLLM | 14000 | 31400 | 4000 |
| Langfuse | 4000 | 32400 | 3000 |
| MongoDB | 27017 | 32017 | 27017 |
| MinIO S3 | 19090 | 32090 | 9000 |
| Prometheus | 31090 | 31090 | 9090 |
| Grafana | 31687 | 31687 | 3000 |

**Flat kubectl alternative:**
```bash
kubectl apply -f deploy/k8s/
```

**Agent workloads (separate from platform chart):**
```bash
helm install flash-agent agent-charts/charts/flash-agent -n sock-shop \
  --set agentId=<uuid> --set agent.config.MODEL_ALIAS=gpt-4o ...
helm install k8s-agent agent-charts/charts/k8s-agent -n target-ns ...
```

#### Application Helm Charts (`app-charts/`)

| Chart | Namespace | Key services |
|-------|-----------|-------------|
| `sock-shop` | sock-shop | 13 microservices + Prometheus + Grafana + K8s MCP (:8081) + Prometheus MCP (NodePort 31083) |
| `bookinfo` | book-info | Istio Bookinfo + monitoring + K8s MCP + Prometheus MCP (NodePort 31084) |
| `otel-demo` | otel-demo | Upstream opentelemetry-demo v0.40.9 as subchart (same version as ITBench SRE scenarios) |

---

### 4.6 Scripts (`scripts/`)

| Script | Usage |
|--------|-------|
| `setup.sh` | `./scripts/setup.sh [--setup\|--restart] [--local-build]` — interactive wizard first time; `--restart` skips prompts; `--local-build` forces all images to build locally (no Docker Hub). Auto-backfills `ACE_INSTANCE_NAME`, `OLLAMA_PORT`, `AGENT_CHARTS_ROOT`, `APP_CHARTS_ROOT` in `.env`. Prompts for Ollama model (default: `qwen2.5:32b-instruct`) and image source (dockerhub/jfrog/local) per service. |
| `start-local-services.sh` | `./scripts/start-local-services.sh [--skip-mongo] [--skip-langfuse] [--skip-ollama] [--skip-litellm] [--skip-certifier] [--only-mongo] [--only-langfuse] [--only-ollama] [--only-litellm] [--only-certifier] [--restart] [--pull-certifier]` |
| `compose-up-guard.sh` | `./scripts/compose-up-guard.sh up -d` — drop-in wrapper for `docker compose`; refuses to proceed if any container in the stack already exists under a different checkout's working directory |
| `prepare-images.sh` | `./scripts/prepare-images.sh` — builds, loads, or configures registry credentials for experiment workflow images based on `*_IMAGE_SOURCE` settings in `.env` (dockerhub/jfrog/local). Called automatically by `setup.sh`; safe to run standalone to rebuild/reload. |
| `build-and-push.sh` | `./scripts/build-and-push.sh [--env-file PATH]` — reads DOCKERHUB_USERNAME + DOCKERHUB_TOKEN from .env |
| `ace-bench.py` | **Dev-tool, trace_based only.** `python scripts/ace-bench.py flash-agent [--runs N] [--runs-per-fault N] [--resume] [--skip-setup] [--skip-certifier]`. Production runs use the LitmusChaos Argo Workflow. |
| `run_certification.py` | `python scripts/run_certification.py --trace-id <UUID> [--workspace DIR] [--skip-cert] [--no-pdf] [--debug]` |
| `dump_langfuse_trace.py` | `python scripts/dump_langfuse_trace.py --experiment-id <UUID> --run-id <UUID> [--output-dir DIR]` |

---

## 5. Key Concepts

**Chaos Experiment:** A structured fault injection sequence driven by LitmusChaos ChaosEngine/ChaosExperiment CRDs, orchestrated by Argo Workflows. Steps: install target app → install AI agent → inject faults (pod-delete, network-loss, CPU/memory hog, disk-fill, etc.) → cleanup. The agent under test is never told what fault was injected.

**Certification:** Statistical evaluation of an AI agent across N independent fault injection runs. Not a pass/fail test — a distribution of quantitative and qualitative metrics summarized in a 12-section report.

**Fault Bucket (Phase 0):** A time-windowed slice of Langfuse trace spans corresponding to one fault's full lifecycle (injection → agent detection → agent response → recovery). Multi-fault overlaps are resolved by the reasoning LLM.

**TTD / TTR:** Time-to-Detect and Time-to-Recover — primary quantitative metrics per fault. Computed in Python from LLM-extracted timestamps. Unit: seconds.

**Hallucination Score:** `(UNGROUNDED + UNGROUNDED_EXTERNAL + FABRICATED_TOOL_CALL + TRAJECTORY_DEVIATION + IGNORED_ERROR) / total_response_count`. Computed deterministically in Python. Eight claim types: GROUNDED, INFERRED, UNGROUNDED, UNGROUNDED_EXTERNAL, FABRICATED_TOOL_CALL, TRAJECTORY_DEVIATION, NON_OPERATIONAL, IGNORED_ERROR.

**RAI Hard Gate:** If `personal_pii_detected=True` OR `adversarial_input_count > 0` in any single run, that run's RAI score is forced to 0 — cannot be averaged away. RAI score = Privacy & Security (50%) + Transparency (25%) + Fairness (25%).

**Worst-Case Safety Propagation:** Boolean safety/compliance flags (guardrail violations, unsafe actions) are raised at the category level if ANY single run triggers them.

**LLM Council (Phase 2):** k independent LLM judges each read all ~30 per-run narrative outputs for a metric and propose a consensus summary, severity label, and confidence score. A meta-judge reconciles disagreements. Reduces single-model bias. Prompts in `aggregator/prompt/prompt.yml`.

**Statistical Hypothesis Framework (Phase E, n≥30):**
- H-01: Bootstrap BCa CI + IQM for continuous metrics
- H-02: Wilson CI safety floor for success rates
- H-03: Kruskal-Wallis + Mann-Whitney U + Vargha-Delaney A12 effect size
- H-04: Fisher's Exact Test for success rate uniformity
- H-05: Levene's Test + Coefficient of Variation for variance stability
- H-06: Wilcoxon one-sample test for SLA threshold compliance
- H-07: Exact Binomial for SLA breach rate estimation
- H-08: CVaR tail risk analysis
- H-09: CUSUM/EWMA drift detection

**Agent Registry:** Every agent under test is registered via the `RegisterAgent` GraphQL mutation. This allocates a UUID, triggers a Helm install into Kubernetes, resolves Langfuse project credentials (injected as `--set` values so all traces land in the correct project), and starts a background health-check scheduler managing `REGISTERED→VALIDATING→ACTIVE/INACTIVE→DELETED` state transitions.

**Agent Sidecar:** HTTP proxy sidecar container that runs alongside the agent pod. Intercepts outbound LLM calls to LiteLLM and stamps them with `EXPERIMENT_ID`, `EXPERIMENT_RUN_ID`, `WORKFLOW_NAME` — without any change to the agent itself. Ensures all Langfuse spans are correlated to the correct experiment run.

**LiteLLM:** Unified LLM gateway routing all agent LLM calls to Azure OpenAI, Google Gemini, OpenRouter, or local Ollama. Default model: `qwen2.5-7b-instruct` (Ollama, `ollama_chat` provider). All calls emit OTEL spans to Langfuse. LiteLLM API key: `sk-agentcert-2026` (local dev). Router timeout: 600s. Context window: 16384 tokens.

**Langfuse:** OTEL-compatible LLM trace storage. Every LLM call from agents (via LiteLLM) and from certifier pipeline phases is stored here. Default credentials: `admin@agentcert.local / agentcert-admin`.

**FLASH Methodology:** Microsoft Research's Feedback-guided Agentic Workflow. Key differentiator: hindsight reflection from previous scan cycles is injected into the current scan's system prompt, enabling the agent to learn from its mistakes within a session (bounded FIFO of 20 history entries, no disk persistence).

**MCP (Model Context Protocol):** JSON-RPC 2.0 protocol for tool discovery (`tools/list`) and invocation (`tools/call`). Flash agent uses MCP over HTTP+SSE. sre-agent-crewai uses MCP streamable-HTTP (fresh session per call).

**ITBench:** IBM's benchmark framework for AI agents on IT operations tasks. ACE is ITBench-compatible: harness contracts are `scenario_data.json` input and `agent_data.tar` output.

**ENV_* Resolution:** Any value in `certifier/configs/configs.json` prefixed with `ENV_` is substituted from the corresponding environment variable at load time by `ConfigLoader`. Allows configs.json to reference secrets without hardcoding.

**Ground Truth:** Per-experiment `fault_configuration.json` (secret from agent during runs) defines ideal course of action, ideal tool trajectory, expected diagnostic sequence. Used by Phase 1 to compute `action_correctness` and `tool_selection_accuracy`.

**Kubernetes Namespace for ACE:** `ace` (platform). Agent workloads deploy into the target application namespace (e.g., `sock-shop`).

**Open-weight model tested:** `qwen2.5:7b-instruct` (and `qwen2.5:32b-instruct`) via Ollama, GPU: NVIDIA RTX A6000 (49 GB VRAM).

**ACE-managed Ollama:** `start-local-services.sh` and `docker-compose.yml` (profile: `ollama`) can run an instance-scoped Ollama container (`ollama-${ACE_INSTANCE_NAME}`) on a UID-derived host port (`OLLAMA_PORT`), isolated from the system Ollama on :11434 and from other checkouts. `setup.sh` prompts for the model tag and writes `OLLAMA_MODEL` to `.env`. Models are stored in a named volume (`ollama-models-${ACE_INSTANCE_NAME}`) scoped per instance. GPU access requires NVIDIA Container Toolkit; falls back to CPU automatically.

---

## 6. Development Setup

### Prerequisites

- Docker Engine 28+ (user in `docker` group)
- `kind` v0.20+, `kubectl` v1.27+, and `helm` v3.12+ (for Kubernetes deployment)
- `git` with submodule support
- Python 3.12 (certifier, scripts)
- Go 1.24 (AgentCert backend changes)
- Node.js 20+ (web frontend changes — Node 18 is too old for `sass@1.102.0` and causes build failure)
- At minimum one LLM API credential: Google Gemini (recommended for local dev) or Azure OpenAI

`./scripts/setup.sh` checks all of the above automatically on every run (both `--setup` and `--restart`) via `scripts/check-prerequisites.sh` — it reports versions found, auto-bootstraps Python 3.12 through `uv` (no sudo) when apt doesn't package it, and prints the exact fix command for anything else missing (docker, git, kind, kubectl all need sudo, so those are never installed silently). Run it standalone for a fast sanity check without the full wizard: `./scripts/check-prerequisites.sh`.

### First-Time Setup (Kubernetes)

```bash
# 1. Clone with all submodules
git clone --recurse-submodules https://github.com/AgentCert/ace-monorepo
cd ace-monorepo

# 2. Interactive wizard: prompts for credentials, creates .env, generates values-env.yaml, optionally deploys
./scripts/setup.sh

# 3. Check pods
kubectl get pods -n ace
```

### Local Dev (Docker Compose, fastest — no Kubernetes needed)

```bash
# Copy and fill in credentials
cp .env.example .env
# Edit .env with AZURE_OPENAI_KEY, GEMINI_API_KEY, etc.
# Run setup.sh at least once — it auto-generates ACE_INSTANCE_NAME and OLLAMA_PORT in .env
./scripts/setup.sh --restart   # or ./scripts/setup.sh for interactive first-time

# Start MongoDB + Langfuse + Ollama + LiteLLM + Certifier
./scripts/start-local-services.sh

# Selective start
./scripts/start-local-services.sh --only-mongo
./scripts/start-local-services.sh --skip-langfuse
./scripts/start-local-services.sh --skip-ollama   # skip Ollama (if using cloud LLM only)
./scripts/start-local-services.sh --only-ollama   # start only Ollama

# Force restart everything
./scripts/start-local-services.sh --restart

# Use pre-built certifier image instead of building from source
./scripts/start-local-services.sh --pull-certifier

# Alternatively: use the one-command root docker-compose.yml with the safety guard
# (belt-and-suspenders check against cross-checkout container collisions)
./scripts/compose-up-guard.sh up -d
./scripts/compose-up-guard.sh down
```

### Certifier Development

```bash
cd certifier

# Install dependencies
pip install -r requirements.txt

# Required: set MongoDB connection
export MONGODB_CONNECTION_STRING="mongodb://admin:1234@localhost:27017/?replicaSet=rs0&authSource=admin"

# Start FastAPI with hot reload
uvicorn main.main:app --host 0.0.0.0 --port 8000 --reload

# Run Phase 0+1 standalone (no HTTP server)
python run_bucketing_and_extraction_pipeline.py \
    --trace-file data/sample_trace.json \
    --output-dir /tmp/test-run \
    [--batch-size 5] [--store] [--fault-pruning] [--debug-metrics]

# Run Phase 2+3 standalone
python run_full_certification_pipeline.py \
    --metrics-dir /tmp/test-run/metrics \
    --output-dir /tmp/test-cert \
    --agent-id test-agent \
    --agent-name "Test Agent" \
    [--runs-per-fault 30] [--advanced-analysis]

# Run Phase 4 rendering standalone
cd cert_reporter
python main.py generate \
    --agent-id <id> --experiment-id <exp> \
    --format html,pdf --mode static
```

### GraphQL Server Development

```bash
cd AgentCert/chaoscenter/graphql/server

# Regenerate gqlgen models (run after schema changes)
go generate ./...

go build ./...
go test ./...
```

### Web Frontend Development

```bash
cd AgentCert/chaoscenter/web
npm install
npm start     # webpack dev server :2001 with hot reload
npm run build # production Webpack build
npm test      # Jest unit tests
```

### Flash Agent Development

```bash
cd flash-agent
pip install -r requirements.txt

export OPENAI_BASE_URL="http://localhost:14000/v1"
export OPENAI_API_KEY="sk-agentcert-2026"
export MODEL_ALIAS="qwen2.5-7b-instruct"
export MCP_URLS="http://localhost:8081/sse"

MAX_ITERATIONS=1 python main.py   # single scan
make build && make run             # Docker build and run
```

### Updating Submodules

```bash
git submodule update --remote --merge
```

### Known Operational Gotchas

**`--restart` without `--local-build` silently skips Go rebuilds.**
`setup.sh --restart` redeploys the Helm charts and restarts containers, but it does **not** rebuild Go binaries or Docker images from source. If you changed Go code in `AgentCert/` (e.g. a new ClusterRoleBinding in `1a_argo_rbac.yaml`, a bug fix in the certification package), you must run:
```bash
./scripts/setup.sh --restart --local-build
```
Otherwise the old image remains in the cluster with no warning.

**JFrog 401 kills experiments mid-run.**
If any `*_IMAGE_SOURCE` in `.env` is set to `jfrog`, containerd will attempt to pull from JFrog at experiment execution time. If credentials are missing, expired, or the token has been rotated, the experiment step fails unrecoverably — there is no retry and the run must be abandoned. For KinD-based experiments, always prefer `local` (build from source + kind load via `scripts/prepare-images.sh`) unless you have verified JFrog credentials are fresh in the cluster.

**KIND_CLUSTER_NAME mismatch in `.env` breaks cluster access.**
If `.env` was copied from another machine or checkout, `KIND_CLUSTER_NAME` may not match the actual cluster name on this host. `setup.sh --restart` auto-detects the running cluster and corrects `.env`, but a raw `kubectl` or `helm` command will fail if the kubeconfig context is wrong. Always run `kind get clusters` to verify before manual kubectl work.

**Credential YAML files must be gitignored before creation.**
Experiment configuration files that embed live secrets (e.g. `itbench-litmus-chaos-enable.yml` which carries a LitmusChaos `ACCESS_KEY`) must be added to `.gitignore` **before** they are written to disk. If one is accidentally committed, remove it from remote with `git rm --cached` and rotate the key immediately — the key lives in git history even after the file is deleted.

**Very new Ubuntu releases may not have `python3.12` in apt at all.**
Ubuntu ships whatever CPython is current as the `python3` default at release time, and that version climbs every release. On a release newer than whatever this repo's contributors had when they last checked (e.g. 26.04 defaults to Python 3.14), apt's `python3.12` package may not exist yet, and the usual deadsnakes-PPA fallback may not have published builds for that codename yet either. `scripts/check-prerequisites.sh` (run standalone or automatically via `setup.sh`) detects this and offers to bootstrap Python 3.12 through `uv` instead — a sudo-free tool that ships prebuilt CPython binaries independent of the OS package manager, so it isn't blocked on the distro catching up. This only matters for certifier local dev outside Docker (§6 "Certifier Development"); the Compose and Kubernetes deploy paths run certifier from the prebuilt image and never need it.

---

## 7. Entry Points

### Most Important Commands

```bash
# Canonical benchmarking: trigger experiment via LitmusChaos Argo Workflow
# (AgentCert UI → Experiments → Run, or via GraphQL RunChaosWorkFlow mutation)

# Dev-tool: run flash-agent trace_based pipeline locally (no LitmusChaos control plane)
python scripts/ace-bench.py flash-agent --runs 30

# Run certifier pipeline for a single trace (no FastAPI server needed)
python scripts/run_certification.py --trace-id <LANGFUSE_UUID>
python scripts/run_certification.py --trace-id <UUID> --no-pdf --debug

# Start local dev stack (start-local-services manages MongoDB, Langfuse, Ollama, LiteLLM, Certifier)
./scripts/start-local-services.sh
./scripts/start-local-services.sh --restart
./scripts/start-local-services.sh --skip-ollama   # skip Ollama when using cloud LLMs only

# Alternative: one-command root docker-compose.yml with ownership guard
./scripts/compose-up-guard.sh up -d

# Redeploy Kubernetes stack with existing .env (no prompts)
./scripts/setup.sh --restart

# Build and push all Docker images to Docker Hub
./scripts/build-and-push.sh

# Start certifier API server
cd certifier && uvicorn main.main:app --host 0.0.0.0 --port 8000

# Phase 0+1 CLI (from certifier/)
python run_bucketing_and_extraction_pipeline.py --trace-file trace.json --output-dir out/

# Phase 2+3 CLI (from certifier/)
python run_full_certification_pipeline.py \
    --metrics-dir out/ --output-dir cert/ \
    --agent-id <id> --agent-name "My Agent"

# Phase 4 CLI (from certifier/cert_reporter/)
python main.py generate --agent-id <id> --experiment-id <exp> --format html,pdf --mode static

# Flash agent single scan
MAX_ITERATIONS=1 python flash-agent/main.py

# Dump a Langfuse trace to offline JSON
python scripts/dump_langfuse_trace.py --experiment-id <UUID> --run-id <UUID> --output-dir ./traces/

# H01-H09 statistical tests standalone
cd certifier && python -m hypothesis_framework.scripts.run_statistical_hypothesis \
    --data-dir <dir> --gt-dir <groundtruth_dir> --output-file results.json

# Docker image management
cd certifier && make build    # build certifier image
cd certifier && make push     # push to Docker Hub
cd certifier && make kind-load  # load into local kind cluster
cd flash-agent && make build && make run
```

### Certifier REST API Workflow

```bash
# Submit Phase 0+1
curl -X POST http://localhost:8000/api/v1/bucketing-extraction \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "<agent-id>",
    "experiment_id": "<exp-id>",
    "run_id": "<run-id>",
    "trace_source": {"type": "file", "file_path": "/path/to/trace.json"}
  }'
# Returns: {"status": "PENDING", "task_id": "...", "poll_url": "..."}

# Poll Phase 0+1
curl "http://localhost:8000/api/v1/tasks?experiment_id=<exp>&experiment_run_id=<run>"

# Submit Phase 2+3 (after all runs COMPLETED)
curl -X POST http://localhost:8000/api/v1/aggregation-certification \
  -H "Content-Type: application/json" \
  -d '{"agent_id": "<id>", "agent_name": "<name>", "experiment_id": "<exp>"}'

# Poll Phase 2+3
curl "http://localhost:8000/api/v1/cert-tasks?experiment_id=<exp>"
```

---

## 8. Environment Variables

All consumed from root `.env` file (created by `scripts/setup.sh`). Values prefixed `ENV_` in JSON configs are resolved from env at runtime by ConfigLoader.

### Shared-Host Isolation (auto-set by `setup.sh`)

These are backfilled into `.env` automatically on every `setup.sh` run (both `--setup` and `--restart`). Do not set them to the same value as another checkout on this host.

| Variable | Default | Purpose |
|----------|---------|---------|
| `ACE_INSTANCE_NAME` | username (from `id -un`) | Suffix for all container names, volume names, Compose project names, and KinD cluster names — ensures two checkouts never collide on the shared host. All scripts read this; never leave it blank. |
| `OLLAMA_PORT` | UID-derived, verified free | Host port for this checkout's Ollama container; avoids collision with system Ollama on :11434 and other checkouts. |
| `OLLAMA_MODEL` | `qwen2.5:32b-instruct` (setup.sh default) | Model tag to pull/use. `setup.sh` prompts interactively; empty means Ollama is skipped. |
| `MONGO_PORT` | `27017` | Host port for this checkout's MongoDB; override if :27017 is taken by another checkout. |
| `LANGFUSE_PORT` | `4000` | Host port for Langfuse web; override if :4000 is taken. |
| `MINIO_API_PORT` | `9090` | Host port for Langfuse MinIO S3 API; override if :9090 is taken. |
| `LITELLM_PORT` | `14000` | Host port for LiteLLM proxy; override if :14000 is taken. |
| `AGENT_CHARTS_ROOT` | `<repo-root>/agent-charts` | Absolute path to agent Helm charts for this checkout. Auto-set by `setup.sh`; corrects values copied from another checkout. |
| `APP_CHARTS_ROOT` | `<repo-root>/app-charts` | Absolute path to app Helm charts for this checkout. Auto-set by `setup.sh`; corrects values copied from another checkout. |

### Critical — Certifier

| Variable | Default | Purpose |
|----------|---------|---------|
| `MONGODB_CONNECTION_STRING` | **required** | Certifier fails on startup if absent |
| `AZURE_OPENAI_API_KEY` | — | Extraction model (GPT-4o class) |
| `AZURE_OPENAI_ENDPOINT` | — | Extraction model endpoint |
| `AZURE_OPENAI_API_VERSION` | — | e.g., `2024-12-01-preview` |
| `AZURE_OPENAI_CHAT_DEPLOYMENT_NAME` | — | Extraction model deployment name |
| `AZURE_OPENAI_GPT5_API_KEY` | — | Reasoning model (o-series/gpt-5.x) |
| `AZURE_OPENAI_GPT5_ENDPOINT` | — | Reasoning model endpoint |
| `AZURE_OPENAI_GPT5_API_VERSION` | — | Reasoning model API version |
| `AZURE_OPENAI_GPT5_CHAT_DEPLOYMENT_NAME` | — | Reasoning model deployment name |
| `AZURE_EMBEDDING_ENDPOINT` | — | Embedding model (text-embedding-3-small) |
| `AZURE_EMBEDDING_API_KEY` | — | Embedding model key |
| `AZURE_EMBEDDING_MODEL` | — | Embedding deployment name |
| `WORKSPACE_DIR` | `workspace` | Phase 0+1 output root |
| `CERT_WORKSPACE_DIR` | `workspace/cert` | Phase 2+3+4 output root |
| `API_MAX_CONCURRENT_TASKS` | `4` | Phase 0+1 concurrency cap |
| `API_MAX_CONCURRENT_CERT_TASKS` | `2` | Phase 2+3 concurrency cap |
| `API_HOST` | `0.0.0.0` | Uvicorn bind host |
| `API_PORT` | `8000` | Uvicorn bind port |
| `MONGODB_DATABASE` | `agentcert` | MongoDB database name |
| `LANGFUSE_HOST` | — | Langfuse URL (for Langfuse trace source) |
| `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` | — | Langfuse authentication |
| `OPENAI_COMPATIBLE_BASE_URL` | `http://127.0.0.1:11434/v1` | Local Ollama endpoint |
| `PLAYWRIGHT_BROWSERS_PATH` | `/opt/playwright-browsers` (Docker) | Playwright Chromium binary path |
| `AZURE_CONTENT_SAFETY_ENDPOINT` / `AZURE_CONTENT_SAFETY_API_KEY` | — | Optional RAI checks |
| `AZURE_STORAGE_CONNECTION_STRING` | — | Optional Azure Blob Storage for reports |

### Critical — Platform / Infrastructure

| Variable | Purpose |
|----------|---------|
| `MONGODB_USERNAME` / `MONGODB_PASSWORD` | MongoDB replica set admin credentials (admin / 1234 in local dev) |
| `GEMINI_API_KEY` | Google Gemini (minimum required for LiteLLM local dev) |
| `AZURE_OPENAI_KEY` / `AZURE_OPENAI_ENDPOINT` / `AZURE_OPENAI_DEPLOYMENT` | Azure OpenAI for LiteLLM + agents |
| `OPENROUTER_API_KEY` | OpenRouter (optional fallback) |
| `LITELLM_MASTER_KEY` | LiteLLM gateway auth key (local dev: `sk-agentcert-2026`) |
| `LANGFUSE_ORG_ID` / `LANGFUSE_PROJECT_ID` | Langfuse project scoping for GraphQL server |
| `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | Used by `build-and-push.sh` |
| `ALLOWED_ORIGINS` | CORS/WebSocket origin allowlist. Extended regex includes `[a-z0-9.-]+\.svc\.cluster\.local` so in-cluster Kubernetes services (e.g. subscriber) can connect. |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Langfuse PostgreSQL |
| `REDIS_AUTH` | Langfuse Redis password |
| `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD` | Langfuse ClickHouse |
| `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` | Langfuse MinIO S3 |

### Experiment Image Sources

Controls where Argo Workflow step images are pulled at experiment run time. `setup.sh` prompts for each; can also be edited directly in `.env` and applied with `scripts/prepare-images.sh`.

| Variable | Default | Purpose |
|----------|---------|---------|
| `INSTALL_APP_IMAGE_SOURCE` | `dockerhub` | Image source for the install-app workflow step: `dockerhub` (public, no creds), `jfrog` (requires JFROG_* creds), `local` (build from source + kind load) |
| `INSTALL_AGENT_IMAGE_SOURCE` | `dockerhub` | Same options for the install-agent step |
| `LITMUS_IMAGES_SOURCE` | `dockerhub` | LitmusChaos helper images: `dockerhub` or `local` (pre-pull + kind load; JFrog not supported for these). `litmuschaos/go-runner:latest` must be present — verify it is included in `prepare-images.sh` before running chaos faults. |
| `JFROG_HOST` | `infyartifactory.jfrog.io` | JFrog Artifactory hostname — only needed when any `*_IMAGE_SOURCE=jfrog` |
| `JFROG_REGISTRY_PATH` | `docker-local` | JFrog registry path |
| `JFROG_USER` | — | JFrog username |
| `JFROG_TOKEN` | — | JFrog API token / password |

### Critical — Flash Agent

| Variable | Default | Purpose |
|----------|---------|---------|
| `OPENAI_BASE_URL` | **required** | LLM endpoint; Azure detected if `.openai.azure.com` in URL |
| `OPENAI_API_KEY` | **required** | API key |
| `MODEL_ALIAS` | **required** | Model name passed to OpenAI client |
| `MCP_URLS` | **required** | Comma-separated MCP server URLs |
| `AZURE_API_VERSION` | `2025-04-01-preview` | Used only for Azure endpoints |
| `MCP_TIMEOUT` | `30` | Per-call MCP timeout (seconds) |
| `LLM_REQUEST_TIMEOUT` | `120.0` | LLM HTTP request timeout |
| `LLM_MAX_RETRIES` | `2` | LLM SDK retry count |
| `LOG_LEVEL` | `INFO` | DEBUG/INFO/WARNING/ERROR |
| `MAX_ITERATIONS` | `10` | Outer scan-cycle cap |
| `RESCAN_DELAY` | `30` | Seconds between scan cycles when issues remain |
| `WATCH_MODE` | `false` | Enable watch mode (set true/1/yes) |
| `WATCH_NAMESPACE` | — | Required in watch mode |
| `WATCH_INTERVAL` | `5.0` | Poll interval (seconds) in watch mode |
| `AGENT_SCOPE_NAMESPACE` | — | Force K8s namespace; skips MCP scope discovery |

### Auth Service

`ADMIN_USERNAME`, `ADMIN_PASSWORD`, `DB_SERVER`, `DB_USER`, `DB_PASSWORD`, `JWT_EXPIRY_MINS` (default 1440), `OAUTH_JWT_EXP_MINS` (default 5), `DEX_ENABLED` (default false), `REST_PORT`, `GRPC_PORT`, `ALLOWED_ORIGINS`

---

## 9. Data Flow

### End-to-End: Fault Injection → Certificate

```
1. UI/CLI creates and runs experiment
   GraphQL mutation → Kubernetes chaos infrastructure subscriber (gRPC WebSocket)
   └─► Argo Workflow in litmus namespace:
       Step 1: install-app  (sock-shop Helm chart via agentcert/agentcert-install-app image)
       Step 2: install-agent (flash-agent Helm chart via agentcert/agentcert-install-agent image)
                   ├── Creates flash-agent Deployment in sock-shop namespace
                   └── Creates agent-sidecar container alongside agent
       Step 3: inject fault (LitmusChaos ChaosEngine — pod-delete/network-loss/cpu-hog/etc.)
       Step 4: cleanup

2. Agent operates during fault (no knowledge of what fault was injected)
   flash-agent → MCP calls to K8s MCP Server (:8081) + Prometheus MCP (:8083)
   flash-agent → LLM calls → [Agent Sidecar stamps EXPERIMENT_ID + RUN_ID headers]
               → LiteLLM Proxy (:14000) → LLM provider (Azure/Gemini/Ollama)
   LiteLLM → OTEL spans → Langfuse (:4000) [spans tagged with experiment trace ID]

3. Experiment run reaches terminal state
   Argo notifies → GraphQL ChaosExperimentRunEvent handler
   └─► certification pkg fires automatically:
       POST /api/v1/bucketing-extraction to certifier (:18000)
       └─► MongoDB: PENDING task created
           └─► asyncio.Semaphore → background worker:
               ├── Phase 0: Reasoning LLM classifies spans → fault_buckets/*.json
               └── Phase 1: Extraction LLM + Python → *_metrics.json per fault
               └─► MongoDB: COMPLETED, storage_paths recorded

4. ALL_RUNS_COMPLETED gate (GraphQL certification pkg checks after each run)
   When all expected runs are COMPLETED:
   POST /api/v1/aggregation-certification to certifier
   └─► MongoDB: PENDING cert task created
       └─► asyncio.Semaphore → background worker:
           ├── Phase 2: Discovers all *_metrics.json across all runs
           │   Groups by fault_category (9 categories)
           │   Python: mean/median/p95/stddev/success_rate per category
           │   LLM Council: k judges + meta-judge → narrative fields
           │   [Phase E if n≥30: H01-H09 statistical tests]
           │   Output: aggregation.json
           ├── Phase 3: CertificationPipeline
           │   5 LLM narrative builders (asyncio.gather, concurrent)
           │   Recommendations builder (sequential, after Limitations)
           │   ReportAssembler → Pydantic v2 validation (FAIL HARD if invalid)
           │   Output: certification.json
           └── Phase 4: LangGraph pipeline
               preprocess → charts (Altair→Vega→SVG) → [llm_enrich optional]
               → html_render (Jinja2) → pdf_render (Playwright headless Chromium, A4)
               Output: <doc_id>.html + <doc_id>.pdf
               [Optionally stored in MongoDB GridFS cert_reports bucket]

5. Certificate retrieval
   GET /api/certification/{projectId}/{experimentId}/certificate.pdf
   → GraphQL handler proxies to certifier → GridFS first, filesystem fallback
```

---

## 10. Testing

### Certifier (pytest, asyncio_mode=auto)

```bash
cd certifier

# Full suite
pytest

# Specific subsystems
pytest fault_analyzer/tests/ -v
pytest metrics_extractor/tests/ -v
pytest aggregator/tests/ -v
pytest cert_builder/tests/ -v
pytest cert_reporter/tests/ -v
pytest hypothesis_framework/tests/ -v
pytest main/tests/ -v
pytest utils/tests/ -v

# With coverage (for SonarQube)
pytest --cov=. --cov-report=xml

# API integration test
python test_api.py
```

### AgentCert Backend (Go)

```bash
cd AgentCert/chaoscenter/graphql/server && go test ./...
cd AgentCert/chaoscenter/authentication && go test ./...
cd AgentCert/chaoscenter/event-tracker && go test ./...
```

### Web Frontend

```bash
cd AgentCert/chaoscenter/web
npm test        # Jest unit tests
npm run build   # TypeScript type check + Webpack production build
```

### Pipeline Smoke Test (requires running FastAPI service)

```bash
# End-to-end certifier API smoke test
# See /pipeline-smoke-test skill for the exact sequence (bucketing → poll → aggregation → poll)

# Quick dev test without FastAPI server:
python scripts/run_certification.py --trace-id <UUID> --debug
```

### SonarQube

```
sonar-project.properties defines:
  sonar.projectKey=ace-monorepo
  sonar.sources=certifier,flash-agent,agent-sidecar,litmus-go,AgentCert/chaoscenter
  sonar.python.version=3.12
```

---

## 11. Published Docker Images

All pushed to Docker Hub under the `agentcert` org by `scripts/build-and-push.sh`.

| Image | Built from | Purpose |
|-------|-----------|---------|
| `agentcert/agentcert-flash-agent:latest` | `flash-agent/Dockerfile` | Flash Agent |
| `agentcert/agent-sidecar:latest` | `agent-sidecar/Dockerfile` | LLM call interceptor sidecar |
| `agentcert/agentcert-install-agent:latest` | `agent-charts/` | Helm install wrapper for agent deploy |
| `agentcert/agentcert-install-app:latest` | `app-charts/` | Helm install wrapper for app deploy |
| `agentcert/certifier:latest` | `certifier/Dockerfile` | Certifier FastAPI + all pipeline phases |
| `agentcert/agentcert-graphql:latest` | `AgentCert/chaoscenter/graphql/` | GraphQL API server |
| `agentcert/agentcert-auth:latest` | `AgentCert/chaoscenter/authentication/` | Auth service |
| `agentcert/agentcert-web:latest` | `AgentCert/chaoscenter/web/` | React UI served by nginx |

---

## 12. Project-Specific Claude Skills

Available via the Skill tool (prefix `/`). Defined in `.claude/skills/`:

| Skill | When to use |
|-------|-------------|
| `/setup-local` | Bootstrap a fresh local dev environment |
| `/run-certification` | Run full pipeline locally against a Langfuse trace |
| `/pipeline-smoke-test` | Smoke test the certifier API end-to-end (bucketing→poll→aggregation→poll) |
| `/release-images` | Build and push all Docker images to Docker Hub |
| `/new-pr` | Open a PR with ACE Conventional-Commit conventions and standard template |
| `/gen-tests` | Generate unit tests for the current diff in the correct framework |
| `/bump-submodule` | Advance a submodule pointer to its tracked branch head |

---

## 13. What NOT to Explore (Skip to Save Tokens)

These paths are generated, vendored, binary, or otherwise not worth reading:

**JavaScript/Node:**
- `AgentCert/chaoscenter/web/node_modules/` — ~3,000+ packages
- `AgentCert/chaoscenter/web/dist/` or `build/` — Webpack output
- `AgentCert/chaoscenter/web/.cache/` — Webpack dev cache

**Go generated code (do not edit manually):**
- `AgentCert/chaoscenter/graphql/server/graph/generated/generated.go` — gqlgen auto-generated (re-generated by `go generate ./...`)
- `AgentCert/chaoscenter/graphql/server/graph/model/models_gen.go` — gqlgen auto-generated models
- `AgentCert/chaoscenter/event-tracker/api/v1/zz_generated.deepcopy.go` — controller-gen output
- `AgentCert/chaoscenter/authentication/api/presenter/protos/*.pb.go` — protobuf generated
- `**/go.sum` — dependency checksums (binary-like, not human-productive)

**Python bytecode and caches:**
- `certifier/__pycache__/` and all `**/__pycache__/` directories
- `scripts/__pycache__/`
- `certifier/.pytest_cache/`
- Any `.venv/` or `venv/` directories

**Large data and runtime outputs:**
- `certifier/data/` — test trace fixtures (large, not code)
- `certifier/trace_dump/` — dumped traces for offline dev
- `data/` — root-level sample data
- `.tmp/` — runtime pipeline workspace outputs
- `certifier/htmlcov/` — coverage HTML (if generated)

**Notebooks (exploratory, not production):**
- `certifier/batch_process_traces.ipynb`
- `certifier/batch_process_traces_pii.ipynb`

**Generated/secret configs:**
- `deploy/helm/ace/values-env.yaml` — generated by `setup.sh` from `.env`; contains secrets; gitignored
- `.env` — local secrets; gitignored; **never commit**
- `itbench-litmus-chaos-enable.yml` (and any `*-enable.yml` experiment config) — contains live `ACCESS_KEY` credentials; gitignored; **never commit**. See "Known Operational Gotchas" in Section 6.

**Submodule internals rarely needed:**
- `chaos-charts/` — LitmusChaos fault YAML templates; only needed when adding new fault types
- `litmus-go/` — LitmusChaos Go fault injector implementations; only needed for fault implementation work
- `agents/sre-agent/ITBench-Evaluations/` — LLM-as-a-Judge evaluator submodule; upstream, rarely modified

**Historical documents (informational only):**
- `OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` — historical handoff document
- `OPEN_WEIGHT_CERTIFICATION_HANDOFF_READABLE.md` — same content, formatted
- `ITBENCH_WORK_IN_PROGRESS.md` — in-progress notes

**File types to skip unless actively editing them:**
- `*.pb.go` — protobuf generated
- `go.sum` — dependency checksums
- `*.jsonl` in data/ directories — test fixtures
- `zz_generated.*.go` — controller-gen generated
- `*.pyc` — compiled Python

---

## 14. Default Credentials (Local Dev)

Ports marked with * are parameterized via `.env` (see Section 8, Shared-Host Isolation) and may differ from the defaults below on a shared host. Always check your `.env` for the actual values.

| Service | URL | Username | Password |
|---------|-----|----------|----------|
| AgentCert UI | http://localhost:2001 | admin | litmus |
| Langfuse | http://localhost:`$LANGFUSE_PORT` (default 4000) | admin@agentcert.local | agentcert-admin |
| MongoDB | localhost:`$MONGO_PORT` (default 27017) (rs0) | admin | 1234 |
| LiteLLM Proxy | http://localhost:`$LITELLM_PORT` (default 14000) | — | sk-agentcert-2026 |
| Ollama API | http://localhost:`$OLLAMA_PORT` (default UID-derived) | — | — |
| Certifier Swagger | http://localhost:8000/docs | — | — |

MongoDB connection string (replace port if MONGO_PORT differs): `mongodb://admin:1234@localhost:27017/?replicaSet=rs0&authSource=admin`
