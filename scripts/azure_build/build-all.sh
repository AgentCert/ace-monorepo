#!/bin/bash
set -euo pipefail

# Build all AgentCert Docker images and push to Docker Hub.
# NO cluster deployment — pure build + push only.
#
# Usage:
#   bash build-all.sh [--git] --llm 1 --env-file /path/to/.env --paths-file /path/to/build-paths.env
#
# --llm        1|azure / 2|openai / 3|all
# --env-file   path to your .env (default: <agentcert-root>/local-custom/config/.env)
# --paths-file path to build-paths.env (default: same dir as this script/build-paths.env)
# --git        clone (if missing) or git pull each repo before building

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE=""
PATHS_FILE="${SCRIPT_DIR}/build-paths.env"
LLM_ARG=""
GIT_SYNC=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --llm)        LLM_ARG="${2:-}";    shift 2 ;;
    --env-file)   ENV_FILE="${2:-}";   shift 2 ;;
    --paths-file) PATHS_FILE="${2:-}"; shift 2 ;;
    --git)        GIT_SYNC=true;       shift ;;
    *)            shift ;;
  esac
done

# ── Load paths file ────────────────────────────────────────────────────────────
if [[ ! -f "${PATHS_FILE}" ]]; then
  echo "[ERROR] Paths file not found: ${PATHS_FILE}" >&2
  echo "[ERROR] Copy azure_build/build-paths.env and update it for your environment." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${PATHS_FILE}"

# ── Git sync (clone or pull each repo) ────────────────────────────────────────
sync_repo() {
  local dir="$1" url="$2" branch="${3:-${GIT_BRANCH:-main}}"
  if [[ -z "${url}" ]]; then
    echo "[ERROR] --git used but no git URL configured for ${dir}" >&2
    exit 1
  fi
  if [[ -d "${dir}/.git" ]]; then
    echo "[INFO] git pull ${dir} (branch: ${branch})"
    # If the configured URL differs from the current remote, update it so
    # forks / mirrors are used instead of the originally-cloned upstream.
    local current_url
    current_url=$(git -C "${dir}" remote get-url origin 2>/dev/null || echo "")
    if [[ -n "${url}" && "${current_url}" != "${url}" ]]; then
      echo "[INFO] Updating remote origin: ${current_url} → ${url}"
      git -C "${dir}" remote set-url origin "${url}"
    fi
    git -C "${dir}" fetch origin
    git -C "${dir}" checkout "${branch}" 2>/dev/null || true
    git -C "${dir}" reset --hard "origin/${branch}"
  else
    echo "[INFO] git clone ${url} → ${dir} (branch: ${branch})"
    mkdir -p "$(dirname "${dir}")"
    git clone --branch "${branch}" --depth 1 "${url}" "${dir}"
  fi
}

if [[ "${GIT_SYNC}" == "true" ]]; then
  # ── Clean previous clones so we always get a fresh pull ─────────────────────
  echo "[INFO] Cleaning previous clones from /tmp before git sync..."
  for dir in "${AGENTCERT_ROOT}" "${APP_CHARTS_ROOT}" "${AGENT_CHARTS_ROOT}" "${FLASH_AGENT_ROOT}" "${CHAOS_CHARTS_ROOT:-}"; do
    if [[ -n "${dir}" && -d "${dir}" ]]; then
      echo "[INFO] Removing ${dir}"
      rm -rf "${dir}"
    fi
  done
  echo "[OK] Clean done"

  echo "[INFO] Syncing repos from git..."
  sync_repo "${AGENTCERT_ROOT}"    "${AGENTCERT_GIT_URL:-}"
  sync_repo "${APP_CHARTS_ROOT}"   "${APP_CHARTS_GIT_URL:-}"
  sync_repo "${AGENT_CHARTS_ROOT}" "${AGENT_CHARTS_GIT_URL:-}"
  sync_repo "${FLASH_AGENT_ROOT}"  "${FLASH_AGENT_GIT_URL:-}"
  # chaos-charts is consumed at runtime by the GraphQL server (DEFAULT_HUB_GIT_URL),
  # not by the Docker build pipeline.  We still sync it so the local clone stays
  # in lockstep with the URL exported by start-agentcert.sh / run.sh, which makes
  # local debugging (helm template, grep) match what the running cluster pulls.
  if [[ -n "${CHAOS_CHARTS_ROOT:-}" && -n "${CHAOS_CHARTS_GIT_URL:-}" ]]; then
    sync_repo "${CHAOS_CHARTS_ROOT}" "${CHAOS_CHARTS_GIT_URL}" "${CHAOS_CHARTS_GIT_BRANCH:-master}"
  fi
  echo "[OK] All repos synced"
fi

# ── Validate path vars ─────────────────────────────────────────────────────────
for var in AGENTCERT_ROOT APP_CHARTS_ROOT AGENT_CHARTS_ROOT FLASH_AGENT_ROOT; do
  if [[ -z "${!var:-}" ]]; then
    echo "[ERROR] ${var} is not set in ${PATHS_FILE}" >&2; exit 1
  fi
  if [[ ! -d "${!var}" ]]; then
    echo "[ERROR] ${var}=${!var} — directory not found" >&2; exit 1
  fi
done

# ── Default env file relative to AGENTCERT_ROOT ───────────────────────────────
if [[ -z "${ENV_FILE}" ]]; then
  ENV_FILE="${AGENTCERT_ROOT}/local-custom/config/.env"
fi
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[ERROR] Env file not found: ${ENV_FILE}" >&2; exit 1
fi

if [[ -n "${LLM_ARG}" ]]; then
  case "${LLM_ARG}" in
    1|azure)  export LITELLM_PROFILE="azure" ;;
    2|openai) export LITELLM_PROFILE="openai" ;;
    3|all)    export LITELLM_PROFILE="all" ;;
    *)
      echo "[ERROR] Unknown --llm value '${LLM_ARG}'. Use 1/azure, 2/openai, or 3/all." >&2
      exit 1 ;;
  esac
fi

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}   $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}  $*"; }

echo ""
echo -e "${CYAN}================================${NC}"
echo -e "${CYAN}AgentCert Docker Build Pipeline${NC}"
echo -e "${CYAN}================================${NC}"
echo ""
log_info "AGENTCERT_ROOT    = ${AGENTCERT_ROOT}"
log_info "APP_CHARTS_ROOT   = ${APP_CHARTS_ROOT}"
log_info "AGENT_CHARTS_ROOT = ${AGENT_CHARTS_ROOT}"
log_info "FLASH_AGENT_ROOT  = ${FLASH_AGENT_ROOT}"
log_info "ENV_FILE          = ${ENV_FILE}"
echo ""

# ── Step 1: Build app chart (Sock Shop) ───────────────────────────────────────
log_info "Starting: Build app chart (Sock Shop)"
if bash "${SCRIPT_DIR}/build-and-deploy-app-chart.sh" \
    --local-mode \
    --env-file "${ENV_FILE}" \
    --source-dir "${APP_CHARTS_ROOT}/install-app"; then
  log_success "Completed: Build app chart (Sock Shop)"
else
  log_error "Failed: Build app chart (Sock Shop)"; exit 1
fi
echo ""

# ── Step 2: Build LiteLLM proxy ───────────────────────────────────────────────
log_info "Starting: Build LiteLLM proxy"
if bash "${SCRIPT_DIR}/build-litellm.sh" --env-file "${ENV_FILE}"; then
  log_success "Completed: Build LiteLLM proxy"
else
  log_error "Failed: Build LiteLLM proxy"; exit 1
fi
echo ""

# ── Step 3: Build install-agent image ─────────────────────────────────────────
log_info "Starting: Build install-agent image"
if bash "${SCRIPT_DIR}/build-install-agent.sh" \
    --env-file "${ENV_FILE}" \
    --source-dir "${AGENT_CHARTS_ROOT}"; then
  log_success "Completed: Build install-agent image"
else
  log_error "Failed: Build install-agent image"; exit 1
fi
echo ""

# ── Step 4: Build agent-sidecar image ─────────────────────────────────────────
log_info "Starting: Build agent-sidecar image"
if bash "${SCRIPT_DIR}/build-agent-sidecar.sh" \
    --env-file "${ENV_FILE}" \
    --source-dir "${AGENT_SIDECAR_ROOT:-${AGENTCERT_ROOT}/../agent-sidecar}"; then
  log_success "Completed: Build agent-sidecar image"
else
  log_error "Failed: Build agent-sidecar image"; exit 1
fi
echo ""

# ── Step 5: Build flash-agent image ───────────────────────────────────────────
log_info "Starting: Build flash-agent image"
if bash "${SCRIPT_DIR}/build-flash-agent.sh" \
    --env-file "${ENV_FILE}" \
    --source-dir "${FLASH_AGENT_ROOT}"; then
  log_success "Completed: Build flash-agent image"
else
  log_error "Failed: Build flash-agent image"; exit 1
fi
echo ""

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}All builds completed successfully!${NC}"
echo -e "${GREEN}================================${NC}"
echo ""
