# Benchmarking prerequisites

This document lists everything that must be in place **before** running
`python scripts/ace-bench.py <agent-name>`.

Items are grouped into three sections:

1. [Always required](#1-always-required) — needed regardless of pipeline
2. [Per-agent Docker images](#2-per-agent-docker-images) — one image per agent
3. [Pipeline-specific](#3-pipeline-specific) — extra setup depending on `pipeline:` in `bench.yaml`

---

## 1. Always required

### Certifier venv

```bash
python3 -m venv .venv-certifier
.venv-certifier/bin/pip install -r certifier/requirements.txt
```

### Submodules

```bash
git submodule update --init --recursive
```

### Ollama + model

All pipelines in this repo route LLM calls through a LiteLLM proxy that
points at a local Ollama instance. The model must be pulled before the proxy
can serve it:

```bash
ollama pull qwen2.5:7b-instruct
```

The proxy is configured in `agentcert-stack/litellm-setup/litellm_config.yaml`
and listens on `:14000` by default.

---

## 2. Per-agent Docker images

Each `setup.sh` builds the agent's Docker image. Run it once before the first
benchmark (or re-run to rebuild after code changes). `ace-bench.py` calls it
automatically on first run unless `--skip-setup` is passed.

| Agent | Command |
|-------|---------|
| `sre-agent-crewai` | `bash agents/harness/sre-agent-crewai/setup.sh` |
| `ciso-agent` | `bash agents/harness/ciso-agent/setup.sh` |
| `sre-agent` | `bash agents/harness/sre-agent/setup.sh` (requires `uv`) |
| `flash-agent` | `bash agents/harness/flash-agent/setup.sh` |

Resulting local image tags:

| Agent | Image tag |
|-------|-----------|
| `sre-agent-crewai` | `ace-harness/sre-agent-crewai:local` |
| `ciso-agent` | `ace-harness/ciso-agent:local` |
| `sre-agent` | `ace-harness/sre-agent:local` |
| `flash-agent` | `ace-harness/flash-agent:local` |

`uv` (required by `sre-agent`):

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

---

## 3. Pipeline-specific

### `pipeline: itbench_sre` — live chaos injection (sre-agent-crewai)

This is the primary pipeline used for open-weight model certification.
It runs real LitmusChaos faults against a live cluster and calls the agent
via online MCP tools.

**Infrastructure checklist:**

| What | Why |
|------|-----|
| k3s / kind cluster running with LitmusChaos CRDs installed | Faults are applied via `kubectl apply` |
| `otel-demo` (or equivalent) deployed in-cluster | Gives the agent something to diagnose |
| `kubernetes-mcp-server` reachable at `:18081` | Agent's Kubernetes tool endpoint |
| `prometheus-mcp-server` reachable at `:31085` | Agent's Prometheus tool endpoint |
| LiteLLM proxy running at `:14000` | Routes LLM calls to Ollama |
| Langfuse running at `:4001` (optional) | Observability only; not required for scoring |

**Engine + RBAC YAMLs** (`engines_dir` in `bench.yaml`, default `.tmp/mass-execution/`):

For every fault scenario `<fault-name>` the pipeline requires:

```
.tmp/mass-execution/
  engine-<fault-name>.yaml    # ChaosEngine manifest
  rbac-<fault-name>.yaml      # (optional) RBAC for the experiment SA
```

These are pre-generated for all `chaos-charts/faults/itbench` and
`chaos-charts/faults/kubernetes` scenarios. For new faults, generate them
with the same naming convention and place them in `engines_dir`.

**Run:**

```bash
python scripts/ace-bench.py sre-agent-crewai
```

---

### `pipeline: ciso` — ITBench CISO compliance (ciso-agent)

**Infrastructure checklist:**

| What | Command / location |
|------|--------------------|
| Kubernetes cluster (kubeconfig) | Path set in `bench.yaml` under `ciso.kubeconfig` |
| ITBench-Scenarios repo cloned | `git clone https://github.com/IBM/ITBench-Scenarios .tmp/ciso-agent-trial/repos/ITBench-Scenarios` |
| CISO scenario Docker image built | `make -C .tmp/ciso-agent-trial/repos/ITBench-Scenarios/ciso build` |

The resulting scenario image tag is `ciso-task-scenarios:latest`.

**Run:**

```bash
python scripts/ace-bench.py ciso-agent
```

---

### `pipeline: sre` — offline snapshot evaluation (sre-agent / Zero)

**Additional CLI download:**

```bash
cd agents/sre-agent
huggingface-cli download \
  --repo-type dataset itbench-org/ITBench-Lite \
  --local-dir ITBench-Lite
```

`huggingface-cli` is installed via:

```bash
pip install huggingface_hub
```

**Run:**

```bash
python scripts/ace-bench.py sre-agent
```

---

### `pipeline: trace_based` — flash-agent with Langfuse trace collection

| What | Requirement |
|------|-------------|
| Langfuse running | Reachable at `trace_based.langfuse_base_url` (default `:4001`) |
| ChaosEngine YAMLs | In `trace_based.engines_dir` |
| MCP endpoints | Comma-separated list in `trace_based.mcp_urls` |
| `kubectl` on PATH | Pointing at the target cluster |

**Run:**

```bash
python scripts/ace-bench.py flash-agent
```

---

## What `agents/README.md` documents vs. what it omits

`agents/README.md` covers the `ciso`, `sre`, and `trace_based` pipelines
(prerequisites, `bench.yaml` schema). It does **not** document the
`itbench_sre` pipeline, which is the pipeline actually used for live
open-weight model certification with `sre-agent-crewai`. This file fills
that gap.
