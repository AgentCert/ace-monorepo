---
title: "Route 2 · Fresh kind"
parent: "Setup"
nav_order: 3
---

# Route 2 — Fresh Machine (compose Creates the kind Cluster)

<div class="callout callout-success">
<span class="callout-title">Use this route when…</span>
You have a clean machine with Docker but <strong>no Kubernetes cluster yet</strong>. <code>cluster-init</code> will create a local <a href="https://kind.sigs.k8s.io">kind</a> cluster for you, and the full stack (MongoDB, Langfuse, LiteLLM, certifier, control plane) comes up in one command. This is the true "one-command" path.
</div>

---

## 1. Configure `.env`

```dotenv
CLUSTER_MODE=fresh                  # always create/ensure a local kind cluster
KIND_CLUSTER_NAME=agentcert         # the cluster name

# Run everything locally:
MONGO_MODE=local
LANGFUSE_MODE=local
LITELLM_MODE=local
COMPOSE_PROFILES=mongo,langfuse,litellm
```

Fill in the `AZURE_OPENAI_*` keys (see [configuration.md](/setup/configuration.html#required-secrets)). Langfuse keys are auto-provisioned on first boot.

<div class="callout callout-tip">
<code>CLUSTER_MODE=auto</code> behaves the same on a clean machine: it probes for a cluster, finds none, and creates kind. Use <code>fresh</code> to force creation every time.
</div>

---

## 2. Bring Up the Whole Stack

```bash
docker compose up -d
```

First run **builds images and creates a Kubernetes cluster** — allow several minutes. The order is automatic:

1. **`cluster-init`** finds no working context → runs `kind create cluster` → publishes the kubeconfig.
2. **`mongo`** starts and **`mongo-init`** initialises replica set `rs0`.
3. **`langfuse`** (6 services) migrates its DB and auto-provisions org/project/keys.
4. **`litellm`**, **`certifier`**, then **`auth`** → **`graphql`** → **`web`**.

Watch it:

```bash
docker compose ps
docker compose logs -f cluster-init      # kind creation progress
docker compose logs -f graphql
```

---

## 3. Verify

```bash
docker compose ps          # all services Up / healthy

curl -s -o /dev/null -w "web      %{http_code}\n" http://localhost:2001/
curl -s -o /dev/null -w "langfuse %{http_code}\n" http://localhost:4000/
curl -s -o /dev/null -w "litellm  %{http_code}\n" http://localhost:14000/health

# kind cluster + graphql reachability:
kubectl --context kind-agentcert get nodes
docker exec -u 65534 agentcert-graphql kubectl --kubeconfig=/kube/config get nodes
```

Open **[http://localhost:2001](http://localhost:2001)**, log in (`admin` / `litmus`).  
Langfuse UI: **[http://localhost:4000](http://localhost:4000)** (`admin@agentcert.local` / `agentcert-admin`).

---

## 4. RBAC for App Installs

App charts like sock-shop ship their own ClusterRole/Role objects. As of the latest infra manifest these permissions are **baked in**, so a freshly connected infrastructure works without any manual grant.

<div class="callout callout-info">
<span class="callout-title">Fallback</span>
Only needed if your infrastructure was connected <em>before</em> this fix and you see <code>clusterroles.rbac.authorization.k8s.io ... is forbidden</code>. Grant it once after step 5 (infra connected), or simply re-connect the infrastructure to pick up the updated role:
</div>

```bash
kubectl --context kind-agentcert create clusterrolebinding argo-chaos-admin \
  --clusterrole=cluster-admin --serviceaccount=litmus:argo-chaos
```

---

## 5. Next: Install Infra and Run an Experiment

A fresh cluster has **no chaos infrastructure yet**. Follow **[running-an-experiment.md](/setup/running-an-experiment.html)** to:
create an environment → enable chaos → **download & apply the infra YAML** → create and run an experiment → read results and the certification.

---

## Notes & Gotchas

<div class="callout callout-warning">
<span class="callout-title">⚠ Don't lose your cluster</span>
<code>docker compose down</code> does <strong>not</strong> delete the kind cluster. To remove it: <code>kind delete cluster --name agentcert</code>.<br><br>
kind stores etcd inside the node container with no external volume — deleting the node container (e.g. via <code>docker system prune</code>) permanently loses cluster state. Recreate with:<br>
<code>kind create cluster --config local-personal-workspace/kind-agentcert.yaml</code>
</div>

- **Port 8080:** the kind config maps host `8080→80` for ingress. If 8080 is busy, edit `hostPort` in `local-personal-workspace/kind-agentcert.yaml` (e.g. to `8088`) before first start.
- **Testing fresh without touching an existing cluster:** run the fresh stack in an isolated project using `compose/fresh.override.yml` (separate kind name + container names + volumes). See the override file's header for the exact command.
- **UFW:** if your host firewall is active, in-cluster pods need ports opened from the kind subnet — see [running-an-experiment.md](/setup/running-an-experiment.html#networking-checklist-pods--host).
