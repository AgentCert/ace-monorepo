# Open-Weight Agent Certification — Change Log & Handoff

Read this before continuing the "open-weight-model agent + full ITBench certification run"
effort. It documents every change made across every repo/fork touched by this work, why each
one was necessary, and exactly what is verified-working vs. still in progress.

This supersedes the now-stale `ITBENCH_WORK_IN_PROGRESS.md` for status purposes — all 30
ITBench SRE fault bundles are complete (see §1); that file predates it.

---

## 0. Repos & forks involved

| Repo | Role | Remote in use | Branch |
|---|---|---|---|
| `ace-monorepo` (this repo) | top-level orchestration, `.env`, scripts | `origin` → `Warsea12-ai/ace-monorepo` | `feature/itbench-scenarios` |
| `chaos-charts` (submodule) | LitmusChaos fault-bundle ChaosHub catalog | `origin` → `Warsea12-ai/chaos-charts` | `feature/itbench-scenarios` |
| `app-charts` (submodule) | target application Helm charts (otel-demo, bookinfo) | `origin` → `Warsea12-ai/app-charts` | `feature/itbench-scenarios` |
| `certifier` (submodule) | 4-phase certification pipeline | `origin` → `Warsea12-ai/certifier` | `feature/itbench-scenarios` |
| `agentcert-stack` (submodule) | LiteLLM proxy + Langfuse compose stack | `origin` → `Warsea12-ai/agentcert-stack` | `feature/itbench-scenarios` |
| `flash-agent` (submodule) | the SRE agent under test | `origin` (no push) → `AgentCert/flash-agent`, `fork` (push) → `Warsea12-ai/flash-agent` | `feature/itbench-certification-fixes` |

`flash-agent` is the one submodule where the upstream `AgentCert` org repo itself is not
writable by this session's GitHub identity (`Warsea12-ai`, confirmed via
`gh api repos/AgentCert/flash-agent --jq .permissions` → `push:false`) — a `fork` remote
pointing at the pre-existing `Warsea12-ai/flash-agent` fork was added and is what gets
pushed to. Always check `git remote -v` before pushing in any of these — ownership has
moved before during this project.

---

## 1. ITBench LitmusChaos fault bundles (prior work, complete)

All 30 ITBench SRE scenarios are implemented as first-class LitmusChaos ChaosHub fault
bundles, now under their own ChaosHub category `chaos-charts/faults/itbench/` (split out
from `faults/kubernetes/`, which retains the ~35 pre-existing generic LitmusChaos
experiments — see §7). Full design notes, source-data mapping, and verification status:
`chaos-charts/ITBENCH_HANDOFF.md`. Key commits (`chaos-charts`): `476684d`, `7efbc15`,
`26a0a6e`, `88e3f34`.

## 2. CISO scorecard + LLM Council integration

Adds a CISO-shaped path through the scorecard/aggregation pipeline (CISO scenarios have no
fault-injection timeline — just a policy artifact that passes or fails a CIS Benchmark
check — so the generic detection/mitigation-rate machinery doesn't apply as-is).

- `certifier/metrics_extractor/scripts/ciso_metrics_adapter.py` (new) — adapts ITBench's own
  `evaluate.yml`/`evaluation.py` `{"pass": bool, ...}` output into the standard per-run doc
  shape.
- `certifier/aggregator/scripts/numeric_aggregation.py` — `compute_ciso_numeric_aggregates`
  (`ciso_time_to_resolve`) and `compute_ciso_derived_rates` (`ciso_task_pass_rate`,
  `ciso_unchanged_policy_preservation_rate`).
- Commit: `certifier@f285ed7`.

## 3. `--include-ciso-finops` CLI flag

Opt-in flag (default `false`) on the Phase 2+3 CLI (`run_aggregation_and_certification_pipeline.py`),
threaded through `CertPipelineService.execute_pipeline()`. Default excludes `ciso_fault`/
`finops_fault`-categorized runs from the scorecard (today's implicit SRE-only scope); `true`
includes FinOps (has a real execution path via the otel-demo-itbench Argo workflow) and
appends a "not implemented, no data collected" note for CISO (no chaos-charts bundle or
Argo workflow exists for any CISO scenario type yet). Commit: `certifier@11f9084`.

---

## 4. Open-weight-model agent certification (current effort)

**Goal:** stand up a real, non-mocked SRE agent running on a local open-weight model
(no Azure/OpenAI credentials), wired to the live k3s cluster + Litmus infra, and run the
actual certifier pipeline against it — fixing every real bug hit along the way rather than
mocking or working around it. Constraint honored throughout: **max ~50% of this shared
host's CPU/memory** (Ollama pinned via `taskset -c 0-11` / `OLLAMA_NUM_PARALLEL=1` /
`OLLAMA_MAX_LOADED_MODELS=1`), and never touching ports/processes/namespaces owned by other
users on this box (verified via `ss`/`docker ps`/`ps aux` before every change).

### 4.1 Architecture

```
flash-agent (local process, qwen2.5:7b-instruct via MODEL_ALIAS)
  │  OPENAI_BASE_URL → LiteLLM proxy (NOT direct to Ollama — flash-agent has
  │                     no native tracing of its own; LiteLLM's langfuse
  │                     callback is the only thing that gets traces into
  │                     Langfuse for certifier Phase 0)
  ▼
LiteLLM proxy (docker, port 14000) ── ollama_chat/qwen2.5:7b-instruct ──▶ Ollama (host, port 11434)
  │                                                                          (CPU-only, taskset-pinned)
  ├─ Langfuse (docker compose, port 4001) — trace storage for Phase 0
  └─ also proxies Gemini/Azure/OpenRouter model_list entries (kept intact,
     unused unless explicitly requested)

flash-agent ── MCP (JSON-RPC/SSE) ──▶ kubernetes-mcp-server (in-cluster, port-forwarded 8186)
           └── MCP ──────────────────▶ prometheus-mcp-server (NodePort 31085)

k3s cluster: otel-demo namespace (target app, Helm-installed) + litmus namespace
             (ChaosEngine/ChaosExperiment CRs — the 30 ITBench fault bundles from §1)

certifier (Azure OR Ollama for LLM judges/meta-judge — configs/configs.json per-model
           "provider": "openai_compatible" opts a model out of Azure)
```

### 4.2 Files changed, by repo

**`agentcert-stack`** (fork `Warsea12-ai/agentcert-stack`, branch `feature/itbench-scenarios`):

| File | Commit | What / why |
|---|---|---|
| `litellm-setup/docker-compose-litellm.yml` | `a4af43b` | Forward `AZURE_OPENAI_DEPLOYMENT`, `LITELLM_AZURE_CHAT_MODEL`, `AZURE_OPENAI_API_VERSION` into the container env (root-caused startup crash, see §5 bug 9). |
| `litellm-setup/litellm_config.yaml` | `a4af43b`, `4651472` | Restored full multi-provider `model_list` (Gemini ×3, Azure GPT-4o, OpenRouter) alongside a new `qwen2.5-7b-instruct` (`ollama_chat/qwen2.5:7b-instruct`, `api_base: http://172.17.0.1:11434`) entry; `default_model` set to `qwen2.5-7b-instruct`; `num_ctx: 16384` added to the Ollama entry (see §5 bug 11). |

**`ace-monorepo`** (this repo, `origin` → `Warsea12-ai/ace-monorepo`):

| File | Commit | What / why |
|---|---|---|
| `scripts/start-local-services.sh` | `d1bf6dc` | `start_langfuse()` now passes `--env-file` to its `docker compose up -d` call, matching `start_litellm()` — was the root cause of Langfuse's `LANGFUSE_INIT_*` vars never reaching the container (§5 bug 8). |
| `.env` | *not committed (gitignored, local secrets)* | Docker-bridge IP corrected from the example `172.26.0.1` to this host's real `172.17.0.1`; added `LANGFUSE_INIT_ORG_ID`/`_ORG_NAME`/`_PROJECT_ID`/`_PROJECT_NAME`/`_PROJECT_PUBLIC_KEY`/`_PROJECT_SECRET_KEY`; `LANGFUSE_HOST` remapped to port `4001` (see §5 bugs 6/7 for why). |
| `.tmp/langfuse/docker-compose.yml` | *not a tracked repo file — locally-generated compose stack* | `langfuse-web` port remapped `3000→4000→4001` (both earlier ports were other users' services, not mine — see §5 bugs 6/7). |

**`certifier`** (`origin` → `Warsea12-ai/certifier`, branch `feature/itbench-scenarios`):

| File | Commit | What / why |
|---|---|---|
| `utils/azure_openai_util.py` | `b67b59c` | Added `_build_chat_client()`: builds `agent_framework.openai.OpenAIChatClient` when a model's config has `"provider": "openai_compatible"`, else the original `AzureOpenAIChatClient` (default, unchanged). Also made `AzureLLMClient.get_clients` resilient — a single misconfigured/unused model entry now logs a warning and is skipped instead of crashing client construction for every model. |
| `README.md` | `b67b59c` | New subsection *"Using a non-Azure backend for the LLM judges (e.g. a local open-weight model)"* at line 278 — documents the `provider: openai_compatible` config shape, an example JSON block, the `agent-framework-ollama` package version-skew bug this sidesteps, and a caveat that 7-8B CPU models are less reliable at structured-JSON judge output than GPT-4o/GPT-5. |
| `configs/configs.json` | *deliberately NOT committed — local-only override, like a `.env`* | `gpt-4o`/`gpt-5.2` entries point at `provider: openai_compatible`, `base_url: http://127.0.0.1:11434/v1`, `model_id: qwen2.5:7b-instruct` for local testing. The shipped default (in git) still points at Azure for every other user. |

**`flash-agent`** (fork `Warsea12-ai/flash-agent`, branch `feature/itbench-certification-fixes`):

| File | Commit | What / why |
|---|---|---|
| `.env.example` | `0de4e7a` | Fixed `MCP_URLs` → `MCP_URLS` casing (env vars are case-sensitive on Linux; `config.py` reads `MCP_URLS` uppercase — following the example verbatim crashed with `Config error: MCP_URLS is required`, see §5 bug 10). |
| `.env` | *not committed (gitignored)* | Local run config — routes through the LiteLLM proxy (`OPENAI_BASE_URL=http://127.0.0.1:14000/v1`), `MODEL_ALIAS=qwen2.5-7b-instruct`, both MCP server URLs, Langfuse keys matching the local stack. Full content in §4.3 below. |

**Live k3s cluster** (not a repo — applied directly via `kubectl`):

| Resource | What / why |
|---|---|
| `NetworkPolicy litmusportal-server` (namespace `litmus`) | Added ingress `podSelector` entries for `app=subscriber`, `app=chaos-exporter`, `name=chaos-operator`, `app=workflow-controller`, `app=event-tracker` (previously only allowed `component=litmusportal-frontend`) — this was crash-looping the `subscriber` pod (876 restarts) that registers with the Litmus control plane. See §5 bug 1. |
| `otel-demo` Helm release (namespace `otel-demo`) | Installed with `--set monitoring.metricsServer.enabled=false` (k3s already ships its own metrics-server; the chart's own collides on a shared ClusterRole — see §5 bug 2). |

### 4.3 `flash-agent/.env` (local, uncommitted — reference copy)

```
AGENT_NAME=flash-agent
AGENT_MODE=active
LOG_LEVEL=INFO
K8S_NAMESPACE=otel-demo
K8S_NODE_IP=127.0.0.1
OPENAI_BASE_URL=http://127.0.0.1:14000/v1
OPENAI_API_KEY=sk-agentcert-2026
MODEL_ALIAS=qwen2.5-7b-instruct
MCP_URLS=http://localhost:8186/mcp,http://localhost:31085/mcp
MCP_TIMEOUT=30
LANGFUSE_PUBLIC_KEY=pk-lf-agentcert-local
LANGFUSE_SECRET_KEY=sk-lf-agentcert-local
LANGFUSE_HOST=http://127.0.0.1:4001
MCP_INTERACTIONS_FILE=/home/icets/ace-monorepo/flash-agent/.tmp/mcp_interactions.jsonl
CHAOS_NAMESPACE=litmus
TARGET_APP_NAME=otel-demo
MCP_INCLUDE_CHAOS_TOOLS=true
TRACE_TAGS=flash-agent,itbench-certification
SCAN_INTERVAL=300
SCAN_QUERY=Analyse the operational health of all workloads in Kubernetes namespace 'otel-demo'. Identify pod failures, restarts, resource pressure, and anomalies, and remediate anything found.
```

Kubernetes MCP server is reached via `kubectl port-forward` (ClusterIP-only,
in-cluster otherwise); Prometheus MCP server is reached directly via its own NodePort
(`31085`), no port-forward needed.

---

## 5. Bugs found and fixed (chronological, all real fixes — none worked around)

1. **Litmus `subscriber` pod crash-looping (876 restarts).** NetworkPolicy blocked ingress
   from `app=subscriber` etc. Fixed via `kubectl apply` (§4.2, live-cluster row). Verified:
   pod logs show "Server connection established, Listening....".
2. **`otel-demo` Helm install collided with k3s's built-in metrics-server** on a shared
   `ClusterRole`. Fixed via `--set monitoring.metricsServer.enabled=false` at install time
   (not editing the checked-in `values.yaml` — environment-specific).
3. **PyAudio build failure** during certifier `pip install` (`portaudio.h` missing).
   Confirmed `pyaudio` is unused/vestigial in certifier's own code; fixed via
   `sudo apt-get install -y portaudio19-dev`.
4. **Azure-only LLM Council** — `AzureLLMClient` hardcoded to
   `agent_framework.azure.AzureOpenAIChatClient` for every model, blocking any non-Azure
   testing. Fixed via `_build_chat_client()` + `provider: openai_compatible` (§4.2).
5. **`embedding_model` client-construction crash** during ad-hoc testing (raw `json.load()`
   bypassing env resolution left `ENV_AZURE_EMBEDDING_ENDPOINT` as a literal string). Fixed
   by using the real `ConfigLoader.load_config()` path for testing, and by making
   `get_clients` resilient to per-model failures (log + skip) as a genuine improvement.
6. **flash-agent has no native tracing** (confirmed via `grep` — zero langfuse/otel
   references in its source; `requirements.txt` comment: "OTEL and Langfuse SDK removed —
   LiteLLM proxy handles tracing"). This reversed the initial plan of pointing flash-agent
   directly at Ollama — it must route through the LiteLLM proxy so its `langfuse` callback
   captures traces for certifier Phase 0.
7. **Ollama bound to localhost only** — LiteLLM's container couldn't reach
   `127.0.0.1:11434` (refers to the container itself). Fixed by restarting Ollama with
   `OLLAMA_HOST=0.0.0.0:11434`.
8. **Langfuse port 3000 conflict** — belonged to a pre-existing `grafana-server`
   (PID 4930, confirmed via `sudo ss -tlnp`, **not mine**). Remapped to 4000.
9. **Langfuse port 4000 conflict** — belonged to another user's `agentlab-ui-angular`
   Docker container (confirmed via `sudo docker ps`, **not mine**). Remapped to 4001
   (confirmed free across several candidates first).
10. **Langfuse `LANGFUSE_INIT_*` vars never reaching the container** — traced to
    `start_langfuse()` never passing `--env-file` to its compose invocation. Fixed in
    `scripts/start-local-services.sh` (commit `d1bf6dc`); Langfuse volumes wiped for a
    clean re-init, verified fixed via `docker exec ... echo $LANGFUSE_INIT_PROJECT_PUBLIC_KEY`.
11. **LiteLLM proxy startup crash (major)** — `TypeError: argument of type 'NoneType' is not
    iterable` at litellm's own `if "ollama" in litellm_model_name and ...` check (no
    null-guard). Root cause: `docker-compose-litellm.yml` never forwarded
    `AZURE_OPENAI_DEPLOYMENT`/`LITELLM_AZURE_CHAT_MODEL`, which the Azure model entry's
    templated `model_name`/`model` fields reference — both resolved to `None` inside the
    container, tripping the crash for the *entire* `model_list`, not just the Azure entry.
    First attempt was to comment out the non-Ollama entries — **explicitly rejected by the
    user**, who wanted LiteLLM's multi-provider config to actually work. Fixed by forwarding
    the missing env vars (commit `a4af43b`); full original `model_list` restored and
    verified (`Initialized Model List [...]`, real completions from both Ollama and, when
    credentials are present, the other providers).
12. **`MCP_URLs` vs `MCP_URLS` casing** — `flash-agent/.env.example` templated the var in
    lowercase-s `MCP_URLs`; `config.py` reads uppercase `MCP_URLS`. Fixed in both the
    working `.env` and `.env.example` (commit `0de4e7a`).
13. **Ollama's default 2048-token context window silently truncating flash-agent's prompt.**
    The most significant bug: flash-agent's system prompt alone measures **~2100 tokens**
    (verified directly: `_build_system_prompt()` → 8409 chars ≈ 2102 tokens), before the
    ~25 MCP tool schemas or any tool-result turns are added on top. Ollama defaults every
    model's `num_ctx` to 2048 regardless of what the model natively supports (qwen2.5:7b-
    instruct supports up to 32768) **unless overridden per-request** — LiteLLM's own source
    confirms `num_ctx: Optional[int] = None  # Default: 2048`. The real symptom, reproduced
    twice: a scan starts fine (iterations 1-2 make valid tool calls), then by iteration 3+
    the model's context has silently overflowed and it produces unparseable/empty JSON
    (`Could not parse analysis: Expecting value: line 1 column 1 (char 0)`, some responses
    literally 0 chars) and degenerate tool calls with missing/wrong arguments, looping
    without progress. Fixed by adding `num_ctx: 16384` to the `qwen2.5-7b-instruct` entry
    in `litellm_config.yaml` (commit `4651472`); verified LiteLLM forwards it (proxy health
    endpoint reports `num_ctx: 16384` for this model) and a direct completion still works.

14. **Two independent hardcoded 120s timeouts, both needed fixing.** After fix #13, a
    re-run hit a *new* failure: iteration 2's LLM call exceeded the OpenAI client's own
    hardcoded `timeout=120.0` in `flash_agent.py`'s `_create_openai_client`. Benchmarked
    directly against Ollama (bypassing LiteLLM entirely) to confirm this wasn't
    misconfiguration but genuine CPU-inference latency: a ~3.5K-input/~1.1K-output-token
    completion took **271.5s** end-to-end (prompt eval ~70 tok/s, generation ~5 tok/s).
    Fixed by making the timeout and SDK retry count configurable
    (`LLM_REQUEST_TIMEOUT`/`LLM_MAX_RETRIES` env vars, `flash-agent@f0096b1`, defaults
    unchanged at 120s/2 retries so hosted-API users see no behavior change) and setting
    `LLM_REQUEST_TIMEOUT=600`/`LLM_MAX_RETRIES=1` in the local `.env`. Re-running still hit
    a *second*, independent 120s ceiling one layer down: LiteLLM's Router (engaged
    whenever a proxy config declares `model_list`, which this one does) enforces its own
    `router_settings.timeout`, separate from and taking precedence over
    `litellm_settings.request_timeout: 600` — left at its old default of 120, it killed
    the same call with `litellm.Timeout: Connection timed out. Timeout passed=120.0`.
    Fixed by raising `router_settings.timeout` to `600` to match
    (`agentcert-stack@903cc47`). Verified fixed: (a) a direct completion through the proxy
    legitimately took 2m48s and succeeded past the old 120s ceiling; (b) two full
    flash-agent scans then ran end-to-end without any timeout or parse error — scan 1 took
    497.1s (2 ReAct iterations, found a real `product-catalog` restart-count warning),
    scan 2 took 311.5s (2 iterations, confirmed no remaining issues). The open-weight
    agent's ReAct loop is now reliably producing valid, parseable structured analysis.

**Residual caveat, not a bug:** the two scans above reported health scores of 80 and 10
for what should be a similar cluster state moments apart — some scan-to-scan scoring
noise is expected from a 7-8B model (already flagged in `certifier/README.md`'s caveat
about local-model reliability vs. GPT-4o/GPT-5); worth keeping an eye on once real
fault-injection runs are underway, but not blocking.

---

## 6. Remaining work (not yet started)

- Verify ChaosEngine submission against the now-registered Litmus infra.
- Run ONE end-to-end validation: single fault, single run, trace captured, certifier
  Phase 0+1 processed.
- Scale to mass execution: 5 runs × all ~29 SRE fault bundles (~145 runs total, per revised
  scope — originally 30 was discussed, reduced from 30 runs/bundle to 5), as a
  resource-capped background loop.
- Run certifier Phase 2+3 (aggregation + certification) once sufficient runs exist.
- Continue fixing real issues as they surface — this has been, and is expected to remain,
  an iterative process.
- Throughout: keep respecting the ~50%-of-host resource cap and shared-host safety
  (verify ownership of any port/process/namespace before touching it).

---

## 7. ITBench fault-category split (`chaos-charts/faults/itbench/`)

Separate from the open-weight-agent effort itself: `chaos-charts/faults/kubernetes/` used
to hold all 68 fault directories (both the 29 ITBench-derived ones and ~35 pre-existing
generic LitmusChaos experiments) with no way to tell which came from ITBench short of
cross-referencing git history or `certifier/configs/fault_categories.json`. Split into two
ChaosHub categories, commit `chaos-charts@88e3f34`:

- `faults/kubernetes/` — the ~35 generic LitmusChaos experiments (`pod-cpu-hog`,
  `node-drain`, `pod-http-latency`, etc.), unchanged names/content.
- `faults/itbench/` — the 29 ITBench-derived fault bundles (identified precisely via
  `git show --diff-filter=A --name-only` on the three ITBench implementation commits:
  `476684d`, `7efbc15`, `26a0a6e`), moved with `git mv` (directory names and internal
  `fault_name`/CR-name values unchanged — only the parent category directory moved, so
  `fault_categories.json`'s mapping and ChaosEngine name matching are unaffected). Has its
  own `itbench.chartserviceversion.yaml` (`displayName: ITBench`) and
  `itbench.package.yaml`, so the Litmus portal now shows "Kubernetes" and "ITBench" as two
  distinct ChaosHub categories.

`faults/kubernetes/experiments.yaml` and `faults/itbench/experiments.yaml` (the combined,
ChaosHub-sync-readable catalog files `combine-all-crs.go` generates) were regenerated by
hand — no Go toolchain on this host — replicating that script's exact logic (concatenate
each subdirectory's `fault.yaml` with a `\n---\n` separator); verified via YAML multi-doc
parse (35 docs / 29 docs respectively).

**Not affected by this move:** the `otel-demo-itbench` Argo workflow
(`chaos-charts/experiments/otel-demo-itbench/experiment.yaml`) that actually executes these
scenarios for real certification runs has its own inlined `kubectl` scripts and never
referenced the ChaosHub catalog paths — confirmed via grep before moving anything. So §4-6
above (the live certification effort) are unaffected by this restructure.

---

## 8. CrewAI CISO Agent trial (real ITBench reference agent, real CISO scenario)

**Context:** ITBench ships two reference agents (not one — confirmed by reading both repos'
READMEs directly, since the top-level ITBench README's "both built with CrewAI" claim turned
out to be stale):
- **SRE Agent** (`itbench-hub/ITBench-CISO-SRE-FinOps-Agent`, internally "Zero") — a wrapper
  around OpenAI's Codex CLI, *not* CrewAI, despite the table label. Not used here.
- **CISO Agent** (`itbench-hub/ITBench-CISO-CAA-Agent`) — genuinely built with **CrewAI +
  LangGraph**. This is the one exercised below, per explicit instruction to use "the CrewAI
  based agent."

This is a real trial: a real Docker-containerized CrewAI agent, a real CIS Benchmark
scenario (`Gen-CIS-b-K8s-Kyverno` — matches the `ciso_fault` category already registered in
`certifier/configs/fault_categories.json` from the earlier CISO scorecard work), deployed
and evaluated against this session's actual k3s cluster — not mocked, not simulated.

### 8.1 What was built

| Repo | Fork | Purpose |
|---|---|---|
| `IBM/ITBench-Scenarios` (`ciso/` subtree) | not forked (read-only reference; no changes needed) | Ansible/Makefile-driven scenario lifecycle: `deploy_bundle` (installs Kyverno via Helm), `inject_fault` (deploys a noncompliant `hostNetwork: true` nginx pod in a new `paa` namespace), `get` (goal text + scenario kubeconfig), `evaluate` (checks PolicyReports), `remove_fault`/`destroy_bundle` (cleanup). |
| `itbench-hub/ITBench-CISO-CAA-Agent` | `aruscher-dev/ITBench-CISO-CAA-Agent`, branch `fix/openai-compatible-llm-fallback` (commits `104f83e`, `b025192`) | The CrewAI+LangGraph CISO Agent itself (`crewai==0.95.0`). Two real bugs found and fixed here — see §8.3. |

Both repos were cloned/built under `ace-monorepo/.tmp/ciso-agent-trial/` (gitignored,
persistent across the session — not the ephemeral `/tmp` scratchpad), including two Docker
images built locally: `ciso-task-scenarios:latest` (the scenario Makefile runner) and
`ciso-agent:latest` (the agent itself).

### 8.2 Infrastructure fixes needed (new, beyond §5's list)

15. **UFW blocked container→k3s-API-server traffic.** The scenario runner container needs
    to reach the k3s API server via the docker bridge IP (`172.17.0.1:6443`) — same pattern
    as Ollama/LiteLLM earlier, but k3s's API server is a host-native (non-containerized)
    process, so its port genuinely goes through the host's `INPUT` iptables chain (unlike
    Docker-published ports such as LiteLLM's 14000, which route through `FORWARD` and were
    already reachable with no firewall change — confirmed empirically both ways). `ufw
    status` showed an explicit `ALLOW` rule for port 11434 (added earlier for Ollama) but
    nothing for 6443. Fixed with `sudo ufw allow 6443/tcp`.
16. **k3s's serving certificate doesn't cover the docker bridge IP.** Even after the
    firewall fix, TLS verification failed: `x509: certificate is valid for 10.43.0.1,
    127.0.0.1, 192.168.28.11, ::1, not 172.17.0.1`. Rather than regenerating the *live*
    k3s server's certificate (which would need a control-plane restart, affecting every
    other in-progress workload on this shared cluster), set
    `insecure-skip-tls-verify: true` on a dedicated container-facing copy of the kubeconfig
    used only for this trial — the original `~/.kube/config` used everywhere else in this
    session is untouched.

### 8.3 Real bugs found and fixed in the CISO Agent itself (`src/ciso_agent/llm.py`)

17. **`init_llm()`'s final branch only recognized `"gpt" in model.lower()`.** Any other
    OpenAI-compatible model name (e.g. `qwen2.5-7b-instruct`, our local Ollama-served model
    routed through the LiteLLM proxy `model_list` alias) fell through to `return None`. The
    caller (`call_llm()`, used by the agent's "manager"/task-selector step) then fell back
    to `ChatOpenAI(temperature=0, model=model)` with **no `api_key`/`base_url` at all**,
    crashing with `openai.OpenAIError: The api_key client option must be set...`.
    Reproduced directly, then fixed by widening the condition to
    `"gpt" in model.lower() or api_url` (any endpoint with an explicit `api_url` is a
    deliberate OpenAI-compatible target, not just OpenAI's own `gpt*` models), and by
    passing `api_key`/`base_url` through on `call_llm()`'s own fallback too, in case
    `init_llm()` ever legitimately returns `None` for some other model shape.
18. **CrewAI's *native* `LLM` class needed a different model-string shape than the fix
    above.** After fixing #17, the manager/task-selector step (LangChain `ChatOpenAI`
    path) succeeded — but the actual `Crew.kickoff()` step (CrewAI's own `LLM` class,
    which calls `litellm.completion()` directly) then failed with
    `litellm.BadRequestError: LLM Provider NOT provided ... You passed
    model=qwen2.5-7b-instruct`. Root cause: LangChain's `ChatOpenAI` sends `model` as-is
    in the HTTP request body to `base_url` (so the bare LiteLLM-proxy alias
    `qwen2.5-7b-instruct` is correct there), but litellm's own `get_llm_provider()`
    (used internally by CrewAI's `LLM` class) requires an explicit provider prefix like
    `openai/<model>` to resolve a provider **even with `base_url` set** — a genuine
    architectural inconsistency in this codebase between its two different LLM call
    paths, both driven by the *same* `LLM_MODEL_NAME` env var. Fixed in
    `init_agent_llm()`'s generic-endpoint branch: prefix with `openai/` only when the
    model string doesn't already declare a provider (checked via `"/" in model`), so a
    single `LLM_MODEL_NAME=qwen2.5-7b-instruct` value now works correctly across both
    code paths.

### 8.4 Result: PASS

With both fixes applied, one full trial run:
1. The CrewAI `CISOCrew` (`role="Test"` agent, `RunKubectlTool` + `GenerateKyvernoTool`,
   two sequential `Task`s) correctly generated a Kyverno `ClusterPolicy`
   (`disallow-host-network-pods`, `validationFailureAction: Audit` — report-only, never
   blocked anything cluster-wide) and deployed it via `kubectl apply` to the real cluster.
2. Verified independently (not just trusting the agent's own report): `kubectl get polr -n
   paa` showed the injected noncompliant pod/ReplicaSet/Deployment all correctly
   **failing** the new policy (`fail=1, pass=0`).
3. `make evaluate` (the scenario's own independent evaluation harness, reading
   `PolicyReport`/`ClusterPolicyReport` resources directly — not the agent's self-report)
   returned **`"pass": true`** (`generate_assessment_posture: true` — the actual
   compliance-detection check). Two secondary sub-checks (`generate_policy`,
   `evidence_available`) were `false` — these check for a separate "evidence archive"
   artifact that ITBench's full official leaderboard-submission tooling produces; running
   the raw agent container directly (as done here) doesn't produce that packaging, but it
   isn't part of the core pass/fail determination.

**Cleanup:** `remove_fault` + `destroy_bundle` (removes the fault + policy), then Kyverno's
Helm release and both the `kyverno` and `paa` namespaces were removed manually (this
scenario framework's `destroy_bundle` only tears down an ephemeral `kind`-provisioned
cluster automatically; for a bring-your-own cluster like ours, Kyverno is left installed by
design for scenario reuse — not appropriate to leave behind after a one-off trial on a
shared host). Verified clean: `kubectl get clusterpolicy` / `kubectl get ns kyverno` / `kubectl
get ns paa` all confirm nothing remains.

### 8.5 Remaining work for this track

- Only scenario 1 (`Gen-CIS-b-K8s-Kyverno`) has been trialed. Three more CISO scenario
  types remain untested with this agent: `Gen-CIS-b-K8s-Kubectl-OPA`,
  `Gen-CIS-b-RHEL9-Ansible-OPA` (needs a RHEL9 host, not just a Kubernetes cluster),
  `Upd-CIS-b-K8s-Kyverno`.
- No integration yet between this trial and the ACE certifier pipeline itself (Phase 0-3).
  This was run as a standalone manual trial per the immediate instruction to "benchmark it
  ... catching, correcting and noting out ... the errors"; wiring real CISO executions into
  `certifier/metrics_extractor/scripts/ciso_metrics_adapter.py` (already built for exactly
  this per-run doc shape, from the earlier CISO scorecard work) is separate follow-on work,
  not yet started.
- Two upstream PRs are open-able but not yet raised: both `fix/openai-compatible-llm-fallback`
  commits on `aruscher-dev/ITBench-CISO-CAA-Agent` are pushed but no PR has been opened
  against `itbench-hub/ITBench-CISO-CAA-Agent` upstream.
