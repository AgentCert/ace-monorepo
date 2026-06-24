#!/bin/bash
set -euo pipefail

# =============================================================================
# Build & Push All Docker Images
# =============================================================================
# Builds all AgentCert component images and pushes them to IMAGE_REGISTRY.
# Reads IMAGE_REGISTRY, REGISTRY_USERNAME, REGISTRY_PASSWORD from .env.
# Falls back to DOCKERHUB_USERNAME / DOCKERHUB_TOKEN for backwards compatibility.
#
# Usage:
#   ./scripts/build-and-push.sh [--env-file PATH]
#
# Options:
#   --env-file PATH   Path to env file (default: <repo-root>/.env)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${REPO_ROOT}/.env"

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

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)
            ENV_FILE="${2:-}"
            shift 2
            ;;
        --help|-h)
            head -14 "$0" | tail -12
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"; exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
    log_error "Env file not found: ${ENV_FILE}"
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    log_error "docker not found"
    exit 1
fi

# ---------------------------------------------------------------------------
# Registry login
# ---------------------------------------------------------------------------
# PUSH_REGISTRY = where images are pushed (docker-remote is read-only proxy)
# Falls back to docker.io if not set in .env
PUSH_REGISTRY="$(grep -m1 '^PUSH_REGISTRY=' "${ENV_FILE}" | cut -d= -f2-)"
PUSH_REGISTRY="${PUSH_REGISTRY:-docker.io}"
IMAGE_REGISTRY="${PUSH_REGISTRY}"

# Generic credentials — fall back to legacy DOCKERHUB_ vars if not set:
REGISTRY_USERNAME="$(grep -m1 '^REGISTRY_USERNAME=' "${ENV_FILE}" | cut -d= -f2-)"
REGISTRY_PASSWORD="$(grep -m1 '^REGISTRY_PASSWORD=' "${ENV_FILE}" | cut -d= -f2-)"
if [[ -z "${REGISTRY_USERNAME}" ]]; then
    REGISTRY_USERNAME="$(grep -m1 '^DOCKERHUB_USERNAME=' "${ENV_FILE}" | cut -d= -f2-)"
    REGISTRY_PASSWORD="$(grep -m1 '^DOCKERHUB_TOKEN=' "${ENV_FILE}" | cut -d= -f2-)"
fi

if [[ -z "${REGISTRY_USERNAME}" || -z "${REGISTRY_PASSWORD}" ]]; then
    log_error "REGISTRY_USERNAME/REGISTRY_PASSWORD (or DOCKERHUB_USERNAME/DOCKERHUB_TOKEN) not set in ${ENV_FILE}"
    exit 1
fi

echo "${REGISTRY_PASSWORD}" | docker login "${IMAGE_REGISTRY}" -u "${REGISTRY_USERNAME}" --password-stdin || {
    log_error "Registry login failed for ${IMAGE_REGISTRY}"
    exit 1
}
log_success "Logged in to ${IMAGE_REGISTRY} as ${REGISTRY_USERNAME}"

# ---------------------------------------------------------------------------
# Image definitions: (name, context_dir, dockerfile)
# ---------------------------------------------------------------------------
declare -a IMAGES=(
    "${IMAGE_REGISTRY}/agentcert/agentcert-flash-agent|${REPO_ROOT}/flash-agent|Dockerfile"
    "${IMAGE_REGISTRY}/agentcert/agent-sidecar|${REPO_ROOT}/agent-sidecar|Dockerfile"
    "${IMAGE_REGISTRY}/agentcert/agentcert-install-agent|${REPO_ROOT}/agent-charts|install-agent/Dockerfile"
    "${IMAGE_REGISTRY}/agentcert/agentcert-install-app|${REPO_ROOT}/app-charts|install-app/Dockerfile"
    "${IMAGE_REGISTRY}/agentcert/certifier|${REPO_ROOT}/certifier|Dockerfile"
)

# ---------------------------------------------------------------------------
# Build & Push
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN}  Build & Push All Images → ${IMAGE_REGISTRY}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

FAILED=()

for entry in "${IMAGES[@]}"; do
    IFS='|' read -r img_name context_dir dockerfile <<< "$entry"
    
    if [[ ! -f "${context_dir}/${dockerfile}" ]]; then
        log_warn "Dockerfile not found: ${context_dir}/${dockerfile} — skipping ${img_name}"
        FAILED+=("${img_name} (no Dockerfile)")
        continue
    fi

    log_info "Building ${img_name}:latest ..."
    if docker build -t "${img_name}:latest" -f "${context_dir}/${dockerfile}" "${context_dir}"; then
        log_success "Built: ${img_name}:latest"
    else
        log_error "Build failed: ${img_name}"
        FAILED+=("${img_name} (build)")
        continue
    fi

    log_info "Pushing ${img_name}:latest ..."
    if docker push "${img_name}:latest"; then
        log_success "Pushed: ${img_name}:latest"
    else
        log_error "Push failed: ${img_name}"
        FAILED+=("${img_name} (push)")
    fi

    echo ""
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo -e "${CYAN}======================================${NC}"
if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo -e "${GREEN}  All images built and pushed!${NC}"
else
    echo -e "${YELLOW}  Completed with failures:${NC}"
    for f in "${FAILED[@]}"; do
        echo -e "    ${RED}✗${NC} $f"
    done
fi
echo -e "${CYAN}======================================${NC}"

[[ ${#FAILED[@]} -eq 0 ]]
