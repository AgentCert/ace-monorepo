---
title: Deep Dive
nav_order: 4
has_children: true
nav_fold: true
---

# Deep Dive

Two complementary views of the platform — the **Certification Methodology** (how fault-injection runs become a defensible report) and the **Control Plane** (how every component fits together for contributors and integrators).

ACE is built on **[LitmusChaos](https://litmuschaos.io)** — a [Linux Foundation Networking](https://lfnetworking.org/) project — extended for agentic evaluation: trace-correlated fault injection, agent registration and health scheduling, and a statistical certification pipeline that converts Langfuse traces into a formal report.

---

## Certification Methodology

<span class="dd-badge dd-badge-methodology">6 chapters</span>

How randomness in agent responses becomes a defensible pass/fail verdict. Read in order for the full picture, or jump to the chapter you need.

<div class="chapter-grid">
  <a class="chapter-card" href="{{ "/Methodologies/01-Introduction.html" | relative_url }}">
    <div class="chapter-num">1</div>
    <div class="chapter-body">
      <div class="chapter-title">Introduction</div>
      <div class="chapter-desc">Why ACE exists, the high-level workflow, and the core assumptions the pipeline rests on.</div>
    </div>
  </a>
  <a class="chapter-card" href="{{ "/Methodologies/02-Experiment-Design.html" | relative_url }}">
    <div class="chapter-num">2</div>
    <div class="chapter-body">
      <div class="chapter-title">Experiment Design</div>
      <div class="chapter-desc">Fault taxonomy, injection config schema, trace collection, and the ground-truth answer key.</div>
    </div>
  </a>
  <a class="chapter-card" href="{{ "/Methodologies/03-Metrics.html" | relative_url }}">
    <div class="chapter-num">3</div>
    <div class="chapter-body">
      <div class="chapter-title">Metrics</div>
      <div class="chapter-desc">Every metric AgentCert captures — how each is extracted and what it tells you about the agent.</div>
    </div>
  </a>
  <a class="chapter-card" href="{{ "/Methodologies/04-Pipeline.html" | relative_url }}">
    <div class="chapter-num">4</div>
    <div class="chapter-body">
      <div class="chapter-title">Pipeline</div>
      <div class="chapter-desc">Fault bucketing → metrics extraction → aggregation → LLM Council → hypothesis framework.</div>
    </div>
  </a>
  <a class="chapter-card" href="{{ "/Methodologies/05-Certification.html" | relative_url }}">
    <div class="chapter-num">5</div>
    <div class="chapter-body">
      <div class="chapter-title">Certification</div>
      <div class="chapter-desc">Report-builder architecture, the 12-section report reference, and certification scenarios.</div>
    </div>
  </a>
  <a class="chapter-card" href="{{ "/Methodologies/06-Observations.html" | relative_url }}">
    <div class="chapter-num">6</div>
    <div class="chapter-body">
      <div class="chapter-title">Observations</div>
      <div class="chapter-desc">TTD, PII, and hallucination findings from real runs. A living record of what ACE finds in practice.</div>
    </div>
  </a>
</div>

---

## Control Plane

<span class="dd-badge dd-badge-platform">Platform internals</span>

Architecture, registries, experiment flow, and observability internals for contributors and integrators.

<div class="topic-grid">
  <div class="topic-card">
    <div class="topic-card-title">Platform Architecture</div>
    <div class="topic-card-desc">Component map, ports, images, and deployment manifests.</div>
    <a href="{{ "/platform/architecture.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Experiment Flow</div>
    <div class="topic-card-desc">End-to-end: from clicking Run to a PDF. Every step, every owner.</div>
    <a href="{{ "/platform/experiment-flow.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Agent Registry</div>
    <div class="topic-card-desc">Registration, Helm install, UUID assignment, and health scheduling.</div>
    <a href="{{ "/platform/agent-registry.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">App Registry</div>
    <div class="topic-card-desc">Target applications (Sock Shop and beyond) and their lifecycle.</div>
    <a href="{{ "/platform/app-registry.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Fault Studio</div>
    <div class="topic-card-desc">Curated, toggleable fault collections attached to experiments.</div>
    <a href="{{ "/platform/fault-studio.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">MCP Infrastructure</div>
    <div class="topic-card-desc">Kubernetes and Prometheus MCP servers agents query via JSON-RPC.</div>
    <a href="{{ "/platform/mcp-infrastructure.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Observability</div>
    <div class="topic-card-desc">How every agent call lands in Langfuse — the dedup machinery and span model.</div>
    <a href="{{ "/platform/observability.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Certifier Architecture</div>
    <div class="topic-card-desc">Four-phase analytical pipeline internals — REST API, CLI, and data model.</div>
    <a href="{{ "/architecture.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Certification Flow</div>
    <div class="topic-card-desc">MongoDB data model for the poller-based certificate workflow.</div>
    <a href="{{ "/platform/certification-flow.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
</div>
