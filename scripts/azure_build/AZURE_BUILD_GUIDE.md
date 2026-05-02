# AgentCert Azure Build & Deploy Guide

## Overview

The `azure_build/` scripts form a two-phase pipeline:

1. **Build phase** (`build-all.sh`) — clones repos, builds Docker images, pushes to Docker Hub, updates `.env` with the new image tags
2. **Start phase** (`start-agentcert.sh`) — reads `.env` for all config and image tags, then starts Auth + GraphQL + Frontend using those images

No hardcoded paths or secrets in any script — everything comes from your `.env` and `build-paths.env`.

---

## Prerequisites (one-time setup on the Azure VM / build machine)

| Tool | Install command |
|------|----------------|
| Docker | `sudo apt-get install docker.io` |
| Go 1.21+ | `sudo apt-get install golang-go` |
| Node.js + yarn | `sudo apt-get install nodejs npm && npm install -g yarn` |
| kubectl | `sudo snap install kubectl --classic` |
| git | `sudo apt-get install git` |

---

## File: `build-paths.env`

Create a local copy on the build machine (or edit the one in `azure_build/`):

```env
AGENTCERT_ROOT=/tmp/agentcert-build/AgentCert
APP_CHARTS_ROOT=/tmp/agentcert-build/app-charts
AGENT_CHARTS_ROOT=/tmp/agentcert-build/agent-charts
FLASH_AGENT_ROOT=/tmp/agentcert-build/flash-agent

AGENTCERT_GIT_URL=https://github.com/AgentCert/AgentCert.git
APP_CHARTS_GIT_URL=https://github.com/AgentCert/app-charts.git
AGENT_CHARTS_GIT_URL=https://github.com/AgentCert/agent-charts.git
FLASH_AGENT_GIT_URL=https://github.com/AgentCert/flash-agent.git
CHAOS_CHARTS_GIT_URL=https://github.com/AgentCert/chaos-charts.git

GIT_BRANCH=main
```

> The `/tmp/agentcert-build/` paths require no special permissions and are writable by any user.

---

## File: `.env`

The **single source of truth** for secrets and image tags. Located at  
`AgentCert/local-custom/config/.env`.

Key variables consumed by the build+start pipeline:

| Variable | Set by | Read by |
|----------|--------|---------|
| `DOCKERHUB_USERNAME` | You (once) | all build scripts |
| `DOCKERHUB_TOKEN` | You (once) | all build scripts |
| `INSTALL_APPLICATION_IMAGE` | `build-and-deploy-app-chart.sh` after push | `start-agentcert.sh` → GraphQL server env |
| `INSTALL_AGENT_IMAGE` | `build-install-agent.sh` after push | `start-agentcert.sh` → GraphQL server env |
| `FLASH_AGENT_IMAGE` | `build-flash-agent.sh` after push | `start-agentcert.sh` → GraphQL server env |
| `AGENT_SIDECAR_IMAGE` | `build-agent-sidecar.sh` after push | `start-agentcert.sh` → GraphQL server env |
| `LITELLM_PROXY_IMAGE` | `build-litellm.sh` after deploy | `start-agentcert.sh` |
| `AZURE_OPENAI_KEY` / `ENDPOINT` / etc. | You | `start-agentcert.sh`, `build-litellm.sh` |
| `LANGFUSE_*` | You | `start-agentcert.sh`, `build-litellm.sh` |
| `DB_SERVER` | You | `start-agentcert.sh` → GraphQL server |
| `MONGODB_USERNAME/PASSWORD` | You | `start-agentcert.sh` → Auth server |

---

## Phase 1: Build images and push to Docker Hub

```bash
bash /path/to/azure_build/build-all.sh \
  --git \
  --llm 1 \
  --env-file /path/to/local-custom/config/.env \
  --paths-file /path/to/azure_build/build-paths.env
```

### What `build-all.sh` does

| Step | Script | What happens |
|------|--------|--------------|
| 1 | `build-and-deploy-app-chart.sh` | Builds `agentcert/agentcert-install-app:ci-<timestamp>`, pushes to Docker Hub, writes new tag to `.env` as `INSTALL_APPLICATION_IMAGE` |
| 2 | `build-litellm.sh` | Records public LiteLLM image + profile in `.env` only — **no docker build, no kubectl** — writes `LITELLM_PROXY_IMAGE`, `LITELLM_PROFILE`, `LITELLM_MASTER_KEY` |
| 3 | `build-install-agent.sh` | Builds `agentcert/agentcert-install-agent:ci-<timestamp>`, pushes to Docker Hub, updates `INSTALL_AGENT_IMAGE` in `.env` |
| 4 | `build-agent-sidecar.sh` | Builds `agentcert/agent-sidecar:ci-<timestamp>`, pushes to Docker Hub, updates `AGENT_SIDECAR_IMAGE` in `.env` |
| 5 | `build-flash-agent.sh` | Builds `agentcert/agentcert-flash-agent:ci-<timestamp>`, pushes to Docker Hub, updates `FLASH_AGENT_IMAGE` in `.env` |

After this phase, `.env` contains the freshly-pushed image tags.

> **Note:** `build-install-agent.sh` uses `agent-charts/install-agent/Dockerfile` with the repo root (`agent-charts/`) as the Docker build context, because the Dockerfile references `COPY install-agent/...` and `COPY charts/` from the repo root.

### Flags

| Flag | Description |
|------|-------------|
| `--git` | Clone repos if missing, or `git pull` if already cloned |
| `--llm 1` | `1`=azure, `2`=openai, `3`=all — sets `LITELLM_PROFILE` |
| `--env-file` | Path to `.env` (required) |
| `--paths-file` | Path to `build-paths.env` (required) |

---

## Architecture: What runs where

| Component | Where it runs | Image source |
|-----------|--------------|-------------|
| MongoDB | Docker container (local) | `mongo:4.2` from Docker Hub |
| Auth service | `go run` (local process) | Source code in `AGENTCERT_ROOT` |
| GraphQL server | `go run` (local process) | Source code in `AGENTCERT_ROOT` |
| Frontend | `yarn dev` (local process) | Source code in `AGENTCERT_ROOT` |
| install-agent | Kubernetes Job (cluster) | `agentcert/agentcert-install-agent` from Docker Hub |
| install-app | Kubernetes Job (cluster) | `agentcert/agentcert-install-app` from Docker Hub |
| flash-agent | Kubernetes Pod (cluster) | `agentcert/agentcert-flash-agent` from Docker Hub |
| agent-sidecar | Kubernetes sidecar (cluster) | `agentcert/agent-sidecar` from Docker Hub |
| LiteLLM proxy | Kubernetes Deployment (cluster) | `docker.io/litellm/litellm:v1.82.0-stable` (public) |

The GraphQL server receives the Docker Hub image tags via env vars (exported from `.env` by `start-agentcert.sh`) and injects them into Kubernetes pod specs when experiments run. Kubernetes pulls the images directly from Docker Hub — no `kubectl apply` needed after a build.

---

## Phase 2: Start AgentCert services

After the build phase (or on any subsequent restart), run:

```bash
bash /path/to/azure_build/start-agentcert.sh \
  --env-file /path/to/local-custom/config/.env \
  --paths-file /path/to/azure_build/build-paths.env
```

### What `start-agentcert.sh` does

1. Loads `AGENTCERT_ROOT` from `build-paths.env`  — uses it to find `chaoscenter/authentication/api`, `chaoscenter/graphql/server`, `chaoscenter/web`
2. Reads **all** image tags, secrets, and endpoints from `.env` via `env_val()`
3. Checks MongoDB — starts a container if not running
4. Starts **Auth service** (`go run`) on port 3030 / 3000
5. Builds + starts **GraphQL server** binary on port 8080 — exports image tag env vars so the server uses the just-pushed Docker Hub images when launching experiment pods
6. Starts **Frontend** (`yarn dev`) on port 2001

### How new images reach the cluster

The GraphQL server reads image tags **at startup** from its environment variables.  
`start-agentcert.sh` exports those env vars from `.env` (which was just updated by the build step).  
When the next chaos experiment runs, the GraphQL server creates K8s jobs using those fresh tags — Kubernetes pulls the images from Docker Hub automatically (`IfNotPresent` / `Always`).  
**No `kubectl apply` needed** — restarting the GraphQL server with updated env vars is the sync.

The only exception is **LiteLLM** — it is a long-running AKS deployment; `build-litellm.sh` handles its own `kubectl rollout restart`.

### Options

| Flag | Description |
|------|-------------|
| `--skip-mongo` | Skip MongoDB check (if you manage MongoDB separately) |
| `--skip-frontend` | Skip starting the web UI |

---

## Running from Windows (WSL)

**Build:**
```powershell
wsl -d Ubuntu -- bash -c "bash /mnt/d/Studies/AgentCert/azure_build/build-all.sh --git --llm 1 --env-file /mnt/d/Studies/AgentCert/local-custom/config/.env --paths-file /mnt/d/Studies/AgentCert/azure_build/build-paths.env 2>&1"
```

**Start:**
```powershell
wsl -d Ubuntu -- bash -c "bash /mnt/d/Studies/AgentCert/azure_build/start-agentcert.sh --env-file /mnt/d/Studies/AgentCert/local-custom/config/.env --paths-file /mnt/d/Studies/AgentCert/azure_build/build-paths.env 2>&1"
```

> Always wrap WSL commands in `bash -c "..."` to prevent PowerShell from intercepting redirects like `2>/dev/null`.

---

## Running on a remote Linux machine (no WSL)

**Build:**
```bash
bash ~/azure_build/build-all.sh --git --llm 1 \
  --env-file ~/config/.env \
  --paths-file ~/azure_build/build-paths.env
```

**Start:**
```bash
bash ~/azure_build/start-agentcert.sh \
  --env-file ~/config/.env \
  --paths-file ~/azure_build/build-paths.env
```

No WSL wrapper needed — the scripts run natively on Linux.

---

## Stopping services

```bash
bash /path/to/AgentCert/stop-agentcert.sh
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `No such file or directory` on shebang | CRLF line endings — run: `sed -i 's/\r//' azure_build/*.sh` |
| `Permission denied` on git clone | Paths file still has `/home/user/` — use `/tmp/agentcert-build/` paths |
| `AGENTCERT_ROOT not found` | Run `build-all.sh --git` first, or check `build-paths.env` paths |
| Auth/GraphQL won't start | Check `.auth.log` / `.graphql.log` in `AGENTCERT_ROOT` |
| Images not updated in cluster | Ensure `start-agentcert.sh` was re-run after `build-all.sh` so GraphQL server picks up new tags |
| Docker Hub push fails | Check `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` in `.env` — no spaces, no trailing commas |
| `DOCKER_BUILDKIT` deprecation warning | Expected — all build scripts use `DOCKER_BUILDKIT=0` (BuildKit not available). The warning is cosmetic only |
| `docker rmi` deleting layers | Normal housekeeping — only removes local image tags. Docker Hub images are **never** affected by local `docker rmi` or `docker image prune` |
| `Total reclaimed space: 0B` after prune | Layers are shared with other local images (e.g. `python:3.12-slim`), so Docker untags but cannot delete the blobs. This is expected |
