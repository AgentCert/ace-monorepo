# agents/

This folder consolidates every agent evaluated during the ACE open-weight-model
certification effort.  It is split into two clearly separate layers:

---

## Original agents (do not modify)

These directories contain the upstream ITBench / AgentCert code verbatim.
Do **not** edit files inside them — they track their upstream repos.

| Directory | Type | Upstream |
|-----------|------|----------|
| `ciso-agent/` | git submodule | [itbench-hub/ITBench-CISO-CAA-Agent](https://github.com/itbench-hub/ITBench-CISO-CAA-Agent) · branch `main` |
| `sre-agent/` | git submodule | [itbench-hub/ITBench-CISO-SRE-FinOps-Agent](https://github.com/itbench-hub/ITBench-CISO-SRE-FinOps-Agent) · branch `main` |
| `flash-agent/` | plain copy | [AgentCert/flash-agent](https://github.com/AgentCert/flash-agent) · mirrors `../flash-agent/` submodule |

To advance a submodule to the latest upstream commit:

```bash
git submodule update --remote agents/ciso-agent   # or agents/sre-agent
git add agents/ciso-agent && git commit -m "chore(agents): bump ciso-agent to upstream HEAD"
```

---

## Running the benchmark (single command)

```bash
python scripts/ace-bench.py <agent-name>
```

Examples:

```bash
python scripts/ace-bench.py ciso-agent
python scripts/ace-bench.py sre-agent --resume
python scripts/ace-bench.py flash-agent --skip-setup --runs 5
```

All artefacts (scenario results, metrics docs, certification JSON + PDF) are
written to `.tmp/bench/<agent-name>/`.

Full flag reference:

| Flag | Effect |
|------|--------|
| `--output-dir DIR` | Override the output directory |
| `--runs N` | Limit the number of scenarios/runs (SRE and trace_based pipelines) |
| `--resume` | Continue a previous run — skip scenarios whose results already exist |
| `--skip-setup` | Do not re-run `setup.sh` (use when the venv is already built) |
| `--skip-scenarios` | Skip agent execution and use existing metrics docs |
| `--skip-certifier` | Run only the scenario phase; stop before PDF generation |

---

## ACE harness (`harness/`)

The `harness/` directory contains **ACE-developed wrappers** that make each
agent runnable inside the ITBench benchmarking framework without touching the
original agent code.

| Directory | Contents |
|-----------|----------|
| `harness/ciso-agent/` | `setup.sh` · `agent-harness.yaml` · `bench.yaml` |
| `harness/sre-agent/` | `setup.sh` · `agent-harness.yaml` · `bench.yaml` |
| `harness/flash-agent/` | `setup.sh` · `agent-harness.yaml` · `bench.yaml` |

See [`harness/README.md`](harness/README.md) for the `scenario_data.json`
schemas expected by each agent.

---

## Requirements for adding a new agent

To make a new agent benchmarkable via `ace-bench.py`, the following three
files must exist under `agents/harness/<agent-name>/`:

### 1. `setup.sh`

A shell script that installs the agent's runtime dependencies from scratch.
It is run once before the first benchmark run (skip with `--skip-setup`).

Typical content:

```bash
#!/usr/bin/env bash
set -euo pipefail
AGENT_DIR="$(cd "$(dirname "$0")/../../<agent-name>" && pwd)"
python3 -m venv "${AGENT_DIR}/.venv"
"${AGENT_DIR}/.venv/bin/pip" install -r "${AGENT_DIR}/requirements.txt"
```

Requirements:
- Must be idempotent (safe to run multiple times).
- Must not require network access if the package data is already cached.
- Must not install into the system Python or the certifier venv.

### 2. `agent-harness.yaml`

Defines the bash command that runs one agent invocation.

```yaml
path_to_data_provided_by_scenario: /tmp/agent/scenario_data.json
path_to_data_pushed_to_scenario:   /tmp/agent/agent_data.tar
run:
  command: ["/bin/bash"]
  args:
    - -c
    - |
      # ... bash script body ...
```

**Harness contract (must be respected):**

| What | Path |
|------|------|
| Input: scenario description | `/tmp/agent/scenario_data.json` |
| Output: all agent artefacts | `/tmp/agent/agent_data.tar` (tar of a staging directory) |

The harness script must:
1. Read `/tmp/agent/scenario_data.json` and extract whatever fields it needs.
2. Run the agent with a timeout (use `timeout <N>` or equivalent).
3. Tar all output artefacts to `/tmp/agent/agent_data.tar`.
4. Exit 0 on success; non-zero exits are recorded but do not abort the benchmark.

The script runs with environment variables injected from the `env_file` listed
in `bench.yaml`.  It should not depend on any externally set variables beyond
those.

### 3. `bench.yaml`

Pipeline configuration consumed by `scripts/ace-bench.py`.

#### Required top-level fields

```yaml
agent_id:    <string>   # short identifier used in certifier reports
agent_name:  <string>   # human-readable name
pipeline:    <string>   # "ciso" | "sre" | "trace_based"
```

#### Optional top-level fields

```yaml
env_file: <path>        # key=value file whose contents are injected into the harness env
                        # path is relative to the repo root or absolute
certifier:
  venv: <path>          # path to the certifier venv (default: .venv-certifier)
  runs_per_fault: <int> # passed to --runs-per-fault in the certifier (default: 5)
```

#### Pipeline-specific sections

**`pipeline: ciso`** — ITBench CISO compliance scenarios (Docker-based lifecycle)

```yaml
ciso:
  scenario_image: <docker-image>      # image that exposes make inject_fault / evaluate / revert / get
  scenarios_repo: <path>              # path to the ITBench-Scenarios/ciso checkout
  kubeconfig:     <path>              # kubeconfig for the target cluster
  plan:
    - dir:  <scenario-dir-name>       # directory name inside scenarios_repo
      type: <human-label>             # used in certifier report
      runs: <int>                     # independent runs for pass-rate estimation
```

Prerequisites:
- Docker must be installed; `sudo docker run` must work.
- A Kubernetes cluster reachable from the kubeconfig.
- The scenario Docker image must be built: `make -C .tmp/ciso-agent-trial/repos/ITBench-Scenarios/ciso build`.

**`pipeline: sre`** — ITBench SRE incident-diagnosis (offline snapshot evaluation)

```yaml
sre:
  snapshots_dir:           <path>    # directory of ITBench-Lite snapshot subdirs (Scenario-N/)
  model:                   <string>  # LiteLLM model string, e.g. "openai/qwen2.5-7b-instruct"
  prompt_file:             <string>  # prompt filename (relative to zero/zero-config/prompts/)
  goal_template:           <string>  # goal text injected into scenario_data.json
  per_scenario_timeout_s:  <int>     # default 1200
```

Prerequisites:
- ITBench-Lite snapshots downloaded:
  ```bash
  cd agents/sre-agent
  huggingface-cli download --repo-type dataset itbench-org/ITBench-Lite --local-dir ITBench-Lite
  ```
- `uv` installed (`pip install uv`).

**`pipeline: trace_based`** — LitmusChaos fault injection + Langfuse trace collection

```yaml
trace_based:
  engines_dir:       <path>    # directory of engine-<fault>.yaml (+ optional rbac-<fault>.yaml)
  langfuse_base_url: <url>     # checked for connectivity before running (default: http://127.0.0.1:4001)
  mcp_urls:          <string>  # comma-separated MCP endpoint URLs
  scan_query:        <string>  # passed to the agent as scan_query
  agent_timeout_s:   <int>     # default 600
```

Prerequisites:
- Running k3s/k8s cluster with LitmusChaos CRDs installed.
- Langfuse service running and reachable at `langfuse_base_url`.
- ChaosEngine YAML files in `engines_dir`.
- `kubectl` on PATH and pointing at the target cluster.

---

## Certifier venv

The certifier pipeline runs inside a dedicated Python venv.
Create it once:

```bash
python3 -m venv .venv-certifier
.venv-certifier/bin/pip install -r certifier/requirements.txt
```

The venv path can be overridden per-agent in `bench.yaml` under `certifier.venv`.
