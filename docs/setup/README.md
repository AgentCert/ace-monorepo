# ACE — One-Command Setup Guide

This folder is the **complete, user-friendly guide** to bringing up the ACE
(Agent Certification Engine) platform with a single command:

```bash
docker compose up -d
```

It explains every configuration knob, the three ways to connect Kubernetes, how
to change ports when some are already busy on your machine, and the full
post-startup flow: **create infrastructure → enable chaos → apply the infra
YAML → create and run an experiment → read the results**.

> **New here? Read in this order:**
> 1. [Prerequisites](#prerequisites) (below)
> 2. [Configuration & changing ports](./configuration.md)
> 3. Pick your route → [1](./route-1-existing-cluster.md) · [2](./route-2-fresh-kind.md) · [3](./route-3-cloud-aks.md)
> 4. [Running your first experiment](./running-an-experiment.md)

---

## What comes up

A single `docker compose up -d` starts the whole platform:

| Component | What it is | Default URL |
|---|---|---|
| **Web UI** | AgentCert console (nginx) | http://localhost:2001 |
| **GraphQL** | Control plane that drives chaos experiments | http://localhost:8081 |
| **Auth** | Authentication service (REST + gRPC) | :3000 / :3030 |
| **MongoDB** | Persistence (replica set `rs0`) | :27017 |
| **LiteLLM** | LLM gateway in front of Azure OpenAI | http://localhost:14000 |
| **Langfuse** | Trace storage for agent runs | http://localhost:4000 |
| **Certifier** | Builds certification reports from traces | http://localhost:8000/docs |
| **cluster-init** | One-shot: ensures a working Kubernetes cluster | — |

Login to the Web UI with `ADMIN_USERNAME` / `ADMIN_PASSWORD` from `.env`
(defaults **`admin` / `litmus`**).

---

## The three routes (how Kubernetes is sourced)

The platform drives chaos experiments on a Kubernetes cluster. The one-shot
`cluster-init` service decides where that cluster comes from, based on the
single `.env` switch **`CLUSTER_MODE`**:

| Route | Your situation | `CLUSTER_MODE` | Guide |
|---|---|---|---|
| **1** | You already have a **local cluster** running (kind / minikube / k3s) and want to reuse it | `local` (or `auto`) | [route-1-existing-cluster.md](./route-1-existing-cluster.md) |
| **2** | **Fresh machine** — you have nothing yet; let compose create a kind cluster for you | `fresh` (or `auto`) | [route-2-fresh-kind.md](./route-2-fresh-kind.md) |
| **3** | Your Kubernetes is in the **cloud** (AKS/EKS/GKE) and your VM is already logged in (e.g. `az aks get-credentials`) | `cloud` | [route-3-cloud-aks.md](./route-3-cloud-aks.md) |

`CLUSTER_MODE=auto` (the default) figures it out for you: if your kubeconfig
already works it reuses that cluster (route 1 or 3); otherwise it creates a kind
cluster (route 2).

---

## Prerequisites

You only need **Docker** and the **docker compose** plugin. No host install of
Go, Node, kubectl, or kind is required — the stack builds its own images and
`cluster-init` provisions kind for you when needed.

| Tool | Check | Install (Ubuntu) |
|---|---|---|
| Docker 28+ | `docker --version` | `sudo apt-get install docker.io` |
| Compose plugin v2.20+ | `docker compose version` | bundled with recent Docker |
| Your user in the `docker` group | `groups \| grep docker` | `sudo usermod -aG docker "$USER"` (re-login) |

Get the code (with submodules), then run the setup wizard:

```bash
git clone --recurse-submodules <repo-url> ace-monorepo
cd ace-monorepo
./scripts/setup.sh          # creates .env, asks only what matters (Azure OpenAI)
```

The wizard defaults everything except the **Azure OpenAI** credentials (the one
thing truly required for the agent's LLM calls). Prefer editing by hand?
`cp .env.example .env` and fill just the `AZURE_OPENAI_*` block — everything else
has a working default. See **[configuration.md](./configuration.md)** for the
full reference and for changing ports.

---

## First-run timing

The very first `docker compose up -d` **builds images** (Go control plane + the
web UI's Node build) and may take **5–15 minutes**. Subsequent runs reuse the
cached images and start in seconds. Watch progress with:

```bash
docker compose ps
docker compose logs -f graphql
```

---

## Day-to-day commands

```bash
docker compose up -d            # start / apply changes
docker compose up -d --build    # rebuild after code changes
docker compose ps               # status + health
docker compose logs -f <svc>    # tail one service (graphql, auth, web, ...)
docker compose restart <svc>    # restart one service
docker compose down             # stop everything (data volumes kept)
docker compose down -v          # stop + WIPE all data volumes
```

> The kind cluster created by `cluster-init` lives **outside** compose and is
> **not** removed by `docker compose down`. Delete it explicitly with
> `kind delete cluster --name agentcert`.

---

## Where to go next

- **[configuration.md](./configuration.md)** — every `.env` switch, the
  `local`/`external` toggles, and a step-by-step for **changing busy ports**.
- **[route-1-existing-cluster.md](./route-1-existing-cluster.md)** — reuse a cluster you already run.
- **[route-2-fresh-kind.md](./route-2-fresh-kind.md)** — fresh machine, compose makes the cluster.
- **[route-3-cloud-aks.md](./route-3-cloud-aks.md)** — point at a cloud (AKS/EKS/GKE) cluster.
- **[running-an-experiment.md](./running-an-experiment.md)** — the full UI flow from login to a certified experiment.
