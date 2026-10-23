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

| Kubernetes name | What it is | Host port (default) |
|---|---|---|
| `deploy/auth` | Authentication backend (REST :3000, gRPC :3030 in-cluster) | 3005 / 3030 |
| `deploy/graphql` | Core backend / GraphQL API (:8081) | 8081 |
| `deploy/web` | AgentCert UI (nginx) | 2001 |
| `deploy/certifier` | Certifier pipeline (FastAPI) | 18000 |
| `deploy/litellm` | LiteLLM proxy | 14000 |
| `deploy/langfuse-web` | Langfuse UI/API | 4002 |
| `deploy/langfuse-worker` | Langfuse background processor | — |
| `statefulset/mongodb` | MongoDB replica set | 27017 |
| `deploy/postgres` | PostgreSQL (Langfuse) | — |
| `deploy/clickhouse` | ClickHouse (Langfuse traces) | — |
| `deploy/redis` | Redis (Langfuse queue) | — |
| `deploy/minio` | MinIO S3 storage (Langfuse blobs) | 19090 |

Host ports come from the `KIND_HOSTPORT_*` keys in `.env`; setup picks free ones on a
shared host, so check `.env` (or the banner setup printed) if a URL does not answer.

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
curl -s -o /dev/null -w "langfuse %{http_code}\n" http://localhost:4002/
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

After editing `.env`, re-apply it. `--restart` reuses every saved answer and asks
nothing:

```bash
./scripts/setup.sh --restart
```

Use the full wizard only when you want to change the answers themselves:

```bash
./scripts/setup.sh --deploy
# … at the final prompt, `Choice [k/H/n]:` — Enter (or `h`) deploys with Helm
```

Both recreate the `ace-env` Secret and roll out the affected deployments.

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

For a full image refresh (all services), rebuild from this checkout and let setup
side-load and restart everything:

```bash
./scripts/setup.sh --restart --local-build
```

To refresh a single published image by hand, note that the cluster name is the
`KIND_CLUSTER_NAME` value in `.env` (`agentcert-<ACE_INSTANCE_NAME>`), not `agentcert`:

```bash
docker pull agentcert/agentcert-graphql:latest
kind load docker-image agentcert/agentcert-graphql:latest \
  --name "$(grep -m1 '^KIND_CLUSTER_NAME=' .env | cut -d= -f2-)"
kubectl rollout restart -n ace deploy/graphql
```

---

## Tear Down and Recreate

Use the script — it dumps MongoDB first, then removes this checkout's containers,
volumes and kind cluster:

```bash
./scripts/shut_down.sh          # add -y to skip the confirmation prompts
```

What it does:

| Action | Detail |
|---|---|
| Dumps MongoDB | `.tmp/mongodb-backups/<instance>/mongodb-<UTC>.archive.gz`, 10 newest kept. Skip with `--no-mongo-backup` |
| Deletes the kind cluster | `kind delete cluster --name "$KIND_CLUSTER_NAME"` plus its ownership-marker volume |
| Deletes this instance's containers and volumes | Everything scoped to `ACE_INSTANCE_NAME` |
| **Keeps** Docker images | `docker image prune` / `docker rmi` them yourself |
| **Keeps** `.env` | Read-only to the script |
| Keeps the Ollama model volume | Default; override with `--delete-ollama-model` |
| Deletes Langfuse trace volumes | Default; keep them with `--keep-langfuse-traces` |

Recreate afterwards — setup rebuilds the cluster from the saved `.env` and offers
to restore the dump it took:

```bash
./scripts/setup.sh --restart
```

Deleting the cluster by hand needs the real name, which is
`agentcert-<ACE_INSTANCE_NAME>` (e.g. `agentcert-sachin-mourya`) and is stored in
`KIND_CLUSTER_NAME` in `.env` — it is never plain `agentcert`:

```bash
kind get clusters                                   # shows the real name
kind delete cluster --name "$(grep -m1 '^KIND_CLUSTER_NAME=' .env | cut -d= -f2-)"
```

To keep the cluster but wipe all ACE data:

```bash
# Delete the ace namespace (removes all deployments, PVCs, secrets):
kubectl delete namespace ace

# Redeploy:
./scripts/setup.sh --restart
```

---

## Helm Path — Upgrade & Rollback

If you deployed via Helm (`h` choice in setup.sh), use these commands instead
of re-applying raw manifests:

```bash
# Upgrade to latest (also re-injects litellm config):
helm upgrade ace deploy/helm/ace \
  --set-file litellm.config=agentcert-stack/litellm-setup/litellm_config.yaml \
  --timeout 10m

# See release history:
helm history ace -n ace

# Roll back one version:
helm rollback ace -n ace

# Roll back to a specific revision:
helm rollback ace 2 -n ace

# Show what would change (dry-run):
helm upgrade ace deploy/helm/ace --dry-run

# Uninstall (keeps PVCs — data is safe):
helm uninstall ace -n ace
```

Helm vs kubectl — after `.env` changes the workflow is the same: re-run
`./scripts/setup.sh --restart` (or `--deploy` and press Enter at `Choice [k/H/n]`).
The script recreates the `ace-env` Secret before running `helm upgrade`.

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
