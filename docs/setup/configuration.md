# Configuration & Changing Ports

Everything is driven by the single **`.env`** file at the repo root. This page
explains the switches you'll actually touch and — importantly — **how to change
ports when some are already busy on your machine**.

- [The compose switches](#the-compose-switches)
- [Profiles: how the switches map to what runs](#profiles-how-the-switches-map-to-what-runs)
- [Required secrets](#required-secrets)
- [Changing ports (busy-port scenario)](#changing-ports-busy-port-scenario)
- [The `172.26.0.1` gateway IP](#the-172_26_0_1-gateway-ip)

---

## The compose switches

These live in the **"Docker Compose one-command bring-up"** block at the bottom
of `.env`:

| Variable | Default | What it does |
|---|---|---|
| `CLUSTER_MODE` | `auto` | How Kubernetes is sourced: `auto`, `local`, `cloud`, `fresh`/`kind`. See the [routes](./README.md#the-three-routes-how-kubernetes-is-sourced). |
| `KIND_CLUSTER_NAME` | `agentcert` | Name of the kind cluster created/reused (routes 2 & auto). |
| `HOST_KUBE_DIR` | `~/.kube` | Host kube directory mounted into the stack. Leave unset to use `~/.kube`; if set, use an **absolute** path. |
| `HOST_PUBLIC_IP` | _(empty)_ | Only for `CLUSTER_MODE=cloud` — the VM address in-cluster pods call back to. |
| `MONGO_MODE` | `local` | `local` = run MongoDB in the stack; `external` = reuse an existing mongo via `DB_SERVER`. |
| `LANGFUSE_MODE` | `local` | `local` = run Langfuse in the stack; `external` = use an existing one via `LANGFUSE_HOST`. |
| `LITELLM_MODE` | `local` | `local` = run the LiteLLM proxy; `external` = use an existing gateway via `LITELLM_HOST`. |
| `COMPOSE_PROFILES` | `mongo,langfuse,litellm` | **The list compose actually reads.** Keep it in sync with the `*_MODE` switches (see below). |
| `WEB_PORT` | `2001` | Informational (the UI runs on host networking; see [changing ports](#changing-ports-busy-port-scenario)). |
| `LANGFUSE_PORT` | `4000` | Host port for the Langfuse UI. |
| `LITELLM_PORT` | `14000` | Host port for the LiteLLM proxy. |

---

## Profiles: how the switches map to what runs

Compose decides which optional stacks start from **`COMPOSE_PROFILES`**. Each
`*_MODE=local` should have its matching token present:

| If you set… | …put this token in `COMPOSE_PROFILES` |
|---|---|
| `MONGO_MODE=local` | `mongo` |
| `LANGFUSE_MODE=local` | `langfuse` |
| `LITELLM_MODE=local` | `litellm` |

**Examples**

```dotenv
# Run absolutely everything locally (default — best for a fresh machine):
COMPOSE_PROFILES=mongo,langfuse,litellm

# Reuse an existing mongo + Langfuse, but run LiteLLM locally:
MONGO_MODE=external
LANGFUSE_MODE=external
LITELLM_MODE=local
COMPOSE_PROFILES=litellm
```

When you set a service to `external`, also point the stack at it:

- `MONGO_MODE=external` → set `DB_SERVER` (and `MONGODB_CONNECTION_STRING` for the certifier).
- `LANGFUSE_MODE=external` → set `LANGFUSE_HOST`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`.
- `LITELLM_MODE=external` → set `LITELLM_HOST`.

> The control-plane services (`auth`, `graphql`, `web`) always run — they are
> the platform itself, not optional infrastructure.

---

## Required secrets

Fill these in `.env` before first start (everything else has defaults):

```dotenv
AZURE_OPENAI_KEY=...            # Azure OpenAI key
AZURE_OPENAI_ENDPOINT=https://<resource>.openai.azure.com/
AZURE_OPENAI_DEPLOYMENT=gpt-4o  # your chat deployment name
LITELLM_MASTER_KEY=sk-...       # any strong string; the gateway's master key
```

If `LANGFUSE_MODE=local`, the Langfuse org/project/API keys are **auto-provisioned**
from the `LANGFUSE_*` values in `.env` on first boot — no manual UI setup. The
Langfuse login for the local instance is `admin@agentcert.local` /
`agentcert-admin` (override with `LANGFUSE_INIT_USER_*`).

---

## Changing ports (busy-port scenario)

> **Scenario:** "I'm new here and some of these ports are already in use on my
> machine. How do I move them, and where exactly?"

There are **two kinds of services**, and they change differently:

### A. Supporting services — one `.env` line each (easy)

`litellm`, `langfuse`, and the `certifier` publish their ports the normal Docker
way, so a single `.env` variable changes the host port:

| Service | Default | Change in `.env` | Also update in `.env` |
|---|---|---|---|
| Langfuse UI | `4000` | `LANGFUSE_PORT=4001` | `LANGFUSE_HOST=http://172.26.0.1:4001` |
| LiteLLM | `14000` | `LITELLM_PORT=14001` | `LITELLM_HOST=http://172.26.0.1:14001` |
| Certifier API | `8000` | `API_PORT=8001` | `CERTIFIER_BASE_URL` / `CERTIFICATE_PDF_BASE_URL` → `:8001` |

Then `docker compose up -d` and you're done.

### B. Control-plane services — host networking (a few coordinated edits)

`auth`, `graphql`, and `web` run on the **host network** so they bind host ports
directly (this keeps the in-cluster networking contract intact). You cannot
remap them with a compose `ports:` line — you change the port the process
**binds**, plus the places that reference it.

| Service | Default | Primary change | Cross-references that MUST match |
|---|---|---|---|
| **GraphQL REST** | `8081` | `.env` → `GQL_REST_PORT=18081` | `.env`: `PORTAL_ENDPOINT`, `SERVER_ADDR`, `SUBSCRIBER_CALLBACK_URL`, `GQL_PROXY_PORT` → use `18081`. Plus `compose/web-nginx.conf` → `/api/` `proxy_pass http://127.0.0.1:18081/` |
| **GraphQL gRPC** | `8082` | `.env` → `GQL_GRPC_PORT=18082` | — |
| **Auth REST** | `3000` | `.env` → `AUTH_REST_PORT=13000` | `.env`: `LITMUS_SVC_ENDPOINT`, `AUTH_PROXY_PORT` → `13000`. Plus `compose/web-nginx.conf` → `/auth/` `proxy_pass http://127.0.0.1:13000/` |
| **Auth gRPC** | `3030` | `.env` → `AUTH_GRPC_PORT=13030` | `.env`: `LITMUS_AUTH_GRPC_PORT=13030` |
| **Web UI** | `2001` | `compose/web-nginx.conf` → `listen 2001;` | (`WEB_PORT` in `.env` is informational only) |

#### Worked example — port 8081 is busy, move GraphQL to 18081

1. **`.env`** — change every occurrence of the GraphQL REST port:
   ```dotenv
   GQL_REST_PORT=18081
   GQL_PROXY_PORT=18081
   PORTAL_ENDPOINT=http://172.26.0.1:18081
   SERVER_ADDR=http://172.26.0.1:18081/query
   SUBSCRIBER_CALLBACK_URL=http://172.26.0.1:18081
   ```
2. **`compose/web-nginx.conf`** — repoint the UI's API proxy:
   ```nginx
   location /api/ {
       ...
       proxy_pass "http://127.0.0.1:18081/";   # was 8081
   }
   ```
3. Recreate the affected services:
   ```bash
   docker compose up -d --force-recreate graphql web
   ```

> **Why so many places?** `SERVER_ADDR` / `SUBSCRIBER_CALLBACK_URL` /
> `PORTAL_ENDPOINT` are baked into the manifests the GraphQL server installs
> **into your cluster** — the in-cluster subscriber pod uses them to call back
> to the control plane. If they don't match the real port, experiments connect
> but the subscriber can't report back.

#### The classic one: port 8080

A kind cluster publishes `8080→80` for its ingress, so AgentCert deliberately
uses **8081** for GraphQL (not 8080). If something else holds 8080 and you need
it for kind ingress, see the [route guides](./route-2-fresh-kind.md) and the
`kind` config in `local-personal-workspace/kind-agentcert.yaml` (the
`hostPort: 8080` mapping). You can change that to e.g. `8088` if 8080 is taken.

### Check what's using a port

```bash
ss -tlnp "( sport = :8081 )"          # your processes
sudo ss -tlnp "( sport = :8081 )"     # include root-owned listeners
docker ps --format '{% raw %}{{.Names}}\t{{.Ports}}{% endraw %}' | grep 8081
```

---

## The `172.26.0.1` gateway IP

You'll see `172.26.0.1` throughout `.env` (e.g. `LANGFUSE_HOST`, `SERVER_ADDR`).
**This is the gateway of the `kind` Docker network** — i.e. "the host, as seen
from inside a cluster pod". It is *not* `docker0` (which is usually
`172.17.0.1`). Using it lets the same address work from both the host and from
in-cluster pods.

- For **kind** (routes 1 & 2) this is correct out of the box.
- For **other local clusters** (minikube/k3s) the gateway may differ — find it
  with `docker network inspect <net> | grep Gateway` and update the `172.26.0.1`
  references in `.env`.
- For **cloud** (route 3), in-cluster pods can't reach `172.26.0.1` — they reach
  your VM via `HOST_PUBLIC_IP`. See [route-3-cloud-aks.md](./route-3-cloud-aks.md).

If your host firewall (UFW) is active, in-cluster pods also need the port opened
**from the kind subnet** — see [running-an-experiment.md](./running-an-experiment.md#networking-checklist-pods--host).
