---
title: Deep Dive
nav_order: 4
has_children: true
nav_fold: true
---

# Deep Dive

ACE is built on **[LitmusChaos](https://litmuschaos.io)** — a Linux Foundation Networking (LFN) project — with its chaos engineering capabilities extended for agentic evaluation scenarios: trace-correlated fault injection, agent registration and health scheduling, and a statistical certification pipeline that converts Langfuse traces into a formal report.

This section covers two complementary views of the platform:

**Certification Methodology** — how fault-injection runs become a defensible certification. Read the chapters in order, or jump to what you need.

**Control Plane** — architecture, registries, experiment flow, and observability internals for contributors and integrators.

---

## Certification Methodology

1. **[Introduction](01-Introduction.md)** — why ACE exists, the high-level workflow, and the assumptions the pipeline rests on.
2. **[Experiment Design](02-Experiment-Design.md)** — experimentation principles, the fault taxonomy, fault-config schema, trace collection, and certification scenarios.
3. **[Metrics](03-Metrics.md)** — the full metrics reference.
4. **[Pipeline](04-Pipeline.md)** — fault bucketing → metrics extraction → aggregation & the LLM Council → the hypothesis framework.
5. **[Certification](05-Certification.md)** — report-builder architecture, the 12-section report reference, and certification scenarios.
6. **[Observations](06-Observations.md)** — TTD / PII / hallucination findings and hypothesis validation.
