#!/bin/bash
set -euo pipefail
# =============================================================================
# build_local_dockerhub/deploy-from-dockerhub.sh
#
# Pulls AgentCert images from Docker Hub and deploys them to local minikube.
# No build step — use this after azure_build/build-all.sh has pushed new images.
#
# Usage:
#   bash deploy-from-dockerhub.sh [--env-file /path/.env]
#
# What it does (mirrors the local build-* scripts, minus the docker build):
#   1. docker pull each image from Docker Hub (tags read from .env)
#   2. Clean old ci-* tags from minikube for each image
#   3. minikube image load each image (latest + ci tag)
#   4. kubectl set env litmusportal-server with all image + config vars
#   5. kubectl rollout status litmusportal-server
#   6. kubectl set image flash-agent deployment + cronjob in sock-shop (if present)
# =============================================================================

ENV_FILE="/mnt/d/Studies/AgentCert/local-custom/config/.env"
SERVER_NAMESPACE="litmus-chaos"
SERVER_DEPLOYMENT="litmusportal-server"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    *) echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[ERROR] .env file not found: ${ENV_FILE}" >&2; exit 1
fi

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}  $*"; }

# Read a value from .env (strips quotes + CR)
read_env_value() {
  local key="$1" default="${2:-}"
  local val
  val=$(grep -E "^${key}=" "${ENV_FILE}" | tail -1 | cut -d'=' -f2- | tr -d '\r\n' || true)
  val=${val#'"'}; val=${val%'"'}; val=${val#"'"}; val=${val%"'"}
  echo "${val:-${default}}"
}

# Read image tags from .env
INSTALL_AGENT_IMAGE="$(read_env_value INSTALL_AGENT_IMAGE agentcert/agentcert-install-agent:latest)"
INSTALL_APP_IMAGE="$(read_env_value INSTALL_APPLICATION_IMAGE agentcert/agentcert-install-app:latest)"
FLASH_AGENT_IMAGE="$(read_env_value FLASH_AGENT_IMAGE agentcert/agentcert-flash-agent:latest)"
AGENT_SIDECAR_IMAGE="$(read_env_value AGENT_SIDECAR_IMAGE agentcert/agent-sidecar:latest)"

# Config vars for litmusportal-server (same as build-flash-agent.sh sync)
LITELLM_MASTER_KEY="$(read_env_value LITELLM_MASTER_KEY sk-litellm-local-dev)"
OPENAI_BASE_URL="$(read_env_value OPENAI_BASE_URL http://litellm-proxy.litellm.svc.cluster.local:4000/v1)"
OPENAI_API_KEY="$(read_env_value OPENAI_API_KEY "${LITELLM_MASTER_KEY}")"
MODEL_ALIAS="$(read_env_value AZURE_OPENAI_DEPLOYMENT gpt-4)"
K8S_MCP_URL="$(read_env_value K8S_MCP_URL http://kubernetes-mcp-server.litmus.svc.cluster.local:8081/mcp)"
PROM_MCP_URL="$(read_env_value PROM_MCP_URL http://prometheus-mcp-server.litmus.svc.cluster.local:9090/mcp)"
CHAOS_NAMESPACE="$(read_env_value CHAOS_NAMESPACE litmus)"
PRE_CLEANUP_WAIT="$(read_env_value PRE_CLEANUP_WAIT_SECONDS 0)"
SLA_DETECT_SEC="$(read_env_value SLA_DETECT_SEC "")"
SLA_MITIGATE_SEC="$(read_env_value SLA_MITIGATE_SEC "")"
SLA_TOOL_CALL_SEC="$(read_env_value SLA_TOOL_CALL_SEC "")"

echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}AgentCert: Pull from Docker Hub + Deploy to Minikube${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""
log_info "INSTALL_AGENT_IMAGE:  ${INSTALL_AGENT_IMAGE}"
log_info "INSTALL_APP_IMAGE:    ${INSTALL_APP_IMAGE}"
log_info "FLASH_AGENT_IMAGE:    ${FLASH_AGENT_IMAGE}"
log_info "AGENT_SIDECAR_IMAGE:  ${AGENT_SIDECAR_IMAGE}"
echo ""

# ── Step 1: Docker Hub login ────────────────────────────────────────────────
DOCKERHUB_USERNAME="$(read_env_value DOCKERHUB_USERNAME)"
DOCKERHUB_TOKEN="$(read_env_value DOCKERHUB_TOKEN)"
if [[ -n "${DOCKERHUB_USERNAME}" && -n "${DOCKERHUB_TOKEN}" ]]; then
  log_info "Logging into Docker Hub as ${DOCKERHUB_USERNAME}..."
  echo "${DOCKERHUB_TOKEN}" | docker login -u "${DOCKERHUB_USERNAME}" --password-stdin
  log_success "Docker Hub login OK"
else
  log_info "DOCKERHUB_USERNAME/TOKEN not in .env — assuming already logged in"
fi
echo ""

# ── Step 2: Pull + clean + load each image ─────────────────────────────────
# Mirrors what the local build-*.sh scripts do after docker build:
#   - prune old ci-* from local docker
#   - clean old ci-* from minikube
#   - load latest + ci tag into minikube

load_image() {
  local image="$1"        # e.g. agentcert/agentcert-flash-agent:ci-20260424214206
  local grep_name="$2"    # e.g. agentcert-flash-agent  (for grep in minikube image ls)

  local tag
  tag=$(echo "${image}" | cut -d':' -f2)  # ci-* or latest

  log_info "Pulling ${image} from Docker Hub..."
  docker pull "${image}"
  log_success "Pulled: ${image}"

  # Tag as :latest locally so minikube load uses consistent name
  local repo
  repo=$(echo "${image}" | cut -d':' -f1)
  docker tag "${image}" "${repo}:latest"

  log_info "Cleaning old ${grep_name} images from minikube..."
  # Remove ALL old tags for this image (ci-*, latest, dev, etc.) except the one we're about to load
  minikube image ls 2>/dev/null \
    | grep "${grep_name}:" \
    | grep -v ":${tag}$" \
    | xargs -r minikube image rm 2>/dev/null || true
  # Also explicitly remove the current tag so minikube doesn't serve a stale cached layer
  minikube image rm "${repo}:${tag}" 2>/dev/null || true
  log_success "Old minikube images cleaned"

  log_info "Loading ${image} into minikube..."
  minikube image load "${image}"
  minikube image load "${repo}:latest"
  log_success "Loaded into minikube: ${image} + ${repo}:latest"
  echo ""
}

# ── Run all 4 AgentCert image loads in parallel ───────────────────────────
log_info "Starting parallel load of 4 AgentCert images..."
declare -a _main_pids=()
( load_image "${INSTALL_AGENT_IMAGE}"  "agentcert-install-agent" ) & _main_pids+=($!)
( load_image "${INSTALL_APP_IMAGE}"    "agentcert-install-app"   ) & _main_pids+=($!)
( load_image "${FLASH_AGENT_IMAGE}"    "agentcert-flash-agent"   ) & _main_pids+=($!)
( load_image "${AGENT_SIDECAR_IMAGE}"  "agent-sidecar"           ) & _main_pids+=($!)

_main_fail=0
for _pid in "${_main_pids[@]}"; do
  wait "$_pid" || _main_fail=1
done
[[ $_main_fail -eq 0 ]] || { log_error "One or more AgentCert image loads failed"; exit 1; }
log_success "All 4 AgentCert images loaded into minikube"
echo ""

# ── Step 3: Pull + load all sock-shop images into minikube ─────────────────
# These are fixed third-party images used when an experiment deploys sock-shop.
# Pre-loading ensures imagePullPolicy:IfNotPresent works offline / fast.
load_static_image() {
  local image="$1"
  log_info "Pulling ${image}..."
  docker pull "${image}" || { log_info "Skipping ${image} (pull failed)"; return 0; }
  minikube image load "${image}" || { log_info "Skipping minikube load for ${image}"; return 0; }
  log_success "Loaded: ${image}"
}

# Pool helpers: run up to _POOL_MAX jobs concurrently
_POOL_MAX=6
_pool_pids=()
_pool_fail=0

_pool_submit() {
  # If pool is full, wait for the oldest job before adding a new one
  while [[ ${#_pool_pids[@]} -ge $_POOL_MAX ]]; do
    wait "${_pool_pids[0]}" || _pool_fail=1
    _pool_pids=("${_pool_pids[@]:1}")
  done
  ( "$@" ) &
  _pool_pids+=($!)
}

_pool_drain() {
  for _p in "${_pool_pids[@]}"; do
    wait "$_p" || _pool_fail=1
  done
  _pool_pids=()
}

log_info "Loading sock-shop + LiteLLM images into minikube (parallel, max ${_POOL_MAX} concurrent)..."
echo ""
# Sock Shop microservices
_pool_submit load_static_image "weaveworksdemos/front-end:0.3.12"
_pool_submit load_static_image "weaveworksdemos/catalogue:0.3.5"
_pool_submit load_static_image "weaveworksdemos/catalogue-db:0.3.0"
_pool_submit load_static_image "weaveworksdemos/carts:0.4.8"
_pool_submit load_static_image "weaveworksdemos/orders:0.4.7"
_pool_submit load_static_image "weaveworksdemos/payment:0.4.3"
_pool_submit load_static_image "weaveworksdemos/shipping:0.4.8"
_pool_submit load_static_image "weaveworksdemos/user:0.4.7"
_pool_submit load_static_image "weaveworksdemos/user-db:0.4.0"
_pool_submit load_static_image "weaveworksdemos/queue-master:0.3.1"
_pool_submit load_static_image "mongo:latest"
_pool_submit load_static_image "rabbitmq:3.6.8"
# Observability
_pool_submit load_static_image "litmuschaos/chaos-exporter:1.13.3"
_pool_submit load_static_image "prom/prometheus:v2.25.0"
_pool_submit load_static_image "grafana/grafana:latest"
# MCP tools
_pool_submit load_static_image "quay.io/containers/kubernetes_mcp_server:latest"
_pool_submit load_static_image "agentcert/prometheus-mcp-server:latest"

# ── Step 4: Pull + load LiteLLM proxy image (overlapped with final sock-shop batch) ──
LITELLM_IMAGE="$(read_env_value LITELLM_PROXY_IMAGE docker.io/litellm/litellm:v1.82.0-stable)"
log_info "Pulling LiteLLM proxy image: ${LITELLM_IMAGE} (parallel with sock-shop)..."
_pool_submit bash -c "docker pull '${LITELLM_IMAGE}' && minikube image load '${LITELLM_IMAGE}' \
  && echo '[INFO]  Loaded: ${LITELLM_IMAGE}' || echo '[INFO]  LiteLLM image load failed — skipping'"

_pool_drain
[[ $_pool_fail -eq 0 ]] || log_info "Some optional sock-shop/LiteLLM images failed to load (non-fatal)"
log_success "All sock-shop + LiteLLM images loaded into minikube"
echo ""

# Restart litellm-proxy pod so it picks up the newly loaded image

if kubectl get deployment litellm-proxy -n litellm >/dev/null 2>&1; then
  log_info "Restarting litellm-proxy deployment..."
  kubectl rollout restart deployment/litellm-proxy -n litellm
  kubectl rollout status deployment/litellm-proxy -n litellm --timeout=120s
  log_success "litellm-proxy restarted"
else
  log_info "litellm-proxy deployment not found — skipping restart"
fi
echo ""

# ── Step 5: kubectl set env litmusportal-server + rollout ──────────────────
if ! command -v kubectl >/dev/null 2>&1; then
  log_error "kubectl not found — skipping deployment sync"; exit 1
fi
if ! kubectl get deployment "${SERVER_DEPLOYMENT}" -n "${SERVER_NAMESPACE}" >/dev/null 2>&1; then
  log_error "${SERVER_NAMESPACE}/${SERVER_DEPLOYMENT} not found — is minikube running with litmus deployed?" >&2
  exit 1
fi

log_info "Syncing litmusportal-server env vars..."
set_env_args=("deployment/${SERVER_DEPLOYMENT}" "-n" "${SERVER_NAMESPACE}")
set_env_args+=(
  "INSTALL_AGENT_IMAGE=${INSTALL_AGENT_IMAGE}"
  "INSTALL_APPLICATION_IMAGE=${INSTALL_APP_IMAGE}"
  "FLASH_AGENT_IMAGE=${FLASH_AGENT_IMAGE}"
  "AGENT_SIDECAR_IMAGE=${AGENT_SIDECAR_IMAGE}"
  "LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}"
  "OPENAI_API_KEY=${OPENAI_API_KEY}"
  "OPENAI_BASE_URL=${OPENAI_BASE_URL}"
  "MODEL_ALIAS=${MODEL_ALIAS}"
  "K8S_MCP_URL=${K8S_MCP_URL}"
  "PROM_MCP_URL=${PROM_MCP_URL}"
  "CHAOS_NAMESPACE=${CHAOS_NAMESPACE}"
  "PRE_CLEANUP_WAIT_SECONDS=${PRE_CLEANUP_WAIT}"
)
[ -n "${SLA_DETECT_SEC}" ]    && set_env_args+=("SLA_DETECT_SEC=${SLA_DETECT_SEC}")
[ -n "${SLA_MITIGATE_SEC}" ]  && set_env_args+=("SLA_MITIGATE_SEC=${SLA_MITIGATE_SEC}")
[ -n "${SLA_TOOL_CALL_SEC}" ] && set_env_args+=("SLA_TOOL_CALL_SEC=${SLA_TOOL_CALL_SEC}")
kubectl set env "${set_env_args[@]}" >/dev/null

log_info "Rolling out ${SERVER_DEPLOYMENT}..."
kubectl rollout status deployment/"${SERVER_DEPLOYMENT}" -n "${SERVER_NAMESPACE}" --timeout=120s
log_success "litmusportal-server updated and healthy"
echo ""

# ── Step 6: Sync flash-agent deployment + cronjob in sock-shop ────────────
FA_NAMESPACE="sock-shop"
for workload_type in deployment cronjob; do
  workload_name="flash-agent"
  [[ "${workload_type}" == "cronjob" ]] && workload_name="flash-agent-cronjob"
  if kubectl -n "${FA_NAMESPACE}" get "${workload_type}" "${workload_name}" >/dev/null 2>&1; then
    log_info "Updating ${FA_NAMESPACE}/${workload_name} image -> ${FLASH_AGENT_IMAGE}"
    kubectl -n "${FA_NAMESPACE}" set image "${workload_type}/${workload_name}" \
      agent="${FLASH_AGENT_IMAGE}" >/dev/null || true
    if [[ "${workload_type}" == "deployment" ]]; then
      # Force a rollout even when the tag is ':latest' (set image is a no-op
      # when the tag string is unchanged but the underlying image has been
      # replaced in minikube). This guarantees the new image is picked up.
      log_info "Forcing rollout restart of ${FA_NAMESPACE}/${workload_name}..."
      kubectl -n "${FA_NAMESPACE}" rollout restart "deployment/${workload_name}" >/dev/null 2>&1 || true
      kubectl -n "${FA_NAMESPACE}" rollout status "deployment/${workload_name}" \
        --timeout=120s >/dev/null || true
    fi
    log_success "${workload_name} updated"
  else
    log_info "${FA_NAMESPACE}/${workload_name} not found — skipping"
  fi
done
echo ""

docker logout >/dev/null 2>&1 || true

# ── Step 7: Post-deploy cluster sync + verify ─────────────────────────────
# Mutating actions first (helm upgrade sock-shop, restart prometheus),
# then verification at the end so the report reflects post-action state.
if kubectl get ns monitoring >/dev/null 2>&1; then
  echo ""
  log_info "Post-deploy cluster sync..."

  # ── Action 1: helm upgrade sock-shop ──────────────────────────────────
  # If a helm release of sock-shop exists, upgrade it so the new chart
  # (cadvisor + KSM scrape jobs, KSM Deployment) reaches the cluster
  # immediately rather than waiting for the next experiment to re-run
  # install-app.
  if command -v helm >/dev/null 2>&1; then
    SOCKSHOP_RELEASE=$(helm list -A 2>/dev/null | awk '$1=="sock-shop"{print $1; exit}')
    SOCKSHOP_NS=$(helm list -A 2>/dev/null | awk '$1=="sock-shop"{print $2; exit}')
    SOCKSHOP_CHART_DIR=""
    for cand in /tmp/agentcert-build/app-charts/charts/sock-shop \
                /mnt/d/Studies/app-charts/charts/sock-shop; do
      [[ -d "$cand" ]] && SOCKSHOP_CHART_DIR="$cand" && break
    done
    if [[ -n "${SOCKSHOP_RELEASE}" && -n "${SOCKSHOP_CHART_DIR}" ]]; then
      log_info "helm upgrade sock-shop in ns ${SOCKSHOP_NS} from ${SOCKSHOP_CHART_DIR}"
      helm upgrade sock-shop "${SOCKSHOP_CHART_DIR}" -n "${SOCKSHOP_NS}" \
        --set monitoring.enabled=true --reuse-values >/dev/null 2>&1 \
        && log_success "sock-shop chart upgraded" \
        || log_info "helm upgrade failed (non-fatal) — re-run experiment to pick up new chart"
    else
      log_info "No sock-shop helm release found locally — new chart will load on next experiment"
    fi
  else
    log_info "helm CLI not found — skipping in-place chart upgrade"
  fi

  # ── Action 2: restart prometheus to reload scrape config ──────────────
  if kubectl -n monitoring get deploy prometheus-deployment >/dev/null 2>&1; then
    log_info "Restarting prometheus-deployment to reload scrape config..."
    kubectl -n monitoring rollout restart deploy/prometheus-deployment >/dev/null 2>&1 || true
    kubectl -n monitoring rollout status deploy/prometheus-deployment --timeout=120s >/dev/null 2>&1 || true
    log_success "prometheus-deployment restarted"
  fi

  # ── Verification (post-action state) ──────────────────────────────────
  echo ""
  log_info "Verifying monitoring stack..."

  # KSM Deployment present?
  if kubectl -n monitoring get deploy kube-state-metrics >/dev/null 2>&1; then
    log_success "kube-state-metrics Deployment exists"
    kubectl -n monitoring get deploy kube-state-metrics -o wide 2>&1 | tail -1
  else
    log_info "kube-state-metrics Deployment NOT found in monitoring ns"
    log_info "  -> install-app may need to be re-run so the new helm chart applies"
  fi

  # Prom configmap contains the new scrape jobs?
  if kubectl -n monitoring get cm prometheus-configmap -o jsonpath='{.data.prometheus\.yml}' 2>/dev/null | grep -q 'kubernetes-cadvisor'; then
    log_success "prometheus-configmap contains 'kubernetes-cadvisor' job"
  else
    log_info "prometheus-configmap MISSING 'kubernetes-cadvisor' job — re-run install-app"
  fi
  if kubectl -n monitoring get cm prometheus-configmap -o jsonpath='{.data.prometheus\.yml}' 2>/dev/null | grep -q 'kube-state-metrics'; then
    log_success "prometheus-configmap contains 'kube-state-metrics' job"
  else
    log_info "prometheus-configmap MISSING 'kube-state-metrics' job — re-run install-app"
  fi

  # Targets up count
  up_count=$(kubectl -n monitoring exec deploy/prometheus-deployment -- \
      wget -qO- localhost:9090/api/v1/targets 2>/dev/null \
    | grep -o '"health":"up"' | wc -l || echo 0)
  log_info "Prometheus targets up: ${up_count}"
else
  log_info "monitoring ns not present (no experiment deployed yet) — skipping sync+verify"
fi
echo ""

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}Done! All images loaded into minikube and${NC}"
echo -e "${GREEN}litmusportal-server synced with new tags.${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
