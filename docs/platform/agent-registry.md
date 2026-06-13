---
title: "Agent Registry"
parent: "Control Plane"
grand_parent: "Deep Dive"
nav_order: 3
---

# Agent Registry

The Agent Registry is AgentCert's first-class catalogue of AI agents. Every agent
that runs against the platform must be registered here first — registration assigns
a stable UUID, installs the agent via Helm, links it to a Langfuse project, and
puts it under a health scheduler.

This document covers the full surface: GraphQL schema, data model, services, helm
bridge, langfuse linkage, and the health scheduler.

> Code is the source of truth. All line numbers refer to files under
> [`chaoscenter/graphql/server/pkg/agent_registry/`](../chaoscenter/graphql/server/pkg/agent_registry/)
> and [`chaoscenter/graphql/definitions/shared/agent_registry.graphqls`](../chaoscenter/graphql/definitions/shared/agent_registry.graphqls).

---

## Package layout

```
pkg/agent_registry/
├── model.go             # Agent + ContainerImage + AgentEndpoint + LangfuseConfig +
│                        # AgentMetadata + AuditInfo + AgentStatus enums
├── constants.go         # Status enums + tunables
├── errors.go            # Typed errors surfaced to GraphQL
├── validator.go         # Input validation (name, version, image, endpoint shape)
├── handler.go           # GraphQL resolver → service-layer glue
├── service.go           # CRUD + status machine + orchestration
├── helm.go              # Helm-driven install / upgrade / uninstall
├── langfuse_client.go   # Per-agent Langfuse project key resolution
├── health_scheduler.go  # Background tick loop, probes Endpoint.HealthPath
├── operator.go          # Mongo CRUD
├── mapper.go            # bson <-> GraphQL model translation
└── agent_registry_test.go
```

---

## Data model

From [`model.go`](../chaoscenter/graphql/server/pkg/agent_registry/model.go):

```go
type Agent struct {
    AgentID         string          // UUID generated at registration
    ProjectID       string          // Litmus project this agent belongs to
    Name            string          // unique within project
    Version         string
    Vendor          string
    Capabilities    []string        // e.g. ["fault-detection","auto-remediation"]
    ContainerImage  *ContainerImage // {Registry, Repository, Tag}
    Namespace       string          // K8s namespace the agent runs in
    HelmReleaseName string          // populated by the helm bridge
    Endpoint        *AgentEndpoint  // {URL, Type, DiscoveryType, HealthPath, ReadyPath}
    LangfuseConfig  *LangfuseConfig // {ProjectID, SyncEnabled, LastSyncedAt}
    Status          AgentStatus     // see status machine below
    Metadata        *AgentMetadata  // Labels + Annotations
    AuditInfo       *AuditInfo      // CreatedAt/By, UpdatedAt/By, LastHealthCheck
}
```

Supporting types:

```go
type ContainerImage struct  { Registry, Repository, Tag string }
type AgentEndpoint  struct  { URL string; Type EndpointType; DiscoveryType EndpointDiscoveryType; HealthPath, ReadyPath string }
type LangfuseConfig struct  { ProjectID string; SyncEnabled bool; LastSyncedAt *int64 }
type AgentMetadata  struct  { Labels, Annotations map[string]string }
type AuditInfo      struct  { CreatedAt, UpdatedAt int64; CreatedBy, UpdatedBy string; LastHealthCheck *int64 }
```

### Status machine

```
   REGISTERED  →  VALIDATING  →  ACTIVE  ⇄  INACTIVE  →  DELETED
        │             │                                        ▲
        └─────────────┴────────── failed validation ───────────┘
```

| Status | When set | By |
|---|---|---|
| `REGISTERED` | Right after `RegisterAgent` writes the doc | `service.go` |
| `VALIDATING` | After helm release completes but before first health probe | `helm.go` + `service.go` |
| `ACTIVE` | First successful health probe against `Endpoint.HealthPath` | `health_scheduler.go` |
| `INACTIVE` | Health probe fails for N consecutive ticks | `health_scheduler.go` |
| `DELETED` | Soft-delete via `DeleteAgent` mutation | `service.go` |

### Discovery types

| `DiscoveryType` | Meaning |
|---|---|
| `AUTO` | URL is computed from the helm release (`<release>.<namespace>.svc.cluster.local`) |
| `MANUAL` | URL is supplied by the caller verbatim |

---

## GraphQL surface

Schema: [`agent_registry.graphqls`](../chaoscenter/graphql/definitions/shared/agent_registry.graphqls) (725 lines).

Resolvers: [`graph/agent_registry.resolvers.go`](../chaoscenter/graphql/server/graph/agent_registry.resolvers.go).

Selected operations (the schema is large; full inventory in the `.graphqls` file):

| Operation | Kind | Returns | Purpose |
|---|---|---|---|
| `RegisterAgent` | Mutation | `RegisterAgentResponse` | Allocate UUID, persist doc, kick off helm install |
| `UpdateAgent` | Mutation | `Agent` | Patch fields (image, endpoint, metadata) |
| `DeleteAgent` | Mutation | `Boolean` | Soft-delete + helm uninstall |
| `GetAgent` | Query | `Agent` | Lookup by `agentID` |
| `ListAgents` | Query | `[Agent!]!` | Paginated list per project |
| `GetAgentHealth` | Query | `AgentHealth` | Most-recent health probe |

The schema also exposes supporting types: `EnvironmentVariable` (key/value pairs
with `isSensitive` flagging for secret-masked UIs), `ContainerImage`,
`AgentEndpoint`, `LangfuseConfig`, `AgentMetadata`, `AuditInfo`, plus the
`AgentStatus` and `EndpointType` / `EndpointDiscoveryType` enums.

---

## The helm bridge

This is the crucial piece that turns a registry record into a running pod.

[`pkg/agent_registry/helm.go`](../chaoscenter/graphql/server/pkg/agent_registry/helm.go)
exposes `DeployWithHelm(ctx, *HelmDeployRequest)` which:

1. Resolves a `helm` binary path from `utils.Config.HelmBinary` (line 101).
2. Optionally creates the target namespace via `kubectl create namespace … --dry-run=client -o yaml | kubectl apply -f -` (lines 143–145).
3. Resolves a kubeconfig (`KUBECONFIG` env → default `~/.kube/config` → in-cluster, lines 222–228).
4. Builds the helm `args` slice, including a `--set agent.config.AGENT_ID=<UUID>` and other registry-known values.
5. Runs `helm upgrade --install …` via `exec.CommandContext` (line 272).
6. Optionally patches Azure credentials into the chart-created ConfigMap via
   `kubectl patch configmap` (`patchAzureCredentials`, line 283).

Key contract: **the registry UUID is generated by `RegisterAgent` *before* helm is
invoked**, and passed in as a `--set` value. The agent therefore receives its
canonical identity at first boot, which is what the
[`agent-sidecar`](../../agent-sidecar/) stamps onto every outbound LLM call.

`HelmDeployRequest` shape (line 61):

```go
type HelmDeployRequest struct {
    // Namespace is where the agent's Helm release is INSTALLED.
    Namespace        string
    Release          string
    ChartPath        string
    ValuesFile       string
    SetValues        []string  // additional --set key=value pairs
    Timeout          time.Duration
    // … plus credential / kubeconfig override fields
}
```

Timeouts default to `utils.Config.HelmTimeout` (line 164).

---

## Langfuse linkage

Each `Agent` may carry a `LangfuseConfig{ProjectID, SyncEnabled, LastSyncedAt}`.
[`langfuse_client.go`](../chaoscenter/graphql/server/pkg/agent_registry/langfuse_client.go)
provides:

- The Langfuse public / secret key pair resolution for a given agent's project.
- Hooks that the helm bridge calls to inject `LANGFUSE_HOST`, `LANGFUSE_PUBLIC_KEY`,
  `LANGFUSE_SECRET_KEY` (and project ID) as `--set` values into the helm install.
- Sync-status updates so `LastSyncedAt` reflects when the registry last pushed agent
  metadata into the Langfuse project.

The result: agent traces land in the **right** Langfuse project automatically, with
the agent's registry UUID as a tag, without any per-agent dashboard plumbing.

---

## Health scheduler

[`health_scheduler.go`](../chaoscenter/graphql/server/pkg/agent_registry/health_scheduler.go)
runs in-process on the GraphQL server and probes registered agents on a tick.

```go
type HealthCheckScheduler struct {
    service  Service
    interval time.Duration   // default 5 * time.Minute when zero
    stopChan chan struct{}
    running  sync.WaitGroup
}
```

- Constructor: `NewHealthCheckScheduler(service Service, interval time.Duration)` —
  zero interval defaults to **5 minutes** (line ~25).
- `Start(ctx)` — runs a `time.Ticker` loop that walks every non-terminal agent in
  the registry and probes `Endpoint.HealthPath`. Mutates `Status` and
  `AuditInfo.LastHealthCheck`.
- `Stop()` — closes `stopChan` and waits on `running`.

The scheduler is the only path through which `ACTIVE` ⇄ `INACTIVE` transitions
happen — manual mutations don't touch them.

---

## Registration flow

Putting it all together. The boundary between this package and the rest of the
platform:

```
GraphQL: RegisterAgent(input)        ──── graph/agent_registry.resolvers.go
                       │
                       ▼
Handler:               h.RegisterAgent(ctx, input)        ──── pkg/agent_registry/handler.go
                       │   • JWT extracted from ctx (authorization.AuthKey)
                       ▼
Service:               svc.RegisterAgent(...)             ──── pkg/agent_registry/service.go
                       │   • validator.go  → reject bad input
                       │   • allocate UUID, set Status=REGISTERED
                       │   • operator.go   → insert into Mongo
                       │   • langfuse_client.go → resolve project keys
                       ▼
Helm bridge:           helm.DeployWithHelm(...)           ──── pkg/agent_registry/helm.go
                       │   • helm upgrade --install <chart> \
                       │       --namespace <ns> --create-namespace \
                       │       --set agent.config.AGENT_ID=<UUID> \
                       │       --set agent.config.LANGFUSE_PROJECT=<projectID> \
                       │       --set agent.config.LANGFUSE_HOST=... \
                       │       --set agent.config.LANGFUSE_PUBLIC_KEY=... \
                       │       --set agent.config.LANGFUSE_SECRET_KEY=...
                       ▼
Status: REGISTERED → VALIDATING
                       │
                       ▼ (next health scheduler tick)
HealthCheckScheduler   service.ProbeHealth(...)           ──── pkg/agent_registry/health_scheduler.go
                       │   • GET <Endpoint.URL><HealthPath>
                       │   • 2xx → Status=ACTIVE
                       │   • failure → INACTIVE after threshold
                       ▼
Status: ACTIVE
```

The `agentcert/agentcert-install-agent` image referenced here is built from
[`agent-charts/install-agent`](../../agent-charts/install-agent/) — see that
repository for the installer CLI flag reference and the charts it bakes in.

---

## AgentHub — chart sources

[`pkg/agenthub`](../chaoscenter/graphql/server/pkg/agenthub/) is the smaller sibling
of `chaoshub`. It manages **chart-source registrations** for the registry: a user
adds an AgentHub pointing at a git URL (e.g.
`https://github.com/AgentCert/agent-charts`), the server clones it, walks
`charts/`, and exposes the discovered chart metadata to the UI.

Files:

| File | Purpose |
|---|---|
| `handler.go` | GraphQL resolver glue (`CreateAgentHub`, `ListAgentHubs`, …) |
| `service.go` | Service layer: git clone, walk, parse `Chart.yaml` |

Default AgentHub URL: configured via `DEFAULT_AGENT_HUB_GIT_URL`
(default `https://github.com/agentcert/agent-charts`). Every project gets it added
automatically on first run.

---

## Related docs

- [`architecture.md`](architecture.md) — where the registry sits in the larger system
- [`app-registry.md`](app-registry.md) — parallel registry for target applications
- [`observability.md`](observability.md) — how registered agents' traces are persisted
- [`experiment-flow.md`](experiment-flow.md) — how the registry participates in a run
