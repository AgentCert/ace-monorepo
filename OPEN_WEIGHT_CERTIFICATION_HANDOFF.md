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

---

## 9. ChaosEngine submission verified — critical mistargeting bug found and fixed

**Context:** none of the 29 ITBench fault bundles (nor the pre-existing generic ones) had
ever actually been submitted as a real `ChaosEngine` against a live cluster before this —
`ITBENCH_HANDOFF.md` explicitly flagged the `APP_NAMESPACE`/`APP_LABEL`/`APP_KIND`
env-injection mechanism as **"NOT independently verified... verify this before trusting
it."** This section is that verification, and it found a real, critical bug.

### 9.1 What was tested

`scaled-to-zero-kubernetes-workload`, targeted at `otel-demo`'s `load-generator`
Deployment (`opentelemetry.io/name=load-generator`), via a real `ChaosEngine` submitted
directly with `kubectl` (bypassing the ChaosCenter portal UI). Required creating RBAC
(`ServiceAccount`/`Role`/`RoleBinding`) by hand first — **no fault bundle in this repo ships
an `rbac.yaml`**, upstream LitmusChaos convention leaves this to the portal's own
install flow, which direct-`kubectl` submission bypasses entirely.

### 9.2 Critical bug found: `APP_NAMESPACE`/`APP_LABEL` are never populated

The first submission's experiment pod logged `Resolving target deployment in ns= label=`
— both vars empty — then resolved and **scaled down `accounting`** (a real, unrelated
`otel-demo` service), not the intended `load-generator`. Restored `accounting` to 1
replica immediately (confirmed back to `1/1 Running` within ~30s; no other impact).

Root cause, confirmed by inspecting the experiment pod's actual injected env directly
(`kubectl get pod ... -o jsonpath='{.spec.containers[0].env}'`): the chaos-operator on
this cluster declares `APP_NAMESPACE`/`APP_LABEL` as env var *names* on the pod spec but
never gives them a `value` — LitmusChaos's assumption in this handoff doc was simply
wrong for this operator version. It instead sets one combined `TARGETS` var:
`"deployment:otel-demo:[opentelemetry.io/name=load-generator]:union"` — format
`<kind>:<namespace>:[<label-selector>]:<mode>`.

**Fix** (`chaos-charts@342259e`): every one of the 29 fault scripts now derives
`APP_KIND`/`APP_NAMESPACE`/`APP_LABEL` from `TARGETS` at the top of its script (falling
back to the old vars if `TARGETS` isn't set, for forward-compat). Applied uniformly via
a scripted patch to 27 files sharing an identical template, plus 2 individually
(`cordoned-kubernetes-worker-node`, `kubernetes-api-server-request-surge` — same fix,
slightly different surrounding script text). Regenerated both `experiments.yaml` catalog
files afterward.

**Re-verified after the fix:** resubmitted the same `ChaosEngine` — correctly logged
`Resolving target deployment in ns=otel-demo label=opentelemetry.io/name=load-generator`,
`Target=load-generator`, scaled it to 0, held for the configured duration, then correctly
reverted it to 1. `load-generator` confirmed `1/1 Running` afterward.

**Also fixed a second RBAC gap** while getting this far: `fault.yaml`'s own declared
`permissions` list only covers what the experiment *pod* needs once running — not the
baseline `batch/jobs create` (and a few related) permissions the chaos-runner needs to
launch the experiment as a Job in the first place. This is a standard LitmusChaos
convention (normally provided by a per-experiment `rbac.yaml` that this repo's fault
bundles simply don't have); documented the full required Role in this section's test
artifacts for future reference.

### 9.3 Known gap, not fixed (non-blocking): no `ChaosResult` CR is ever created

Even with the mistargeting bug fixed, the `ChaosEngine`'s `verdict` stayed `"Awaited"`
and `kubectl get chaosresult` returned nothing — despite the experiment pod completing
successfully (`Succeeded` phase, correct inject+revert). Standard LitmusChaos experiments
get this for free from the `litmus-go` SDK; these are hand-written shell scripts (per
`ITBENCH_HANDOFF.md`'s own documented design decision — no compiled Go binary exists for
these), and none of them ever `kubectl apply` a `ChaosResult` CR themselves.

**Deliberately not fixed here** — checked whether it blocks the actual certification
pipeline first: it doesn't. `ITBENCH_HANDOFF.md` §2 already established that
`fault_bucketing` is "pure LLM-driven trace classification with **zero dependency on
ChaosEngine/ChaosResult CRs existing**," and `ground_truth.yaml` (also unrelated to
ChaosResult) is optional. The only real consequence: the Litmus **ChaosCenter portal**
won't show a pass/fail badge for any of these 29 experiments. Worth fixing eventually for
full portal conformance, but explicitly out of scope for unblocking real certification
runs — noted here so it isn't mistaken for an oversight.

### 9.4 Cleanup

All test artifacts removed: `ChaosEngine`, `ChaosExperiment`, and RBAC deleted from
`otel-demo`. Verified `otel-demo` fully healthy afterward — every pod `1/1`/`Running`,
`accounting` and `load-generator` both back at their original replica count of 1.

---

## 10. One end-to-end validation — SUCCESS (real fault → agent → certifier Phase 0+1)

Full loop, all real: `scaled-to-zero-kubernetes-workload` injected against `otel-demo`'s
`load-generator` → flash-agent scan observes it (correctly attributing a chaos-related pod
restart to "deliberate disturbance") → Langfuse trace → `scripts/run_certification.py
--trace-id ... --skip-cert` → Phase 0 (fault bucketing) + Phase 1 (metric extraction) both
completed successfully, real output files written under
`.tmp/flash-agent-qwen2.5-7b-instruct/scaled-to-zero-kubernetes-workload/fault-bucketing/<run_id>/`.

Two more real bugs found and fixed getting there:

19. **flash-agent never attached certifier trace metadata at all.** `scripts/
    run_certification.py --trace-id` requires `metadata.{agent_id,experiment_id,
    experiment_run_id}` on the Langfuse trace; flash-agent's LLM calls set none of it.
    Two, not one, sub-bugs surfaced fixing this (each confirmed empirically via a real
    completion call + inspecting the resulting trace via Langfuse's API, since the
    correct convention isn't obvious and guessing wrong wastes an expensive real
    round-trip): (a) a bare `metadata={...}` field lands on the per-call GENERATION
    observation (nested under `requester_metadata`), not the trace itself — LiteLLM's
    Langfuse integration only promotes `trace_`-prefixed keys to the trace's own
    attributes, so it must be nested as `metadata.trace_metadata`; (b) the certifier's
    own search (`certifier/main/services/trace_service.py`'s `_list_traces`) looks for
    the exact key `experiment_run_id`, not `run_id` — confirmed by reading that file
    after a first attempt with the wrong key produced `TRACE_NOT_FOUND` despite the
    single-trace `--trace-id` lookup resolving the same run's IDs correctly moments
    earlier. Fixed in `flash_agent.py`'s new `_trace_metadata_extra_body()` helper
    (attaches nothing when `EXPERIMENT_ID` is unset, so ad-hoc/dev runs are unaffected)
    and three new `config.py` fields (`AGENT_ID`, `EXPERIMENT_ID`, `RUN_ID` — the last
    auto-generates a fresh UUID per process invocation if unset).
20. **`.tmp/` ownership regression.** The top-level `ace-monorepo/.tmp/` directory was
    still root-owned from an earlier `sudo`-run setup step (same root cause as the
    `.tmp/langfuse` and `.tmp/ciso-agent-trial` fixes earlier), blocking
    `run_certification.py`'s own `mkdir`. Fixed with `sudo chown icets:icets .tmp`
    (one level only — subdirectories it needs to create itself work fine once the
    parent is writable).

**Also found (real, but a process-management issue, not a pipeline bug):** a flash-agent
process from an earlier validation run received `SIGTERM`, logged its full graceful-
shutdown sequence ("shutting down gracefully" → "shut down cleanly"), yet **kept running**
in the background for another 15+ minutes, concurrently with a newly-started run, both
competing for Ollama's single-concurrency slot (`OLLAMA_NUM_PARALLEL=1`). Not
investigated further (out of scope for this validation), but worth knowing: `kill`
(SIGTERM) is not reliable for stopping flash-agent — use `kill -9` and verify the process
list afterward, don't trust the log message alone.

Both fixes pushed: `flash-agent@bbd4b61` on `feature/itbench-certification-fixes`.

### Expected caveat, not a new bug

Phase 1's LLM-judge steps (structured metric/qualitative extraction, routed through the
same local Ollama-backed `configs.json` override) logged three
`Failed to parse structured output: Expecting value: line 1 column 1 (char 0). Returning
raw text.` warnings — handled gracefully (falls back to raw text, doesn't crash the
pipeline) but confirms the exact caveat already documented in `certifier/README.md`: a
7-8B CPU-served model is meaningfully less reliable at structured JSON output than
GPT-4o/GPT-5, for the certifier's own judge calls just as much as for flash-agent's.

**Timing:** Phase 0+1 took ~18 minutes end-to-end for a trivial 2-observation trace —
three separate LLM-judge calls at CPU-inference speed. This is the same bottleneck
documented in §5 bug 13/14, now confirmed to affect the certifier pipeline's own LLM
calls too, not just flash-agent's. Directly motivates §11.

---

## 11. GPU acceleration — abandoned `5g-lab`, discovered a local GPU instead

Mid-session, a second host became available: `5g-lab` (SSH alias → `192.168.28.45`,
hostname `agenticai`) — 2x NVIDIA L40 (46GB VRAM each), 64 CPU cores, 251GB RAM, Ollama
and Docker already installed. `qwen2.5:7b-instruct` was pulled there and the migration
path was scoped (an SSH tunnel, since the account had no `docker` group membership or
passwordless `sudo` there, and Ollama was bound to `127.0.0.1` only).

**Superseded by explicit instruction: stop using `5g-lab`, stay on this host.** Checking
*this* host's own GPU access (never checked before this point in the session) found it
already has an **NVIDIA RTX A6000 (49GB VRAM)**, completely idle, with drivers/CUDA
already installed (`nvidia-smi` works, driver 580.159.03, CUDA 13.0) — apparently made
available around the same time as `5g-lab`, explaining why every benchmark earlier in
this document measured CPU-only speeds despite a GPU being physically present.

Ollama (already running on this host as a plain background process, not a systemd
service) auto-detected the GPU correctly on restart with zero configuration changes:
`inference compute id=0 ... library=CUDA compute=8.6 name=CUDA0 description="NVIDIA RTX
A6000" total="47.4 GiB"`. **No LiteLLM/litellm_config.yaml changes were needed at all** —
Ollama still runs on this same host at the same address (`172.17.0.1:11434` from the
LiteLLM container's perspective), just GPU-accelerated now instead of CPU-only.

**Verified speedup** (same model, same host, only the compute backend changed):
- First call after restart: prompt eval 43 tokens in 26.25s (one-time VRAM/context
  allocation overhead) — this is why the *second* call is the real number:
- Second call (GPU warm): 44 prompt tokens in **0.0155s** (≈2832 tok/s, vs. ≈70 tok/s on
  CPU — **~40x**), 371 completion tokens in **3.45s** (≈107.6 tok/s vs. ≈5.1 tok/s on
  CPU — **~21x**). A full LiteLLM-proxied chat completion round-trip: **3.56 seconds**
  total, versus the multi-minute-to-8-minute-cold-start calls measured everywhere earlier
  in this document.

This changes the mass-execution time budget from "the dominant cost is LLM inference,
measured in minutes per call" to "the dominant cost shifts to k8s/chaos orchestration
overhead" — the original ~145-run estimate that looked like a multi-day undertaking on
CPU is now realistically a same-session undertaking.

**Also found while checking "no issue remains" before mass execution:** the
`litellm-proxy` container had been reporting Docker-level `unhealthy` for 20+ hours
straight — its `HEALTHCHECK` shells out to `curl`, which isn't installed in the
`litellm/litellm:v1.82.0-stable` image, so the check itself failed to *execute* (not a
real service failure; verified the proxy served correct completions the entire time).
Fixed by switching the healthcheck to a `python3`-based HTTP GET (`python3` is present in
the image) — `agentcert-stack@b56a5cf`. Recreated the container and reconfirmed both
health (`"status":"healthy"`) and a real completion afterward.

Full cluster health check before mass execution: every pod in `litmus` and `otel-demo`
`Running`, no lingering `ChaosEngine`/`ChaosExperiment` anywhere, no stray namespaces from
earlier trials, Langfuse/MongoDB/LiteLLM all up, other users' unrelated containers on this
shared host untouched and healthy.

---

## 12. Mass execution — 137/137 runs successful, plus a critical cleanup bug found and fixed

Ran the full sweep: all 29 ITBench fault bundles × 5 runs each (2 explicitly-flagged
high-blast-radius faults — `cordoned-kubernetes-worker-node`,
`kubernetes-api-server-request-surge` — capped at 1 run), 137 total. **Result: 137/137
succeeded** (real fault injected, flash-agent completed a genuine scan observing it,
correctly-tagged Langfuse trace captured for each).

### 12.1 Driver

A new (untracked, `.tmp/mass-execution/driver.py` — gitignored, documented here instead)
Python driver per run: build RBAC from the fault's own declared `permissions` (plus the
baseline chaos-runner permissions from §5 bug 15), apply the `ChaosExperiment` + a
filled-in `ChaosEngine`, set `EXPERIMENT_ID` to the fault name in `flash-agent/.env`, run
one scan, wait for `"Scan complete"`, clean up. Resumable via a `results.jsonl` log keyed
by `(fault, run_index)`.

**Target mapping**: extracted directly from `chaos-charts/experiments/otel-demo-itbench/
experiment.yaml`'s already-validated `ChaosEngine.spec.appinfo` blocks (28 of 29 faults
already had a real, tested target there) rather than guessing fresh ones; the 2 missing
faults (`invalid-kubernetes-service-selector`, `nonexistent-kubernetes-workload-
persistent-volume-claim`) got sensible unused otel-demo components (`currency`, `llm`).

### 12.2 New bug found before launch: `ChaosEngine.spec.appinfo.appkind` is a fixed CRD enum

`appinfo.appkind` is schema-validated to
`^(^$|deployment|statefulset|daemonset|deploymentconfig|rollout|job)$` — submitting
`service`, `configmap`, `horizontalpodautoscaler`, or `pod` (the *actual* resource kind
for 6 of the 29 faults) is rejected outright at admission time. Fixed two ways together:
each of those 6 fault scripts now hardcodes its own real target kind directly (instead of
trusting `TARGETS`' kind component, per the §9.2 fix) since the kind never varies for a
given fault; the `ChaosEngine` submission itself uses a harmless CRD-valid dummy
`appkind: deployment` whose `applabel` still matches a real Deployment of the same
component, so any operator-side existence check still passes.

### 12.3 Two real bugs found during the first full sweep (43/101 runs "failed")

14. *(continuing the numbering from §5/§9)* **Driver race condition.** The scan-completion
    poll checked `proc.poll() is not None` *before* reading the log file. At GPU speed a
    scan can finish and the flash-agent process can exit within the same 5-second poll
    interval — so by the time the driver next woke up, the process had already exited
    and the loop broke on that check alone, never getting to see that `"Scan complete"`
    was already on disk. Caused 27 of 43 failures to be misreported as scan failures when
    the scan had actually succeeded. Fixed: check the log content first, and even after
    observing the process has exited, do one final log read before concluding failure.
15. **`_parse_analysis_response()` didn't validate the parsed JSON's top-level type.**
    `json.loads()` doesn't care whether the result is a dict or a list — both are valid
    JSON. When the model wrapped its response in a list (`[{...}]` instead of `{...}}`),
    parsing "succeeded" and the loop moved on, only to crash later on
    `analysis.get("health", {})` with `AttributeError: 'list' object has no attribute
    'get'`. Reproduced identically in exactly 15 of 43 failures, across many different
    fault types. Fixed in `flash_agent.py` (`flash-agent@21e138d`): unwrap the common
    one-element-list case (the model's intended object, just over-wrapped), and raise a
    clear `ValueError` for any other shape mismatch so the existing "ask the model to
    reformat" retry logic handles it instead of crashing the process.

After both fixes, every one of the remaining/retried runs succeeded — 0 failures in the
final 121+ attempts. Total: 137/137.

### 12.4 Critical bug found *after* the sweep completed: premature `ChaosEngine` cleanup

The driver waited for flash-agent's scan to finish, then immediately deleted the
`ChaosEngine` in its `finally` block. But flash-agent's scan reliably finishes in
**35-60 seconds** (GPU speed) — well before a fault's own `TOTAL_CHAOS_DURATION`
(60-120s) elapses. Deleting the `ChaosEngine` at that point kills the still-running
experiment `Job` **before it ever reaches its own revert commands**. The scan itself was
unaffected (it observed the fault while genuinely active, before cleanup ran) — this is a
**post-scan cleanup bug, not a corruption of the certification data** — but it left real
damage on the live, shared cluster:

- `email` and `recommendation` Deployments stuck with their fault-injected hanging/crashing
  init containers still in the pod template (each had spawned a new, permanently-failing
  ReplicaSet that Kubernetes correctly declined to promote over the still-healthy old one
  — no outage, but a lingering broken half-state).
- 5 leftover synthetic-traffic-generator pods from `chaos-mesh-http-body-tamper-replacement`,
  still running (and presumably still generating synthetic traffic) for 2+ hours.
- 2 leftover `NetworkPolicy` objects (`frontend-ingress-block-fault`,
  `quote-http-abort-fault`) from the two Chaos-Mesh-replacement/ingress-blocking faults.
- **One leftover `ResourceQuota`** (`memory`, from `insufficient-kubernetes-resource-quota`,
  hard limits set to `20m`/`32Mi` — deliberately tiny, the fault's whole point) — this one
  is namespace-*wide*, so it silently blocked `checkout`'s own rollout **and** an unrelated
  `load-generator` restart from creating any new pod for over an hour, since usage was
  already far past the quota's tiny limits.

**Remediation performed:**
1. Manually removed the two Deployments' lingering `initContainers` (`kubectl patch
   --type=json ... remove /spec/template/spec/initContainers`).
2. Deleted the 5 leftover pods, the `ResourceQuota`, and the 2 `NetworkPolicy` objects.
3. `kubectl rollout restart` on `checkout` and `load-generator` once the quota block was
   cleared.
4. `helm upgrade otel-demo` (same chart, same values) to reconcile every remaining
   Helm-templated field (env vars, commands, images, readiness probes, dnsPolicy, node
   selectors, affinity rules, service selectors/ports, HPA targets, the `flagd-config`
   ConfigMap) back to its pristine spec in one shot — first attempt failed because it ran
   *while* the quota was still blocking new pods; succeeded once the quota was gone.
5. Verified clean systematically, not just by symptom: full pod/deployment health,
   `NetworkPolicy`/`ResourceQuota`/`PriorityClass` sweep across the namespace, node cordon
   state, PVCs, ephemeral containers, and (double-checked against the chart's own rendered
   `helm template` output, not intuition) confirmed `valkey-cart`'s `20Mi` memory limit is
   the chart's actual intended default, not a leftover fault artifact.

Final state: every otel-demo pod `1/1 Running`, every deployment `DESIRED=READY=AVAILABLE`,
zero fault-related resources remaining anywhere on the cluster.

**Driver fixed** (`.tmp/mass-execution/driver.py`, untracked but documented here): cleanup
now polls the `ChaosEngine`'s own `status.engineStatus` and waits for it to report
`completed`/`stopped` (bounded by `duration + 120s`, then deletes anyway rather than
hanging forever, logging a warning if that timeout is hit) before deleting anything.


## 13. First full Phase 0-4 certification report — 5 real bugs found and fixed, none worked around

After the mass execution (§12) completed, the user asked to stop the Phase 0+1 batch
(114/137 runs still pending — deliberately left for later, not lost) and instead generate
**one complete certification report** (Phase 0 → 1 → 2 → 3 → 4, including the PDF) for a
single SRE scenario: `chaos-mesh-pod-failure-replacement`, using all 5 of its mass-execution
runs. This was the **first time this session that Phase 3 (narrative synthesis) and
Phase 4 (assembly + PDF) had ever been exercised against the real local open-weight
stack** — every earlier validation in this effort stopped at Phase 0+1 (`--skip-cert`) or
Phase 2. That gap in coverage is exactly why 5 more real, previously-latent bugs surfaced
here, all fixed:

### 13.1 `cert_builder`'s own Azure OpenAI client was still pointed at the `.env.example` placeholder

`certifier/cert_builder/scripts/narratives/llm_client.py`'s `get_client()` built an
`openai.AzureOpenAI` client from `AZURE_OPENAI_ENDPOINT`/`AZURE_OPENAI_API_KEY`, unconditionally.
The repo-root `.env`'s `AZURE_OPENAI_ENDPOINT` was still the unfilled `.env.example` placeholder
(`https://YOUR_RESOURCE.openai.azure.com/`) — nobody had pointed it at the local stack, because
this was the first time any code path reading it had actually been run. Every one of Phase 3's
6 narrative-builder LLM calls (`scope_narrative`, `key_findings`, `qualitative`, `fault_analysis`,
`limitations`, `fairness_score`) plus the 7th sequential one (`recommendations`) failed fast with
`LLM call failed after 3 attempts: Connection error.` (a real DNS/connection failure to a
non-existent hostname, not a timeout — confirmed by how fast the whole 6-way concurrent batch
"completed": 15.1s, far too fast for 6 real generations).

Phase 0-2 never hit this because they use a *different*, older client
(`utils/azure_openai_util.py`'s `AzureLLMClient`, despite the name) that already has an
`"openai_compatible"` provider branch pointed at Ollama directly
(`configs/configs.json`'s `"gpt-4o"`/`"gpt-5.2"` entries: `base_url: http://127.0.0.1:11434/v1`,
`api_key: "ollama"`, `model_id: "qwen2.5:7b-instruct"`). `cert_builder`'s Phase 3 client was
written independently and never got the same treatment.

**Fix:** `get_client()` now falls back to a plain `openai.OpenAI` client against
`http://127.0.0.1:11434/v1` (same working endpoint) whenever `AZURE_OPENAI_ENDPOINT` is unset or
still contains the placeholder string `"YOUR_RESOURCE"`, and `call_llm()`'s deployment-name
default switches accordingly (`isinstance(client, AzureOpenAI)` check) so it asks Ollama for its
real model name (`qwen2.5:7b-instruct`) rather than the Azure deployment alias (`gpt-4o`).
Verified with a direct smoke test (structured-output schema call, real 113-token completion)
before re-running the full pipeline.

### 13.2 The pipeline's own defensive fallback was itself malformed (`KeyError: 'limitation'`)

`main/services/pipeline_service.py`'s `_SafeCertificationPipeline` monkey-patches
`NarrativeAssembler.assemble()` to inject a generic placeholder (`_NARRATIVE_FALLBACKS`) for any
narrative key missing after an LLM failure — exactly the scenario 13.1 triggered for real. But
the placeholder for `limitations_enriched`/`recommendations_enriched` was shaped
`{"severity", "headline", "detail"}`, while `report_assembler.py`'s `_section_limitations()` /
`_section_recommendations()` read `item["limitation"]` / `item["recommendation"]` (plus
`category`/`label`/`frequency`/`priority`). So the *safety net meant to prevent a crash* crashed
instead, with `KeyError: 'limitation'` inside `_section_limitations`, killing Phase 4 Assembly.
Fixed by reshaping both fallback entries to match what the assembler actually reads.

### 13.3 Missing `reportlab` dependency

Once 13.1 and 13.2 were fixed, Phase 4 Assembly succeeded but PDF rendering failed outright:
`ERROR: reportlab is required. pip install --user reportlab` — never added to
`certifier/requirements.txt` because PDF rendering, like Phase 3, had never actually been run
this session. Installed into `.venv-certifier` and added to `requirements.txt`.

### 13.4 PDF renderer crashed on `header: None`

With `reportlab` installed, PDF rendering still failed: `'NoneType' object has no attribute
'get'`. `report_assembler.py`'s `_build_header()` deliberately returns `None` now (a prior,
intentional change — the old Section 3 scorecard/findings content was folded into Section 1,
§1.3 Experiment Findings), but `scripts/render_certification_pdf.py`'s `render()` still did
`header = cert.get("header", {})` — `.get()`'s default only covers a *missing* key, not an
explicit `null`, so `header` was `None`, and `_scorecard(header, ...)` crashed on `header.get(...)`.
Fixed with `header = cert.get("header") or {}`; both `_scorecard`/`_key_findings` already
handle an empty dict gracefully (return `[]`), so this is a no-op now that the content lives in
Section 1, not a hack.

### 13.5 `total_runs: 0` and `runs_per_fault_configured: 0` in every report — two separate bugs

Once the report generated cleanly end-to-end, its own header data was visibly wrong: "Total
Runs: 0" and "Runs / fault: 0" despite 5 real runs. Traced through the full chain
(`fault_bucketing.py` → per-run `*_metrics.json` → `aggregator/scripts/aggregation.py` →
`report_assembler.py`'s `_build_meta()`):

- **`run_id` extraction typo.** `fault_analyzer/scripts/fault_bucketing.py`'s
  `_extract_agent_metadata()` searched each trace event's metadata for
  `d.get("run_id") or d.get("experiment.run_id")` (dotted, matching the OTel-attribute-style
  convention used for `"experiment.id"`) — but the real key LiteLLM's Langfuse integration
  writes is `experiment_run_id` (underscored), confirmed directly from a raw trace event:
  `metadata.requester_metadata.trace_metadata.experiment_run_id`. So `run_id` was `None` for
  every single run, all along — this bug predates this session's certifier metadata fixes
  (§5/§12.3) and was simply never exercised until a real `total_runs` count was needed.
  Fixed the typo to `d.get("experiment_run_id")`.
- **Missing `runs_per_fault` field.** Separately, `aggregator/scripts/aggregation.py`'s
  `assemble_final_scorecard()` accepted a `runs_per_fault` parameter (docstring: "configured/
  expected runs per fault (display only)") but never actually included it in its returned dict —
  a plain omission. Added `"runs_per_fault": runs_per_fault` to the return value.
- After both fixes, reprocessed Phase 0+1 for all 5 runs. This left one operational gotcha
  worth recording: because `run_id` went from `None`/falsy to a real value, the per-run metrics
  filename (`f"{fault_id}_{run_id}_metrics.json"` vs. the old falsy-run_id fallback
  `f"{fault_id}_metrics.json"`) *changed*, leaving the **old, stale, run_id=None file
  side-by-side with the new one** — since Phase 2's `DirectoryQueryService` globs
  `**/*metrics.json`, this would have silently double-counted every run in aggregation had the
  stale files not been deleted by hand before re-aggregating. Verified `total_runs: 5`,
  `successful_runs: 5`, `runs_per_fault_configured: 5` in the final report.

### 13.6 Result

Final `certification.json` + `certification.pdf` (19 pages) for `chaos-mesh-pod-failure-replacement`
generated cleanly: all 7 narrative builders produced real LLM content (not fallback stubs, not
0-token placeholders), Phase 4 assembled without error, and the report's own metadata is now
accurate. This is the first fully-real, fully-verified Phase 0-4 certification report produced
in this project against the open-weight local stack.


## 14. First real CISO certification report — genuine Phase 2-4 integration, 2 more bugs found

With the SRE report (§13) done, the user asked for one CISO scenario report too. This had
**never been done before** — earlier work in this effort (§8) only ran the CISO Agent
standalone via `make evaluate` and confirmed a real PASS result; there was no wiring from that
result into the certifier pipeline. Research (via a dedicated investigation) confirmed the
integration seam already existed but had never been exercised:

- `certifier/metrics_extractor/scripts/ciso_metrics_adapter.py`'s `build_ciso_metrics_doc()`
  adapts ITBench's own CISO evaluation output (`{"pass": bool, "tasks": {...}}` etc.) into a
  per-run metrics doc.
- `certifier/configs/fault_categories.json` already declares a `ciso_fault` bucket with the 4
  real ITBench CISO scenario types.
- `main/services/pipeline_service.py` already has explicit `ciso_fault`-aware logic (only adds
  a "CISO not implemented" note to the report when `include_ciso_finops=True` **and** no real
  `ciso_fault` docs were actually supplied — i.e. it was already designed to do the right thing
  once real data showed up).
- The CISO agent traces via `langtrace`, not Langfuse, so `run_certification.py`'s
  `--trace-id`/Langfuse-based resolution doesn't apply; the correct entry point for a
  trace-less category is `main/cli/run_aggregation_and_certification_pipeline.py
  --metrics-dir <dir> --include-ciso-finops`, which starts directly at Phase 2.

**Path taken:** fed the real, already-captured `.tmp/ciso-agent-trial/scenario-workdir/evaluation.json`
(`{"pass": true, "tasks": {"generate_assessment_posture": true, "generate_policy": false,
"evidence_available": false}}` — a genuine result from the earlier CISO Agent trial, run
`ciso-trial-run-1`) through `build_ciso_metrics_doc(scenario_type="Gen-CIS-b-K8s-Kyverno", ...)`,
then Phase 2+3+4 via the CLI above. Two more real bugs surfaced and were fixed:

### 14.1 `ciso_metrics_adapter.py` nested `agent_id`/`agent_name` under the wrong key

`build_ciso_metrics_doc()`'s docstring explicitly promises output in "the same per-run doc
shape ... every other category's per-run metrics doc uses" — but it nested identity fields
under `doc["agent"]["agent_id"]`/`doc["agent"]["agent_name"]`, while every other category (and
`aggregator/scripts/aggregation.py`'s own `_extract_agent_id()`/`_extract_agent_name()`) only
ever check `doc["agent_id"]` / `doc["quantitative"]["agent_id"]` (top-level or nested under
`quantitative`, never under `agent`). Left as-is, `query_runs_by_agent(agent_id=...)` would never
find a single CISO doc — the exact same class of key-path mismatch bug as §5/§12.3/§13.5, in
code that (per a repo-wide search) had no test coverage and had simply never been run
end-to-end before. Fixed by moving `agent_id`/`agent_name`/`agent_version` to the top level of
the returned dict, matching every other category.

### 14.2 Three of seven Phase 3 narrative builders assume SRE-only fields — correctly fell back, not fixed further

`key_findings`, `qualitative`, and `limitations` all read `fault_detection_success_rate` (a
detect/mitigate concept meaningful for fault-injection scenarios, not for CISO's pass/fail
compliance checks) and threw `KeyError: 'fault_detection_success_rate'` for the `ciso_fault`
category. This is an honest semantic gap, not a bug to silently paper over: CISO tasks don't
have a "detection rate." Each failure was caught by `NarrativeAssembler`'s per-builder
`_safe_call` wrapper and correctly replaced by `_SafeCertificationPipeline`'s
`_NARRATIVE_FALLBACKS` safety net (validated as *correctly shaped* thanks to the §13.2 fix, so
this degraded gracefully instead of crashing Phase 4 the way it would have before that fix).
The other 4 builders (`scope_narrative`, `fault_analysis`, `fairness_score`, `recommendations`)
produced real, CISO-appropriate content. **Not fixed further** — writing CISO-aware
detect/mitigate-free narrative templates for those 3 builders is a real scope-of-work item
(building actual CISO narrative support), not a bug fix, and wasn't part of what was asked.
Recorded here as known, real, follow-on work.

### 14.3 PDF renderer was silently dropping most of both reports' content — a pre-existing, wide gap

While generating the CISO PDF, `pdftotext` on the output showed several `(unrendered block:
scope_stats)`-style placeholder lines. Checking the **already-shipped SRE PDF** (§13) found the
exact same gap, at much larger scale — `scripts/render_certification_pdf.py`'s `_DISPATCH` table
only had handlers for 7 of the 14 block types `report_assembler.py` actually emits. Missing:
`scope_stats` (the cover-page stat grid), `notice` (the sample-size warning banner),
`part_banner` (the Part I/II/III/IV section dividers), `interpretation_scale` (score-band
legends), `category_panel` (the whole per-fault-category narrative panel — agent summary,
reasoning quality, safety, etc.), and **`enumerated_item`** — the type used for every single
numbered item in the Limitations and Recommendations sections. In practice this meant both
PDFs' entire Limitations/Recommendations sections, all Part banners, and the per-category
narrative panels were rendering as a bare one-line placeholder instead of their real content —
a large, real defect affecting every certification PDF this pipeline has ever produced, not
something introduced by this session's other fixes. Root cause: PDF rendering (like Phase 3
narratives, §13.1) had simply never been exercised end-to-end before this session, so gaps
in `render_certification_pdf.py` had never been caught.

Fixed by implementing all 6 missing renderers (`_render_scope_stats`, `_render_notice`,
`_render_part_banner`, `_render_interpretation_scale`, `_render_category_panel`,
`_render_enumerated_item`) matching each block's real shape (confirmed against actual
`certification.json` output, not guessed), and registering them in `_DISPATCH`. Verified via
`pdftotext` that both the SRE and CISO PDFs are now fully clean — zero `(unrendered block: ...)`
lines — and spot-checked that a real Limitations item renders correctly (severity chip, scope
heading, full body text, frequency/tags footer).

### 14.4 Result

`.tmp/ciso-agent-trial/certifier-output/cert-builder/certification.{json,pdf}` — a genuine,
19-page CISO certification report for `Gen-CIS-b-K8s-Kyverno` (1 real run, `ciso_task_passed:
true`, RAI score 83.3/PASS), the first CISO report ever produced by this pipeline, alongside a
regenerated, now fully-rendered SRE PDF (20 pages, up from 19 once `part_banner` and
`scope_stats` blocks started rendering).

**Caveat worth flagging explicitly**: the source evaluation (`evaluation.json`) has top-level
`"pass": true` but two of its three sub-tasks are individually `false`
(`generate_policy`/`evidence_available`) — `build_ciso_metrics_doc()` takes ITBench's own
top-level `pass` field at face value (this is ITBench's own scoring convention, not something
this integration changed), so the report's `ciso_task_pass_rate: 1.0` reflects that top-level
verdict, not a task-by-task breakdown. Worth knowing when reading the report's RAI PASS
verdict at face value.
