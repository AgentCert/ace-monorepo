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
#   SRE_AGENTS_IMAGE_SOURCE     dockerhub | local
#   JFROG_HOST, JFROG_REGISTRY_PATH, JFROG_USER, JFROG_TOKEN
#   KIND_CLUSTER_NAME, ACE_INSTANCE_NAME
#   APP_CHARTS_ROOT, AGENT_CHARTS_ROOT  (set by setup.sh to absolute paths)
#
# For "local":
#   install-app / install-agent  — docker build from source + kind load
#   sre-agent-comprehensive / sre-agent-crewai — build from agents/ + kind load
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
SRE_AGENTS_SRC="$(cur SRE_AGENTS_IMAGE_SOURCE)"

APP_SRC="${APP_SRC:-dockerhub}"
AGENT_SRC="${AGENT_SRC:-dockerhub}"
LITMUS_SRC="${LITMUS_SRC:-dockerhub}"
SRE_AGENTS_SRC="${SRE_AGENTS_SRC:-local}"

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
echo -e "${CYAN}  install-app: ${APP_SRC}   install-agent: ${AGENT_SRC}   litmus: ${LITMUS_SRC}   sre-agents: ${SRE_AGENTS_SRC}${NC}"
echo -e "${CYAN}=======================================================${NC}"
echo

# ─── helpers ─────────────────────────────────────────────────────────────────

# ACE_ALREADY_BUILT_IMAGES: space-separated image tags setup.sh's own build
# loop already built + kind-loaded THIS run (set when "a" — build ALL locally
# — was chosen, which also sets INSTALL_APP_IMAGE_SOURCE/INSTALL_AGENT_IMAGE_
# SOURCE=local, triggering this script right afterward). Without this check,
# build_and_load_install_app/agent below would rebuild + reload the exact
# same image from scratch a second time, every "build ALL locally" run.
# Unset when this script is run standalone (its normal, intended use) — every
# branch below then behaves exactly as it always has.
ALREADY_BUILT_IMAGES=" ${ACE_ALREADY_BUILT_IMAGES:-} "
image_already_built() {
    [[ "${ALREADY_BUILT_IMAGES}" == *" $1 "* ]]
}

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
    if image_already_built "${img}"; then
        ok "${img} already built + kind-loaded by setup.sh's build step this run — skipping redundant rebuild"
        return 0
    fi
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
    if image_already_built "${img}"; then
        ok "${img} already built + kind-loaded by setup.sh's build step this run — skipping redundant rebuild"
        return 0
    fi
    if [[ ! -f "${dockerfile}" ]]; then
        warn "Dockerfile not found: ${dockerfile} — skipping install-agent local build"
        return 1
    fi
    info "Building ${img} from ${ctx} …"
    docker build -t "${img}" -f "${dockerfile}" "${ctx}"
    ok "Built ${img}"
    kind_load "${img}"
}

build_and_load_sre_agent() {
    local name="$1"   # e.g. sre-agent-comprehensive
    local img="$2"    # e.g. agentcert/sre-agent-comprehensive:latest
    local ctx="${REPO_ROOT}/agents/${name}"
    local dockerfile="${ctx}/Dockerfile"
    if image_already_built "${img}"; then
        ok "${img} already built + kind-loaded by setup.sh's build step this run — skipping redundant rebuild"
        return 0
    fi
    if [[ ! -f "${dockerfile}" ]]; then
        warn "Dockerfile not found: ${dockerfile} — skipping ${name} local build"
        return 1
    fi
    info "Building ${img} from ${ctx} …"
    docker build --network=host -t "${img}" -f "${dockerfile}" "${ctx}"
    ok "Built ${img}"
    kind_load "${img}"
}

pull_and_load_litmus_images() {
    # Base images pulled under their Docker Hub names.
    # For each image we also load an alias under any alternative registry names
    # that stored experiment manifests may reference (JFrog, Scarf proxy).
    local images=(
        "litmuschaos/k8s:latest"
        "litmuschaos/litmus-checker:latest"
        "litmuschaos/litmus-app-deployer:latest"
        "litmuschaos/go-runner:latest"
        "alexeiled/stress-ng:latest-ubuntu"
        "gaiadocker/iproute2:latest"
    )

    # Each image pulls (network-bound) and kind-loads independently of every
    # other, so serializing all 6 was pure wall-clock waste -- bounded rather
    # than unbounded for the same shared-host reason as setup.sh's build loop
    # (see ACE_BUILD_PARALLELISM there); override via ACE_PULL_PARALLELISM.
    # `kind load docker-image` against the same node concurrently from
    # multiple processes isn't officially documented as safe, but containerd's
    # content store is content-addressed with its own internal locking and
    # this is a common pattern in CI pipelines; a failed load here was already
    # a non-fatal warning before this change, so the worst case is unchanged.
    local parallelism="${ACE_PULL_PARALLELISM:-4}"
    local results_dir; results_dir="$(mktemp -d "${REPO_ROOT}/.tmp/litmus-pull-results.XXXXXX" 2>/dev/null || mktemp -d)"
    local log_dir="${REPO_ROOT}/.tmp/litmus-pull-logs"
    rm -rf "${log_dir}"; mkdir -p "${log_dir}"

    _pull_and_load_one() {
        local img="$1" idx="$2"
        {
            echo "Pulling ${img} from Docker Hub …"
            if docker pull "${img}"; then
                echo "Pulled ${img}"
                kind_load "${img}"
                if [[ "${img}" == "litmuschaos/go-runner:latest" ]]; then
                    local scarf="litmuschaos.docker.scarf.sh/litmuschaos/go-runner:latest"
                    docker tag "${img}" "${scarf}"
                    kind_load "${scarf}"
                fi
                echo ok > "${results_dir}/${idx}.status"
            else
                echo "Pull failed for ${img}"
                echo failed > "${results_dir}/${idx}.status"
            fi
        } >"${log_dir}/${idx}.log" 2>&1
    }

    info "Pulling ${#images[@]} litmus helper image(s), up to ${parallelism} at a time — logs: ${log_dir}/"
    local idx=0 running=0
    for img in "${images[@]}"; do
        _pull_and_load_one "${img}" "${idx}" &
        idx=$(( idx + 1 ))
        running=$(( running + 1 ))
        if (( running >= parallelism )); then
            wait -n
            running=$(( running - 1 ))
        fi
    done
    wait
    unset -f _pull_and_load_one

    local i status
    for (( i = 0; i < idx; i++ )); do
        status="$(cat "${results_dir}/${i}.status" 2>/dev/null || echo missing)"
        if [[ "${status}" == "ok" ]]; then
            ok "Pulled + loaded: ${images[i]}"
        else
            warn "Failed: ${images[i]} — log: ${log_dir}/${i}.log"
        fi
    done
    rm -rf "${results_dir}"
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

case "${SRE_AGENTS_SRC}" in
    local)
        info "sre-agent-comprehensive: local build"
        build_and_load_sre_agent "sre-agent-comprehensive" "agentcert/sre-agent-comprehensive:latest" && _did_something=1
        info "sre-agent-crewai: local build"
        build_and_load_sre_agent "sre-agent-crewai" "agentcert/sre-agent-crewai:latest" && _did_something=1
        ;;
    dockerhub)
        info "sre-agents: Docker Hub — no action needed (pulled at runtime)"
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
