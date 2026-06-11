---
title: "Route 3 · Cloud (AKS/EKS/GKE)"
parent: "Setup"
nav_order: 4
---

# Route 3 — Cloud Kubernetes (AKS / EKS / GKE)

**Use this when:** your Kubernetes cluster lives in the cloud and your VM is
already logged in to it — for example you ran `az login` and
`az aks get-credentials`, so `kubectl` on the VM already talks to AKS. ACE runs
on the VM (control plane + optional local infra) and drives chaos experiments on
your **remote** cloud cluster.

> **Status:** the `cloud` code path reuses your existing kubeconfig exactly like
> [route 1](./route-1-existing-cluster.md), with two cloud-specific concerns:
> **exec-auth** (the kubeconfig may call a cloud CLI) and **call-backs** (remote
> pods must be able to reach your VM). Both are covered below.

---

## 1. Log in and select the cluster (on the VM)

### AKS (Azure)
```bash
az login
az aks get-credentials --resource-group <rg> --name <cluster> --admin
kubectl config current-context     # e.g. <cluster>-admin
kubectl get nodes                  # should list your AKS nodes
```

> **Use `--admin`.** It writes a **certificate-based** kubeconfig with no exec
> plugin, so the stack can use it directly. A non-admin `get-credentials` writes
> an **Azure AD / `kubelogin` exec-auth** kubeconfig — see
> [exec-auth](#exec-auth-kubeconfigs-azure-ad--kubelogin) below.

### EKS (AWS) / GKE (Google)
```bash
# EKS
aws eks update-kubeconfig --name <cluster> --region <region>
# GKE
gcloud container clusters get-credentials <cluster> --zone <zone>
```
Both produce exec-auth kubeconfigs (`aws`/`gke-gcloud-auth-plugin`) — see
[exec-auth](#exec-auth-kubeconfigs-azure-ad--kubelogin).

---

## 2. Configure `.env`

```dotenv
CLUSTER_MODE=cloud

# The address remote pods use to call back to THIS VM. Must be reachable from
# the cloud cluster (public IP, or a VPN/peered private IP).
HOST_PUBLIC_IP=<vm-public-or-reachable-ip>

# Run supporting infra locally on the VM (or point to managed services):
MONGO_MODE=local
LANGFUSE_MODE=local
LITELLM_MODE=local
COMPOSE_PROFILES=mongo,langfuse,litellm
```

Then make the call-back / trace endpoints use the VM's reachable address instead
of the kind gateway `172.26.0.1` (which means nothing to a cloud pod):

```dotenv
SERVER_ADDR=http://<HOST_PUBLIC_IP>:8081/query
SUBSCRIBER_CALLBACK_URL=http://<HOST_PUBLIC_IP>:8081
PORTAL_ENDPOINT=http://<HOST_PUBLIC_IP>:8081
LANGFUSE_HOST=http://<HOST_PUBLIC_IP>:4000
LITELLM_HOST=http://<HOST_PUBLIC_IP>:14000   # the agent (via sidecar) calls LiteLLM here
```

> **Why:** the GraphQL server bakes these into the manifests it installs into
> your cloud cluster. The in-cluster subscriber pod, the running **agent** (its
> LLM calls go through the sidecar to `LITELLM_HOST`), and the agent's OTEL
> exporter all use these to reach the VM. On a cloud cluster they **cannot** be
> `localhost` or `172.26.0.1`.
>
> Leave `K8S_MCP_URL` / `PROM_MCP_URL` as-is — those are in-cluster service DNS
> names (`*.svc.cluster.local`) resolved by the agent pod *inside* the cluster,
> so they need no change for cloud.

---

## 3. Make the VM reachable from the cloud cluster

This is the defining constraint of route 3: remote pods initiate connections
**back** to your VM (subscriber call-backs, trace export). Ensure:

1. The VM has a **public IP** (or is VPN/VNet-peered with the cluster).
2. Inbound ports **8081** (GraphQL), **4000** (Langfuse), and **14000** (LiteLLM)
   are open from the cluster's egress range — open them in your **cloud security
   group / NSG** and, if the VM runs UFW, locally too:
   ```bash
   sudo ufw allow proto tcp to any port 8081  comment 'AgentCert pods→GraphQL'
   sudo ufw allow proto tcp to any port 4000  comment 'AgentCert pods→Langfuse'
   sudo ufw allow proto tcp to any port 14000 comment 'AgentCert pods→LiteLLM'
   ```
3. The services bind `0.0.0.0` (they do, by default on host networking).

> If the VM is **not** reachable from the cloud (e.g. a laptop behind NAT), the
> experiment can still be *launched*, but the subscriber can't report back and
> traces won't arrive. In that case use [route 1/2](./route-2-fresh-kind.md)
> with a local cluster, or run ACE inside the cloud network.

---

## 4. Bring up

```bash
docker compose up -d
```

`cluster-init` (mode `cloud`) verifies your kubeconfig works, warns if
`HOST_PUBLIC_IP` is empty, and publishes the kubeconfig for graphql. The rest of
the stack starts as usual.

Verify graphql reaches the cloud API server:
```bash
docker exec -u 65534 agentcert-graphql kubectl --kubeconfig=/kube/config get nodes
```

---

## 5. Next: install infra and run an experiment

Continue with **[running-an-experiment.md](./running-an-experiment.md)**. The
flow is identical, but the infra YAML is applied to your **cloud** cluster
(`kubectl --context <cluster> apply -f ...`).

---

## exec-auth kubeconfigs (Azure AD / kubelogin, aws, gcloud)

If your kubeconfig authenticates via an exec plugin (you'll see a `user.exec`
block referencing `kubelogin`, `aws`, or `gke-gcloud-auth-plugin`), the graphql
and cluster-init containers need that CLI **and** its credentials to mint tokens.
Two options:

**Option A — simplest: use a credential-based kubeconfig (recommended)**
- AKS: `az aks get-credentials --admin` (certificate-based, no plugin).
- Generate a long-lived ServiceAccount token kubeconfig and point `HOST_KUBE_DIR`
  at a directory containing it.

**Option B — mount the cloud CLI + creds.** This is more involved than it looks,
because the exec plugin is needed in **two** images, not one:

- **`cluster-init`** runs `kubectl cluster-info` *first* (it gates the whole
  stack via `depends_on`). Its image is alpine + `kubectl` only — **no
  `az`/`kubelogin`** — so an exec-auth kubeconfig makes it exit 1 before graphql
  ever starts.
- **`graphql`** then uses the kubeconfig via client-go + `kubectl`/`helm`; its
  image also has **no** exec plugin.

So mounting the cred dir is not enough — the **plugin binary** must be baked into
*both* the `cluster-init` and `graphql` images. Mount creds via a
`docker-compose.override.yml`:

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

and add the plugin to **both** images via derived Dockerfiles (e.g. install
`kubelogin` / `aws` / `gke-gcloud-auth-plugin`).

**Because of this, prefer Option A** — `az aks get-credentials --admin` yields a
certificate-based kubeconfig with no exec plugin, so it works out of the box with
the stock `cluster-init` and `graphql` images. That is the supported cloud path.

---

## Notes & gotchas

- **RBAC:** managed clusters often already grant broad permissions to your
  principal, so the `argo-chaos` cluster-admin binding needed on fresh kind may
  not be necessary. Verify with:
  ```bash
  kubectl get clusterrolebinding -o json \
    | jq -r '.items[] | select(.subjects[]?.name=="argo-chaos") | "\(.metadata.name) → \(.roleRef.name)"'
  ```
- **Cost & blast radius:** chaos experiments inject real faults into the target
  namespace on your cloud cluster. Scope experiments to a disposable namespace.
- **Gateway IP:** unlike kind, there is no `172.26.0.1` shortcut — always use
  `HOST_PUBLIC_IP` for anything pods must reach.
