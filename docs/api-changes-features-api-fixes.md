# API Changes — `features/api-fixes`

## Overview

This document records all changes made to the certifier API in this session.
The changes affect the `POST /api/v1/bucketing-extraction` endpoint and its
underlying Langfuse trace ingestion pipeline.

---

## 1. Langfuse Credentials Removed from Request Body

**File:** `main/models/bucket_requests.py`

### Before

`LangfuseTraceSource` required callers to pass credentials and query parameters
in every request:

```json
{
  "type": "langfuse",
  "base_url": "http://langfuse.example.com",
  "public_key": "pk-...",
  "secret_key": "sk-...",
  "from_timestamp": "2025-01-01T00:00:00Z",
  "page_size": 100,
  "max_pages": 20,
  "include_observations": true
}
```

### After

Credentials and timestamp-based querying are gone. The model now only accepts
optional pagination tuning knobs:

```json
{
  "type": "langfuse",
  "page_size": 50,
  "max_pages": 10,
  "include_observations": true
}
```

`experiment_id` and `run_id` (already present in the top-level request) are
used to identify traces — no duplication in the body.

**Removed fields:** `base_url`, `public_key`, `secret_key`, `from_timestamp`

---

## 2. Langfuse Credentials Moved to Environment Variables

**File:** `main/services/trace_service.py`, `.env.example`

Credentials are now read from environment variables at call time:

| Variable | Purpose |
|---|---|
| `LANGFUSE_HOST` | Langfuse instance URL |
| `LANGFUSE_PUBLIC_KEY` | Langfuse public API key |
| `LANGFUSE_SECRET_KEY` | Langfuse secret API key |

If any variable is missing or empty, the request fails immediately with a
`LANGFUSE_FETCH_ERROR` before any network call is made, listing the missing
variable names.

The `.env.example` comment was updated to clarify that these variables are
**required when `trace_source.type = "langfuse"`** — credentials are no longer
accepted in the request body.

---

## 3. Langfuse Trace Identification by experiment_id + run_id

**File:** `main/services/trace_service.py`

### Motivation

Previously traces were fetched by timestamp (`from_timestamp`), which returned
all traces after a given time regardless of which experiment or run they
belonged to.

### Approach

The pipeline emits two distinct types of Langfuse traces for the same
experiment run, each using different metadata key naming conventions:

| Source | experiment_id key | run_id key |
|---|---|---|
| Chaos/OTel spans | `experiment.id` | `experiment.run_id` |
| LiteLLM/Agent generations | `experiment_id` | `experiment_run_id` |

Both types are now fetched via two separate server-side Langfuse `filter` API
queries and merged by trace ID before observations are pulled.

### Filter Query 1 — Chaos / OTel spans

```json
[
  { "type": "stringObject", "column": "metadata", "key": "experiment.id",    "operator": "=", "value": "<experiment_id>" },
  { "type": "stringObject", "column": "metadata", "key": "experiment.run_id", "operator": "=", "value": "<run_id>" }
]
```

### Filter Query 2 — LiteLLM / Agent generations

```json
[
  { "type": "stringObject", "column": "metadata", "key": "experiment_id",     "operator": "=", "value": "<experiment_id>" },
  { "type": "stringObject", "column": "metadata", "key": "experiment_run_id", "operator": "=", "value": "<run_id>" }
]
```

Results from both queries are deduplicated by `trace.id` before observations
are fetched, so overlapping traces are never fetched twice.

### Removed helpers

`_parse_iso_to_utc` was removed (timestamp-based fetch no longer used).

---

## 4. `acquire_trace` Signature Extended

**File:** `main/services/trace_service.py`

`TraceService.acquire_trace` gained two new parameters used by the Langfuse
path:

```python
async def acquire_trace(
    self,
    trace_source,
    dest_dir: Path,
    experiment_id: str = "",   # new
    run_id: str = "",          # new
) -> Tuple[Path, int]:
```

The `file` source path is unaffected — both parameters are ignored when
`trace_source.type == "file"`.

---

## 5. `bucket_task_runner` Updated

**File:** `main/workers/bucket_task_runner.py`

The `acquire_trace` call now passes `experiment_id` and `run_id` from the
incoming request:

```python
trace_path, total_observations = await trace_svc.acquire_trace(
    request.trace_source,
    run_dir / "traces",
    experiment_id=request.experiment_id,
    run_id=request.run_id,
)
```

---

## 6. Secret Key Stripping Removed from Router

**File:** `main/routers/bucketing_extraction.py`

The block that stripped `secret_key` from the MongoDB request snapshot before
persisting was removed — `secret_key` no longer exists in the model, so
nothing sensitive is ever present in the request body.

The snapshot is now a straightforward:

```python
request_snapshot=body.model_dump()
```

---

## Request Payload — Before vs After

### Before

```json
{
  "agent_id": "my-agent",
  "experiment_id": "16347084-830e-48bb-8d7f-1fa010aa0fd6",
  "run_id": "cbc0a9e1-de84-4b8c-8c74-80503a7b0fb4",
  "trace_source": {
    "type": "langfuse",
    "base_url": "http://langfuse.example.com",
    "public_key": "pk-...",
    "secret_key": "sk-...",
    "from_timestamp": "2025-01-01T00:00:00Z",
    "page_size": 100,
    "max_pages": 20,
    "include_observations": true
  }
}
```

### After

```json
{
  "agent_id": "my-agent",
  "experiment_id": "16347084-830e-48bb-8d7f-1fa010aa0fd6",
  "run_id": "cbc0a9e1-de84-4b8c-8c74-80503a7b0fb4",
  "trace_source": {
    "type": "langfuse"
  }
}
```

Credentials come from `.env` / environment. `experiment_id` and `run_id` are
taken from the top-level request fields — no duplication needed.

---

## Files Changed

| File | Change |
|---|---|
| `main/models/bucket_requests.py` | Removed credential + timestamp fields from `LangfuseTraceSource` |
| `main/services/trace_service.py` | Credentials from env; dual metadata-key query; new `acquire_trace` params; removed `_parse_iso_to_utc` |
| `main/routers/bucketing_extraction.py` | Removed secret key stripping; simplified snapshot |
| `main/workers/bucket_task_runner.py` | Pass `experiment_id` and `run_id` to `acquire_trace` |
| `.env.example` | Updated Langfuse section comment |
