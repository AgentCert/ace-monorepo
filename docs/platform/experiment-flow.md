---
title: "Experiment Flow"
parent: "Control Plane"
grand_parent: "Deep Dive"
nav_order: 2
---

# End-to-End Experiment Flow

This document traces a single chaos experiment from the moment an operator clicks
*Run* in the UI to the moment the [`certifier`](../../certifier/) produces a PDF.
Every step references the package or manifest that owns it — use this as the
"where do I go to debug step N" map.

For the static system architecture see [`architecture.md`](architecture.md); for
individual subsystem details, the per-feature docs (registries, fault studio,
observability, MCP).

---

## Prerequisites in the platform

Before a single experiment can run, the operator (or a one-shot bootstrap) needs
to have:

1. **Signed in** — UI at `https://localhost:2001`, JWT issued by
   [`authentication`](../chaoscenter/authentication).
2. **Registered an environment** — a Kubernetes target. The subscriber pod is
   installed there via stages 1–4 of the per-namespace manifests
   ([`mcp-infrastructure.md`](mcp-infrastructure.md) covers stage 4 in detail).
3. **Added a ChaosHub** pointing at [`chaos-charts`](../../chaos-charts/) — faults
   appear in the *Fault Studio*.
4. **Added an AgentHub** pointing at [`agent-charts`](../../agent-charts/) —
   agents appear under *Agents*.
5. **Added an AppHub** pointing at [`app-charts`](../../app-charts/) — apps
   appear under *Applications*.
6. **Registered an Agent** — see [`agent-registry.md`](agent-registry.md).
7. **Registered an App** — see [`app-registry.md`](app-registry.md).
8. **Created a Fault Studio** — see [`fault-studio.md`](fault-studio.md).

After this the operator can create a *Benchmark Project* or *Experiment* that
binds: an agent + an app + a fault studio + a schedule.

---

## The runtime flow

```
                           ┌──────────────────────────┐
                           │       AgentCert UI       │     operator clicks Run
                           └────────────┬─────────────┘
                                        │
                                        ▼
                           ┌──────────────────────────┐
                           │     GraphQL API          │
                           │  chaos_experiment_run/   │
                           └────────────┬─────────────┘
                                        │   1. Mongo: experiment_run.Status = QUEUED
                                        │   2. Build Argo Workflow from
                                        │      (agent + app + active fault selections)
                                        │   3. Call observability.TraceExperimentExecution
                                        │      → Langfuse: new trace, root span open
                                        ▼
                           ┌──────────────────────────┐
                           │   Subscriber pod         │     dispatched via gRPC
                           │   (target cluster)       │
                           └────────────┬─────────────┘
                                        │
                                        ▼
              ┌─────────────────────────────────────────────────┐
              │  Argo Workflow step 1: install-app              │
              │    agentcert/agentcert-install-app:latest       │
              │    helm upgrade --install <chart> -n <ns>       │
              └────────────────────┬────────────────────────────┘
                                   ▼
              ┌─────────────────────────────────────────────────┐
              │  Argo Workflow step 2: install-agent            │
              │    agentcert/agentcert-install-agent:latest     │
              │    helm upgrade --install <chart> -n <ns> \     │
              │      --set agent.config.AGENT_ID=<UUID> \       │
              │      --set agent.config.MCP_URLS=... \          │
              │      --set agent.config.OPENAI_BASE_URL=... \   │
              │      --set agent.config.LANGFUSE_*              │
              └────────────────────┬────────────────────────────┘
                                   ▼
              ┌─────────────────────────────────────────────────┐
              │  Argo Workflow step 3: load-test (optional)     │
              └────────────────────┬────────────────────────────┘
                                   ▼
              ┌─────────────────────────────────────────────────┐
              │  Argo Workflow step 4: chaos faults             │
              │    parallel or sequential per fault studio      │
              │    each spawns a ChaosEngine → ChaosResult      │
              └────────────────────┬────────────────────────────┘
                                   │
                ┌──────────────────┼──────────────────┐
                ▼                  ▼                  ▼
   ┌───────────────────┐  ┌───────────────────┐  ┌───────────────────────────┐
   │ flash-agent       │  │  LitmusChaos      │  │  Subscriber callbacks     │
   │ (scan/watch loop) │  │  operator runs    │  │  → GraphQL Update         │
   │ + agent-sidecar   │  │  the fault        │  │  → observability.        │
   │                   │  │                   │  │    EmitFaultSpanAt-       │
   │ LLM calls flow:   │  │  ChaosResult      │  │    Injection(...)         │
   │ agent →           │  │  status updates   │  │                           │
   │   sidecar:4001 →  │  │  late-arriving    │  │                           │
   │   LiteLLM:4000 →  │  │  (deterministic   │  │                           │
   │   Azure/OpenAI    │  │   ID upserts in   │  │                           │
   │                   │  │   Langfuse)       │  │                           │
   │ Trace metadata    │  │                   │  │                           │
   │ injected by side- │  │                   │  │                           │
   │ car: trace_id =   │  │                   │  │                           │
   │ NOTIFY_ID         │  │                   │  │                           │
   └────────┬──────────┘  └───────────────────┘  └───────────────────────────┘
            │
            ▼
   Langfuse stores:
     • root span (the experiment)
     • child spans per fault
     • LLM call spans (from LiteLLM)
                                   │
                                   ▼  Argo workflow ends
                           ┌──────────────────────────┐
                           │   Subscriber callback    │
                           │   → CompleteExperiment-  │
                           │     Execution(...)       │
                           └────────────┬─────────────┘
                                        │  Status = COMPLETED / FAILED
                                        │  ClearEmittedFaults(traceID)
                                        │  ClearWorkflowNodeStates(traceID)
                                        ▼
                           ┌──────────────────────────┐
                           │  Operator triggers       │
                           │  certifier:              │
                           │  POST /api/v1/           │
                           │  aggregation-            │
                           │  certification           │
                           └────────────┬─────────────┘
                                        │  reads Langfuse traces for the run
                                        ▼
                          [12-section HTML + PDF report]
```

---

## The trace correlation contract

The single trick that makes every layer's data joinable: **one stable `trace_id`
per experiment run**, propagated through every component.

| Component | Where the `trace_id` comes from |
|---|---|
| GraphQL server (`observability.TraceExperimentExecution`) | Generated when `experiment_run` is created |
| Subscriber callbacks | Carried as part of the gRPC payload |
| ConfigMap mounted into agent pod | Written by the helm bridge as `NOTIFY_ID` |
| [`agent-sidecar`](../../agent-sidecar/) | Reads `NOTIFY_ID` from the mounted ConfigMap, stamps it as Langfuse `trace_id` on every outbound LLM call |
| LiteLLM proxy | Forwards the `trace_id` to Langfuse |
| Certifier | Joins on `trace_id` to find every span for the run |

---

## Code-cited summary of each step

| Step | Code |
|---|---|
| Create the run row | `pkg/chaos_experiment_run/` |
| Build Argo workflow from fault studio + agent + app | `pkg/chaos_experiment/` |
| Open Langfuse trace | [`pkg/observability/langfuse_tracer.go:129 TraceExperimentExecution`](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L129) |
| Dispatch to subscriber | `pkg/grpc/` |
| Subscriber runs Argo workflow | [`chaoscenter/subscriber`](../chaoscenter/subscriber/) |
| Stage-1..4 per-namespace install | [`graphql/server/manifests/namespace/`](../chaoscenter/graphql/server/manifests/namespace/) |
| Install target app | [`app-charts/install-app`](../../app-charts/install-app/) image |
| Install agent + sidecar | [`agent-charts/install-agent`](../../agent-charts/install-agent/) image |
| Inject `trace_id` into agent's LLM calls | [`agent-sidecar/proxy.py`](../../agent-sidecar/proxy.py) |
| Fault spans (dedup'd) | [`langfuse_tracer.go:500 EmitFaultSpanAtInjection`](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L500), [`langfuse_tracer.go:386 EmitFaultSpansForTrace`](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L386) |
| Close trace | [`langfuse_tracer.go:216 CompleteExperimentExecution`](../chaoscenter/graphql/server/pkg/observability/langfuse_tracer.go#L216) |
| Generate the report | [`certifier`](../../certifier/) — `POST /api/v1/aggregation-certification` |

---

## Failure modes & what they look like

| Symptom | Likely cause | Look at |
|---|---|---|
| Run stays `QUEUED` forever | Subscriber unreachable from control plane | `pkg/chaos_infrastructure` connection state |
| `install-app` Argo step fails | Bad chart name in `App` registration or missing chart in AppHub git URL | [`app-registry.md`](app-registry.md) + `pkg/apphub` |
| `install-agent` step fails | Image pull / Helm timeout / kubeconfig | [`agent-registry.md`](agent-registry.md) — helm bridge section |
| Agent boots but `Status` stays `VALIDATING` | Health probe failing — wrong `HealthPath`, wrong port, app not actually serving readiness | [`agent-registry.md`](agent-registry.md) — health scheduler section |
| No Langfuse spans for the run | Tracer disabled (`IsEnabled() == false`) — missing `LANGFUSE_HOST` env | [`observability.md`](observability.md) |
| Spans show up but agent calls are missing | `agent-sidecar` not wired (`OPENAI_BASE_URL` points at LiteLLM directly instead of the sidecar) | [`../../agent-sidecar/README.md`](../../agent-sidecar/README.md) |
| Duplicate fault spans | `emittedFaults` dedup cache reset / signature collision — unlikely | [`observability.md`](observability.md) — dedup section |

---

## Related docs

- [`architecture.md`](architecture.md) — static component map
- [`agent-registry.md`](agent-registry.md), [`app-registry.md`](app-registry.md),
  [`fault-studio.md`](fault-studio.md) — the three registries this flow joins
- [`observability.md`](observability.md) — what the tracer does at each step
- [`mcp-infrastructure.md`](mcp-infrastructure.md) — how agents see the cluster
