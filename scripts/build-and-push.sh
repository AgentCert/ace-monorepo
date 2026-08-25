#!/bin/bash
set -euo pipefail

# =============================================================================
# Build & Push All Docker Images to Docker Hub
# =============================================================================
# Builds all AgentCert component images and pushes them to Docker Hub.
# Reads DOCKERHUB_USERNAME and DOCKERHUB_TOKEN from the root .env file.
#
# Usage:
#   ./scripts/build-and-push.sh [--env-file PATH] [--local] [--kind-load]
#
# Options:
#   --env-file PATH   Path to env file (default: <repo-root>/.env)
#   --local           Build only — skip Docker Hub login and push
#   --kind-load       After building, load each image into the local KinD cluster
#                     (reads KIND_CLUSTER_NAME / ACE_INSTANCE_NAME from .env;
#                      implies --local)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${REPO_ROOT}/.env"
LOCAL_ONLY=false
KIND_LOAD=false

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
        --local)
            LOCAL_ONLY=true
            shift
            ;;
        --kind-load)
            KIND_LOAD=true
            LOCAL_ONLY=true
            shift
            ;;
        --help|-h)
            head -18 "$0" | tail -16
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
# KinD cluster name (used with --kind-load)
# ---------------------------------------------------------------------------
if [[ "${KIND_LOAD}" == true ]]; then
    if ! command -v kind >/dev/null 2>&1; then
        log_error "kind not found — cannot use --kind-load"
        exit 1
    fi
    ACE_INSTANCE="$(grep -m1 '^ACE_INSTANCE_NAME=' "${ENV_FILE}" | cut -d= -f2-)"
    KIND_CLUSTER="${KIND_CLUSTER_NAME:-agentcert-${ACE_INSTANCE}}"
    if [[ -z "${ACE_INSTANCE}" ]]; then
        log_error "ACE_INSTANCE_NAME not set in ${ENV_FILE}"
        exit 1
    fi
    log_info "KinD cluster: ${KIND_CLUSTER}"
fi

# ---------------------------------------------------------------------------
# Image → Kubernetes deployment map (for --kind-load pod restart)
# Only images that run as persistent Deployments are listed here.
# Workflow-step images (install-agent, install-app) and per-experiment images
# (flash-agent, agent-sidecar) are excluded — they have no running Deployment
# to restart.
# Format: image_name → "namespace/deployment-name"
# ---------------------------------------------------------------------------
declare -A IMAGE_DEPLOY_MAP=(
    ["agentcert/agentcert-auth"]="ace/auth"
    ["agentcert/agentcert-graphql"]="ace/graphql"
    ["agentcert/agentcert-web"]="ace/web"
    ["agentcert/certifier"]="ace/certifier"
)

# Restart a deployment after kind-loading its image so running pods pick up
# the new image immediately (kind load replaces the containerd cache entry,
# but IfNotPresent won't restart already-running pods on its own).
restart_deployment() {
    local img_name="$1"
    local target="${IMAGE_DEPLOY_MAP[$img_name]:-}"
    [[ -z "${target}" ]] && return 0   # no persistent deployment for this image

    local ns="${target%%/*}"
    local deploy="${target##*/}"

    if ! kubectl get deployment "${deploy}" -n "${ns}" &>/dev/null; then
        log_warn "Deployment ${deploy} not found in namespace ${ns} — skipping restart"
        return 0
    fi

    log_info "Restarting deployment/${deploy} in ${ns} to pick up new image ..."
    if kubectl rollout restart "deployment/${deploy}" -n "${ns}"; then
        log_success "Restarted: deployment/${deploy} (${ns})"
        RESTARTED_DEPLOYMENTS+=("${ns}/${deploy}")
    else
        log_warn "Rollout restart failed for deployment/${deploy} — pods may still use the old image"
    fi
}

# ---------------------------------------------------------------------------
# Docker Hub login (skipped in --local mode)
# ---------------------------------------------------------------------------
if [[ "${LOCAL_ONLY}" == false ]]; then
    DH_USER="$(grep -m1 '^DOCKERHUB_USERNAME=' "${ENV_FILE}" | cut -d= -f2-)"
    DH_TOKEN="$(grep -m1 '^DOCKERHUB_TOKEN=' "${ENV_FILE}" | cut -d= -f2-)"

    if [[ -z "${DH_USER}" || -z "${DH_TOKEN}" ]]; then
        log_error "DOCKERHUB_USERNAME or DOCKERHUB_TOKEN not set in ${ENV_FILE}"
        exit 1
    fi

    echo "${DH_TOKEN}" | docker login -u "${DH_USER}" --password-stdin || {
        log_error "Docker Hub login failed"
        exit 1
    }
    log_success "Logged in to Docker Hub as ${DH_USER}"
fi

# ---------------------------------------------------------------------------
# Image definitions: (name, context_dir, dockerfile, tag)
#
# `tag` is optional and defaults to "latest" when omitted (the 4th field is
# simply absent from most entries below). itbench-experiment is the one
# exception: every chaos-charts/faults/itbench/*/fault.yaml hardcodes the
# image reference as "agentcert/itbench-experiment:dev" (not :latest), so it
# must be built/pushed under that exact tag or nothing referencing it would
# actually resolve. NOTE: this entry exists so the image *can* be published
# on request, but ITBENCH_EXPERIMENT_IMAGE_SOURCE currently defaults to
# `local` (scripts/prepare-images.sh) precisely because this has never
# actually been pushed to Docker Hub — see OPEN_WEIGHT_CERTIFICATION_HANDOFF.md
# for the exact steps to flip that over once it has been.
# ---------------------------------------------------------------------------
declare -a IMAGES=(
    "agentcert/agentcert-flash-agent|${REPO_ROOT}/agents/flash-agent|Dockerfile"
    "agentcert/agent-sidecar|${REPO_ROOT}/agent-sidecar|Dockerfile"
    "agentcert/agentcert-install-agent|${REPO_ROOT}/agent-charts|install-agent/Dockerfile"
    "agentcert/agentcert-install-app|${REPO_ROOT}/app-charts|install-app/Dockerfile"
    "agentcert/certifier|${REPO_ROOT}/certifier|Dockerfile"
    "agentcert/agentcert-graphql|${REPO_ROOT}/AgentCert/chaoscenter/graphql|server/Dockerfile"
    "agentcert/agentcert-auth|${REPO_ROOT}/AgentCert/chaoscenter/authentication|Dockerfile"
    "agentcert/agentcert-web|${REPO_ROOT}/AgentCert/chaoscenter/web|Dockerfile"
    "agentcert/itbench-experiment|${REPO_ROOT}/litmus-go|build/Dockerfile.itbench|dev"
)

# ---------------------------------------------------------------------------
# Build (+ optional push / kind-load)
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}======================================${NC}"
if [[ "${KIND_LOAD}" == true ]]; then
    echo -e "${CYAN}  Build & Load into KinD${NC}"
elif [[ "${LOCAL_ONLY}" == true ]]; then
    echo -e "${CYAN}  Build Only (local)${NC}"
else
    echo -e "${CYAN}  Build & Push All Images${NC}"
fi
echo -e "${CYAN}======================================${NC}"
echo ""

FAILED=()
RESTARTED_DEPLOYMENTS=()

for entry in "${IMAGES[@]}"; do
    IFS='|' read -r img_name context_dir dockerfile tag <<< "$entry"
    tag="${tag:-latest}"
    full_ref="${img_name}:${tag}"

    if [[ ! -f "${context_dir}/${dockerfile}" ]]; then
        log_warn "Dockerfile not found: ${context_dir}/${dockerfile} — skipping ${img_name}"
        FAILED+=("${img_name} (no Dockerfile)")
        continue
    fi

    log_info "Building ${full_ref} ..."
    if docker build -t "${full_ref}" -f "${context_dir}/${dockerfile}" "${context_dir}"; then
        log_success "Built: ${full_ref}"
    else
        log_error "Build failed: ${img_name}"
        FAILED+=("${img_name} (build)")
        continue
    fi

    if [[ "${KIND_LOAD}" == true ]]; then
        log_info "Loading ${full_ref} into KinD cluster ${KIND_CLUSTER} ..."
        if kind load docker-image "${full_ref}" --name "${KIND_CLUSTER}"; then
            log_success "Loaded: ${full_ref}"
            # Restart the matching deployment so running pods immediately use the
            # new image — kind load replaces the containerd cache entry but
            # IfNotPresent won't restart already-running pods on its own.
            restart_deployment "${img_name}"
        else
            log_error "kind load failed: ${img_name}"
            FAILED+=("${img_name} (kind-load)")
        fi
    elif [[ "${LOCAL_ONLY}" == false ]]; then
        log_info "Pushing ${full_ref} ..."
        if docker push "${full_ref}"; then
            log_success "Pushed: ${full_ref}"
        else
            log_error "Push failed: ${img_name}"
            FAILED+=("${img_name} (push)")
        fi
    fi

    echo ""
done

# ---------------------------------------------------------------------------
# Wait for restarted deployments to finish rolling out
# ---------------------------------------------------------------------------
if [[ ${#RESTARTED_DEPLOYMENTS[@]} -gt 0 ]]; then
    echo ""
    log_info "Waiting for rollouts to complete ..."
    for target in "${RESTARTED_DEPLOYMENTS[@]}"; do
        ns="${target%%/*}"
        deploy="${target##*/}"
        if kubectl rollout status "deployment/${deploy}" -n "${ns}" --timeout=120s; then
            log_success "Rollout complete: deployment/${deploy} (${ns})"
        else
            log_warn "Rollout timed out for deployment/${deploy} — check: kubectl get pods -n ${ns}"
        fi
    done
    echo ""
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo -e "${CYAN}======================================${NC}"
if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo -e "${GREEN}  All images built successfully!${NC}"
else
    echo -e "${YELLOW}  Completed with failures:${NC}"
    for f in "${FAILED[@]}"; do
        echo -e "    ${RED}✗${NC} $f"
    done
fi
echo -e "${CYAN}======================================${NC}"

[[ ${#FAILED[@]} -eq 0 ]]
