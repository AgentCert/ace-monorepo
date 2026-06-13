---
title: "Setup"
nav_order: 2
has_children: true
nav_fold: true
---

# You're 5 minutes from your first certification report.

In a single `docker compose up -d` you get a complete platform: Kubernetes chaos injection, an LLM observability layer, a statistical certification pipeline, and a UI to drive it all. No infrastructure expertise required.

This guide takes you from zero to a running certification experiment.

---

## Quick Start

**Prerequisites: Docker 28+ and the compose plugin. That's it.**

```bash
# 1. Clone with submodules
git clone --recurse-submodules https://github.com/AgentCert/ace-monorepo
cd ace-monorepo

# 2. Configure — wizard asks only for your Azure OpenAI key
./scripts/setup.sh

# 3. Start everything
docker compose up -d
```

Open **[http://localhost:2001](http://localhost:2001)** · login `admin / litmus`

First run takes 5–15 minutes to build images; subsequent starts take seconds.

> **Stuck?** Join [Slack ↗](https://join.slack.com/t/agentcertific-evj3152/shared_invite/zt-4066ekqer-uIT~K_URfwiC15KlwT5Pjw) — the fastest way to get unblocked.

---

## Prerequisites

You need **Docker** and the **compose plugin**. Nothing else — no Go, Node, kubectl, kind, or Helm needs to be on your host. The stack builds its own images and provisions Kubernetes automatically.

| Tool | Min version | Check | Install |
|---|---|---|---|
| Docker Engine | 28+ | `docker --version` | [docs.docker.com ↗](https://docs.docker.com/engine/install/) |
| Docker Compose plugin | v2.20+ | `docker compose version` | bundled with recent Docker |
| User in `docker` group | — | `groups \| grep docker` | `sudo usermod -aG docker $USER` then re-login |

**Azure OpenAI** — the Flash ITOps agent uses Azure OpenAI for LLM calls. You need an endpoint and API key. Every other credential is auto-generated.

---

## What comes up

One command starts the entire platform:

| Service | What it does | URL |
|---|---|---|
| **Web UI** | AgentCert console — agents, experiments, reports | [localhost:2001](http://localhost:2001) |
| **GraphQL API** | Control plane that drives all experiment logic | localhost:8081 |
| **Auth** | JWT + OIDC via Dex | :3000 / :3030 |
| **MongoDB** | Persistence (replica set `rs0`) | :27017 |
| **LiteLLM** | LLM gateway in front of Azure OpenAI | localhost:14000 |
| **Langfuse** | Trace store — every agent decision recorded here | [localhost:4000](http://localhost:4000) |
| **Certifier** | 4-phase pipeline → 12-section PDF report | [localhost:8000/docs](http://localhost:8000/docs) |
| **cluster-init** | One-shot: provisions Kubernetes (or reuses existing) | — |

---

## System Architecture

ACE composes four subsystems. Understanding how they connect makes debugging and extending the platform straightforward.

```
┌──────────────────────────────────────────────────────────┐
│                  ACE Control Plane                        │
│  Web UI :2001  ←→  GraphQL :8081  ←→  Auth :3000         │
│                         │                                 │
│                   MongoDB :27017                          │
└─────────────────────┬────────────────────────────────────┘
                      │  Argo Workflow + Helm
                      ▼
┌──────────────────────────────────────────────────────────┐
│         Kubernetes Cluster (kind / AKS / your own)        │
│                                                           │
│  SockShop (SUT)    Flash ITOps Agent    Chaos Faults      │
│  + Prometheus   ◀▶ + agent-sidecar  ←  (LitmusChaos)     │
│  + Grafana         + MCP servers                          │
└─────────────────────┬────────────────────────────────────┘
                      │ LLM calls (OTEL traced)
                      ▼
               LiteLLM :14000  (Azure OpenAI proxy)
                      │ trace spans
                      ▼
               Langfuse :4000  (every call recorded)
                      │
                      ▼
┌──────────────────────────────────────────────────────────┐
│  Certifier :8000  — 4-phase pipeline                      │
│                                                           │
│  Phase 0 · Fault Bucketing                                │
│    LLM classifies trace events into per-fault windows     │
│                                                           │
│  Phase 1 · Metrics Extraction  (×30 runs)                 │
│    TTD, TTR, hallucination score, PII rate per fault      │
│                                                           │
│  Phase 2 · Statistical Aggregation                        │
│    Mean, P95, confidence intervals across all runs        │
│                                                           │
│  Phase 3 · Certification                                  │
│    12-section report with pass/fail verdict → PDF         │
└──────────────────────────────────────────────────────────┘
```

**One experiment run, step by step:**

1. A fault is selected from the Fault Library (application / network / resource)
2. LitmusChaos injects it into SockShop on Kubernetes
3. Flash agent investigates via MCP tools — every call traced through OTEL → LiteLLM → Langfuse
4. Certifier reads the trace, buckets it, extracts metrics, stores them in MongoDB
5. After 30 runs: aggregation → hypothesis testing → 12-section report → PDF

---

## Choosing your Kubernetes route

The platform drives chaos experiments on a Kubernetes cluster. Set `CLUSTER_MODE` in `.env`:

| Route | Your situation | `CLUSTER_MODE` | Guide |
|---|---|---|---|
| **Route 1** | Local cluster already running (kind/minikube/k3s) | `local` | [→](./route-1-existing-cluster.md) |
| **Route 2** | Fresh machine, nothing installed | `fresh` | [→](./route-2-fresh-kind.md) |
| **Route 3** | Cloud cluster (AKS / EKS / GKE) | `cloud` | [→](./route-3-cloud-aks.md) |

`CLUSTER_MODE=auto` (the default) probes for an existing cluster first and creates one if none is found.

---

## Configuration

The wizard handles 90% of it. The only values you **must** provide are Azure OpenAI credentials:

```bash
AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com/
AZURE_OPENAI_API_KEY=sk-...
AZURE_OPENAI_DEPLOYMENT=gpt-4o
```

Everything else — MongoDB passwords, Langfuse keys, JWT secrets — is auto-generated. Full reference: [Configuration & Ports →](./configuration.md)

---

## After the stack is up

Follow the experiment guide to run your first certification:

- **[Run your first experiment →](./running-an-experiment.md)** — UI walkthrough from login to report
- **[Managing & restarting services →](./managing-services.md)** — day-to-day commands

### Useful commands

```bash
docker compose ps                                          # health check
docker compose logs -f graphql                             # control plane logs
docker compose logs -f certifier                           # pipeline logs
docker compose up -d --force-recreate auth graphql web app # reload .env
docker compose down                                        # stop (keep data)
docker compose down -v                                     # stop + wipe all data
```

> `docker compose restart` does **not** reload `.env`. Use `--force-recreate` when you change env vars.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cluster-init` exits non-zero | `docker compose logs cluster-init` — usually Docker socket permissions or missing kind config |
| UI at :2001 shows blank | GraphQL not ready yet — wait 30s, then check `docker compose logs graphql` |
| Langfuse key errors | `docker compose restart langfuse-worker langfuse-server` — auto-provisioning runs on first boot only |
| LiteLLM 401 errors | Check `AZURE_OPENAI_API_KEY` in `.env`, then `docker compose up -d --force-recreate litellm` |

Still stuck? **[Join Slack ↗](https://join.slack.com/t/agentcertific-evj3152/shared_invite/zt-4066ekqer-uIT~K_URfwiC15KlwT5Pjw)** or [open a GitHub issue ↗](https://github.com/AgentCert/ace-monorepo/issues).
