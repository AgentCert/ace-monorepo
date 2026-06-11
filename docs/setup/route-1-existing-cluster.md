---
title: "Route 1 · Existing Cluster"
parent: "Setup"
nav_order: 2
---

# Route 1 — Reuse an existing local cluster

**Use this when:** you already have a working local Kubernetes cluster running
(kind / minikube / k3s) and a valid kubeconfig, and you want ACE to use *that*
cluster instead of creating a new one. Your existing MongoDB / Langfuse /
LiteLLM can also be reused.

This is the lightest route — only the ACE control plane (auth, GraphQL, web) and
the one-shot `cluster-init` come up; your existing infrastructure is left
running and untouched.

---

## 1. Confirm your cluster works

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

Then point the stack at your existing infra (these are already the defaults in
`.env` if you used the previous script-based setup):

```dotenv
DB_SERVER=mongodb://admin:1234@172.26.0.1:27017/?replicaSet=rs0&authSource=admin
LANGFUSE_HOST=http://172.26.0.1:4000
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
LITELLM_HOST=http://172.26.0.1:14000
```

> `CLUSTER_MODE=auto` also works here — it probes your kubeconfig and reuses it.
> Use `local` when you want it to **fail loudly** if the cluster isn't up
> (rather than silently creating a kind cluster).

---

## 3. Bring up only the control plane

Because the infra profiles are empty, a plain `up` starts just what's needed.
To be explicit you can name the services:

```bash
docker compose up -d cluster-init auth graphql web
```

What happens:

1. **`cluster-init`** verifies your kube context, then writes a world-readable
   copy of your kubeconfig into a shared volume (your `~/.kube/config` is
   typically `0600` and unreadable by the container's user).
2. **`auth`** starts on :3000 / :3030 and connects to your existing mongo.
3. **`graphql`** starts on :8081 / :8082, reads the shared kubeconfig, and can
   reach your cluster's API server.
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

Open **http://localhost:2001** and log in (`admin` / `litmus`).

---

## 5. Next: run an experiment

Your cluster may already have the chaos infrastructure installed (if you used it
before). If not, follow **[running-an-experiment.md](./running-an-experiment.md)**
to create an environment, enable chaos, apply the infra YAML, and run an
experiment.

---

## Notes & gotchas

- **kubeconfig permissions:** if graphql logs `unable to load in-cluster
  configuration, KUBERNETES_SERVICE_HOST ... must be defined`, it couldn't read
  your kubeconfig. `cluster-init` handles this by publishing a `0644` copy — make
  sure `cluster-init` ran successfully (`docker logs ace-cluster-init`).
- **minikube/k3s gateway IP:** the `172.26.0.1` references assume the kind
  network gateway. For other clusters, find the right host IP
  (`docker network inspect <net> | grep Gateway`, or your host LAN IP) and
  update the `172.26.0.1` values in `.env`.
- **Switching back from a fresh test:** if you ran [route 2](./route-2-fresh-kind.md)
  in the isolated `acefresh` project, stop it and restart your originals:
  ```bash
  docker compose -p acefresh -f docker-compose.yml -f compose/fresh.override.yml down
  docker start agentcert-control-plane agentcert-mongo litellm-proxy \
    langfuse-langfuse-web-1 langfuse-langfuse-worker-1 langfuse-clickhouse-1 \
    langfuse-postgres-1 langfuse-minio-1 langfuse-redis-1
  docker compose up -d cluster-init auth graphql web
  ```
