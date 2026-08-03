#!/usr/bin/env bash
# prepare-images.sh — build, load, or configure registry credentials for
# experiment workflow images based on *_IMAGE_SOURCE settings in .env.
#
# Called automatically by setup.sh when any source is non-default.
# Safe to run standalone at any time to rebuild / reload / re-create secrets.
#
# Reads from .env:
#   INSTALL_APP_IMAGE_SOURCE    dockerhub | jfrog | local
#   INSTALL_AGENT_IMAGE_SOURCE  dockerhub | jfrog | local
#   LITMUS_IMAGES_SOURCE        dockerhub | local
#   JFROG_HOST, JFROG_REGISTRY_PATH, JFROG_USER, JFROG_TOKEN
#   KIND_CLUSTER_NAME, ACE_INSTANCE_NAME
#   APP_CHARTS_ROOT, AGENT_CHARTS_ROOT  (set by setup.sh to absolute paths)
#
# For "local":
#   install-app / install-agent  — docker build from source + kind load
#   litmuschaos images           — docker pull from Docker Hub + kind load
# For "jfrog":
#   Creates a docker-registry Secret and patches the argo-chaos ServiceAccount
#   in every experiment namespace that exists on the cluster.
# For "dockerhub":
#   No action (Kubernetes pulls at runtime; IfNotPresent reuses cached copies).

set -euo pipefail

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
info() { echo -e "${CYAN}▸${NC} $*"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: ${ENV_FILE} not found — run scripts/setup.sh first." >&2
    exit 1
fi

cur() { grep -E "^${1}=" "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2-; }

APP_SRC="$(cur INSTALL_APP_IMAGE_SOURCE)"
AGENT_SRC="$(cur INSTALL_AGENT_IMAGE_SOURCE)"
LITMUS_SRC="$(cur LITMUS_IMAGES_SOURCE)"

APP_SRC="${APP_SRC:-dockerhub}"
AGENT_SRC="${AGENT_SRC:-dockerhub}"
LITMUS_SRC="${LITMUS_SRC:-dockerhub}"

JFROG_HOST="$(cur JFROG_HOST)"; JFROG_HOST="${JFROG_HOST:-infyartifactory.jfrog.io}"
JFROG_PATH="$(cur JFROG_REGISTRY_PATH)"; JFROG_PATH="${JFROG_PATH:-docker-local}"
JFROG_USER="$(cur JFROG_USER)"
JFROG_TOKEN="$(cur JFROG_TOKEN)"

APP_CHARTS_ROOT="$(cur APP_CHARTS_ROOT)"; APP_CHARTS_ROOT="${APP_CHARTS_ROOT:-${REPO_ROOT}/app-charts}"
AGENT_CHARTS_ROOT="$(cur AGENT_CHARTS_ROOT)"; AGENT_CHARTS_ROOT="${AGENT_CHARTS_ROOT:-${REPO_ROOT}/agent-charts}"

# Resolve KinD cluster name (mirrors logic in setup.sh / ensure_kind_cluster)
KIND_CLUSTER_NAME="$(cur KIND_CLUSTER_NAME)"
if [[ -z "${KIND_CLUSTER_NAME}" ]]; then
    ACE_INSTANCE="$(cur ACE_INSTANCE_NAME)"
    KIND_CLUSTER_NAME="agentcert${ACE_INSTANCE:+-${ACE_INSTANCE}}"
fi

echo
echo -e "${CYAN}=======================================================${NC}"
echo -e "${CYAN}  Preparing experiment images${NC}"
echo -e "${CYAN}  install-app: ${APP_SRC}   install-agent: ${AGENT_SRC}   litmus: ${LITMUS_SRC}${NC}"
echo -e "${CYAN}=======================================================${NC}"
echo

# ─── helpers ─────────────────────────────────────────────────────────────────

kind_load() {
    local img="$1"
    if kind get clusters 2>/dev/null | grep -qxF "${KIND_CLUSTER_NAME}"; then
        if kind load docker-image "${img}" --name "${KIND_CLUSTER_NAME}"; then
            ok "kind load: ${img} → cluster '${KIND_CLUSTER_NAME}'"
        else
            warn "kind load failed for ${img} — pods will pull from registry at runtime"
        fi
    else
        warn "KinD cluster '${KIND_CLUSTER_NAME}' not found — skipping kind load for ${img}"
        warn "Re-run this script after the cluster is created."
    fi
}

# Namespaces where LitmusChaos experiment workflows run.
# The argo-chaos service account and any pull secrets must exist in each.
experiment_namespaces() {
    kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
        | tr ' ' '\n' \
        | grep -E '^(itbench|sock-shop|book-info|otel-demo)$' || true
}

# ─── local: build from source ────────────────────────────────────────────────

build_and_load_install_app() {
    local dockerfile="${APP_CHARTS_ROOT}/install-app/Dockerfile"
    local ctx="${APP_CHARTS_ROOT}/install-app"
    local img="agentcert/agentcert-install-app:latest"
    if [[ ! -f "${dockerfile}" ]]; then
        warn "Dockerfile not found: ${dockerfile} — skipping install-app local build"
        return 1
    fi
    info "Building ${img} from ${ctx} …"
    docker build -t "${img}" -f "${dockerfile}" "${ctx}"
    ok "Built ${img}"
    kind_load "${img}"
}

build_and_load_install_agent() {
    local dockerfile="${AGENT_CHARTS_ROOT}/install-agent/Dockerfile"
    local ctx="${AGENT_CHARTS_ROOT}/install-agent"
    local img="agentcert/agentcert-install-agent:latest"
    if [[ ! -f "${dockerfile}" ]]; then
        warn "Dockerfile not found: ${dockerfile} — skipping install-agent local build"
        return 1
    fi
    info "Building ${img} from ${ctx} …"
    docker build -t "${img}" -f "${dockerfile}" "${ctx}"
    ok "Built ${img}"
    kind_load "${img}"
}

pull_and_load_litmus_images() {
    local images=(
        "litmuschaos/k8s:latest"
        "litmuschaos/litmus-checker:latest"
        "litmuschaos/litmus-app-deployer:latest"
    )
    for img in "${images[@]}"; do
        info "Pulling ${img} from Docker Hub …"
        if docker pull "${img}"; then
            ok "Pulled ${img}"
            kind_load "${img}"
        else
            warn "Pull failed for ${img}"
        fi
    done
}

# ─── jfrog: create pull secret + patch service account ───────────────────────

ensure_jfrog_pull_secret() {
    if [[ -z "${JFROG_USER}" || -z "${JFROG_TOKEN}" ]]; then
        warn "JFROG_USER or JFROG_TOKEN not set in .env — cannot create pull secret"
        warn "Set them and re-run this script, or run:"
        warn "  kubectl create secret docker-registry jfrog-pull-secret \\"
        warn "    --docker-server=${JFROG_HOST} \\"
        warn "    --docker-username=<user> --docker-password=<token> -n <namespace>"
        return 1
    fi

    local namespaces
    namespaces="$(experiment_namespaces)"
    if [[ -z "${namespaces}" ]]; then
        warn "No experiment namespaces found on the cluster (itbench, sock-shop, book-info, otel-demo)."
        warn "Re-run this script after the experiment namespace is created."
        return 0
    fi

    while IFS= read -r ns; do
        [[ -z "${ns}" ]] && continue
        info "Namespace ${ns}: creating/updating jfrog-pull-secret …"
        # Replace instead of fail if already exists
        kubectl create secret docker-registry jfrog-pull-secret \
            --docker-server="${JFROG_HOST}" \
            --docker-username="${JFROG_USER}" \
            --docker-password="${JFROG_TOKEN}" \
            -n "${ns}" \
            --dry-run=client -o yaml \
        | kubectl apply -f - -n "${ns}"
        ok "jfrog-pull-secret applied in namespace ${ns}"

        # Patch argo-chaos service account to use it
        if kubectl get serviceaccount argo-chaos -n "${ns}" &>/dev/null; then
            kubectl patch serviceaccount argo-chaos -n "${ns}" \
                -p '{"imagePullSecrets":[{"name":"jfrog-pull-secret"}]}'
            ok "argo-chaos patched with imagePullSecrets in namespace ${ns}"
        else
            warn "argo-chaos service account not found in ${ns} — skipping patch"
        fi
    done <<< "${namespaces}"
}

# ─── main ────────────────────────────────────────────────────────────────────

_did_something=0

case "${APP_SRC}" in
    local)
        info "install-application: local build"
        build_and_load_install_app && _did_something=1
        ;;
    jfrog)
        info "install-application: JFrog (${JFROG_HOST}/${JFROG_PATH}/agentcert/agentcert-install-app:latest)"
        ensure_jfrog_pull_secret && _did_something=1
        ;;
    dockerhub)
        info "install-application: Docker Hub — no action needed (pulled at runtime)"
        ;;
esac

case "${AGENT_SRC}" in
    local)
        info "install-agent: local build"
        build_and_load_install_agent && _did_something=1
        ;;
    jfrog)
        info "install-agent: JFrog (${JFROG_HOST}/${JFROG_PATH}/agentcert/agentcert-install-agent:latest)"
        # Pull secret already created above if APP_SRC was also jfrog; idempotent if called again
        [[ "${APP_SRC}" != "jfrog" ]] && ensure_jfrog_pull_secret
        _did_something=1
        ;;
    dockerhub)
        info "install-agent: Docker Hub — no action needed (pulled at runtime)"
        ;;
esac

case "${LITMUS_SRC}" in
    local)
        info "litmuschaos helpers: pull from Docker Hub + kind load"
        pull_and_load_litmus_images && _did_something=1
        ;;
    dockerhub)
        info "litmuschaos helpers: Docker Hub — no action needed (pulled at runtime)"
        ;;
esac

echo
if [[ "${_did_something}" -eq 1 ]]; then
    ok "Image preparation complete."
    # Restart graphql so it re-reads INSTALL_APPLICATION_IMAGE and INSTALL_AGENT_IMAGE
    # from the ace-env Secret (updated by setup.sh before this script ran).
    if kubectl get deployment graphql -n ace &>/dev/null; then
        info "Restarting graphql deployment to pick up updated image env vars …"
        kubectl rollout restart deployment/graphql -n ace
        kubectl rollout status deployment/graphql -n ace --timeout=120s \
            && ok "graphql restarted successfully" \
            || warn "graphql rollout timed out — check: kubectl get pods -n ace"
    else
        warn "graphql deployment not found in namespace ace — skipping restart"
    fi
else
    ok "Nothing to do — all sources are 'dockerhub' (images pulled at runtime)."
fi
echo
