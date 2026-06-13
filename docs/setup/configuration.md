---
title: "Configuration & Ports"
parent: "Setup"
nav_order: 1
---

# Configuration & Changing Ports

Everything is driven by the single **`.env`** file at the repo root. This page explains the switches you'll actually touch and — importantly — **how to change ports when some are already busy on your machine**.

- [The compose switches](#the-compose-switches)
- [Profiles: how the switches map to what runs](#profiles-how-the-switches-map-to-what-runs)
- [Required secrets](#required-secrets)
- [Changing ports (busy-port scenario)](#changing-ports-busy-port-scenario)
- [The `172.26.0.1` gateway IP](#the-172_26_0_1-gateway-ip)

---

## The Compose Switches

These live in the **"Docker Compose one-command bring-up"** block at the bottom of `.env`:

| Variable | Default | What it does |
|---|---|---|
| `CLUSTER_MODE` | `auto` | How Kubernetes is sourced: `auto`, `local`, `cloud`, `fresh`/`kind`. See the [routes]({{ "/setup/README.html" | relative_url }}#choose-your-kubernetes-route). |
| `KIND_CLUSTER_NAME` | `agentcert` | Name of the kind cluster created/reused (routes 2 & auto). |
| `HOST_KUBE_DIR` | `~/.kube` | Host kube directory mounted into the stack. Use an **absolute** path if set. |
| `HOST_PUBLIC_IP` | _(empty)_ | Only for `CLUSTER_MODE=cloud` — the VM address in-cluster pods call back to. |
| `MONGO_MODE` | `local` | `local` = run MongoDB in the stack; `external` = reuse an existing mongo via `DB_SERVER`. |
| `LANGFUSE_MODE` | `local` | `local` = run Langfuse in the stack; `external` = use an existing one via `LANGFUSE_HOST`. |
| `LITELLM_MODE` | `local` | `local` = run the LiteLLM proxy; `external` = use an existing gateway via `LITELLM_HOST`. |
| `COMPOSE_PROFILES` | `mongo,langfuse,litellm` | **The list compose actually reads.** Keep in sync with the `*_MODE` switches. |
| `WEB_PORT` | `2001` | Informational (the UI runs on host networking). |
| `LANGFUSE_PORT` | `4000` | Host port for the Langfuse UI. |
| `LITELLM_PORT` | `14000` | Host port for the LiteLLM proxy. |

---

## Profiles: How the Switches Map to What Runs

Compose decides which optional stacks start from **`COMPOSE_PROFILES`**. Each `*_MODE=local` should have its matching token present:

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

When you set a service to `external`, point the stack at it:

- `MONGO_MODE=external` → set `DB_SERVER` (and `MONGODB_CONNECTION_STRING` for the certifier).
- `LANGFUSE_MODE=external` → set `LANGFUSE_HOST`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`.
- `LITELLM_MODE=external` → set `LITELLM_HOST`.

<div class="callout callout-info">
The control-plane services (<code>auth</code>, <code>graphql</code>, <code>web</code>) always run — they are the platform itself, not optional infrastructure.
</div>

---

## LLM Providers

The wizard (`./scripts/setup.sh`) walks through three providers in order. Configure as many as you need:

### a) Azure OpenAI

Required for the **certifier** (all four phases). Also used by the flash-agent if selected.

| Variable | What it does |
|---|---|
| `AZURE_OPENAI_KEY` | API key (fanned to certifier standard, reasoning, and embedding consumers) |
| `AZURE_OPENAI_ENDPOINT` | `https://<resource>.openai.azure.com/` |
| `AZURE_OPENAI_API_VERSION` | API version (default in `.env.example` if omitted) |
| `AZURE_OPENAI_CHAT_DEPLOYMENT_NAME` | **Certifier** standard model deployment (e.g. `gpt4o`) |
| `AZURE_OPENAI_GPT5_CHAT_DEPLOYMENT_NAME` | **Certifier** reasoning model deployment (defaults to standard if omitted) |
| `AZURE_EMBEDDING_MODEL` | **Certifier** embedding deployment (optional — skip to disable vector search) |
| `AZURE_OPENAI_DEPLOYMENT` | LiteLLM model alias the flash-agent requests (e.g. `gpt-4o`) |

### b) Google Gemini

Optional. Powers the **flash-agent** only (not the certifier). Provides `gemini-3-flash`, `gemini-2.5-flash`, `gemini-2.5-flash-lite` as LiteLLM aliases.

```dotenv
GEMINI_API_KEY=...
```

### c) OpenRouter

Optional. Powers the **flash-agent** only. Provides the `auto-free` alias for zero-cost routing.

```dotenv
OPENROUTER_API_KEY=...
```

### Flash-agent model

After configuring providers, the wizard shows all available aliases and sets:

```dotenv
FLASH_AGENT_MODEL=gpt-4o   # the LiteLLM alias the flash-agent will request
```

You can change this at any time and `docker compose up -d --force-recreate graphql` to apply.

<div class="callout callout-warning">
<span class="callout-title">Certifier always needs Azure</span>
The certifier calls Azure OpenAI directly, not via LiteLLM. Gemini/OpenRouter keys power the flash-agent but do not enable certification reports.
</div>

---

## Required Secrets

<div class="callout callout-warning">
<span class="callout-title">Fill these in before first start</span>
The wizard prompts for all of these. If you run <code>docker compose up -d</code> directly, set them in <code>.env</code> first.
</div>

**Minimum for running experiments (flash-agent only, no certification):**

```dotenv
# One of: Azure / Gemini / OpenRouter
GEMINI_API_KEY=...          # OR OPENROUTER_API_KEY / Azure block below
FLASH_AGENT_MODEL=gemini-2.5-flash
```

**Full stack including certification reports:**

```dotenv
AZURE_OPENAI_KEY=...
AZURE_OPENAI_ENDPOINT=https://<resource>.openai.azure.com/
AZURE_OPENAI_CHAT_DEPLOYMENT_NAME=gpt4o          # certifier standard model
AZURE_OPENAI_GPT5_CHAT_DEPLOYMENT_NAME=gpt5-2    # certifier reasoning (optional)
AZURE_OPENAI_DEPLOYMENT=gpt-4o                   # LiteLLM alias for flash-agent
FLASH_AGENT_MODEL=gpt-4o
```

If `LANGFUSE_MODE=local`, the Langfuse org/project/API keys are **auto-provisioned** on first boot. The local Langfuse login is `admin@agentcert.local` / `agentcert-admin` (override with `LANGFUSE_INIT_USER_*`).

---

## Changing Ports (Busy-Port Scenario)

There are **two kinds of services**, and they change differently:

### A. Supporting Services — One `.env` Line Each

`litellm`, `langfuse`, and `certifier` publish their ports the normal Docker way:

| Service | Default | Change in `.env` | Also update in `.env` |
|---|---|---|---|
| Langfuse UI | `4000` | `LANGFUSE_PORT=4001` | `LANGFUSE_HOST=http://172.26.0.1:4001` |
| LiteLLM | `14000` | `LITELLM_PORT=14001` | `LITELLM_HOST=http://172.26.0.1:14001` |
| Certifier API | `8000` | `API_PORT=8001` | `CERTIFIER_BASE_URL` / `CERTIFICATE_PDF_BASE_URL` → `:8001` |

Then `docker compose up -d` and you're done.

### B. Control-Plane Services — Host Networking

`auth`, `graphql`, and `web` run on the **host network** — you change the port the process **binds**, plus the places that reference it.

| Service | Default | Primary change | Cross-references that MUST match |
|---|---|---|---|
| **GraphQL REST** | `8081` | `.env` → `GQL_REST_PORT=18081` | `.env`: `PORTAL_ENDPOINT`, `SERVER_ADDR`, `SUBSCRIBER_CALLBACK_URL`, `GQL_PROXY_PORT` → `18081`; plus `compose/web-nginx.conf` → `proxy_pass http://127.0.0.1:18081/` |
| **GraphQL gRPC** | `8082` | `.env` → `GQL_GRPC_PORT=18082` | — |
| **Auth REST** | `3000` | `.env` → `AUTH_REST_PORT=13000` | `.env`: `LITMUS_SVC_ENDPOINT`, `AUTH_PROXY_PORT` → `13000`; plus `compose/web-nginx.conf` → `proxy_pass http://127.0.0.1:13000/` |
| **Auth gRPC** | `3030` | `.env` → `AUTH_GRPC_PORT=13030` | `.env`: `LITMUS_AUTH_GRPC_PORT=13030` |
| **Web UI** | `2001` | `compose/web-nginx.conf` → `listen 2001;` | (`WEB_PORT` in `.env` is informational only) |

#### Worked Example — Port 8081 Is Busy, Move GraphQL to 18081

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

<div class="callout callout-info">
<span class="callout-title">Why so many places?</span>
<code>SERVER_ADDR</code> / <code>SUBSCRIBER_CALLBACK_URL</code> / <code>PORTAL_ENDPOINT</code> are baked into the manifests the GraphQL server installs <strong>into your cluster</strong>. The in-cluster subscriber pod uses them to call back to the control plane. If they don't match the real port, experiments connect but the subscriber can't report back.
</div>

#### The Classic One: Port 8080

A kind cluster publishes `8080→80` for its ingress, so ACE deliberately uses **8081** for GraphQL. If something else holds 8080 and you need it for kind ingress, edit `hostPort` in `local-personal-workspace/kind-agentcert.yaml`.

### Check What's Using a Port

```bash
ss -tlnp "( sport = :8081 )"          # your processes
sudo ss -tlnp "( sport = :8081 )"     # include root-owned listeners
docker ps --format '{% raw %}{{.Names}}\t{{.Ports}}{% endraw %}' | grep 8081
```

---

## The Kind Gateway IP

You'll see a gateway address (typically `172.26.0.1` but **not always**) throughout `.env` in variables like `LANGFUSE_HOST`, `SERVER_ADDR`, and `SUBSCRIBER_CALLBACK_URL`. This is the **gateway of the `kind` Docker network** — the address that means "the host, as seen from inside a cluster pod".

<div class="callout callout-success">
<span class="callout-title">setup.sh auto-detects this for you</span>
The wizard runs <code>docker network inspect kind</code> to find the actual gateway for your machine. It also re-detects <em>after</em> <code>docker compose up</code> (on a fresh VM the kind network doesn't exist yet when you first run the wizard) and rewrites the callback URLs if the value changed, then recreates <code>graphql</code> automatically.
</div>

<div class="callout callout-info">
The gateway is assigned by Docker based on how many networks already exist on your machine — it is <strong>not always <code>172.26.0.1</code></strong>. It could be <code>172.18.0.1</code>, <code>172.19.0.1</code>, etc. Never hardcode it; always let setup.sh detect it, or find it yourself with <code>docker network inspect kind | grep Gateway</code>.
</div>

<div class="route-grid" style="grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); margin-top: .8rem;">
  <div class="route-card">
    <div class="route-label">kind (routes 1 &amp; 2)</div>
    <div class="route-card-when">Auto-detected by setup.sh. Find it yourself: <code>docker network inspect kind | grep Gateway</code>.</div>
  </div>
  <div class="route-card">
    <div class="route-label">Other local clusters</div>
    <div class="route-card-when">Gateway may differ from kind's. Find it with <code>docker network inspect &lt;net&gt; | grep Gateway</code> and update the URL vars in <code>.env</code>.</div>
  </div>
  <div class="route-card">
    <div class="route-label">Cloud (route 3)</div>
    <div class="route-card-when">No kind network — in-cluster pods use <code>HOST_PUBLIC_IP</code> instead. Set this in <code>.env</code> and the wizard wires it up.</div>
  </div>
</div>

If your host firewall (UFW) is active, in-cluster pods also need the port opened **from the kind subnet** — see [running-an-experiment.md]({{ "/setup/running-an-experiment.html" | relative_url }}#networking-checklist-pods--host).
