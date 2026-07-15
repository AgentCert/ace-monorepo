#!/bin/bash
set -e

SERVER_NAMESPACE="litmus-chaos"
SERVER_DEPLOYMENT="litmusportal-server"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[ERROR] Env file not found: ${ENV_FILE}" >&2
  exit 1
fi

read_env_value() {
  local key="$1"
  local value
  value=$(grep -E "^${key}=" "${ENV_FILE}" | tail -1 | cut -d'=' -f2- || true)
  value=$(echo "${value}" | tr -d '\r\n')
  value=${value#"\""}
  value=${value%"\""}
  value=${value#"'"}
  value=${value%"'"}
  echo "${value}"
}

sync_live_server_env() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "[WARN] kubectl not found; skipping live server env sync"
    return 0
  fi

  if ! kubectl get deployment "${SERVER_DEPLOYMENT}" -n "${SERVER_NAMESPACE}" >/dev/null 2>&1; then
    echo "[WARN] ${SERVER_NAMESPACE}/${SERVER_DEPLOYMENT} not found; skipping live server env sync"
    return 0
  fi

  echo "[INFO] Syncing live server env..."
  local litellm_master_key
  local openai_base_url
  local openai_api_key
  local k8s_mcp_url
  local prom_mcp_url
  local chaos_namespace
  local pre_cleanup_wait_seconds

  litellm_master_key=$(read_env_value "LITELLM_MASTER_KEY")
  openai_base_url=$(read_env_value "OPENAI_BASE_URL")
  openai_api_key=$(read_env_value "OPENAI_API_KEY")
  model_alias=$(read_env_value "AZURE_OPENAI_DEPLOYMENT")
  k8s_mcp_url=$(read_env_value "K8S_MCP_URL")
  prom_mcp_url=$(read_env_value "PROM_MCP_URL")
  chaos_namespace=$(read_env_value "CHAOS_NAMESPACE")
  pre_cleanup_wait_seconds=$(read_env_value "PRE_CLEANUP_WAIT_SECONDS")

  if [ -z "${litellm_master_key}" ]; then
    litellm_master_key="sk-litellm-local-dev"
  fi

  if [ -z "${model_alias}" ]; then
    model_alias="gpt-4"
  fi

  if [ -z "${openai_base_url}" ]; then
    openai_base_url="http://litellm-proxy.litellm.svc.cluster.local:4000/v1"
  fi

  if [ -z "${openai_api_key}" ]; then
    openai_api_key="${litellm_master_key}"
  fi

  # Fail loud if MCP URLs are missing from .env — silent fallbacks here were the
  # root cause of "agent picks :9090 even though .env says :8083" regressions.
  # The operator must define these in .env; do NOT inject a guess.
  if [ -z "${k8s_mcp_url}" ]; then
    echo "[ERROR] K8S_MCP_URL missing from ${ENV_FILE}; refusing to patch server env with a guess" >&2
    exit 1
  fi

  if [ -z "${prom_mcp_url}" ]; then
    echo "[ERROR] PROM_MCP_URL missing from ${ENV_FILE}; refusing to patch server env with a guess" >&2
    exit 1
  fi

  if [ -z "${chaos_namespace}" ]; then
    chaos_namespace="litmus"
  fi

  if [ -z "${pre_cleanup_wait_seconds}" ]; then
    pre_cleanup_wait_seconds="0"
  fi

  kubectl set env deployment/"${SERVER_DEPLOYMENT}" -n "${SERVER_NAMESPACE}" \
    FLASH_AGENT_IMAGE="${IMAGE}" \
    LITELLM_MASTER_KEY="${litellm_master_key}" \
    OPENAI_API_KEY="${openai_api_key}" \
    OPENAI_BASE_URL="${openai_base_url}" \
    MODEL_ALIAS="${model_alias}" \
    K8S_MCP_URL="${k8s_mcp_url}" \
    PROM_MCP_URL="${prom_mcp_url}" \
    CHAOS_NAMESPACE="${chaos_namespace}" \
    PRE_CLEANUP_WAIT_SECONDS="${pre_cleanup_wait_seconds}" >/dev/null
  kubectl rollout status deployment/"${SERVER_DEPLOYMENT}" -n "${SERVER_NAMESPACE}" --timeout=120s >/dev/null
  echo "[OK] Live server env synced: FLASH_AGENT_IMAGE=${IMAGE} LITELLM_MASTER_KEY=<set>"
}

sync_live_flash_agent_workloads() {
  local namespace="sock-shop"
  local deployment="flash-agent"
  local cronjob="flash-agent-cronjob"

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "[WARN] kubectl not found; skipping flash-agent workload image sync"
    return 0
  fi

  if kubectl -n "${namespace}" get deployment "${deployment}" >/dev/null 2>&1; then
    echo "[INFO] Updating ${namespace}/${deployment} image to ${IMAGE}"
    kubectl -n "${namespace}" set image deployment/"${deployment}" agent="${IMAGE}" >/dev/null || true
    kubectl -n "${namespace}" rollout status deployment/"${deployment}" --timeout=120s >/dev/null || true
  else
    echo "[WARN] ${namespace}/${deployment} not found; skipping deployment image sync"
  fi

  if kubectl -n "${namespace}" get cronjob "${cronjob}" >/dev/null 2>&1; then
    echo "[INFO] Updating ${namespace}/${cronjob} image to ${IMAGE}"
    kubectl -n "${namespace}" set image cronjob/"${cronjob}" agent="${IMAGE}" >/dev/null || true
  else
    echo "[WARN] ${namespace}/${cronjob} not found; skipping cronjob image sync"
  fi

  echo "[OK] Flash-agent workloads synced to ${IMAGE}"
}

# Prune old agentcert-flash-agent images before building new one
echo "[INFO] Pruning old agentcert-flash-agent images..."
docker images | grep "agentcert-flash-agent" | grep -v "latest\|dev" | awk '{print $3}' | xargs -r docker rmi -f 2>/dev/null || true
docker image prune -f 2>/dev/null || true
echo "[OK] Old images pruned"

IMAGE_TAG="ci-$(date +%Y%m%d%H%M%S)"
IMAGE="agentcert/agentcert-flash-agent:${IMAGE_TAG}"

echo "[INFO] Building ${IMAGE}"
cd "${SCRIPT_DIR}"
docker build -t "${IMAGE}" -f Dockerfile .
docker tag "${IMAGE}" agentcert/agentcert-flash-agent:latest
docker tag "${IMAGE}" agentcert/agentcert-flash-agent:dev
echo "[OK] Docker build completed"

echo "[INFO] Cleaning up old images from minikube..."
# Remove old ci-* tags from minikube (keep only latest, dev, and the new one)
minikube image ls | grep "agentcert-flash-agent:ci-" | grep -v "${IMAGE_TAG}" | awk '{print $1}' | xargs -r minikube image rm 2>/dev/null || true
echo "[OK] Old minikube images cleaned"

echo "[INFO] Loading into minikube..."
minikube image load "${IMAGE}"
minikube image load agentcert/agentcert-flash-agent:latest
minikube image load agentcert/agentcert-flash-agent:dev
echo "[OK] Images loaded into minikube"

# Update .env with :latest tag instead of timestamped version
# This ensures consistent deployment across restarts and scales
LATEST_IMAGE="agentcert/agentcert-flash-agent:latest"

# Check if FLASH_AGENT_IMAGE exists in .env, if not add it
if grep -q "^FLASH_AGENT_IMAGE=" "${ENV_FILE}"; then
  sed -i "s|^FLASH_AGENT_IMAGE=.*|FLASH_AGENT_IMAGE=${LATEST_IMAGE}|" "${ENV_FILE}"
else
  # Add it after INSTALL_AGENT_IMAGE line
  sed -i "/^INSTALL_AGENT_IMAGE=/a FLASH_AGENT_IMAGE=${LATEST_IMAGE}" "${ENV_FILE}"
fi
echo "[OK] .env updated: FLASH_AGENT_IMAGE=${LATEST_IMAGE}"

# Update global variable for sync function
IMAGE="${LATEST_IMAGE}"
sync_live_server_env
sync_live_flash_agent_workloads
