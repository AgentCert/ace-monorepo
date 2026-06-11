---
title: "Running an Experiment"
parent: "Setup"
nav_order: 5
---

# Running Your First Experiment

This is the end-to-end flow **after the stack is up**: from logging in to a
running chaos experiment with a certification report. It applies to all three
routes — the only difference is *which* cluster the infrastructure YAML is
applied to.

The control plane is based on **Litmus ChaosCenter 3.x**, so the UI uses Litmus
terminology: **Environments → Chaos Infrastructures → Chaos Experiments**. Exact
button labels may vary slightly by build; the sequence is what matters.

**The big picture**

```
Log in
  → 1. Create an Environment
  → 2. Enable Chaos (create a Chaos Infrastructure)
  → 3. Download the infra YAML and `kubectl apply` it to your cluster
  → 4. Wait until the infrastructure shows CONNECTED / ACTIVE
  → 5. Create a Chaos Experiment (pick a fault, target, tune, probes)
  → 6. Run it and watch the execution
  → 7. Review results → traces in Langfuse → certification report
```

---

## 0. Before you start

- Stack is healthy: `docker compose ps` shows `auth`, `graphql`, `web` Up, and
  `cluster-init` exited 0.
- You can open the UI: **http://localhost:2001** and log in with
  `ADMIN_USERNAME` / `ADMIN_PASSWORD` (default **`admin` / `litmus`**).
- `kubectl` on the host points at the cluster you want to target:
  ```bash
  kubectl config current-context
  kubectl get nodes
  ```

---

## 1. Create an Environment

An *Environment* is a logical grouping (e.g. `dev`, `staging`) that holds your
chaos infrastructures.

1. In the UI, open **Environments**.
2. Click **New Environment**.
3. Give it a name (e.g. `local-dev`) and type (Non-Production), then **Create**.

---

## 2. Enable Chaos — create a Chaos Infrastructure

A *Chaos Infrastructure* is the agent that runs inside your Kubernetes cluster
and executes experiments. "Enabling chaos" generates the Kubernetes manifest you
install into the cluster.

1. Open your environment → **Enable Chaos** (or **Chaos Infrastructures → New
   Chaos Infrastructure**).
2. Choose **Kubernetes** as the infrastructure type.
3. Pick the installation **scope**:
   - **Cluster-wide** — can target workloads in any namespace (recommended for
     the demo / sock-shop).
   - **Namespace** — restricted to one namespace.
4. Accept the defaults for the service account / namespace (`litmus`) unless you
   have a reason to change them.
5. Continue to the step that shows the **installation manifest** — this is the
   YAML you apply next.

---

## 3. Download & apply the infrastructure YAML

The UI presents the manifest in one of two ways — both are fine:

**a) Copy the `kubectl apply` command** shown in the UI:
```bash
kubectl apply -f "<url-shown-in-the-ui>"
```

**b) Download the YAML** and apply the file:
```bash
# target the right cluster explicitly
kubectl --context kind-agentcert apply -f ~/Downloads/litmus-infra.yaml
```

> A reference copy of this infrastructure manifest lives at
> [`local-personal-workspace/litmus-fresh.yaml`](../../local-personal-workspace/litmus-fresh.yaml)
> — it creates the `litmus` namespace, the `argo-chaos` service account, the
> workflow controller, the subscriber, CRDs, and RBAC. The UI-generated version
> is the same shape but stamped with a unique `instanceID` and your
> `SERVER_ADDR` so the in-cluster subscriber knows how to call back to the
> control plane.

Watch it come up:
```bash
kubectl -n litmus get pods -w
# expect: subscriber, chaos-operator, workflow-controller, event-tracker → Running
```

---

## 4. Confirm the infrastructure is CONNECTED

Back in the UI, the new infrastructure should flip to **CONNECTED / ACTIVE**
within a minute or two. If it stays **DISCONNECTED**, the subscriber pod can't
reach the control plane — work through the [networking checklist](#networking-checklist-pods--host)
and [troubleshooting](#troubleshooting) below.

```bash
kubectl -n litmus logs deploy/subscriber --tail=30
```

---

## Networking checklist (pods → host)

In-cluster pods must reach the control plane **on the host**. Three things have
to line up (each fails silently in a different way):

1. **Right host IP.** Inside a pod, `localhost` is the pod, not the host.
   - **kind (routes 1 & 2):** the host is the kind-network gateway
     `172.26.0.1`. This is what `SERVER_ADDR` / `SUBSCRIBER_CALLBACK_URL` use.
   - **cloud (route 3):** the host is your VM at `HOST_PUBLIC_IP`.
2. **Host services bind `0.0.0.0`** (not `127.0.0.1`). The compose control plane
   does this by default. Verify: `ss -tlnp "( sport = :8081 )"` → `0.0.0.0:8081`.
3. **Firewall allows the port from the cluster.** If UFW is active on the host:
   ```bash
   # kind: allow from the kind subnet
   sudo ufw allow from 172.26.0.0/16 to any port 8081 proto tcp comment 'pods→GraphQL'
   sudo ufw allow from 172.26.0.0/16 to any port 4000 proto tcp comment 'pods→Langfuse'
   ```
   (For cloud, open 8081/4000 in the NSG/security group + UFW — see
   [route-3](./route-3-cloud-aks.md#3-make-the-vm-reachable-from-the-cloud-cluster).)

Quick reachability test from inside the cluster:
```bash
kubectl run -i --rm --restart=Never reach-test --image=busybox --command -- \
  sh -c 'wget -q -T 3 -O- http://172.26.0.1:8081/query --post-data={} --header=Content-Type:application/json'
# reached & rejected empty body = OK; timeout = networking/firewall problem
```

---

## RBAC for app installs

App charts (e.g. sock-shop with monitoring) ship their own ClusterRole/Role
objects, which the `argo-chaos` install service account must be able to manage.
The infra manifest (`infra-cluster-role`) now includes these RBAC permissions
(scoped to RBAC resources), so a **freshly connected** infrastructure handles
this automatically.

**Fallback** — only if your infra was connected *before* that fix and you see
`clusterroles.rbac.authorization.k8s.io ... is forbidden`, grant it once (after
the `litmus` namespace + `argo-chaos` SA exist, i.e. after step 3) — or simply
re-connect the infrastructure:

```bash
kubectl --context kind-agentcert create clusterrolebinding argo-chaos-admin \
  --clusterrole=cluster-admin --serviceaccount=litmus:argo-chaos
```

Managed cloud clusters often already grant this — check with:
```bash
kubectl get clusterrolebinding -o json \
  | jq -r '.items[] | select(.subjects[]?.name=="argo-chaos") | "\(.metadata.name) → \(.roleRef.name)"'
```

---

## 5. Create a Chaos Experiment

1. Open **Chaos Experiments → New Experiment**.
2. Select the **Environment** and the **Chaos Infrastructure** you just connected.
3. Choose a fault from a **ChaosHub** (the default hub is synced automatically).
   Start simple — e.g. `pod-delete` against a target deployment.
4. Define the **target** (namespace / app label / deployment).
5. (Optional but recommended) Add **Resilience Probes** — the steady-state
   checks (HTTP/cmd/prometheus) that decide whether the system stayed healthy.
6. **Tune** the fault parameters (duration, chaos interval, etc.).
7. Save / **Run** the experiment (run now, or schedule).

---

## 6. Watch the run

- In the UI, open the experiment's **run** to see the live execution graph
  (install → inject fault → probes → cleanup).
- From the cluster:
  ```bash
  kubectl -n litmus get pods           # runner / experiment pods appear
  kubectl -n <target-ns> get pods -w   # watch the fault take effect
  ```

---

## 7. Results → Langfuse → Certification

- **Result:** the run shows **Pass/Fail** and a resilience score based on your
  probes.
- **Traces:** the agent's actions under fault are exported to **Langfuse**
  (http://localhost:4000). Open the project (`agentcert`) to inspect the trace.
- **Certification:** the **Certifier** (http://localhost:8000/docs) consumes the
  Langfuse trace and produces a multi-phase certification report (JSON + PDF).
  See the repo README's "Certifier" sections for the API calls, or use the
  `scripts/run_certification.py` helper.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Experiment create shows `failed RBAC preflight: unable to load in-cluster configuration ...` | graphql can't read the kubeconfig | Ensure `cluster-init` ran OK (`docker logs ace-cluster-init`); it publishes a `0644` kubeconfig to the shared volume that graphql reads at `/kube/config`. |
| Infra stuck **DISCONNECTED**; subscriber log: `dial tcp [::1]:8081: connection refused` | `SERVER_ADDR` points at `localhost` | Set `SERVER_ADDR`/`SUBSCRIBER_CALLBACK_URL` to `172.26.0.1:8081` (kind) or `HOST_PUBLIC_IP:8081` (cloud), recreate graphql, reinstall infra (or patch the `subscriber-config` ConfigMap + `kubectl rollout restart deploy/subscriber -n litmus`). |
| Subscriber log: `dial tcp 172.26.0.1:8081: i/o timeout` | UFW dropping the port | `sudo ufw allow from 172.26.0.0/16 to any port 8081 proto tcp`. |
| Subscriber log: `websocket: bad handshake` | `ALLOWED_ORIGINS` regex doesn't match the pod's Host | Widen `ALLOWED_ORIGINS` in `.env` to include `172.*` / `10.*` ranges, restart graphql. |
| App install fails: `clusterroles ... 'prometheus' is forbidden` | fresh cluster, chaos SA lacks RBAC perms | Apply the [`argo-chaos-admin`](#rbac-grant-fresh-clusters) binding. |
| Login fails `invalid_credentials` | admin row predates current `.env` | `docker exec agentcert-mongo mongosh -u admin -p 1234 --authenticationDatabase admin auth --eval 'db.users.deleteOne({username:"admin"})'`, then `docker compose restart auth` (re-seeds from `.env`). |
| Langfuse UI 500 on first boot | init-user password < 8 chars | Set `LANGFUSE_INIT_USER_PASSWORD` (≥8 chars) and recreate `langfuse-web` (default is `agentcert-admin`). |

For deeper subscriber/LiteLLM debugging, see
[`local-personal-workspace/archived/local-setup.md`](../../local-personal-workspace/archived/local-setup.md).
