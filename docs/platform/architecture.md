---
title: "Platform Architecture"
parent: "Control Plane"
grand_parent: "Deep Dive"
nav_order: 1
---

# Architecture

AgentCert is the **control plane** of the AgentCert platform. It owns the UI, the
GraphQL API, three registries (agents, apps, fault studios), the in-cluster
subscriber, and the Langfuse-tracing layer that correlates everything together. This
document is the reader's map: it lists every component, names every port and image,
and shows how the pieces wire together in both a single-cluster local setup and a
multi-cluster production deployment.

---

## Component map

```
┌────────────────────────────────────────────────────────────────────────────────────┐
│                         AgentCert Control Plane                                    │
│                                                                                    │
│  ┌──────────────┐    ┌──────────────────────┐    ┌────────────────────┐           │
│  │  Web (React) │    │    GraphQL API        │    │  Authentication    │          │
│  │  :2001 HTTPS │◀──▶│    :8080  (Go 1.24)   │◀──▶│  :3000 REST        │          │
│  │              │    │                       │    │  :3030 gRPC (Go)   │          │
│  └──────────────┘    │  - agent_registry     │    └────────┬───────────┘          │
│                      │  - apps_registry      │             │                       │
│                      │  - fault_studio       │      ┌──────▼──────┐               │
│                      │  - chaoshub /         │      │   Dex OIDC   │              │
│                      │    agenthub / apphub  │      │   :5556      │              │
│                      │  - observability      │      └─────────────┘               │
│                      │    (LangfuseTracer)   │                                     │
│                      │  - chaos_experiment*  │      ┌──────────────┐              │
│                      └───────────┬───────────┘      │  MongoDB rs0 │              │
│                                  │                  │  :27017      │              │
│                                  └─────────────────▶│              │              │
│                                                     └──────────────┘              │
└────────────────────────────────────────────────────────────────────────────────────┘
                                  │
                                  │ Argo Workflow templates + helm installer images
                                  ▼
┌────────────────────────────────────────────────────────────────────────────────────┐
│                      Kubernetes target cluster (one per registered infra)          │
│                                                                                    │
│   ┌────────────────────┐     ┌──────────────────────────────┐                     │
│   │  Subscriber pod    │     │  Argo controller +           │                     │
│   │  (chaoscenter/     │◀───▶│  LitmusChaos operator         │                     │
│   │   subscriber)      │     │  ChaosExperiment / Engine     │                     │
│   └─────────┬──────────┘     └──────────────────────────────┘                     │
│             │ installs target app + agent + faults                                │
│             ▼                                                                      │
│   ┌────────────────────┐  ┌────────────────────┐  ┌────────────────────┐          │
│   │  Sock Shop (SUT)   │  │ Flash agent +       │  │  Chaos faults      │         │
│   │  + Prom + Grafana  │  │ agent-sidecar       │  │  (pod-delete, …)   │         │
│   │  + MCP servers     │◀▶│ (under test)        │  │                    │         │
│   └────────────────────┘  └─────────┬──────────┘  └────────────────────┘          │
│                                     │ OpenAI calls (with injected identity)        │
│                                     ▼                                              │
│                          ┌────────────────────┐                                    │
│                          │  LiteLLM proxy     │                                    │
│                          │  :4000             │                                    │
│                          └─────────┬──────────┘                                    │
│                                    │ trace spans                                   │
└────────────────────────────────────┼───────────────────────────────────────────────┘
                                     ▼
                            ┌────────────────────┐         ┌──────────────────────┐
                            │     Langfuse       │ ──────▶ │     certifier        │
                            │  (trace store)     │         │  (12-section report) │
                            └────────────────────┘         └──────────────────────┘
```

---

## Backend services

Every service has its own multi-stage Dockerfile and is built + pushed independently.

| Service | Path | Language | Default port | Image | Responsibilities |
|---|---|---|---|---|---|
| **GraphQL API** | [`chaoscenter/graphql/server`](../chaoscenter/graphql/server) | Go 1.24 | `:8080` | `agentcert/litmusportal-server` | Schema, resolvers, MongoDB persistence, Langfuse tracer, Helm bridge to install registered agents |
| **Authentication** | [`chaoscenter/authentication`](../chaoscenter/authentication) | Go 1.24 | `:3000` REST, `:3030` gRPC | `agentcert/litmusportal-auth-server` | JWT issuance / verification, project membership, user CRUD |
| **Web** | [`chaoscenter/web`](../chaoscenter/web) | React + TypeScript (Webpack) | `:2001` HTTPS (dev) | `agentcert/litmusportal-frontend` | SPA bundled with nginx on `ubi8-minimal` in production |
| **Dex** | [`chaoscenter/dex-server`](../chaoscenter/dex-server) | Go | `:5556` | `agentcert/dex-server` | OIDC provider used for SSO |
| **Subscriber** | [`chaoscenter/subscriber`](../chaoscenter/subscriber) | Go | in-cluster | `agentcert/litmusportal-subscriber` | Runs inside each target cluster, talks home over gRPC, dispatches Argo workflows, reports run status back |
| **Event tracker** | [`chaoscenter/event-tracker`](../chaoscenter/event-tracker) | Go | in-cluster | `agentcert/event-tracker` | Watches K8s events and triggers `ChaosEngine`s on matching rules |
| **Upgrade agents** | [`chaoscenter/upgrade-agents`](../chaoscenter/upgrade-agents) | Go | one-shot | — | Per-version migration tooling for registered agents |

Base images: `golang:1.24` → `ubi9-minimal` for Go services; `node:18` → `ubi8-minimal`
+ nginx for the SPA.

---

## GraphQL server package layout

```
chaoscenter/graphql/server/pkg/
├── agent_registry/    ⭐ AgentCert — agent CRUD, helm bridge, langfuse linkage, health scheduler
├── agenthub/          ⭐ AgentCert — chart-source management (AgentHub)
├── apps_registry/     ⭐ AgentCert — app CRUD
├── apphub/            ⭐ AgentCert — chart-source management (AppHub)
├── fault_studio/      ⭐ AgentCert — curated fault collection CRUD
├── observability/     ⭐ AgentCert — LangfuseTracer + SLA
├── chaoshub/          ChaosHub (upstream Litmus, slightly extended)
├── chaos_experiment/  Experiment CRUD
├── chaos_experiment_run/  Run lifecycle
├── chaos_infrastructure/  Subscriber / infra registration
├── authorization/, environment/, projects/, gitops/, helm/, image_registry/, probe/
├── grpc/, handlers/   gRPC + HTTP entry points
└── database/, data-store/
```

⭐ = added by AgentCert. The rest is forked from `litmuschaos/litmus/chaoscenter`
v3.0.0 with minor adjustments.

Feature-specific deep dives:

- [`agent-registry.md`](agent-registry.md)
- [`app-registry.md`](app-registry.md)
- [`fault-studio.md`](fault-studio.md)
- [`observability.md`](observability.md)
- [`mcp-infrastructure.md`](mcp-infrastructure.md)

---

## Deployment manifests

The platform ships manifests in two locations — one for the *control* cluster, one
for each *infra* cluster the subscriber lands in.

### Top-level (control cluster only)

[`chaoscenter/manifests/`](../chaoscenter/manifests/) — applied once on the cluster
running the API + UI:

| File | What it installs |
|---|---|
| `litmus-portal-crds.yml` (~224 KB) | Every CRD — `ChaosExperiment`, `ChaosEngine`, `ChaosSchedule`, Argo Workflow CRDs |
| `litmus-installation.yaml` | Full Litmus + Argo stack |
| `litmus-getting-started.yaml` | Slimmer "getting started" variant |
| `litmus-without-resources.yaml` | Variant without resource quotas |

### Per-namespace (each infra cluster)

[`chaoscenter/graphql/server/manifests/namespace/`](../chaoscenter/graphql/server/manifests/namespace/)
— applied **per registered infra**. The subscriber substitutes
`#{PLACEHOLDER}` tokens (e.g. `#{INFRA_NAMESPACE}`, `#{KUBERNETES_MCP_SERVER_IMAGE}`)
at install time using the registered infra's configuration:

| Stage | Files | What it installs |
|---|---|---|
| 1 | `1a_argo_rbac.yaml` + `1b_argo_deployment.yaml` | Argo Workflows controller + RBAC |
| 2 | `2a_litmus_admin_rbac.yaml` + `2b_litmus_deployment.yaml` | Litmus operator + admin RBAC |
| 3 | `3a_agents_rbac.yaml` + `3b_agents_deployment.yaml` | Subscriber pod + agent infra RBAC |
| 4 | `4a_mcp_tools_rbac.yaml` + `4b_mcp_tools_deployment.yaml` | `kubernetes-mcp-server` + `prometheus-mcp-server` |

Stage 4 is documented in [`mcp-infrastructure.md`](mcp-infrastructure.md).

---

## Storage

| Component | Purpose |
|---|---|
| **MongoDB** (replica set `rs0`, port `:27017`) | Sole persistence layer for the platform. Hosts collections for users, projects, agents, apps, fault studios, chaos hubs, experiments, experiment runs, audit history. Schemas are defined per-package under `pkg/<feature>/model.go`. |
| **Mongo collections** | At minimum: users, projects, chaos_hubs, chaos_experiments, experiment_runs, environments, image_registries, gitops_configs — plus the AgentCert-added agents, apps, agent_hubs, app_hubs, fault_studios. Each package owns its collection via the `database/mongodb/<feature>/` Go subpackage. |

Mongo is brought up as a single-node replica set in dev (admin auth, default
`admin:1234`); in production any reachable cluster works.

---

## External integrations

| System | Used by | Notes |
|---|---|---|
| **Langfuse** | `pkg/observability/langfuse_tracer.go` (server-wide); `pkg/agent_registry/langfuse_client.go` (per-agent project resolution) | See [`observability.md`](observability.md) |
| **LiteLLM** | `LITELLM_URL` plumbed into every install-agent invocation | The agents under test call the proxy, not the providers directly. See [`agentcert-stack`](../../agentcert-stack/) |
| **OpenAI / Azure OpenAI / Gemini** | Routed by LiteLLM | Credentials never live in this repo |
| **Argo Workflows** | Experiment execution | Installed in stage 1 of the per-namespace manifests |
| **LitmusChaos operator** | Fault injection | Installed in stage 2 |
| **Kubernetes / Minikube / Kind** | Subscriber + target apps + agents + faults | Per-infra install via stages 1–4 |

---

## Where AgentCert ends and other repos begin

| This repo (control plane) | Other repos in the monorepo |
|---|---|
| GraphQL API, web UI, subscriber, registries, Langfuse tracer | [`agent-charts`](../../agent-charts/) — Helm charts + `install-agent` image |
| | [`app-charts`](../../app-charts/) — Helm charts + `install-app` image |
| | [`chaos-charts`](../../chaos-charts/) — fault catalogue (ChaosHub source) |
| | [`agent-sidecar`](../../agent-sidecar/) — stamps experiment identity on LLM calls |
| | [`agentcert-stack`](../../agentcert-stack/) — LiteLLM bootstrap |
| | [`flash-agent`](../../flash-agent/) — reference agent under test |
| | [`certifier`](../../certifier/) — trace → 12-section report pipeline |

AgentCert never embeds the agents or apps it deploys — it only references them by
chart-source URL (the AgentHub / AppHub git URLs configured at install time).

See also: [`experiment-flow.md`](experiment-flow.md) for the end-to-end runtime
trajectory.
