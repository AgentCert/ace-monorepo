---
title: "MCP Infrastructure"
parent: "Control Plane"
grand_parent: "Deep Dive"
nav_order: 6
---

# MCP Infrastructure

Stage 4 of the per-namespace install brings up the **MCP (Model Context Protocol)
servers** that the AI agents under test talk to. These servers are the bridge
between LLM-driven reasoning and live Kubernetes / Prometheus state — agents like
[`flash-agent`](../../flash-agent/) consume their tool catalogues via JSON-RPC 2.0
and never call the Kubernetes API or PromQL directly.

This document covers what the subscriber installs in stage 4, how the placeholders
are filled in, and how agents discover the result.

Manifest: [`chaoscenter/graphql/server/manifests/namespace/4b_mcp_tools_deployment.yaml`](../chaoscenter/graphql/server/manifests/namespace/4b_mcp_tools_deployment.yaml)
(172 lines).
RBAC: [`4a_mcp_tools_rbac.yaml`](../chaoscenter/graphql/server/manifests/namespace/4a_mcp_tools_rbac.yaml).

---

## What gets installed

Two `Deployment`s with matching `ClusterIP` `Service`s, plus a `ConfigMap` and a
`Secret` for the Prometheus side:

| Workload | Image | Port | Probe | Notes |
|---|---|---|---|---|
| `kubernetes-mcp-server` | `#{KUBERNETES_MCP_SERVER_IMAGE}` | `:8081` (HTTP) | `livenessProbe` GET `/healthz`, `readinessProbe` GET `/healthz` | Args: `--port 8081 --stateless`. Non-root `runAsUser: 65532`, `allowPrivilegeEscalation: false`. Resources 128/256Mi, 100/500m CPU. |
| `prometheus-mcp-server` | `#{PROMETHEUS_MCP_SERVER_IMAGE}` | `:9090` (HTTP) | TCP-socket liveness | Env pulled from `prometheus-mcp-config` ConfigMap + `prometheus-mcp-secret` Secret (the secret is a placeholder for future credential needs — currently `PLACEHOLDER=unused`). |

Both Deployments use:

- `serviceAccountName: mcp-server` / `prometheus-mcp-server` (created by stage 4a)
- `#{TOLERATIONS}` and `#{NODE_SELECTOR}` placeholder blocks the subscriber
  substitutes per-infra.

### Prometheus MCP `ConfigMap`

```yaml
PROMETHEUS_URL:                  "#{PROMETHEUS_MCP_URL}"   # set per-infra
PROMETHEUS_MCP_SERVER_TRANSPORT: "http"
PROMETHEUS_MCP_BIND_HOST:        "0.0.0.0"
PROMETHEUS_MCP_BIND_PORT:        "9090"
PROMETHEUS_REQUEST_TIMEOUT:      "30"
PROMETHEUS_URL_SSL_VERIFY:       "true"
PROMETHEUS_DISABLE_LINKS:        "false"
```

---

## Placeholder tokens

The subscriber processes the manifest with simple string substitution before
applying it to the target cluster. The relevant tokens for stage 4:

| Token | Source |
|---|---|
| `#{INFRA_NAMESPACE}` | The target namespace registered for this infra |
| `#{KUBERNETES_MCP_SERVER_IMAGE}` | Image registry value configured server-side (defaults to a published `agentcert/...` tag) |
| `#{PROMETHEUS_MCP_SERVER_IMAGE}` | Same — `agentcert/prometheus-mcp-server:latest` by default |
| `#{PROMETHEUS_MCP_URL}` | Upstream Prometheus the MCP server queries. Defaults to the Prometheus deployed by [`app-charts`](../../app-charts/)'s `sock-shop` chart |
| `#{TOLERATIONS}` | Cluster-specific scheduling tolerations |
| `#{NODE_SELECTOR}` | Cluster-specific node-selector block |

These tokens are filled in by the install code under `pkg/chaos_infrastructure`
when the subscriber writes the manifest into the target cluster.

---

## In-cluster DNS

After stage 4 applies, the agents reach the MCP servers at:

```
http://kubernetes-mcp-server.<infra-namespace>.svc.cluster.local:8081
http://prometheus-mcp-server.<infra-namespace>.svc.cluster.local:9090
```

In an experiment using the default Sock Shop scenario, that resolves to:

```
http://kubernetes-mcp-server.sock-shop.svc.cluster.local:8081/sse
http://prometheus-mcp-server.sock-shop.svc.cluster.local:9090/sse
```

(The `/sse` path is the JSON-RPC + Server-Sent-Events endpoint — see
[`flash-agent`'s `mcp/client.py`](../../flash-agent/mcp/client.py).)

---

## How agents discover the servers

The agent under test receives the MCP URLs as an env var (`MCP_URLS`) at install
time. The wiring goes:

```
AgentCert UI (operator picks agent + scenario)
     │
     ▼
GraphQL: RegisterAgent / RunExperiment   ──▶  helm install agent-charts/flash-agent
     │                                          --set agent.config.MCP_URLS=…
     ▼
Pod env:   MCP_URLS=http://kubernetes-mcp-server.sock-shop…,
                    http://prometheus-mcp-server.sock-shop…
     │
     ▼
flash-agent boots → flash_agent._discover_mcp_tools()
     │   • initialize() handshake → session ID
     │   • tools/list             → tool catalogue
     │   • discover_scope(...)    → tiered probe (see flash-agent README)
     ▼
ReAct loop calls tools via tools/call
```

The MCP client knows nothing about the host platform — only that there's a
JSON-RPC 2.0 endpoint speaking the MCP protocol over SSE. That means any future
MCP server (Cilium, Istio, AWS, observability platforms) plugs in identically.

---

## What the MCP servers actually expose

These are off-the-shelf MCP servers — the platform doesn't build them.

### `kubernetes-mcp-server`

Exposes typed tools for the Kubernetes API: pods, deployments, services, events,
namespaces, logs. Each tool's input schema declares whether a `namespace`
parameter is supported, which is what the
[flash-agent scope-discovery algorithm](../../flash-agent/README.md#mcp-scope-discovery)
keys off of when deciding "this server is namespace-scoped" vs "this server is
cluster-scoped".

Health: `GET /healthz`.

### `prometheus-mcp-server`

Exposes PromQL query tools against `PROMETHEUS_URL`. Liveness is a TCP socket
probe (not HTTP) because earlier images didn't implement an HTTP health endpoint.

---

## Authorization & least-privilege

The agents themselves run with whatever RBAC the agent chart grants. The MCP
servers are deployed with `runAsUser: 65532` (non-root, distroless-style) and
`allowPrivilegeEscalation: false`. Their `ServiceAccount`s carry only the
permissions defined in [`4a_mcp_tools_rbac.yaml`](../chaoscenter/graphql/server/manifests/namespace/4a_mcp_tools_rbac.yaml).

The agent under test is therefore confined to what the MCP servers permit —
which is what makes the [scope-discovery probe in
flash-agent](../../flash-agent/README.md#mcp-scope-discovery) useful: it lets the
agent figure out "I can only see namespace `sock-shop`" without anyone hand-
writing that into the prompt.

---

## Related docs

- [`architecture.md`](architecture.md) — where stage 4 sits in the install pipeline
- [`agent-registry.md`](agent-registry.md) — how the helm bridge wires `MCP_URLS`
- [`../../flash-agent/README.md`](../../flash-agent/README.md) — the consumer's view
- [`../../app-charts/README.md`](../../app-charts/README.md) — alternative MCP server
  deployments shipped inside the target app
