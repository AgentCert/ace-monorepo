---
title: "Control Plane"
parent: "Deep Dive"
nav_order: 2
has_children: true
nav_fold: true
---

# Control Plane

The orchestration layer that drives every experiment — the GraphQL API, three registries (agents, apps, fault studios), the in-cluster subscriber, and the Langfuse tracing layer that correlates every agent decision.

Built on a fork of **[LitmusChaos](https://litmuschaos.io)** — a [Linux Foundation Networking (LFN)](https://lfnetworking.org/) project — with the chaos infrastructure extended for agentic evaluation: agent registration, trace-correlated fault injection, and the statistical certification pipeline.

---

<div class="topic-grid">
  <div class="topic-card">
    <div class="topic-card-title">Platform Architecture</div>
    <div class="topic-card-desc">Component map, ports, images, and deployment manifests for both local and cloud setups.</div>
    <a href="{{ "/platform/architecture.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Experiment Flow</div>
    <div class="topic-card-desc">End-to-end: from clicking Run to a PDF. Every step, every package owner.</div>
    <a href="{{ "/platform/experiment-flow.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Agent Registry</div>
    <div class="topic-card-desc">Registration, Helm install, UUID assignment, Langfuse project linking, and health scheduling.</div>
    <a href="{{ "/platform/agent-registry.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">App Registry</div>
    <div class="topic-card-desc">Target application lifecycle — Sock Shop and beyond. Parallel structure to the Agent Registry.</div>
    <a href="{{ "/platform/app-registry.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Fault Studio</div>
    <div class="topic-card-desc">Curated, toggleable fault collections attached to experiments. The link between ChaosHub and runs.</div>
    <a href="{{ "/platform/fault-studio.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">MCP Infrastructure</div>
    <div class="topic-card-desc">Kubernetes and Prometheus MCP servers agents query via JSON-RPC 2.0 — never the k8s API directly.</div>
    <a href="{{ "/platform/mcp-infrastructure.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Observability</div>
    <div class="topic-card-desc">How every agent call lands in Langfuse — the dedup machinery, span model, and SLA push.</div>
    <a href="{{ "/platform/observability.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Certifier Architecture</div>
    <div class="topic-card-desc">Four-phase analytical pipeline internals — REST API job model, CLI, and phase design decisions.</div>
    <a href="{{ "/architecture.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Certification Flow</div>
    <div class="topic-card-desc">MongoDB data model for the poller-based certificate workflow — collections, schema, UI decoupling.</div>
    <a href="{{ "/platform/certification-flow.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
</div>
