# ITBench Evaluations

Toolkit for running **LLM-as-a-Judge** evaluations on ITBench root-cause analysis (RCA) agent outputs. The CLI loads ground-truth scenarios, reads agent trial outputs, repairs malformed JSON when possible, scores multiple metrics with a judge model, and aggregates macro statistics.

---

## Repository layout

| Path | Description |
| --- | --- |
| `itbench_evaluations/__main__.py` | CLI entrypoint (`python -m itbench_evaluations`). |
| `itbench_evaluations/agent.py` | Judge workflow and evaluation logic |
| `itbench_evaluations/client.py` | OpenAI-compatible judge client and model selection. |
| `itbench_evaluations/loader.py` | Ground-truth and agent output loading.|
| `itbench_evaluations/aggregator.py` | Computes per-incident and overall statistics. |
| `itbench_evaluations/json_fixer.py` | JSON repair utilities for malformed model outputs. |
| `itbench_evaluations/namespace_filter.py` | Optional post-processing helpers for filtering and recalculating metrics. |
| `itbench_evaluations/prompts/` | System prompts and per-metric templates. |
| `itbench_evaluations/data/` | Example incident output hierarchy. |
| `.env.tmpl` | Environment configuration template (copy to `.env`). |
| `pyproject.toml` | Python package configuration and dependencies. |

---

## Quick start

1. **Install prerequisites**
   ```bash
   uv sync

   # Install huggingface_hub for downloading datasets
   uv pip install huggingface_hub
   ```

2. **Configure environment variables**
   ```bash
   cp .env.tmpl .env
   # Edit .env with your actual values
   ```

   The judge client reads `.env` via `python-dotenv`. Required variables:

   | Purpose | Keys |
   | --- | --- |
   | Judge API | `JUDGE_API_KEY` (defaults to `"dummy"` for local endpoints) |
   | Judge model | `JUDGE_MODEL` (defaults to `gpt-4-turbo`) |
   | Optional base URL | `JUDGE_BASE_URL` (OpenAI-compatible endpoint) |

3. **Download ITBench-Lite dataset**

   Download benchmark scenarios from Hugging Face (https://huggingface.co/datasets/ibm-research/ITBench-Lite):

   ```bash
   # Download all scenarios (50 total: 35 SRE + 15 FinOps)
   uv run hf download \
     ibm-research/ITBench-Lite \
     --repo-type dataset \
     --local-dir ./ITBench-Lite

   # Or download only specific scenarios (faster for testing)
   uv run hf download \
     ibm-research/ITBench-Lite \
     --repo-type dataset \
     --include "snapshots/sre/v0.2-*/Scenario-1/*" \
     --include "snapshots/sre/v0.2-*/Scenario-2/*" \
     --local-dir ./ITBench-Lite
   ```

4. **Prepare data**
   **Ground truth** supports:
   - A single JSON/YAML file with one incident (must include `id` or the filename is used).
   - A JSON/YAML list of incidents (each must include `id`).
   - A directory of scenario subfolders containing `ground_truth.yaml|yml|json` (or `gt.yaml|json`).
   - A consolidated `ground_truths.json` inside a directory.

   **Agent outputs** should be structured as:
   ```
   agent-outputs/
     <incident_id>/
       <trial_number>/
         outputs/agent_output.json
         # or outputs/agent_response.json
         # or agent_output.json / agent_response.json
   ```
   Supported incident folder naming is case-insensitive and accepts patterns like
   `scenario-i<id>`, `scenario_<id>`, `scenario-<id>`, `scenario<id>`, and `incident-<id>`.

---

## Running evaluations

```bash
uv run itbench-evaluations \
  --ground-truth path/to/ground_truths.json \
  --outputs path/to/agent-outputs \
  --eval-criteria ROOT_CAUSE_ENTITY ROOT_CAUSE_REASONING
```

Key options:
- `--result-file` sets the output file (default: `evaluation_results.json`).
- `--eval-criteria` accepts: `ROOT_CAUSE_ENTITY`, `ROOT_CAUSE_REASONING`, `PROPAGATION_CHAIN`,
  `FAULT_LOCALIZATION`, `ROOT_CAUSE_REASONING_PARTIAL`, `ROOT_CAUSE_PROXIMITY`,
  `ROOT_CAUSE_PROXIMITY_FP`.
- `--k` is kept for backward compatibility (entity@k metrics are derived from `ROOT_CAUSE_ENTITY`).
- `--max-concurrent` controls evaluation concurrency (default: 5).
- `--verbose` enables debug logging.

---

## Outputs

The CLI writes a JSON report containing raw results and aggregated statistics:
```json
{
  "raw_results": [
    {"incident_id": "1", "trial_id": 0, "scores": { "...": "..." }}
  ],
  "statistics": {
    "per_incident": { "...": "..." },
    "overall": { "...": "..." }
  },
  "config": {
    "ground_truth_path": "...",
    "outputs_path": "...",
    "eval_criteria": ["..."],
    "k": 3
  }
}
```

## Metrics covered

`aggregator.py` computes macro-level mean, stderr, and pass@1 (for categorical metrics) for the following:

- `root_cause_entity` (precision/recall/F1 + pass@1): Whether the correct root cause entity was identified
- `root_cause_entity_k` (precision/recall/F1 + pass@1, configurable `k`): Whether the correct root cause entity was identified in the first k=(1,..,5) model predictions
- `root_cause_reasoning`: Whether the reasoning for the root cause was correct (0, 0.5 or 1).
- `propagation_chain`: Scores the full propagation chain
- `fault_localization_component_identification`: Checks if the model correctly identified the first semantic component to exhibit a significant failure symptom
- `root_cause_reasoning_partial`: Awards partial credit for reasoning if the model correctly analyzed a downstream symptom when it missed the root cause entity.
- `root_cause_proximity` (precision/recall/F1): Compute closeness between model root cause entities and the Ground-Truth (GT) root-cause entities based on distance (number of hops) between the model entity’s component and any GT root-cause component
- `root_cause_proximity_with_fp` (precision/recall/F1): Similar to root_cause_proximity_no_fp but distance is relative to the GT path length
