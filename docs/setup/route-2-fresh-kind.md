---
title: "Route 2 · Fresh VM + kind"
parent: "Setup"
nav_order: 3
---

# Route 2 — Fresh VM Setup (kind cluster)

<div class="callout callout-success">
<span class="callout-title">Use this route when…</span>
You have a clean VM with no existing Kubernetes cluster. <code>scripts/setup.sh</code>
creates a local <a href="https://kind.sigs.k8s.io">kind</a> cluster with the correct
port mappings, deploys all ACE services to it, and prints access URLs — one command
from zero to running platform.
</div>

---

## 1. Install Prerequisites

```bash
# Docker
sudo apt-get update && sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
newgrp docker   # or log out and back in

# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# kubectl
sudo snap install kubectl --classic
# or: curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
#     chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# helm (the default deploy method)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# git + python3 (setup's helpers use only the standard library)
sudo apt-get install -y git python3
```

Verify:

```bash
docker --version      # Docker 28+
kind version          # kind v0.20+
kubectl version --client
helm version --short  # v3.12+
```

`./scripts/setup.sh` re-checks all of these (via `scripts/check-prerequisites.sh`) and prints
the exact fix for anything missing.

---

## 2. Clone the Repo

```bash
git clone --recurse-submodules https://github.com/AgentCert/ace-monorepo
cd ace-monorepo
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

This manual command is optional: `./scripts/setup.sh` detects and initializes
missing submodules before it builds the platform.

---

## 3. Run the Setup Wizard

```bash
./scripts/setup.sh
```

The wizard asks for your LLM credentials; press **Enter** at every other prompt to take the
stable defaults. In order, it:

1. Checks prerequisites, creates `.env` from `.env.example` (or updates yours) and picks
   collision-free host ports and a per-user instance name (`ACE_INSTANCE_NAME`) — safe on a
   shared host.
2. Asks **Express or Guided** (`Enter` = guided) and **Build images?** (`Enter` = *build ALL
   locally*). All first-party images — control plane, installers, agents, sidecar, ITBench
   runner — and the **hub bundle** (app/agent/fault catalogs and charts) are built from this
   checkout, so what runs is exactly what you cloned. Experiment image sources default to
   **local** for the same reason.
3. Asks for Azure OpenAI / Gemini / OpenRouter keys and optionally a local Ollama model.
4. Asks **Deploy?** — `h` Helm (default) or `k` plain `kubectl apply`; `n` skips.

With a deploy choice it then, unattended:

- Creates the kind cluster `agentcert-<ACE_INSTANCE_NAME>` with all required port mappings
- Builds and side-loads the hub bundle, then deploys the platform (Helm chart `deploy/helm/ace`,
  or the manifests in `deploy/k8s/`) including a platform-owned metrics-server
- Waits for the experiment images; **stops with an error** if any required image failed to build
- Registers the `ace-local` chaos infrastructure, installs its subscriber into `litmus` and waits
  until it is connected — no UI steps needed
- Seeds the demo experiments and prints the access URLs

Re-running `./scripts/setup.sh` (or `--restart` to reuse the saved answers) is idempotent.

#### If you chose Helm

The wizard generates `deploy/helm/ace/values-env.yaml` from your `.env` and runs, in effect:

```bash
helm upgrade --install ace deploy/helm/ace \
  -n ace --create-namespace \
  -f deploy/helm/ace/values-env.yaml \
  --set-string chartsHub.bundleImage=agentcert/ace-hub-bundle:local \
  --set chartsHub.bundleImagePullPolicy=Never
```

Always redeploy through `./scripts/setup.sh --restart` rather than raw `helm upgrade`: the hub
bundle must be rebuilt and side-loaded first, and the post-deploy steps (host-service wiring,
infrastructure registration, subscriber sync) only run from the script. Use `helm history ace -n ace`
and `helm rollback ace -n ace` for release management. See
[Managing services]({{ "/setup/managing-services.html" | relative_url }}) for more.

---

## 4. Verify

```bash
kubectl get pods -n ace           # all pods Running / Ready
kubectl get nodes                 # kind cluster node shows Ready
```

Expected output (all pods Running):

```
NAME                              READY   STATUS    RESTARTS   AGE
auth-xxxx                         1/1     Running   0          3m
certifier-xxxx                    1/1     Running   0          3m
clickhouse-xxxx                   1/1     Running   0          3m
graphql-xxxx                      1/1     Running   0          3m
langfuse-web-xxxx                 1/1     Running   0          3m
langfuse-worker-xxxx              1/1     Running   0          3m
litellm-xxxx                      1/1     Running   0          3m
minio-xxxx                        1/1     Running   0          3m
mongodb-0                         1/1     Running   0          3m
postgres-xxxx                     1/1     Running   0          3m
redis-xxxx                        1/1     Running   0          3m
web-xxxx                          1/1     Running   0          3m
```

Quick connectivity check:

```bash
curl -s -o /dev/null -w "web      %{http_code}\n" http://localhost:2001/
curl -s -o /dev/null -w "langfuse %{http_code}\n" http://localhost:4000/
curl -s -o /dev/null -w "litellm  %{http_code}\n" http://localhost:14000/health
curl -s -o /dev/null -w "cert     %{http_code}\n" http://localhost:18000/docs
```

Open **[http://localhost:2001](http://localhost:2001)**, log in (`admin` / `litmus`).  
Langfuse UI: **[http://localhost:4000](http://localhost:4000)** (`admin@agentcert.local` / `agentcert-admin`).

---

## 5. Service Access Reference

All ports are mapped from kind's `extraPortMappings` (defined in
`deploy/kind/kind-agentcert.yaml`):

| Service | Host port | NodePort | Notes |
|---|---|---|---|
| AgentCert UI | 2001 | 32001 | nginx serving the React app |
| GraphQL REST | 8081 | 32081 | GraphQL + WebSocket |
| GraphQL gRPC | 8082 | 32082 | — |
| Auth REST | 3000 | 32003 | — |
| Auth gRPC | 3030 | 32030 | — |
| Certifier | **18000** | 32080 | Swagger at `/docs` |
| LiteLLM | 14000 | 31400 | — |
| Langfuse | 4000 | 32400 | — |
| MongoDB | 27017 | 32017 | replica set `rs0` |
| MinIO S3 | 19090 | 32090 | internal S3 for Langfuse |

> **Certifier runs on :18000** (not :8000) because port 8000 is often occupied
> on developer VMs. The container still listens on 8000 internally.

---

## 6. RBAC for App Installs

App charts like sock-shop ship their own ClusterRole/Role objects. The latest infra
manifest bakes in the necessary `escalate` and `bind` verbs, so a freshly connected
infrastructure works without any manual grant.

<div class="callout callout-info">
<span class="callout-title">Fallback</span>
Only needed if your infrastructure was connected <em>before</em> the RBAC fix and
you see <code>clusterroles.rbac.authorization.k8s.io ... is forbidden</code>.
Grant it once, or simply re-connect the infrastructure to pick up the updated role:
</div>

```bash
kubectl create clusterrolebinding argo-chaos-admin \
  --clusterrole=cluster-admin --serviceaccount=litmus:argo-chaos
```

---

## 7. Next: Run an Experiment

Setup already connected the `ace-local` chaos infrastructure (`kubectl get pods -n litmus`).
Continue with **[running-an-experiment.md]({{ "/setup/running-an-experiment.html" | relative_url }})**
to create and run an experiment and view its certification report.

---

## Notes & Gotchas

<div class="callout callout-warning">
<span class="callout-title">⚠ Don't accidentally lose your cluster</span>
The kind cluster is a Docker container named <code>agentcert-&lt;ACE_INSTANCE_NAME&gt;-control-plane</code>. It
is <strong>not</strong> backed by an external volume — deleting the container (e.g. via
<code>docker system prune</code>) permanently loses cluster state, including MongoDB. Re-run
<code>./scripts/setup.sh --restart</code> to recreate and redeploy everything.
</div>

- **Ports** — every host port is chosen by `setup.sh` (free-port walk) and saved in `.env` as `KIND_HOSTPORT_*`; the table above shows the defaults. See [configuration.md]({{ "/setup/configuration.html" | relative_url }}) to change them.
- **Idempotent setup** — re-running `./scripts/setup.sh` is safe: it detects existing port mappings, skips cluster recreation, updates the `ace-env` Secret, re-applies all manifests and reuses the registered chaos infrastructure.
- **UFW** — if your host firewall is active, in-cluster pods need ports open from the kind subnet. See [running-an-experiment.md]({{ "/setup/running-an-experiment.html" | relative_url }}#networking-checklist-pods--host).
- **Submodule pointer issues** — if `agent-charts/` or `app-charts/` is empty, run `git submodule update --init --recursive` from the repo root.
