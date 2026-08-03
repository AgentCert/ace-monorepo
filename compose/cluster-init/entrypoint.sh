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
# Identifies THIS checkout on the shared host (see docker-compose.yml, which
# passes this through from the monorepo-root .env's ACE_INSTANCE_NAME).
# "unknown-instance" only applies if someone runs this container directly,
# bypassing `docker compose up` from the repo root -- the supported path
# always has a concrete value here.
ACE_INSTANCE_NAME="${ACE_INSTANCE_NAME:-unknown-instance}"
# Never bare "agentcert" -- see the ensure_kind() ownership-marker comment
# below for why a checkout-independent default is unsafe on a shared host.
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-agentcert-${ACE_INSTANCE_NAME}}"
# The host-side absolute path of this checkout (docker-compose.yml passes
# `${PWD}` through as this, i.e. wherever `docker compose up` was invoked
# from). Used only to label kind-cluster ownership below -- `/repo` itself
# is just this container's fixed internal mount alias and is identical
# across every checkout, so it can't serve as an identity.
HOST_REPO_ROOT="${HOST_REPO_ROOT:-/repo}"
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

# For private-link cloud clusters (AKS/EKS/GKE), the API server hostname only
# resolves via cloud-internal DNS (e.g. Azure 168.63.129.16). Alpine's musl
# resolver can fail intermittently when forwarding through systemd-resolved.
# Pin the resolved IP into /etc/hosts immediately after a successful DNS lookup
# so all subsequent kubectl calls bypass DNS entirely.
pin_api_server_host() {
    local server ip
    server=$(kubectl config view --minify \
        -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null \
        | sed -e 's|https://||' -e 's|:[0-9]*$||')
    [[ -z "${server}" ]] && return 0
    # Already an IP — nothing to pin.
    [[ "${server}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
    # Already pinned — don't duplicate.
    grep -q "${server}" /etc/hosts 2>/dev/null && return 0
    ip=$(python3 -c "import socket; print(socket.gethostbyname('${server}'))" 2>/dev/null || true)
    if [[ -n "${ip}" ]]; then
        echo "${ip}  ${server}" >> /etc/hosts
        ok "Pinned ${server} → ${ip} in /etc/hosts (private-link DNS workaround)"
    fi
}

kind_cluster_exists() {
    kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"
}

# Ownership marker for a kind cluster THIS checkout created: a docker volume
# labelled with this checkout's host-side path. A kind cluster (like a
# docker container name) is a host-wide unique resource, not scoped to a
# checkout or user -- two engineers' checkouts on the same shared host can
# both default to a cluster named "agentcert". Before reusing, restarting,
# or deleting a cluster by name, refuse unless this marker proves THIS
# checkout created it. This is the kind-cluster equivalent of
# assert_not_foreign_container() in scripts/start-local-services.sh -- see
# CLAUDE.md section 0 for the incident that safety net was built to prevent.
kind_owner_marker() { echo "ace-kind-owner-$1"; }

assert_kind_cluster_ownership() {
    local cluster_name="$1"
    kind_cluster_exists || return 0   # doesn't exist yet -- nothing to protect
    local marker; marker="$(kind_owner_marker "${cluster_name}")"
    if ! docker volume inspect "${marker}" >/dev/null 2>&1; then
        err "kind cluster '${cluster_name}' exists but has no ACE ownership marker (${marker})."
        err "It may belong to another checkout or user on this shared host. Refusing to reuse, restart, or delete it."
        err "Set a unique KIND_CLUSTER_NAME in .env for this checkout, or if you are CERTAIN this cluster is yours, run:"
        err "  docker volume create --label ace.kind.owner=${HOST_REPO_ROOT} ${marker}"
        return 1
    fi
    local owner
    owner="$(docker volume inspect "${marker}" --format '{{index .Labels "ace.kind.owner"}}' 2>/dev/null)"
    if [[ "${owner}" != "${HOST_REPO_ROOT}" ]]; then
        err "kind cluster '${cluster_name}' is owned by a different checkout (working_dir: ${owner:-unknown}, ours: ${HOST_REPO_ROOT})."
        err "Refusing to touch it. Set a unique KIND_CLUSTER_NAME in .env for this checkout."
        return 1
    fi
    return 0
}

mark_kind_cluster_owned()   { docker volume create --label "ace.kind.owner=${HOST_REPO_ROOT}" "$(kind_owner_marker "$1")" >/dev/null; }
unmark_kind_cluster_owned() { docker volume rm "$(kind_owner_marker "$1")" >/dev/null 2>&1 || true; }

ensure_kind() {
    # Hard stop before touching ANYTHING by this name -- see CLAUDE.md section 0.
    assert_kind_cluster_ownership "${KIND_CLUSTER_NAME}" || exit 1

    if kind_cluster_exists; then
        kubectl config use-context "kind-${KIND_CLUSTER_NAME}" >/dev/null 2>&1 || true
        if context_works; then
            ok "kind cluster '${KIND_CLUSTER_NAME}' already exists and is reachable — reusing it."
            return 0
        fi
        # Cluster exists but the API server is down (node container stopped, e.g.
        # Exited 137). Try to restart its node(s) before giving up / recreating.
        warn "kind cluster '${KIND_CLUSTER_NAME}' exists but its API server is unreachable — starting its node(s)…"
        docker ps -a --format '{{.Names}}' \
            | grep -E "^${KIND_CLUSTER_NAME}-(control-plane|worker)" \
            | xargs -r docker start >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do
            context_works && { ok "Restarted existing kind cluster '${KIND_CLUSTER_NAME}'."; return 0; }
            sleep 2
        done
        warn "Still unreachable after restart — recreating the cluster."
        kind delete cluster --name "${KIND_CLUSTER_NAME}" >/dev/null 2>&1 || true
        unmark_kind_cluster_owned "${KIND_CLUSTER_NAME}"
    fi

    log "Creating kind cluster '${KIND_CLUSTER_NAME}' ..."
    mkdir -p "$(dirname "${KUBECONFIG}")"   # so kind can write the kubeconfig
    if [[ -f "${KIND_CONFIG}" ]]; then
        log "Using kind config ${KIND_CONFIG}"
        kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${KIND_CONFIG}"
    else
        warn "No kind config at ${KIND_CONFIG} — creating with defaults (no ACE port mappings, and NOT instance-scoped)."
        warn "Run deploy/kind/render-kind-config.sh --personal-workspace on the host first, then re-run, to get ACE's port mappings without colliding with another checkout on this host."
        kind create cluster --name "${KIND_CLUSTER_NAME}"
    fi
    mark_kind_cluster_owned "${KIND_CLUSTER_NAME}"
    kubectl config use-context "kind-${KIND_CLUSTER_NAME}" >/dev/null 2>&1 || true
}

# az CLI writes command logs to $AZURE_CONFIG_DIR/commands/. The host ~/.azure
# is mounted read-only, so copy it to a writable /tmp location and redirect az
# there. This keeps the host credentials untouched while letting az log freely.
if [[ -d /root/.azure ]]; then
    mkdir -p /tmp/azure-config
    cp -r /root/.azure/. /tmp/azure-config/
    export AZURE_CONFIG_DIR=/tmp/azure-config
    log "Copied ~/.azure → /tmp/azure-config (writable) for az CLI logging."
fi

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
            err "Tried: ${KUBECONFIG}"
            err "--- kubectl cluster-info output ---"
            kubectl cluster-info 2>&1 || true
            err "-----------------------------------"
            err "If it uses exec-auth (az/aws/gcloud), make sure you are logged in on the host"
            err "  Azure: az login  then re-run setup.sh (auto-sets AZURE_CONFIG_DIR)"
            err "  AWS:   aws sso login  then re-run setup.sh (auto-sets AWS_CONFIG_DIR)"
            err "  GCP:   gcloud auth login  then re-run setup.sh (auto-sets GCLOUD_CONFIG_DIR)"
            err "Then: docker compose up -d"
            exit 1
        fi
        pin_api_server_host
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

# Export a world-readable kubeconfig to the shared volume for non-root app
# containers (graphql runs as uid 65534).
#
# Cloud clusters (AKS/EKS/GKE) produce exec-auth kubeconfigs that require a
# cloud CLI binary inside every container that uses them — graphql has none.
# Instead, we mint a 48-hour ServiceAccount token here (cluster-init has all
# auth plugins) and write a static token kubeconfig. Provider-agnostic: works
# for Azure AD/kubelogin, AWS IAM, GKE, or any other exec-auth setup.
KUBECONFIG_OUT="${KUBECONFIG_OUT:-/shared/config}"
if [[ -d "$(dirname "${KUBECONFIG_OUT}")" ]]; then
    if grep -q "exec:" "${KUBECONFIG}" 2>/dev/null; then
        log "exec-auth kubeconfig detected — minting a ServiceAccount token for shared kubeconfig."
        # Create the ServiceAccount and binding (idempotent).
        kubectl create serviceaccount ace-system -n kube-system \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        kubectl create clusterrolebinding ace-system-admin \
            --clusterrole=cluster-admin \
            --serviceaccount=kube-system:ace-system \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        # Mint a 48-hour token (no Secret needed; uses the TokenRequest API).
        _token=$(kubectl create token ace-system -n kube-system --duration=48h)
        _server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
        _ca=$(kubectl config view --minify --raw \
                -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
        cat > "${KUBECONFIG_OUT}" <<KUBECFG
apiVersion: v1
kind: Config
clusters:
- name: ace
  cluster:
    server: ${_server}
    certificate-authority-data: ${_ca}
users:
- name: ace-system
  user:
    token: ${_token}
contexts:
- name: ace
  context:
    cluster: ace
    user: ace-system
current-context: ace
KUBECFG
        chmod 644 "${KUBECONFIG_OUT}"
        ok "Wrote static token kubeconfig → ${KUBECONFIG_OUT} (token valid 48 h)"
    else
        if cp "${KUBECONFIG}" "${KUBECONFIG_OUT}" && chmod 644 "${KUBECONFIG_OUT}"; then
            ok "Wrote shared kubeconfig → ${KUBECONFIG_OUT} (0644)"
        else
            warn "Could not write shared kubeconfig to ${KUBECONFIG_OUT}"
        fi
    fi
fi

ok "cluster-init complete."
