---
title: "Setup"
nav_order: 2
has_children: true
nav_fold: true
---

# You're minutes away from your first certification report.

One command starts the entire platform: a Kubernetes cluster, MongoDB, the AgentCert
control plane (auth + GraphQL + UI), LiteLLM, Langfuse, and the Certifier.

---

## Quick Start

**Prerequisites: Docker 28+, kind, kubectl. That's it.**

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
      <strong>Run the setup wizard — configures .env, creates kind cluster, deploys to Kubernetes</strong>
      <pre><code>./scripts/setup.sh</code></pre>
      <p>Answer the Azure OpenAI prompts, accept defaults for everything else, then answer <strong>Y</strong> to deploy at the end.</p>
    </div>
  </div>
</div>

Open **[http://localhost:2001](http://localhost:2001)** · login `admin / litmus`

<div class="callout callout-info">
<span class="callout-title">First run</span>
Pulling images and creating the kind cluster takes 3–10 minutes; subsequent
<code>./scripts/setup.sh</code> runs take seconds.<br>
<strong>Stuck?</strong> Join <a href="https://join.slack.com/t/agentcertific-evj3152/shared_invite/zt-4066ekqer-uIT~K_URfwiC15KlwT5Pjw">Slack ↗</a> — the fastest way to get unblocked.
</div>

---

## Prerequisites

| Tool | Min version | Check | Install |
|---|---|---|---|
| Docker Engine | 28+ | `docker --version` | [docs.docker.com ↗](https://docs.docker.com/engine/install/) |
| User in `docker` group | — | `groups \| grep docker` | `sudo usermod -aG docker $USER` then re-login |
| kind | v0.20+ | `kind version` | [kind releases ↗](https://github.com/kubernetes-sigs/kind/releases) or `go install sigs.k8s.io/kind@latest` |
| kubectl | v1.27+ | `kubectl version --client` | `sudo snap install kubectl --classic` or [kubernetes.io ↗](https://kubernetes.io/docs/tasks/tools/) |
| git | any | `git --version` | `sudo apt-get install git` |

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

`./scripts/setup.sh` deploys the full platform into a kind cluster:

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
    <div class="svc-card-desc">LLM gateway — proxies calls to Azure OpenAI / Gemini / OpenRouter</div>
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
    <a href="http://localhost:18000/docs" class="svc-card-port">:18000/docs</a>
  </div>
</div>

All services run as Kubernetes Deployments in the `ace` namespace inside a local
kind cluster. Ports are exposed via NodePort services and kind's `extraPortMappings`
so they are reachable on `localhost` from the VM.

---

## System Architecture

ACE composes four subsystems. Understanding how they connect makes debugging and extending the platform straightforward.

<div class="arch-diagram">

  <div class="arch-box arch-box-cp">
    <div class="arch-box-title">ACE Control Plane — namespace: ace</div>
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
    <div class="arch-box-title">Certifier — 4-phase pipeline · :18000</div>
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

## Choose Your Route

<div class="route-grid">
  <div class="route-card">
    <div class="route-label">Route 1</div>
    <div class="route-card-title">Existing local cluster</div>
    <div class="route-card-env">CLUSTER_MODE=local</div>
    <div class="route-card-when">You already have a kind / minikube / k3s cluster and <code>kubectl</code> points at it. The full ACE stack is deployed into that cluster.</div>
    <a href="{{ "/setup/route-1-existing-cluster.html" | relative_url }}" class="route-card-link">Setup guide →</a>
  </div>
  <div class="route-card">
    <div class="route-label">Route 2</div>
    <div class="route-card-title">Fresh VM (kind)</div>
    <div class="route-card-env">CLUSTER_MODE=fresh</div>
    <div class="route-card-when">Clean VM with Docker + kind + kubectl but no cluster yet. The wizard creates a kind cluster with the right port mappings. Services are on <code>localhost</code> immediately.</div>
    <a href="{{ "/setup/route-2-fresh-kind.html" | relative_url }}" class="route-card-link">Setup guide →</a>
  </div>
  <div class="route-card">
    <div class="route-label">Route 3</div>
    <div class="route-card-title">Cloud cluster (AKS / EKS / GKE)</div>
    <div class="route-card-env">CLUSTER_MODE=local</div>
    <div class="route-card-when">VM is already logged in to a cloud cluster (<code>az aks get-credentials</code> etc.) and <code>kubectl get nodes</code> works. ACE deploys into the cloud cluster; browser UIs exposed via LoadBalancer.</div>
    <a href="{{ "/setup/route-3-cloud-aks.html" | relative_url }}" class="route-card-link">Setup guide →</a>
  </div>
  <div class="route-card">
    <div class="route-label">Local Dev</div>
    <div class="route-card-title">Host processes</div>
    <div class="route-card-env">start-agentcert-v2.sh</div>
    <div class="route-card-when">Actively developing the Go backend or React frontend. Auth, GraphQL, and the UI run directly on the host with hot-reload; MongoDB, Langfuse, LiteLLM, and the Certifier run in Docker.</div>
    <a href="{{ "/setup/local-dev.html" | relative_url }}" class="route-card-link">Setup guide →</a>
  </div>
</div>

---

## After the Stack Is Up

Follow the experiment guide to run your first certification:

- **[Run your first experiment →]({{ "/setup/running-an-experiment.html" | relative_url }})** — UI walkthrough from login to report
- **[Managing & restarting services →]({{ "/setup/managing-services.html" | relative_url }})** — day-to-day kubectl commands

### Useful commands

```bash
kubectl get pods -n ace                                    # health check
kubectl logs -n ace deploy/graphql -f                      # control plane logs
kubectl logs -n ace deploy/certifier -f                    # pipeline logs
kubectl rollout restart -n ace deploy/auth deploy/graphql deploy/web deploy/certifier  # reload config
kind delete cluster --name agentcert                       # tear down everything
```

<div class="callout callout-warning">
<span class="callout-title">⚠ Applying .env changes</span>
After editing <code>.env</code>, re-run <code>./scripts/setup.sh</code> and answer Y to deploy. It recreates the <code>ace-env</code> Secret and rolls out affected deployments.
</div>

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Pods stuck in `Pending` | `kubectl describe pod -n ace <pod>` — usually a PVC or image pull issue |
| UI at :2001 shows blank | GraphQL not ready — `kubectl logs -n ace deploy/graphql` |
| Langfuse key errors | Delete and recreate the langfuse-web pod: `kubectl rollout restart -n ace deploy/langfuse-web` |
| LiteLLM 401 errors | Check `AZURE_OPENAI_API_KEY` in `.env`, re-run `./scripts/setup.sh` |
| `kind` cluster missing port mappings | Run `./scripts/setup.sh` — it detects missing port bindings and offers to recreate the cluster |

Still stuck? **[Join Slack ↗](https://join.slack.com/t/agentcertific-evj3152/shared_invite/zt-4066ekqer-uIT~K_URfwiC15KlwT5Pjw)** or [open a GitHub issue ↗](https://github.com/AgentCert/ace-monorepo/issues).
