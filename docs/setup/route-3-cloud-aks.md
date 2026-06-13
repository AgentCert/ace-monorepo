---
title: "Route 3 · Cloud (AKS/EKS/GKE)"
parent: "Setup"
nav_order: 4
---

# Route 3 — Cloud Kubernetes (AKS / EKS / GKE)

<div class="callout callout-success">
<span class="callout-title">Use this route when…</span>
Your Kubernetes cluster lives in the cloud and your VM is already logged in to it — for example you ran <code>az login</code> and <code>az aks get-credentials</code>, so <code>kubectl</code> on the VM already talks to AKS. ACE runs on the VM (control plane + optional local infra) and drives chaos experiments on your <strong>remote</strong> cloud cluster.
</div>

<div class="callout callout-info">
<span class="callout-title">Status</span>
The <code>cloud</code> code path reuses your existing kubeconfig exactly like <a href="{{ "/setup/route-1-existing-cluster.html" | relative_url }}">route 1</a>, with two cloud-specific concerns: <strong>exec-auth</strong> (the kubeconfig may call a cloud CLI) and <strong>call-backs</strong> (remote pods must reach your VM). Both are covered below.
</div>

---

## 1. Log In and Select the Cluster (on the VM)

### AKS (Azure)

```bash
az login
az aks get-credentials --resource-group <rg> --name <cluster> --admin
kubectl config current-context     # e.g. <cluster>-admin
kubectl get nodes                  # should list your AKS nodes
```

<div class="callout callout-tip">
<span class="callout-title">Use --admin</span>
It writes a <strong>certificate-based</strong> kubeconfig with no exec plugin, so the stack can use it directly. A non-admin <code>get-credentials</code> writes an Azure AD / <code>kubelogin</code> exec-auth kubeconfig — see <a href="#exec-auth-kubeconfigs-azure-ad--kubelogin">exec-auth</a> below.
</div>

### EKS (AWS) / GKE (Google)

```bash
# EKS
aws eks update-kubeconfig --name <cluster> --region <region>
# GKE
gcloud container clusters get-credentials <cluster> --zone <zone>
```

Both produce exec-auth kubeconfigs (`aws`/`gke-gcloud-auth-plugin`) — see [exec-auth](#exec-auth-kubeconfigs-azure-ad--kubelogin).

---

## 2. Configure `.env`

```dotenv
CLUSTER_MODE=cloud

# The address remote pods use to call back to THIS VM.
# Must be reachable from the cloud cluster (public IP, or VPN/peered private IP).
HOST_PUBLIC_IP=<vm-public-or-reachable-ip>

# Run supporting infra locally on the VM (or point to managed services):
MONGO_MODE=local
LANGFUSE_MODE=local
LITELLM_MODE=local
COMPOSE_PROFILES=mongo,langfuse,litellm
```

Make the call-back / trace endpoints use the VM's reachable address instead of the kind gateway `172.26.0.1` (which means nothing to a cloud pod):

```dotenv
SERVER_ADDR=http://<HOST_PUBLIC_IP>:8081/query
SUBSCRIBER_CALLBACK_URL=http://<HOST_PUBLIC_IP>:8081
PORTAL_ENDPOINT=http://<HOST_PUBLIC_IP>:8081
LANGFUSE_HOST=http://<HOST_PUBLIC_IP>:4000
LITELLM_HOST=http://<HOST_PUBLIC_IP>:14000   # the agent (via sidecar) calls LiteLLM here
```

<div class="callout callout-info">
<span class="callout-title">Why these addresses?</span>
The GraphQL server bakes these into the manifests it installs into your cloud cluster. The in-cluster subscriber pod, the running agent (LLM calls go through the sidecar to <code>LITELLM_HOST</code>), and the agent's OTEL exporter all use these to reach the VM. On a cloud cluster they <strong>cannot</strong> be <code>localhost</code> or <code>172.26.0.1</code>.<br><br>
Leave <code>K8S_MCP_URL</code> / <code>PROM_MCP_URL</code> as-is — those are in-cluster service DNS names resolved by the agent pod <em>inside</em> the cluster.
</div>

---

## 3. Make the VM Reachable From the Cloud Cluster

<div class="callout callout-warning">
<span class="callout-title">⚠ This is the defining constraint of route 3</span>
Remote pods initiate connections <strong>back</strong> to your VM (subscriber call-backs, trace export). Ensure the VM has a public IP and the ports are open.
</div>

1. The VM has a **public IP** (or is VPN/VNet-peered with the cluster).
2. Inbound ports **8081**, **4000**, and **14000** are open from the cluster's egress range — open them in your cloud security group / NSG and, if the VM runs UFW, locally too:
   ```bash
   sudo ufw allow proto tcp to any port 8081  comment 'AgentCert pods→GraphQL'
   sudo ufw allow proto tcp to any port 4000  comment 'AgentCert pods→Langfuse'
   sudo ufw allow proto tcp to any port 14000 comment 'AgentCert pods→LiteLLM'
   ```
3. The services bind `0.0.0.0` (they do by default on host networking).

<div class="callout callout-info">
If the VM is <strong>not</strong> reachable from the cloud (e.g. a laptop behind NAT), the experiment can still be <em>launched</em>, but the subscriber can't report back and traces won't arrive. Use <a href="{{ "/setup/route-2-fresh-kind.html" | relative_url }}">route 1/2</a> with a local cluster, or run ACE inside the cloud network.
</div>

---

## 4. Bring Up

```bash
docker compose up -d
```

`cluster-init` (mode `cloud`) verifies your kubeconfig works, warns if `HOST_PUBLIC_IP` is empty, and publishes the kubeconfig for graphql. The rest starts as usual.

Verify graphql reaches the cloud API server:
```bash
docker exec -u 65534 agentcert-graphql kubectl --kubeconfig=/kube/config get nodes
```

---

## 5. Next: Install Infra and Run an Experiment

Continue with **[running-an-experiment.md]({{ "/setup/running-an-experiment.html" | relative_url }})**. The flow is identical, but the infra YAML is applied to your **cloud** cluster:

```bash
kubectl --context <cluster> apply -f <url-shown-in-the-ui>
```

---

## exec-auth Kubeconfigs (Azure AD / kubelogin, aws, gcloud)

If your kubeconfig authenticates via an exec plugin (you'll see a `user.exec` block referencing `kubelogin`, `aws`, or `gke-gcloud-auth-plugin`), the graphql and cluster-init containers need that CLI and its credentials to mint tokens.

**Option A — simplest: use a credential-based kubeconfig (recommended)**

- AKS: `az aks get-credentials --admin` (certificate-based, no plugin).
- Generate a long-lived ServiceAccount token kubeconfig and point `HOST_KUBE_DIR` at a directory containing it.

**Option B — mount the cloud CLI + creds**

<div class="callout callout-warning">
<span class="callout-title">⚠ More involved than it looks</span>
The exec plugin is needed in <strong>two</strong> images: <code>cluster-init</code> (gates the whole stack via <code>depends_on</code>) and <code>graphql</code>. Neither image ships <code>az</code>/<code>kubelogin</code>/<code>aws</code>/<code>gke-gcloud-auth-plugin</code>. Mounting the cred directory alone is not enough — the plugin binary must be baked into both images.<br><br>
<strong>Because of this, prefer Option A.</strong>
</div>

Mount creds via a `docker-compose.override.yml`:
```yaml
services:
  cluster-init:
    # also requires kubelogin/aws/gke-gcloud-auth-plugin baked into the image
    volumes:
      - ${HOME}/.azure:/root/.azure          # or ~/.aws, ~/.config/gcloud
  graphql:
    user: "0:0"                              # root, to read your kubeconfig + creds
    volumes:
      - ${HOME}/.azure:/root/.azure
```

And add the plugin to both images via derived Dockerfiles (install `kubelogin` / `aws` / `gke-gcloud-auth-plugin`).

---

## Notes & Gotchas

- **RBAC:** managed clusters often grant broad permissions already, so the `argo-chaos` cluster-admin binding needed on fresh kind may not be necessary. Verify:
  ```bash
  kubectl get clusterrolebinding -o json \
    | jq -r '.items[] | select(.subjects[]?.name=="argo-chaos") | "\(.metadata.name) → \(.roleRef.name)"'
  ```
- **Cost & blast radius:** chaos experiments inject real faults into the target namespace on your cloud cluster. Scope experiments to a disposable namespace.
- **Gateway IP:** unlike kind, there is no `172.26.0.1` shortcut — always use `HOST_PUBLIC_IP` for anything pods must reach.
