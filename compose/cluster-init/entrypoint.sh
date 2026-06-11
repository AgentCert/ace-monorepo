#!/usr/bin/env bash
# =============================================================================
# cluster-init entrypoint — resolves a working Kubernetes context for the stack.
#
# Driven entirely by CLUSTER_MODE (from the monorepo-root .env):
#   auto         probe the mounted kubeconfig; reuse if it works, else kind.
#   cloud        reuse an existing cloud context (AKS/EKS/GKE). Requires the
#                kubeconfig (and any cloud cred dirs / CLIs for exec-auth) to be
#                mounted by compose. In-cluster pods call back to HOST_PUBLIC_IP.
#   local        reuse an existing local context (kind/minikube/k3s).
#   fresh | kind always ensure a local kind cluster named KIND_CLUSTER_NAME.
#
# Runs on the host network with /var/run/docker.sock mounted, so `kind create`
# spawns node containers as host-docker siblings and `kubectl` reaches the
# apiserver at the host-local address kind writes into the kubeconfig.
# =============================================================================
set -euo pipefail

CLUSTER_MODE="${CLUSTER_MODE:-auto}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-agentcert}"
HOST_PUBLIC_IP="${HOST_PUBLIC_IP:-}"
# Host ~/.kube is mounted here read-write so `kind create` can rewrite it.
export KUBECONFIG="${KUBECONFIG:-/host-kube/config}"
# Optional kind config (host port mappings etc.), mounted from the repo.
KIND_CONFIG="${KIND_CONFIG:-/repo/local-personal-workspace/kind-agentcert.yaml}"

log()  { echo -e "\033[36m[cluster-init]\033[0m $*"; }
ok()   { echo -e "\033[32m[cluster-init]\033[0m $*"; }
warn() { echo -e "\033[33m[cluster-init]\033[0m $*"; }
err()  { echo -e "\033[31m[cluster-init]\033[0m $*" >&2; }

context_works() {
    [[ -f "${KUBECONFIG}" ]] || return 1
    kubectl cluster-info >/dev/null 2>&1
}

kind_cluster_exists() {
    kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"
}

ensure_kind() {
    if kind_cluster_exists; then
        ok "kind cluster '${KIND_CLUSTER_NAME}' already exists — reusing it."
    else
        log "Creating kind cluster '${KIND_CLUSTER_NAME}' ..."
        # Make sure ~/.kube exists so kind can write the kubeconfig.
        mkdir -p "$(dirname "${KUBECONFIG}")"
        if [[ -f "${KIND_CONFIG}" ]]; then
            log "Using kind config ${KIND_CONFIG}"
            kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${KIND_CONFIG}"
        else
            warn "No kind config at ${KIND_CONFIG} — creating with defaults."
            kind create cluster --name "${KIND_CLUSTER_NAME}"
        fi
    fi
    # Point the active context at the (possibly new) kind cluster.
    kubectl config use-context "kind-${KIND_CLUSTER_NAME}" >/dev/null 2>&1 || true
}

log "CLUSTER_MODE=${CLUSTER_MODE}  KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME}  KUBECONFIG=${KUBECONFIG}"

case "${CLUSTER_MODE}" in
    auto)
        if context_works; then
            ok "Existing kube context works — reusing it ($(kubectl config current-context 2>/dev/null))."
        else
            warn "No working kube context found — provisioning a local kind cluster."
            ensure_kind
        fi
        ;;
    fresh|kind)
        ensure_kind
        ;;
    local)
        if ! context_works; then
            err "CLUSTER_MODE=local but no working context at ${KUBECONFIG}."
            err "Start your local cluster (kind/minikube/k3s) or switch CLUSTER_MODE=fresh."
            exit 1
        fi
        ok "Reusing local context ($(kubectl config current-context 2>/dev/null))."
        ;;
    cloud)
        if ! context_works; then
            err "CLUSTER_MODE=cloud but the mounted kubeconfig does not work."
            err "If it uses exec-auth (az/aws/gcloud), mount the cloud CLI + cred dir,"
            err "or generate a token-based kubeconfig. Tried: ${KUBECONFIG}"
            exit 1
        fi
        ok "Reusing cloud context ($(kubectl config current-context 2>/dev/null))."
        if [[ -z "${HOST_PUBLIC_IP}" ]]; then
            warn "HOST_PUBLIC_IP is empty — in-cluster subscriber pods will not be able"
            warn "to call back to this VM. Set HOST_PUBLIC_IP in .env for cloud clusters."
        fi
        ;;
    *)
        err "Unknown CLUSTER_MODE='${CLUSTER_MODE}' (expected auto|cloud|local|fresh|kind)."
        exit 1
        ;;
esac

# Final sanity check — fail loudly so dependent services don't start blind.
if ! context_works; then
    err "Kubernetes context still not reachable after provisioning. Aborting."
    exit 1
fi

ok "Kubernetes ready:"
kubectl get nodes -o wide 2>/dev/null || kubectl cluster-info

# Export a world-readable copy of the resolved kubeconfig so non-root app
# containers (graphql runs as uid 65534) can read it — the host ~/.kube/config
# is typically mode 600 and unreadable by that uid. cluster-init runs as root.
KUBECONFIG_OUT="${KUBECONFIG_OUT:-/shared/config}"
if [[ -d "$(dirname "${KUBECONFIG_OUT}")" ]]; then
    if cp "${KUBECONFIG}" "${KUBECONFIG_OUT}" && chmod 644 "${KUBECONFIG_OUT}"; then
        ok "Wrote shared kubeconfig → ${KUBECONFIG_OUT} (0644)"
    else
        warn "Could not write shared kubeconfig to ${KUBECONFIG_OUT}"
    fi
fi

ok "cluster-init complete."
