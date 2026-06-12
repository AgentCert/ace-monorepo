---
title: "Managing & Restarting Services"
parent: "Setup"
nav_order: 6
---

# Managing & Restarting Services

Day-to-day operations once the stack is up: restarting individual services,
reloading `.env` changes, and updating images. Everything is `docker compose`
run from the repo root (`/srv/projects/ace-monorepo`).

---

## Service names

The control-plane services you'll restart most often:

| Service (compose) | Container | What it is |
|---|---|---|
| `auth` | `agentcert-auth` | Authentication backend (REST :3000, gRPC :3030) |
| `graphql` | `agentcert-graphql` | Core backend / GraphQL API (:8081) — installs agents, RBAC, infra |
| `web` | `agentcert-web` | AgentCert UI (nginx, :2001 → http://localhost:2001) |
| `app` | `certifier_app` | Certifier service (:8000 → http://localhost:8000/docs) |

Supporting services (you rarely restart these): `mongo`, `langfuse-web`,
`langfuse-worker`, `postgres`, `clickhouse`, `redis`, `minio`, `litellm`,
`cluster-init`.

List everything live: `docker compose ps`

---

## Restart just the control-plane services

```bash
# Reuse the existing containers (fast). Does NOT reload .env — see the warning below.
docker compose restart auth graphql web app
```

```bash
# Recreate the containers so edited .env / image changes take effect.
docker compose up -d --force-recreate auth graphql web app
```

One service only:

```bash
docker compose up -d --force-recreate graphql
```

---

## ⚠️ `restart` does NOT reload `.env`

Environment variables are read **only when a container is created**. So:

- `docker compose restart <svc>` → reuses the existing container → **keeps the old env**.
- `docker compose up -d --force-recreate <svc>` → creates a fresh container → **reads the current `.env`**.

**After editing `.env` (ports, model alias, callback host, Mongo address, …),
always use `up -d --force-recreate`** — a plain `restart` will silently run with
the stale values.

---

## Does it pull / rebuild images every time?

**No.** Neither `restart` nor `up -d --force-recreate` pulls or rebuilds. There
is no `pull_policy: always` in the compose file, so the **local image is reused
as-is**. `--force-recreate` only rebuilds the *container*, not the *image*.

You only get a new image when you ask for one:

```bash
# (A) Update PUBLISHED images (agentcert/* on Docker Hub), then restart:
docker compose pull auth graphql web
docker compose up -d auth graphql web

#     …or in one step:
docker compose up -d --pull always auth graphql web
```

```bash
# (B) Rebuild from LOCAL source (these services have a build: section), then restart:
docker compose build graphql
docker compose up -d graphql

#     …or in one step:
docker compose up -d --build graphql
```

> First-ever `docker compose up` (image missing locally): services with a
> `build:` section are **built** from source; image-only services (mongo,
> litellm, postgres, …) are **pulled**. After that, the image is cached and
> reused until you explicitly `pull` or `build`.

---

## Common one-liners

```bash
docker compose ps                                # states of all services
docker compose ps auth graphql web app           # just the control plane
docker compose logs -f graphql                   # tail one service's logs
docker compose logs -f auth graphql web app      # tail several at once
docker compose stop graphql                       # stop one service
docker compose down                               # stop & remove all containers (keeps volumes/data)
docker compose down -v                            # …and WIPE data (Mongo, Langfuse, etc.) — destructive
```

---

## After a `.env` change — quick reference

| You changed… | Affected services | Command |
|---|---|---|
| `AZURE_OPENAI_*`, model alias | `graphql` (injects agent config) | `docker compose up -d --force-recreate graphql` |
| Mongo address / port | `auth`, `graphql`, `app` | `docker compose up -d --force-recreate auth graphql app` |
| Callback host / `SERVER_ADDR` / origins | `graphql` | `docker compose up -d --force-recreate graphql` |
| Langfuse / LiteLLM host | `app`, `litellm` | `docker compose up -d --force-recreate app litellm` |
| Any control-plane env, unsure | all four | `docker compose up -d --force-recreate auth graphql web app` |

> Re-running `scripts/setup.sh` also applies `.env` changes and recreates the
> affected services for you, including re-detecting the kind gateway.
