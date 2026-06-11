# MongoDB Storage — AgentCert API

## Database

| Setting | Default | Env var |
|---|---|---|
| Database name | `agentcert` | `MONGODB_DATABASE` |
| Connection | — | `MONGODB_CONNECTION_STRING` (required) |

The connection is managed by **Motor** (async driver). The client is created once in the FastAPI `lifespan` handler ([main/main.py](../main/main.py)) and closed on shutdown. All five collections and their indexes are created idempotently on every startup — restarting the server is safe.

---

## Collections at a Glance

| Collection | Env var to override | Writes per API call | Purpose |
|---|---|---|---|
| `pipeline_tasks` | `API_TASK_COLLECTION` | 4–5 updates | Bucketing/extraction task lifecycle |
| `certification_tasks` | `CERT_TASK_COLLECTION` | 4–5 updates | Aggregation/certification task lifecycle |
| `agent_run_metrics` | *(set in configs.json)* | 1 insert per fault | Per-fault extracted metrics + embeddings |
| `certification_metadata` | `CERT_METADATA_COLLECTION` | 1 insert | Summary of a completed certification run |
| `aggregated_category_metadata` | `AGG_CATEGORY_COLLECTION` | 1 insert per fault category | Per-category scorecard rows |

---

## Collection Schemas

### `pipeline_tasks`

One document per `POST /api/v1/bucketing-extraction` request. Managed by `SessionService` ([main/services/session_service.py](../main/services/session_service.py)).

```jsonc
{
  "task_id": "<uuid>",              // unique, indexed
  "agent_id": "string",
  "experiment_id": "string",
  "run_id": "string",
  "status": "PENDING | RUNNING | COMPLETED | FAILED",
  "stage": "pending | acquiring_trace | running_pipeline | done",
  "created_at": "<ISODate>",
  "updated_at": "<ISODate>",
  "started_at": "<ISODate> | null",
  "completed_at": "<ISODate> | null",
  "request": { /* full request body snapshot */ },
  "result": { /* pipeline output — set on COMPLETED */ } | null,
  "error": {
    "error_code": "string",
    "message": "string",
    "failed_stage": "string",
    "detail": "string"
  } | null
}
```

**Indexes:**

| Name | Keys | Options |
|---|---|---|
| `idx_task_id_unique` | `task_id` | unique |
| `idx_agent_exp_run` | `(agent_id, experiment_id, run_id)` | — |
| `idx_status_created` | `(status ASC, created_at DESC)` | — |
| `idx_created_at` | `created_at` | — |

---

### `certification_tasks`

One document per `POST /api/v1/aggregation-certification` request. Managed by `CertSessionService` ([main/services/session_service.py](../main/services/session_service.py)).

```jsonc
{
  "cert_task_id": "<uuid>",         // unique, indexed
  "agent_id": "string",
  "agent_name": "string",
  "experiment_id": "string",
  "certification_run_id": "string", // e.g. git SHA, optional
  "status": "PENDING | RUNNING | COMPLETED | FAILED",
  "stage": "pending | fetching_metrics | running_pipeline | storing_metadata | done",
  "created_at": "<ISODate>",
  "updated_at": "<ISODate>",
  "started_at": "<ISODate> | null",
  "completed_at": "<ISODate> | null",
  "request": { /* full request body snapshot */ },
  "result": {
    "total_documents": 0,
    "total_fault_categories": 0,
    "fault_categories": ["string"],
    "certification_id": "<uuid>",   // links to certification_metadata
    "storage_paths": {
      "aggregated_scorecard": "path/to/aggregation.json",
      "certification_report": "path/to/certification.json",
      "summary": "path/to/pipeline_summary.json"
    },
    "processing_time_seconds": 0.0
  } | null,
  "error": {
    "error_code": "string",
    "message": "string",
    "failed_stage": "string",
    "detail": "string"
  } | null
}
```

**Indexes:**

| Name | Keys | Options |
|---|---|---|
| `idx_cert_task_id_unique` | `cert_task_id` | unique |
| `idx_cert_agent_exp` | `(agent_id, experiment_id)` | — |
| `idx_cert_status_created` | `(status ASC, created_at DESC)` | — |
| `idx_cert_created_at` | `created_at` | — |

---

### `agent_run_metrics`

One document per fault extracted by the metrics extraction pipeline (Phase 1). Written by `MongoDBClient.insert_metrics()` ([utils/mongodb_util.py](../utils/mongodb_util.py)) only when the `--store` flag is passed to the pipeline or `store_to_mongodb=True` in the API request.

```jsonc
{
  "experiment_id": "string",        // unique + sparse index
  "run_id": "string",
  "agent_name": "string",
  "agent_id": "string",
  "fault_category": "string",       // e.g. "compute", "network"
  "fault_name": "string",           // e.g. "pod-cpu-hog"
  "quantitative": {
    "agent_name": "string",
    "agent_id": "string",
    "agent_version": "string",
    "experiment_id": "string",
    "run_id": "string",
    "fault_injection_time": "<ISO-8601>",
    "agent_fault_detection_time": "<ISO-8601>",
    "agent_fault_mitigation_time": "<ISO-8601>",
    "time_to_detect": 0.0,          // seconds
    "time_to_mitigate": 0.0,        // seconds
    "fault_detected": "Yes | No | Unknown",
    "trajectory_steps": 0,
    "input_tokens": 0,
    "output_tokens": 0,
    "injected_fault_name": "string",
    "injected_fault_category": "string",
    "detected_fault_type": "string",
    "fault_target_service": "string",
    "fault_namespace": "string",
    "tool_calls": [
      {
        "tool_name": "string",
        "arguments": {},
        "response_summary": "string",
        "was_successful": true,
        "timestamp": "<ISO-8601>"
      }
    ],
    "pii_detection": false,
    "number_of_pii_instances_detected": 0,
    "malicious_prompts_detected": 0,
    "tool_selection_accuracy": 0.0
  },
  "qualitative": {
    "rai_check_status": "Passed | Failed | Not Evaluated",
    "rai_check_notes": "string",
    "security_compliance_status": "Compliant | Non-Compliant | ...",
    "security_compliance_notes": "string",
    "reasoning_quality_score": 0.0, // 0–10
    "reasoning_quality_notes": "string",
    "agent_summary": "string",
    "hallucination_score": 0.0,
    "plan_adherence": "string",
    "collateral_damage": "string"
  },
  "embedding": [0.0],               // 1536-dim vector (optional)
  "metadata": {
    "trace_file": "string",
    "total_spans": 0,
    "extraction_token_usage": {
      "input_tokens": 0,
      "output_tokens": 0,
      "total_tokens": 0
    },
    "bucket_metadata": {
      "fault_id": "string",
      "fault_name": "string",
      "severity": "string",
      "injection_timestamp": "<ISO-8601>"
    }
  },
  "created_at": "<ISODate>"
}
```

**Indexes:**

| Name | Keys | Options |
|---|---|---|
| *(compound)* | `(fault_category, fault_name)` | — |
| *(unique sparse)* | `experiment_id` | unique, sparse |
| *(compound)* | `(fault_category ASC, created_at DESC)` | — |
| *(sparse)* | `agent_name` | sparse |
| *(sparse)* | `agent_id` | sparse |
| *(sparse)* | `run_id` | sparse |
| `metrics_vector_index` | `embedding` (Atlas Vector Search) | 1536 dims, cosine |

---

### `certification_metadata`

One document per successful certification run. Written by `_write_certification_metadata()` ([main/workers/cert_task_runner.py](../main/workers/cert_task_runner.py)).

```jsonc
{
  "certification_id": "<uuid>",     // unique; FK to aggregated_category_metadata
  "cert_task_id": "<uuid>",
  "agent_id": "string",
  "agent_name": "string",
  "experiment_id": "string",
  "certification_run_id": "string", // optional (e.g. git SHA)
  "status": "success",
  "created_at": "<ISODate>",
  "storage_paths": {
    "aggregated_scorecard": "absolute/path/aggregation.json",
    "certification_report": "absolute/path/certification.json",
    "summary": "absolute/path/pipeline_summary.json"
  },
  "summary": {
    "total_documents": 0,
    "total_fault_categories": 0,
    "fault_categories": ["string"]
  },
  "processing_time_seconds": 0.0,
  "error_message": null
}
```

**Indexes:**

| Name | Keys | Options |
|---|---|---|
| `idx_certmeta_id_unique` | `certification_id` | unique |
| `idx_certmeta_agent_exp` | `(agent_id, experiment_id)` | — |
| `idx_certmeta_agent_created` | `(agent_id ASC, created_at DESC)` | — |
| `idx_certmeta_run_id` | `certification_run_id` | sparse |

---

### `aggregated_category_metadata`

One document per fault category per certification. Written by `_write_aggregated_category_metadata()` ([main/workers/cert_task_runner.py](../main/workers/cert_task_runner.py)), fanned out from the `aggregation.json` scorecard.

```jsonc
{
  "fault_category": "string",       // e.g. "compute", "network", "storage"
  "certification_id": "<uuid>",     // FK to certification_metadata
  "agent_id": "string",
  "experiment_id": "string",
  "total_runs": 0,
  "faults_tested": ["string"],
  "numeric_metrics": {
    "time_to_detect":   { "mean": 0.0, "median": 0.0, "p95": 0.0 },
    "time_to_mitigate": { "mean": 0.0, "median": 0.0, "p95": 0.0 }
    // ...other aggregated stats
  },
  "derived_metrics": {
    "fault_detection_success_rate": 0.0,
    "fault_mitigation_success_rate": 0.0,
    "rai_compliance_rate": 0.0,
    "security_compliance_rate": 0.0
  },
  "created_at": "<ISODate>"
}
```

**Indexes:**

| Name | Keys | Options |
|---|---|---|
| `idx_aggcat_cert_fault_unique` | `(certification_id, fault_category)` | unique |
| `idx_aggcat_agent_exp` | `(agent_id, experiment_id)` | — |
| `idx_aggcat_created_at` | `created_at DESC` | — |

---

## Write Points Per API Call

### `POST /api/v1/bucketing-extraction`

```
Request arrives
  └─► SessionService.create_task()           → pipeline_tasks  (PENDING)
        └─► background worker starts
              └─► set_started()              → pipeline_tasks  (RUNNING / acquiring_trace)
                    └─► update_stage()       → pipeline_tasks  (running_pipeline)
                          │
                          ├─► [if store=true] insert_metrics() → agent_run_metrics (1 doc per fault)
                          │
                          └─► set_completed() / set_failed()  → pipeline_tasks  (COMPLETED | FAILED)
```

### `POST /api/v1/aggregation-certification`

```
Request arrives
  └─► CertSessionService.create_task()            → certification_tasks  (PENDING)
        └─► background worker starts
              └─► set_started()                   → certification_tasks  (RUNNING / fetching_metrics)
                    └─► update_stage()            → certification_tasks  (running_pipeline)
                          └─► pipeline executes
                                └─► update_stage()→ certification_tasks  (storing_metadata)
                                      ├─► _write_certification_metadata()
                                      │     → certification_metadata  (1 doc)
                                      ├─► _write_aggregated_category_metadata()
                                      │     → aggregated_category_metadata (1 doc per category)
                                      └─► set_completed() / set_failed()
                                            → certification_tasks  (COMPLETED | FAILED)
```

---

## State Machine

Both task services enforce the same state machine:

```
PENDING ──► RUNNING ──► COMPLETED
   │            │
   └────────────┴──► FAILED
```

Each transition uses a **filter on the current status** in `update_one`, so concurrent writes cannot double-advance a task. `set_completed` raises `ValueError` if the task is not `RUNNING` (double-write guard).

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MONGODB_CONNECTION_STRING` | *(required)* | MongoDB Atlas or self-hosted URI |
| `MONGODB_DATABASE` | `agentcert` | Database name |
| `API_TASK_COLLECTION` | `pipeline_tasks` | Bucketing/extraction task docs |
| `CERT_TASK_COLLECTION` | `certification_tasks` | Aggregation/certification task docs |
| `CERT_METADATA_COLLECTION` | `certification_metadata` | Per-run certification summary |
| `AGG_CATEGORY_COLLECTION` | `aggregated_category_metadata` | Per-category scorecard rows |
| `API_MAX_CONCURRENT_TASKS` | `4` | Max parallel bucketing/extraction runs |
| `API_MAX_CONCURRENT_CERT_TASKS` | `2` | Max parallel certification runs |
| `WORKSPACE_DIR` | `workspace/` | Root dir for bucketing/extraction output |
| `CERT_WORKSPACE_DIR` | `workspace/cert/` | Root dir for certification output |
