# Architecture — AgentCert Certifier

## Overview

AgentCert is a **four-phase analytical pipeline** that consumes raw Langfuse traces from AI agents under Kubernetes fault injection and produces structured 12-section certification reports. The same pipeline logic is accessible via a **REST API** (async job model) and directly via **CLI commands**.

```
Raw Langfuse Trace (JSON)
         │
         ▼
┌──────────────────────┐
│  Phase 0             │  LLM classifies interleaved trace events into
│  Fault Bucketing     │  per-fault lifecycle buckets
│  fault_analyzer/     │
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│  Phase 1             │  LLM extracts quantitative (TTD, TTR, tokens)
│  Metrics Extraction  │  and qualitative metrics per fault bucket
│  metrics_extractor/  │  → writes *_metrics.json + optionally MongoDB
└────────┬─────────────┘
         │  (repeated N times, one per agent run)
         ▼
┌──────────────────────┐
│  Phase 2             │  Pure-Python statistical aggregation per fault
│  Aggregation         │  category + LLM Council narrative synthesis
│  aggregator/         │  → writes aggregation.json (CertificationScorecard)
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│  Phase 3             │  Builds a validated 12-section CertificationReport
│  Certification       │  with 5 concurrent LLM narrative builders
│  cert_builder/       │  → writes certification.json
└─────────────────────-┘
```

---

## Repository Layout

```
certifier/
│
├── main/                        # FastAPI application layer
│   ├── main.py                  # App factory, MongoDB lifespan, index creation
│   ├── config/
│   │   └── settings.py          # Env-var-backed Settings singleton
│   ├── models/
│   │   ├── bucket_requests.py   # BucketingExtractionRequest, TraceSource union
│   │   ├── bucket_responses.py  # TaskAcceptedResponse, TaskStatusResponse
│   │   ├── cert_requests.py     # AggregationCertificationRequest
│   │   └── cert_responses.py    # CertTaskAcceptedResponse
│   ├── routers/
│   │   ├── bucketing_extraction.py       # POST /bucketing-extraction, GET /tasks/{id}
│   │   └── aggregation_certification.py  # POST /aggregation-certification, GET /cert-tasks/{id}
│   ├── services/
│   │   ├── session_service.py   # MongoDB task lifecycle (SessionService, CertSessionService)
│   │   ├── trace_service.py     # Trace acquisition (file copy or Langfuse fetch)
│   │   └── pipeline_service.py  # BucketPipelineService, CertPipelineService
│   └── workers/
│       ├── bucket_task_runner.py  # Background coroutine: Phase 0+1
│       └── cert_task_runner.py    # Background coroutine: Phase 2+3
│
├── fault_analyzer/              # Phase 0: LLM fault bucketing
├── metrics_extractor/           # Phase 1: quantitative + qualitative extraction
├── aggregator/                  # Phase 2: deterministic stats + LLM Council
├── cert_builder/                # Phase 3: 12-section CertificationReport
│
├── utils/
│   ├── azure_openai_util.py     # AzureLLMClient (handles reasoning model quirks)
│   ├── mongodb_util.py          # MongoDBClient + Atlas Vector Search
│   ├── load_config.py           # ConfigLoader: ENV_ variable resolution
│   └── setup_logging.py         # Shared logger
│
├── configs/configs.json         # Global model + MongoDB + blob config
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
└── .env.example
```

---

## Application Layer (`main/`)

### Startup and lifespan (`main/main.py`)

The FastAPI `lifespan` context manager runs once on startup and once on shutdown:

1. Loads `configs/configs.json` via `ConfigLoader` (resolves all `ENV_` variable references)
2. Creates an `AsyncIOMotorClient` (Motor async MongoDB driver)
3. Binds five collections to `app.state`, creating their indexes idempotently:
   - `pipeline_tasks`
   - `certification_tasks`
   - `certification_metadata`
   - `aggregated_category_metadata`
   - (metrics written by Phase 1 go to `agent_run_metrics` via `MongoDBClient`)
4. Attaches two `asyncio.Semaphore` instances — one per pipeline type — to cap concurrent heavy executions
5. Ensures workspace directories exist before the first request

On shutdown, the Motor connection pool is closed after in-flight background tasks complete (Uvicorn `timeout_graceful_shutdown=300`).

### Request flow — Phase 0+1

```
POST /api/v1/bucketing-extraction
  │
  ├─ 1. Duplicate guard: find_active_task(agent_id, experiment_id, run_id)
  │       → 409 TASK_ALREADY_ACTIVE if found
  │
  ├─ 2. create_task() → pipeline_tasks (PENDING)
  │
  ├─ 3. Return 202 { task_id, poll_url }
  │
  └─ 4. background_tasks.add_task(run_task, ...)
           │
           ├─ set_started()           → pipeline_tasks (RUNNING / acquiring_trace)
           ├─ TraceService.acquire_trace()   [file copy or Langfuse API]
           ├─ update_stage()          → pipeline_tasks (running_pipeline)
           ├─ [semaphore] BucketPipelineService.execute_pipeline()
           │       Phase 0: FaultBucketingPipeline
           │       Phase 1: TraceMetricsExtractor × N faults
           │       [if storage_config.type ∈ {mongodb, hybrid}]
           │         → MongoDBClient.insert_metrics() → agent_run_metrics
           └─ set_completed() / set_failed()  → pipeline_tasks
```

### Request flow — Phase 2+3

```
POST /api/v1/aggregation-certification
  │
  ├─ 1. Validate storage_config.type == "local"
  ├─ 2. Derive metrics_dir if not supplied
  ├─ 3. Pre-flight: _discover_and_validate() — count *metrics.json for agent_id
  │       → 400 METRICS_NOT_FOUND if none
  ├─ 4. Duplicate guard: find_active_task(agent_id, experiment_id)
  │       → 409 TASK_ALREADY_ACTIVE if found
  ├─ 5. create_task() → certification_tasks (PENDING)
  ├─ 6. Return 202 { cert_task_id, poll_url }
  └─ 7. background_tasks.add_task(run_cert_task, ...)
           │
           ├─ set_started()            → certification_tasks (RUNNING / fetching_metrics)
           ├─ resolve_cert_output_dir()
           ├─ [semaphore] CertPipelineService.execute_pipeline()
           │       Phase 2: AggregationOrchestrator
           │       Phase 3: CertificationPipeline (5 concurrent narrative builders)
           ├─ update_stage()            → certification_tasks (storing_metadata)
           ├─ _write_certification_metadata()   → certification_metadata (1 doc)
           ├─ _write_aggregated_category_metadata() → aggregated_category_metadata (N docs)
           └─ set_completed() / set_failed()   → certification_tasks
```

### Task state machine

```
PENDING ──► RUNNING ──► COMPLETED
   │            │
   └────────────┴──► FAILED
```

Each transition uses a **`status` filter in `update_one`** so concurrent writes cannot double-advance a task. `set_completed()` raises `ValueError` if the task is not currently `RUNNING` (double-write guard).

### Concurrency model

- `asyncio.Semaphore(API_MAX_CONCURRENT_TASKS=4)` — caps simultaneous Phase 0+1 runs
- `asyncio.Semaphore(API_MAX_CONCURRENT_CERT_TASKS=2)` — caps simultaneous Phase 2+3 runs (lower because cert runs are significantly heavier)
- Background tasks are FastAPI `BackgroundTask` coroutines — they run in the same event loop, not in threads
- Blocking filesystem I/O inside workers is dispatched via `asyncio.to_thread` to avoid stalling the event loop

---

## Phase 0 — Fault Bucketing (`fault_analyzer/`)

**Input:** raw Langfuse trace JSON (array of observation/span objects)  
**Output:** per-fault bucket files + manifest in `fault_buckets/`

The `FaultBucketingPipeline` sends interleaved trace events to an LLM in configurable batches (`llm_batch_size`, default 5). The LLM classifies each event as belonging to a specific fault lifecycle phase (pre-injection, detection, mitigation, post-mitigation). Events are grouped into `FaultBucket` objects, one per detected fault.

Key design points:
- Batching prevents token limit exhaustion on long traces
- The LLM does **classification only** — no quantitative arithmetic
- Bucket metadata includes: `fault_id`, `fault_name`, `severity`, `injection_timestamp`, `target_pod`, `namespace`, `ground_truth`

---

## Phase 1 — Metrics Extraction (`metrics_extractor/`)

**Input:** fault bucket (events slice) + fault config JSON  
**Output:** `*_metrics.json` per fault (optionally also written to MongoDB)

`TraceMetricsExtractor` runs two LLM extraction passes per fault:

| Pass | Model | Output schema |
|---|---|---|
| Quantitative | extraction model (GPT-4o) | `LLMQuantitativeExtraction` — TTD, TTR, token counts, tool calls, PII |
| Qualitative | extraction model | `LLMQualitativeExtraction` — RAI status, security compliance, reasoning quality, hallucination score |

Results are combined into an `ExtractionResult` and written to `{fault_id}_{run_id}_metrics.json`. When `store_to_mongodb=True`, `MongoDBClient.insert_metrics()` also stores the combined document (with optional 1536-dim vector embedding) in `agent_run_metrics`.

---

## Phase 2 — Aggregation (`aggregator/`)

**Input:** directory of `*_metrics.json` files from Phase 1 (N runs × M faults)  
**Output:** `aggregation.json` — a `CertificationScorecard`

Two components:

**1. Deterministic numeric aggregation (pure Python, no LLM)**
- `DirectoryQueryService` reads all `*_metrics.json` files and groups them by `(agent_id, fault_category)`
- `AggregationOrchestrator` computes mean, median, p95, success rates per category
- Results are fully reproducible

**2. LLM Council for qualitative synthesis**
- k independent LLM judges each assess the qualitative data for a fault category
- A meta-judge produces a consensus narrative from the k responses
- Concurrency is capped to avoid rate-limiting

The scorecard shape:
```
CertificationScorecard
  ├── agent_id, agent_name, certification_run_id
  ├── total_runs, total_fault_categories, total_faults_tested
  └── fault_category_scorecards[]
        ├── fault_category, total_runs, faults_tested[]
        ├── numeric_metrics { time_to_detect, time_to_mitigate, tokens, ... }
        └── derived_metrics { detection_rate, mitigation_rate, rai_rate, security_rate }
```

---

## Phase 3 — Certification (`cert_builder/`)

**Input:** `aggregation.json` (CertificationScorecard)  
**Output:** `certification.json` — a validated 12-section `CertificationReport`

`CertificationPipeline` runs **5 narrative builders concurrently** via `asyncio.gather`:

| Builder | Section |
|---|---|
| Executive summary | High-level pass/fail narrative |
| Fault resilience | Per-category detection/mitigation analysis |
| RAI compliance | Responsible AI check results |
| Security compliance | Security posture assessment |
| Performance | Token usage, trajectory efficiency |

A sixth builder — **Recommendations** — runs **sequentially after Limitations** (explicit dependency on the limitations section content).

The final report is validated against the `CertificationReport` Pydantic schema. If validation fails, the pipeline errors rather than emitting a malformed report.

---

## Shared Utilities (`utils/`)

### `AzureLLMClient` (`azure_openai_util.py`)

- Single client used by all phases
- Detects `model_type: "reasoning"` in config and automatically strips `temperature` for GPT-o-series (o1, o3-mini) deployments — these models do not accept the `temperature` parameter
- Connection pool closed via `await llm_client.close()` in the `finally` block of `CertPipelineService`

### `ConfigLoader` (`load_config.py`)

- Loads `configs/configs.json`
- Resolves any value prefixed with `ENV_` from the process environment at load time
- Example: `"ENV_MONGODB_CONNECTION_STRING"` → `os.environ["MONGODB_CONNECTION_STRING"]`

### `MongoDBClient` (`mongodb_util.py`)

- Sync PyMongo client (used by Phase 1 which predates the async API layer)
- `insert_metrics()` — inserts combined quantitative + qualitative doc into `agent_run_metrics`
- Atlas Vector Search index creation for semantic similarity queries

---

## Configuration

### `configs/configs.json` (global)

```jsonc
{
  "mongodb": {
    "database":    "agentcert",
    "collections": {
      "metrics":      "agent_run_metrics",
      "quantitative": "llm_quantitative_extractions",
      "qualitative":  "llm_qualitative_extractions"
    },
    "vector_search": {
      "index_name": "metrics_vector_index",
      "dimensions": 1536,
      "similarity": "cosine"
    }
  },
  "extraction_model": { "model_type": "chat", ... },
  "reasoning_model":  { "model_type": "reasoning", ... },
  "embedding_model":  { ... }
}
```

### `main/config/settings.py` (API layer)

`Settings` is a frozen dataclass populated from environment variables at startup. All fields have defaults except `MONGODB_CONNECTION_STRING`, which is required (the server crashes fast on startup if absent).

| Setting | Env var | Default |
|---|---|---|
| MongoDB URI | `MONGODB_CONNECTION_STRING` | required |
| Database | `MONGODB_DATABASE` | `agentcert` |
| Task collection | `API_TASK_COLLECTION` | `pipeline_tasks` |
| Cert task collection | `CERT_TASK_COLLECTION` | `certification_tasks` |
| Cert metadata collection | `CERT_METADATA_COLLECTION` | `certification_metadata` |
| Agg category collection | `AGG_CATEGORY_COLLECTION` | `aggregated_category_metadata` |
| Workspace | `WORKSPACE_DIR` | `workspace/` |
| Cert workspace | `CERT_WORKSPACE_DIR` | `workspace/cert/` |
| Max concurrent Phase 0+1 | `API_MAX_CONCURRENT_TASKS` | `4` |
| Max concurrent Phase 2+3 | `API_MAX_CONCURRENT_CERT_TASKS` | `2` |

Per-module configs live in each module's `config/` subdirectory (JSON or YAML) and control batch sizes, model selection, and temperatures for that phase only.

---

## Data Flow — Files and MongoDB

```
                      Phase 0          Phase 1           Phase 2          Phase 3
                  ┌─────────────┐  ┌──────────────┐  ┌────────────┐  ┌─────────────┐
Trace JSON  ────► │ Fault       │─►│ Metrics      │─►│ Aggregation│─►│ Certification│
                  │ Bucketing   │  │ Extraction   │  │            │  │             │
                  └─────────────┘  └──────────────┘  └────────────┘  └─────────────┘
                       │                 │                 │                │
                  fault_buckets/   *_metrics.json    aggregation.json  certification.json
                  *.json                │
                               [if store=mongodb]
                               agent_run_metrics ──────────────────────────────────────
                                                                                       │
                  pipeline_tasks (task lifecycle) ─────────────────────────────────────┤ MongoDB
                  certification_tasks (task lifecycle) ──────────────────────────────── ┤
                  certification_metadata (1 per run) ─────────────────────────────────── ┤
                  aggregated_category_metadata (1 per category) ──────────────────────── ┘
```

See [docs/mongodb-storage.md](mongodb-storage.md) for full collection schemas and index definitions.

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Async job model (submit → poll) | Pipeline runs take minutes; synchronous HTTP would time out |
| Deterministic numeric aggregation (no LLM arithmetic) | Reproducibility; LLMs are unreliable for arithmetic |
| LLM Council (k judges + meta-judge) | Reduces variance in qualitative narrative generation |
| 5 concurrent narrative builders | Phase 3 has no inter-section dependencies except Recommendations → Limitations |
| `status` filter on every `update_one` | Prevents double-advance races on concurrent writes |
| `asyncio.Semaphore` per pipeline type | Prevents OOM from too many simultaneous heavy LLM pipeline runs |
| `ENV_` prefix convention in config | Keeps secrets out of JSON files; resolved once at load time |
| Pydantic schema validation on Phase 3 output | Fail-fast on malformed reports rather than silently emitting invalid JSON |
| `secret_key` stripped before MongoDB persistence | Langfuse credentials never stored at rest in task documents |
