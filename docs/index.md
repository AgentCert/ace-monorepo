# ACE Wiki

**ACE** stands for **Agent Certification Engine** — a platform for evaluating,
fault-injecting, and certifying autonomous agents under controlled chaos
conditions. This monorepo aggregates every component required to run the
platform end-to-end.

- **Purpose.** Produce reproducible certification reports that quantify how an
  agent behaves under faults, with evidence (traces, metrics, ground truth)
  preserved at every phase.
- **Architecture.** A GraphQL control plane (AgentCert) drives chaos experiments
  on Kubernetes; the certifier consumes the resulting Langfuse traces and emits
  a multi-phase certification artifact (JSON + PDF).
- **Pipeline.** Phase 0 (trace ingest) → Phase 1 (fault bucketing) →
  Phase 2 (statistical aggregation) → Phase 3 (certificate build).
- **Local stack.** MongoDB for persistence, Langfuse for OTEL trace storage,
  LiteLLM as the unified LLM gateway in front of Azure OpenAI.

## Where to next

- [**Try it out**](quickstart.md) — get a local ACE stack running in minutes.
- [Source on GitHub](https://github.com/AgentCert/ace-monorepo)
