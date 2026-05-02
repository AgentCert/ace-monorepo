# Machine setup notes

System-wide tooling installed on this host. All paths and ports here are accurate as of 2026-04-30.

---

## kind (Kubernetes in Docker)

### Install

| Item | Value |
|---|---|
| Version | v0.31.0 |
| Binary | `/usr/local/bin/kind` (owner `root:root`, mode `0755`) |
| Architecture | linux/amd64 |
| Backend | Docker (`/usr/bin/docker`) |

The binary lives in `/usr/local/bin`, so every user gets it via `$PATH`. To run kind, a user needs to be in the `docker` group:

```bash
groups | grep -q docker || sudo usermod -aG docker "$USER"   # then log out and back in
```

### Per-user kubeconfig

`/etc/profile` sets `KUBECONFIG=$HOME/.kube/config` for every login shell. On first login, if the user has no `~/.kube/config`, it is auto-seeded from the shared `/etc/kubernetes/config` so existing cluster access is preserved. After seeding, each user's kubeconfig is independent — kind, minikube, and `kubectl config set-context` can all write to it without permission errors.

Backup of the original profile: `/etc/profile.bak.20260430`.

### Smoke test

```bash
kind create cluster --name test && kind delete cluster --name test
```

Should complete with no errors and no flags.

---

## Langfuse (self-hosted)

### Layout

| Item | Value |
|---|---|
| Install dir | `/opt/langfuse` |
| Compose file | `/opt/langfuse/docker-compose.yml` |
| Secrets | `/opt/langfuse/.env` (mode `0640`, randomly generated) |
| Image tag | `langfuse:3` (web), `langfuse-worker:3` |

### Reserved ports — NOT used by Langfuse

`3000`, `3030`, `8080`, `8082`, `2001` are intentionally avoided so they remain free for other services on this host.

### Published ports

| Service | Host port | Bind | Notes |
|---|---|---|---|
| **Langfuse Web UI** | **4000** | `0.0.0.0` | http://localhost:4000 — main UI/API |
| Langfuse Worker | 4030 | `127.0.0.1` | health/debug only |
| Postgres | 5432 | `127.0.0.1` | internal storage |
| Redis | 6379 | `127.0.0.1` | queue/cache |
| ClickHouse HTTP | 8123 | `127.0.0.1` | analytics store |
| ClickHouse native | 9000 | `127.0.0.1` | analytics store |
| MinIO API | 9090 | `0.0.0.0` | S3-compatible object store |
| MinIO Console | 9091 | `127.0.0.1` | web console |

### Open the UI

http://localhost:4000 — the first user to sign up becomes the org owner.

### Manage the stack

Any user in the `docker` group can manage it:

```bash
cd /opt/langfuse
docker compose ps                    # status
docker compose logs -f langfuse-web  # tail web logs
docker compose down                  # stop
docker compose up -d                 # start (or restart after config change)
```

### Persistent state

Stack data lives in named Docker volumes:

- `langfuse_langfuse_postgres_data`
- `langfuse_langfuse_clickhouse_data`
- `langfuse_langfuse_clickhouse_logs`
- `langfuse_langfuse_minio_data`
- `langfuse_langfuse_redis_data`

Wiping any of these resets that component. Secrets in `.env` are tied to volume state — if you wipe postgres but keep `.env`, you must also re-init the new password (or wipe `.env` and let a fresh stack start clean).

---

## kind pods → host services (networking + UFW)

When a service runs on the host and needs to be reached from inside a kind cluster pod, three things have to line up. Each one fails silently in a different way, so check them in order.

### 1. The host IP from inside a kind pod

`localhost` inside a kind pod is the **pod's** loopback, not the host. Pods reach the host on the kind-network gateway:

```bash
docker network inspect kind | grep Gateway
# → 172.26.0.1   (this host's IP from inside the cluster)
```

Subnet is `172.26.0.0/16`. Pods get `10.244.x.x`. Anything templated as `localhost` will be wrong inside the cluster — substitute `172.26.0.1`.

### 2. The host service must bind `0.0.0.0`, not `127.0.0.1`

Verify with `ss -tlnp '( sport = :PORT )'`. A `127.0.0.1` bind is unreachable from kind pods even with UFW open.

### 3. UFW must allow the port from the kind subnet

UFW INPUT defaults to `DROP` on this host. Each app port reached from kind needs an explicit allow:

```bash
sudo ufw allow from 172.26.0.0/16 to any port <PORT> proto tcp comment '<service> kind→host'
```

Symptom when missing: `wget` from a `kubectl run` busybox times out; the kind node container itself can curl `127.0.0.1:PORT` (loopback, exempt) but **not** `172.26.0.1:PORT`.

### Currently allowed for kind→host

| Port | Service | Notes |
|---|---|---|
| 4000 | Langfuse Web UI/API | needed by GraphQL traces and any in-cluster otel exporter |
| 8081 | AgentCert GraphQL | moved off 8080 because kind control-plane publishes 8080→80 for its ingress |

(3000/3001 are open `Anywhere` already for Langfuse v3 + OTEL.)

---

## AgentCert dev stack on this host

### Port assignments (post-move)

| Port | Service | Why this port |
|---|---|---|
| 3000 | Auth REST | default |
| 3030 | Auth gRPC | default |
| 8081 | GraphQL REST | **moved off 8080** — kind's `agentcert-control-plane` container publishes `0.0.0.0:8080->80` for ingress |
| 8082 | GraphQL gRPC | default |
| 2001 | Frontend (yarn dev) | default |

### `.env` values that must use `172.26.0.1` (not `localhost`)

These are read by GraphQL at startup and templated into manifests installed into the kind cluster. `localhost` here means "the subscriber pod's loopback" and breaks every install.

```dotenv
SERVER_ADDR=http://172.26.0.1:8081/query
CHAOS_CENTER_UI_ENDPOINT=http://172.26.0.1:8081
PORTAL_ENDPOINT=http://172.26.0.1:8081
LANGFUSE_HOST=http://172.26.0.1:4000
OTEL_EXPORTER_OTLP_ENDPOINT=http://172.26.0.1:3001/api/public/otel
```

`AGENT_OTEL_EXPORTER_OTLP_ENDPOINT` already uses an external IP — leave it.

### `ALLOWED_ORIGINS` (websocket / CORS)

The GraphQL server's WS upgrader regex-matches the Host header. The default in the script only covers `localhost` + tailscale `100.78.*` / `100.104.*`. Subscribers connecting to `172.26.0.1:8081` are rejected as `bad handshake` until the regex includes RFC1918 ranges:

```
^(http://|https://|)((localhost|host\.docker\.internal|host\.minikube\.internal)|100\.78\.[0-9]+\.[0-9]+|100\.104\.[0-9]+\.[0-9]+|172\.[0-9]+\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+)(:[0-9]+|)$
```

This is exported by [AgentCert/azure_build/start-agentcert-v2.sh](AgentCert/azure_build/start-agentcert-v2.sh).

### Fixing an existing infra install (when subscriber is already deployed)

If the subscriber pod was created before the fixes above, its ConfigMap still has `localhost`. Patch in place — no need to reinstall:

```bash
kubectl patch configmap subscriber-config -n litmus --type merge \
  -p '{"data":{"SERVER_ADDR":"http://172.26.0.1:8081/query"}}'
kubectl rollout restart deploy/subscriber -n litmus
```

### Failure-mode quick reference

| Subscriber log says | Cause | Fix |
|---|---|---|
| `dial tcp [::1]:8081: connect: connection refused` | `SERVER_ADDR` has `localhost` | patch ConfigMap to `172.26.0.1` |
| `dial tcp 172.26.0.1:8081: i/o timeout` | UFW dropping the port | add `ufw allow from 172.26.0.0/16 to any port 8081` |
| `websocket: bad handshake` | `ALLOWED_ORIGINS` regex doesn't match `172.*` | widen regex (see above) and restart GraphQL |
| `Post "http://.../api/query": 404` | infra_utils.go appends `/api/query` but server only routes `/query` | patch ConfigMap with `/query` (no `/api`) — code-level fix pending |

---

## Command runbook

Copy-paste in order. Most commands are user-level; sudo lines are flagged.

### One-time per user (host-level prerequisites)

```bash
# Allow git to operate on the shared repos (owner is `chetana`, you may be `ujjwal`)
git config --global --add safe.directory /srv/projects/ace-monorepo/AgentCert
git config --global --add safe.directory /srv/projects/ace-monorepo/agent-charts
git config --global --add safe.directory /srv/projects/ace-monorepo/app-charts
git config --global --add safe.directory /srv/projects/ace-monorepo/flash-agent

# UFW: open AgentCert ports for kind→host (sudo)
sudo ufw allow from 172.26.0.0/16 to any port 8081 proto tcp comment 'AgentCert kind→GraphQL'
sudo ufw allow from 172.26.0.0/16 to any port 4000 proto tcp comment 'AgentCert kind→Langfuse'
sudo ufw status numbered | grep -E '8081|4000'   # verify
```

### Pull latest on every repo

```bash
for d in AgentCert agent-charts app-charts flash-agent; do
  echo "=== $d ===" && (cd /srv/projects/ace-monorepo/$d && git status -sb && git pull --ff-only)
done
```

### Start the AgentCert stack

```bash
cd /srv/projects/ace-monorepo/AgentCert/azure_build
bash start-agentcert-v2.sh \
  --env-file   /srv/projects/ace-monorepo/AgentCert/azure_build/.env \
  --paths-file /srv/projects/ace-monorepo/AgentCert/azure_build/build-paths.env

# Useful flags:
#   --skip-mongo      # already running
#   --skip-frontend   # backend-only
#   --skip-litellm    # kind cluster down / kubectl unreachable
```

The script auto-handles three things that bit us:

```bash
# CRLF in chaoscenter/web/scripts/generate-certificate.sh
sed -i 's/\r$//' /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/scripts/generate-certificate.sh

# Missing certificates dir (yarn generate-certificate fails otherwise)
mkdir -p /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/certificates

# go build VCS stamping under shared ownership
GOFLAGS=-buildvcs=false go build -o agentcert-graph .   # baked into v2 script
```

### Stop the AgentCert stack

```bash
bash /srv/projects/ace-monorepo/AgentCert/stop-agentcert.sh

# Or by hand:
pkill -9 -f agentcert-graph
pkill -9 -f 'go run main.go'
pkill -9 -f 'yarn dev'
for p in 3030 3000 8080 8081 8082 2001; do
  pid=$(lsof -ti :$p 2>/dev/null); [ -n "$pid" ] && kill -9 "$pid" && echo "killed $pid on $p"
done
```

### Verify the stack is healthy

```bash
# Listening ports (look for our PIDs, not docker-proxy)
ss -tlnp '( sport = :3030 or sport = :3000 or sport = :8081 or sport = :8082 or sport = :2001 )'

# GraphQL responds
curl -s -o /dev/null -w "graphql /query -> %{http_code}\n" \
  -X POST -H 'Content-Type: application/json' \
  --data '{"query":"{ __typename }"}' \
  http://172.26.0.1:8081/query

# kind pods can reach the host
kubectl run -i --rm --restart=Never reach-test --image=busybox --command -- \
  sh -c 'wget -q -T 3 -O- http://172.26.0.1:8081/query --post-data={} --header=Content-Type:application/json'
```

### Subscriber troubleshooting

```bash
# Inspect what the subscriber pod is currently configured with
kubectl logs -n litmus deploy/subscriber --tail=20
kubectl get cm subscriber-config -n litmus -o yaml | grep SERVER_ADDR

# Patch a stale install (no need to reinstall the whole infra)
kubectl patch cm subscriber-config -n litmus --type merge \
  -p '{"data":{"SERVER_ADDR":"http://172.26.0.1:8081/query"}}'
kubectl rollout restart deploy/subscriber -n litmus
kubectl rollout status  deploy/subscriber -n litmus --timeout=120s
```

### LiteLLM troubleshooting

```bash
# Pod status
kubectl -n litellm get pods
kubectl -n litellm logs deploy/litellm-proxy --tail=50

# Re-apply config + force a fresh pod
kubectl apply -f /srv/projects/ace-monorepo/agent-charts/litellm/configmap.yaml
kubectl -n litellm rollout restart deploy/litellm-proxy

# Hit it from inside the cluster
kubectl run -i --rm --restart=Never litellm-test --image=curlimages/curl --command -- \
  curl -s -H "Authorization: Bearer $(grep ^LITELLM_MASTER_KEY /srv/projects/ace-monorepo/AgentCert/azure_build/.env | cut -d= -f2)" \
  http://litellm-proxy.litellm.svc.cluster.local:4000/v1/models
```

### Mongo: reset admin password

If `admin/litmus` login fails with `invalid_credentials`, the existing user row predates your current `.env`:

```bash
# Drop the admin user and restart auth so it reseeds from .env
docker exec mongodb mongo -u admin -p 1234 --authenticationDatabase admin auth \
  --eval 'db.users.deleteOne({username:"admin"})'
pkill -9 -f 'go run main.go'
# Then re-run start-agentcert-v2.sh (auth will re-seed admin/litmus)
```

### App install fails with `clusterroles ... is forbidden`

The install-app job runs as `system:serviceaccount:litmus:argo-chaos`, which is bound to `infra-cluster-role` — a namespace-scoped role missing `rbac.authorization.k8s.io/clusterroles` perms. Charts like sock-shop with `monitoring.enabled: true` ship a `ClusterRole prometheus` that this SA can't create.

Symptom in the install-app pod log:

```
Error: Unable to continue with install: ... clusterroles.rbac.authorization.k8s.io 'prometheus'
is forbidden: User 'system:serviceaccount:litmus:argo-chaos' cannot get resource 'clusterroles'
in API group 'rbac.authorization.k8s.io' at the cluster scope
```

Quick fix (dev-only — grants cluster-admin):

```bash
kubectl create clusterrolebinding argo-chaos-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=litmus:argo-chaos
```

Scoped alternative — extend the existing role with just RBAC perms:

```bash
kubectl patch clusterrole infra-cluster-role --type=json -p='[
  {"op":"add","path":"/rules/-","value":{
    "apiGroups":["rbac.authorization.k8s.io"],
    "resources":["clusterroles","clusterrolebindings"],
    "verbs":["get","list","create","update","patch","delete","watch"]
  }}
]'
```

To remove (revert to default RBAC):

```bash
kubectl delete clusterrolebinding argo-chaos-admin
```

#### Why this works on AKS without the fix

The same chaos infra install ([1b_argo_rbac.yaml](AgentCert/chaoscenter/graphql/server/manifests/cluster/1b_argo_rbac.yaml)) runs on every cluster — kind or AKS. It only binds `argo-chaos` to:

| Binding | Role | Scope |
|---|---|---|
| `argo-chaos-infra-cluster-role-binding` | `infra-cluster-role` | cluster-wide but limited (apps, batch, pods, events, services — **no `rbac.authorization.k8s.io`**) |
| `argo-chaos-ops-role-binding` | `infra-ops-role` | namespace-only |

Neither grants `clusterroles` create perms. So in theory, sock-shop with `monitoring.enabled=true` should fail on AKS too. If it doesn't, almost always the AKS cluster has an *extra* binding done out-of-band:

1. **Pre-existing cluster-admin binding** — an early ops command like `kubectl create clusterrolebinding litmus-admin --clusterrole=cluster-admin --serviceaccount=litmus:argo-chaos` survives infra reinstalls. Kind starts fresh and never had it.
2. **A different install chart/operator** — if AgentCert on AKS was deployed via a top-level helm chart (not the per-infra subscriber install), that chart may have shipped its own cluster-admin binding.
3. **Azure RBAC integration** — if Azure RBAC is wired in, an AAD principal may inherit broader perms (rare for SAs, but possible).

To confirm on AKS:

```bash
# Switch to AKS context first, then:
kubectl get clusterrolebinding -o json \
  | jq -r '.items[] | select(.subjects[]?.name=="argo-chaos") | "\(.metadata.name) → \(.roleRef.name)"'
```

Anything beyond `argo-chaos-infra-cluster-role-binding → infra-cluster-role` is the leftover binding that makes AKS "just work" while kind needs the fix above.

### Conflict with kind on port 8080

```bash
# What's holding 8080 (run as root or via sudo to see the PID)
sudo ss -tlnp '( sport = :8080 )'
docker ps --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}' | grep 8080

# Free 8080 by pausing the kind cluster (state preserved on disk)
docker stop agentcert-control-plane     # pauses cluster (in-cluster LiteLLM unreachable)
docker start agentcert-control-plane    # bring it back
```
