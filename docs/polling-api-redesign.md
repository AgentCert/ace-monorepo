# Polling API Redesign — Semantic Query Parameters

## Problem

The original polling endpoints used opaque UUIDs as path parameters:

```
GET /api/v1/tasks/{task_id}
GET /api/v1/cert-tasks/{cert_task_id}
```

Callers had to store the UUID returned from the submission response and pass it back on every poll. This is brittle: if the caller loses the UUID (e.g. process restart, log truncation), there is no way to recover task status without querying MongoDB directly.

Both submission requests already carry `experiment_id` and `run_id` — human-meaningful identifiers that callers always know. The `(experiment_id, run_id)` pair is unique per agent run and already indexed in MongoDB. There is no reason the polling API cannot use these directly.

---

## Solution

Replace both UUID-path polling endpoints with query-parameter endpoints. Callers supply the same identifiers they used at submission time.

### Bucketing-Extraction polling

```
# Before
GET /api/v1/tasks/{task_id}

# After
GET /api/v1/tasks?experiment_id=<id>&experiment_run_id=<id>
```

### Aggregation-Certification polling

```
# Before
GET /api/v1/cert-tasks/{cert_task_id}

# After
GET /api/v1/cert-tasks?experiment_id=<id>
```

Cert polling needs only `experiment_id` because certification is per-experiment (aggregates all runs); there is no `run_id` concept at that level.

---

## Parameter naming

| API query param    | DB field        | Notes                                         |
|--------------------|-----------------|-----------------------------------------------|
| `experiment_id`    | `experiment_id` | UUID, globally unique — no `agent_id` needed  |
| `experiment_run_id`| `run_id`        | Renamed in the API layer for clarity; no DB migration |

`agent_id` is dropped from the query interface. Since `experiment_id` is a UUID it is globally unique; `agent_id` provides no additional disambiguation.

---

## Lookup semantics

Both new endpoints return the **most recent task** (sorted `created_at DESC`) matching the supplied key. This means:

- If a run was attempted, failed, and retried, the poll returns the latest attempt.
- Historical tasks for the same run are not lost — they remain in MongoDB and can be retrieved via direct DB query if needed.

---

## poll_url update

The `poll_url` field in both accepted responses now returns the semantic URL so callers can follow it directly without constructing parameters themselves:

```jsonc
// Bucketing-Extraction 202 response
{
  "status":   "accepted",
  "task_id":  "550e8400-...",   // still returned for reference
  "poll_url": "/api/v1/tasks?experiment_id=606f617e-...&experiment_run_id=0268f649-..."
}

// Aggregation-Certification 202 response
{
  "status":       "accepted",
  "cert_task_id": "7c4a8d64-...",   // still returned for reference
  "poll_url":     "/api/v1/cert-tasks?experiment_id=606f617e-..."
}
```

`task_id` / `cert_task_id` remain in the response body for reference (e.g. for direct MongoDB lookup or logging) but are no longer needed for polling.

---

## Service layer changes

Two new read methods added to `session_service.py`:

```python
# SessionService
async def get_task_by_run(self, experiment_id: str, run_id: str) -> Optional[dict]
# Returns most-recent pipeline_tasks document for (experiment_id, run_id)

# CertSessionService  
async def get_task_by_experiment(self, experiment_id: str) -> Optional[dict]
# Returns most-recent certification_tasks document for experiment_id
```

Both use `find_one` with `sort=[("created_at", -1)]`. No new indexes are required — `(agent_id, experiment_id, run_id)` already covers the bucketing query and `(agent_id, experiment_id)` covers cert. Since `experiment_id` is globally unique (UUID), the agent_id prefix in the index is still traversed and the query is efficient.

---

## What does NOT change

- POST submission endpoints and request bodies are unchanged.
- MongoDB document schema is unchanged (`run_id` field name stays).
- All status/stage fields and response shapes are unchanged.
- Duplicate-submission guard (`find_active_task`) is unchanged.
- `task_id` / `cert_task_id` UUIDs are still generated, stored, and returned in the 202 response.

---

## Migration impact

Breaking change on the two GET endpoints. Any client currently polling via UUID path must switch to query params. The `poll_url` in the 202 response is updated, so clients that follow `poll_url` directly will automatically use the new form.
