---
title: "Certifier Architecture"
parent: "Control Plane"
grand_parent: "Deep Dive"
nav_order: 8
---

# Architecture — AgentCert Certifier

## Overview

AgentCert is a **four-phase analytical pipeline** that consumes raw Langfuse traces from AI agents under Kubernetes fault injection and produces structured 12-section certification reports. The same pipeline logic is accessible via a **REST API** (async job model) and directly via **CLI commands**.

<div class="flow-pipeline">

  <div class="flow-data-node">Raw Langfuse Trace (JSON)</div>

  <div class="flow-arrow">
    <div class="flow-arrow-line"></div>
    <div class="flow-arrow-head"></div>
  </div>

  <div class="flow-phase-box">
    <span class="flow-phase-badge">Phase 0</span>
    <div>
      <div class="flow-phase-title">Fault Bucketing</div>
      <div class="flow-phase-desc">LLM classifies interleaved trace events into per-fault lifecycle buckets &middot; <code>fault_analyzer/</code></div>
    </div>
  </div>

  <div class="flow-arrow">
    <div class="flow-arrow-line"></div>
    <div class="flow-arrow-head"></div>
  </div>

  <div class="flow-phase-box">
    <span class="flow-phase-badge">Phase 1</span>
    <div>
      <div class="flow-phase-title">Metrics Extraction</div>
      <div class="flow-phase-desc">LLM extracts quantitative (TTD, TTR, tokens) and qualitative metrics per fault bucket &middot; <code>metrics_extractor/</code> &middot; writes <code>*_metrics.json</code> + optionally MongoDB</div>
    </div>
  </div>

  <div class="flow-arrow">
    <div class="flow-arrow-line"></div>
    <div class="flow-arrow-note">repeated N times, one per agent run</div>
    <div class="flow-arrow-line"></div>
    <div class="flow-arrow-head"></div>
  </div>

  <div class="flow-phase-box">
    <span class="flow-phase-badge">Phase 2</span>
    <div>
      <div class="flow-phase-title">Aggregation</div>
      <div class="flow-phase-desc">Pure-Python statistical aggregation per fault category + LLM Council narrative synthesis &middot; <code>aggregator/</code> &middot; writes <code>aggregation.json</code> (CertificationScorecard)</div>
    </div>
  </div>

  <div class="flow-arrow">
    <div class="flow-arrow-line"></div>
    <div class="flow-arrow-head"></div>
  </div>

  <div class="flow-phase-box">
    <span class="flow-phase-badge">Phase 3</span>
    <div>
      <div class="flow-phase-title">Certification</div>
      <div class="flow-phase-desc">Builds a validated 12-section CertificationReport with 5 concurrent LLM narrative builders &middot; <code>cert_builder/</code> &middot; writes <code>certification.json</code></div>
    </div>
  </div>

</div>

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

<div class="flow-pipeline">

  <div class="flow-input-node">POST /api/v1/bucketing-extraction</div>

  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header">
      <span class="flow-step-num">1</span>
      <span class="flow-step-title">Duplicate guard</span>
    </div>
    <div class="flow-step-body"><code>find_active_task(agent_id, experiment_id, run_id)</code> → <code>409 TASK_ALREADY_ACTIVE</code> if found</div>
  </div>

  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header">
      <span class="flow-step-num">2</span>
      <span class="flow-step-title">Create task</span>
    </div>
    <div class="flow-step-body"><code>create_task()</code> &rarr; <code>pipeline_tasks</code> (PENDING)</div>
  </div>

  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header">
      <span class="flow-step-num">3</span>
      <span class="flow-step-title">Accept — return immediately</span>
    </div>
    <div class="flow-step-body">Return <code>202 { task_id, poll_url }</code></div>
    <div class="flow-step-output">client polls GET /tasks/{task_id}</div>
  </div>

  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header">
      <span class="flow-step-num">4</span>
      <span class="flow-step-title">Background pipeline</span>
    </div>
    <div class="flow-step-body">
      <ul class="flow-phase-list">
        <li><code>set_started()</code> &rarr; pipeline_tasks (RUNNING / acquiring_trace)</li>
        <li><code>TraceService.acquire_trace()</code> — file copy or Langfuse API</li>
        <li><code>update_stage()</code> &rarr; pipeline_tasks (running_pipeline)</li>
        <li>[semaphore] <code>BucketPipelineService.execute_pipeline()</code>
          <ul>
            <li>Phase 0: FaultBucketingPipeline</li>
            <li>Phase 1: TraceMetricsExtractor &times; N faults</li>
            <li>if storage_config.type &isin; {mongodb, hybrid}: <code>MongoDBClient.insert_metrics()</code> &rarr; agent_run_metrics</li>
          </ul>
        </li>
        <li><code>set_completed()</code> / <code>set_failed()</code></li>
      </ul>
    </div>
    <div class="flow-step-output">pipeline_tasks &rarr; COMPLETED or FAILED</div>
  </div>

</div>

### Request flow — Phase 2+3

<div class="flow-pipeline">

  <div class="flow-input-node">POST /api/v1/aggregation-certification</div>

  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header">
      <span class="flow-step-num">1–3</span>
      <span class="flow-step-title">Validate &amp; pre-flight</span>
    </div>
    <div class="flow-step-body">
      <ul class="flow-phase-list">
        <li>Validate <code>storage_config.type == "local"</code></li>
        <li>Derive <code>metrics_dir</code> if not supplied</li>
        <li><code>_discover_and_validate()</code> — count <code>*metrics.json</code> for agent_id &rarr; <code>400 METRICS_NOT_FOUND</code> if none</li>
      </ul>
    </div>
  </div>

  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header">
      <span class="flow-step-num">4–5</span>
      <span class="flow-step-title">Duplicate guard &amp; create task</span>
    </div>
    <div class="flow-step-body">
      <code>find_active_task(agent_id, experiment_id)</code> &rarr; <code>409 TASK_ALREADY_ACTIVE</code> if found<br>
      <code>create_task()</code> &rarr; certification_tasks (PENDING)
    </div>
  </div>

  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header">
      <span class="flow-step-num">6</span>
      <span class="flow-step-title">Accept — return immediately</span>
    </div>
    <div class="flow-step-body">Return <code>202 { cert_task_id, poll_url }</code></div>
    <div class="flow-step-output">client polls GET /cert-tasks/{cert_task_id}</div>
  </div>

  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header">
      <span class="flow-step-num">7</span>
      <span class="flow-step-title">Background pipeline</span>
    </div>
    <div class="flow-step-body">
      <ul class="flow-phase-list">
        <li><code>set_started()</code> &rarr; certification_tasks (RUNNING / fetching_metrics)</li>
        <li><code>resolve_cert_output_dir()</code></li>
        <li>[semaphore] <code>CertPipelineService.execute_pipeline()</code>
          <ul>
            <li>Phase 2: AggregationOrchestrator</li>
            <li>Phase 3: CertificationPipeline (5 concurrent narrative builders)</li>
          </ul>
        </li>
        <li><code>update_stage()</code> &rarr; certification_tasks (storing_metadata)</li>
        <li><code>_write_certification_metadata()</code> &rarr; certification_metadata (1 doc)</li>
        <li><code>_write_aggregated_category_metadata()</code> &rarr; aggregated_category_metadata (N docs)</li>
        <li><code>set_completed()</code> / <code>set_failed()</code></li>
      </ul>
    </div>
    <div class="flow-step-output">certification_tasks &rarr; COMPLETED or FAILED</div>
  </div>

</div>

### Task state machine

<div style="display:flex;flex-direction:column;gap:.5rem;margin:1rem 0 1.2rem;">
  <div style="display:flex;align-items:center;gap:.6rem;flex-wrap:wrap;">
    <span style="background:#f1f5f9;border:1.5px solid #e2e8f0;border-radius:8px;padding:.35rem .9rem;font-family:monospace;font-size:.82rem;font-weight:600;color:#475569;">PENDING</span>
    <span style="color:#93c5fd;font-size:1.1rem;">&#10142;</span>
    <span style="background:#eff6ff;border:1.5px solid #bfdbfe;border-radius:8px;padding:.35rem .9rem;font-family:monospace;font-size:.82rem;font-weight:600;color:#1d4ed8;">RUNNING</span>
    <span style="color:#93c5fd;font-size:1.1rem;">&#10142;</span>
    <span style="background:#f0fdf4;border:1.5px solid #bbf7d0;border-radius:8px;padding:.35rem .9rem;font-family:monospace;font-size:.82rem;font-weight:600;color:#15803d;">COMPLETED</span>
  </div>
  <div style="display:flex;align-items:center;gap:.6rem;flex-wrap:wrap;">
    <span style="font-size:.78rem;color:#94a3b8;font-style:italic;">PENDING or RUNNING</span>
    <span style="color:#f87171;font-size:1.1rem;">&#10142;</span>
    <span style="background:#fef2f2;border:1.5px solid #fecaca;border-radius:8px;padding:.35rem .9rem;font-family:monospace;font-size:.82rem;font-weight:600;color:#dc2626;">FAILED</span>
  </div>
</div>

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

<div class="flow-pipeline">

  <div class="flow-data-node">Trace JSON</div>

  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header">
      <span class="flow-step-num">P0</span>
      <span class="flow-step-title">Fault Bucketing</span>
    </div>
    <div class="flow-step-body"><code>fault_analyzer/</code> — LLM classifies events into per-fault lifecycle buckets</div>
    <div class="flow-step-output">&#8594; fault_buckets/*.json</div>
  </div>

  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header">
      <span class="flow-step-num">P1</span>
      <span class="flow-step-title">Metrics Extraction</span>
    </div>
    <div class="flow-step-body"><code>metrics_extractor/</code> — quantitative + qualitative LLM extraction per fault</div>
    <div class="flow-step-output">&#8594; *_metrics.json &nbsp;&middot;&nbsp; [if store=mongodb] &#8594; agent_run_metrics</div>
  </div>

  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header">
      <span class="flow-step-num">P2</span>
      <span class="flow-step-title">Aggregation</span>
    </div>
    <div class="flow-step-body"><code>aggregator/</code> — deterministic stats per fault category + LLM Council narrative</div>
    <div class="flow-step-output">&#8594; aggregation.json &nbsp;&middot;&nbsp; &#8594; aggregated_category_metadata (MongoDB)</div>
  </div>

  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header">
      <span class="flow-step-num">P3</span>
      <span class="flow-step-title">Certification</span>
    </div>
    <div class="flow-step-body"><code>cert_builder/</code> — 5 concurrent narrative builders produce the 12-section report</div>
    <div class="flow-step-output">&#8594; certification.json &nbsp;&middot;&nbsp; &#8594; certification_metadata (MongoDB)</div>
  </div>

</div>

Task lifecycle collections written across all phases:

| Collection | Written by |
|---|---|
| `pipeline_tasks` | Phase 0+1 request handler — task state throughout |
| `certification_tasks` | Phase 2+3 request handler — task state throughout |
| `certification_metadata` | Phase 2+3 on completion — 1 doc per run |
| `aggregated_category_metadata` | Phase 2+3 on completion — 1 doc per fault category |

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
