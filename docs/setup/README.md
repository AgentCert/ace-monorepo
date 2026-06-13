---
title: "Setup"
nav_order: 2
has_children: true
nav_fold: true
---

# You're minutes away from your first certification report.

One command starts the entire platform: Kubernetes chaos injection, an LLM observability layer, a statistical certification pipeline, and a UI to drive it all. No Go, Node, kubectl, kind, or Helm needs to be on your host — the stack builds its own images and provisions Kubernetes automatically.

---

## Quick Start

**Prerequisites: Docker 28+ and the compose plugin. That's it.**

<div class="qs-steps">
  <div class="qs-step">
    <div class="qs-num">1</div>
    <div class="qs-body">
      <strong>Clone with submodules</strong>
      <pre><code>git clone --recurse-submodules https://github.com/AgentCert/ace-monorepo
cd ace-monorepo</code></pre>
    </div>
  </div>
  <div class="qs-step">
    <div class="qs-num">2</div>
    <div class="qs-body">
      <strong>Configure — wizard walks you through LLM providers, flash-agent model, and cluster mode</strong>
      <pre><code>./scripts/setup.sh</code></pre>
    </div>
  </div>
  <div class="qs-step">
    <div class="qs-num">3</div>
    <div class="qs-body">
      <strong>Start everything</strong>
      <pre><code>docker compose up -d</code></pre>
    </div>
  </div>
</div>

Open **[http://localhost:2001](http://localhost:2001)** · login `admin / litmus`

<div class="callout callout-info">
<span class="callout-title">First run</span>
Building images takes 5–15 minutes; subsequent starts take seconds.<br>
<strong>Stuck?</strong> Join <a href="https://join.slack.com/t/agentcertific-evj3152/shared_invite/zt-4066ekqer-uIT~K_URfwiC15KlwT5Pjw">Slack ↗</a> — the fastest way to get unblocked.
</div>

---

## Prerequisites

You need **Docker** and the **compose plugin**. Nothing else.

| Tool | Min version | Check | Install |
|---|---|---|---|
| Docker Engine | 28+ | `docker --version` | [docs.docker.com ↗](https://docs.docker.com/engine/install/) |
| Docker Compose plugin | v2.20+ | `docker compose version` | bundled with recent Docker |
| User in `docker` group | — | `groups \| grep docker` | `sudo usermod -aG docker $USER` then re-login |

**LLM credentials** — you need at least one of:

<div class="route-grid" style="grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); margin-top: .6rem; margin-bottom: .8rem;">
  <div class="route-card">
    <div class="route-label">Azure OpenAI</div>
    <div class="route-card-when">Powers both the <strong>flash-agent</strong> and the <strong>certifier</strong>. Required if you want certification reports.</div>
  </div>
  <div class="route-card">
    <div class="route-label">Google Gemini</div>
    <div class="route-card-when">Powers the <strong>flash-agent</strong> only. Provides <code>gemini-3-flash</code>, <code>gemini-2.5-flash</code>, <code>gemini-2.5-flash-lite</code>.</div>
  </div>
  <div class="route-card">
    <div class="route-label">OpenRouter</div>
    <div class="route-card-when">Powers the <strong>flash-agent</strong> only. Provides the <code>auto-free</code> alias for no-cost routing.</div>
  </div>
</div>

<div class="callout callout-warning">
<span class="callout-title">Certifier always needs Azure OpenAI</span>
The 4-phase certification pipeline calls Azure OpenAI directly (standard model, reasoning model, embedding model). If you skip Azure credentials the flash-agent can still run experiments via Gemini or OpenRouter, but the certifier will not produce reports.
</div>

---

## What Comes Up

One `docker compose up -d` starts the full platform:

<div class="svc-grid">
  <div class="svc-card">
    <div class="svc-card-name">Web UI</div>
    <div class="svc-card-desc">AgentCert console — agents, experiments, reports</div>
    <a href="http://localhost:2001" class="svc-card-port">:2001</a>
  </div>
  <div class="svc-card">
    <div class="svc-card-name">GraphQL API</div>
    <div class="svc-card-desc">Control plane: registries, experiment logic, Helm bridge</div>
    <span class="svc-card-port">:8081</span>
  </div>
  <div class="svc-card">
    <div class="svc-card-name">Auth</div>
    <div class="svc-card-desc">JWT issuance + OIDC via Dex</div>
    <span class="svc-card-port">:3000 / :3030</span>
  </div>
  <div class="svc-card">
    <div class="svc-card-name">MongoDB</div>
    <div class="svc-card-desc">Sole persistence layer (replica set <code>rs0</code>)</div>
    <span class="svc-card-port">:27017</span>
  </div>
  <div class="svc-card">
    <div class="svc-card-name">LiteLLM</div>
    <div class="svc-card-desc">LLM gateway — proxies calls to Azure OpenAI</div>
    <a href="http://localhost:14000" class="svc-card-port">:14000</a>
  </div>
  <div class="svc-card">
    <div class="svc-card-name">Langfuse</div>
    <div class="svc-card-desc">Trace store — every agent decision recorded here</div>
    <a href="http://localhost:4000" class="svc-card-port">:4000</a>
  </div>
  <div class="svc-card">
    <div class="svc-card-name">Certifier</div>
    <div class="svc-card-desc">4-phase pipeline → 12-section certification report</div>
    <a href="http://localhost:8000/docs" class="svc-card-port">:8000/docs</a>
  </div>
  <div class="svc-card">
    <div class="svc-card-name">cluster-init</div>
    <div class="svc-card-desc">One-shot: provisions Kubernetes or reuses existing cluster</div>
    <span class="svc-card-port">one-shot</span>
  </div>
</div>

---

## System Architecture

ACE composes four subsystems. Understanding how they connect makes debugging and extending the platform straightforward.

<div class="arch-diagram">

  <div class="arch-box arch-box-cp">
    <div class="arch-box-title">ACE Control Plane</div>
    <div class="arch-services">
      <div class="arch-svc">Web UI <span class="arch-svc-port">:2001</span></div>
      <span class="arch-arrow-h">⟷</span>
      <div class="arch-svc">GraphQL API <span class="arch-svc-port">:8081</span></div>
      <span class="arch-arrow-h">⟷</span>
      <div class="arch-svc">Auth <span class="arch-svc-port">:3000 / :3030</span></div>
    </div>
    <div class="arch-services" style="margin-top:.4rem;">
      <div class="arch-svc">MongoDB <span class="arch-svc-port">:27017</span></div>
    </div>
  </div>

  <div class="arch-connector">
    <div class="arch-connector-line"></div>
    <div class="arch-connector-label">Argo Workflow + Helm install</div>
    <div class="arch-connector-line"></div>
    <div class="arch-connector-arrow">▼</div>
  </div>

  <div class="arch-box arch-box-k8s">
    <div class="arch-box-title">Kubernetes Cluster — kind / AKS / your own</div>
    <div class="arch-services">
      <div class="arch-svc">SockShop (SUT)<span class="arch-svc-note">Prometheus · Grafana</span></div>
      <span class="arch-arrow-h">⟷</span>
      <div class="arch-svc">Flash ITOps Agent<span class="arch-svc-note">agent-sidecar · MCP servers</span></div>
      <span class="arch-arrow-h">←</span>
      <div class="arch-svc">Chaos Faults<span class="arch-svc-note">LitmusChaos operator</span></div>
    </div>
  </div>

  <div class="arch-connector">
    <div class="arch-connector-line"></div>
    <div class="arch-connector-label">LLM calls · OTEL traced</div>
    <div class="arch-connector-line"></div>
    <div class="arch-connector-arrow">▼</div>
  </div>

  <div class="arch-single">
    <div class="arch-pill arch-pill-amber">
      LiteLLM proxy
      <span class="arch-pill-port">:14000</span>
      <span class="arch-pill-note">Azure OpenAI · Gemini · OpenRouter</span>
    </div>
  </div>

  <div class="arch-connector">
    <div class="arch-connector-line"></div>
    <div class="arch-connector-label">trace spans</div>
    <div class="arch-connector-line"></div>
    <div class="arch-connector-arrow">▼</div>
  </div>

  <div class="arch-single">
    <div class="arch-pill arch-pill-blue">
      Langfuse
      <span class="arch-pill-port">:4000</span>
      <span class="arch-pill-note">trace store · every agent decision recorded</span>
    </div>
  </div>

  <div class="arch-connector">
    <div class="arch-connector-line"></div>
    <div class="arch-connector-arrow">▼</div>
  </div>

  <div class="arch-box arch-box-cert">
    <div class="arch-box-title">Certifier — 4-phase pipeline · :8000</div>
    <div class="arch-phases">
      <div class="arch-phase">
        <span class="arch-phase-num">Phase 0 · </span>Fault Bucketing
        <span class="arch-phase-desc">LLM classifies trace events into per-fault windows</span>
      </div>
      <div class="arch-phase">
        <span class="arch-phase-num">Phase 1 · </span>Metrics Extraction
        <span class="arch-phase-desc">TTD · TTR · hallucination score · PII rate  ×30 runs</span>
      </div>
      <div class="arch-phase">
        <span class="arch-phase-num">Phase 2 · </span>Statistical Aggregation
        <span class="arch-phase-desc">mean · P95 · confidence intervals across all runs</span>
      </div>
      <div class="arch-phase">
        <span class="arch-phase-num">Phase 3 · </span>Certification
        <span class="arch-phase-desc">12-section report · pass/fail verdict → PDF</span>
      </div>
    </div>
  </div>

</div>

**One experiment run, step by step:**

1. A fault is selected from the Fault Library (application / network / resource)
2. LitmusChaos injects it into SockShop on Kubernetes
3. Flash agent investigates via MCP tools — every call traced through OTEL → LiteLLM → Langfuse
4. Certifier reads the trace, buckets it, extracts metrics, stores them in MongoDB
5. After 30 runs: aggregation → hypothesis testing → 12-section report → PDF

---

## Choose Your Kubernetes Route

Set `CLUSTER_MODE` in `.env` to match your situation:

<div class="route-grid">
  <div class="route-card">
    <div class="route-label">Route 1</div>
    <div class="route-card-title">Existing cluster</div>
    <div class="route-card-env">CLUSTER_MODE=local</div>
    <div class="route-card-when">You already have a working kind / minikube / k3s cluster and a valid kubeconfig. Lightest path — only the ACE control plane starts.</div>
    <a href="{{ "/setup/route-1-existing-cluster.html" | relative_url }}" class="route-card-link">Setup guide →</a>
  </div>
  <div class="route-card">
    <div class="route-label">Route 2</div>
    <div class="route-card-title">Fresh machine</div>
    <div class="route-card-env">CLUSTER_MODE=fresh</div>
    <div class="route-card-when">Clean machine with Docker but no Kubernetes yet. <code>cluster-init</code> creates a local kind cluster for you. The true one-command path.</div>
    <a href="{{ "/setup/route-2-fresh-kind.html" | relative_url }}" class="route-card-link">Setup guide →</a>
  </div>
  <div class="route-card">
    <div class="route-label">Route 3</div>
    <div class="route-card-title">Cloud cluster</div>
    <div class="route-card-env">CLUSTER_MODE=cloud</div>
    <div class="route-card-when">Your Kubernetes cluster lives in the cloud (AKS / EKS / GKE) and your VM is already logged in to it. ACE runs on the VM and drives the remote cluster.</div>
    <a href="{{ "/setup/route-3-cloud-aks.html" | relative_url }}" class="route-card-link">Setup guide →</a>
  </div>
</div>

`CLUSTER_MODE=auto` (the default) probes for an existing cluster first and creates a kind cluster if none is found.

---

## Configuration

The wizard handles 90% of it. The only values you **must** provide are Azure OpenAI credentials:

```bash
AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com/
AZURE_OPENAI_API_KEY=sk-...
AZURE_OPENAI_DEPLOYMENT=gpt-4o
```

Everything else — MongoDB passwords, Langfuse keys, JWT secrets — is auto-generated.

Full reference: [Configuration & Ports →]({{ "/setup/configuration.html" | relative_url }})

---

## After the Stack Is Up

Follow the experiment guide to run your first certification:

- **[Run your first experiment →]({{ "/setup/running-an-experiment.html" | relative_url }})** — UI walkthrough from login to report
- **[Managing & restarting services →]({{ "/setup/managing-services.html" | relative_url }})** — day-to-day commands

### Useful commands

```bash
docker compose ps                                          # health check
docker compose logs -f graphql                             # control plane logs
docker compose logs -f certifier                           # pipeline logs
docker compose up -d --force-recreate auth graphql web app # reload .env
docker compose down                                        # stop (keep data)
docker compose down -v                                     # stop + wipe all data
```

<div class="callout callout-warning">
<span class="callout-title">⚠ Restart vs recreate</span>
<code>docker compose restart</code> does <strong>not</strong> reload <code>.env</code>. Use <code>--force-recreate</code> when you change env vars.
</div>

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cluster-init` exits non-zero | `docker compose logs cluster-init` — usually Docker socket permissions or missing kind config |
| UI at :2001 shows blank | GraphQL not ready yet — wait 30 s, then check `docker compose logs graphql` |
| Langfuse key errors | `docker compose restart langfuse-worker langfuse-server` — auto-provisioning runs on first boot only |
| LiteLLM 401 errors | Check `AZURE_OPENAI_API_KEY` in `.env`, then `docker compose up -d --force-recreate litellm` |

Still stuck? **[Join Slack ↗](https://join.slack.com/t/agentcertific-evj3152/shared_invite/zt-4066ekqer-uIT~K_URfwiC15KlwT5Pjw)** or [open a GitHub issue ↗](https://github.com/AgentCert/ace-monorepo/issues).
