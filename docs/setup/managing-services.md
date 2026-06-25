---
title: "Managing & Restarting Services"
parent: "Setup"
nav_order: 6
---

# Managing & Restarting Services

Day-to-day operations once the stack is up: checking health, restarting services,
applying `.env` changes, and tearing down. Everything is `kubectl` run from the
repo root against the `ace` namespace.

---

## Service Names

All ACE services are Kubernetes Deployments (or StatefulSets) in the `ace`
namespace:

| Kubernetes name | What it is | Host port |
|---|---|---|
| `deploy/auth` | Authentication backend (REST :3000, gRPC :3030) | 3000 / 3030 |
| `deploy/graphql` | Core backend / GraphQL API (:8081) | 8081 |
| `deploy/web` | AgentCert UI (nginx) | 2001 |
| `deploy/certifier` | Certifier pipeline (FastAPI) | 18000 |
| `deploy/litellm` | LiteLLM proxy | 14000 |
| `deploy/langfuse-web` | Langfuse UI/API | 4000 |
| `deploy/langfuse-worker` | Langfuse background processor | — |
| `statefulset/mongodb` | MongoDB replica set | 27017 |
| `deploy/postgres` | PostgreSQL (Langfuse) | — |
| `deploy/clickhouse` | ClickHouse (Langfuse traces) | — |
| `deploy/redis` | Redis (Langfuse queue) | — |
| `deploy/minio` | MinIO S3 storage (Langfuse blobs) | 19090 |

```bash
kubectl get pods -n ace          # list everything with current state
kubectl get pods -n ace -w       # watch for changes
```

---

## Health Check

```bash
kubectl get pods -n ace
# All pods should show READY 1/1 (or N/N) and STATUS Running
```

Quick HTTP check:

```bash
curl -s -o /dev/null -w "UI      %{http_code}\n" http://localhost:2001/
curl -s -o /dev/null -w "graphql %{http_code}\n" http://localhost:8081/
curl -s -o /dev/null -w "langfuse %{http_code}\n" http://localhost:4000/
curl -s -o /dev/null -w "litellm %{http_code}\n" http://localhost:14000/health
curl -s -o /dev/null -w "cert    %{http_code}\n" http://localhost:18000/docs
```

---

## Restart a Service

```bash
# Rolling restart (keeps old pod running until new one is ready):
kubectl rollout restart -n ace deploy/graphql

# Restart multiple:
kubectl rollout restart -n ace deploy/auth deploy/graphql deploy/web deploy/certifier

# Wait for rollout to complete:
kubectl rollout status -n ace deploy/graphql
```

---

## Tail Logs

```bash
kubectl logs -n ace deploy/graphql -f          # control plane
kubectl logs -n ace deploy/certifier -f        # certification pipeline
kubectl logs -n ace deploy/langfuse-web -f     # Langfuse
kubectl logs -n ace deploy/litellm -f          # LiteLLM proxy
kubectl logs -n ace statefulset/mongodb -f     # MongoDB
```

Add `--previous` to see logs from a crashed container:

```bash
kubectl logs -n ace deploy/graphql --previous
```

---

## Applying `.env` Changes

After editing `.env`, re-run the setup wizard. It recreates the `ace-env` Secret
and restarts all affected deployments:

```bash
./scripts/setup.sh
# … answer Y to deploy at the end
```

To update only the Secret without rerunning the full wizard:

```bash
kubectl create secret generic ace-env \
  --namespace ace \
  --from-env-file=.env \
  --dry-run=client -o yaml | kubectl apply -f -

# Then restart the affected services to pick up the new env:
kubectl rollout restart -n ace deploy/auth deploy/graphql deploy/certifier
```

<div class="callout callout-warning">
<span class="callout-title">⚠ Secrets don't hot-reload</span>
Kubernetes Secrets mounted as env vars are read at pod creation time. A Secret
update only takes effect after the pod is restarted — use <code>kubectl rollout
restart</code> after updating <code>ace-env</code>.
</div>

---

## After a `.env` Change — Quick Reference

| You changed… | Affected deployments | Command |
|---|---|---|
| `AZURE_OPENAI_*`, model alias | `graphql`, `certifier` | `kubectl rollout restart -n ace deploy/graphql deploy/certifier` |
| MongoDB address / creds | `auth`, `graphql`, `certifier` | `kubectl rollout restart -n ace deploy/auth deploy/graphql deploy/certifier` |
| Langfuse keys | `certifier`, `langfuse-web` | `kubectl rollout restart -n ace deploy/certifier deploy/langfuse-web` |
| LiteLLM config | `litellm` | `kubectl rollout restart -n ace deploy/litellm` |
| Any control-plane env, unsure | all four | `kubectl rollout restart -n ace deploy/auth deploy/graphql deploy/web deploy/certifier` |

---

## Pulling Updated Images

Kubernetes uses the image cached on the kind node. To force a pull of a newer
`agentcert/*:latest`:

```bash
# Delete the pod — Kubernetes recreates it, pulling the image fresh:
kubectl delete pod -n ace -l app=graphql
# Or re-apply the manifest (imagePullPolicy: IfNotPresent means no pull if already cached):
# To force: temporarily edit imagePullPolicy to Always, apply, then revert.
```

For a full image refresh (all services):

```bash
# Pull into kind node first:
docker pull agentcert/agentcert-graphql:latest
kind load docker-image agentcert/agentcert-graphql:latest --name agentcert
# Then restart the pod:
kubectl rollout restart -n ace deploy/graphql
```

---

## Tear Down and Recreate

```bash
# Stop everything and delete the kind cluster (removes all data):
kind delete cluster --name agentcert

# Recreate from scratch:
kind create cluster --config local-personal-workspace/kind-agentcert.yaml
./scripts/setup.sh   # answer Y to deploy
```

To keep the cluster but wipe all ACE data:

```bash
# Delete the ace namespace (removes all deployments, PVCs, secrets):
kubectl delete namespace ace

# Redeploy:
./scripts/setup.sh   # answer Y to deploy
```

---

## Common One-Liners

```bash
kubectl get pods -n ace                                    # all service states
kubectl get pods -n ace -l app=graphql                     # one service
kubectl describe pod -n ace <pod-name>                     # detailed state / events
kubectl exec -it -n ace deploy/graphql -- sh               # shell into a container
kubectl top pods -n ace                                    # CPU / memory usage
kubectl get events -n ace --sort-by='.lastTimestamp'       # recent events
```
