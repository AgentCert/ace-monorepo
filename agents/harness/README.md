# agents/harness/

ACE-developed glue code that wraps each upstream agent so it can be benchmarked
via the ITBench agent-harness protocol without modifying the original agent repos.

---

## Harness contract

The ITBench orchestration framework drives agents through two files:

| File | Direction | Description |
|------|-----------|-------------|
| `path_to_data_provided_by_scenario` | framework → agent | JSON written by the framework before the agent starts. Contains all inputs the agent needs (goal, credentials, snapshot paths, …). |
| `path_to_data_pushed_to_scenario` | agent → framework | Tarball the agent must produce before it exits. The framework reads it to extract results. |

The `run` stanza in `agent-harness.yaml` tells the framework how to launch the agent
(`command` + `args`, executed with the harness directory as the working directory).

---

## Quick start

```bash
# 1. Install dependencies for a specific agent (one-time, per machine)
bash agents/harness/<agent>/setup.sh

# 2. Point the ITBench framework at the harness directory
#    The framework writes scenario_data.json, runs agent-harness.yaml, reads the tar.
```

---

## Adding a new agent — the A2A/MCP path

Any agent that speaks the **A2A protocol** (Google Agent-to-Agent, JSON-RPC 2.0)
and connects to tools via **MCP** can be benchmarked without touching the
certifier, the metrics extractor, or the fault categories.  Only two things
are needed **on the agent's side**:

1. Expose an A2A-compatible HTTP server:
   - `GET  /.well-known/agent.json` — Agent Card describing capabilities.
   - `POST /` — JSON-RPC 2.0 endpoint accepting `tasks/send` and `tasks/get`.
2. Read `MCP_URLS`, `OPENAI_BASE_URL`, and `MODEL_ALIAS` from either the
   structured task `metadata` field or the text preamble of the user message,
   and use them to connect to MCP tool servers and the ACE LiteLLM proxy.
   Routing LLM calls through `OPENAI_BASE_URL` is required so the ACE sidecar
   can capture Langfuse traces for the certifier.

Point the ITBench framework at `agents/harness/a2a-mcp-agent/` and provide the
universal `scenario_data.json` schema below — no agent-specific harness file
is needed.

### Universal scenario_data.json schema (A2A/MCP agents)

Schema version: **1.0**

```json
{
  "version":          "1.0",
  "a2a_endpoint":     "http://<agent-host>:<port>",
  "goal":             "Analyse Kubernetes cluster health and report all detected faults.",
  "mcp_urls":         "http://kubernetes-mcp:8081/mcp,http://prometheus-mcp:8083/mcp",
  "openai_base_url":  "http://litellm-proxy:4000/v1",
  "model_alias":      "gpt-4o",
  "timeout_seconds":  300
}
```

| Field             | Required | Description |
|-------------------|----------|-------------|
| `version`         | yes      | Schema version; currently `"1.0"`. |
| `a2a_endpoint`    | yes      | Base URL of the agent's A2A server (no trailing slash). The bridge appends `/.well-known/agent.json` for the Agent Card and `/` for JSON-RPC calls. |
| `goal`            | yes      | Natural-language task description. Delivered verbatim as the `text` part of the A2A user message. |
| `mcp_urls`        | no       | Comma-separated list of MCP server SSE/HTTP endpoints the agent should use for tool access. |
| `openai_base_url` | no       | LiteLLM proxy URL. The agent must route its LLM calls here so ACE can capture Langfuse traces for certification. |
| `model_alias`     | no       | Model name/alias the agent should use (must exist in the LiteLLM proxy config). |
| `timeout_seconds` | no       | How long the bridge waits for task completion before timing out (default: 300). |

The bridge also passes `mcp_urls`, `openai_base_url`, and `model_alias` in the
task's structured `metadata` field for agents that parse `params.metadata`
rather than reading the text preamble.

---

## scenario_data.json schemas

### ciso-agent

```json
{
  "goal_template": "Check that <condition> is satisfied …\nThe cluster kubeconfig is at {{ kubeconfig }}.",
  "vars": {
    "kubeconfig":        "<base64-encoded kubeconfig YAML or file path>",
    "ansible_ini":       "<ansible inventory INI content>",
    "ansible_user_key":  "<SSH private key PEM>"
  }
}
```

### sre-agent

```json
{
  "snapshot_dirs":  "/path/to/ITBench-Lite/snapshots/sre/v0.2-.../Scenario-N",
  "model":          "openai/gpt-4o-mini",
  "prompt_file":    "sre_react_shell_investigation.md",
  "goal_template":  "Start the investigation"
}
```

`snapshot_dirs` can be a colon-separated list of multiple snapshot directories.
`prompt_file` must be a filename (not a full path) from
`agents/sre-agent/zero/zero-config/prompts/`.

### flash-agent

```json
{
  "mcp_urls":       "http://kubernetes-mcp:8081/mcp",
  "model_alias":    "gpt-4o",
  "openai_base_url": "http://litellm:4000/v1",
  "scan_query":     "Analyse Kubernetes cluster health and report all issues"
}
```

---

## Directory layout

```
harness/
  a2a-mcp-agent/
    agent-harness.yaml   ← universal ITBench entry-point for any A2A/MCP agent
    a2a_bridge.py        ← A2A client: reads scenario_data.json, drives agent, packages result
    setup.sh             ← pip-installs httpx + tenacity into .venv/
  ciso-agent/
    agent-harness.yaml   ← ITBench harness entry-point
    setup.sh             ← installs deps into agents/ciso-agent/.venv/
  sre-agent/
    agent-harness.yaml
    setup.sh             ← runs `uv sync` in agents/sre-agent/
  flash-agent/
    agent-harness.yaml
    setup.sh             ← pip-installs into agents/flash-agent/.venv/
```
