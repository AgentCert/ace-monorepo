# ACE Scripts Guide

Complete reference for all scripts in the `/scripts` directory and how to run them.

---

## 1. **Core Setup & Infrastructure**

### `setup.sh` — First-time Setup Wizard
**Purpose:** Creates and configures the root `.env` file for a new user or checkout. Sets up Kubernetes/Helm deployment infrastructure and container orchestration.

**Usage:**
```bash
# First-time interactive setup (prompts for credentials and config)
./scripts/setup.sh

# Restart deployment without prompts (uses existing .env values)
./scripts/setup.sh --restart

# Bootstrap personal rootless Docker daemon (avoid shared host conflicts)
./scripts/setup.sh --rootless-docker
./scripts/setup.sh --restart --rootless-docker

# Pre-select which agent to benchmark (pre-answers "Agent to benchmark" question)
./scripts/setup.sh --agent=flash-agent
./scripts/setup.sh --restart --agent=ciso-agent

# Combine flags
./scripts/setup.sh --rootless-docker --agent=flash-agent
```

**What it does:**
- Checks prerequisites (Docker, git, kind, kubectl, helm, Python 3.12)
- Creates `.env` from `.env.example` (if needed)
- Auto-sets `ACE_INSTANCE_NAME`, `OLLAMA_PORT`, other instance-scoped values
- Prompts for Azure OpenAI / Gemini API keys
- Generates `deploy/helm/ace/values-env.yaml` from .env
- Optionally deploys to Kubernetes cluster
- Initializes MongoDB replica set
- Sets up Langfuse, LiteLLM, Ollama services

**Notes:**
- Idempotent — safe to re-run
- On shared hosts, auto-generates unique port/instance names to avoid collisions
- Use `--rootless-docker` for personal container isolation without affecting other users

---

### `start-local-services.sh` — Start Docker Compose Services
**Purpose:** Brings up MongoDB, Langfuse, LiteLLM, Ollama, and Certifier as Docker containers for local development (no Kubernetes needed).

**Usage:**
```bash
# Start all services
./scripts/start-local-services.sh

# Start specific services only
./scripts/start-local-services.sh --only-mongo
./scripts/start-local-services.sh --only-langfuse
./scripts/start-local-services.sh --only-litellm
./scripts/start-local-services.sh --only-certifier
./scripts/start-local-services.sh --only-ollama

# Skip specific services
./scripts/start-local-services.sh --skip-ollama          # skip Ollama (use cloud LLMs)
./scripts/start-local-services.sh --skip-langfuse       # skip Langfuse
./scripts/start-local-services.sh --skip-certifier      # skip Certifier

# Restart services (even if already running)
./scripts/start-local-services.sh --restart

# Pull pre-built certifier image instead of building from source
./scripts/start-local-services.sh --pull-certifier

# Check for local uncommitted changes before starting
./scripts/start-local-services.sh --check-local-mods

# Specify custom env file or Langfuse directory
./scripts/start-local-services.sh --env-file /path/to/.env
./scripts/start-local-services.sh --langfuse-dir /opt/langfuse

# Combine options
./scripts/start-local-services.sh --restart --skip-ollama --pull-certifier
```

**What it does:**
- Pulls Docker images (or builds from source)
- Creates Docker volumes for persistent data
- Starts containers with proper networking and environment variables
- Initializes MongoDB replica set with credentials
- Each service is idempotent — only starts if not already running

**Connection strings:**
- MongoDB: `mongodb://admin:1234@localhost:27017/?replicaSet=rs0&authSource=admin`
- Langfuse: `http://localhost:4000` (user: admin@agentcert.local, pwd: agentcert-admin)
- LiteLLM: `http://localhost:14000/v1` (key: sk-agentcert-2026)
- Certifier API: `http://localhost:8000` (Swagger at `/docs`)

---

### `compose-up-guard.sh` — Safe Docker Compose Wrapper
**Purpose:** Wraps `docker compose` with ownership checks to prevent cross-checkout collisions on shared hosts.

**Usage:**
```bash
# Use like docker compose normally
./scripts/compose-up-guard.sh up -d              # start all services
./scripts/compose-up-guard.sh down               # stop all services
./scripts/compose-up-guard.sh logs -f graphql   # stream logs
./scripts/compose-up-guard.sh ps                 # list containers

# It's a drop-in replacement for `docker compose`
./scripts/compose-up-guard.sh restart mongo
./scripts/compose-up-guard.sh rm -f certifier
```

**What it does:**
- Checks every container name in docker-compose.yml
- Verifies if it's already running under a DIFFERENT checkout (by inspecting Docker labels)
- Refuses to proceed if a foreign container is found
- Prevents the incident where one checkout silently deletes another's running services

---

### `check-prerequisites.sh` — Verify Required Tools
**Purpose:** Audits system dependencies and auto-fixes what can be fixed without sudo.

**Usage:**
```bash
# Standalone check (human-readable output)
./scripts/check-prerequisites.sh

# Sourced by setup.sh; also sets $PYTHON312_BIN when resolved
source ./scripts/check-prerequisites.sh

# Export custom Python for audit (setup.sh uses this)
ACE_PREREQ_PYTHON_BIN=/usr/bin/python3.12 ./scripts/check-prerequisites.sh
```

**What it checks:**
- ✓ Docker 28+ and docker compose
- ✓ git
- ✓ kind 0.20+, kubectl 1.27+, helm 3.12+ (Kubernetes path)
- ✓ Python 3.12 (certifier local dev only)
- ✓ Node.js 20+ (frontend changes only)
- ✓ Go 1.24 (backend changes only)
- Auto-fixes: Python 3.12 via `uv` when apt doesn't have it
- Requires sudo for: docker, git, kind, kubectl, helm (just prints command to run)

---

## 2. **Pipeline & Certification**

### `run_certification.py` — End-to-End Certifier Pipeline (Dev Tool)
**Purpose:** Runs the full 4-phase certification pipeline against a single Langfuse trace without needing the FastAPI server.

**Usage:**
```bash
# Look up experiment_id/run_id automatically from a Langfuse trace ID
./scripts/run_certification.py --trace-id <UUID>

# Or provide IDs explicitly (skips Langfuse metadata lookup)
./scripts/run_certification.py \
    --agent-id <UUID> \
    --experiment-id <UUID> \
    --run-id <UUID>

# Optional knobs
./scripts/run_certification.py --trace-id <UUID> \
    --workspace ./.tmp \
    --batch-size 10 \
    --runs-per-fault 1 \
    --skip-cert              # skip Phase 2+3, stop after Phase 0+1

# No PDF generation (faster)
./scripts/run_certification.py --trace-id <UUID> --no-pdf

# Debug mode (verbose logging)
./scripts/run_certification.py --trace-id <UUID> --debug
```

**What it does:**
- **Phase 0:** LLM fault bucketing (classifies spans into fault buckets)
- **Phase 1:** LLM + Python metrics extraction (TTD, TTR, hallucination score)
- **Phase 2:** Python stats + LLM Council aggregation (across all runs if n≥1)
- **Phase 3:** Pydantic-validated 12-section CertificationReport assembly
- **Phase 4:** Jinja2 HTML + Playwright PDF rendering (A4 multi-page)
- Workspace layout: `.tmp/{agent_id}/{experiment_id}/`

**Output:**
- Fault buckets: `fault-bucketing/{run_id}/fault_buckets/*.json`
- Metrics: `fault-bucketing/{run_id}/metrics/*_metrics.json`
- Aggregation: `aggregation/aggregation.json`
- Certificate: `cert-builder/certification.json`
- HTML/PDF: `certification/docs/*.{html,pdf}`

---

### `ace-bench.py` — Local Trace-Based Benchmarking (Flash Agent Dev Tool)
**Purpose:** Development convenience for running flash-agent experiments locally WITHOUT the LitmusChaos control plane. For production, use the LitmusChaos Argo Workflow.

**Usage:**
```bash
# Run flash-agent trace_based pipeline (default 1 run)
python scripts/ace-bench.py flash-agent

# Multiple runs
python scripts/ace-bench.py flash-agent --runs 30

# Multiple runs per fault
python scripts/ace-bench.py flash-agent --runs-per-fault 5

# Resume interrupted benchmark
python scripts/ace-bench.py flash-agent --runs 30 --resume

# Skip environment setup
python scripts/ace-bench.py flash-agent --skip-setup

# Skip certifier (just generate traces, don't run the pipeline)
python scripts/ace-bench.py flash-agent --skip-certifier

# Combine options
python scripts/ace-bench.py flash-agent --runs 10 --resume --skip-certifier
```

**What it does:**
- Reads `agents/harness/flash-agent/bench.yaml` for pipeline config
- Spins up flash-agent with MCP tools in a containerized environment
- Collects Langfuse traces
- Runs the certifier pipeline (Phase 0+1+2+3+4)
- Outputs all artefacts to `.tmp/bench/flash-agent/`

**Note:** This is a dev-only tool. For production benchmarking, use the LitmusChaos Argo Workflow registered in AgentCert.

---

### `dump_langfuse_trace.py` — Export Langfuse Trace to JSON
**Purpose:** Extracts a Langfuse trace by experiment/run ID and saves it as JSON for offline pipeline testing.

**Usage:**
```bash
# Basic usage (reads credentials from .env)
./scripts/dump_langfuse_trace.py \
    --experiment-id 1a3226c7-b186-4c74-8b09-9dd1bb45177d \
    --run-id        795b0c04-d24e-464a-9b1e-a70c53891a0f

# Custom output directory (default: trace_dumps/<exp_id>__<run_id>)
./scripts/dump_langfuse_trace.py \
    --experiment-id <EXP> \
    --run-id <RUN> \
    --output-dir ./my-traces/sample-001

# Override Langfuse credentials
./scripts/dump_langfuse_trace.py \
    --experiment-id <EXP> --run-id <RUN> \
    --langfuse-host https://my-langfuse.com \
    --public-key pk_... \
    --secret-key sk_...

# Control pagination and filtering
./scripts/dump_langfuse_trace.py \
    --experiment-id <EXP> --run-id <RUN> \
    --page-size 100 \
    --max-pages 50 \
    --no-observations    # skip observation details
```

**Output:**
- `raw_trace.json` — Full Langfuse trace in certifier-compatible format
- `trace_meta.json` — Metadata summary (IDs, timing, stats)

---

### `render_certification_pdf.py` — Render PDF from Certificate JSON
**Purpose:** Converts a `certification.json` file into a styled multi-page A4 PDF report.

**Usage:**
```bash
# Basic usage (output goes next to input)
./scripts/render_certification_pdf.py \
    --input .tmp/<agent_id>/<exp_id>/cert-builder/certification.json
# Creates: .tmp/<agent_id>/<exp_id>/cert-builder/certification.pdf

# Custom output path
./scripts/render_certification_pdf.py \
    --input certification.json \
    --output certificate.pdf

# Batch rendering (multiple certificates)
for json_file in .tmp/*/*/cert-builder/certification.json; do
    ./scripts/render_certification_pdf.py --input "$json_file"
done
```

**What it does:**
- Parses JSON certification report (12 sections + blocks)
- Renders blocks (text, headings, tables, findings, cards, charts, assessments)
- Uses ReportLab Platypus for PDF layout
- Applies theme colors and typography
- Produces A4 multi-page document

---

## 3. **Image Management & Deployment**

### `build-and-push.sh` — Build & Push Docker Images to Docker Hub
**Purpose:** Builds all AgentCert component Docker images and pushes them to Docker Hub.

**Usage:**
```bash
# Build and push to Docker Hub (reads DOCKERHUB_USERNAME / DOCKERHUB_TOKEN from .env)
./scripts/build-and-push.sh

# Build only, don't push
./scripts/build-and-push.sh --local

# Build and load into local KinD cluster (implies --local)
./scripts/build-and-push.sh --kind-load

# Custom env file
./scripts/build-and-push.sh --env-file /path/to/.env

# Combine options
./scripts/build-and-push.sh --local --kind-load
```

**Images built:**
1. agentcert/agentcert-flash-agent
2. agentcert/agent-sidecar
3. agentcert/agentcert-install-agent
4. agentcert/agentcert-install-app
5. agentcert/certifier
6. agentcert/agentcert-graphql
7. agentcert/agentcert-auth
8. agentcert/agentcert-web

**What it does:**
- Runs `docker build` on each component's Dockerfile
- Tags as `agentcert/<name>:latest` (or custom tag from .env)
- Logs into Docker Hub (requires DOCKERHUB_USERNAME and DOCKERHUB_TOKEN in .env)
- Pushes all images
- Optionally loads into KinD cluster

---

### `prepare-images.sh` — Configure Experiment Workflow Images
**Purpose:** Builds, loads, or configures registry credentials for experiment workflow images based on `*_IMAGE_SOURCE` in `.env`.

**Usage:**
```bash
# Auto-detect sources from .env and prepare accordingly
./scripts/prepare-images.sh

# Called automatically by setup.sh when any source is non-default
# Safe to run standalone to rebuild/reload
```

**What it does:**
- Reads `INSTALL_APP_IMAGE_SOURCE`, `INSTALL_AGENT_IMAGE_SOURCE`, `LITMUS_IMAGES_SOURCE`, etc.
- For `local`: builds from source + loads into KinD cluster
- For `jfrog`: creates docker-registry Secret + patches argo-chaos ServiceAccount
- For `dockerhub`: no action (images pulled at runtime)

**Image sources:**
- `dockerhub` — Pull from public Docker Hub (default, no creds needed)
- `jfrog` — Pull from JFrog Artifactory (requires JFROG_USER, JFROG_TOKEN)
- `local` — Build from source + load into KinD cluster

---

## 4. **Infrastructure Management**

### `shut_down.sh` — Cleanup and Teardown
**Purpose:** Removes all Docker containers, volumes, and KinD clusters created by this checkout. Safe for shared hosts — never touches other users' resources.

**Usage:**
```bash
# Interactive teardown with confirmation
./scripts/shut_down.sh

# Non-interactive (CI/scripted use); keeps Ollama models by default
./scripts/shut_down.sh --yes

# Keep Ollama models (don't re-download on next setup)
./scripts/shut_down.sh --keep-ollama-model

# Delete Ollama models explicitly
./scripts/shut_down.sh --delete-ollama-model

# Keep Langfuse trace data (Postgres, ClickHouse, Redis, MinIO)
./scripts/shut_down.sh --keep-langfuse-traces

# Delete Langfuse trace data
./scripts/shut_down.sh --delete-langfuse-traces

# Skip MongoDB backup (default: backs up before deletion)
./scripts/shut_down.sh --no-mongo-backup

# Clean only Completed pods in itbench namespace(s)
./scripts/shut_down.sh --clean-itbench-pods

# Target specific namespace
./scripts/shut_down.sh --clean-itbench-pods --namespace=sock-shop

# Combine options
./scripts/shut_down.sh --yes --delete-ollama-model --keep-langfuse-traces
```

**What it does:**
- Force-stops and removes Docker containers (matches ACE_INSTANCE_NAME)
- Deletes named volumes (ollama-models, mongodb-data, langfuse-*, etc.)
- Deletes KinD cluster (unless `--clean-itbench-pods` is used alone)
- Dumps MongoDB before deletion (automatic backup to `.tmp/mongodb-backups/`)
- Respects instance isolation — never touches other users' resources

---

### `cleanup-litmus-ns.sh` — Force-Clean Stuck Kubernetes Namespace
**Purpose:** Recovers a namespace stuck in Terminating state due to held finalizers.

**Usage:**
```bash
# Clean the default "litmus" namespace
bash cleanup-litmus-ns.sh

# Clean a different namespace
bash cleanup-litmus-ns.sh sock-shop

# Dry-run mode (show what would be done)
bash cleanup-litmus-ns.sh --dry-run

# Skip the nuclear namespace finalize step
bash cleanup-litmus-ns.sh --no-finalize

# Combine options
bash cleanup-litmus-ns.sh sock-shop --dry-run
```

**What it does:**
1. Shows current namespace state + finalizers
2. Force-deletes all pods (grace-period=0, --force)
3. Strips pod finalizers
4. Strips finalizers from ChaosEngines, ChaosResults, Workflows
5. Strips namespace finalizers via `/finalize` subresource (nuclear option)
6. Verifies the namespace is gone

---

## 5. **Development Utilities**

### `sync-python-venv.sh` — Create/Update Python Virtual Environment
**Purpose:** Sets up or syncs a Python virtual environment for development.

**Usage:**
```bash
# Create/update default .venv
bash scripts/sync-python-venv.sh

# Dry-run mode (show what would be done)
bash scripts/sync-python-venv.sh --dry-run

# Custom venv location
bash scripts/sync-python-venv.sh --venv=/path/to/venv

# Combine options
bash scripts/sync-python-venv.sh --dry-run --venv=/custom/venv
```

**What it does:**
- Detects python3.12 or falls back to python3
- Creates `.venv/` if it doesn't exist
- Renders progress bar during pip installs
- Used for local certifier development (alternative to Docker)

---

### `gen-vscode-ports.sh` — Generate VS Code Port Forwarding Config
**Purpose:** Generates VS Code settings for remote port forwarding with ACE services for this checkout.

**Usage:**
```bash
# Auto-generate .vscode/settings.json port attributes
bash scripts/gen-vscode-ports.sh
```

**What it does:**
- Inspects this checkout's KinD cluster and Docker containers
- Extracts service ports (web, auth, graphql, litellm, etc.)
- Writes `.vscode/settings.json` with `remote.portsAttributes` labels
- Generates `remote.SSH.defaultForwardedPorts` snippet
- Safe for shared hosts — only recognizes services tagged with this checkout's ACE_INSTANCE_NAME
- Idempotent — safe to re-run after port changes

---

### `validate-fault-capabilities.py` — Fault Catalog Conformance Check
**Purpose:** Static validation that every fault in the catalog, charts, and dispatcher are in sync and properly configured.

**Usage:**
```bash
# Run full conformance check (no cluster needed)
scripts/validate-fault-capabilities.py

# Quiet mode (errors only, no warnings)
scripts/validate-fault-capabilities.py --quiet

# Custom repo root
scripts/validate-fault-capabilities.py --repo-root /path/to/ace-monorepo
```

**What it checks:**
- Every fault selectable in UI has an implementation
- Every implementation is exposed in a Helm chart
- Tunables match between chart and Go code
- Fault target requirements are realistic
- No dead branches in implementation code

**Exit status:** 0 = clean, 1+ = errors found (warnings don't fail)

---

### `verify-innovation-log.py` — Consistency Check for innovation.md
**Purpose:** Verifies that innovation.md's section headings and summary table stay in sync.

**Usage:**
```bash
# Check for desync between headings and table
scripts/verify-innovation-log.py

# (run after editing innovation.md; exit code non-zero if out of sync)
```

**What it does:**
- Parses all `### N.M Title` headings
- Extracts **Status: ...** lines from each heading
- Compares against the "## 10. Summary Table" section
- Validates all cross-references (§N.M syntax)
- Reports mismatches

---

### `audit_python_image_deps.py` — Python Dependency Audit
**Purpose:** Audits that Python dependencies declared in code match what's pinned in Dockerfile/requirements.txt.

**Usage:**
```bash
# Audit Python images (certifier, install-app wrapper, install-agent wrapper, etc.)
scripts/audit_python_image_deps.py

# Quiet mode
scripts/audit_python_image_deps.py --quiet
```

**What it checks:**
- Scans Python source code for imports
- Cross-references against Dockerfile RUN pip install
- Flags missing or extra dependencies
- Detects version pins that might be outdated

---

### `audit_non_python_image_deps.py` — Non-Python Dependency Audit
**Purpose:** Audits Go and Node.js dependencies in Dockerfiles.

**Usage:**
```bash
# Audit Go and Node.js images (AgentCert backend, web frontend, etc.)
scripts/audit_non_python_image_deps.py

# Quiet mode
scripts/audit_non_python_image_deps.py --quiet
```

**What it checks:**
- Go: scans for imports and checks Dockerfile `RUN go get`
- Node.js: scans for imports and checks Dockerfile `RUN npm install`
- Detects missing packages, version conflicts, etc.

---

## 6. **Azure Build (Subfolder)**

### `azure_build/start-agentcert-v2.sh` — Start ACE on Azure VMs
**Purpose:** Bootstraps ACE infrastructure on Azure VMs (part of the cloud deployment workflow).

**Usage:**
```bash
bash scripts/azure_build/start-agentcert-v2.sh
```

---

### `azure_build/build-and-deploy-app-chart.sh` — Deploy App Helm Chart to Azure
**Purpose:** Builds and deploys application Helm charts to a cloud-based Kubernetes cluster.

**Usage:**
```bash
bash scripts/azure_build/build-and-deploy-app-chart.sh
```

---

### `azure_build/run.sh` — Azure Build Entrypoint
**Purpose:** Main entry point for Azure infrastructure provisioning.

**Usage:**
```bash
bash scripts/azure_build/run.sh
```

---

## Quick Reference

### Setup from Scratch
```bash
./scripts/setup.sh                    # Interactive wizard
./scripts/start-local-services.sh     # Start Docker services
```

### Tear Down Everything
```bash
./scripts/shut_down.sh --yes          # Non-interactive cleanup
```

### Local Development (Certifier Pipeline)
```bash
./scripts/run_certification.py --trace-id <UUID>
```

### Benchmark Flash Agent (Dev Only)
```bash
python scripts/ace-bench.py flash-agent --runs 10
```

### Push to Docker Hub
```bash
./scripts/build-and-push.sh
```

### Check System Health
```bash
./scripts/check-prerequisites.sh
./scripts/validate-fault-capabilities.py
```

---

## Tips for Shared Hosts

On shared hosts (where multiple users checkout this repo):

1. **Run setup.sh first** — it auto-generates a unique `ACE_INSTANCE_NAME` and port numbers to avoid collisions
2. **Use compose-up-guard.sh** instead of bare `docker compose` — it prevents cross-checkout accidents
3. **Run shut_down.sh before leaving** — cleanup is automatic, not manual
4. **Pass --rootless-docker to setup.sh** — for complete container isolation from other users
5. **Never manually docker rm/stop containers** — they might belong to another checkout's active experiment

---

## Environment Variables

All scripts read from the root `.env` file (created by `setup.sh`). Key variables:

- `ACE_INSTANCE_NAME` — Unique suffix for this checkout's resources (auto-set)
- `OLLAMA_PORT`, `MONGO_PORT`, `LANGFUSE_PORT`, `LITELLM_PORT` — Service ports (auto-assigned)
- `AZURE_OPENAI_API_KEY`, `GEMINI_API_KEY` — LLM credentials
- `MONGODB_CONNECTION_STRING` — MongoDB URI for certifier
- `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` — For `build-and-push.sh`
- `JFROG_*` — JFrog registry credentials (optional, for image sources)

See CLAUDE.md Section 8 for the complete list.
