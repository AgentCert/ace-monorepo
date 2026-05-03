#!/bin/bash
set -euo pipefail

# =============================================================================
# ace-monorepo Build Pipeline
# =============================================================================
# Orchestrates building all AgentCert components from the monorepo.
#
# Submodule structure:
#   - AgentCert/              Platform (auth, graphql, frontend, chaoscenter)
#   - flash-agent/            LLM-powered ITOps agent
#   - agent-sidecar/          Metadata injection proxy
#   - agent-charts/           Agent Helm charts + install-agent CLI
#   - app-charts/             Target app charts + install-app CLI
#   - agentcert-stack/        LiteLLM and infrastructure configs
#   - certifier/              Certification report generator
#   - chaos-charts/           Litmus chaos experiment definitions
#
# Usage:
#   ./build-all.sh [options]
#
# Options:
#   --llm 1|azure|2|openai|3|all   LiteLLM provider profile
#   --env-file PATH                Environment file (default: AgentCert/local-custom/config/.env)
#   --context NAME                 Required kubectl context
#   --skip-app-chart               Skip building app chart
#   --skip-cluster-deploy          Skip cluster deployment sync
#   --only-images                  Only build Docker images (skip deploy steps)
#   --help                         Show this help
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Submodule paths (relative to monorepo root)
AGENTCERT_DIR="${SCRIPT_DIR}/AgentCert"
FLASH_AGENT_DIR="${SCRIPT_DIR}/flash-agent"
AGENT_SIDECAR_DIR="${SCRIPT_DIR}/agent-sidecar"
AGENT_CHARTS_DIR="${SCRIPT_DIR}/agent-charts"
APP_CHARTS_DIR="${SCRIPT_DIR}/app-charts"
AGENTCERT_STACK_DIR="${SCRIPT_DIR}/agentcert-stack"
CERTIFIER_DIR="${SCRIPT_DIR}/certifier"

# Defaults
ENV_FILE="${AGENTCERT_DIR}/local-custom/config/.env"
TARGET_CONTEXT=""
SKIP_APP_CHART="false"
SKIP_CLUSTER_DEPLOY="false"
ONLY_IMAGES="false"
LLM_ARG=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

show_help() {
    head -35 "$0" | tail -30
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --llm)
            [[ -z "${2:-}" ]] && { log_error "Missing value for --llm"; exit 1; }
            LLM_ARG="$2"
            shift 2
            ;;
        --env-file)
            [[ -z "${2:-}" ]] && { log_error "Missing value for --env-file"; exit 1; }
            ENV_FILE="$2"
            shift 2
            ;;
        --context)
            [[ -z "${2:-}" ]] && { log_error "Missing value for --context"; exit 1; }
            TARGET_CONTEXT="$2"
            shift 2
            ;;
        --skip-app-chart)
            SKIP_APP_CHART="true"
            shift
            ;;
        --skip-cluster-deploy)
            SKIP_CLUSTER_DEPLOY="true"
            shift
            ;;
        --only-images)
            ONLY_IMAGES="true"
            SKIP_APP_CHART="true"
            SKIP_CLUSTER_DEPLOY="true"
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            log_error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Export LiteLLM profile if specified
if [[ -n "${LLM_ARG}" ]]; then
    case "${LLM_ARG}" in
        1|azure)  export LITELLM_PROFILE="azure" ;;
        2|openai) export LITELLM_PROFILE="openai" ;;
        3|all)    export LITELLM_PROFILE="all" ;;
        *)
            log_error "Unknown --llm value '${LLM_ARG}'. Use 1/azure, 2/openai, or 3/all."
            exit 1
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    log_info "Running preflight checks..."
    
    # Check required commands
    for cmd in bash docker kubectl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done

    # Check env file
    if [[ ! -f "${ENV_FILE}" ]]; then
        log_error "Env file not found: ${ENV_FILE}"
        exit 1
    fi
    log_info "Using env file: ${ENV_FILE}"

    # Check kubectl context
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "kubectl cannot reach cluster"
        exit 1
    fi
    
    local current_context
    current_context="$(kubectl config current-context 2>/dev/null || true)"
    log_info "kubectl context: ${current_context}"
    
    if [[ -n "${TARGET_CONTEXT}" && "${TARGET_CONTEXT}" != "${current_context}" ]]; then
        log_error "Context mismatch. Expected '${TARGET_CONTEXT}', got '${current_context}'"
        exit 1
    fi

    # Check submodule directories exist
    local missing=()
    [[ ! -d "${FLASH_AGENT_DIR}" ]] && missing+=("flash-agent")
    [[ ! -d "${AGENT_SIDECAR_DIR}" ]] && missing+=("agent-sidecar")
    [[ ! -d "${AGENT_CHARTS_DIR}" ]] && missing+=("agent-charts")
    [[ ! -d "${APP_CHARTS_DIR}" ]] && missing+=("app-charts")
    [[ ! -d "${AGENTCERT_STACK_DIR}" ]] && missing+=("agentcert-stack")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing submodules: ${missing[*]}"
        log_info "Run: git submodule update --init --recursive"
        exit 1
    fi

    # Check build scripts exist
    [[ ! -f "${FLASH_AGENT_DIR}/build-flash-agent.sh" ]] && log_warn "Missing: flash-agent/build-flash-agent.sh"
    [[ ! -f "${AGENT_SIDECAR_DIR}/build-agent-sidecar.sh" ]] && log_warn "Missing: agent-sidecar/build-agent-sidecar.sh"
    [[ ! -f "${AGENT_CHARTS_DIR}/install-agent/build-install-agent.sh" ]] && log_warn "Missing: agent-charts/install-agent/build-install-agent.sh"
    [[ ! -f "${APP_CHARTS_DIR}/install-app/build-install-app.sh" ]] && log_warn "Missing: app-charts/install-app/build-install-app.sh"
    [[ ! -f "${AGENTCERT_STACK_DIR}/litellm-setup/build-litellm.sh" ]] && log_warn "Missing: agentcert-stack/litellm-setup/build-litellm.sh"

    log_success "Preflight checks passed"
}

# ---------------------------------------------------------------------------
# Build functions
# ---------------------------------------------------------------------------
build_app_chart() {
    if [[ "${SKIP_APP_CHART}" == "true" ]]; then
        log_info "Skipping app chart build (--skip-app-chart)"
        return 0
    fi
    
    log_info "Building app chart (sock-shop)..."
    local script="${APP_CHARTS_DIR}/install-app/build-and-deploy-app-chart.sh"
    if [[ -f "$script" ]]; then
        if bash "$script" --local-mode; then
            log_success "App chart built"
        else
            log_error "App chart build failed"
            return 1
        fi
    else
        log_warn "build-and-deploy-app-chart.sh not found, skipping"
    fi
}

build_litellm() {
    log_info "Building LiteLLM proxy..."
    local script="${AGENTCERT_STACK_DIR}/litellm-setup/build-litellm.sh"
    if [[ -f "$script" ]]; then
        if bash "$script" --env-file "${ENV_FILE}"; then
            log_success "LiteLLM built"
        else
            log_error "LiteLLM build failed"
            return 1
        fi
    else
        log_warn "build-litellm.sh not found, skipping"
    fi
}

build_install_agent() {
    log_info "Building install-agent image..."
    local script="${AGENT_CHARTS_DIR}/install-agent/build-install-agent.sh"
    if [[ -f "$script" ]]; then
        if DOCKER_BUILDKIT=1 bash "$script" --env-file "${ENV_FILE}"; then
            log_success "install-agent built"
        else
            log_error "install-agent build failed"
            return 1
        fi
    else
        # Fallback to Makefile
        if [[ -f "${AGENT_CHARTS_DIR}/install-agent/Makefile" ]]; then
            if make -C "${AGENT_CHARTS_DIR}/install-agent" build; then
                log_success "install-agent built (via Makefile)"
            else
                log_error "install-agent build failed"
                return 1
            fi
        else
            log_warn "No build script or Makefile for install-agent"
        fi
    fi
}

build_install_app() {
    log_info "Building install-app image..."
    local script="${APP_CHARTS_DIR}/install-app/build-install-app.sh"
    if [[ -f "$script" ]]; then
        if bash "$script" --env-file "${ENV_FILE}"; then
            log_success "install-app built"
        else
            log_error "install-app build failed"
            return 1
        fi
    else
        if [[ -f "${APP_CHARTS_DIR}/install-app/Makefile" ]]; then
            if make -C "${APP_CHARTS_DIR}/install-app" build; then
                log_success "install-app built (via Makefile)"
            else
                log_error "install-app build failed"
                return 1
            fi
        else
            log_warn "No build script or Makefile for install-app"
        fi
    fi
}

build_agent_sidecar() {
    log_info "Building agent-sidecar image..."
    local script="${AGENT_SIDECAR_DIR}/build-agent-sidecar.sh"
    if [[ -f "$script" ]]; then
        if bash "$script" --env-file "${ENV_FILE}"; then
            log_success "agent-sidecar built"
        else
            log_error "agent-sidecar build failed"
            return 1
        fi
    else
        if [[ -f "${AGENT_SIDECAR_DIR}/Makefile" ]]; then
            if make -C "${AGENT_SIDECAR_DIR}" build; then
                log_success "agent-sidecar built (via Makefile)"
            else
                log_error "agent-sidecar build failed"
                return 1
            fi
        else
            log_warn "No build script or Makefile for agent-sidecar"
        fi
    fi
}

build_flash_agent() {
    log_info "Building flash-agent image..."
    local script="${FLASH_AGENT_DIR}/build-flash-agent.sh"
    if [[ -f "$script" ]]; then
        if bash "$script" --env-file "${ENV_FILE}"; then
            log_success "flash-agent built"
        else
            log_error "flash-agent build failed"
            return 1
        fi
    else
        if [[ -f "${FLASH_AGENT_DIR}/Makefile" ]]; then
            if make -C "${FLASH_AGENT_DIR}" build; then
                log_success "flash-agent built (via Makefile)"
            else
                log_error "flash-agent build failed"
                return 1
            fi
        else
            log_warn "No build script or Makefile for flash-agent"
        fi
    fi
}

build_certifier() {
    log_info "Building certifier image..."
    if [[ -f "${CERTIFIER_DIR}/Makefile" ]]; then
        if make -C "${CERTIFIER_DIR}" build; then
            log_success "certifier built"
        else
            log_error "certifier build failed"
            return 1
        fi
    else
        log_warn "No Makefile for certifier, skipping"
    fi
}

sync_cluster_deploy() {
    if [[ "${SKIP_CLUSTER_DEPLOY}" == "true" ]]; then
        log_info "Skipping cluster deploy (--skip-cluster-deploy)"
        return 0
    fi
    
    log_info "Syncing cluster deployment..."
    local scripts_dir="${AGENTCERT_DIR}/local-custom/scripts"
    if [[ -d "$scripts_dir" ]]; then
        local deploy_script="build-and-deploy.sh"
        if [[ -f "${scripts_dir}/${deploy_script}" ]]; then
            if bash "${scripts_dir}/${deploy_script}" --env-file "${ENV_FILE}"; then
                log_success "Cluster deployment synced"
            else
                log_warn "Cluster deployment sync failed (non-fatal)"
            fi
        fi
    else
        log_warn "Deploy scripts directory not found: ${scripts_dir}"
    fi
}

load_images_to_kind() {
    log_info "Loading images into kind cluster..."
    local cluster_name="${KIND_CLUSTER_NAME:-agentcert}"
    
    for img in \
        "agentcert/agentcert-flash-agent:latest" \
        "agentcert/agent-sidecar:latest" \
        "agentcert/agentcert-install-agent:latest" \
        "agentcert/agentcert-install-app:latest" \
        "agentcert/certifier:latest"
    do
        if docker image inspect "$img" >/dev/null 2>&1; then
            kind load docker-image "$img" --name "$cluster_name" 2>/dev/null && \
                log_success "Loaded: $img" || \
                log_warn "Failed to load: $img"
        fi
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN}  ace-monorepo Build Pipeline${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

preflight_checks

echo ""

# Build sequence
if [[ "${ONLY_IMAGES}" == "false" ]]; then
    build_app_chart
    echo ""
    sync_cluster_deploy
    echo ""
fi

build_litellm
echo ""

build_install_agent
echo ""

build_install_app
echo ""

build_agent_sidecar
echo ""

build_flash_agent
echo ""

build_certifier
echo ""

# Load into kind if available
if command -v kind >/dev/null 2>&1; then
    load_images_to_kind
    echo ""
fi

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  All builds completed successfully!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
