---
title: "Fault Studio"
parent: "Control Plane"
grand_parent: "Deep Dive"
nav_order: 5
---

# Fault Studio

A **Fault Studio** is AgentCert's primitive for assembling a *curated, toggleable*
subset of faults from a ChaosHub into a reusable collection. Where a raw ChaosHub
contains every available fault, a Fault Studio is the user-friendly artifact that
gets attached to an experiment: "for this benchmark project, run *these* faults
under *this* injection schedule."

Schema and service live in:

- Schema: [`fault_studio.graphqls`](../chaoscenter/graphql/definitions/shared/fault_studio.graphqls) (447 lines)
- Resolver: [`graph/fault_studio.resolvers.go`](../chaoscenter/graphql/server/graph/fault_studio.resolvers.go)
- Service: [`pkg/fault_studio/service.go`](../chaoscenter/graphql/server/pkg/fault_studio/service.go)

---

## Concepts

### Injection types

From [`fault_studio.graphqls`](../chaoscenter/graphql/definitions/shared/fault_studio.graphqls):

```graphql
enum InjectionType {
  SCHEDULED   # fault is injected on a cron schedule
  ON_DEMAND   # fault is injected manually
  CONTINUOUS  # fault is active for the duration of the test
}
```

### Fault injection configuration

```graphql
type FaultInjectionConfig {
  injectionType:  InjectionType!
  schedule:       String   # cron expression, e.g. "0 */5 * * *"
  duration:       String   # e.g. "30s", "5m"
  targetSelector: String   # Kubernetes selector for targeting
  interval:       String   # gap between repeated injections
}
```

The matching input type is `FaultInjectionConfigInput` with the same fields.

### A `FaultSelection`

A single fault chosen from a ChaosHub for inclusion in a studio:

```graphql
type FaultSelection {
  faultCategory:   String!           # "kubernetes" | "aws" | "azure" | "gcp" | "network"
  faultName:       String!           # internal name, e.g. "pod-delete"
  displayName:     String!
  description:     String
  enabled:         Boolean!          # toggleable without removal
  injectionConfig: FaultInjectionConfig
  customParams:    String            # JSON-encoded overrides
}
```

The `enabled` field is what makes studios feel light: you can flick a fault off
without restructuring the studio.

---

## Default ChaosHub binding

From [`service.go`](../chaoscenter/graphql/server/pkg/fault_studio/service.go):

```go
const DefaultHubID   = "6f39cea9-6264-4951-83a8-29976b614289"
const DefaultHubName = "Litmus ChaosHub"
```

Every project gets the built-in *"Litmus ChaosHub"* registered at bootstrap. New
studios default to drawing faults from it unless explicitly bound to a custom hub
(via `CreateFaultStudio.hubID`).

---

## Service operations

The `Service` interface (excerpt from `service.go`):

```go
type Service interface {
    CreateFaultStudio  (ctx, projectID, request)                   (*FaultStudio, error)
    GetFaultStudio     (ctx, projectID, studioID)                  (*FaultStudio, error)
    ListFaultStudios   (ctx, projectID, *request)                  (*ListFaultStudioResponse, error)
    UpdateFaultStudio  (ctx, projectID, studioID, request)         (*FaultStudio, error)
    DeleteFaultStudio  (ctx, projectID, studioID)                  (bool, error)

    ToggleFaultInStudio (ctx, projectID, studioID, faultName, enabled)   (*ToggleFaultResponse, error)
    SetFaultStudioActive(ctx, projectID, studioID, isActive)             (*FaultStudio, error)
    AddFaultToStudio    (ctx, projectID, studioID, FaultSelectionInput)  (*FaultStudio, error)
}
```

Mapped to GraphQL operations:

| Service method | GraphQL operation | Notes |
|---|---|---|
| `CreateFaultStudio` | `mutation createFaultStudio` | Bind to a hub (defaults to `DefaultHubID`), seed with `[FaultSelectionInput]` |
| `GetFaultStudio` | `query getFaultStudio` | |
| `ListFaultStudios` | `query listFaultStudios` | Paginated, filterable by name / active state |
| `UpdateFaultStudio` | `mutation updateFaultStudio` | Patch top-level fields |
| `DeleteFaultStudio` | `mutation deleteFaultStudio` | Soft-delete |
| `ToggleFaultInStudio` | `mutation toggleFaultInStudio` | The "tap to silence" UX path |
| `SetFaultStudioActive` | `mutation setFaultStudioActive` | Freeze / unfreeze the whole studio |
| `AddFaultToStudio` | `mutation addFaultToStudio` | Append a new fault without rewriting the studio |

---

## How studios flow into an experiment

```
   Fault Studio (curated subset of faults from a ChaosHub)
            │
            ▼  (referenced when creating an experiment)
   Benchmark Project / Experiment
            │
            ▼  (Argo workflow generated from the active selections)
   Subscriber → applies ChaosEngine resources in target cluster
            │
            ▼
   LitmusChaos operator executes the fault
            │
            ▼
   pkg/observability/langfuse_tracer.go emits a fault span
```

The agent under test sees the resulting cluster disturbance through its MCP tools
and produces a diagnosis — see [`experiment-flow.md`](experiment-flow.md) for the
full picture.

---

## Storage

Studios are persisted by `pkg/database/mongodb/fault_studio` (referenced by the
service via `dbSchemaFaultStudio`). Hub-side resolution (looking up a fault's
underlying CR by name) routes through `pkg/database/mongodb/chaos_hub`
(`dbSchemaChaosHub`).

Both translate via `mapper`-style functions in the service file so the GraphQL
shape never leaks BSON details.

---

## Related docs

- [`architecture.md`](architecture.md) — where the studio sits in the larger system
- [`experiment-flow.md`](experiment-flow.md) — when faults are selected, queued, run
- The fault catalogue itself: [`../../chaos-charts/README.md`](../../chaos-charts/README.md)
