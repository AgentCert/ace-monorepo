# ACE — Innovation Log

Consolidated record of every feature, enhancement, and improvement considered or implemented across ACE development sessions. Grouped by area; each item notes its current status.

---

## 1. Agent Evaluation & Certification

### 1.1 Statistical Certification Framework (N=30)
**Status: Implemented**
Multi-run statistical evaluation (N=30) over a distribution of LLM agent runs rather than pass/fail on a single run. Phases 0–3 yield a 12-section certification report with mean/median/p95/stddev, success rates, and narrative synthesis.

### 1.2 Hypothesis Testing Framework (Phase E, n≥30)
**Status: Implemented**
Nine statistical tests (H01–H09) applied when n≥30:
- H01: Bootstrap BCa CI + IQM
- H02: Wilson CI safety floor for success rates
- H03: Kruskal-Wallis + Mann-Whitney U + Vargha-Delaney A12
- H04: Fisher's Exact for success-rate uniformity
- H05: Levene's + Coefficient of Variation for variance stability
- H06: Wilcoxon one-sample test for SLA compliance
- H07: Exact Binomial for SLA breach rate estimation
- H08: CVaR tail-risk analysis
- H09: CUSUM/EWMA drift detection

### 1.3 LLM Council for Narrative Synthesis (Phase 2)
**Status: Implemented**
k independent LLM judges each synthesize qualitative narratives; a meta-judge reconciles disagreements. Reduces single-model bias in Phase 2 aggregation. Prompts live in `aggregator/prompt/prompt.yml`.

### 1.4 CISO Scenario Support
**Status: Implemented**
- `ciso_metrics_adapter.py` translates ITBench CISO evaluation output (`pass: bool`, sub-checks) into the standard per-run metrics shape.
- CISO/FinOps aggregation functions added to `aggregator/scripts/numeric_aggregation.py`.
- `--include-ciso-finops` flag on Phase 2+3 CLI (default: SRE-only scope).
- `ciso_generate_policy` and `ciso_evidence_available` stored as individual quantitative fields per run for richer per-run scoring.
- CISO evidence packaging (`package_evidence.py`): scans ciso-agent workspace for `*.yaml` policies, stages them as `agent_output.data` for ITBench `make evaluate`.

### 1.5 OpenAI-Compatible Provider in Certifier LLM Judges
**Status: Implemented**
All certifier LLM judges accept `"provider": "openai_compatible"` in `configs/configs.json`, pointing at a local Ollama or LiteLLM instance — no Azure credentials required for full-pipeline dev and open-weight model research.

### 1.6 Certifier `get_clients` Resilience
**Status: Implemented**
A misconfigured or unused model entry in `configs.json` now logs a warning and is skipped rather than crashing client construction for every other model.

### 1.7 Complete PDF Renderer Block Coverage
**Status: Implemented**
Six previously missing block types were added to `cert_reporter`'s dispatch table: `scope_stats`, `notice`, `part_banner`, `interpretation_scale`, `category_panel`, `enumerated_item`. Previously Limitations, Recommendations, Part banners, and per-category narrative panels were silently dropped from every PDF.

### 1.8 CISO-Aware Phase 3 Narrative Builders
**Status: Implemented**
`key_findings_builder.py`, `qualitative_builder.py`, and `limitation_builder.py` now split on `_is_ciso()` so CISO categories (which lack `fault_detection_success_rate`) get appropriate narrative paths rather than crashing.

### 1.9 Two-Layer Capability Probe Evaluation System
**Status: Implemented**
`ace-bench.py` + `bench.yaml` support `capability_probes`. Layer 1 measures raw agent capability with unpatched prompts. Layer 2 fires only when a `failure_signal_regex` matches Layer 1 output, measuring whether a hint resolves the gap. Results include `probe_triggered` and `probe_layer` fields.

### 1.10 ChaosResult CR Verdict Patching
**Status: Implemented**
ITBench shell-script fault bundles (not Go litmus-go SDK) never write a `ChaosResult` CR themselves. `ace-bench.py` now patches the auto-created CR with `Pass`/`Fail` after the agent scan, giving the LitmusChaos portal a real verdict.

### 1.11 Per-Experiment Model Selection from ChaosCenter UI
**Status: Proposed**
Currently `FLASH_AGENT_MODEL` is a global `.env` setting. Enabling per-experiment model selection from the UI would require a GraphQL schema change, a new Go resolver, an `agent_registry` update, and a React form addition.

### 1.12 Aggregation-Failure Status Propagation to `certificate_experiments`
**Status: Implemented**
`pollAggregation()` and `startAggregation()` in `pkg/certification/service.go` previously wrote `AGGREGATION_FAILED` only onto the per-attempt `certificate_aggregation_workflows` sub-document, never onto the parent `certificate_experiments.status` field that `getCertificationStatus` and the ChaosCenter UI's `CertificationStatusPanel` actually read. A failed aggregation/certification run (e.g. a Phase 3 `KeyError` in `report_assembler.py`) left the UI stuck showing "Generating Certificate: running" indefinitely, with no way to tell from the UI that the pipeline had died. Fixed by:
- Added `ExperimentStatusAggregationFailed = "AGGREGATION_FAILED"` to `model.go`.
- Both failure paths in `service.go` (trigger failure in `startAggregation`, poll failure in `pollAggregation`) now also call `UpdateExperimentStatus(..., ExperimentStatusAggregationFailed)`.
- `ResetStatusIfCertified` (operator.go) extended to reset from `AGGREGATION_FAILED` back to `RUNS_IN_PROGRESS`, not just from `EXPERIMENT_CERTIFICATE_READY`, so a replacement run reopens the pipeline in the UI instead of leaving it stuck on the old failure.
- `CertificationStatusPanel.tsx` (frontend) adds an explicit `AGGREGATION_FAILED` case rendering the "Generating Certificate" stage as failed rather than falling through to the misleading default.
- Follow-up (not yet done): surface the actual `error.reason` string (e.g. the underlying Python traceback) through a new `errorMessage` field on `CertificationExperimentSummary`, which requires a GraphQL schema change + gqlgen regen.

---

## 2. Agent Implementations

### 2.1 ACE-Built CrewAI SRE Agent (`sre-agent-crewai`)
**Status: Implemented**
New ACE-native agent for the `itbench_sre` pipeline. Eight-step investigation protocol via CrewAI + MCP streamable-HTTP: list namespaces → pod health → events → NetworkPolicies → policy specs → Prometheus PromQL → delete faulty resources → verify recovery. Connects to live Kubernetes (:18081) and Prometheus (:31085) MCP servers; runs with `--network=host`.

### 2.2 A2A JSON-RPC 2.0 Bridge (`a2a-mcp-agent`)
**Status: Implemented**
Universal harness-side adapter for any A2A-compatible agent. Reads `scenario_data.json`, fetches an Agent Card from `/.well-known/agent-card.json`, sends `tasks/send`, polls `tasks/get` to terminal, packages result into `agent_data.tar`. Uses httpx + tenacity for retries.

### 2.3 FLASH Agent on Open-Weight Local GPU (Qwen2.5:7b-instruct)
**Status: Implemented**
Full end-to-end certification of an open-weight model on a local NVIDIA RTX A6000 (49 GB VRAM). Required `num_ctx: 16384` in LiteLLM config, LLM timeout raised to 600s, LiteLLM router timeout raised to match, and containerized instance-scoped Ollama.

### 2.4 `{{include: ...}}` Processing in Zero's Prompt System
**Status: Implemented**
Zero's `runner.py` now processes `{{include: filename}}` directives (recursive, depth-limited, relative to each file's directory). ITBench live-mode SRE prompts rely on this to assemble the full prompt from composable files.

### 2.5 Prometheus + Kubernetes MCP Servers for Live SRE Mode
**Status: Implemented**
Live-mode SRE agent now uses `kubernetes-mcp-server` and `prometheus-mcp-server` (both already shipped in `otel-demo`), replacing the ClickHouse MCP that was not present. Includes an idempotent port-forward script (`start_live_mcp_portforwards.sh`).

### 2.6 Agent Sidecar as Sole `experiment_run_id` Injection Point
**Status: Implemented**
`agent-sidecar/proxy.py` is now the single point that stamps every LLM call with `experiment_run_id`, regardless of agent. Removes the parallel duplicate injection that existed in flash-agent source.

### 2.7 `sre_react_online.md` Composite Entry-Point
**Status: Proposed (deferred — methodological implications for capability probes)**
`bench.yaml` for `sre-agent-qwen` should switch to `sre_react_online.md` to activate the include system and bring the patched `kubernetes.md` into the assembled prompt. Deliberately held to avoid invalidating ongoing capability probe baseline data.

---

## 3. Infrastructure & Deployment

### 3.1 Instance-Scoped Shared-Host Isolation
**Status: Implemented**
Every container name, KinD cluster name, Docker Compose project name, volume name, and Ollama port is suffixed with `ACE_INSTANCE_NAME` (defaults to the Unix username). Two checkouts on the same host never collide. Enforced in `docker-compose.yml`, `start-local-services.sh`, and `setup.sh`.

### 3.2 KinD Eviction Threshold Override (Absolute Byte Floors)
**Status: Implemented**
`kind-agentcert.yaml` sets `kubelet.eviction-hard: nodefs.available=5Gi,imagefs.available=5Gi` instead of default percentage thresholds. On the shared host (`/Innovation/docker`, large disk), percentage thresholds (~2.6% free) triggered spurious pod evictions even though tens of GB remained. Absolute floors prevent this.

### 3.3 `compose-up-guard.sh` Cross-Checkout Safety Wrapper
**Status: Implemented**
Drop-in `docker compose` wrapper that refuses to proceed if any container in the target stack already exists under a different checkout's working directory. Prevents the incident where a `docker compose up` silently deleted another user's running containers.

### 3.4 KinD Cluster Ownership Marker
**Status: Implemented**
`cluster-init/entrypoint.sh` marks every KinD cluster it creates with a Docker volume (`ace-kind-owner-<name>`) labelled with the checkout's host path. Before reusing or deleting a cluster it checks this marker — clusters owned by other checkouts are refused.

### 3.5 Dynamic KinD Port Selection
**Status: Implemented**
`pick_kind_hostport()` auto-detects if the default port is already bound and increments until a free one is found. Applies to all KinD-exposed ports.

### 3.6 Containerized Instance-Scoped Ollama
**Status: Implemented**
Each ACE checkout gets its own Ollama container on a collision-free, UID-derived host port (`OLLAMA_PORT`), isolated from the system Ollama on :11434 and from other checkouts. Model stored in a named volume scoped per instance.

### 3.7 `--local-build` Flag in `setup.sh`
**Status: Implemented**
Builds all monorepo-owned images locally, `kind load`s them into KinD, and sets `imagePullPolicy: IfNotPresent`. Avoids Docker Hub entirely for local dev.

### 3.8 `shut_down.sh` Safe Teardown Script
**Status: Implemented**
Reads `.env`, enumerates all resources owned by this checkout, and tears them down safely. Includes an ownership safeguard before acting.

### 3.9 Parallel Ollama Model Pull During Setup
**Status: Implemented**
Backgrounds the `ollama pull` right after the container is confirmed up, so KinD cluster creation and Helm deployment proceed in parallel with the multi-GB model download.

### 3.10 Persistent Image Build Policy (`PLATFORM_IMAGE_SOURCE`)
**Status: Implemented**
The `local` / `push` / `skip` choice is written to `.env` as `PLATFORM_IMAGE_SOURCE` and silently re-applied on `--restart` instead of re-prompting every time.

### 3.11 Chart Paths Auto-Updated Per-Host at Setup Time
**Status: Implemented**
`AGENT_CHARTS_ROOT` and `APP_CHARTS_ROOT` in `.env` are unconditionally rewritten on every `setup.sh` run to point at the actual checkout path, since these paths are machine-specific.

### 3.12 Inode-Based Container Ownership Check
**Status: Implemented**
`/home/alfred02.TRN` and `/Innovation/home/alfred02.TRN` are bind-mounts of the same directory; path-string comparison always failed. Switched to `stat` device+inode comparison, which is path-alias-proof.

### 3.13 Durable `argo-chaos` ClusterRoleBinding in Manifest Template
**Status: Implemented**
RBAC for `argo-chaos` to create namespaces cluster-wide is generated from the manifest template (`1a_argo_rbac.yaml`) so every new infrastructure registration automatically includes it, without manual post-registration patching.

### 3.14 Multi-Stage Self-Contained Web Dockerfile
**Status: Proposed**
Rewrite `agentcert/agentcert-web` Dockerfile with a Node.js build stage so the frontend is built inside Docker rather than requiring a pre-built `dist/` folder.

### 3.15 `make dev` Target
**Status: Proposed**
A `make dev` target that always runs `docker compose up --build`, giving the Compose path the same image-freshness guarantee as `setup.sh --local-build` without developers having to remember the flag.

### 3.16 Prompt for JWT/MongoDB Credentials at Setup
**Status: Proposed**
`JWT_SECRET` (currently defaulting to `litmus-portal@123`) and `MONGODB_USERNAME`/`MONGODB_PASSWORD` are never prompted by `setup.sh`. These are security risks in any non-dev deployment and should be prompted for or auto-generated.

### 3.17 Azure Content Safety & Blob Storage Prompted at Setup
**Status: Proposed**
`AZURE_CONTENT_SAFETY_ENDPOINT`/`AZURE_CONTENT_SAFETY_API_KEY` and `AZURE_STORAGE_CONNECTION_STRING` exist in `.env.example` but are never prompted. Could be included as optional steps.

### 3.18 HTTPS for the ChaosCenter Web UI
**Status: Proposed**
The web UI is currently HTTP-only end to end: `AgentCert/chaoscenter/web/nginx/nginx.conf` has a single `server` block listening on plain `8185` (`root /opt/chaos`, proxying `/auth/` and `/api/` to the auth and GraphQL services), fronted by a Kubernetes NodePort Service (host `2001` → NodePort `32001` → container `2001`, per `deploy/helm/ace/templates/web.yaml`) with no TLS termination anywhere in the chart. No cert-manager, TLS secret, or `ssl_certificate` directive exists in the repo today. Serving credentials (JWT bearer tokens, the `admin`/`litmus` login) over plaintext HTTP is a real exposure once ACE runs anywhere beyond localhost/loopback.

Enabling HTTPS would require:
- A TLS certificate + key, either self-signed (generated at `setup.sh` time, good enough for local/shared-host dev) or issued via `cert-manager` (better for anything longer-lived); mounted into the web pod as a Secret.
- A second `server` block (or a rewrite of the existing one) in `nginx.conf` listening on `443 ssl` with `ssl_certificate`/`ssl_certificate_key`, plus an HTTP→HTTPS redirect on the existing `8185`/plain listener.
- `deploy/helm/ace/templates/web.yaml` updated to expose the TLS port (NodePort or LoadBalancer) and mount the cert Secret into the container.
- `ALLOWED_ORIGINS` (auth service + GraphQL server CORS/WebSocket allowlist, see §4 in CLAUDE.md) extended to accept the `https://` origin, since it's currently only validated against `http://`-style entries.
- Frontend `OPENAI_BASE_URL`-style absolute-URL assumptions (if any) and Apollo/WebSocket client config in `AgentCert/chaoscenter/web/src` double-checked for hardcoded `ws://`/`http://` schemes that would need to become `wss://`/`https://` behind TLS.

---

## 4. LLM & Model Configuration

### 4.1 `num_ctx: 16384` for Ollama Models in LiteLLM
**Status: Implemented**
Ollama defaults every model to 2048-token context regardless of model capability. The flash-agent system prompt alone exceeds 2100 tokens before tool schemas. Fixed by adding `num_ctx: 16384` to the LiteLLM config for `qwen2.5-7b-instruct`.

### 4.2 LiteLLM Router Timeout Raised to 600s
**Status: Implemented**
`router_settings.timeout` must match `litellm_settings.request_timeout`. The router's own 120s ceiling was silently killing calls that had already survived the per-call timeout. Raised to 600s for open-weight model workloads.

### 4.3 Disable `enable_pre_call_checks` in LiteLLM
**Status: Implemented**
With `callbacks: ["langfuse"]`, LiteLLM's background health probes every ~5 minutes created spurious Langfuse traces — accumulating 15,000+ traces that polluted certification trace queries. Setting `enable_pre_call_checks: false` stops this.

### 4.4 `FLASH_AGENT_MODEL` Automatic Self-Healing in `setup.sh`
**Status: Implemented**
A validation block runs on every `setup.sh` invocation. If `FLASH_AGENT_MODEL` doesn't match any provider with real, non-placeholder credentials, it is auto-corrected to the first healthy alias (Ollama prioritized, then Azure, Gemini, OpenRouter) with a printed warning.

### 4.5 Configurable LLM Timeout and Retry Count in Flash Agent
**Status: Implemented**
`LLM_REQUEST_TIMEOUT` (default 120s) and `LLM_MAX_RETRIES` (default 2) added as env vars. Local CPU inference typically needs 600s+; these are now tunable without code changes.

### 4.6 Switch Prometheus MCP to Upstream `ghcr.io/pab1it0`
**Status: Implemented**
`agentcert/prometheus-mcp-server:latest` was a re-tag of `ghcr.io/pab1it0/prometheus-mcp-server:v1.6.0` with no Dockerfile. All references updated to point at the upstream directly to clarify ownership.

---

## 5. Image Management

### 5.1 Image Freshness Guarantee: `kind load` + Rollout Restart
**Status: Implemented**
When `--local-build` is chosen, after every local build the image is loaded into KinD via `kind load docker-image` and the relevant Deployment is rollout-restarted, forcing `IfNotPresent` to pick up the new layer rather than the stale cached one.

### 5.2 Global Image Registry Strip in `service.go`
**Status: Implemented**
A function similar to `ApplyInstallApplicationTemplateOverrides` strips a configurable `CHAOS_IMAGE_REGISTRY_STRIP` prefix from all images in both template containers and raw ChaosEngine YAML artifacts. Cleans up stored manifests that still carry JFrog URLs from older deployments.

### 5.3 `--local` Flag for `build-and-push.sh`
**Status: Proposed**
A `--local` flag that skips Docker Hub login/push and instead runs `kind load` into the local KinD cluster. Makes the build script dual-purpose for publishing and local dev.

---

## 6. Developer Experience

### 6.1 `scripts/run_certification.py` Standalone Pipeline Runner
**Status: Implemented**
Runs the full certifier pipeline (Phase 0+1+2+3+4) locally against a Langfuse trace without starting the FastAPI service. Supports `--no-pdf` and `--debug` flags.

### 6.2 `scripts/dump_langfuse_trace.py`
**Status: Implemented**
Fetches a Langfuse trace by experiment-id + run-id to offline `raw_trace.json` + `trace_meta.json` for local replay without live Langfuse access.

### 6.3 `scripts/render_certification_pdf.py`
**Status: Implemented**
Standalone re-render of an existing `certification.json` to PDF. Useful for iterating on the cert_reporter template without re-running the full pipeline.

### 6.4 `ace-bench.py` Orchestrator
**Status: Implemented**
Single-command benchmarking pipeline: reads `bench.yaml`, launches the agent harness, polls for completion, and optionally triggers the certifier. Covers `trace_based` and `itbench_sre` pipeline types.

### 6.5 CLAUDE.md Operational Gotchas Section
**Status: Implemented**
Four operational traps documented with exact workarounds: `--restart` skips Go rebuilds (add `--local-build`); JFrog 401 kills experiments mid-run; `KIND_CLUSTER_NAME` mismatch in `.env`; credential YAML files must not be committed.

### 6.6 Install App Console Progress Bar (`[step N/M]`)
**Status: Implemented**
`installChart()` in the Go GraphQL server now prefixes each phase with `[step N/M]` so the ChaosCenter UI console log shows progress rather than an undifferentiated stream.

### 6.7 `make setup-env` Target or Doc for Trial Env Files
**Status: Proposed**
`.tmp/flash-agent-trial/flash-agent.env` and `.tmp/sre-agent-qwen-trial/sre-agent-qwen.env` are gitignored but required before benchmarking. A `make setup-env` target or dedicated setup doc should create these files from `.env.example` templates.

### 6.8 "Answer All Questions Upfront" Option in `setup.sh`
**Status: Proposed**
Allow answering all implementation choices at the start of `setup.sh` rather than being prompted mid-run between long-running operations (KinD creation, Helm deploy). Pure UX improvement.

### 6.9 Simple Onboarding Procedure for Benchmarked Agents
**Status: Proposed**
Adding a new agent/app pairing to Chaos Studio currently has no guided path. `AppsHub`/`AgentHub` are read-only catalog pages with no "Create Experiment" CTA — users must hand-author the `install-application`/`install-agent` Argo container `args` directly in the raw YAML tab (`AgentCert/chaoscenter/web/src/views/ChaosStudio`). The required `-folder=<chart-dir-name>` value must match the literal chart directory name under `app-charts/`/`agent-charts/` exactly (e.g. `bookinfo`, not the `book-info` namespace/display name used elsewhere for the same app — a mismatch that silently fails the install step and cascades into an empty fault-injection target list, since `TargetApplicationTab` only lists what's actually live in-cluster). Additionally, Save stays disabled until a real fault step (`install-chaos-faults`/`install-chaos-experiments` with ≥1 artifact) is added via the fault drawer — `install-app`/`install-agent` steps alone never populate it, and no chaos-charts template currently pairs `book-info` with plain `sre-agent`. A simple onboarding procedure — either a short guided doc or a form-based install-app/install-agent step in the builder that lists valid chart folder names from `apphub`/`agenthub` — would remove this whole class of blank-canvas confusion.

---

## 7. Security & Shared-Host Isolation

### 7.1 `compose-up-guard.sh` Ownership Check
**Status: Implemented** — See §3.3.

### 7.2 `itbench-litmus-chaos-enable.yml` Added to `.gitignore`
**Status: Implemented**
This file contains a generated LitmusChaos subscriber registration access key. Added to `.gitignore` to prevent accidental commit to the public repo.

### 7.3 Hardcoded `/srv/projects/` Path Made Runtime-Adaptive
**Status: Implemented**
The chaos-charts default directory was hardcoded to `/srv/projects/ace-monorepo/chaos-charts-default/`. Changed to be dynamically resolved from `REPO_ROOT` at setup time so the repo works from any checkout path.

### 7.4 Origin Header Added to GraphQL Subscriber (Proposed Alternative)
**Status: Proposed**
Instead of broadening the `ALLOWED_ORIGINS` regex to match in-cluster Kubernetes service hostnames, add an `Origin` header directly in the subscriber's WebSocket dial code. Safer because it authenticates rather than bypasses the origin check.

---

## 8. Upstream Contributions (Open To-Dos)

### 8.1 PR: CISO Agent OpenAI-Compatible LLM Fix
**Status: Not Yet Raised**
Two fixes (already inlined into `agents/ciso-agent/` in this monorepo) are pushed on `fix/openai-compatible-llm-fallback` to a personal fork, but no PR has been opened against `itbench-hub/ITBench-CISO-CAA-Agent` upstream.

### 8.2 PR: SRE Agent Live-Mode MCP Compatibility Fix
**Status: Not Yet Pushed**
`agents/sre-agent@2d31052` has the live-mode compatibility fix committed locally but not pushed — `origin` is the real `itbench-hub` repo (no fork), so pushing requires an explicit decision.

### 8.3 Remaining CISO Scenario Types
**Status: Partially Tested**
Only `Gen-CIS-b-K8s-Kyverno` has been fully trialed end-to-end.
- `Gen-CIS-b-K8s-Kubectl-OPA` — not yet started.
- `Gen-CIS-b-RHEL9-Ansible-OPA` — requires a RHEL9 host; not yet started.
- `Upd-CIS-b-K8s-Kyverno` — not yet started.

---

## 9. Repository Structure

### 9.1 `agents/` Directory Consolidation
**Status: Implemented**
All agent implementations moved under `agents/` with standardized harness contracts (`bench.yaml`, `agent-harness.yaml`, `setup.sh`). Root-level `flash-agent/` duplicate removed; `agents/flash-agent/` is the canonical copy.

### 9.2 ChaosHub Category Split: `faults/itbench/` vs `faults/kubernetes/`
**Status: Implemented**
29 ITBench-derived fault bundles separated from ~35 generic LitmusChaos experiments. The portal now shows "Kubernetes" and "ITBench" as distinct ChaosHub categories.

### 9.3 `TARGETS`-Based Target Resolution in Fault Scripts
**Status: Implemented**
The chaos-operator on the cluster populates a combined `TARGETS` var instead of per-field vars. All 29 fault scripts now parse `TARGETS` at their top to derive `APP_KIND`/`APP_NAMESPACE`/`APP_LABEL`, fixing a critical bug where experiments never targeted the correct workload.

---

## 10. Summary Table

| # | Feature | Area | Status |
|---|---------|------|--------|
| 1.1 | Statistical certification (N=30) | Certifier | Implemented |
| 1.2 | H01–H09 hypothesis tests | Certifier | Implemented |
| 1.3 | LLM Council narrative synthesis | Certifier | Implemented |
| 1.4 | CISO scenario support + evidence packaging | Certifier | Implemented |
| 1.5 | OpenAI-compatible provider for LLM judges | Certifier | Implemented |
| 1.6 | `get_clients` resilience | Certifier | Implemented |
| 1.7 | Complete PDF block type coverage | Certifier | Implemented |
| 1.8 | CISO-aware Phase 3 builders | Certifier | Implemented |
| 1.9 | Two-layer capability probe system | Evaluation | Implemented |
| 1.10 | ChaosResult CR verdict patching | Evaluation | Implemented |
| 1.11 | Per-experiment model selection from UI | Control Plane | Proposed |
| 1.12 | Aggregation-failure status propagation to UI | Certifier | Implemented |
| 2.1 | sre-agent-crewai (ACE-built CrewAI SRE agent) | Agents | Implemented |
| 2.2 | A2A JSON-RPC 2.0 bridge | Agents | Implemented |
| 2.3 | Open-weight model certification (Qwen2.5 7B local GPU) | Agents | Implemented |
| 2.4 | `{{include:}}` processing in Zero's prompt system | Agents | Implemented |
| 2.5 | Prometheus + K8s MCP for live SRE mode | Agents | Implemented |
| 2.6 | Agent sidecar as sole `experiment_run_id` injection point | Agents | Implemented |
| 2.7 | `sre_react_online.md` composite entry-point | Agents | Proposed (deferred) |
| 3.1 | Instance-scoped shared-host isolation | Infrastructure | Implemented |
| 3.2 | KinD eviction absolute byte floor thresholds | Infrastructure | Implemented |
| 3.3 | `compose-up-guard.sh` safety wrapper | Infrastructure | Implemented |
| 3.4 | KinD cluster ownership marker | Infrastructure | Implemented |
| 3.5 | Dynamic KinD port selection | Infrastructure | Implemented |
| 3.6 | Containerized instance-scoped Ollama | Infrastructure | Implemented |
| 3.7 | `--local-build` flag in setup.sh | Infrastructure | Implemented |
| 3.8 | `shut_down.sh` safe teardown | Infrastructure | Implemented |
| 3.9 | Parallel Ollama model pull | Infrastructure | Implemented |
| 3.10 | Persistent image build policy in `.env` | Infrastructure | Implemented |
| 3.11 | Chart paths auto-updated per-host | Infrastructure | Implemented |
| 3.12 | Inode-based container ownership check | Infrastructure | Implemented |
| 3.13 | Durable argo-chaos ClusterRoleBinding | Infrastructure | Implemented |
| 3.14 | Multi-stage self-contained web Dockerfile | Infrastructure | Proposed |
| 3.15 | `make dev` target | Dev Experience | Proposed |
| 3.16 | Prompt JWT/MongoDB credentials at setup | Security | Proposed |
| 3.17 | Azure Content Safety prompted at setup | Security | Proposed |
| 3.18 | HTTPS for ChaosCenter web UI | Infrastructure | Proposed |
| 4.1 | `num_ctx: 16384` for Ollama models | LLM Config | Implemented |
| 4.2 | LiteLLM router timeout 600s | LLM Config | Implemented |
| 4.3 | Disable `enable_pre_call_checks` in LiteLLM | LLM Config | Implemented |
| 4.4 | `FLASH_AGENT_MODEL` self-healing | LLM Config | Implemented |
| 4.5 | Configurable LLM timeout/retry in flash-agent | LLM Config | Implemented |
| 4.6 | Switch Prometheus MCP to upstream ghcr.io image | Images | Implemented |
| 5.1 | `kind load` + rollout restart for image freshness | Images | Implemented |
| 5.2 | Global image registry strip in service.go | Images | Implemented |
| 5.3 | `--local` flag for build-and-push.sh | Images | Proposed |
| 6.1 | `run_certification.py` standalone runner | Dev Experience | Implemented |
| 6.2 | `dump_langfuse_trace.py` | Dev Experience | Implemented |
| 6.3 | `render_certification_pdf.py` | Dev Experience | Implemented |
| 6.4 | `ace-bench.py` orchestrator | Dev Experience | Implemented |
| 6.5 | Operational gotchas section in CLAUDE.md | Dev Experience | Implemented |
| 6.6 | Install-app console progress bar | Dev Experience | Implemented |
| 6.7 | `make setup-env` for trial env files | Dev Experience | Proposed |
| 6.8 | "Answer all upfront" option in setup.sh | Dev Experience | Proposed |
| 6.9 | Simple onboarding procedure for benchmarked agents | Dev Experience | Proposed |
| 7.1 | Compose-up-guard ownership check | Security | Implemented |
| 7.2 | `itbench-litmus-chaos-enable.yml` in .gitignore | Security | Implemented |
| 7.3 | Hardcoded `/srv/projects/` path made adaptive | Security | Implemented |
| 7.4 | Origin header in GraphQL subscriber (vs ALLOWED_ORIGINS regex) | Security | Proposed |
| 8.1 | PR: CISO agent OpenAI-compatible fix to upstream | Upstream | Not raised |
| 8.2 | Push: SRE agent live-mode fix to upstream | Upstream | Not pushed |
| 8.3 | Remaining CISO scenario types (Kubectl-OPA, RHEL9, Upd-Kyverno) | Evaluation | Partially tested |
| 9.1 | `agents/` consolidation | Repo Structure | Implemented |
| 9.2 | ChaosHub category split (itbench vs kubernetes) | Repo Structure | Implemented |
| 9.3 | `TARGETS`-based target resolution in fault scripts | Repo Structure | Implemented |
