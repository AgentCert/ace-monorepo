# ITBench Post-Merge Setup Checklist

This document captures everything required to get a clean, working ACE+ITBench environment on any host **after** the `feature/itbench-scenarios` branch has been merged to `main`. It was written against the state of that branch as of 2026-08-04.

Read it in order. Steps in Section 1 must be done by a maintainer with repo write access **before** merge. Steps in Section 2 onwards apply to whoever is standing up a fresh host.

---

## 1. Pre-Merge: Pending Code Changes (Must Be Committed)

These changes exist as local edits on the branch but are **not yet committed**. Without them the images built from this branch are stale and certain experiment failures will recur.

### 1.1 Flash-Agent Multi-MCP Routing Fix

**File:** `agents/flash-agent/flash_agent.py`

**Problem:** `_execute_mcp_tool` iterated MCP clients in dict insertion order. The Kubernetes MCP server responds to unknown tools like `execute_query` with an HTTP 200 + JSON-RPC error `{"code":-32602,"message":"unknown tool"}` — not an exception — so the loop returned immediately and the Prometheus MCP server was never reached. All `execute_query` calls returned a 66-character error string instead of live Prometheus data.

**Fix summary:**
- `_discover_mcp_tools` already stamps each discovered tool with `tool["_mcp_url"]` (the URL of the MCP server that owns it).
- A `tool_owner` dict is built in `scan()` and `watch()` immediately after discovery: `{tool_name: client_for_that_url}`.
- `_execute_mcp_tool` takes an optional `tool_owner` kwarg. When provided, it routes directly to the correct client instead of iterating all of them.
- The fallback (iterate all) is kept for single-MCP deployments where `_mcp_url` metadata may be absent.

**Verify the fix is committed:**
```bash
grep -c "tool_owner" agents/flash-agent/flash_agent.py
# Must be ≥ 9
```

### 1.2 Litmus Helper Image Overrides Applied at Run Time

**Files:** `AgentCert/chaoscenter/graphql/server/pkg/chaos_experiment/ops/service.go` and `.../chaos_experiment_run/handler/handler.go`

**Problem:** `applyLitmusHelperImageOverrides` (previously unexported) was only called at *save time* (`processExperimentManifest`). Experiments already stored in MongoDB with JFrog registry URLs were submitted to Argo unchanged — the image pull failed mid-run.

**Fix summary:**
- Renamed to `ApplyLitmusHelperImageOverrides` (exported).
- Called at *run time* in both `RunChaosWorkFlow` and `RunCronExperiment`, immediately before the Argo workflow is submitted.
- Two new env vars read by the GraphQL server control behaviour (see Section 4).

**New env vars in the `ace-env` Kubernetes Secret** (set by `setup.sh` → `values-env.yaml`):

| Env Var | What it does | KinD / local value | JFrog value |
|---|---|---|---|
| `LITMUS_HELPER_IMAGES_REGISTRY_PREFIX` | Prefix prepended to all litmus helper image refs | `docker.io/` or empty | `infyartifactory.jfrog.io/docker-local/` |
| `LITMUS_HELPER_IMAGES_PULL_POLICY` | `imagePullPolicy` injected into all litmus helper templates | `IfNotPresent` (pre-loaded) or `Always` | `Always` |

If both vars are empty, the function is a no-op — images are left exactly as stored in MongoDB.

**Verify the fix is committed:**
```bash
grep -c "ApplyLitmusHelperImageOverrides" \
  AgentCert/chaoscenter/graphql/server/pkg/chaos_experiment_run/handler/handler.go
# Must be ≥ 2 (one for RunChaosWorkFlow, one for RunCronExperiment)
```

### 1.3 Flash-Agent Helm Chart: pullPolicy

**File:** `agent-charts/charts/flash-agent/values.yaml`

**Change:** Both `agent.containerImage.pullPolicy` and `sidecar.image.pullPolicy` changed from `Always` to `IfNotPresent`.

**Why this matters:** `Always` causes Kubernetes to pull from Docker Hub on every pod restart. Since the flash-agent FLASH methodology exits cleanly after 10 scan cycles and the Deployment's `restartPolicy: Always` immediately relaunches it, the pod restarts frequently — meaning `Always` pulls the Docker Hub image on every cycle, discarding any kind-loaded local fix.

`IfNotPresent` lets the kind-loaded image (with fixes applied) survive pod restarts.

**Important caveat:** `IfNotPresent` only works correctly when the fixed image is already in the cluster's containerd store. See Section 3.2 for the kind-load step. Once the fixed images are published to Docker Hub, the policy can be reverted to `Always` if preferred.

---

## 2. Post-Merge: Images to Rebuild and Push to Docker Hub

After the pending commits above are merged to `main`, the following Docker images **must** be rebuilt from the updated source and pushed to Docker Hub. The old images at `latest` will not contain the fixes.

Whoever has Docker Hub push access to the `agentcert` org runs:

```bash
# From the repo root
./scripts/build-and-push.sh
```

This builds and pushes all 5 images. If you only want the affected ones:

```bash
# Flash-agent (routing fix)
cd agents/flash-agent
make build && make push

# GraphQL server (run-time image overrides + SA discovery)
cd AgentCert/chaoscenter/graphql
docker build -f server/Dockerfile -t agentcert/agentcert-graphql:latest .
docker push agentcert/agentcert-graphql:latest

# Install-agent wrapper (progress logging improvement)
cd agent-charts
docker build -f install-agent/Dockerfile -t agentcert/agentcert-install-agent:latest .
docker push agentcert/agentcert-install-agent:latest
```

Until these pushes happen, any fresh host pulling from Docker Hub will get the old code.

---

## 3. Fresh Host Setup

### 3.1 Standard Setup (no changes to the documented flow)

```bash
git clone --recurse-submodules https://github.com/AgentCert/ace-monorepo
cd ace-monorepo
cp .env.example .env
# Edit .env with your credentials
./scripts/setup.sh          # interactive first run
```

The `setup.sh` wizard will:
- Auto-assign `ACE_INSTANCE_NAME` (from your Unix username) — this scopes all container names, volumes, Compose projects, and KinD cluster names to your checkout.
- Auto-assign `OLLAMA_PORT` (derived from your UID) — avoids collision with system Ollama on :11434.
- Prompt for image sources (`dockerhub` / `jfrog` / `local`) per workflow step image.
- Prompt for `LITMUS_HELPER_IMAGES_REGISTRY_PREFIX` and `LITMUS_HELPER_IMAGES_PULL_POLICY` — see Section 1.2 for the right values per environment.

### 3.2 KinD Cluster: Load Locally Built Images

If you build any image locally (e.g. because Docker Hub does not yet have the fixes, or you are iterating on a change), you must load it into the kind node's containerd store **before** running experiments — otherwise the pod will use whatever Docker Hub has cached.

```bash
# Build locally
cd agents/flash-agent && make build && cd ../..

# Load into the kind node (replace ACE_INSTANCE_NAME with yours, e.g. "alfred02-trn")
kind load docker-image agentcert/agentcert-flash-agent:latest \
  --name agentcert-${ACE_INSTANCE_NAME}

# Same for graphql if you rebuilt it
kind load docker-image agentcert/agentcert-graphql:latest \
  --name agentcert-${ACE_INSTANCE_NAME}

kind load docker-image agentcert/agentcert-install-agent:latest \
  --name agentcert-${ACE_INSTANCE_NAME}
```

After loading, restart the running pods so they pick up the new image:

```bash
kubectl rollout restart deployment/flash-agent -n sock-shop
# If graphql was reloaded and the graphql server pod needs updating:
kubectl rollout restart deployment/chaos-graphql-server -n ace
```

**Verify the correct image is running:**
```bash
# flash-agent should show local sha, not a Docker Hub digest
kubectl get pod -n sock-shop -l app=flash-agent \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'

# Confirm the routing fix is in the running container
kubectl exec -n sock-shop \
  $(kubectl get pod -n sock-shop -l app=flash-agent -o jsonpath='{.items[0].metadata.name}') \
  -c agent -- grep -c "tool_owner" /app/flash_agent.py
# Must be ≥ 9
```

### 3.3 Verifying the Multi-MCP Fix Is Working

Once the flash-agent pod is running, tail its logs during a scan:

```bash
kubectl logs -n sock-shop -l app=flash-agent -c agent -f | grep -E "Tool call:|Tool result:"
```

Expected healthy output — `execute_query` results should be **hundreds to thousands** of characters, not 66:

```
Tool call: execute_query({'query': 'sum by (pod) (rate(container_cpu_usage_seconds_total{...}[2m]))'})
Tool result: 2086 chars
Tool call: execute_query({'query': 'sum by (pod) (container_memory_working_set_bytes{...})'})
Tool result: 1945 chars
```

A result of exactly 66 chars for `execute_query` means the K8s MCP is intercepting the call (routing fix not applied or wrong image is running).

### 3.4 KinD Host-Specific: Eviction Threshold Override

The `kind-agentcert.yaml` (and `compose/kind/kind-fresh.yaml`) contains kubelet eviction overrides:

```yaml
kubeadmConfigPatches:
- |
  kind: KubeletConfiguration
  evictionHard:
    nodefs.available: "5Gi"
    imagefs.available: "5Gi"
```

These replace the default percentage-based thresholds (`10%` / `15%`). On hosts where Docker's data-root sits on a large volume that appears nearly full by percentage (e.g. `/Innovation/docker`), the default thresholds fire and evict all pods immediately. The absolute floor (`5Gi`) prevents spurious eviction as long as at least 5 GB remain.

**Do not remove these overrides** on any host where the Docker data-root partition is >85% full by percentage.

---

## 4. Known Issues (No Fix Yet)

### 4.1 Flash-Agent Self-Restart False Positive

**Symptom:** The flash-agent Deployment shows 19+ pod restarts. The agent reports itself as CRITICAL for having too many container restarts. The certification pipeline may interpret this as an infrastructure fault rather than an intentional agent behavior.

**Root cause:** The FLASH methodology runs up to 10 scan cycles (`MAX_ITERATIONS=10`) then exits cleanly with code 0. The Deployment's `restartPolicy: Always` immediately relaunches the pod. Each 10-cycle run takes a few minutes, so after an hour the restart count climbs to 10+.

**Workaround:** Manually exclude the `flash-agent` pod from restart-count analysis when reviewing raw certification metrics. No code fix has been implemented.

**Proper fix (not yet done):** Change the agent to run as a Kubernetes `Job` (run-once, no automatic restart) or a `CronJob` (scheduled recurring scan), not a `Deployment`. This requires changes to the `install-agent` Helm chart and the harness.

### 4.2 Docker Hub Push Access Required for Durable Image Fixes

The `agentcert` Docker Hub org requires push credentials that are not widely distributed. If you have a code fix that needs to reach all hosts, you must coordinate with someone who has those credentials to rebuild and push the affected images. Until then, any host must build locally and use the kind-load workflow (Section 3.2).

---

## 5. Quick Reference: Which Change Lives Where

| Change | File location | Committed? | Image to rebuild |
|---|---|---|---|
| Multi-MCP routing fix | `agents/flash-agent/flash_agent.py` | Pending | `agentcert/agentcert-flash-agent` |
| Litmus image overrides at run time | `AgentCert/...graphql/server/pkg/chaos_experiment_run/handler/handler.go` | Pending (in submodule) | `agentcert/agentcert-graphql` |
| Litmus image overrides at save time | `AgentCert/...graphql/server/pkg/chaos_experiment/ops/service.go` | Pending (in submodule) | `agentcert/agentcert-graphql` |
| New env vars for image overrides | `AgentCert/...graphql/server/utils/variables.go` | Pending (in submodule) | `agentcert/agentcert-graphql` |
| Prometheus MCP image ref | `AgentCert/...graphql/server/utils/variables.go` — default changed from `agentcert/prometheus-mcp-server:latest` to `ghcr.io/pab1it0/prometheus-mcp-server:latest` | Pending (in submodule) | `agentcert/agentcert-graphql` |
| install-agent progress logging | `agent-charts/install-agent/main.go` | Pending (in submodule) | `agentcert/agentcert-install-agent` |
| flash-agent Helm chart pullPolicy | `agent-charts/charts/flash-agent/values.yaml` | Pending (in submodule) | none (Helm chart, not Docker image) |
