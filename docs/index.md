---
title: Home
nav_order: 1
description: >-
  Agent Certification Engine — evaluate, fault-inject, and certify autonomous
  agents under controlled chaos. One-command setup and a reproducible
  certification pipeline.
---

# Agent Certification Engine
{: .fs-9 }

Evaluate, fault-inject, and **certify autonomous agents** under controlled chaos
conditions — with reproducible, evidence-backed certification reports.
{: .fs-6 .fw-300 }

[Get started](setup/README.md){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }
[Run an experiment](setup/running-an-experiment.md){: .btn .fs-5 .mb-4 .mb-md-0 .mr-2 }
[View on GitHub](https://github.com/AgentCert/ace-monorepo){: .btn .fs-5 .mb-4 .mb-md-0 }

---

## What ACE does

A GraphQL control plane drives chaos experiments on Kubernetes; the certifier
consumes the resulting Langfuse traces and emits a multi-phase certification
artifact (JSON + PDF) — so you can answer *"how does this agent behave under
failure, and can I trust it in production?"* with evidence.

> **Pipeline:** Phase 0 (trace ingest) → Phase 1 (fault bucketing) → Phase 2 (statistical aggregation) → Phase 3 (certificate build).

---

## Quick start

The whole platform — Kubernetes, MongoDB, the control plane, LiteLLM, Langfuse,
and the certifier — comes up with **one command**:

```bash
./scripts/setup.sh      # creates .env, asks only what matters (Azure OpenAI)
docker compose up -d    # builds images, provisions Kubernetes, starts everything
```

Then open **[http://localhost:2001](http://localhost:2001)** and log in with
`admin` / `litmus`.

No host-side Go / Node / kubectl toolchain required — the stack builds its own
images and provisions a Kubernetes cluster if you don't have one.

### Pick your path

| Your situation | Guide |
|---|---|
| 🖥️ You already run a local cluster (kind / minikube / k3s) | [Route 1 · Existing cluster](setup/route-1-existing-cluster.md) |
| ✨ Fresh machine — let compose create the cluster | [Route 2 · Fresh kind](setup/route-2-fresh-kind.md) |
| ☁️ Your Kubernetes is in the cloud (AKS / EKS / GKE) | [Route 3 · Cloud](setup/route-3-cloud-aks.md) |

---

## Explore the docs

- **[Setup & operations](setup/README.md)** — the three cluster routes, the
  [configuration & ports reference](setup/configuration.md), and the
  [experiment walkthrough](setup/running-an-experiment.md).
- **[Architecture](architecture.md)** — the control plane + certifier end to end
  (plus an [interactive workflow animation](animated_archiecture/agentcert_workflow_animation.html)).
- **[Methodology](Methodologies/index.md)** — the certification methodology, from
  experiment design through the report.
- **[Reference](reference.md)** — API, storage model, RAI compliance, and testing.

*(Full navigation is in the sidebar on the left, with search.)*

---

## What's in the box

ACE is a monorepo of independently-versioned components:

| Component | Role |
|---|---|
| **AgentCert** | GraphQL control plane, auth, and web UI |
| **certifier** | Certification engine (FastAPI pipeline → JSON + PDF) |
| **flash-agent** | The agent under test |
| **agent-sidecar** | Proxies the agent's LLM / MCP traffic |
| **app-charts** / **agent-charts** | Helm charts + install images for the app and the agent |
| **chaos-charts** / **litmus-go** | Chaos experiment & fault definitions and executors |
| **agentcert-stack** | Deployment assets (LiteLLM setup, etc.) |

---

<sub>Repository: <a href="https://github.com/AgentCert/ace-monorepo">AgentCert/ace-monorepo</a> · Released under the MIT License.</sub>
