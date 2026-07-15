<div align="center">

# flash-agent

### A FLASH-style ITOps agent for Kubernetes — discovers tools, reasons, acts, reflects.

Flash Agent is a **reference AI agent** in the AgentCert platform: a single Python
process that probes a Kubernetes namespace through Model Context Protocol (MCP)
servers, runs a tool-calling LLM in a ReAct loop, produces a structured health
analysis, and (when patterns recur) reflects on its own past behaviour before the next
scan. It is the agent the platform exists to certify.

The design follows Microsoft Research's
[**FLASH — Feedback-guided Agentic Workflow**](https://www.microsoft.com/en-us/research/project/flash-a-reliable-workflow-automation-agent/)
methodology, cited directly in the source.

![Python](https://img.shields.io/badge/Python-3.12-3776AB?style=flat-square&logo=python)
![MCP](https://img.shields.io/badge/MCP-JSON--RPC%202.0%20%2B%20SSE-1C3D5A?style=flat-square)
![Loop](https://img.shields.io/badge/Loop-ReAct%20%2B%20Hindsight-EF7B4D?style=flat-square)
![FLASH](https://img.shields.io/badge/FLASH-Microsoft%20Research-7E47C5?style=flat-square)
![License](https://img.shields.io/badge/License-Apache%202.0-lightgrey?style=flat-square)

</div>

---

## Table of Contents

1. [The 4-phase FLASH pipeline](#the-4-phase-flash-pipeline)
2. [What you put in, what you get out](#what-you-put-in-what-you-get-out)
3. [Architecture](#architecture)
4. [Code layout](#code-layout)
5. [Two modes — scan and watch](#two-modes--scan-and-watch)
6. [The ReAct loop](#the-react-loop)
7. [MCP scope discovery](#mcp-scope-discovery)
8. [The scope-aware system prompt](#the-scope-aware-system-prompt)
9. [Hindsight reflection](#hindsight-reflection)
10. [In-process history](#in-process-history)
11. [Output schema](#output-schema)
12. [Configuration reference](#configuration-reference)
13. [Running locally](#running-locally)
14. [Image build & deploy](#image-build--deploy)
15. [Integration with AgentCert](#integration-with-agentcert)
16. [Related repositories](#related-repositories)
17. [License](#license)

---

## The 4-phase FLASH pipeline

Per-scan, from the docstring at the top of
[`flash_agent.py`](flash_agent.py):

| Phase | What happens |
|---|---|
| **DISCOVER** | Probe every URL in `MCP_URLS`; collect tool catalogues; merge authorization scopes across servers |
| **REASON + ACT** | Bounded ReAct loop — LLM picks a tool → agent calls it over MCP → result is streamed back into the conversation → LLM picks the next tool, until it produces a final structured analysis or the iteration cap is hit |
| **ANALYZE** | LLM emits a strict JSON object (`status_reasoning`, `thoughts`, `health`, `issues`, `insights`) describing what it found |
| **REFLECT** | If patterns suggest the agent is missing something, generate a hindsight note that is **injected into the next scan's user prompt**. No disk persistence — reflection is in-process only |

---

## What you put in, what you get out

**Input:** one Kubernetes namespace (auto-discovered or set via `AGENT_SCOPE_NAMESPACE`),
one or more MCP server URLs (`MCP_URLS`), an OpenAI-compatible endpoint
(`OPENAI_BASE_URL`), and a free-form `SCAN_QUERY`.

**Output:** a JSON document like

```jsonc
{
  "status_reasoning": { "determined_status": "degraded", "data_quality": {…}, … },
  "thoughts":         { "key_observations": [], "analysis_approach": [], "observability_gaps": [] },
  "health":           { "total_pods": 12, "healthy_pods": 10, "overall_health_score": 70 },
  "issues":           [{ "severity": "critical", "component": "…", "recommended_action": "…" }],
  "insights":         { "summary": "…", "concerns": [], "recommendations": [] },
  "_metadata":        { "scan_id": "…", "duration_sec": 31.4, "tool_calls": [], "iterations": 4 },
  "hindsight_reflection": { "generated": true, "content": "…" }
}
```

Every key is set in code — `_metadata` at
[flash_agent.py:651](flash_agent.py#L651), `hindsight_reflection` at
[flash_agent.py:659](flash_agent.py#L659).

---

## Architecture

```
              ┌──────────────────────────────────────────────────────────────┐
              │                          main.py                              │
              │   • loads AgentConfig.from_env() / validate()                 │
              │   • registers SIGTERM / SIGINT handlers (graceful shutdown)   │
              │   • dispatches to run_scan_mode() or run_watch_mode()         │
              └────────────────────────────┬─────────────────────────────────┘
                                           │
                                           ▼
   ┌──────────────────────────────────────────────────────────────────────────────┐
   │                       flash_agent.FlashAgent  (1170+ lines)                  │
   │                                                                              │
   │   public:   scan(query)                  →  _execute_scan_steps()           │
   │             establish_baseline(ns)        →  WatchBaseline                   │
   │             watch(baseline, …)            →  polling loop                    │
   │             health_check() / get_capabilities()                              │
   │                                                                              │
   │   internal: _discover_mcp_tools()         _merge_scopes()                    │
   │             _build_system_prompt()        _convert_mcp_tool_to_openai()      │
   │             _execute_mcp_tool()           _format_tool_result()              │
   │             _parse_analysis_response()    _add_to_history()                  │
   │             _get_hindsight_for_prompt()   _detect_warning_patterns()         │
   │             _collect_watch_metrics()      _detect_deviation()                │
   └────────────┬────────────────────────────────────────────────┬────────────────┘
                │                                                │
                ▼                                                ▼
   ┌──────────────────────────────┐              ┌──────────────────────────────┐
   │      llm/ — LLM glue          │              │      mcp/ — tool transport   │
   │                              │              │                              │
   │  hindsight.HindsightBuilder  │              │  client.MCPClient             │
   │   • summarize_history()      │              │   • initialize()              │
   │   • generate_hindsight_      │              │   • list_tools()              │
   │     prompt()                 │              │   • call_tool(name, args)     │
   │   • develop_hindsight()      │              │   • discover_scope(...)       │
   │   • should_generate_         │              │   • _jsonrpc_call()  (SSE)    │
   │     hindsight()              │              │                              │
   │                              │              │  client.MCPScope (dataclass)  │
   │  utils.estimate_tokens()     │              │   • kind: namespace |         │
   │  utils.trim_history_to_      │              │     namespaces | cluster |    │
   │    token_limit(max=90000)    │              │     agnostic | unknown        │
   │  utils.format_analysis_for_  │              │                              │
   │    history()                 │              │  ~12 helper fns for           │
   │  utils.create_history_       │              │  introspection / probing /    │
   │    entry()                   │              │  validation                   │
   └──────────────────────────────┘              └──────────────────────────────┘
```

---

## Code layout

```
flash-agent/
├── main.py                 # 177 lines — entry point, mode dispatch, signal handlers
├── flash_agent.py          # 1173 lines — FlashAgent class + system prompt builders
├── config.py               #  84 lines — AgentConfig dataclass + .env / .env.local loader
├── llm/
│   ├── hindsight.py        # 326 lines — HindsightBuilder + reflection prompt
│   └── utils.py            # 227 lines — token estimation, history shaping, JSON parsing
├── mcp/
│   └── client.py           # MCPClient (JSON-RPC 2.0 + SSE) + MCPScope + scope discovery
├── Dockerfile              # Two-stage python:3.12-slim, non-root agent:1000
├── Makefile                # build / push / build-push / tag / kind-load / run / clean
├── build-flash-agent.sh    # CI: monorepo .env sync, timestamped tag, minikube load
├── requirements.txt        # kubernetes, openai, requests, python-dotenv
├── FUNCTIONING.md          # Behavioural spec (may lag code — verify against source)
├── LICENSE
└── README.md
```

---

## Two modes — scan and watch

Mode is picked at startup by [main.py:35](main.py#L35) from the `WATCH_MODE` env var.

### Scan mode (default)

Quoted from [main.py:110–148](main.py#L110-L148):

1. Run `agent.scan(cfg.scan_query)`.
2. If no unresolved issues (`severity in {critical, warning}`), exit cleanly.
3. Otherwise sleep `RESCAN_DELAY` seconds (default 30) and re-scan.
4. Cap at `MAX_ITERATIONS` (default 10) total scan cycles.
5. `SIGTERM` / `SIGINT` breaks the loop between cycles within 1 s granularity.

Each call to `scan()` runs the full DISCOVER → REASON+ACT → ANALYZE → REFLECT pipeline.

### Watch mode (`WATCH_MODE=true`)

Quoted from [main.py:69–107](main.py#L69-L107):

1. **Establish baseline** — `agent.establish_baseline(namespace)` calls the LLM **once**
   to pick a minimal set of watch tools + healthy thresholds. Returns a `WatchBaseline`
   dataclass (`namespace`, `watch_tools`, `healthy_thresholds`, `baseline_metrics`).
2. **Poll** — `agent.watch(baseline, poll_interval=WATCH_INTERVAL, …)` runs the watch
   tools every `WATCH_INTERVAL` seconds (default 5.0) **without the LLM in the hot
   path**.
3. **Escalate** — when a threshold is breached, the agent can re-invoke the full scan
   pipeline (caller-injected callback).

Watch mode is the cost-aware path for long-running monitoring; scan mode is the
deep-reasoning path for incident response.

---

## The ReAct loop

The heart of the agent. Quoted from `_execute_scan_steps`,
[flash_agent.py:534+](flash_agent.py#L534) — the loop runs until either the LLM emits a
parseable final analysis or `MAX_TOOL_ITERATIONS` (default 10) is reached:

```python
while iteration < MAX_TOOL_ITERATIONS:
    iteration += 1
    response = client.chat.completions.create(
        model=self.cfg.model_alias,
        messages=messages,
        tools=openai_tools,
        tool_choice="auto",
        temperature=0.1,
    )
    assistant_message = response.choices[0].message

    if assistant_message.tool_calls:
        # Step 1: append the assistant message (including tool_calls) to the convo
        messages.append({"role": "assistant", "content": …, "tool_calls": […]})

        # Step 2: execute each tool call against MCP, append result as a tool message
        for tool_call in assistant_message.tool_calls:
            tool_args = json.loads(tool_call.function.arguments)
            result    = self._execute_mcp_tool(mcp_clients, tool_call.function.name, tool_args)
            result_text = _format_tool_result(tool_call.function.name, result)  # truncated to 8 KB
            messages.append({"role": "tool", "tool_call_id": tool_call.id, "content": result_text})
    else:
        # No tool calls → LLM is trying to produce final analysis
        analysis = self._parse_analysis_response(assistant_message.content)
        break
```

A few implementation details worth knowing:

- **MCP tools are exposed to the LLM in OpenAI function-call shape** via
  `_convert_mcp_tool_to_openai()`. The LLM never sees the JSON-RPC envelope directly.
- **Tool output is truncated to 8 KB** per call in `_format_tool_result()` to bound the
  context budget.
- **If the LLM emits free-form text instead of JSON**, the agent asks it once to
  reformat — quoted from [flash_agent.py:612](flash_agent.py#L612):
  > *"Please provide your analysis as a valid JSON object matching the required
  > schema."*
- **`MAX_ITERATIONS` (main.py) is the outer cap**; **`MAX_TOOL_ITERATIONS` (flash_agent.py
  line 48) is the per-scan ReAct cap.** They are independent.

---

## MCP scope discovery

Flash Agent never assumes which Kubernetes namespace a given MCP server is allowed to
see. It discovers it. The algorithm lives in
[`mcp/client.py:discover_scope`](mcp/client.py) and uses a four-tier fallback strategy:

| Tier | What it tries | If success |
|---|---|---|
| **0 — explicit override** | If `AGENT_SCOPE_NAMESPACE` is set, take it | `MCPScope(kind="namespace", source="explicit")` |
| **1 — schema check** | Does any tool's input schema declare a `namespace` parameter? | If not → `MCPScope(kind="agnostic")` (e.g. a pure Prometheus MCP) |
| **1b — introspection** | Find a tool whose name matches `configuration\|context\|whoami\|server_info` and call it with no args; parse the namespace from the response | candidate added |
| **2 — probe** | Call a tool with no required args. Success → `MCPScope(kind="cluster")`. Forbidden → mine the SA home namespace from `system:serviceaccount:<ns>:` in the error | candidate added |
| **3 — validate** | For each candidate, call a namespace-required read tool with `{"namespace": ns}`. Keep only the namespaces that work | `MCPScope(kind="namespace" \| "namespaces", source="probe")` |

Across multiple MCP servers, scopes are merged by `_merge_scopes()` in
[flash_agent.py:669–701](flash_agent.py#L669-L701) with these rules:

- **Drop `agnostic` scopes** — they don't constrain.
- **`unknown` everywhere → `unknown`** (the agent says so honestly in the system
  prompt).
- **Any concrete namespace scope wins** — the union is taken, and `least-privilege wins
  over any cluster-wide peer`.
- **Otherwise → `cluster`.**

The result is then fed into the system prompt builder, which renders **scope-aware**
instructions to the LLM.

---

## The scope-aware system prompt

`_build_system_prompt(scope)` (flash_agent.py) assembles the system prompt from
purpose-built blocks. Quoted from
[flash_agent.py:509–524](flash_agent.py#L509-L524), the user prompt itself is also
scope-aware:

```python
if merged_scope.kind == "namespace" and merged_scope.namespaces:
    user_prompt = (f"Analyze the health of namespace `{merged_scope.namespaces[0]}` "
                   f"using only namespace-scoped tools. Task: {scan_query}")
elif merged_scope.kind == "namespaces" and merged_scope.namespaces:
    ns_csv = ", ".join(merged_scope.namespaces)
    user_prompt = (f"Analyze the health of namespaces [{ns_csv}] using namespace-scoped "
                   f"tools (always pass an explicit `namespace=`). Task: {scan_query}")
elif merged_scope.kind == "cluster":
    user_prompt = f"Analyze the Kubernetes cluster health. Task: {scan_query}"
else:
    user_prompt = f"Analyze the Kubernetes namespace health. Task: {scan_query}"
```

The system prompt describes **tool shapes**, not tool names — so the agent stays
portable across MCP implementations (kubernetes-mcp-server, k8s_open_api,
mcp-go-kubernetes, …).

---

## Hindsight reflection

When the same warning pattern recurs across scans, the agent asks itself: *what did I
miss?* The reflection is generated by
[`llm/hindsight.HindsightBuilder.develop_hindsight()`](llm/hindsight.py) at temperature
0.3 with an output cap of ~800 tokens, then injected verbatim into the **next** scan's
user prompt — see [flash_agent.py:525–526](flash_agent.py#L525-L526):

```python
if hindsight:
    user_prompt = f"{user_prompt}\n\nHINDSIGHT FROM PREVIOUS ANALYSIS:\n{hindsight}"
```

Triggers (from `HindsightBuilder.should_generate_hindsight()` plus
`_detect_warning_patterns()` in `flash_agent.py`): overall health score below a threshold,
critical issues present, or ≥ 2 of the last 3 history entries contain error/warning
keywords.

**Memory model:** hindsight is held in `self._last_hindsight` (a Python attribute).
**It is not persisted**. When the pod restarts, all reflection is lost — by design.
Cross-restart memory belongs to Langfuse + the certifier, not to the agent.

---

## In-process history

The agent maintains a **bounded FIFO history of condensed scan summaries** — see the
`MAX_HISTORY_SIZE` constant in `flash_agent.py`. Each scan appends two entries (one
`user` query, one `assistant` analysis summary). `format_analysis_for_history()` in
`llm/utils.py` compresses the analysis to roughly ~1.5 KB — health snapshot + top
issues — to keep the buffer small enough to feed back into the hindsight LLM call.

When the hindsight LLM is invoked, `trim_history_to_token_limit(max_tokens=90000)`
defensively trims the buffer from the oldest entry forward (token estimate is a simple
`len(text) // 4` heuristic in [`llm/utils.py:19–32`](llm/utils.py#L19-L32) — not
tiktoken, intentionally conservative).

---

## Output schema

The system prompt instructs the LLM to return JSON matching this shape (lifted from
[flash_agent.py:60–108](flash_agent.py#L60-L108)):

```jsonc
{
  "status_reasoning": {
    "determined_status":  "healthy | degraded | critical | unknown",
    "status_justification": ["reason 1", "reason 2"],
    "data_quality": {
      "completeness":       "complete | partial | insufficient",
      "gaps":               ["metrics_unavailable", "logs_unavailable"],
      "confidence_impact":  "Health score capped due to missing observability"
    }
  },
  "thoughts": {
    "key_observations":     [],
    "analysis_approach":    [],
    "observability_gaps":   ["List any tools that failed"]
  },
  "health": {
    "total_pods":   0,
    "healthy_pods": 0,
    "unhealthy_pods": 0,
    "error_count":  0,
    "warning_count": 0,
    "overall_health_score": 0
  },
  "issues": [
    {
      "severity":           "critical | warning | info",
      "component":          "component-name",
      "category":           "category",
      "summary":            "what went wrong",
      "recommended_action": "concrete remediation step"
    }
  ],
  "insights": {
    "summary":                          "overall narrative",
    "concerns":                         [],
    "recommendations":                  [],
    "observability_recommendations":    ["Deploy metrics-server"]
  }
}
```

After the LLM returns, two more keys are stamped by the agent:

- **`_metadata`** — `scan_id`, `duration_sec`, `tool_calls` (ordered list), `iterations`.
  Set at [flash_agent.py:651](flash_agent.py#L651).
- **`hindsight_reflection`** — `{generated: bool, content?: str}`. Set at
  [flash_agent.py:659](flash_agent.py#L659).

The prompt closes with an explicit operational instruction
([flash_agent.py:105–108](flash_agent.py#L105-L108)):
> *"For every issue in the `issues` array, `recommended_action` must be concrete,
> operational, and fix-oriented. Do not stop at diagnosis."*

---

## Configuration reference

All settings flow through environment variables (loaded from `.env.local` if present,
otherwise `.env`, otherwise the process environment).

### Read by `AgentConfig.from_env()` ([config.py](config.py))

| Variable | Default | Required | Description |
|---|---|---|---|
| `AGENT_NAME` | `flash-agent` | no | Identifier embedded in `scan_id` and logs |
| `OPENAI_BASE_URL` | *(empty)* | **yes** | OpenAI-compatible endpoint. Auto-detects Azure when URL contains `.openai.azure.com` |
| `OPENAI_API_KEY` | *(empty)* | yes | API key sent to the proxy |
| `MODEL_ALIAS` | *(empty)* | **yes** | Model name (e.g. `gpt-4o`, `gemini-3-flash`) |
| `AZURE_API_VERSION` | `2025-04-01-preview` | no | Used only when Azure endpoint detected |
| `MCP_URLS` | *(empty)* | **yes** | Comma-separated MCP server URLs |
| `MCP_TIMEOUT` | `30` | no | Per-call MCP timeout (seconds) |
| `SCAN_QUERY` | *"Analyse the data from MCP tools and provide insights."* | no | User prompt the agent starts every scan with |
| `AGENT_SCOPE_NAMESPACE` | *(auto-discover)* | no | Force a namespace; skips scope discovery |

### Read by `main.py`

| Variable | Default | Description |
|---|---|---|
| `LOG_LEVEL` | `INFO` | `DEBUG / INFO / WARNING / ERROR` |
| `MAX_ITERATIONS` | `10` | Outer scan-cycle cap |
| `RESCAN_DELAY` | `30` | Seconds between scan cycles when issues remain |
| `WATCH_MODE` | `false` | `true / 1 / yes` flips to watch mode |
| `WATCH_NAMESPACE` | *(empty)* | Required in watch mode (or inferable from `SCAN_QUERY`) |
| `WATCH_INTERVAL` | `5.0` | Watch-mode poll interval (seconds) |

### Compile-time constants

- `MAX_TOOL_ITERATIONS = 10` ([flash_agent.py:48](flash_agent.py#L48)) — inner ReAct cap
- `MAX_HISTORY_SIZE` — bounded FIFO size for the history buffer
- LLM call temperature: `0.1` for analysis ([flash_agent.py:540](flash_agent.py#L540)),
  `0.3` for hindsight ([`llm/hindsight.py`](llm/hindsight.py))

---

## Running locally

```bash
# 1) Virtualenv + deps
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 2) Config
cat > .env <<'EOF'
OPENAI_BASE_URL=http://localhost:4000/v1
OPENAI_API_KEY=sk-agentcert-dev
MODEL_ALIAS=gpt-4o
MCP_URLS=http://localhost:8081/sse,http://localhost:8082/sse
AGENT_SCOPE_NAMESPACE=sock-shop
SCAN_QUERY=Analyse the sock-shop namespace and report any failing pods.
LOG_LEVEL=DEBUG
EOF

# 3) Run a single scan (then exit)
MAX_ITERATIONS=1 python main.py
```

To exercise watch mode instead:

```bash
WATCH_MODE=true WATCH_NAMESPACE=sock-shop WATCH_INTERVAL=5 python main.py
```

---

## Image build & deploy

The image is published as `agentcert/agentcert-flash-agent:latest` from a two-stage
Dockerfile (`python:3.12-slim`, non-root `agent:1000`, entrypoint `python -u main.py`).

```bash
make build                       # → agentcert/agentcert-flash-agent:latest
make build-no-cache              # full rebuild
make push                        # to registry
make build-push                  # build + push
make run                         # docker run with .env mounted
make tag NEW_TAG=v1.0.0          # retag
make version                     # echo current image/registry/tag
make clean                       # docker rmi
```

[`build-flash-agent.sh`](build-flash-agent.sh) is the CI driver: reads the monorepo
`.env`, prunes old `agentcert/agentcert-flash-agent` images, builds with a `ci-*`
timestamp tag plus `latest` + `dev`, `minikube image load`s the result, and writes
`FLASH_AGENT_IMAGE=…` back into `.env`. When a `flash-agent` Deployment or CronJob
already exists in the target cluster, it updates the image reference in place.

---

## Integration with AgentCert

```
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  AgentCert ChaosCenter (registry, UI, GraphQL, subscriber)              │
   └──────────┬──────────────────────────────────────────────────────────────┘
              │ RegisterAgent → AGENT_ID UUID
              ▼
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  install-agent (container) — helm install of ../agent-charts/flash-agent│
   │     • sets agent.config.AGENT_ID, MCP_URLS, OPENAI_BASE_URL, …          │
   └──────────┬──────────────────────────────────────────────────────────────┘
              ▼
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  Pod = flash-agent  (this repo)                                         │
   │       + agent-sidecar (../agent-sidecar)                                │
   │  Agent's OPENAI_BASE_URL points at localhost:4001/v1 (the sidecar)      │
   └──────────┬──────────────────────────────────────────────────────────────┘
              │ OpenAI /chat/completions with body
              ▼ (sidecar injects experiment_id / agent_id / trace_id)
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  LiteLLM proxy (../agentcert-stack) → Azure / Gemini / OpenAI           │
   │                                       + Langfuse callbacks               │
   └──────────┬──────────────────────────────────────────────────────────────┘
              │
              │ MCP JSON-RPC 2.0 + SSE
              ▼
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  kubernetes-mcp-server + prometheus-mcp-server                          │
   │  (deployed by AgentCert subscriber stage-4 manifests, exposed via       │
   │   app-charts to the agent under test)                                   │
   └──────────┬──────────────────────────────────────────────────────────────┘
              │
              ▼ (reads cluster state from the target SUT)
   ┌─────────────────────────────────────────────────────────────────────────┐
   │  Sock Shop  ◀── chaos faults from ../chaos-charts                       │
   └─────────────────────────────────────────────────────────────────────────┘
                                                            │
                                                            ▼
                                              ┌───────────────────────────┐
                                              │  certifier (../certifier) │
                                              │  → 12-section HTML + PDF  │
                                              └───────────────────────────┘
```

**Tracing**: Flash Agent **does not** export OTLP/Langfuse spans itself. Tracing is
fully delegated to the LiteLLM proxy that fronts every LLM call. The agent's only job
on the observability side is to emit a clean, structured analysis JSON; correlating
that to a particular chaos experiment is the sidecar's responsibility (it injects
`experiment_id` / `trace_id` into the request body before the proxy forwards it).

---

## Related repositories

| Repository | Role for flash-agent |
|---|---|
| [`AgentCert`](../AgentCert) | Registers this agent, installs it via the `install-agent` image, runs the Argo workflow that exercises it |
| [`agent-charts`](../agent-charts) | Helm chart that deploys this agent + sidecar with all the wiring |
| [`agent-sidecar`](../agent-sidecar) | Stamps experiment + agent identity onto every LLM call |
| [`agentcert-stack`](../agentcert-stack) | Runs the LiteLLM proxy this agent talks to |
| [`app-charts`](../app-charts) | Deploys the MCP servers referenced in `MCP_URLS` |
| [`chaos-charts`](../chaos-charts) | Defines the faults this agent diagnoses (and is judged against) |
| [`certifier`](../certifier) | Consumes the resulting Langfuse traces and produces the certification report |

---

## License

Apache 2.0 — see [LICENSE](LICENSE).
