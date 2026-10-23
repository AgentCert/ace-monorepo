---
title: "Route 1 · Existing Local Cluster"
parent: "Setup"
nav_order: 2
---

# Route 1 — Reuse an Existing Local Cluster

<div class="callout callout-success">
<span class="callout-title">Use this route when…</span>
You already have a working local Kubernetes cluster (kind / minikube / k3s) and
<code>kubectl</code> is already pointed at it. <code>scripts/setup.sh --deploy</code> deploys
the full ACE stack into that cluster — no new cluster is created.
</div>

---

## 1. Confirm Your Cluster Works

```bash
kubectl config current-context     # e.g. kind-agentcert, minikube, k3d-...
kubectl get nodes                  # node(s) should be Ready
```

---

## 2. Run the Setup Wizard

```bash
./scripts/setup.sh --deploy
```

<div class="callout callout-warning">
<span class="callout-title">⚠ Without <code>--deploy</code> nothing is installed</span>
<code>./scripts/setup.sh</code> alone builds images and exits with
<code>All images built successfully!</code> — it never touches your cluster.
</div>

When the wizard asks `CLUSTER_MODE [auto]:`, enter **`local`** (accepted values:
`auto`, `fresh`, `local`, `cloud`). The wizard:

1. Patches `.env` with Kubernetes service DNS names (`graphql.ace.svc.cluster.local`, etc.)
2. **Skips** kind cluster creation (cluster already exists)
3. Creates the `ace-env` Secret from `.env`
4. Applies all manifests in `deploy/k8s/`
5. Waits for core services to become ready

At the deploy prompt the wizard asks how to apply: `Choice [k/H/n]:` — **Enter selects `h` (Helm)**, `k` is plain `kubectl apply`, `n` skips deploying. Helm gives you release tracking (`helm history`, `helm rollback`) and upgrades without re-running the full wizard. See [Managing services]({{ "/setup/managing-services.html" | relative_url }}) for Helm day-to-day commands.

<div class="callout callout-tip">
<code>CLUSTER_MODE=auto</code> also works — it probes your kubeconfig, finds the
existing cluster, and skips kind creation. Use <code>local</code> to fail loudly if
no cluster is reachable rather than silently creating a kind cluster.
</div>

---

## 3. Access the Services

### kind (with ACE port mappings)

If your existing cluster is a kind cluster created from this repo's template
(`deploy/kind/kind-agentcert.yaml`, rendered by `deploy/kind/render-kind-config.sh`),
the ACE `extraPortMappings` are already baked in and services are reachable at the
usual `localhost` ports:

| Service | URL |
|---|---|
| AgentCert UI | http://localhost:2001 |
| Langfuse | http://localhost:4002 |
| Certifier | http://localhost:18000/docs |
| LiteLLM | http://localhost:14000 |
| MongoDB | localhost:27017 |

### minikube / k3s / other local clusters

NodePort services are on the cluster node's IP, not `localhost`. Use
`kubectl port-forward` to map them to your local machine:

```bash
# Run in the background (or use separate terminals):
kubectl port-forward -n ace svc/web          2001:32001 &
kubectl port-forward -n ace svc/langfuse-web 4002:3000  &
kubectl port-forward -n ace svc/certifier    18000:8000 &
kubectl port-forward -n ace svc/litellm      14000:14000 &
kubectl port-forward -n ace svc/mongodb      27017:27017 &
```

Then access the same `localhost` URLs as above.

---

## 4. Verify

```bash
kubectl get pods -n ace           # all Running
curl -s -o /dev/null -w "UI  %{http_code}\n" http://localhost:2001/
```

Open **[http://localhost:2001](http://localhost:2001)** and log in (`admin` / `litmus`).

---

## 5. Next: Run an Experiment

Setup registers and connects the `ace-local` chaos infrastructure in this cluster
(`kubectl get pods -n litmus`). Continue with
**[running-an-experiment.md]({{ "/setup/running-an-experiment.html" | relative_url }})**.

<div class="callout callout-warning">
<span class="callout-title">Images on non-kind clusters</span>
The default <em>build locally</em> answers side-load images into the cluster, which works for
kind and k3s only. On any other cluster <code>scripts/prepare-images.sh</code> stops with
"no local side-load path"; answer <code>r</code> (registry) at the experiment image-source
prompts — <code>[l/r, Enter=l]</code>, where <code>l</code> = build locally and <code>r</code> =
pull from <code>IMAGE_REGISTRY</code> (Docker Hub when it is empty) — or push the images to a
registry the cluster can pull from. Published <code>:latest</code> images may lag this checkout.
</div>

---

## Notes

- **Re-running setup** — `./scripts/setup.sh --deploy` is idempotent. Running it again updates the `ace-env` Secret and re-applies all manifests (no-op if nothing changed).
- **Port conflicts** — if you have existing NodePort services on the same NodePorts (32001, 32400, etc.), edit `deploy/k8s/` service manifests to use different NodePorts before applying.
