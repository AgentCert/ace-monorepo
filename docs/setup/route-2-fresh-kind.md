---
title: "Route 2 · Fresh VM + kind"
parent: "Setup"
nav_order: 3
---

# Route 2 — Fresh VM Setup (kind cluster)

<div class="callout callout-success">
<span class="callout-title">Use this route when…</span>
You have a clean VM with no existing Kubernetes cluster. <code>scripts/setup.sh --deploy</code>
creates a local <a href="https://kind.sigs.k8s.io">kind</a> cluster with the correct
port mappings, deploys all ACE services to it, and prints access URLs — one command
from zero to running platform.
</div>

---

## 1. Install Prerequisites

```bash
# Docker
sudo apt-get update && sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
newgrp docker   # or log out and back in

# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# kubectl
sudo snap install kubectl --classic
# or: curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
#     chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# helm (the default deploy method)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# git + python3 (setup's helpers use only the standard library)
sudo apt-get install -y git python3
```

Verify:

```bash
docker --version      # Docker 28+
kind version          # kind v0.20+
kubectl version --client
helm version --short  # v3.12+
```

`./scripts/setup.sh --deploy` re-checks all of these (via `scripts/check-prerequisites.sh`) and prints
the exact fix for anything missing.

---

## 2. Clone the Repo

```bash
git clone --recurse-submodules https://github.com/AgentCert/ace-monorepo
cd ace-monorepo
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

This manual command is optional: `./scripts/setup.sh --deploy` detects and initializes
missing submodules before it builds the platform.

---

## 3. Run the Setup Wizard

```bash
./scripts/setup.sh --deploy
```

<div class="callout callout-warning">
<span class="callout-title">⚠ The <code>--deploy</code> flag is what makes this an install</span>
<code>./scripts/setup.sh</code> with no flags builds every image and <strong>exits</strong> —
no <code>.env</code>, no cluster, no questions. It ends with
<code>All images built successfully!</code> followed by
<code>Next: ./scripts/setup.sh --deploy</code>. That is a successful build, but nothing is deployed.
</div>

The wizard asks for your LLM credentials; press **Enter** at every other prompt to take the
stable defaults. The questions come in this order:

| # | Question | Prompt | Enter gives you |
|---|---|---|---|
| 0 | Personal rootless Docker | `Set up and use rootless Docker for this checkout? [y/N]:` | No (skip it) — or pass `--rootless-docker` |
| 1 | Setup style | `Choice [e/G]:` | **g** guided (section by section); `e` = answer everything up front, then unattended |
| 2 | Where ACE runs | `CLUSTER_MODE [auto]:` | **auto** — create or reuse a kind cluster on this machine |
| 3 | Build images | `Choice [p/l/A/n]:` | **a** — build **ALL** locally (the heaviest option, not `n`) |
| 4 | Experiment image sources | `[l/r, Enter=l]:` | **local** — skipped entirely when you chose `a` above |
| 5 | Image registry | `IMAGE_REGISTRY [...]:` | keep current (empty = Docker Hub, no login); `-` clears it |
| 6 | Azure OpenAI | `API key:` | skip — **all other Azure questions are skipped too when the key is empty** |
| 7–8 | Gemini / OpenRouter | `API key:` | skip |
| 9 | Ollama | `Set up Ollama? [Y/n]` | defaults to **Y when no other provider key was given** — that pulls a multi-GB model |
| 10 | Flash-agent model | `Flash-agent model alias [...]:` | the first configured alias, in order Ollama → Azure → Gemini → OpenRouter |
| 11 | Agent to benchmark | `Agent [flash-agent]:` | `flash-agent`; valid values are the directories under `agents/` |
| 12 | Corporate CA certificate | `Path to root CA cert file (.pem/.crt, Enter to skip):` | host system bundle |
| 13 | Deploy method | `Choice [k/H/n]:` | **h** — Helm (`k` = `kubectl apply`, `n` = skip deploying) |

In guided mode questions 3 and 13 are asked around the build; in express mode (`e`)
every question is asked first and the script then runs unattended.

With a deploy choice it then, unattended:

- Creates the kind cluster `agentcert-<ACE_INSTANCE_NAME>` with all required port mappings
- Builds and side-loads the hub bundle, then deploys the platform (Helm chart `deploy/helm/ace`,
  or the manifests in `deploy/k8s/`) including a platform-owned metrics-server
- Waits for the experiment images; **stops with an error** if any required image failed to build
- Registers the `ace-local` chaos infrastructure, installs its subscriber into `litmus` and waits
  until it is connected — no UI steps needed
- Seeds the demo experiments and prints the access URLs

Builds run `nproc / 2` at a time (min 1, max 6; override with `ACE_BUILD_PARALLELISM`),
without Docker's cache unless you pass `--allow-build-cache`. Per-image logs go to
`.tmp/build-logs/<n>.log` — **that directory is wiped at the start of every build**.

### Expected output

A successful run ends with:

```text
=======================================================
  ✓ ACE stack deployed via Helm
=======================================================
  Release       ace  (namespace: ace)
  AgentCert UI  http://localhost:2001          login: admin / litmus
  Langfuse      http://localhost:4002          login: admin@agentcert.local / agentcert-admin
  Certifier     http://localhost:18000/docs
  LiteLLM       http://localhost:14000
  MongoDB       localhost:27017

  status:   kubectl get pods -n ace
  upgrade:  helm upgrade --install ace deploy/helm/ace -n ace --create-namespace ...
  rollback: helm rollback ace -n ace
  teardown: helm uninstall ace -n ace
=======================================================
```

Things that mean it did **not** fully succeed:

| Ending | Meaning | Next step |
|---|---|---|
| `! Chaos infrastructure is NOT connected` inside the banner | Stack is up, experiments cannot run | Fix the warnings above it, then `./scripts/setup.sh --restart` |
| `! Selected image builds failed: <labels>` | Setup aborted before deploying | Read `.tmp/build-logs/<n>.log`, fix, re-run |
| `Skipped — run './scripts/setup.sh --restart' and choose k or h to deploy with these settings.` | You answered `n` at the deploy prompt | Re-run with `--restart` and pick `h` |
| `All images built successfully!` and nothing else | You forgot `--deploy` | `./scripts/setup.sh --deploy` |

Re-running `./scripts/setup.sh --deploy` (or `--restart` to reuse the saved answers) is idempotent.

#### If you chose Helm

The wizard generates `deploy/helm/ace/values-env.yaml` from your `.env` and runs, in effect:

```bash
helm upgrade --install ace deploy/helm/ace \
  -n ace --create-namespace \
  -f deploy/helm/ace/values-env.yaml \
  --set-string chartsHub.bundleImage=agentcert/ace-hub-bundle:local \
  --set chartsHub.bundleImagePullPolicy=Never
```

Always redeploy through `./scripts/setup.sh --restart` rather than raw `helm upgrade`: the hub
bundle must be rebuilt and side-loaded first, and the post-deploy steps (host-service wiring,
infrastructure registration, subscriber sync) only run from the script. Use `helm history ace -n ace`
and `helm rollback ace -n ace` for release management. See
[Managing services]({{ "/setup/managing-services.html" | relative_url }}) for more.

---

## 4. Verify

```bash
kubectl get pods -n ace           # all pods Running / Ready
kubectl get nodes                 # kind cluster node shows Ready
```

Expected output (all pods Running):

```
NAME                              READY   STATUS    RESTARTS   AGE
auth-xxxx                         1/1     Running   0          3m
certifier-xxxx                    1/1     Running   0          3m
clickhouse-xxxx                   1/1     Running   0          3m
graphql-xxxx                      1/1     Running   0          3m
langfuse-web-xxxx                 1/1     Running   0          3m
langfuse-worker-xxxx              1/1     Running   0          3m
litellm-xxxx                      1/1     Running   0          3m
minio-xxxx                        1/1     Running   0          3m
mongodb-0                         1/1     Running   0          3m
postgres-xxxx                     1/1     Running   0          3m
redis-xxxx                        1/1     Running   0          3m
web-xxxx                          1/1     Running   0          3m
```

Quick connectivity check:

```bash
curl -s -o /dev/null -w "web      %{http_code}\n" http://localhost:2001/
curl -s -o /dev/null -w "langfuse %{http_code}\n" http://localhost:4002/
curl -s -o /dev/null -w "litellm  %{http_code}\n" http://localhost:14000/health
curl -s -o /dev/null -w "cert     %{http_code}\n" http://localhost:18000/docs
```

Open **[http://localhost:2001](http://localhost:2001)**, log in (`admin` / `litmus`).  
Langfuse UI: **[http://localhost:4002](http://localhost:4002)** (`admin@agentcert.local` / `agentcert-admin`).

---

## 5. Service Access Reference

Host ports are rendered into the kind config by `deploy/kind/render-kind-config.sh`,
which takes the template `deploy/kind/kind-agentcert.yaml` and substitutes each
`KIND_HOSTPORT_*` value from `.env` (output: `.tmp/kind-agentcert.rendered.yaml`).
The defaults below are what you get when `.env` does not override them:

| Service | Host port | `.env` key | NodePort | Notes |
|---|---|---|---|---|
| AgentCert UI | 2001 | `KIND_HOSTPORT_WEB` | 32001 | nginx serving the React app |
| GraphQL REST | 8081 | `KIND_HOSTPORT_GRAPHQL_REST` | 32081 | GraphQL + WebSocket |
| GraphQL gRPC | 8082 | `KIND_HOSTPORT_GRAPHQL_GRPC` | 32082 | — |
| Auth REST | **3005** | `KIND_HOSTPORT_AUTH_REST` | 32003 | the container still listens on 3000 |
| Auth gRPC | 3030 | `KIND_HOSTPORT_AUTH_GRPC` | 32030 | — |
| Certifier | **18000** | `KIND_HOSTPORT_CERTIFIER` | 32080 | Swagger at `/docs` |
| LiteLLM | 14000 | `KIND_HOSTPORT_LITELLM` | 31400 | — |
| Langfuse | **4002** | `KIND_HOSTPORT_LANGFUSE` | 32400 | 4000 is the host-process (non-kind) default |
| MongoDB | 27017 | `KIND_HOSTPORT_MONGO` | 32017 | replica set `rs0` |
| MinIO S3 | 19090 | `KIND_HOSTPORT_MINIO` | 32090 | internal S3 for Langfuse |
| Ingress | 8088 | `KIND_HOSTPORT_INGRESS` | 80 | — |
| Dex (OIDC) | 32000 | `KIND_HOSTPORT_DEX` | 32000 | — |
| Prometheus | 31090 | `KIND_HOSTPORT_PROMETHEUS` | 31090 | experiment observability |
| Grafana | 31687 | `KIND_HOSTPORT_GRAFANA` | 31687 | experiment observability |
| OTel Prom MCP | 31085 | `KIND_HOSTPORT_OTEL_PROM_MCP` | 31085 | agent tool endpoint |
| OTel K8s MCP | 31086 | `KIND_HOSTPORT_OTEL_K8S_MCP` | 31086 | agent tool endpoint |

> **Certifier runs on :18000** (not :8000) because port 8000 is often occupied
> on developer VMs. The container still listens on 8000 internally.

> **Auth is on :3005 and Langfuse on :4002** in the kind deployment. The
> `.env` values win over this table — on a shared host setup walks to the next
> free port and saves what it picked, and the final banner prints the real URLs.

---

## 6. RBAC for App Installs

App charts like sock-shop ship their own ClusterRole/Role objects. The latest infra
manifest bakes in the necessary `escalate` and `bind` verbs, so a freshly connected
infrastructure works without any manual grant.

<div class="callout callout-info">
<span class="callout-title">Fallback</span>
Only needed if your infrastructure was connected <em>before</em> the RBAC fix and
you see <code>clusterroles.rbac.authorization.k8s.io ... is forbidden</code>.
Grant it once, or simply re-connect the infrastructure to pick up the updated role:
</div>

```bash
kubectl create clusterrolebinding argo-chaos-admin \
  --clusterrole=cluster-admin --serviceaccount=litmus:argo-chaos
```

---

## 7. Next: Run an Experiment

Setup already connected the `ace-local` chaos infrastructure (`kubectl get pods -n litmus`).
Continue with **[running-an-experiment.md]({{ "/setup/running-an-experiment.html" | relative_url }})**
to create and run an experiment and view its certification report.

---

## Notes & Gotchas

<div class="callout callout-warning">
<span class="callout-title">⚠ Don't accidentally lose your cluster</span>
The kind cluster is a Docker container named <code>agentcert-&lt;ACE_INSTANCE_NAME&gt;-control-plane</code>. It
is <strong>not</strong> backed by an external volume — deleting the container (e.g. via
<code>docker system prune</code>) permanently loses cluster state, including MongoDB. Re-run
<code>./scripts/setup.sh --restart</code> to recreate and redeploy everything.
</div>

- **Ports** — every host port is chosen by `setup.sh` (free-port walk) and saved in `.env` as `KIND_HOSTPORT_*`; the table above shows the defaults. See [configuration.md]({{ "/setup/configuration.html" | relative_url }}) to change them.
- **Idempotent setup** — re-running `./scripts/setup.sh --deploy` is safe: it detects existing port mappings, skips cluster recreation, updates the `ace-env` Secret, re-applies all manifests and reuses the registered chaos infrastructure.
- **UFW** — if your host firewall is active, in-cluster pods need ports open from the kind subnet. See [running-an-experiment.md]({{ "/setup/running-an-experiment.html" | relative_url }}#networking-checklist-pods--host).
- **Submodule pointer issues** — if `agent-charts/` or `app-charts/` is empty, run `git submodule update --init --recursive` from the repo root.
