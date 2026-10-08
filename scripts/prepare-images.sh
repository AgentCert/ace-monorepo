#!/usr/bin/env bash
# prepare-images.sh — build, load, or configure registry credentials for
# experiment workflow images based on *_IMAGE_SOURCE settings in .env.
#
# Called automatically by setup.sh when any source is non-default.
# Safe to run standalone at any time to rebuild / reload / re-create secrets.
#
# Reads from .env:
#   INSTALL_APP_IMAGE_SOURCE       registry | local
#   INSTALL_AGENT_IMAGE_SOURCE     registry | local
#   LITMUS_IMAGES_SOURCE           registry | local
#   SRE_AGENTS_IMAGE_SOURCE        registry | local
#   ITBENCH_EXPERIMENT_IMAGE_SOURCE registry | local (published only to the
#                                    Infosys registry — see below)
#     (legacy values "jfrog" and "dockerhub" are read as "registry")
#   IMAGE_REGISTRY, REGISTRY_USERNAME, REGISTRY_PASSWORD, IMAGE_PULL_SECRET_NAME
#     (scripts/lib/registry.sh; IMAGE_REGISTRY empty = public registries)
#   HUB_BUNDLE_IMAGE_SOURCE        local | registry
#   HUB_BUNDLE_IMAGE               image reference used by the GraphQL init container
#   KIND_CLUSTER_NAME, ACE_INSTANCE_NAME
#   APP_CHARTS_ROOT, AGENT_CHARTS_ROOT  (set by setup.sh to absolute paths)
#   ACE_KIND_LOAD_TMPDIR                (set by setup.sh; temp dir for kind load tarballs)
#
# For "local":
#   install-app / install-agent  — docker build from source + kind load
#   sre-agent-comprehensive / sre-agent-crewai — build from agents/ + kind load
#   runtime dependencies         — pull pinned/public images + kind load
#                                  (Litmus helpers, stress/network tools, and
#                                  the platform-owned metrics-server). Pulled
#                                  from IMAGE_REGISTRY when it is set, then
#                                  tagged with the public name the cluster uses.
#   itbench-experiment           — docker build from litmus-go/ (Dockerfile.itbench) + kind load
#                                   (single dispatcher binary shared by every fault under
#                                   chaos-charts/faults/itbench/*/fault.yaml — see EXPERIMENT_NAME
#                                   switch in litmus-go/bin/itbench-experiment/main.go)
# For "registry":
#   IMAGE_REGISTRY set   — creates the IMAGE_PULL_SECRET_NAME docker-registry
#                          Secret and patches the argo-chaos ServiceAccount in
#                          every experiment namespace that exists on the cluster.
#   IMAGE_REGISTRY empty — no action (Kubernetes pulls the public images at
#                          runtime; IfNotPresent reuses cached copies).

set -euo pipefail

HUB_ONLY="${1:-}"

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


# Reads an optional key from .env, printing "" (not erroring) when the key is
# absent. Under `set -eo pipefail`, `grep -E ... | tail -1 | cut ...` exits
# non-zero when grep finds no match even though tail/cut both succeed — and
# since every caller here is a bare `VAR="$(cur KEY)"` assignment, that
# non-zero status kills the whole script via errexit the moment *any* key
# that's legitimately allowed to be unset (falling back to a default below)
# is actually unset in .env. Found live: SRE_AGENTS_IMAGE_SOURCE is absent
# from a real checkout's .env and crashed the script here before it ever
# reached its own `${SRE_AGENTS_SRC:-local}` fallback three lines down.
cur() { grep -E "^${1}=" "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

# shellcheck source=lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"
registry_load "${ENV_FILE}" || exit 1   # also sets IMAGE_PULL_SECRET_NAME

APP_SRC="$(cur INSTALL_APP_IMAGE_SOURCE)"
AGENT_SRC="$(cur INSTALL_AGENT_IMAGE_SOURCE)"
LITMUS_SRC="$(cur LITMUS_IMAGES_SOURCE)"
SRE_AGENTS_SRC="$(cur SRE_AGENTS_IMAGE_SOURCE)"
HUB_BUNDLE_SRC="$(cur HUB_BUNDLE_IMAGE_SOURCE)"
HUB_BUNDLE_IMAGE="$(cur HUB_BUNDLE_IMAGE)"
ITBENCH_EXPERIMENT_SRC="$(cur ITBENCH_EXPERIMENT_IMAGE_SOURCE)"
INSTALL_APP_IMAGE="$(cur INSTALL_APPLICATION_IMAGE)"
INSTALL_AGENT_IMAGE="$(cur INSTALL_AGENT_IMAGE)"
SUBSCRIBER_IMAGE="$(cur SUBSCRIBER_IMAGE)"
EVENT_TRACKER_IMAGE="$(cur EVENT_TRACKER_IMAGE)"
ARGO_WORKFLOW_CONTROLLER_IMAGE="$(cur ARGO_WORKFLOW_CONTROLLER_IMAGE)"
ARGO_WORKFLOW_EXECUTOR_IMAGE="$(cur ARGO_WORKFLOW_EXECUTOR_IMAGE)"
CHAOS_OPERATOR_IMAGE="$(cur CHAOS_OPERATOR_IMAGE)"
CHAOS_RUNNER_IMAGE="$(cur CHAOS_RUNNER_IMAGE)"
CHAOS_EXPORTER_IMAGE="$(cur CHAOS_EXPORTER_IMAGE)"

APP_SRC="$(image_source_normalize "${APP_SRC:-registry}")"
AGENT_SRC="$(image_source_normalize "${AGENT_SRC:-registry}")"
LITMUS_SRC="$(image_source_normalize "${LITMUS_SRC:-registry}")"
SRE_AGENTS_SRC="$(image_source_normalize "${SRE_AGENTS_SRC:-local}")"
# No Docker Hub image has ever been published for this one (Docker Hub API 404s
# on agentcert/itbench-experiment); it exists only in the Infosys registry. local
# is therefore the default, same as SRE_AGENTS_SRC's rationale.
ITBENCH_EXPERIMENT_SRC="$(image_source_normalize "${ITBENCH_EXPERIMENT_SRC:-local}")"
HUB_BUNDLE_SRC="${HUB_BUNDLE_SRC:-local}"
HUB_BUNDLE_IMAGE="${HUB_BUNDLE_IMAGE:-agentcert/ace-hub-bundle:local}"
INSTALL_APP_IMAGE="${INSTALL_APP_IMAGE:-agentcert/agentcert-install-app:latest}"
INSTALL_AGENT_IMAGE="${INSTALL_AGENT_IMAGE:-agentcert/agentcert-install-agent:latest}"
SUBSCRIBER_IMAGE="${SUBSCRIBER_IMAGE:-agentcert/litmusportal-subscriber:3.0.0}"
EVENT_TRACKER_IMAGE="${EVENT_TRACKER_IMAGE:-litmuschaos/litmusportal-event-tracker:3.0.0}"
ARGO_WORKFLOW_CONTROLLER_IMAGE="${ARGO_WORKFLOW_CONTROLLER_IMAGE:-litmuschaos/workflow-controller:v3.3.1}"
ARGO_WORKFLOW_EXECUTOR_IMAGE="${ARGO_WORKFLOW_EXECUTOR_IMAGE:-litmuschaos/argoexec:v3.3.1}"
CHAOS_OPERATOR_IMAGE="${CHAOS_OPERATOR_IMAGE:-litmuschaos/chaos-operator:3.0.0}"
CHAOS_RUNNER_IMAGE="${CHAOS_RUNNER_IMAGE:-litmuschaos/chaos-runner:3.0.0}"
CHAOS_EXPORTER_IMAGE="${CHAOS_EXPORTER_IMAGE:-litmuschaos/chaos-exporter:3.0.0}"

RUNTIME_IMAGES_ARCHIVE="${RUNTIME_IMAGES_ARCHIVE:-$(cur RUNTIME_IMAGES_ARCHIVE)}"
RUNTIME_IMAGES_EXPORT_PATH="${RUNTIME_IMAGES_EXPORT_PATH:-$(cur RUNTIME_IMAGES_EXPORT_PATH)}"

APP_CHARTS_ROOT="$(cur APP_CHARTS_ROOT)"; APP_CHARTS_ROOT="${APP_CHARTS_ROOT:-${REPO_ROOT}/app-charts}"
AGENT_CHARTS_ROOT="$(cur AGENT_CHARTS_ROOT)"; AGENT_CHARTS_ROOT="${AGENT_CHARTS_ROOT:-${REPO_ROOT}/agent-charts}"
ACE_KIND_LOAD_TMPDIR="${ACE_KIND_LOAD_TMPDIR:-$(cur ACE_KIND_LOAD_TMPDIR)}"
if [[ -z "${ACE_KIND_LOAD_TMPDIR}" ]]; then
    if [[ -d "/Innovation/home/$(id -un)" && -w "/Innovation/home/$(id -un)" ]]; then
        ACE_KIND_LOAD_TMPDIR="/Innovation/home/$(id -un)/.tmp/kind-load"
    elif [[ -d /Innovation && -w /Innovation ]]; then
        ACE_KIND_LOAD_TMPDIR="/Innovation/ace-$(id -un)/kind-load-tmp"
    else
        ACE_KIND_LOAD_TMPDIR="${REPO_ROOT}/.tmp/kind-load"
    fi
    warn "ACE_KIND_LOAD_TMPDIR is unset; using ${ACE_KIND_LOAD_TMPDIR}. Run scripts/setup.sh to persist a host-local choice."
fi
export ACE_KIND_LOAD_TMPDIR

# Resolve KinD cluster name (mirrors logic in setup.sh / ensure_kind_cluster)
KIND_CLUSTER_NAME="$(cur KIND_CLUSTER_NAME)"
if [[ -z "${KIND_CLUSTER_NAME}" ]]; then
    ACE_INSTANCE="$(cur ACE_INSTANCE_NAME)"
    KIND_CLUSTER_NAME="agentcert${ACE_INSTANCE:+-${ACE_INSTANCE}}"
fi

echo
echo -e "${CYAN}=======================================================${NC}"
echo -e "${CYAN}  Preparing experiment images${NC}"
echo -e "${CYAN}  registry: ${IMAGE_REGISTRY:-public registries}${NC}"
echo -e "${CYAN}  hub-bundle: ${HUB_BUNDLE_SRC}   install-app: ${APP_SRC}   install-agent: ${AGENT_SRC}   litmus: ${LITMUS_SRC}   sre-agents: ${SRE_AGENTS_SRC}   itbench-experiment: ${ITBENCH_EXPERIMENT_SRC}${NC}"
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

ensure_runtime_registry_login() {
    # Local runtime preparation preloads every image the bundled charts render.
    # With IMAGE_REGISTRY set they all come from that registry, which needs a
    # login. With it empty they come from public registries, where Docker Hub's
    # anonymous quota is easily exceeded in a fresh client environment, so the
    # optional credentials are used when present. Tokens are never echoed.
    if ! registry_has_credentials; then
        if [[ -n "${IMAGE_REGISTRY}" ]]; then
            warn "IMAGE_REGISTRY=${IMAGE_REGISTRY} but REGISTRY_USERNAME/REGISTRY_PASSWORD are not set in .env — cannot pull runtime images."
            return 1
        fi
        warn "Registry credentials are not configured; cached images may work, but a full local runtime preload can hit Docker Hub's anonymous pull limits."
        warn "Set REGISTRY_USERNAME and REGISTRY_PASSWORD (Docker Hub) in .env, then re-run this script."
        return 0
    fi

    if registry_login >/dev/null; then
        ok "Authenticated to ${IMAGE_REGISTRY:-Docker Hub} for workflow runtime image preload."
        return 0
    fi

    warn "Login to ${IMAGE_REGISTRY:-Docker Hub} failed; refusing the runtime preload. Verify REGISTRY_USERNAME/REGISTRY_PASSWORD."
    return 1
}

# Pull an image the cluster knows by its public name. With IMAGE_REGISTRY set
# the copy is pulled from the registry and tagged with the public name, so
# kind-loaded images keep the names the manifests reference. Prints docker's
# output; returns docker's status.
pull_runtime_image() {
    local img="$1" src out rc
    src="$(registry_ref "${img}")"
    if [[ "${src}" == "$(image_canonical "${img}")" ]]; then
        docker pull "${img}" 2>&1
        return $?
    fi
    out="$(docker pull "${src}" 2>&1)"; rc=$?
    printf '%s\n' "${out}"
    [[ "${rc}" -eq 0 ]] || return "${rc}"
    docker tag "${src}" "${img}"
}

preload_runtime_images_archive() {
    [[ -z "${RUNTIME_IMAGES_ARCHIVE}" ]] && return 0
    if [[ ! -r "${RUNTIME_IMAGES_ARCHIVE}" ]]; then
        warn "RUNTIME_IMAGES_ARCHIVE is not readable: ${RUNTIME_IMAGES_ARCHIVE}"
        return 1
    fi
    info "Loading offline workflow runtime image archive: ${RUNTIME_IMAGES_ARCHIVE}"
    if ! docker load -i "${RUNTIME_IMAGES_ARCHIVE}"; then
        warn "Could not load RUNTIME_IMAGES_ARCHIVE=${RUNTIME_IMAGES_ARCHIVE}"
        return 1
    fi
    ok "Offline workflow runtime image archive loaded."
}

is_docker_hub_image() {
    local image="$1" first_component
    first_component="${image%%/*}"
    [[ "${image}" != */* || ( "${first_component}" != *.* && "${first_component}" != *:* && "${first_component}" != "localhost" ) ]]
}

# A restart can reuse images that Kubernetes already pulled into every KinD
# node, even when they are absent from the host Docker cache. Check every
# node so an image missing on one worker is still prepared normally.
image_present_on_all_kind_nodes() {
    local img="$1" nodes node
    [[ "$(cluster_flavour)" == "kind" ]] || return 1
    nodes="$(kind get nodes --name "${KIND_CLUSTER_NAME}" 2>/dev/null)" || return 1
    [[ -n "${nodes}" ]] || return 1
    while IFS= read -r node; do
        [[ -n "${node}" ]] || continue
        docker exec "${node}" crictl inspecti "${img}" >/dev/null 2>&1 || return 1
    done <<< "${nodes}"
}

assert_runtime_images_are_available_or_authenticated() {
    local image missing_count=0
    local -a missing_images=()

    # An image archive can make a local setup fully offline. If it did not
    # contain every Docker Hub image, do not begin a large anonymous pull that
    # will fail part-way through a customer setup because of registry quotas.
    registry_has_credentials && return 0
    # With IMAGE_REGISTRY set every pull needs credentials; that case is
    # reported by ensure_runtime_registry_login.
    [[ -n "${IMAGE_REGISTRY}" ]] && return 0
    for image in "$@"; do
        if is_docker_hub_image "${image}" \
            && ! docker image inspect "${image}" >/dev/null 2>&1 \
            && ! image_present_on_all_kind_nodes "${image}"; then
            missing_images+=("${image}")
        fi
    done
    missing_count="${#missing_images[@]}"
    [[ "${missing_count}" -eq 0 ]] && return 0

    warn "${missing_count} Docker Hub image(s) are missing from Docker and the cluster and no Docker Hub credentials (REGISTRY_USERNAME/REGISTRY_PASSWORD) are configured."
    for image in "${missing_images[@]:0:5}"; do
        warn "  missing: ${image}"
    done
    if (( missing_count > 5 )); then
        warn "  ... plus $(( missing_count - 5 )) more"
    fi
    warn "Set REGISTRY_USERNAME/REGISTRY_PASSWORD, or provide a complete RUNTIME_IMAGES_ARCHIVE, then re-run scripts/prepare-images.sh."
    return 1
}

# Detect which flavour of cluster the active kubectl context points at, so
# locally-built images are side-loaded the way that cluster actually accepts.
# `kind load docker-image` is KinD-only: on k3s it finds no matching cluster,
# warns, and skips — leaving every locally-built image (install-app,
# install-agent, the SRE agents, itbench-experiment) absent from the cluster and
# every pod that references one stuck in ImagePullBackOff. Since none of those
# images are published to a registry, there is no runtime pull to fall back on.
#
# Cached after the first call: this shells out to the API server.
ACE_CLUSTER_FLAVOUR=""
cluster_flavour() {
    if [[ -n "${ACE_CLUSTER_FLAVOUR}" ]]; then
        echo "${ACE_CLUSTER_FLAVOUR}"
        return 0
    fi

    # A KinD cluster matching this checkout's name wins outright — it is the
    # deliberate, instance-scoped target this repo's tooling creates.
    if kind get clusters 2>/dev/null | grep -qxF "${KIND_CLUSTER_NAME}"; then
        ACE_CLUSTER_FLAVOUR="kind"
        echo "${ACE_CLUSTER_FLAVOUR}"
        return 0
    fi

    # Otherwise ask the cluster itself what runtime it runs, the same signal
    # litmus-go's socket-path resolver uses (pkg/utils/common/runtime.go).
    local rv
    rv="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || true)"
    case "${rv,,}" in
        *k3s*)       ACE_CLUSTER_FLAVOUR="k3s" ;;
        containerd*) ACE_CLUSTER_FLAVOUR="containerd" ;;
        cri-o*|crio*) ACE_CLUSTER_FLAVOUR="crio" ;;
        docker*)     ACE_CLUSTER_FLAVOUR="docker" ;;
        "")          ACE_CLUSTER_FLAVOUR="unreachable" ;;
        *)           ACE_CLUSTER_FLAVOUR="other" ;;
    esac
    echo "${ACE_CLUSTER_FLAVOUR}"
}

# Import a local docker image into a k3s cluster's own containerd namespace.
# k3s keeps its image store behind /run/k3s/containerd/containerd.sock, which is
# root-owned, so this needs either root or passwordless sudo. Both are attempted
# without prompting; if neither works the exact command is printed rather than
# hanging on a password prompt inside a setup script.
k3s_import() {
    local img="$1"
    local ctr_bin=""
    for candidate in k3s /usr/local/bin/k3s; do
        if command -v "${candidate}" &>/dev/null; then ctr_bin="${candidate}"; break; fi
    done
    if [[ -z "${ctr_bin}" ]]; then
        warn "k3s cluster detected but the 'k3s' binary is not on PATH — cannot import ${img}"
        return 1
    fi

    if docker image inspect "${img}" &>/dev/null; then
        if docker save "${img}" | "${ctr_bin}" ctr images import - &>/dev/null; then
            ok "k3s import: ${img} → k3s containerd"
            return 0
        fi
        if docker save "${img}" | sudo -n "${ctr_bin}" ctr images import - &>/dev/null; then
            ok "k3s import: ${img} → k3s containerd (via sudo)"
            return 0
        fi
        warn "Could not import ${img} into k3s — needs root on /run/k3s/containerd/containerd.sock."
        warn "Run this once by hand, then re-run this script:"
        warn "  docker save ${img} | sudo ${ctr_bin} ctr images import -"
        return 1
    fi

    warn "${img} is not present in the local docker image store — nothing to import"
    return 1
}

kind_load() {
    local img="$1"
    local flavour
    flavour="$(cluster_flavour)"

    case "${flavour}" in
        k3s)
            k3s_import "${img}"
            return $?
            ;;
        containerd|crio|docker|other)
            warn "Cluster runtime '${flavour}' has no local side-load path — ${img} must come from a registry."
            warn "Either push it and set the matching *_IMAGE_SOURCE to that registry, or run on KinD/k3s."
            return 1
            ;;
        unreachable)
            warn "No reachable cluster (kubectl returned nothing) — skipping side-load of ${img}."
            warn "Re-run this script once the cluster is up."
            return 1
            ;;
    esac

    # flavour == kind
    if kind get clusters 2>/dev/null | grep -qxF "${KIND_CLUSTER_NAME}"; then
        mkdir -p "${ACE_KIND_LOAD_TMPDIR}" || {
            warn "Could not create ACE_KIND_LOAD_TMPDIR='${ACE_KIND_LOAD_TMPDIR}' — falling back to kind's default temp directory"
            ACE_KIND_LOAD_TMPDIR=""
        }
        if TMPDIR="${ACE_KIND_LOAD_TMPDIR:-${TMPDIR:-/tmp}}" kind load docker-image "${img}" --name "${KIND_CLUSTER_NAME}"; then
            ok "kind load: ${img} → cluster '${KIND_CLUSTER_NAME}'"
            return 0
        else
            warn "kind load failed for ${img} — pods will pull from registry at runtime"
            return 1
        fi
    else
        warn "KinD cluster '${KIND_CLUSTER_NAME}' not found — skipping kind load for ${img}"
        warn "Re-run this script after the cluster is created."
        return 1
    fi
}

# Fallback for images `kind load docker-image` cannot transfer -- observed
# with multi-arch manifest-list images (e.g. litmuschaos/go-runner,
# litmuschaos/litmus-app-deployer): `docker pull` only fetches the host's
# platform, but kind's underlying `ctr images import --all-platforms` still
# tries to import every platform listed in the manifest index and fails with
# "content digest ... not found" for the platforms never actually pulled.
# Pulling directly on each node via containerd/crictl sidesteps the
# export/import round-trip entirely -- crictl resolves only the node's own
# platform, the same way a pod's normal image pull already would. Only
# meaningful for registry-backed images (the litmus helpers); images that
# exist solely as local docker builds (install-app, install-agent, the SRE
# agents, itbench-experiment) have nowhere for this fallback to pull from.
node_crictl_pull() {
    local img="$1"
    local nodes
    nodes="$(kind get nodes --name "${KIND_CLUSTER_NAME}" 2>/dev/null)"
    if [[ -z "${nodes}" ]]; then
        return 1
    fi
    local node ok_all=0 mirror_img target_img normalized_img first_component
    normalized_img="${img#docker.io/}"
    first_component="${normalized_img%%/*}"
    if [[ "${normalized_img}" != */* ]]; then
        mirror_img="mirror.gcr.io/library/${normalized_img}"
        target_img="docker.io/library/${normalized_img}"
    elif [[ "${first_component}" == *.* || "${first_component}" == *:* || "${first_component}" == "localhost" ]]; then
        mirror_img=""
        target_img="${img}"
    else
        mirror_img="mirror.gcr.io/${normalized_img}"
        target_img="docker.io/${normalized_img}"
    fi
    while IFS= read -r node; do
        [[ -z "${node}" ]] && continue
        if docker exec "${node}" crictl pull "${img}" >/dev/null 2>&1; then
            ok "node pull: ${img} → node '${node}' (kind load fallback)"
        elif [[ -n "${mirror_img}" ]] \
             && docker exec "${node}" crictl pull "${mirror_img}" >/dev/null 2>&1 \
             && docker exec "${node}" ctr --namespace=k8s.io images tag "${mirror_img}" "${target_img}" >/dev/null 2>&1; then
            ok "node pull: ${mirror_img} → node '${node}' (public mirror fallback)"
        else
            warn "node pull fallback also failed for ${img} on node '${node}'"
            ok_all=1
        fi
    done <<< "${nodes}"
    return "${ok_all}"
}

# ─── immutable local hub bundle ──────────────────────────────────────────────
# Build one immutable image from the exact checked-out hub trees. This is the
# only hub source used by Kubernetes deployments; no runtime Git clone exists.
build_and_load_hub_bundle() {
    local dockerfile="${REPO_ROOT}/deploy/hub-bundle/Dockerfile"
    local content_sha current_sha
    if [[ ! -f "${dockerfile}" ]]; then
        warn "Hub bundle Dockerfile not found: ${dockerfile}"
        return 1
    fi

    content_sha="$(hub_bundle_content_sha "${REPO_ROOT}")"
    if [[ -z "${content_sha}" ]]; then
        warn "Could not compute hub bundle content digest"
        return 1
    fi

    current_sha="$(docker image inspect \
        --format '{{ index .Config.Labels "io.agentcert.hub-bundle.content-sha" }}' \
        "${HUB_BUNDLE_IMAGE}" 2>/dev/null || true)"

    if [[ "${current_sha}" == "${content_sha}" ]]; then
        ok "${HUB_BUNDLE_IMAGE} already matches local hub content (${content_sha:0:12})"
    else
        info "Building ${HUB_BUNDLE_IMAGE} from local hub trees (${content_sha:0:12}) …"
        hub_bundle_build "${REPO_ROOT}" "${HUB_BUNDLE_IMAGE}" \
            || { warn "Building ${HUB_BUNDLE_IMAGE} failed"; return 1; }
        ok "Built ${HUB_BUNDLE_IMAGE}"
    fi

    kind_load "${HUB_BUNDLE_IMAGE}"
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
    # Context must be APP_CHARTS_ROOT (not .../install-app) -- the Dockerfile's
    # `COPY install-app/go.mod ./` and `COPY charts/ /charts/` both resolve
    # relative to the build context, and `charts/` is a sibling of
    # `install-app/`, not nested inside it. build-and-push.sh already gets
    # this right; this was previously a copy-paste-shifted-one-level-deep bug
    # that made every "local" install-app build here fail outright.
    local ctx="${APP_CHARTS_ROOT}"
    local img="${INSTALL_APP_IMAGE}"
    if image_already_built "${img}"; then
        ok "${img} already built + kind-loaded by setup.sh's build step this run — skipping redundant rebuild"
        return 0
    fi
    if [[ ! -f "${dockerfile}" ]]; then
        warn "Dockerfile not found: ${dockerfile} — skipping install-app local build"
        return 1
    fi
    info "Building ${img} from ${ctx} …"
    docker_build_resolved "${dockerfile}" -t "${img}" "${ctx}" \
        || { warn "Building ${img} failed"; return 1; }
    ok "Built ${img}"
    kind_load "${img}"
}

build_and_load_install_agent() {
    local dockerfile="${AGENT_CHARTS_ROOT}/install-agent/Dockerfile"
    # Same context fix as build_and_load_install_app above -- charts/ is a
    # sibling of install-agent/, not nested inside it.
    local ctx="${AGENT_CHARTS_ROOT}"
    local img="${INSTALL_AGENT_IMAGE}"
    if image_already_built "${img}"; then
        ok "${img} already built + kind-loaded by setup.sh's build step this run — skipping redundant rebuild"
        return 0
    fi
    if [[ ! -f "${dockerfile}" ]]; then
        warn "Dockerfile not found: ${dockerfile} — skipping install-agent local build"
        return 1
    fi
    info "Building ${img} from ${ctx} …"
    docker_build_resolved "${dockerfile}" -t "${img}" "${ctx}" \
        || { warn "Building ${img} failed"; return 1; }
    ok "Built ${img}"
    kind_load "${img}"
}

build_and_load_sre_agent() {
    local name="$1"   # e.g. sre-agent-comprehensive
    local img="$2"    # e.g. agentcert/sre-agent-comprehensive:latest
    local ctx="${3:-${REPO_ROOT}/agents/${name}}"
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
    docker_build_resolved "${dockerfile}" --network=host -t "${img}" "${ctx}" \
        || { warn "Building ${img} failed"; return 1; }
    ok "Built ${img}"
    kind_load "${img}"
}

build_and_load_itbench_experiment() {
    local dockerfile="${REPO_ROOT}/litmus-go/build/Dockerfile.itbench"
    local ctx="${REPO_ROOT}/litmus-go"
    local img="agentcert/itbench-experiment:dev"
    if image_already_built "${img}"; then
        ok "${img} already built + kind-loaded by setup.sh's build step this run — skipping redundant rebuild"
        return 0
    fi
    if [[ ! -f "${dockerfile}" ]]; then
        warn "Dockerfile not found: ${dockerfile} — skipping itbench-experiment local build"
        return 1
    fi
    info "Building ${img} from ${ctx} (Dockerfile.itbench) …"
    docker_build_resolved "${dockerfile}" -t "${img}" "${ctx}" \
        || { warn "Building ${img} failed"; return 1; }
    ok "Built ${img}"
    kind_load "${img}"
}

bundled_application_images() {
    # Render charts from the install-app image, not the host checkout. The image
    # contains the resolved OTel subchart and is the exact chart payload Argo
    # will execute, so this cannot drift from workflow runtime content.
    local installer_image="${INSTALL_APP_IMAGE}"
    if ! docker image inspect "${installer_image}" >/dev/null 2>&1; then
        warn "Cannot enumerate bundled app images: ${installer_image} is not built locally." >&2
        return 1
    fi

    local charts
    if ! charts="$(docker run --rm --entrypoint sh "${installer_image}" -ec '
        for chart in /charts/*/; do
            [ -f "${chart}Chart.yaml" ] && basename "${chart%/}"
        done
    ' | sort)"; then
        warn "Could not enumerate charts from ${installer_image}." >&2
        return 1
    fi
    if [[ -z "${charts}" ]]; then
        warn "No bundled application charts found in ${installer_image}." >&2
        return 1
    fi

    local chart rendered
    while IFS= read -r chart; do
        [[ -n "${chart}" ]] || continue
        if ! rendered="$(docker run --rm --entrypoint helm "${installer_image}" \
                template "ace-image-scan" "/charts/${chart}")"; then
            warn "Could not render /charts/${chart} from ${installer_image}." >&2
            return 1
        fi
        # Pod specs may render as `image: x` or list-form `- image: x`.
        # Strip either quote style and reject unresolved template fragments.
        awk '{
                 for (i=1; i<NF; i++) if ($i == "image:") {
                     image=$(i+1); gsub(/["\047]/, "", image);
                     if (image != "" && image !~ /[{}]/) print image
                 }
             }' <<<"${rendered}"
    done <<<"${charts}" | sort -u
}

pull_and_load_runtime_images() {
    # Infrastructure and workflow images that Kubernetes must find in each node's
    # image store when running locally. Keep this aligned with the platform
    # metricsServer image and every image referenced by bundled fault templates.
    # For each image we also load an alias under any alternative registry names
    # that stored experiment manifests may reference (JFrog, Scarf proxy).
    local images=(
        "${SUBSCRIBER_IMAGE}"
        "${EVENT_TRACKER_IMAGE}"
        "${ARGO_WORKFLOW_CONTROLLER_IMAGE}"
        "${ARGO_WORKFLOW_EXECUTOR_IMAGE}"
        "${CHAOS_OPERATOR_IMAGE}"
        "${CHAOS_RUNNER_IMAGE}"
        "${CHAOS_EXPORTER_IMAGE}"
        "litmuschaos/k8s:latest"
        "litmuschaos/litmus-checker:latest"
        "litmuschaos/litmus-app-deployer:latest"
        "litmuschaos/go-runner:latest"
        "alexeiled/stress-ng:latest-ubuntu"
        "gaiadocker/iproute2:latest"
        "registry.k8s.io/metrics-server/metrics-server:v0.7.2"
    )

    local app_images img
    if ! app_images="$(bundled_application_images)"; then
        return 1
    fi
    while IFS= read -r img; do
        [[ -n "${img}" ]] || continue
        # Kubernetes/Docker normalize an omitted tag to :latest. Normalize here
        # too so equivalent references are not pulled/transferred twice.
        if [[ "${img}" != *@* && "${img##*/}" != *:* ]]; then
            img="${img}:latest"
        fi
        images+=("${img}")
    done <<<"${app_images}"
    # Monitoring/helper images repeat across charts. Transfer each exact image
    # reference once and keep the execution/log order deterministic.
    mapfile -t images < <(printf '%s\n' "${images[@]}" | sort -u)

    preload_runtime_images_archive || return 1
    assert_runtime_images_are_available_or_authenticated "${images[@]}" || return 1

    # Each image pulls (network-bound) and kind-loads independently of every
    # other, so serializing the complete set is unnecessary wall-clock cost.
    # Keep concurrency bounded for the same shared-host reason as setup.sh's build loop
    # (see ACE_BUILD_PARALLELISM there); override via ACE_PULL_PARALLELISM.
    # `kind load docker-image` against the same node concurrently from
    # multiple processes isn't officially documented as safe, but containerd's
    # content store is content-addressed with its own internal locking and
    # this is a common pattern in CI pipelines; a failed load here was already
    # a non-fatal warning before this change, so the worst case is unchanged.
    local parallelism="${ACE_PULL_PARALLELISM:-4}"
    if ! [[ "${parallelism}" =~ ^[1-9][0-9]*$ ]]; then
        warn "Ignoring invalid ACE_PULL_PARALLELISM=${parallelism@Q}; using 4"
        parallelism=4
    fi
    local pull_retries="${ACE_IMAGE_PULL_RETRIES:-3}"
    if ! [[ "${pull_retries}" =~ ^[1-9][0-9]*$ ]]; then
        warn "Ignoring invalid ACE_IMAGE_PULL_RETRIES=${pull_retries@Q}; using 3"
        pull_retries=3
    fi
    local refresh_runtime_images="${ACE_REFRESH_RUNTIME_IMAGES:-0}"
    local results_dir; results_dir="$(mktemp -d "${REPO_ROOT}/.tmp/runtime-pull-results.XXXXXX" 2>/dev/null || mktemp -d)"
    local log_dir="${REPO_ROOT}/.tmp/runtime-pull-logs"
    rm -rf "${log_dir}"; mkdir -p "${log_dir}"

    _pull_and_load_one() {
        local img="$1" idx="$2" attempt=1 pull_ok=0 pull_output retry_delay cached=0
        {
            if [[ "${refresh_runtime_images}" != "1" ]] \
                && ! docker image inspect "${img}" >/dev/null 2>&1 \
                && image_present_on_all_kind_nodes "${img}"; then
                echo "Already present on every KinD node: ${img}"
                echo ok > "${results_dir}/${idx}.status"
                return 0
            fi
            # A local-first restart must be repeatable and offline. Docker pull
            # still contacts a registry for an already-cached mutable tag, so
            # avoid it unless an operator explicitly requests a refresh.
            if docker image inspect "${img}" >/dev/null 2>&1 && [[ "${refresh_runtime_images}" != "1" ]]; then
                echo "Using cached local image ${img}"
                pull_ok=1
                cached=1
            else
                echo "Pulling ${img} from $(registry_ref "${img}") …"
                while (( attempt <= pull_retries )); do
                    if pull_output="$(pull_runtime_image "${img}")"; then
                        printf '%s\n' "${pull_output}"
                        echo "Pulled ${img}"
                        pull_ok=1
                        break
                    fi
                    printf '%s\n' "${pull_output}"
                    if [[ "${pull_output}" =~ [Rr]ate[[:space:]-]*limit|429[[:space:]]Too[[:space:]]Many[[:space:]]Requests ]]; then
                        echo "Pull rate limit reached for ${img}; set REGISTRY_USERNAME/REGISTRY_PASSWORD (Docker Hub) or wait for its quota window."
                        break
                    fi
                    if (( attempt == pull_retries )); then
                        break
                    fi
                    retry_delay=$(( 5 * (2 ** (attempt - 1)) ))
                    echo "Pull attempt ${attempt}/${pull_retries} failed for ${img}; retrying in ${retry_delay}s …"
                    sleep "${retry_delay}"
                    attempt=$(( attempt + 1 ))
                done
            fi

            if [[ "${pull_ok}" -eq 1 ]]; then
                local load_ok=1
                if kind_load "${img}"; then
                    load_ok=0
                else
                    # A cached Docker image can have missing blobs (for example
                    # after an interrupted pull). Refresh that public image once
                    # before falling back to a direct pull inside the KinD node.
                    if [[ "${cached}" -eq 1 ]]; then
                        echo "Cached image ${img} failed to load; refreshing it from its registry …"
                        if pull_output="$(pull_runtime_image "${img}")"; then
                            printf "%s\n" "${pull_output}"
                            if kind_load "${img}"; then
                                load_ok=0
                            fi
                        else
                            printf "%s\n" "${pull_output}"
                        fi
                    fi
                    if [[ "${load_ok}" -ne 0 ]] && node_crictl_pull "${img}"; then
                        echo "kind load failed for ${img} but node-side crictl pull fallback succeeded"
                        load_ok=0
                    fi
                fi
                if [[ "${img}" == "litmuschaos/go-runner:latest" ]]; then
                    local scarf="litmuschaos.docker.scarf.sh/litmuschaos/go-runner:latest"
                    docker tag "${img}" "${scarf}"
                    if ! kind_load "${scarf}"; then
                        node_crictl_pull "${scarf}" || warn "could not get ${scarf} onto the cluster by any method"
                    fi
                fi
                if [[ "${load_ok}" -eq 0 ]]; then
                    echo ok > "${results_dir}/${idx}.status"
                else
                    echo "Neither kind load nor node-side pull could get ${img} onto the cluster"
                    echo failed > "${results_dir}/${idx}.status"
                fi
            else
                echo "Pull failed for ${img}"
                echo failed > "${results_dir}/${idx}.status"
            fi
        } >"${log_dir}/${idx}.log" 2>&1
    }
    info "Pulling ${#images[@]} workflow runtime image(s), up to ${parallelism} at a time — logs: ${log_dir}/"
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

    local i status failed=0
    for (( i = 0; i < idx; i++ )); do
        status="$(cat "${results_dir}/${i}.status" 2>/dev/null || echo missing)"
        if [[ "${status}" == "ok" ]]; then
            ok "Pulled + loaded: ${images[i]}"
        else
            failed=1
            warn "Failed: ${images[i]} — log: ${log_dir}/${i}.log"
        fi
    done
    if [[ "${failed}" -eq 0 && -n "${RUNTIME_IMAGES_EXPORT_PATH}" ]]; then
        local export_parent
        export_parent="$(dirname "${RUNTIME_IMAGES_EXPORT_PATH}")"
        if [[ -d "${RUNTIME_IMAGES_EXPORT_PATH}" ]]; then
            warn "RUNTIME_IMAGES_EXPORT_PATH is a directory, not an archive file: ${RUNTIME_IMAGES_EXPORT_PATH}"
            failed=1
        elif ! mkdir -p "${export_parent}" || ! docker save -o "${RUNTIME_IMAGES_EXPORT_PATH}" "${images[@]}"; then
            warn "Could not write workflow runtime image archive: ${RUNTIME_IMAGES_EXPORT_PATH}"
            failed=1
        else
            ok "Wrote workflow runtime image archive: ${RUNTIME_IMAGES_EXPORT_PATH}"
        fi
    fi
    rm -rf "${results_dir}"
    return "${failed}"
}

# ─── registry: create pull secret + patch service account ────────────────────

ensure_registry_pull_secret() {
    if [[ -z "${IMAGE_REGISTRY}" ]]; then
        return 0   # public registries — nothing to authenticate
    fi
    if ! registry_has_credentials; then
        warn "REGISTRY_USERNAME or REGISTRY_PASSWORD not set in .env — cannot create pull secret"
        warn "Set them and re-run this script (or scripts/apply_cluster_prereqs.sh)."
        return 1
    fi

    local namespaces
    namespaces="$(experiment_namespaces)"
    if [[ -z "${namespaces}" ]]; then
        warn "No experiment namespaces found on the cluster (itbench, sock-shop, book-info, otel-demo)."
        warn "registry-secret-sync (scripts/apply_cluster_prereqs.sh) covers them once they are created."
        return 0
    fi

    # Same helpers as scripts/apply_cluster_prereqs.sh (scripts/lib/registry.sh).
    while IFS= read -r ns; do
        [[ -z "${ns}" ]] && continue
        if registry_ns_opted_out "${ns}"; then
            info "${ns}: skipped (labelled ace.registry-sync=disabled)"
            continue
        fi
        if registry_secret_apply "${ns}"; then
            ok "${IMAGE_PULL_SECRET_NAME} applied in namespace ${ns}"
        else
            warn "could not apply ${IMAGE_PULL_SECRET_NAME} in namespace ${ns}"
            continue
        fi
        if registry_sa_attach "${ns}" argo-chaos; then
            ok "argo-chaos uses ${IMAGE_PULL_SECRET_NAME} in namespace ${ns}"
        else
            warn "argo-chaos service account not found in ${ns} — skipping"
        fi
    done <<< "${namespaces}"
}

# ─── main ────────────────────────────────────────────────────────────────────

_did_something=0
declare -a _failures=()
case "${HUB_BUNDLE_SRC}" in
    local)
        if [[ "${ACE_HUB_BUNDLE_PREPARED:-0}" == "1" && "${HUB_ONLY}" != "--hub-only" ]]; then
            ok "hub-bundle: already built + loaded earlier in this setup run"
        else
            info "hub-bundle: build from checked-out app/agent/chaos charts"
            build_and_load_hub_bundle
            _did_something=1
        fi
        ;;
    registry)
        if [[ "${HUB_BUNDLE_IMAGE}" == *":local" ]]; then
            warn "HUB_BUNDLE_IMAGE_SOURCE=registry requires a pullable HUB_BUNDLE_IMAGE, not ${HUB_BUNDLE_IMAGE}"
            exit 1
        fi
        info "hub-bundle: registry image ${HUB_BUNDLE_IMAGE}"
        ;;
    *)
        warn "Unsupported HUB_BUNDLE_IMAGE_SOURCE='${HUB_BUNDLE_SRC}' (expected local or registry)"
        exit 1
        ;;
esac

if [[ "${HUB_ONLY}" == "--hub-only" ]]; then
    ok "Hub bundle is ready."
    exit 0
elif [[ -n "${HUB_ONLY}" ]]; then
    warn "Unknown argument: ${HUB_ONLY}"
    exit 2
fi


case "${APP_SRC}" in
    local)
        info "install-application: local build"
        if build_and_load_install_app; then
            _did_something=1
        else
            _failures+=("install-application")
        fi
        ;;
    registry)
        info "install-application: registry ($(registry_ref "${INSTALL_APP_IMAGE}"), pulled at runtime)"
        if [[ -n "${IMAGE_REGISTRY}" ]]; then
            ensure_registry_pull_secret && _did_something=1
        fi
        ;;
esac

case "${AGENT_SRC}" in
    local)
        info "install-agent: local build"
        if build_and_load_install_agent; then
            _did_something=1
        else
            _failures+=("install-agent")
        fi
        ;;
    registry)
        info "install-agent: registry ($(registry_ref "${INSTALL_AGENT_IMAGE}"), pulled at runtime)"
        # Pull secret already created above if APP_SRC was also registry; idempotent if called again
        if [[ -n "${IMAGE_REGISTRY}" && "${APP_SRC}" != "registry" ]]; then
            ensure_registry_pull_secret && _did_something=1
        fi
        ;;
esac

case "${LITMUS_SRC}" in
    local)
        info "runtime dependencies: pull once + load into the local cluster"
        if ensure_runtime_registry_login && pull_and_load_runtime_images; then
            _did_something=1
        else
            _failures+=("workflow-runtime-images")
        fi
        ;;
    registry)
        info "workflow runtime images: registry mode — pulled by Kubernetes at runtime from ${IMAGE_REGISTRY:-public registries}"
        ;;
esac

case "${SRE_AGENTS_SRC}" in
    local)
        # Every agent in agents.chartserviceversion.yaml, plus the sidecar all of
        # them run beside. Leaving any of these to a Docker Hub :latest pull would
        # run code from a different revision than this checkout.
        info "flash-agent: local build"
        if build_and_load_sre_agent "flash-agent" "agentcert/agentcert-flash-agent:latest"; then
            _did_something=1
        else
            _failures+=("flash-agent")
        fi
        info "agent-sidecar: local build"
        if build_and_load_sre_agent "agent-sidecar" "agentcert/agent-sidecar:latest" "${REPO_ROOT}/agent-sidecar"; then
            _did_something=1
        else
            _failures+=("agent-sidecar")
        fi
        info "sre-agent-comprehensive: local build"
        if build_and_load_sre_agent "sre-agent-comprehensive" "agentcert/sre-agent-comprehensive:latest"; then
            _did_something=1
        else
            _failures+=("sre-agent-comprehensive")
        fi
        info "sre-agent-crewai: local build"
        if build_and_load_sre_agent "sre-agent-crewai" "agentcert/sre-agent-crewai:latest"; then
            _did_something=1
        else
            _failures+=("sre-agent-crewai")
        fi
        ;;
    registry)
        info "sre-agents: registry — no action needed (pulled at runtime from ${IMAGE_REGISTRY:-Docker Hub})"
        ;;
esac

case "${ITBENCH_EXPERIMENT_SRC}" in
    local)
        info "itbench-experiment: local build"
        if build_and_load_itbench_experiment; then
            _did_something=1
        else
            _failures+=("itbench-experiment")
        fi
        ;;
    registry)
        if [[ -z "${IMAGE_REGISTRY}" ]]; then
            warn "itbench-experiment: registry selected with IMAGE_REGISTRY empty, but no image has" \
                 "ever been published to docker.io/agentcert/itbench-experiment — every ITBench" \
                 "fault under chaos-charts/faults/itbench/ will hit ImagePullBackOff. Use 'local' instead."
        else
            info "itbench-experiment: registry ($(registry_ref agentcert/itbench-experiment:dev), pulled at runtime)"
        fi
        ;;
esac

if (( ${#_failures[@]} > 0 )); then
    warn "Required image preparation failed: ${_failures[*]}"
    warn "Experiments that use these images would fail with ImagePullBackOff; fix the build above and re-run scripts/prepare-images.sh."
    exit 1
fi

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
    ok "Nothing to do — all sources are 'registry' (images pulled at runtime from ${IMAGE_REGISTRY:-public registries})."
fi
echo
