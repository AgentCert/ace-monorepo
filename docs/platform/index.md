---
title: "Control Plane"
parent: "Deep Dive"
nav_order: 7
has_children: true
nav_fold: true
---

# Control Plane

The AgentCert control plane is the orchestration layer that drives every experiment: the GraphQL API, three registries (agents, apps, fault studios), the in-cluster subscriber, and the Langfuse tracing layer that correlates every agent decision.

It is built on a fork of **LitmusChaos** — a [Linux Foundation Networking (LFN)](https://lfnetworking.org/) project — with the chaos infrastructure extended to support agentic evaluation scenarios: agent registration, trace-correlated fault injection, and the statistical certification pipeline.

- **[Platform Architecture](architecture.md)** — component map, ports, images, deployment manifests.
- **[Experiment Flow](experiment-flow.md)** — end-to-end: from clicking *Run* to a PDF.
- **[Agent Registry](agent-registry.md)** — how agents are registered, helmed, and health-checked.
- **[App Registry](app-registry.md)** — target applications (Sock Shop and beyond).
- **[Fault Studio](fault-studio.md)** — curated, toggleable fault collections.
- **[MCP Infrastructure](mcp-infrastructure.md)** — Kubernetes and Prometheus MCP servers agents query.
- **[Observability](observability.md)** — how every agent call lands in Langfuse.
