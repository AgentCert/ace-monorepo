#!/bin/bash
set -uo pipefail

# =============================================================================
# Start local supporting services: MongoDB, Langfuse, LiteLLM
# =============================================================================
# Idempotent — each service is only started if it isn't already running.
# Pulls LiteLLM env vars from <repo-root>/.env via `docker compose --env-file`.
#
# Usage:
#   ./scripts/start-local-services.sh [options]
#
# Options:
#   --skip-mongo                  Skip MongoDB
#   --skip-langfuse               Skip Langfuse
#   --skip-litellm                Skip LiteLLM
#   --only-mongo                  Run only MongoDB
#   --only-langfuse               Run only Langfuse
#   --only-litellm                Run only LiteLLM
#   --env-file PATH               .env to feed LiteLLM (default: <repo-root>/.env)
#   --langfuse-dir PATH           Langfuse compose dir (default: /opt/langfuse,
#                                 then ~/langfuse, then <repo-root>/.tmp/langfuse)
#   --restart                     Recreate services even if already running
#   -h, --help                    Show this help
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${REPO_ROOT}/.env"
LANGFUSE_DIR=""
RUN_MONGO=true
RUN_LANGFUSE=true
RUN_LITELLM=true
RESTART=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

usage() { awk '/^# ====/{c++; next} c>0 && c<3 {sub(/^# ?/,""); print}' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-mongo)    RUN_MONGO=false; shift ;;
        --skip-langfuse) RUN_LANGFUSE=false; shift ;;
        --skip-litellm)  RUN_LITELLM=false; shift ;;
        --only-mongo)    RUN_MONGO=true;  RUN_LANGFUSE=false; RUN_LITELLM=false; shift ;;
        --only-langfuse) RUN_MONGO=false; RUN_LANGFUSE=true;  RUN_LITELLM=false; shift ;;
        --only-litellm)  RUN_MONGO=false; RUN_LANGFUSE=false; RUN_LITELLM=true;  shift ;;
        --env-file)      ENV_FILE="${2:-}"; shift 2 ;;
        --langfuse-dir)  LANGFUSE_DIR="${2:-}"; shift 2 ;;
        --restart)       RESTART=true; shift ;;
        -h|--help)       usage ;;
        *)               log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

command -v docker >/dev/null 2>&1 || { log_error "docker not found"; exit 1; }
docker compose version >/dev/null 2>&1 || { log_error "'docker compose' plugin not available"; exit 1; }

port_in_use() { ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${1}$"; }
container_running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }
container_exists()  { docker ps -a --format '{{.Names}}' | grep -qx "$1"; }

# ---------------------------------------------------------------------------
# MongoDB
# ---------------------------------------------------------------------------
start_mongo() {
    log_info "MongoDB: checking port 27017 ..."
    if port_in_use 27017; then
        local existing
        existing=$(docker ps --filter "publish=27017" --format "{{.Names}}" | head -1)
        if [[ "${RESTART}" == true && -n "${existing}" ]]; then
            log_warn "Restarting MongoDB container '${existing}' ..."
            docker restart "${existing}" >/dev/null
        else
            log_success "MongoDB already up (${existing:-external listener on :27017})"
            return 0
        fi
    fi

    local name="agentcert-mongo"
    if container_exists "${name}"; then
        log_info "Starting existing container '${name}' ..."
        docker start "${name}" >/dev/null
    elif container_exists "m3"; then
        name="m3"
        log_info "Starting existing container '${name}' ..."
        docker start "${name}" >/dev/null
    else
        log_info "Creating new container '${name}' (mongo:4.2) ..."
        docker run -d --name "${name}" -p 27017:27017 mongo:4.2 >/dev/null
    fi

    local retries=0
    while (( retries < 15 )); do
        if docker exec "${name}" mongosh --quiet --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1 \
           || docker exec "${name}" mongo --eval 'db.adminCommand("ping")' >/dev/null 2>&1; then
            log_success "MongoDB ready on :27017"
            return 0
        fi
        sleep 1; ((retries++))
    done
    log_error "MongoDB did not become ready within 15s"
    return 1
}

# ---------------------------------------------------------------------------
# Langfuse
# ---------------------------------------------------------------------------
resolve_langfuse_dir() {
    if [[ -n "${LANGFUSE_DIR}" ]]; then
        [[ -f "${LANGFUSE_DIR}/docker-compose.yml" ]] && return 0
        log_error "No docker-compose.yml in --langfuse-dir: ${LANGFUSE_DIR}"
        return 1
    fi
    for cand in /opt/langfuse "${HOME}/langfuse" "${REPO_ROOT}/.tmp/langfuse"; do
        if [[ -f "${cand}/docker-compose.yml" ]]; then
            LANGFUSE_DIR="${cand}"; return 0
        fi
    done
    return 1
}

start_langfuse() {
    log_info "Langfuse: checking ..."
    if container_running langfuse-langfuse-web-1 && [[ "${RESTART}" == false ]]; then
        log_success "Langfuse already up (web: http://localhost:4000)"
        return 0
    fi

    if ! resolve_langfuse_dir; then
        local clone_dir="${REPO_ROOT}/.tmp/langfuse"
        log_warn "No Langfuse checkout found — cloning upstream into ${clone_dir} ..."
        mkdir -p "$(dirname "${clone_dir}")"
        if ! git clone --depth 1 https://github.com/langfuse/langfuse.git "${clone_dir}"; then
            log_error "git clone of langfuse failed"
            return 1
        fi
        LANGFUSE_DIR="${clone_dir}"
    fi

    log_info "Starting Langfuse compose stack from ${LANGFUSE_DIR} ..."
    if ! (cd "${LANGFUSE_DIR}" && docker compose up -d); then
        log_error "Langfuse compose up failed"
        return 1
    fi
    log_success "Langfuse up. Web UI: http://localhost:4000"
}

# ---------------------------------------------------------------------------
# LiteLLM
# ---------------------------------------------------------------------------
start_litellm() {
    log_info "LiteLLM: checking ..."
    local compose_dir="${REPO_ROOT}/agentcert-stack/litellm-setup"
    local compose_file="${compose_dir}/docker-compose-litellm.yml"

    if [[ ! -f "${compose_file}" ]]; then
        log_error "Compose file not found: ${compose_file}"
        return 1
    fi
    if [[ ! -f "${ENV_FILE}" ]]; then
        log_error "LiteLLM needs an env file (got: ${ENV_FILE}) for AZURE_OPENAI_*, LANGFUSE_*, etc."
        return 1
    fi

    if container_running litellm-proxy && [[ "${RESTART}" == false ]]; then
        log_success "LiteLLM already up (proxy: http://localhost:14000)"
        return 0
    fi

    log_info "Starting LiteLLM proxy with env-file ${ENV_FILE} ..."
    if ! (cd "${compose_dir}" && docker compose --env-file "${ENV_FILE}" -f docker-compose-litellm.yml up -d); then
        log_error "LiteLLM compose up failed"
        return 1
    fi
    log_success "LiteLLM up. Proxy: http://localhost:14000"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN}  Local supporting services${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

FAILED=()
run_step() {
    local label="$1"; shift
    if ! "$@"; then FAILED+=("${label}"); fi
    echo ""
}
[[ "${RUN_MONGO}"    == true ]] && run_step mongo    start_mongo
[[ "${RUN_LANGFUSE}" == true ]] && run_step langfuse start_langfuse
[[ "${RUN_LITELLM}"  == true ]] && run_step litellm  start_litellm

echo -e "${CYAN}======================================${NC}"
if (( ${#FAILED[@]} == 0 )); then
    log_success "All requested services are up."
else
    log_warn "Failed: ${FAILED[*]}"
    exit 1
fi
