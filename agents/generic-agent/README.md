# Generic Agent

An MCP-driven Kubernetes analysis agent, onboarded into ACE as a **new,
self-contained agent** — its own image, its own Helm chart, its own AgentHub
entry. It shares no build artefact, image tag or chart with any other agent in
this repo.

## What it does

Per scan: discover MCP tools → ReAct tool-calling loop → structured JSON
analysis → hindsight reflection carried into the next scan.

## The ACE contract

The agent reads **only** environment variables. It has no awareness of Argo,
Helm, Langfuse or experiment IDs — the `agent-sidecar` injects all of that into
the LLM traffic transparently.

| Variable | Required | Meaning |
|---|---|---|
| `OPENAI_BASE_URL` | yes | OpenAI-compatible endpoint. Points at the sidecar in-cluster. |
| `MODEL_ALIAS` | yes | Model name routed by LiteLLM |
| `MCP_URLS` | yes | Comma-separated MCP server URLs |
| `OPENAI_API_KEY` | no | From the chart Secret |
| `MCP_TIMEOUT` | no | Per-call MCP timeout, default 30 |
| `AGENT_SCOPE_NAMESPACE` | no | Pin the namespace; empty = auto-discover from MCP |
| `SCAN_QUERY` | no | The task text |
| `AGENT_NAME` | no | Defaults to `generic-agent` |

Agent-private knobs (`SCAN_INTERVAL`, `MAX_ITERATIONS`, `RESCAN_DELAY`,
`WATCH_MODE`, `LOG_LEVEL`, `LLM_REQUEST_TIMEOUT`, `LLM_MAX_RETRIES`) are set in
the chart, never by the ACE control plane.

> Hardcoding an LLM endpoint anywhere in the agent breaks certification: the
> traces never reach Langfuse and the certifier has nothing to score.

## Layout

```
agents/generic-agent/
├── main.py            entry point, scan/watch loops
├── config.py          the ACE env contract
├── agent_core.py      GenericAgent reasoning core
├── mcp/client.py      MCP client + scope discovery
├── llm/               hindsight + history helpers
├── Dockerfile         non-root uid 1000
├── build-generic-agent.sh
└── Makefile
```

## Build

```bash
./build-generic-agent.sh          # build + kind load
./build-generic-agent.sh --push   # build + docker push
```

Image: `agentcert/generic-agent:v1.0.0`

## Run locally

```bash
cp .env.example .env    # edit endpoints
pip install -r requirements.txt
python -u main.py
```

## Deploy

Chart lives at `agent-charts/charts/generic-agent/`.

```bash
make install NAMESPACE=sock-shop
make logs
```

In a certification run the chart is installed by the `install-agent` Argo step,
not by hand — see `onboarding-guides/02-onboard-agent.md`.
