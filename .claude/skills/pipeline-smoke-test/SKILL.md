---
name: pipeline-smoke-test
description: Run the documented certifier end-to-end smoke test against the running FastAPI service (bucketing-extraction → poll → aggregation-certification → poll). Use to verify the certifier API path works before opening a PR.
---

# pipeline-smoke-test

Verify the certifier *service* (not the dev script) end-to-end.

## Prerequisites

- Certifier API running: `./scripts/start-local-services.sh --only-certifier`, reachable at http://localhost:8000/docs.
- A real Langfuse run to certify (`agent_id`, `experiment_id`, `experiment_run_id`).

## Steps

```bash
AGENT="<agent_id>"; EXP="<experiment_id>"; RID="<experiment_run_id>"

# Phase 0+1 — fault bucketing + metrics extraction
curl -s -X POST -H "Content-Type: application/json" -d "$(cat <<EOF
{"agent_id":"${AGENT}","experiment_id":"${EXP}","run_id":"${RID}",
 "trace_source":{"type":"langfuse"},"storage_config":{"type":"local"}}
EOF
)" http://localhost:8000/api/v1/bucketing-extraction

# Poll until the task completes
curl -s "http://localhost:8000/api/v1/tasks?experiment_id=${EXP}&experiment_run_id=${RID}"

# Phase 2+3 — aggregation + certification report
curl -s -X POST -H "Content-Type: application/json" -d "$(cat <<EOF
{"agent_id":"${AGENT}","agent_name":"vaya","experiment_id":"${EXP}",
 "runs_per_fault":5,"storage_config":{"type":"local"}}
EOF
)" http://localhost:8000/api/v1/aggregation-certification

# Poll the certification task
curl -s "http://localhost:8000/api/v1/cert-tasks?experiment_id=${EXP}"
```

## What to check

- Phase 0+1 returns a `task_id`; the `/tasks` poll eventually reports success.
- Phase 2+3 returns a `cert_task_id`; the `/cert-tasks` poll yields a finished certification.
- Outputs appear under `certifier/workspace/{agent_id}/{experiment_id}/` including the `certification/cert-*.html` and `cert-*.pdf`.
- Wall-clock is ~10 min for one run — poll, don't assume failure early.

Report PASS/FAIL with the failing phase and the relevant task status payload.
