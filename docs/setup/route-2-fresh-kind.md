# Route 2 — Fresh machine (compose creates the kind cluster)

**Use this when:** you have a clean machine with Docker but **no Kubernetes
cluster yet**. `cluster-init` will create a local [kind](https://kind.sigs.k8s.io)
cluster for you, and the full stack (MongoDB, Langfuse, LiteLLM, certifier,
control plane) comes up in one command. This is the true "one-command" path.

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

Fill in the `AZURE_OPENAI_*` keys (see
[configuration.md](./configuration.md#required-secrets)). The Langfuse keys are
auto-provisioned on first boot — you don't need to set them up manually.

> `CLUSTER_MODE=auto` behaves the same on a clean machine: it probes for a
> cluster, finds none, and creates kind. Use `fresh` to force creation.

---

## 2. Bring up the whole stack

```bash
docker compose up -d
```

First run **builds images and creates a Kubernetes cluster**, so allow several
minutes. The order is automatic:

1. **`cluster-init`** finds no working context → runs `kind create cluster`
   (using `local-personal-workspace/kind-agentcert.yaml` if present, which maps
   ingress `8080→80` and the Prometheus/Grafana/dex NodePorts) → publishes the
   kubeconfig.
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

Open **http://localhost:2001**, log in (`admin` / `litmus`).
Langfuse UI: **http://localhost:4000** (`admin@agentcert.local` / `agentcert-admin`).

---

## 4. RBAC for app installs (now handled automatically)

App charts like sock-shop (with monitoring) ship their own ClusterRole/Role
objects, so the `argo-chaos` service account that runs the install needs RBAC
management permissions — otherwise the install fails with
`clusterroles.rbac.authorization.k8s.io ... is forbidden`.

As of the latest infra manifest (`infra-cluster-role` in
`AgentCert/chaoscenter/graphql/server/manifests/cluster/3a_agents_rbac.yaml`)
these permissions are **baked in**, scoped to RBAC resources only — so a freshly
connected infrastructure works without any manual grant.

**Fallback** — if your infrastructure was connected *before* this fix (the live
`infra-cluster-role` predates it), grant it once:

```bash
kubectl --context kind-agentcert create clusterrolebinding argo-chaos-admin \
  --clusterrole=cluster-admin --serviceaccount=litmus:argo-chaos
```

(Run *after* the infra is connected — step 5 — since it creates the `litmus`
namespace + `argo-chaos` SA.) Or re-connect the infrastructure to pick up the
updated role.

---

## 5. Next: install infra and run an experiment

A fresh cluster has **no chaos infrastructure yet**. Follow
**[running-an-experiment.md](./running-an-experiment.md)** to:
create an environment → enable chaos → **download & apply the infra YAML** →
create and run an experiment → read results and the certification.

---

## Notes & gotchas

- **Don't lose your cluster:** `docker compose down` does **not** delete the kind
  cluster. To remove it: `kind delete cluster --name agentcert`. Note that kind
  stores etcd inside the node container with no external volume — deleting the
  node container (e.g. via `docker system prune`) permanently loses cluster
  state. Recreate with the saved config:
  `kind create cluster --config local-personal-workspace/kind-agentcert.yaml`.
- **Port 8080:** the kind config maps host `8080→80` for ingress. If 8080 is
  busy, edit `hostPort` in `local-personal-workspace/kind-agentcert.yaml` (e.g.
  to `8088`) before first start.
- **Testing fresh without touching an existing cluster:** if you already have a
  precious cluster you don't want to disturb, run the fresh stack in an isolated
  project using `compose/fresh.override.yml` (separate kind name + container
  names + volumes). See the override file's header for the exact command.
- **UFW:** if your host firewall is active, in-cluster pods need ports opened
  from the kind subnet — see
  [running-an-experiment.md](./running-an-experiment.md#networking-checklist-pods--host).
