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

<div class="flow-pipeline">

  <div class="flow-step-box">
    <div class="flow-step-header"><span class="flow-step-num">1</span><span class="flow-step-title">AgentCert UI</span></div>
    <div class="flow-step-body">Operator clicks <strong>Run</strong> on a Benchmark Project or Experiment in the web UI.</div>
    <div class="flow-step-output">→ GraphQL mutation to chaos_experiment_run/</div>
  </div>
  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header"><span class="flow-step-num">2</span><span class="flow-step-title">GraphQL API — chaos_experiment_run/</span></div>
    <div class="flow-step-body">
      1. Mongo: <code>experiment_run.Status = QUEUED</code><br>
      2. Build Argo Workflow from (agent + app + active fault selections)<br>
      3. Call <code>observability.TraceExperimentExecution</code> → Langfuse: new trace, root span open
    </div>
    <div class="flow-step-output">→ Argo Workflow dispatched to Subscriber via gRPC</div>
  </div>
  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-note">dispatched via gRPC</div><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header"><span class="flow-step-num">3</span><span class="flow-step-title">Subscriber pod (target cluster)</span></div>
    <div class="flow-step-body">Receives the Argo Workflow definition, submits it to the in-cluster Argo controller. Stages 1–4 per-namespace manifests must already be installed.</div>
  </div>
  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-env" style="max-width:580px">
    <div class="flow-env-label">Argo Workflow</div>
    <div class="flow-step-box" style="margin-bottom:.5rem;max-width:100%">
      <div class="flow-step-header"><span class="flow-step-num">4a</span><span class="flow-step-title">install-app</span></div>
      <div class="flow-step-body"><code>agentcert/agentcert-install-app:latest</code> · <code>helm upgrade --install &lt;chart&gt; -n &lt;ns&gt;</code></div>
    </div>
    <div class="flow-step-box" style="margin-bottom:.5rem;max-width:100%">
      <div class="flow-step-header"><span class="flow-step-num">4b</span><span class="flow-step-title">install-agent</span></div>
      <div class="flow-step-body"><code>agentcert/agentcert-install-agent:latest</code> · sets <code>AGENT_ID</code>, <code>MCP_URLS</code>, <code>OPENAI_BASE_URL</code>, <code>LANGFUSE_*</code> via Helm</div>
    </div>
    <div class="flow-step-box" style="margin-bottom:.5rem;max-width:100%">
      <div class="flow-step-header"><span class="flow-step-num">4c</span><span class="flow-step-title">load-test <span style="font-size:.74rem;font-weight:400;color:#64748b">(optional)</span></span></div>
      <div class="flow-step-body">Generates background traffic so the agent has meaningful signals to observe.</div>
    </div>
    <div class="flow-step-box" style="max-width:100%">
      <div class="flow-step-header"><span class="flow-step-num">4d</span><span class="flow-step-title">chaos faults</span></div>
      <div class="flow-step-body">Parallel or sequential per fault studio definition. Each spawns a <code>ChaosEngine</code> → <code>ChaosResult</code>.</div>
    </div>
  </div>
  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-note">faults live — three things happen in parallel</div><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-fork">
    <div class="flow-fork-branch">
      <div class="flow-phase-box">
        <span class="flow-phase-badge" style="background:#7c3aed">Agent</span>
        <div>
          <div class="flow-phase-title">flash-agent + agent-sidecar</div>
          <ul class="flow-phase-list">
            <li>Scan/watch loop — no fault visibility</li>
            <li>LLM calls: agent → sidecar :4001 → LiteLLM :4000 → Azure/OpenAI</li>
            <li>Sidecar injects <code>trace_id = NOTIFY_ID</code> on every call</li>
            <li>Langfuse receives: root span, child spans per fault, LLM call spans</li>
          </ul>
        </div>
      </div>
    </div>
    <div class="flow-fork-branch">
      <div class="flow-phase-box">
        <span class="flow-phase-badge" style="background:#dc2626">Fault</span>
        <div>
          <div class="flow-phase-title">LitmusChaos operator</div>
          <div class="flow-phase-desc">Runs the fault per <code>ChaosEngine</code>. <code>ChaosResult</code> status updates arrive late (deterministic ID upserts in Langfuse).</div>
        </div>
      </div>
    </div>
    <div class="flow-fork-branch">
      <div class="flow-phase-box">
        <span class="flow-phase-badge" style="background:#0369a1">Events</span>
        <div>
          <div class="flow-phase-title">Subscriber callbacks</div>
          <ul class="flow-phase-list">
            <li>→ GraphQL <code>Update</code></li>
            <li>→ <code>observability.EmitFaultSpanAtInjection</code></li>
          </ul>
        </div>
      </div>
    </div>
  </div>
  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-note">Argo workflow ends</div><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header"><span class="flow-step-num">5</span><span class="flow-step-title">Subscriber callback — CompleteExperimentExecution</span></div>
    <div class="flow-step-body">
      Status = <code>COMPLETED / FAILED</code><br>
      <code>ClearEmittedFaults(traceID)</code> · <code>ClearWorkflowNodeStates(traceID)</code>
    </div>
    <div class="flow-step-output">→ run row updated in Mongo, Langfuse root span closed</div>
  </div>
  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>

  <div class="flow-step-box">
    <div class="flow-step-header"><span class="flow-step-num">6</span><span class="flow-step-title">Operator triggers certifier</span></div>
    <div class="flow-step-body"><code>POST /api/v1/aggregation-certification</code> — reads Langfuse traces for the run, runs Phase 0–3 pipeline</div>
    <div class="flow-step-output">→ 12-section HTML + PDF certification report</div>
  </div>

</div>

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
