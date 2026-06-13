---
title: "Managing & Restarting Services"
parent: "Setup"
nav_order: 6
---

# Managing & Restarting Services

Day-to-day operations once the stack is up: restarting individual services, reloading `.env` changes, and updating images. Everything is `docker compose` run from the repo root.

---

## Service Names

The control-plane services you'll restart most often:

| Service (compose) | Container | What it is |
|---|---|---|
| `auth` | `agentcert-auth` | Authentication backend (REST :3000, gRPC :3030) |
| `graphql` | `agentcert-graphql` | Core backend / GraphQL API (:8081) — installs agents, RBAC, infra |
| `web` | `agentcert-web` | AgentCert UI (nginx, :2001) |
| `app` | `certifier_app` | Certifier service (:8000) |

Supporting services (you rarely restart these): `mongo`, `langfuse-web`, `langfuse-worker`, `postgres`, `clickhouse`, `redis`, `minio`, `litellm`, `cluster-init`.

```bash
docker compose ps    # list everything with current state
```

---

## Restart vs Recreate

<div class="callout callout-warning">
<span class="callout-title">⚠ restart does NOT reload .env</span>
Environment variables are read <strong>only when a container is created</strong>.<br><br>
<code>docker compose restart &lt;svc&gt;</code> → reuses the existing container → <strong>keeps the old env</strong>.<br>
<code>docker compose up -d --force-recreate &lt;svc&gt;</code> → creates a fresh container → <strong>reads the current .env</strong>.<br><br>
After editing <code>.env</code>, always use <code>--force-recreate</code>.
</div>

```bash
# Fast restart (does NOT reload .env):
docker compose restart auth graphql web app

# Recreate so .env + image changes take effect:
docker compose up -d --force-recreate auth graphql web app

# One service only:
docker compose up -d --force-recreate graphql
```

---

## Pulling and Rebuilding Images

<div class="callout callout-info">
<span class="callout-title">No auto-pull on restart</span>
Neither <code>restart</code> nor <code>--force-recreate</code> pulls or rebuilds the image. The local image is reused as-is. You only get a new image when you ask for one.
</div>

```bash
# (A) Update published images (agentcert/* on Docker Hub), then restart:
docker compose pull auth graphql web
docker compose up -d auth graphql web

# …or in one step:
docker compose up -d --pull always auth graphql web
```

```bash
# (B) Rebuild from local source (services with a build: section):
docker compose build graphql
docker compose up -d graphql

# …or in one step:
docker compose up -d --build graphql
```

> **First-ever `docker compose up`** (image missing locally): services with a `build:` section are **built** from source; image-only services (`mongo`, `litellm`, `postgres`, …) are **pulled**. After that, the image is cached until you explicitly `pull` or `build`.

---

## Common One-Liners

```bash
docker compose ps                                # states of all services
docker compose ps auth graphql web app           # just the control plane
docker compose logs -f graphql                   # tail one service's logs
docker compose logs -f auth graphql web app      # tail several at once
docker compose stop graphql                       # stop one service
docker compose down                               # stop & remove containers (keeps volumes/data)
docker compose down -v                            # stop + WIPE data — destructive
```

---

## After a `.env` Change — Quick Reference

| You changed… | Affected services | Command |
|---|---|---|
| `AZURE_OPENAI_*`, model alias | `graphql` | `docker compose up -d --force-recreate graphql` |
| Mongo address / port | `auth`, `graphql`, `app` | `docker compose up -d --force-recreate auth graphql app` |
| Callback host / `SERVER_ADDR` / origins | `graphql` | `docker compose up -d --force-recreate graphql` |
| Langfuse / LiteLLM host | `app`, `litellm` | `docker compose up -d --force-recreate app litellm` |
| Any control-plane env, unsure | all four | `docker compose up -d --force-recreate auth graphql web app` |

<div class="callout callout-tip">
Re-running <code>scripts/setup.sh</code> also applies <code>.env</code> changes and recreates the affected services for you, including re-detecting the kind gateway.
</div>
