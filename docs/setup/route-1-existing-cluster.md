---
title: "Route 1 · Existing Cluster"
parent: "Setup"
nav_order: 2
---

# Route 1 — Reuse an Existing Local Cluster

<div class="callout callout-success">
<span class="callout-title">Use this route when…</span>
You already have a working local Kubernetes cluster (kind / minikube / k3s) and a valid kubeconfig, and you want ACE to use <em>that</em> cluster. This is the lightest path — only the ACE control plane (<code>auth</code>, <code>graphql</code>, <code>web</code>) and the one-shot <code>cluster-init</code> come up; your existing infrastructure is untouched.
</div>

---

## 1. Confirm Your Cluster Works

```bash
kubectl config current-context     # e.g. kind-agentcert
kubectl get nodes                  # nodes should be Ready
```

If that works from your shell, `cluster-init` will reuse it.

---

## 2. Configure `.env`

```dotenv
CLUSTER_MODE=local              # reuse the existing kube context (fail fast if none)

# Reuse infrastructure you already run → mark them external and drop the profiles:
MONGO_MODE=external
LANGFUSE_MODE=external
LITELLM_MODE=external
COMPOSE_PROFILES=               # empty → compose starts no mongo/langfuse/litellm
```

Then point the stack at your existing infra:

```dotenv
DB_SERVER=mongodb://admin:1234@172.26.0.1:27017/?replicaSet=rs0&authSource=admin
LANGFUSE_HOST=http://172.26.0.1:4000
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
LITELLM_HOST=http://172.26.0.1:14000
```

<div class="callout callout-tip">
<code>CLUSTER_MODE=auto</code> also works here — it probes your kubeconfig and reuses it. Use <code>local</code> when you want it to <strong>fail loudly</strong> if the cluster isn't up, rather than silently creating a kind cluster.
</div>

---

## 3. Bring Up Only the Control Plane

Because the infra profiles are empty, a plain `up` starts just what's needed:

```bash
docker compose up -d cluster-init auth graphql web
```

What happens:

1. **`cluster-init`** verifies your kube context and writes a world-readable copy of your kubeconfig into a shared volume (`~/.kube/config` is typically `0600` and unreadable by the container's user).
2. **`auth`** starts on :3000 / :3030 and connects to your existing mongo.
3. **`graphql`** starts on :8081 / :8082, reads the shared kubeconfig, and can reach your cluster's API server.
4. **`web`** serves the UI on :2001.

---

## 4. Verify

```bash
docker compose ps
curl -s -o /dev/null -w "web   %{http_code}\n" http://localhost:2001/
curl -s -o /dev/null -w "api   %{http_code}\n" http://localhost:2001/api/

# graphql can reach your cluster:
docker exec -u 65534 agentcert-graphql kubectl --kubeconfig=/kube/config get nodes
```

Open **[http://localhost:2001](http://localhost:2001)** and log in (`admin` / `litmus`).

---

## 5. Next: Run an Experiment

Your cluster may already have the chaos infrastructure installed. If not, follow **[running-an-experiment.md](/setup/running-an-experiment.html)** to create an environment, enable chaos, apply the infra YAML, and run an experiment.

---

## Notes & Gotchas

<div class="callout callout-warning">
<span class="callout-title">kubeconfig permissions</span>
If graphql logs <code>unable to load in-cluster configuration, KUBERNETES_SERVICE_HOST ... must be defined</code>, it couldn't read your kubeconfig. <code>cluster-init</code> handles this by publishing a <code>0644</code> copy — make sure it ran successfully: <code>docker logs ace-cluster-init</code>.
</div>

- **minikube/k3s gateway IP:** the `172.26.0.1` references assume the kind network gateway. For other clusters, find the right host IP (`docker network inspect <net> | grep Gateway`, or your host LAN IP) and update the `172.26.0.1` values in `.env`.
- **Switching back from a fresh test:** if you ran [route 2](/setup/route-2-fresh-kind.html) in the isolated `acefresh` project, stop it and restart your originals:
  ```bash
  docker compose -p acefresh -f docker-compose.yml -f compose/fresh.override.yml down
  docker start agentcert-control-plane agentcert-mongo litellm-proxy \
    langfuse-langfuse-web-1 langfuse-langfuse-worker-1 langfuse-clickhouse-1 \
    langfuse-postgres-1 langfuse-minio-1 langfuse-redis-1
  docker compose up -d cluster-init auth graphql web
  ```
