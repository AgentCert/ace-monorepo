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
```

Verify:

```bash
docker --version      # Docker 28+
kind version          # kind v0.20+
kubectl version --client
```

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

---

## 3. Run the Setup Wizard

```bash
./scripts/setup.sh
```

The wizard:

1. Creates `.env` from `.env.example` (or updates an existing one)
2. Prompts for **Azure OpenAI** credentials (endpoint, key, deployment names)
3. Optionally prompts for **Gemini** or **OpenRouter** keys
4. Prompts for a `CLUSTER_MODE` — press Enter to accept `auto` (creates a kind cluster if none exists)
5. Patches `.env` with Kubernetes service DNS names
6. Asks: **Deploy the stack to the Kubernetes cluster now? [y/N]** → answer **Y**

When you answer Y, the wizard:

- Creates the kind cluster `agentcert` using `local-personal-workspace/kind-agentcert.yaml` (with all required `extraPortMappings` and `extraMounts`)
- Creates the `ace-env` Kubernetes Secret from `.env`
- Applies all manifests in `deploy/k8s/` in order: namespace → RBAC → MongoDB → auth → graphql → web → LiteLLM → certifier → Langfuse
- Waits for MongoDB, auth, graphql, web, and certifier to become ready (up to 5 min)
- Prints access URLs

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
`local-personal-workspace/kind-agentcert.yaml`):

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

## 7. Next: Install Infra and Run an Experiment

A fresh cluster has **no chaos infrastructure yet**. Follow
**[running-an-experiment.md]({{ "/setup/running-an-experiment.html" | relative_url }})** to:

1. Create an environment in the UI
2. Enable chaos (creates a Chaos Infrastructure)
3. Download and apply the infra YAML to the cluster
4. Run a chaos experiment
5. View the certification report

---

## Notes & Gotchas

<div class="callout callout-warning">
<span class="callout-title">⚠ Don't accidentally lose your cluster</span>
The kind cluster is a Docker container named <code>agentcert-control-plane</code>. It
is <strong>not</strong> backed by an external volume — deleting the container (e.g. via
<code>docker system prune</code>) permanently loses cluster state. Recreate with:<br>
<code>kind create cluster --config local-personal-workspace/kind-agentcert.yaml</code><br>
then re-run <code>./scripts/setup.sh</code> and answer Y to redeploy.
</div>

- **Port 8080** — the kind config also maps host `8080 → 80` for ingress. If 8080 is busy, edit `hostPort` in `local-personal-workspace/kind-agentcert.yaml` before first start.
- **Idempotent setup** — re-running `./scripts/setup.sh` is safe: it detects existing port mappings, skips cluster recreation, updates the `ace-env` Secret, and re-applies all manifests (no-op if nothing changed).
- **UFW** — if your host firewall is active, in-cluster pods need ports open from the kind subnet. See [running-an-experiment.md]({{ "/setup/running-an-experiment.html" | relative_url }}#networking-checklist-pods--host).
- **Submodule pointer issues** — if `agent-charts/` or `app-charts/` is empty, run `git submodule update --init --recursive` from the repo root.
