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

# kind node images default the `iptables` alternative to the nft backend. On
# this host's kernel/iptables toolchain, nft's netlink-based rule loading has
# a hard per-message size ceiling that kube-proxy's normal Service ruleset
# exceeds -- every periodic resync then fails with
# "sendmsg() failed: Message too long" (kube-proxy retries every 30s, forever,
# and never once succeeds again after the first sync that happened to fit).
# The practical effect: Service routing silently freezes at whatever ruleset
# loaded at the very first successful sync. Any Service whose backing pod
# later restarts (gets a new IP) is blackholed from that point on -- new
# connections to its ClusterIP get NATed to a now-dead pod IP and silently
# dropped -- while every other Service keeps "working" purely by accident
# (their stale rules still happen to be correct). This is exactly what broke
# the ChaosCenter UI's GraphQL calls after a graphql pod restart; see
# OPEN_WEIGHT_CERTIFICATION_HANDOFF.md for the live incident this was found in.
#
# iptables-legacy sidesteps the bug entirely -- it programs the kernel via a
# setsockopt() ruleset replace, not one giant batched netlink message, so
# there's no comparable size ceiling to hit.
#
# kube-proxy bundles its own copy of the iptables tools (it does not use the
# node's /usr/sbin), so flipping the node's own `update-alternatives` default
# has no effect on it. kube-proxy instead auto-detects nft vs legacy at its
# own startup by counting which backend currently has MORE rules already
# loaded in the kernel (ties favor legacy) -- so the only way to make it
# actually choose legacy is to zero out nft's rule count *before* kube-proxy
# starts (fresh cluster) or before it next restarts (existing cluster), so
# legacy's smaller-or-equal count wins that tie-break. Everything here is
# scoped to nftables tables inside this one kind node container's own network
# namespace -- it never touches the shared host's kernel state or any other
# checkout's containers.
steer_kube_proxy_onto_iptables_legacy() {
    local node
    for node in $(docker ps --format '{{.Names}}' | grep -E "^${KIND_CLUSTER_NAME}-(control-plane|worker)" || true); do
        docker exec "${node}" sh -c '
            update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1 || true
            update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
            for t in "ip nat" "ip mangle" "ip filter" "ip6 nat" "ip6 mangle" "ip6 filter"; do
                nft delete table ${t} >/dev/null 2>&1 || true
            done
        ' 2>/dev/null || warn "Could not steer ${node} onto iptables-legacy -- kube-proxy may hit the nft message-size bug (see innovation.md)."
    done
    # kube-proxy only auto-detects once, at its own startup -- bounce it now
    # so it re-evaluates against the rule counts set up above.
    if kubectl -n kube-system get daemonset kube-proxy >/dev/null 2>&1; then
        kubectl -n kube-system delete pod -l k8s-app=kube-proxy >/dev/null 2>&1 || true
        kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-proxy --timeout=60s >/dev/null 2>&1 \
            || warn "kube-proxy did not report Ready within 60s after the iptables-backend fix -- check manually (kubectl -n kube-system logs -l k8s-app=kube-proxy)."
    fi
}

# Cheap, read-only check so the "reuse an existing cluster" path only pays
# for the (mildly disruptive -- it bounces kube-proxy) fix above when the
# cluster is actually hitting the bug, e.g. one created before this fix
# existed. Fresh clusters always get the fix unconditionally (see ensure_kind
# below) since they always start out on the broken nft default.
kube_proxy_iptables_broken() {
    kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=20 2>/dev/null | grep -q "Message too long"
}

# kind's node entrypoint rewrites each node's /etc/resolv.conf to point at
# the node's own docker-network gateway IP (e.g. 172.18.0.1:53) whenever it
# detects the host's own resolv.conf uses a loopback resolver -- true on this
# fleet, since it uses systemd-resolved's 127.0.0.53 stub. Under the ROOTFUL
# daemon that gateway IP is transparently proxied through to the host's real
# resolver (iptables DNAT the rootful daemon sets up) and everything just
# works. Under a PERSONAL ROOTLESS daemon (see CLAUDE.md §6 "Personal
# rootless Docker") RootlessKit/slirp4netns does not replicate that DNAT, so
# the gateway IP is simply unreachable on :53 and EVERY external DNS lookup
# inside every node times out -- this includes containerd's own image pulls
# (it reads the node container's /etc/resolv.conf directly) and CoreDNS's
# upstream forwarding (its default Corefile is `forward . /etc/resolv.conf`,
# inherited from the node via dnsPolicy: Default). The practical symptom:
# any chaos-infrastructure connect (subscriber/chaos-exporter/chaos-operator)
# -- or any other in-cluster image pull -- sits in ImagePullBackOff forever,
# and the ChaosCenter UI shows the infra stuck "Pending" indefinitely with no
# error surfaced anywhere in the UI itself. Fix: detect the broken gateway
# resolver per-node and fall back to public resolvers, which rootless
# networking (slirp4netns) CAN reach directly as ordinary outbound traffic.
node_dns_broken() {
    local node="$1"
    ! docker exec "${node}" timeout 3 getent hosts registry-1.docker.io >/dev/null 2>&1
}

fix_node_dns() {
    local node="$1"
    if docker exec "${node}" sh -c 'printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf'; then
        ok "Rewrote ${node}'s /etc/resolv.conf to public resolvers (gateway-IP resolver unreachable under rootless Docker)."
    else
        warn "Could not patch ${node}'s /etc/resolv.conf -- image pulls and in-cluster DNS may keep failing."
    fi
}

ensure_node_dns() {
    local node any_fixed=0
    for node in $(docker ps --format '{{.Names}}' | grep -E "^${KIND_CLUSTER_NAME}-(control-plane|worker)" || true); do
        if node_dns_broken "${node}"; then
            warn "${node} cannot resolve external DNS (gateway-IP resolver unreachable) -- patching ..."
            fix_node_dns "${node}"
            any_fixed=1
        fi
    done
    # CoreDNS pods inherit the node's resolv.conf at pod-start time -- if any
    # were already running against the broken one, bounce them so they pick
    # up the patched file rather than keep SERVFAILing on cached failures.
    if [[ "${any_fixed}" == "1" ]] && kubectl -n kube-system get deployment coredns >/dev/null 2>&1; then
        kubectl -n kube-system delete pod -l k8s-app=kube-dns >/dev/null 2>&1 || true
        kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=60s >/dev/null 2>&1 \
            || warn "CoreDNS did not report Ready within 60s after the DNS fix -- check manually (kubectl -n kube-system logs -l k8s-app=kube-dns)."
    fi
}

ensure_kind() {
    # Hard stop before touching ANYTHING by this name -- see CLAUDE.md section 0.
    assert_kind_cluster_ownership "${KIND_CLUSTER_NAME}" || exit 1

    if kind_cluster_exists; then
        # kind create's merge-on-create is not guaranteed to have landed in
        # THIS KUBECONFIG (e.g. a previous run under a different resolved
        # ${HOME}/.kube bind-mount source) -- re-derive the entry from the
        # running cluster rather than best-effort switching to a context that
        # may not exist yet. `context_works` below is the real gate; this
        # `|| true` is fine because that check catches a failed export too.
        kind export kubeconfig --name "${KIND_CLUSTER_NAME}" >/dev/null 2>&1 || true
        if context_works; then
            if kube_proxy_iptables_broken; then
                warn "kube-proxy on '${KIND_CLUSTER_NAME}' is hitting the iptables-nft message-size bug (Service routing silently stale) — fixing ..."
                steer_kube_proxy_onto_iptables_legacy
            fi
            ensure_node_dns
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
        if ! kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${KIND_CONFIG}"; then
            err "kind create cluster failed for '${KIND_CLUSTER_NAME}' (config: ${KIND_CONFIG})."
            err "Common causes: a hostPort in ${KIND_CONFIG} already bound by another checkout on this host,"
            err "or /var/run/docker.sock (bind-mounted into this container) not reaching a working daemon."
            exit 1
        fi
    else
        warn "No kind config at ${KIND_CONFIG} — creating with defaults (no ACE port mappings, and NOT instance-scoped)."
        warn "Run deploy/kind/render-kind-config.sh --personal-workspace on the host first, then re-run, to get ACE's port mappings without colliding with another checkout on this host."
        if ! kind create cluster --name "${KIND_CLUSTER_NAME}"; then
            err "kind create cluster failed for '${KIND_CLUSTER_NAME}' (no config -- created with defaults)."
            exit 1
        fi
    fi
    mark_kind_cluster_owned "${KIND_CLUSTER_NAME}"
    # Same rationale as above: force the merge instead of hoping
    # `kind create`'s implicit one landed correctly.
    kind export kubeconfig --name "${KIND_CLUSTER_NAME}" >/dev/null 2>&1 || true
    # A brand-new cluster always starts on the broken nft default (see the
    # comment on steer_kube_proxy_onto_iptables_legacy above) -- fix it now,
    # before anything else depends on Service routing actually working.
    log "Steering kube-proxy onto iptables-legacy to avoid the nft netlink message-size bug ..."
    steer_kube_proxy_onto_iptables_legacy
    # A brand-new node always starts with whatever resolv.conf kind's own
    # entrypoint wrote -- check and patch it now, before anything (image
    # pulls, CoreDNS) depends on external DNS actually working.
    log "Checking node DNS reaches the outside world (rootless Docker can't proxy the gateway-IP resolver) ..."
    ensure_node_dns
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

# Export an ADDITIONAL "internal" kubeconfig for containers that are NOT
# real-host-networked — currently just graphql, which runs on bridge
# networking + explicit ports: under docker-compose.yml so it's reachable at
# all under a personal rootless Docker daemon (see CLAUDE.md §6 "Personal
# rootless Docker"). `kind get kubeconfig --internal` resolves the API server
# as https://<cluster>-control-plane:6443 — a Docker-network container DNS
# name, reachable by anything sharing the `kind` network (see
# KIND_EXPERIMENTAL_DOCKER_NETWORK / docker-compose.yml) — instead of
# https://127.0.0.1:<port>, which only resolves for containers sharing the
# real (or, under rootless, RootlessKit's) host network namespace, same as
# this container. Only meaningful for an actual local kind cluster; cloud/
# local contexts leave KUBECONFIG_INTERNAL_OUT unset or the kind-cluster
# check below simply no-ops.
if [[ -n "${KUBECONFIG_INTERNAL_OUT:-}" ]] && kind_cluster_exists && [[ -d "$(dirname "${KUBECONFIG_INTERNAL_OUT}")" ]]; then
    if kind get kubeconfig --internal --name "${KIND_CLUSTER_NAME}" > "${KUBECONFIG_INTERNAL_OUT}.tmp" 2>/dev/null; then
        mv "${KUBECONFIG_INTERNAL_OUT}.tmp" "${KUBECONFIG_INTERNAL_OUT}"
        chmod 644 "${KUBECONFIG_INTERNAL_OUT}"
        ok "Wrote internal (container-DNS) kubeconfig → ${KUBECONFIG_INTERNAL_OUT}"
    else
        rm -f "${KUBECONFIG_INTERNAL_OUT}.tmp"
        warn "Could not write internal kubeconfig — graphql's Kubernetes access will not work unless it shares this container's network."
    fi
fi

ok "cluster-init complete."
