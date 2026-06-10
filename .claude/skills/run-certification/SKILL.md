---
name: run-certification
description: Run the full certifier pipeline (Phase 0+1+2+3) locally against a Langfuse trace using scripts/run_certification.py, then summarize the .tmp/ output tree. Use for the certifier inner dev loop without starting the FastAPI service.
---

# run-certification

Exercise the certifier pipeline end-to-end against one trace, off the API path.

## Prerequisites

- `.env` filled in with `LANGFUSE_*` and `AZURE_OPENAI_*` (the script reads them directly).
- Python deps installed. PDF rendering needs `reportlab` (`pip install --user reportlab`).

## Steps

1. **Run the pipeline.** Prefer the trace-ID form, which auto-resolves agent/experiment/run IDs:
   ```bash
   ./scripts/run_certification.py --trace-id <LANGFUSE_TRACE_UUID>
   ```
   Or pass IDs directly:
   ```bash
   ./scripts/run_certification.py \
     --agent-id <UUID> --experiment-id <UUID> --run-id <UUID> --agent-name vaya
   ```
2. **Useful flags:** `--skip-cert` (stop after Phase 0+1), `--no-pdf` (skip PDF render), `--runs-per-fault N` (Phase 2 significance), `--batch-size N` (LLM classification batch), `--workspace <dir>` (default `.tmp/`), `--debug` (retain Phase 3 intermediates).
3. **Summarize output.** Outputs land under `.tmp/{agent_id}/{experiment_id}/`. Report the key artifacts:
   - `fault-bucketing/{run_id}/metrics/*_metrics.json`
   - `aggregation/aggregation.json`
   - `cert-builder/certification.json` (final certificate)
   - `cert-builder/certification.pdf` (rendered report)

## Notes

- `.tmp/` is gitignored — safe to leave artifacts there.
- To re-render a PDF from an existing `certification.json`, use `scripts/render_certification_pdf.py`.
- To verify the *service* path instead of the script path, use the `pipeline-smoke-test` skill.
