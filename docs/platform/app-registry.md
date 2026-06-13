---
title: "App Registry"
parent: "Control Plane"
grand_parent: "Deep Dive"
nav_order: 4
---

# App Registry

The App Registry is the parallel structure to the [Agent Registry](agent-registry.md)
for **target applications** — the systems under test that AI agents diagnose and
remediate. Where the Agent Registry catalogues who is testing, the App Registry
catalogues what is being tested.

The most common app is Sock Shop (a microservices demo) deployed from
[`app-charts`](../../app-charts/), but anything you can ship as a Helm chart works.

---

## Package layout

```
pkg/apps_registry/
├── model.go        # App + AppMetadata + AppStatus + AppFilter
├── errors.go       # Typed errors surfaced to GraphQL
├── handler.go      # GraphQL resolver → service-layer glue
└── operator.go     # Mongo CRUD
```

(Smaller than `agent_registry` — no helm bridge or health scheduler. App
installation goes through the
[`agent-charts/install-app`](../../app-charts/install-app/) image dispatched by the
subscriber, not via in-process helm calls from the GraphQL server.)

---

## Data model

From [`pkg/apps_registry/model.go`](../chaoscenter/graphql/server/pkg/apps_registry/model.go):

```go
type App struct {
    AppID         string
    ProjectID     string
    Name          string
    Version       string
    Description   string
    ChartName     string         // Helm chart name in the AppHub
    Namespace     string
    EnvironmentID string         // bound to a Litmus environment
    Method        string         // HELM_CHART | CLOUD_MANAGED | …
    Status        AppStatus
    Metadata      *AppMetadata
    AuditInfo     *AuditInfo
}

type AppMetadata struct {
    Labels       map[string]string
    Annotations  map[string]string
    ChartVersion string
    AppVersion   string
}

type AuditInfo struct {
    CreatedAt int64; CreatedBy string
    UpdatedAt int64; UpdatedBy string
}
```

### Status machine

```
   REGISTERED  →  ACTIVE  ⇄  INACTIVE  →  DELETED
```

| Status | When set |
|---|---|
| `REGISTERED` | Right after `RegisterApp` writes the doc |
| `ACTIVE` | After successful install + smoke (set by the subscriber callback) |
| `INACTIVE` | When the underlying release is uninstalled or fails health |
| `DELETED` | Soft-delete |

### Listing — `AppFilter`

```go
type AppFilter struct {
    ProjectID     string
    EnvironmentID string
    Status        AppStatus
    SearchTerm    string
}
```

---

## Methods on apps

Where the agent registry plumbs helm in-process via `helm.go`, app installation is
delegated to the **`agentcert/agentcert-install-app`** image — built from
[`app-charts/install-app`](../../app-charts/install-app/) — which the subscriber
runs as an Argo workflow step inside the target cluster.

The flow is therefore:

```
GraphQL: RegisterApp(input)
                │
                ▼
Service:        operator.InsertApp()  → Mongo
                │   • Status = REGISTERED
                ▼
Argo workflow:  agentcert/agentcert-install-app:latest
                │   --folder sock-shop --namespace sock-shop --release sock-shop
                │   (charts are baked into the image)
                ▼
Subscriber callback ──▶ service.MarkActive(appID)
                │
                ▼
Status: ACTIVE
```

This is documented as the **app-install side** of
[`experiment-flow.md`](experiment-flow.md).

---

## AppHub — chart sources

[`pkg/apphub`](../chaoscenter/graphql/server/pkg/apphub/) is the chart-source
manager for apps, parallel to `agenthub`:

| File | Purpose |
|---|---|
| `handler.go` | GraphQL: `CreateAppHub`, `ListAppHubs`, … |
| `service.go` | Git clone of the AppHub URL, walk `charts/`, expose chart metadata |

Default AppHub URL: `DEFAULT_APP_HUB_GIT_URL` (default
`https://github.com/agentcert/app-charts`). Auto-registered on first run, just like
ChaosHub and AgentHub.

---

## Sock Shop, in particular

The default app shipped via `app-charts/sock-shop` deploys 13 services + the
Prometheus / Grafana / metrics-server / kube-state-metrics observability stack +
the two MCP servers (`kubernetes-mcp-server`, `prometheus-mcp-server`) that agents
under test query. See
[`app-charts/README.md`](../../app-charts/README.md) for the full inventory.

For the AgentCert side, all that matters is: registering Sock Shop as an `App`
makes it selectable in the *Applications* section of the UI, the subscriber
deploys it on demand, and the registry tracks its lifecycle.

---

## Related docs

- [`architecture.md`](architecture.md) — where the app registry sits in the larger system
- [`agent-registry.md`](agent-registry.md) — the parallel registry for AI agents
- [`mcp-infrastructure.md`](mcp-infrastructure.md) — the MCP servers Sock Shop ships with
- [`experiment-flow.md`](experiment-flow.md) — when the app gets installed during a run
