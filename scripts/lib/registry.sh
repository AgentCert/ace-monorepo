# shellcheck shell=bash
# scripts/lib/registry.sh — the one place that knows how image names map to a
# registry. Sourced by check-registry-images.sh, mirror-images.sh and
# build-and-push.sh.
#
# Naming rule (every image is written in the repo by its upstream public name):
#   IMAGE_REGISTRY set   -> <IMAGE_REGISTRY>/<public name>
#       The public name keeps its own registry host (quay.io/..., ghcr.io/...),
#       which is how JFrog docker-local already stores non-Docker-Hub images.
#   IMAGE_REGISTRY empty -> the frozen copy on Docker Hub,
#       docker.io/<IMAGE_MIRROR_NAMESPACE>/<flat name> (default namespace
#       agentcert). Docker Hub repos cannot nest, so the flat name drops the
#       registry host and turns "/" into "-":
#         mongo:5                    -> agentcert/mongo:5
#         litmuschaos/k8s:latest     -> agentcert/litmuschaos-k8s:latest
#         quay.io/containers/x:v1    -> agentcert/containers-x:v1
#       ACE's own images (already agentcert/...) are unchanged. The copies keep
#       upstream changes or deletions from breaking ACE (scripts/mirror-images.sh
#       makes them). IMAGE_MIRROR_NAMESPACE=none uses the upstream names as-is.
#
# Settings are read from the environment first (so `IMAGE_REGISTRY= ./script`
# forces the public path), then from .env:
#   IMAGE_REGISTRY                      e.g. infyartifactory.jfrog.io/docker-local
#   IMAGE_MIRROR_NAMESPACE              Docker Hub namespace of the frozen
#                                       copies (default agentcert; none = upstream)
#   REGISTRY_USERNAME / REGISTRY_PASSWORD   credentials for IMAGE_REGISTRY, or
#     for Docker Hub when IMAGE_REGISTRY is empty (optional there). Legacy
#     JFROG_* / DOCKERHUB_* keys are read as a fallback.

# Print the last value of KEY in ENV_FILE, or nothing if absent.
env_file_value() {
    local key="$1" file="$2"
    [[ -f "${file}" ]] || return 0
    grep -E "^${key}=" "${file}" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# True when a value is empty or still a .env.example placeholder.
value_is_unset() {
    [[ -z "$1" || "$1" == *YOUR_* || "$1" == *REPLACE_ME* || "$1" == *CHANGE_ME* ]]
}

# Normalise an *_IMAGE_SOURCE value to local | registry. "jfrog" and
# "dockerhub" are the legacy names for registry: which registry is decided by
# IMAGE_REGISTRY alone. Other values are passed through lower-cased.
image_source_normalize() {
    case "${1,,}" in
        jfrog|dockerhub|registry) printf 'registry' ;;
        *)                        printf '%s' "${1,,}" ;;
    esac
}

# True when REGISTRY_USERNAME and REGISTRY_PASSWORD are both set.
registry_has_credentials() {
    [[ -n "${REGISTRY_USERNAME:-}" && -n "${REGISTRY_PASSWORD:-}" ]]
}

# Turn whatever the user typed into "host/path" with no scheme or trailing
# slash. Also accepts the Artifactory UI address
# (https://host/ui/native/<repo>/) because that is what people copy from the
# browser.
registry_normalize() {
    local r="$1"
    r="${r#http://}"; r="${r#https://}"
    r="${r//\/ui\/native\//\/}"
    r="${r%/}"
    printf '%s' "${r}"
}

# Load IMAGE_REGISTRY + credentials into the shell. Fails (return 1) on a value
# that cannot work, e.g. a JFrog host with no repository key.
registry_load() {
    local env_file="$1"
    if [[ -z "${IMAGE_REGISTRY+x}" ]]; then
        IMAGE_REGISTRY="$(env_file_value IMAGE_REGISTRY "${env_file}")"
    fi
    IMAGE_REGISTRY="$(registry_normalize "${IMAGE_REGISTRY}")"
    if [[ -z "${IMAGE_MIRROR_NAMESPACE+x}" ]]; then
        IMAGE_MIRROR_NAMESPACE="$(env_file_value IMAGE_MIRROR_NAMESPACE "${env_file}")"
    fi
    IMAGE_MIRROR_NAMESPACE="${IMAGE_MIRROR_NAMESPACE:-agentcert}"
    # Tag for every ACE-built image (e.g. RELEASE-3); empty keeps each own tag.
    if [[ -z "${ACE_IMAGE_TAG+x}" ]]; then
        ACE_IMAGE_TAG="$(env_file_value ACE_IMAGE_TAG "${env_file}")"
    fi
    ACE_IMAGE_TAG="$(printf '%s' "${ACE_IMAGE_TAG}" | tr -d '[:space:]')"

    # REGISTRY_* in .env belong to the IMAGE_REGISTRY written in .env. When the
    # caller overrides IMAGE_REGISTRY to empty (`IMAGE_REGISTRY= ./script`) on a
    # .env that names a private registry, those are the wrong credentials for
    # Docker Hub — fall through to DOCKERHUB_* instead.
    local env_registry
    REGISTRY_USERNAME="${REGISTRY_USERNAME:-}"; REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-}"
    env_registry="$(registry_normalize "$(env_file_value IMAGE_REGISTRY "${env_file}")")"
    if [[ -n "${IMAGE_REGISTRY}" || -z "${env_registry}" ]]; then
        REGISTRY_USERNAME="${REGISTRY_USERNAME:-$(env_file_value REGISTRY_USERNAME "${env_file}")}"
        REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-$(env_file_value REGISTRY_PASSWORD "${env_file}")}"
    fi
    # Legacy key fallbacks for .env files written before the REGISTRY_* keys
    # existed: JFROG_* belonged to a private registry, DOCKERHUB_* to Docker
    # Hub, so each only applies to the matching IMAGE_REGISTRY setting.
    if [[ -n "${IMAGE_REGISTRY}" ]]; then
        [[ -z "${REGISTRY_USERNAME}" ]] && REGISTRY_USERNAME="$(env_file_value JFROG_USER "${env_file}")"
        [[ -z "${REGISTRY_PASSWORD}" ]] && REGISTRY_PASSWORD="$(env_file_value JFROG_TOKEN "${env_file}")"
    else
        [[ -z "${REGISTRY_USERNAME}" ]] && REGISTRY_USERNAME="$(env_file_value DOCKERHUB_USERNAME "${env_file}")"
        [[ -z "${REGISTRY_PASSWORD}" ]] && REGISTRY_PASSWORD="$(env_file_value DOCKERHUB_TOKEN "${env_file}")"
    fi
    # Template placeholders count as unset.
    if value_is_unset "${REGISTRY_USERNAME}" || value_is_unset "${REGISTRY_PASSWORD}"; then
        REGISTRY_USERNAME=""; REGISTRY_PASSWORD=""
    fi

    if [[ -n "${IMAGE_REGISTRY}" && "${IMAGE_REGISTRY}" != */* && "${IMAGE_REGISTRY}" == *jfrog.io ]]; then
        echo "IMAGE_REGISTRY='${IMAGE_REGISTRY}' has no repository key." >&2
        echo "  JFrog needs host/<repo>, e.g. ${IMAGE_REGISTRY}/docker-local" >&2
        return 1
    fi
    IMAGE_PULL_SECRET_NAME="${IMAGE_PULL_SECRET_NAME:-$(env_file_value IMAGE_PULL_SECRET_NAME "${env_file}")}"
    IMAGE_PULL_SECRET_NAME="${IMAGE_PULL_SECRET_NAME:-registry-pull}"
    export IMAGE_REGISTRY REGISTRY_USERNAME REGISTRY_PASSWORD IMAGE_PULL_SECRET_NAME IMAGE_MIRROR_NAMESPACE
}

# Host part of IMAGE_REGISTRY (what `docker login` and pull secrets need).
registry_host() {
    printf '%s' "${IMAGE_REGISTRY%%/*}"
}

# Canonical public name: drop an explicit docker.io / library prefix and add
# :latest when no tag or digest is given, so "mongo", "docker.io/library/mongo"
# and "mongo:latest" all map to the same registry path.
image_canonical() {
    local ref="$1"
    case "${ref}" in
        docker.io/*)            ref="${ref#docker.io/}" ;;
        index.docker.io/*)      ref="${ref#index.docker.io/}" ;;
        registry-1.docker.io/*) ref="${ref#registry-1.docker.io/}" ;;
    esac
    ref="${ref#library/}"
    local last="${ref##*/}"
    if [[ "${last}" != *:* && "${ref}" != *@* ]]; then
        ref="${ref}:latest"
    fi
    printf '%s' "${ref}"
}

# Flat Docker Hub name of a canonical public name under namespace $2:
# drop the registry host, "/" -> "-". Images already in the namespace keep
# their name.   litmuschaos/k8s:latest agentcert -> agentcert/litmuschaos-k8s:latest
image_flat_ref() {
    local ref="$1" ns="$2" name tag first
    [[ "${ref}" == "${ns}/"* ]] && { printf '%s' "${ref}"; return; }
    name="${ref%:*}"; tag="${ref##*:}"
    first="${name%%/*}"
    if [[ "${name}" == */* && ( "${first}" == *.* || "${first}" == *:* || "${first}" == localhost ) ]]; then
        name="${name#*/}"
    fi
    printf '%s/%s:%s' "${ns}" "${name//\//-}" "${tag}"
}

# Images that have a frozen copy under IMAGE_MIRROR_NAMESPACE: the
# non-optional "mirror" rows of deploy/images.txt (loaded once).
declare -gA _REGISTRY_MIRRORED=()
_REGISTRY_MIRRORED_LOADED=0
image_is_mirrored() {
    if [[ "${_REGISTRY_MIRRORED_LOADED}" -eq 0 ]]; then
        local inv kind group image rest
        inv="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/deploy/images.txt"
        while IFS='|' read -r kind group image rest; do
            [[ "${kind}" == mirror && "${rest}" != *optional* ]] || continue
            _REGISTRY_MIRRORED["$(image_canonical "${image}")"]=1
        done < <(grep -v '^[[:space:]]*#' "${inv}" 2>/dev/null)
        _REGISTRY_MIRRORED_LOADED=1
    fi
    [[ -n "${_REGISTRY_MIRRORED[$1]:-}" ]]
}

# Images ACE builds itself: names (without tag) of the deploy/images.txt
# "build" rows (loaded once). ACE_IMAGE_TAG replaces their tag.
declare -gA _REGISTRY_ACE=()
_REGISTRY_ACE_LOADED=0
image_is_ace() {
    if [[ "${_REGISTRY_ACE_LOADED}" -eq 0 ]]; then
        local inv kind group image rest c
        inv="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/deploy/images.txt"
        while IFS='|' read -r kind group image rest; do
            [[ "${kind}" == build ]] || continue
            c="$(image_canonical "${image}")"
            _REGISTRY_ACE["${c%:*}"]=1
        done < <(grep -v '^[[:space:]]*#' "${inv}" 2>/dev/null)
        _REGISTRY_ACE_LOADED=1
    fi
    [[ "$1" != *@* && -n "${_REGISTRY_ACE[${1%:*}]:-}" ]]
}

# Canonical reference with ACE_IMAGE_TAG applied to ACE-built images.
image_retag() {
    if [[ -n "${ACE_IMAGE_TAG:-}" ]] && image_is_ace "$1"; then
        printf '%s:%s' "${1%:*}" "${ACE_IMAGE_TAG}"
    else
        printf '%s' "$1"
    fi
}

# <registry>/<canonical name>, without repeating the registry's last path
# segment: .../docker-local/agentcert + agentcert/certifier:x
# -> .../docker-local/agentcert/certifier:x
registry_join() {
    local reg="$1" ref="$2" seg
    if [[ "${reg}" == */* ]]; then
        seg="${reg##*/}"
        [[ "${ref}" == "${seg}/"* ]] && ref="${ref#"${seg}"/}"
    fi
    printf '%s/%s' "${reg}" "${ref}"
}

# Registry path images live under: <IMAGE_REGISTRY>/<IMAGE_MIRROR_NAMESPACE>,
# or IMAGE_REGISTRY itself when the namespace is "none" or already its last
# path segment.
registry_base() {
    local ns="${IMAGE_MIRROR_NAMESPACE:-agentcert}"
    if [[ -z "${IMAGE_REGISTRY}" || "${ns}" == none || "/${IMAGE_REGISTRY}" == */"${ns}" ]]; then
        printf '%s' "${IMAGE_REGISTRY}"
    else
        printf '%s/%s' "${IMAGE_REGISTRY}" "${ns}"
    fi
}

# Where an image lives under the current IMAGE_REGISTRY setting: set ->
# <registry_base>/<public name> (ACE's agentcert/x not doubled). With
# IMAGE_REGISTRY empty only images that have a frozen copy are renamed; others
# keep their upstream name. ACE-built images get ACE_IMAGE_TAG when it is set.
# Already-resolved references are returned unchanged.
registry_ref() {
    local ref
    ref="$(image_retag "$(image_canonical "$1")")"
    if [[ -n "${IMAGE_REGISTRY}" ]]; then
        if [[ "$1" == "${IMAGE_REGISTRY}/"* ]]; then
            printf '%s' "$1"
        else
            registry_join "$(registry_base)" "${ref}"
        fi
    elif [[ "${IMAGE_MIRROR_NAMESPACE:-agentcert}" != none ]] && image_is_mirrored "${ref}"; then
        image_flat_ref "${ref}" "${IMAGE_MIRROR_NAMESPACE:-agentcert}"
    else
        printf '%s' "${ref}"
    fi
}

# Upstream source of an image (where mirror-images.sh copies it from).
upstream_ref() {
    image_canonical "$1"
}

# Log in to the registry host when credentials are available. Public pulls need
# no login, so missing credentials are not an error here — a later push or
# pull will report it if they were actually needed.
registry_login() {
    local host
    if [[ -n "${IMAGE_REGISTRY}" ]]; then
        host="$(registry_host)"
    else
        # Empty registry = public images. Pulls work anonymously; log in to
        # Docker Hub only when credentials are given (pushes, rate limits).
        registry_has_credentials || return 0
        host="docker.io"
    fi
    if registry_has_credentials; then
        if printf '%s' "${REGISTRY_PASSWORD}" | docker login "${host}" -u "${REGISTRY_USERNAME}" --password-stdin >/dev/null 2>&1; then
            echo "Logged in to ${host} as ${REGISTRY_USERNAME}"
            return 0
        fi
        echo "Login to ${host} failed for ${REGISTRY_USERNAME}" >&2
        return 1
    fi
    echo "No registry credentials set — relying on any existing docker login for ${host}" >&2
    return 0
}

# Print inventory rows as "kind|group|image|context|recipe|flags", skipping
# comments and blank lines. Optional rows are dropped unless INCLUDE_OPTIONAL=1.
# $1 = inventory file, $2 = kind filter (build|mirror|all)
inventory_rows() {
    local file="$1" want="${2:-all}"
    local kind group image context recipe flags
    while IFS='|' read -r kind group image context recipe flags; do
        kind="${kind//[[:space:]]/}"
        [[ -z "${kind}" || "${kind}" == \#* ]] && continue
        [[ "${want}" != all && "${kind}" != "${want}" ]] && continue
        [[ "${flags}" == *optional* && "${INCLUDE_OPTIONAL:-0}" != 1 ]] && continue
        printf '%s|%s|%s|%s|%s|%s\n' "${kind}" "${group}" "${image}" "${context}" "${recipe}" "${flags}"
    done < "${file}"
}

# Does this exact image reference exist in its registry? Uses the registry API
# directly (works for any registry, needs only `docker login`), no pull.
# Retries twice so a transient registry/API error is not reported as missing.
image_exists() {
    local attempt
    for attempt in 1 2 3; do
        docker buildx imagetools inspect "$1" >/dev/null 2>&1 && return 0
        [[ "${attempt}" -lt 3 ]] && sleep "${attempt}"
    done
    return 1
}

# Label build-and-push.sh stamps on every ACE image so a registry copy can be
# compared with the checkout without pulling it.
ACE_REVISION_LABEL="org.opencontainers.image.revision"

# Content digest of everything the hub bundle packs (same inputs and order as
# scripts/prepare-images.sh), so the bundle's revision changes exactly when its
# content does.
hub_bundle_content_sha() {
    local repo_root="$1"
    (
        cd "${repo_root}" || exit 1
        find app-charts/charts agent-charts/charts chaos-charts/faults chaos-charts/experiments \
            -type f -print0 \
            | LC_ALL=C sort -z \
            | xargs -0 sha256sum \
            | sha256sum \
            | awk '{print $1}'
    )
}

# Base-image build args for a Dockerfile: every "ARG <NAME>_IMAGE=<public ref>"
# declared before its first FROM becomes "--build-arg <NAME>_IMAGE=<resolved>"
# (one word per line, for `mapfile -t`). Dockerfiles keep upstream defaults, so
# a plain `docker build` works anywhere; our build scripts pass the copy from
# IMAGE_REGISTRY or the frozen agentcert/ Docker Hub copies.
dockerfile_base_image_args() {
    local f="$1" line
    [[ -f "${f}" ]] || return 0
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ "${line}" =~ ^[[:space:]]*FROM[[:space:]] ]] && break
        if [[ "${line}" =~ ^[[:space:]]*ARG[[:space:]]+([A-Z0-9_]+_IMAGE)=([^[:space:]]+) ]]; then
            printf -- '--build-arg\n%s=%s\n' "${BASH_REMATCH[1]}" "$(registry_ref "${BASH_REMATCH[2]}")"
        fi
    done < "${f}"
}

# docker build with the Dockerfile's base images resolved (see above).
# $1 = Dockerfile path, then any other `docker build` arguments (context last).
docker_build_resolved() {
    local dockerfile="$1" base_args=()
    shift
    mapfile -t base_args < <(dockerfile_base_image_args "${dockerfile}")
    docker build "${base_args[@]}" -f "${dockerfile}" "$@"
}

# Build the hub bundle image from the checked-out chart/fault trees — the one
# recipe shared by scripts/prepare-images.sh (local KinD) and
# scripts/build-and-push.sh (registry). Extra arguments are passed to
# `docker build` (e.g. --no-cache, --label ...).
# $1 = repo root, $2 = image tag, $3.. = extra docker build args
hub_bundle_build() {
    local repo_root="$1" image="$2" content_sha base_args=()
    shift 2
    mapfile -t base_args < <(dockerfile_base_image_args "${repo_root}/deploy/hub-bundle/Dockerfile")
    content_sha="$(hub_bundle_content_sha "${repo_root}")"
    [[ -n "${content_sha}" ]] || { echo "Could not compute hub bundle content digest" >&2; return 1; }
    (
        cd "${repo_root}" || exit 1
        # BuildKit requires explicit archive entries for parent directories;
        # GNU tar does not emit app-charts/ when only app-charts/charts is
        # named, which makes COPY fail with mkdirat ... no such directory.
        tar -cf - \
            --no-recursion app-charts agent-charts chaos-charts deploy deploy/hub-bundle \
            --recursion \
            deploy/hub-bundle/Dockerfile \
            app-charts/charts \
            agent-charts/charts \
            chaos-charts/faults \
            chaos-charts/experiments
    ) | docker build "$@" "${base_args[@]}" \
        --build-arg "BUNDLE_CONTENT_SHA=${content_sha}" \
        --tag "${image}" \
        --file deploy/hub-bundle/Dockerfile \
        -
}

# Revision of the source an inventory "build" row is built from:
# <12-char commit of the context's git repo>[-dirty]. Dirty means the context
# has uncommitted changes, so the image is not reproducible from the commit.
# The hub bundle uses its content digest instead (it spans four submodules).
# $1 = repo root, $2 = context (relative), $3 = recipe
source_revision() {
    local repo_root="$1" ctx="$2" recipe="$3" dir sha dirty
    if [[ "${recipe}" == hub-bundle ]]; then
        sha="$(hub_bundle_content_sha "${repo_root}")"
        printf 'content-%s' "${sha:0:12}"
        return 0
    fi
    dir="${repo_root}/${ctx}"
    sha="$(git -C "${dir}" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
    dirty="$(git -C "${dir}" status --porcelain -- . 2>/dev/null | head -1)"
    if [[ -n "${dirty}" ]]; then printf '%s-dirty' "${sha}"; else printf '%s' "${sha}"; fi
}

# Revision label of an image already in a registry ("" if absent/unreadable).
remote_revision() {
    docker buildx imagetools inspect "$1" --format '{{json .Image}}' 2>/dev/null \
        | python3 -c '
import json, sys
label = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def find(o):
    if isinstance(o, dict):
        labels = (o.get("config") or {}).get("Labels") or {}
        if label in labels:
            return labels[label]
        for v in o.values():
            r = find(v)
            if r:
                return r
    return ""
print(find(data))
' "${ACE_REVISION_LABEL}"
}

# ── Kubernetes pull credentials ──────────────────────────────────────────────
# Shared by scripts/apply_cluster_prereqs.sh and scripts/prepare-images.sh so
# the secret is always created the same way, under IMAGE_PULL_SECRET_NAME.

# A namespace labelled ace.registry-sync=disabled opts out of registry
# credential management (same label deploy/registry-secret-sync.yaml honours).
registry_ns_opted_out() {
    [[ "$(kubectl get namespace "$1" -o jsonpath='{.metadata.labels.ace\.registry-sync}' 2>/dev/null)" == disabled ]]
}

# Create or update the IMAGE_PULL_SECRET_NAME docker-registry Secret in a
# namespace from REGISTRY_USERNAME / REGISTRY_PASSWORD. No-op without a
# registry (public images need no login).
registry_secret_apply() {
    local ns="$1"
    [[ -z "${IMAGE_REGISTRY}" ]] && return 0
    if ! registry_has_credentials; then
        echo "REGISTRY_USERNAME / REGISTRY_PASSWORD are not set — cannot create ${IMAGE_PULL_SECRET_NAME} in ${ns}" >&2
        return 1
    fi
    # Built in-process and piped to kubectl: the password never appears in a
    # command line (visible to every user on a shared host via ps/proc).
    ACE_SECRET_NS="${ns}" ACE_SECRET_NAME="${IMAGE_PULL_SECRET_NAME}" ACE_SECRET_SERVER="$(registry_host)" \
    python3 -c '
import base64, json, os, sys
server, user, pw = os.environ["ACE_SECRET_SERVER"], os.environ["REGISTRY_USERNAME"], os.environ["REGISTRY_PASSWORD"]
auth = base64.b64encode(f"{user}:{pw}".encode()).decode()
cfg = {"auths": {server: {"username": user, "password": pw, "auth": auth}}}
json.dump({"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/dockerconfigjson",
           "metadata": {"name": os.environ["ACE_SECRET_NAME"], "namespace": os.environ["ACE_SECRET_NS"]},
           "data": {".dockerconfigjson": base64.b64encode(json.dumps(cfg).encode()).decode()}}, sys.stdout)
' | kubectl apply -f - >/dev/null
}

# Add IMAGE_PULL_SECRET_NAME to a ServiceAccount's imagePullSecrets, keeping any
# secrets already listed there. Returns 1 if the ServiceAccount does not exist.
registry_sa_attach() {
    local ns="$1" sa="$2" have
    have="$(kubectl get serviceaccount "${sa}" -n "${ns}" \
        -o jsonpath='{range .imagePullSecrets[*]}{.name}{" "}{end}' 2>/dev/null)" || return 1
    [[ " ${have} " == *" ${IMAGE_PULL_SECRET_NAME} "* ]] && return 0
    if [[ -z "${have// /}" ]]; then
        kubectl patch serviceaccount "${sa}" -n "${ns}" --type merge \
            -p "{\"imagePullSecrets\":[{\"name\":\"${IMAGE_PULL_SECRET_NAME}\"}]}" >/dev/null
    else
        kubectl patch serviceaccount "${sa}" -n "${ns}" --type json \
            -p "[{\"op\":\"add\",\"path\":\"/imagePullSecrets/-\",\"value\":{\"name\":\"${IMAGE_PULL_SECRET_NAME}\"}}]" >/dev/null
    fi
}

# ── docker compose ────────────────────────────────────────────────────────────
# Compose files name the images compose itself runs as ${ACE_IMG_<NAME>:-<ref>}
# (also used for build args) or, on `image:` lines, an existing
# ${<NAME>_IMAGE:-<ref>} setting. compose_image_env exports each such variable
# resolved for IMAGE_REGISTRY / the frozen agentcert/ copies, so `docker
# compose` (whose shell environment wins over .env) pulls the right copy. A
# value already set in the environment or in .env is resolved instead of the
# default. Images graphql hands to the cluster (chaos infra, installers) are
# NOT handled here: they follow each *_IMAGE_SOURCE via resolve_image_env.py
# (see scripts/compose-up-guard.sh). $1 = .env file, $2.. = compose files.
compose_image_env() {
    local env_file="$1" f var def val
    shift
    for f in "$@"; do
        [[ -f "${f}" ]] || continue
        while IFS=$'\t' read -r var def; do
            val="${!var:-$(env_file_value "${var}" "${env_file}")}"
            export "${var}=$(registry_ref "${val:-${def}}")"
        done < <({ grep -oE '\$\{ACE_IMG_[A-Z0-9_]+:-[^}]+\}' "${f}"
                   grep -E '^[[:space:]]*image:' "${f}" | grep -oE '\$\{[A-Z0-9_]+_IMAGE:-[^}]+\}'; } \
                 | sed -E 's/^\$\{([A-Z0-9_]+):-(.*)\}$/\1\t\2/' | sort -u)
    done
    KIND_NODE_IMAGE="$(kind_node_image "${env_file}")"
    export KIND_NODE_IMAGE
}

# ── kind ──────────────────────────────────────────────────────────────────────
# Node image for `kind create cluster --image` (prints nothing = kind's default).
# KIND_NODE_IMAGE (env or .env) is a public name resolved like every other
# image. Left empty with a private registry, kind's own default node image
# (read from the installed kind binary; v1.35.0 for kind v0.31) is pulled from
# that registry instead of Docker Hub. Empty with no registry: kind's default.
kind_node_image() {
    local env_file="${1:-}" img
    img="${KIND_NODE_IMAGE:-$(env_file_value KIND_NODE_IMAGE "${env_file}")}"
    if [[ -z "${img}" ]]; then
        [[ -n "${IMAGE_REGISTRY}" ]] || return 0
        if command -v kind >/dev/null 2>&1; then
            img="$(strings "$(command -v kind)" 2>/dev/null | grep -oE 'kindest/node:v[0-9.]+' | head -1)"
        fi
        img="${img:-kindest/node:v1.35.0}"
    fi
    registry_ref "${img%@*}"
}
