---
title: "Running an Experiment"
parent: "Setup"
nav_order: 5
---

# Running Your First Experiment

End-to-end flow **after the stack is up**: from logging in to a running chaos experiment with a certification report. Applies to all three routes — the only difference is *which* cluster the infrastructure YAML is applied to.

The control plane is based on **Litmus ChaosCenter 3.x**, so the UI uses Litmus terminology: **Environments → Chaos Infrastructures → Chaos Experiments**.

---

**The big picture**

<div class="qs-steps">
  <div class="qs-step">
    <div class="qs-num">1</div>
    <div class="qs-body"><strong>Create an Environment</strong> — a logical grouping (e.g. <code>local-dev</code>) that holds your chaos infrastructures.</div>
  </div>
  <div class="qs-step">
    <div class="qs-num">2</div>
    <div class="qs-body"><strong>Enable Chaos</strong> — create a Chaos Infrastructure; this generates the Kubernetes manifest you install into your cluster.</div>
  </div>
  <div class="qs-step">
    <div class="qs-num">3</div>
    <div class="qs-body"><strong>Apply the infra YAML</strong> — <code>kubectl apply -f &lt;url&gt;</code> on your cluster. The subscriber pod starts and calls home.</div>
  </div>
  <div class="qs-step">
    <div class="qs-num">4</div>
    <div class="qs-body"><strong>Wait for CONNECTED / ACTIVE</strong> — the infrastructure flips status in the UI within a minute or two.</div>
  </div>
  <div class="qs-step">
    <div class="qs-num">5</div>
    <div class="qs-body"><strong>Create a Chaos Experiment</strong> — pick a fault, define the target, add probes, tune parameters.</div>
  </div>
  <div class="qs-step">
    <div class="qs-num">6</div>
    <div class="qs-body"><strong>Run it</strong> — watch the live execution graph in the UI or via <code>kubectl -n litmus get pods -w</code>.</div>
  </div>
  <div class="qs-step">
    <div class="qs-num">7</div>
    <div class="qs-body"><strong>Results → Langfuse → Certification</strong> — traces land in Langfuse; the Certifier produces a 12-section report.</div>
  </div>
</div>

---

## 0. Before You Start

<div class="callout callout-info">
<span class="callout-title">Pre-flight checklist</span>
Stack is healthy: <code>docker compose ps</code> shows <code>auth</code>, <code>graphql</code>, <code>web</code> Up, and <code>cluster-init</code> exited 0.<br>
UI is reachable: <strong><a href="http://localhost:2001">http://localhost:2001</a></strong> — log in with <code>ADMIN_USERNAME / ADMIN_PASSWORD</code> (default <code>admin / litmus</code>).<br>
<code>kubectl config current-context</code> and <code>kubectl get nodes</code> both work on the host.
</div>

---

## 1. Create an Environment

An *Environment* is a logical grouping (e.g. `dev`, `staging`) that holds your chaos infrastructures.

1. In the UI, open **Environments**.
2. Click **New Environment**.
3. Give it a name (e.g. `local-dev`) and type (Non-Production), then **Create**.

---

## 2. Enable Chaos — Create a Chaos Infrastructure

A *Chaos Infrastructure* is the agent that runs inside your Kubernetes cluster and executes experiments.

1. Open your environment → **Enable Chaos** (or **Chaos Infrastructures → New Chaos Infrastructure**).
2. Choose **Kubernetes** as the infrastructure type.
3. Pick the installation **scope**:
   - **Cluster-wide** — can target workloads in any namespace (recommended for the demo / sock-shop).
   - **Namespace** — restricted to one namespace.
4. Accept the defaults for the service account / namespace (`litmus`) unless you have a reason to change them.
5. Continue to the step that shows the **installation manifest** — this is the YAML you apply next.

---

## 3. Download & Apply the Infrastructure YAML

The UI presents the manifest in one of two ways — both are fine:

**a) Copy the `kubectl apply` command** shown in the UI:
```bash
kubectl apply -f "<url-shown-in-the-ui>"
```

**b) Download the YAML** and apply the file:
```bash
kubectl --context kind-agentcert apply -f ~/Downloads/litmus-infra.yaml
```

Watch it come up:
```bash
kubectl -n litmus get pods -w
# expect: subscriber, chaos-operator, workflow-controller, event-tracker → Running
```

<div class="callout callout-tip">
A reference copy of the infrastructure manifest lives at <code>local-personal-workspace/litmus-fresh.yaml</code>. The UI-generated version is the same shape but stamped with a unique <code>instanceID</code> and your <code>SERVER_ADDR</code> so the in-cluster subscriber knows how to call back to the control plane.
</div>

---

## 4. Confirm the Infrastructure Is CONNECTED

Back in the UI, the new infrastructure should flip to **CONNECTED / ACTIVE** within a minute or two.

```bash
kubectl -n litmus logs deploy/subscriber --tail=30
```

If it stays **DISCONNECTED**, work through the [networking checklist](#networking-checklist-pods--host) below.

---

## Networking Checklist (Pods → Host)

In-cluster pods must reach the control plane **on the host**. Three things have to line up:

<div class="callout callout-warning">
<span class="callout-title">⚠ The three failure modes</span>
<strong>1. Wrong host IP.</strong> Inside a pod, <code>localhost</code> is the pod, not the host. For kind (routes 1 &amp; 2) the host is the kind-network gateway <code>172.26.0.1</code>. For cloud (route 3) use <code>HOST_PUBLIC_IP</code>.<br><br>
<strong>2. Host services bind <code>0.0.0.0</code>.</strong> The compose control plane does this by default. Verify: <code>ss -tlnp "( sport = :8081 )"</code> → <code>0.0.0.0:8081</code>.<br><br>
<strong>3. Firewall allows the port.</strong> If UFW is active on the host:<br>
<code>sudo ufw allow from 172.26.0.0/16 to any port 8081 proto tcp</code><br>
<code>sudo ufw allow from 172.26.0.0/16 to any port 4000 proto tcp</code>
</div>

Quick reachability test from inside the cluster:
```bash
kubectl run -i --rm --restart=Never reach-test --image=busybox --command -- \
  sh -c 'wget -q -T 3 -O- http://172.26.0.1:8081/query --post-data={} --header=Content-Type:application/json'
# reached & rejected empty body = OK; timeout = networking/firewall problem
```

---

## RBAC for App Installs

App charts (e.g. sock-shop with monitoring) ship their own ClusterRole/Role objects. The `infra-cluster-role` in the latest infra manifest includes these RBAC permissions — so a **freshly connected** infrastructure handles this automatically.

<div class="callout callout-info">
<span class="callout-title">Fallback</span>
Only needed if your infra was connected <em>before</em> this fix and you see <code>clusterroles.rbac.authorization.k8s.io ... is forbidden</code>. Grant it once (after the <code>litmus</code> namespace exists) — or simply re-connect the infrastructure:
</div>

```bash
kubectl --context kind-agentcert create clusterrolebinding argo-chaos-admin \
  --clusterrole=cluster-admin --serviceaccount=litmus:argo-chaos
```

Verify existing bindings:
```bash
kubectl get clusterrolebinding -o json \
  | jq -r '.items[] | select(.subjects[]?.name=="argo-chaos") | "\(.metadata.name) → \(.roleRef.name)"'
```

---

## 5. Create a Chaos Experiment

1. Open **Chaos Experiments → New Experiment**.
2. Select the **Environment** and the **Chaos Infrastructure** you just connected.
3. Choose a fault from a **ChaosHub** (the default hub is synced automatically). Start simple — e.g. `pod-delete` against a target deployment.
4. Define the **target** (namespace / app label / deployment).
5. (Optional but recommended) Add **Resilience Probes** — the steady-state checks (HTTP/cmd/prometheus) that decide whether the system stayed healthy.
6. **Tune** the fault parameters (duration, chaos interval, etc.).
7. Save / **Run** the experiment.

---

## 6. Watch the Run

In the UI, open the experiment's **run** to see the live execution graph (install → inject fault → probes → cleanup).

```bash
kubectl -n litmus get pods           # runner / experiment pods appear
kubectl -n <target-ns> get pods -w   # watch the fault take effect
```

---

## 7. Results → Langfuse → Certification

| What | Where | Notes |
|---|---|---|
| **Pass/Fail + score** | Experiment run in UI | Based on your Resilience Probes |
| **Agent traces** | [Langfuse :4000](http://localhost:4000) → project `agentcert` | Every LLM call the agent made under fault |
| **Certification report** | [Certifier :8000/docs](http://localhost:8000/docs) | POST the Langfuse trace → get a 12-section JSON+PDF report |

The `scripts/run_certification.py` helper wraps the Certifier API calls for you.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Experiment create: `failed RBAC preflight: unable to load in-cluster configuration` | graphql can't read the kubeconfig | Ensure `cluster-init` ran OK (`docker logs ace-cluster-init`); it publishes a `0644` kubeconfig to the shared volume |
| Infra stuck **DISCONNECTED**; subscriber log: `dial tcp [::1]:8081: connection refused` | `SERVER_ADDR` points at `localhost` | Set `SERVER_ADDR`/`SUBSCRIBER_CALLBACK_URL` to `172.26.0.1:8081` (kind) or `HOST_PUBLIC_IP:8081` (cloud) |
| Subscriber log: `dial tcp 172.26.0.1:8081: i/o timeout` | UFW dropping the port | `sudo ufw allow from 172.26.0.0/16 to any port 8081 proto tcp` |
| Subscriber log: `websocket: bad handshake` | `ALLOWED_ORIGINS` regex mismatch | Widen `ALLOWED_ORIGINS` in `.env` to include `172.*` / `10.*` ranges, restart graphql |
| App install fails: `clusterroles ... 'prometheus' is forbidden` | chaos SA lacks RBAC perms | Apply the `argo-chaos-admin` binding shown above |
| Login fails `invalid_credentials` | admin row predates current `.env` | Delete admin user from MongoDB, then `docker compose restart auth` |
| Langfuse UI 500 on first boot | init password < 8 chars | Set `LANGFUSE_INIT_USER_PASSWORD` (≥ 8 chars) and recreate `langfuse-web` |
