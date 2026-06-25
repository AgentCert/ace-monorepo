---
title: "Route 3 · Cloud (AKS/EKS/GKE)"
parent: "Setup"
nav_order: 4
---

# Route 3 — Cloud Kubernetes (AKS / EKS / GKE)

<div class="callout callout-success">
<span class="callout-title">Use this route when…</span>
Your Kubernetes cluster lives in the cloud and your VM is already logged in to it —
for example you ran <code>az login</code> and <code>az aks get-credentials</code>,
so <code>kubectl</code> on the VM already talks to AKS. <code>scripts/setup.sh</code>
deploys the full ACE stack (control plane + MongoDB + Langfuse + LiteLLM + Certifier)
<strong>into</strong> your cloud cluster, and chaos experiments run in the same cluster.
</div>

<div class="callout callout-info">
<span class="callout-title">Key difference from Route 2</span>
Unlike kind, cloud cluster NodePort services are <strong>not</strong> reachable on
<code>localhost</code> from the VM. The two browser UIs (AgentCert + Langfuse) are
exposed via <code>LoadBalancer</code>; internal APIs are reached via
<code>kubectl port-forward</code> on demand.
</div>

---

## 1. Log In and Select the Cluster (on the VM)

### AKS (Azure) — recommended

```bash
az login
az aks get-credentials --resource-group <rg> --name <cluster> --admin
kubectl config current-context     # e.g. <cluster>-admin
kubectl get nodes                  # AKS nodes should be Ready
```

<div class="callout callout-tip">
<span class="callout-title">Use --admin</span>
It writes a <strong>certificate-based</strong> kubeconfig with no exec plugin, so
<code>scripts/setup.sh</code> can use it directly without needing <code>kubelogin</code>
or <code>az</code> inside the cluster.
</div>

### EKS (AWS) / GKE (Google)

```bash
# EKS
aws eks update-kubeconfig --name <cluster> --region <region>
# GKE
gcloud container clusters get-credentials <cluster> --zone <zone>
```

Both produce exec-auth kubeconfigs — see [exec-auth caveats](#exec-auth-kubeconfigs) below.

---

## 2. Run the Setup Wizard

```bash
./scripts/setup.sh
```

When the wizard asks for `CLUSTER_MODE`, enter **`local`** — your kubeconfig already
points at the cloud cluster, so no kind cluster creation is needed. The wizard:

1. Patches `.env` with Kubernetes service DNS names so all in-cluster cross-service
   calls use `service.namespace.svc.cluster.local` instead of host IPs
2. Creates the `ace-env` Secret in the `ace` namespace
3. Applies all manifests in `deploy/k8s/` to your cloud cluster
4. Waits for core services to become ready

At the deploy prompt the wizard asks how to apply: press **`k`** for `kubectl apply` (default) or **`h`** for `helm upgrade --install`. The Helm path is convenient for cloud clusters where you want `helm history` and `helm rollback` for rollbacks without re-running the wizard. See [Managing services]({{ "/setup/managing-services.html" | relative_url }}) for Helm day-to-day commands.

---

## 3. Expose the Browser UIs (LoadBalancer)

Patch the two browser-facing services to `LoadBalancer` type. AKS provisions an
Azure Load Balancer with a public IP for each:

```bash
kubectl patch svc web          -n ace -p '{"spec":{"type":"LoadBalancer"}}'
kubectl patch svc langfuse-web -n ace -p '{"spec":{"type":"LoadBalancer"}}'
```

Wait for the external IPs to be assigned (~1–2 min):

```bash
kubectl get svc -n ace web langfuse-web -w
# NAME           TYPE           EXTERNAL-IP
# web            LoadBalancer   <pending> → 20.x.x.x
# langfuse-web   LoadBalancer   <pending> → 20.x.x.x
```

Once populated, the browser UIs are at:

| Service | URL | Default login |
|---|---|---|
| AgentCert UI | `http://<web-external-ip>:32001` | `admin` / `litmus` |
| Langfuse | `http://<langfuse-external-ip>:32400` | `admin@agentcert.local` / `agentcert-admin` |

<div class="callout callout-info">
<span class="callout-title">Langfuse login — update NEXTAUTH_URL</span>
Langfuse's Next.js auth validates the browser origin against <code>NEXTAUTH_URL</code>.
The default is <code>http://localhost:4000</code>, which breaks login when accessed
from a public IP. After getting the Langfuse external IP, update <code>.env</code>
and redeploy:
<pre><code>NEXTAUTH_URL=http://&lt;langfuse-external-ip&gt;:32400</code></pre>
<pre><code>./scripts/setup.sh   # answer Y — recreates ace-env Secret and restarts langfuse-web</code></pre>
</div>

<div class="callout callout-warning">
<span class="callout-title">⚠ These IPs are public</span>
Restrict access via an Azure NSG on the AKS node pool:
<pre><code>az network nsg rule create \
  --resource-group &lt;node-rg&gt; --nsg-name &lt;aks-nsg&gt; \
  --name AllowACEUI --priority 200 \
  --source-address-prefixes &lt;your-ip&gt;/32 \
  --destination-port-ranges 32001 32400 \
  --access Allow --protocol Tcp</code></pre>
</div>

### Internal services — port-forward on demand

The remaining services are APIs or infra — access them from the VM only when needed:

```bash
kubectl port-forward -n ace svc/certifier 18000:8000  # Swagger at http://localhost:18000/docs
kubectl port-forward -n ace svc/litellm   14000:14000
kubectl port-forward -n ace svc/mongodb   27017:27017
```

---

## 4. Verify

```bash
kubectl get pods -n ace
WEB_IP=$(kubectl get svc -n ace web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -o /dev/null -w "UI  %{http_code}\n" "http://${WEB_IP}:32001/"
```

---

## 5. Apply the Infra YAML to the Cloud Cluster

After creating a Chaos Infrastructure in the UI, apply its manifest to the cluster:

```bash
kubectl apply -f "<url-shown-in-the-ui>"

# Watch litmus come up:
kubectl -n litmus get pods -w
```

Since both ACE control plane and Litmus run inside the same cluster, the subscriber
reaches graphql at `http://graphql.ace.svc.cluster.local:8081` with no firewall
rules needed.

Continue with **[running-an-experiment.md]({{ "/setup/running-an-experiment.html" | relative_url }})**.

---

## exec-auth Kubeconfigs

If your kubeconfig authenticates via an exec plugin (`kubelogin`, `aws`,
`gke-gcloud-auth-plugin`), `scripts/setup.sh` runs `kubectl` directly on the VM
host so the plugin works as long as you're logged in.

**For AKS**, prefer `az aks get-credentials --admin` — it writes a certificate-based
kubeconfig with no exec dependency.

---

## Notes & Gotchas

- **RBAC** — if you hit `clusterroles ... is forbidden` during a sock-shop install:
  ```bash
  kubectl create clusterrolebinding argo-chaos-admin \
    --clusterrole=cluster-admin --serviceaccount=litmus:argo-chaos
  ```
- **PVC storage** — the `ace` namespace PVCs use the cluster's default StorageClass. Verify it supports `ReadWriteOnce`:
  ```bash
  kubectl get storageclass
  kubectl get pvc -n ace     # all should be Bound after deploy
  ```
- **Cost & blast radius** — chaos experiments inject real faults. Scope experiments to a disposable namespace.
- **Re-running setup** — idempotent. Re-run `./scripts/setup.sh` after any `.env` change; it updates the `ace-env` Secret and re-applies all manifests.
