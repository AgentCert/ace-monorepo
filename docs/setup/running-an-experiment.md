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
    <div class="qs-body"><strong>Already done by <code>./scripts/setup.sh</code></strong> — it creates the <code>ace-local</code> environment, registers the <code>ace-local</code> chaos infrastructure (cluster scope, namespace <code>litmus</code>), installs its subscriber, and waits until it is CONNECTED.</div>
  </div>
  <div class="qs-step">
    <div class="qs-num">2</div>
    <div class="qs-body"><strong>Create a Chaos Experiment</strong> — pick an application, an agent and faults, and complete each fault's target. Save and Run reject combinations the local catalogs do not support.</div>
  </div>
  <div class="qs-step">
    <div class="qs-num">3</div>
    <div class="qs-body"><strong>Run it</strong> — watch the live execution graph in the UI or via <code>kubectl -n litmus get pods -w</code>. Cleanup always runs at the end (Argo <code>onExit</code>), even when a step fails.</div>
  </div>
  <div class="qs-step">
    <div class="qs-num">4</div>
    <div class="qs-body"><strong>Results → Langfuse → Certification</strong> — traces land in Langfuse; the Certifier produces one result per injected fault and a 12-section report.</div>
  </div>
</div>

---

## 0. Before You Start

<div class="callout callout-info">
<span class="callout-title">Pre-flight checklist</span>
Stack is healthy: <code>kubectl get pods -n ace</code> shows all pods <code>Running</code>.<br>
Chaos infrastructure is up: <code>kubectl get pods -n litmus</code> shows <code>subscriber</code>, <code>chaos-operator</code>, <code>workflow-controller</code> and <code>event-tracker</code> Running, and the UI's <strong>Environments → ace-local</strong> page shows <code>ace-local</code> as CONNECTED.<br>
UI is reachable at the URL <code>setup.sh</code> printed (default <strong><a href="http://localhost:2001">http://localhost:2001</a></strong>) — log in with <code>ADMIN_USERNAME / ADMIN_PASSWORD</code> (default <code>admin / litmus</code>).<br>
<code>kubectl config current-context</code> is <code>kind-agentcert-&lt;ACE_INSTANCE_NAME&gt;</code> (see <code>KIND_CLUSTER_NAME</code> in <code>.env</code>).
</div>

If setup printed <em>"Chaos infrastructure is NOT connected"</em>, fix the warning it showed and re-run
<code>./scripts/setup.sh --restart</code> — registration is idempotent and reuses the existing infrastructure.

---

## Connecting a chaos infrastructure by hand (fallback)

Only needed when you set <code>ACE_AUTO_REGISTER_INFRA=false</code> in <code>.env</code>, or want an extra
infrastructure on another cluster.

1. In the UI open **Environments → New Environment**, give it a name and type (Non-Production).
2. Open it → **Enable Chaos** → **Kubernetes**; pick **Cluster-wide** scope and keep the `litmus` namespace / service account.
3. Apply the manifest the UI shows (`kubectl apply -f "<url-shown-in-the-ui>"`, or download it and `kubectl apply -f` the file).
4. Watch it come up (`kubectl -n litmus get pods -w`) and wait for **CONNECTED / ACTIVE** in the UI; if it stays DISCONNECTED, work through the networking checklist below.
5. Re-run `./scripts/setup.sh --restart` so the subscriber secret and workflow-controller `instanceID` are synced to it.

---

## Networking Checklist (Pods → Control Plane)

In the Kubernetes setup, the control plane (graphql, auth, etc.) runs inside the
same cluster as the infra subscriber — so pods reach graphql via Kubernetes DNS,
not the host IP. The `SERVER_ADDR` and `SUBSCRIBER_CALLBACK_URL` in `.env` are
patched to `http://graphql.ace.svc.cluster.local:8081` by `scripts/setup.sh`.

If the subscriber still can't connect:

<div class="callout callout-warning">
<span class="callout-title">⚠ Common failure modes</span>
<strong>1. Graphql pod not running.</strong> <code>kubectl get pods -n ace -l app=graphql</code> — must show Running.<br><br>
<strong>2. Wrong SERVER_ADDR in .env.</strong> Check <code>grep SERVER_ADDR .env</code> — should be
<code>http://graphql.ace.svc.cluster.local:8081/query</code>, not a host IP.<br>
Re-run <code>./scripts/setup.sh</code> to patch and redeploy.<br><br>
<strong>3. Subscriber in wrong namespace.</strong> Cross-namespace DNS works fine (<code>service.namespace.svc.cluster.local</code>). The subscriber in <code>litmus</code> can reach <code>graphql.ace.svc.cluster.local</code> without any extra config.
</div>

Quick reachability test from inside the litmus namespace:
```bash
kubectl run -i --rm --restart=Never reach-test -n litmus --image=busybox --command -- \
  sh -c 'wget -q -T 3 -O- http://graphql.ace.svc.cluster.local:8081/query --post-data={} --header=Content-Type:application/json'
# reached & rejected empty body = OK; timeout = DNS or pod not running
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

## 1. Create a Chaos Experiment

1. Open **Chaos Experiments → New Experiment**.
2. Select the **ace-local** environment and the **ace-local** chaos infrastructure (created by `setup.sh`).
3. Choose a fault from the default **ChaosHub** — it is served from this checkout's `chaos-charts/` (baked into the hub bundle image at setup), never cloned at runtime. Start simple — e.g. `pod-delete` against a target deployment.
4. Define the **target** (namespace / app label / deployment). A newly added fault is only committed to the experiment when you click **Apply** with a complete target; Save and Run are blocked while any fault is incomplete.
5. (Optional but recommended) Add **Resilience Probes** — the steady-state checks (HTTP/cmd/prometheus) that decide whether the system stayed healthy.
6. **Tune** the fault parameters (duration, chaos interval, etc.).
7. Save / **Run** the experiment.

---

## 2. Watch the Run

In the UI, open the experiment's **run** to see the live execution graph (install → inject fault → probes → cleanup).

```bash
kubectl -n litmus get pods           # runner / experiment pods appear
kubectl -n <target-ns> get pods -w   # watch the fault take effect
```

---

## 3. Results → Langfuse → Certification

| What | Where | Notes |
|---|---|---|
| **Pass/Fail + score** | Experiment run in UI | Based on your Resilience Probes |
| **Agent traces** | [Langfuse :4000](http://localhost:4000) → project `agentcert` | Every LLM call the agent made under fault |
| **Certification report** | [Certifier :18000/docs](http://localhost:18000/docs) | POST the Langfuse trace → get a 12-section JSON+PDF report |

The `scripts/run_certification.py` helper wraps the Certifier API calls for you.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Experiment create: `failed RBAC preflight: unable to load in-cluster configuration` | graphql can't reach the K8s API | Check `kubectl logs -n ace deploy/graphql` — the graphql pod uses its ServiceAccount token for in-cluster auth |
| Infra stuck **DISCONNECTED**; subscriber log: `dial tcp [::1]:8081: connection refused` | Subscriber can't reach graphql | The infra YAML uses `graphql.ace.svc.cluster.local:8081` as the callback — verify graphql pod is Running |
| Subscriber log: `dial tcp 172.26.0.1:8081: i/o timeout` | UFW dropping the port | `sudo ufw allow from 172.26.0.0/16 to any port 8081 proto tcp` |
| Subscriber log: `websocket: bad handshake` | `ALLOWED_ORIGINS` regex mismatch | Widen `ALLOWED_ORIGINS` in `.env` to include `172.*` / `10.*` ranges, restart graphql |
| App install fails: `clusterroles ... 'prometheus' is forbidden` | chaos SA lacks RBAC perms | Apply the `argo-chaos-admin` binding shown above |
| Login fails `invalid_credentials` | admin row predates current `.env` | Delete admin user from MongoDB, then `kubectl rollout restart -n ace deploy/auth` |
| Langfuse UI 500 on first boot | init password < 8 chars | Set `LANGFUSE_INIT_USER_PASSWORD` (≥ 8 chars) and recreate `langfuse-web` |
