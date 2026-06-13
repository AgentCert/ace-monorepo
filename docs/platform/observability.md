---
title: "Observability"
parent: "Control Plane"
grand_parent: "Deep Dive"
nav_order: 7
---

# Observability

The `pkg/observability` package owns the platform's relationship with Langfuse.
It is the single piece of code through which the GraphQL server pushes experiment,
fault, and SLA data into trace storage — and the place where the **dedup**
machinery lives that keeps repeated controller reconciles from spamming Langfuse
with duplicate spans.

Files:

| File | What it owns |
|---|---|
| [`langfuse_tracer.go`](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go) | `LangfuseTracer` — the trace emitter |
| [`sla.go`](../chaoscenter/graphql/server/pkg/observability/sla.go) | `SLAConfig` — env-loaded SLA targets stamped onto every trace |

---

## `LangfuseTracer`

Definition starts at [langfuse_tracer.go:20](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L20):

```go
type LangfuseTracer struct {
    client     agent_registry.LangfuseClient
    enabled    bool
    orgID      string  // Langfuse organization
    projectID  string  // Langfuse project
    mu         sync.RWMutex

    traceChan  chan *agent_registry.ExperimentTrace
    workerDone chan struct{}
    closed     bool

    // emittedFaults  — last span-payload signature for each (trace, fault)
    emittedFaults map[string]string
    emittedMu     sync.RWMutex

    // nodeStateCache — last (start, end, terminal) signature per workflow node
    // …
}
```

### Lifecycle

| Function | Line | Purpose |
|---|---|---|
| `InitializeLangfuseTracer()` | [66](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L66) | Read env (`LANGFUSE_HOST`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, org / project IDs), construct the singleton |
| `GetLangfuseTracer()` | [113](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L113) | Singleton accessor used by the resolvers |
| `IsEnabled()` | [897](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L897) | False when env is missing — every emit becomes a no-op |
| `Close(ctx)` | [904](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L904) | Stop accepting, drain `traceChan`, wait on `workerDone` |
| `traceWorker()` | [928](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L928) | Background goroutine — reads `traceChan`, batches HTTP calls to Langfuse |

The async-via-channel design is intentional: resolver threads never block on the
Langfuse HTTP API. If Langfuse is slow or down, runs still complete (and the
backlog drains when the worker recovers).

### Public emit API

| Function | Line | Used by |
|---|---|---|
| `TraceExperimentExecution(ctx, *ExperimentExecutionDetails)` | [129](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L129) | Resolver: a new experiment run starts |
| `CompleteExperimentExecution(ctx, traceID, *ExperimentCompletionDetails)` | [216](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L216) | Resolver: run terminates (success / fail / timeout) |
| `TraceExperimentObservation(ctx, *ExperimentObservationDetails)` | [266](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L266) | Resolver: structured observation events |
| `EmitFaultSpansForTrace(...)` | [386](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L386) | Resolver: bulk emit of fault spans for a given trace |
| `EmitFaultSpanAtInjection(...)` | [500](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L500) | Resolver: a specific fault injection moment |
| `SetTraceName(ctx, traceID, name)` | [774](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L774) | Resolver: humanise a trace post-hoc |
| `SetTraceExperimentRunID(ctx, traceID, traceName, expRunID)` | [825](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L825) | Resolver: bind run IDs into Langfuse metadata |
| `ScoreExperimentExecution(ctx, *ExperimentScoreDetails)` | [870](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L870) | Resolver: attach a score / verdict |

### Supporting struct types

| Type | Line |
|---|---|
| `ExperimentContextForTrace` | [308](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L308) |
| `FaultDetail` | [330](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L330) |
| `FaultInjectionDetails` | [453](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L453) |
| `ExperimentExecutionDetails` | [944](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L944) |
| `ExperimentCompletionDetails` | [963](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L963) |
| `ExperimentObservationDetails` | [972](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L972) |
| `ExperimentScoreDetails` | [984](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L984) |

---

## The dedup machinery

The single most-distinguishing detail of this package: **deterministic observation
IDs + content signatures** that let Langfuse coalesce repeated emissions
server-side, while local dedup suppresses the no-ops before they even hit the wire.

### Deterministic fault observation IDs

[`faultObservationID(traceID, faultName)`](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L682)
generates a stable ID per `(traceID, faultName)` pair. Repeat emissions for the
same fault use the **same** ID, so Langfuse upserts instead of inserting a new
observation each time. This is what makes late `ChaosResult` updates (which can
land minutes after the fault span was first created) overlay cleanly onto the
existing record.

### Content signature dedup (`emittedFaults`)

[`buildFaultSpanSignature(d, finishedISO)`](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L688)
hashes the meaningful content of a fault span — fields plus terminal timestamp.
Before emitting, the tracer compares the candidate signature against
`emittedFaults[traceID:faultName]`. If unchanged, the emit is dropped locally,
**before** the HTTP call. Keyed map; protected by `emittedMu`.

### Workflow-node state dedup (`nodeStateCache`)

Tracks `(startTime, endTime, terminal)` per Argo workflow node. Repeat events
that don't change state are dropped before hitting the Langfuse API. Documented
in-code as the same pattern used for fault spans. The cache is cleared per-trace
by `ClearWorkflowNodeStates(traceID)`
([757](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L757)).

### Cache invalidation

When a trace ends or is cleared explicitly, the resolvers call:

```go
tracer.ClearEmittedFaults(traceID)        // line 743
tracer.ClearWorkflowNodeStates(traceID)   // line 757
tracer.ClearTraceNameSet(traceID)         // line 810
tracer.ClearTraceExperimentRunIDSet(...)  // line 863
```

…which evict the per-trace cache entries so a re-run of the same `traceID` doesn't
incorrectly suppress new emissions.

---

## `SLAConfig`

[`sla.go`](../chaoscenter/graphql/server/pkg/observability/sla.go) loads SLA targets
from environment variables once at startup and stamps them onto every emitted
trace as Langfuse metadata. This makes downstream Langfuse dashboards able to
compare actual run latency against target SLA without a separate join.

```go
type SLAConfig struct {
    // … float SLA targets (e.g. TTD, TTR, success-rate thresholds)
}

func LoadSLAFromEnv() SLAConfig            // line 39 — reads via readFloatEnv()
func (s SLAConfig) Attributes() []attribute.KeyValue
func (s SLAConfig) AsMetadata() map[string]interface{}
```

`readFloatEnv(key, fallback)` is the small env-with-default helper at
[line 69](../chaoscenter/graphql/server/pkg/observability/sla.go#L69).

---

## Per-agent vs platform Langfuse

There are two layers of Langfuse linkage in AgentCert. Don't confuse them.

| Layer | Code | Scope | Project resolution |
|---|---|---|---|
| **Platform-wide trace ingestion** | `pkg/observability/langfuse_tracer.go` | One project per AgentCert instance | Reads env at boot: `LANGFUSE_HOST` / `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` |
| **Per-agent project linkage** | [`pkg/agent_registry/langfuse_client.go`](../chaoscenter/graphql/server/pkg/agent_registry/langfuse_client.go) | One project per registered agent | Resolved from the agent's `LangfuseConfig.ProjectID`. Used at helm-install time to plumb the right keys into the agent's runtime env |

The platform tracer writes **server-side** spans (workflow / fault lifecycle); the
per-agent project receives **client-side** spans (the agent's own LLM calls,
emitted by the LiteLLM proxy). The two are correlated by the agent's UUID + the
experiment's `trace_id`, both set at install time and propagated by the
[`agent-sidecar`](../../agent-sidecar/).

---

## Configuration reference

| Env var | Used by | Notes |
|---|---|---|
| `LANGFUSE_HOST` | `InitializeLangfuseTracer` | e.g. `https://cloud.langfuse.com` |
| `LANGFUSE_PUBLIC_KEY` | `InitializeLangfuseTracer` | server-wide writer |
| `LANGFUSE_SECRET_KEY` | `InitializeLangfuseTracer` | server-wide writer |
| `LANGFUSE_ORG_ID` | `InitializeLangfuseTracer` | optional; surfaced as trace metadata |
| `LANGFUSE_PROJECT_ID` | `InitializeLangfuseTracer` | optional; surfaced as trace metadata |
| `SLA_*` (floats) | `LoadSLAFromEnv` | per-target SLA values; missing → `readFloatEnv` falls back to defaults |

Setting `LANGFUSE_HOST` to an empty string is the supported way to *disable*
tracing — `IsEnabled()` returns false and every emit becomes a no-op.

---

## Related docs

- [`architecture.md`](architecture.md) — where the tracer sits in the larger system
- [`agent-registry.md`](agent-registry.md) — per-agent Langfuse linkage
- [`../../certifier/`](../../certifier/) — downstream consumer of the trace stream
