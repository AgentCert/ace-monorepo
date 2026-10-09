#!/bin/bash
set -euo pipefail

# =============================================================================
# Build & Push ACE's own Docker images
# =============================================================================
# Builds every "build" row in deploy/images.txt from this checkout and pushes it
# to IMAGE_REGISTRY (naming rule: scripts/lib/registry.sh).
#
#   IMAGE_REGISTRY set    -> push to <IMAGE_REGISTRY>/agentcert/<image>
#   IMAGE_REGISTRY empty  -> push to Docker Hub as agentcert/<image> (unchanged
#                            open-source behaviour)
# Both log in with REGISTRY_USERNAME / REGISTRY_PASSWORD (legacy JFROG_* /
# DOCKERHUB_* keys are read as a fallback, see scripts/lib/registry.sh).
#
# Every image is pushed twice: its normal tag (e.g. :latest) and a fixed tag
# naming the source revision (e.g. :58512cc70a1b, or :58512cc70a1b-dirty when
# the source had uncommitted changes). The revision is also stamped as the
# org.opencontainers.image.revision label, which check-registry-images.sh uses
# to spot registry copies that are older than the checkout.
#
# Usage:
#   ./scripts/build-and-push.sh [--env-file PATH] [--local] [--kind-load]
#                               [--only REGEX] [--allow-build-cache]
#                               [--tag RELEASE-N]
#
# Options:
#   --env-file PATH       Path to env file (default: <repo-root>/.env)
#   --local               Build only — skip login and push
#   --kind-load           After building, load each image into the local KinD
#                         cluster (reads KIND_CLUSTER_NAME / ACE_INSTANCE_NAME
#                         from .env; implies --local)
#   --only REGEX          Only images whose name matches REGEX
#                         (e.g. --only 'graphql|auth')
#   --tag RELEASE-N       Push every ACE image as :RELEASE-N instead of its
#                         own tag (:latest), and on success write
#                         ACE_IMAGE_TAG=RELEASE-N to the env file, so setup.sh,
#                         the Helm chart, graphql and the installers pull that
#                         release. Use a new number per release: a release tag
#                         is never overwritten. Default: ACE_IMAGE_TAG from .env.
#   --allow-build-cache   Reuse Docker's build cache. Off by default: BuildKit
#                         has been seen replaying stale COPY/go-build layers
#                         after the source changed (same reason setup.sh builds
#                         with --no-cache).
#   --committed-only      When a source has uncommitted changes, build its
#                         committed HEAD instead (exported to .tmp/build-src;
#                         the working tree is not touched). Use for releases.
#   --reuse-local         Skip the build when the local image was already built
#                         from the same source revision (its
#                         org.opencontainers.image.revision label matches), and
#                         just tag + push it. Pushes the identical image to a
#                         second registry without rebuilding.
#
# The revision tag is pushed before the release/moving tag. If the registry refuses to
# overwrite an existing tag (JFrog without Delete/Overwrite permission), the
# new build is still available under its revision tag and the summary says so.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/registry.sh
source "${SCRIPT_DIR}/lib/registry.sh"

ENV_FILE="${REPO_ROOT}/.env"
IMAGES_FILE="${REPO_ROOT}/deploy/images.txt"
LOCAL_ONLY=false
KIND_LOAD=false
ONLY=""
NO_CACHE_FLAG="--no-cache"
COMMITTED_ONLY=false
REUSE_LOCAL=false
RELEASE_TAG=""

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
        --only)
            ONLY="${2:-}"
            shift 2
            ;;
        --allow-build-cache)
            NO_CACHE_FLAG=""
            shift
            ;;
        --committed-only)
            COMMITTED_ONLY=true
            shift
            ;;
        --reuse-local)
            REUSE_LOCAL=true
            shift
            ;;
        --tag)
            RELEASE_TAG="${2:-}"
            [[ "${RELEASE_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] \
                || { log_error "--tag needs a valid Docker tag, e.g. RELEASE-3 (got '${RELEASE_TAG}')"; exit 1; }
            export ACE_IMAGE_TAG="${RELEASE_TAG}"
            shift 2
            ;;
        --help|-h)
            sed -n '4,45p' "$0"
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

if [[ ! -f "${IMAGES_FILE}" ]]; then
    log_error "Image inventory not found: ${IMAGES_FILE}"
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    log_error "docker not found"
    exit 1
fi

registry_load "${ENV_FILE}" || exit 1

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
# Registry login (skipped in --local mode)
# ---------------------------------------------------------------------------
if [[ "${LOCAL_ONLY}" == false ]]; then
    # Pushing always needs credentials: for IMAGE_REGISTRY, or for Docker Hub
    # when it is empty (REGISTRY_USERNAME / REGISTRY_PASSWORD).
    if ! registry_has_credentials; then
        log_error "REGISTRY_USERNAME / REGISTRY_PASSWORD are not set in ${ENV_FILE} (needed to push to ${IMAGE_REGISTRY:-Docker Hub})"
        exit 1
    fi
    registry_login || { log_error "Login to ${IMAGE_REGISTRY:-Docker Hub} failed"; exit 1; }
    log_success "Pushing to ${IMAGE_REGISTRY:-Docker Hub}"
fi

# ---------------------------------------------------------------------------
# Builders. Each builds the plain local name (e.g. agentcert/certifier:latest,
# which is what KinD clusters reference today) with the revision label.
# ---------------------------------------------------------------------------

# Plain Dockerfile build. $3 is the Dockerfile's path (it may live outside the
# build context, e.g. compose/web/Dockerfile); base images come from the
# registry (dockerfile_base_image_args).
build_dockerfile() {
    local image="$1" ctx="$2" dockerfile="$3" revision="$4"
    # shellcheck disable=SC2086  # NO_CACHE_FLAG is intentionally word-split (may be empty)
    docker_build_resolved "${dockerfile}" ${NO_CACHE_FLAG} \
        --label "${ACE_REVISION_LABEL}=${revision}" \
        -t "${image}" "${ctx}"
}

# Hub bundle: the chart/fault trees packed into one image (shared recipe in
# scripts/lib/registry.sh, also used by scripts/prepare-images.sh).
build_hub_bundle() {
    local image="$1" revision="$2"
    # shellcheck disable=SC2086
    hub_bundle_build "${REPO_ROOT}" "${image}" ${NO_CACHE_FLAG} \
        --label "${ACE_REVISION_LABEL}=${revision}"
}

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
    echo -e "${CYAN}  Build & Push to ${IMAGE_REGISTRY:-Docker Hub}${NC}"
fi
echo -e "${CYAN}======================================${NC}"
echo ""

FAILED=()
PUSHED=()
NOT_OVERWRITTEN=()
RESTARTED_DEPLOYMENTS=()

# Tag the local image as $2 and push it. Sets PUSH_OVERWRITE_DENIED=true when
# the registry refused because the tag already exists and may not be replaced.
PUSH_OVERWRITE_DENIED=false
push_ref() {
    local image="$1" ref="$2" out rc
    PUSH_OVERWRITE_DENIED=false
    if [[ "${ref}" != "${image}" ]]; then
        docker tag "${image}" "${ref}" || return 1
    fi
    log_info "Pushing ${ref} ..."
    out="$(mktemp)"
    docker push "${ref}" 2>&1 | tee "${out}"
    rc="${PIPESTATUS[0]}"
    if [[ "${rc}" -ne 0 ]] && grep -qiE 'permission to overwrite|overwrite.*(not allowed|forbidden)' "${out}"; then
        PUSH_OVERWRITE_DENIED=true
    fi
    rm -f "${out}"
    return "${rc}"
}

# Export the committed (HEAD) state of a build context into a scratch dir, so
# an image can be built from committed code while the working tree has
# uncommitted changes. Prints the export dir.
export_committed_context() {
    local ctx_dir="$1" name="$2" prefix top out
    prefix="$(git -C "${ctx_dir}" rev-parse --show-prefix)" || return 1
    top="$(git -C "${ctx_dir}" rev-parse --show-toplevel)" || return 1
    out="${REPO_ROOT}/.tmp/build-src/${name}"
    rm -rf "${out}" && mkdir -p "${out}" || return 1
    # Run from the repo top level: from a subdirectory, git archive also
    # filters by that subdirectory's path, which yields an empty archive.
    git -C "${top}" archive --format=tar "HEAD:${prefix%/}" | tar -x -C "${out}" || return 1
    printf '%s' "${out}"
}

while IFS='|' read -r _kind _group image ctx recipe _flags; do
    img_name="${image%:*}"
    [[ -n "${ONLY}" && ! "${image}" =~ ${ONLY} ]] && continue
    context_dir="${REPO_ROOT}/${ctx}"
    revision="$(source_revision "${REPO_ROOT}" "${ctx}" "${recipe}")"

    # --reuse-local: the image already built from exactly this revision is
    # pushed as-is. With --committed-only that is the committed revision.
    target_revision="${revision}"
    if [[ "${COMMITTED_ONLY}" == true && "${revision}" == *-dirty \
          && "${recipe}" != hub-bundle ]]; then
        target_revision="${revision%-dirty}"
    fi
    if [[ "${REUSE_LOCAL}" == true ]] \
       && [[ "$(docker image inspect "${image}" --format "{{index .Config.Labels \"${ACE_REVISION_LABEL}\"}}" 2>/dev/null)" == "${target_revision}" ]]; then
        revision="${target_revision}"
        log_success "${image}: local image already built from ${revision} — reusing it (no rebuild)"
        reused=true
    else
        reused=false
    fi

    if [[ "${reused}" == false && "${COMMITTED_ONLY}" == true && "${revision}" == *-dirty ]]; then
        case "${recipe}" in
            hub-bundle)
                log_warn "${img_name}: --committed-only is not supported for recipe '${recipe}' — building the working tree"
                ;;
            *)
                if export_dir="$(export_committed_context "${context_dir}" "${img_name//\//_}")"; then
                    log_info "${img_name}: source has uncommitted changes — building committed HEAD from ${export_dir}"
                    context_dir="${export_dir}"
                    revision="${revision%-dirty}"
                else
                    log_error "Could not export committed source for ${img_name}"
                    FAILED+=("${img_name} (export)")
                    continue
                fi
                ;;
        esac
    fi

    build_ok=false
    if [[ "${reused}" == true ]]; then
        build_ok=true
    else
        log_info "Building ${image} (revision ${revision}) ..."
        case "${recipe}" in
            hub-bundle)
                build_hub_bundle "${image}" "${revision}" && build_ok=true
                ;;
            *)
                # The Dockerfile path is relative to the checkout's context
                # (not an exported --committed-only copy), as it may sit outside it.
                dockerfile_path="$(realpath -m "${REPO_ROOT}/${ctx}/${recipe}")"
                if [[ ! -f "${dockerfile_path}" ]]; then
                    log_warn "Dockerfile not found: ${dockerfile_path} — skipping ${img_name}"
                    FAILED+=("${img_name} (no Dockerfile)")
                    continue
                fi
                build_dockerfile "${image}" "${context_dir}" "${dockerfile_path}" "${revision}" && build_ok=true
                ;;
        esac
    fi
    if [[ "${build_ok}" != true ]]; then
        log_error "Build failed: ${img_name}"
        FAILED+=("${img_name} (build)")
        continue
    fi
    if [[ "${reused}" == false ]]; then log_success "Built: ${image}"; fi

    if [[ "${KIND_LOAD}" == true ]]; then
        log_info "Loading ${image} into KinD cluster ${KIND_CLUSTER} ..."
        if kind load docker-image "${image}" --name "${KIND_CLUSTER}"; then
            log_success "Loaded: ${image}"
            # Restart the matching deployment so running pods immediately use the
            # new image — kind load replaces the containerd cache entry but
            # IfNotPresent won't restart already-running pods on its own.
            restart_deployment "${img_name}"
        else
            log_error "kind load failed: ${img_name}"
            FAILED+=("${img_name} (kind-load)")
        fi
    elif [[ "${LOCAL_ONLY}" == false ]]; then
        dst="$(registry_ref "${image}")"
        dst_rev="${dst%:*}:${revision}"
        # Revision tag first: it is new on every source change, so it lands
        # even on registries that refuse to overwrite an existing tag (JFrog
        # without Delete/Overwrite permission). The moving tag (:latest etc.)
        # is pushed second.
        # A revision tag the registry refuses to replace is fine when it already
        # holds a build of the same revision (e.g. pushed by an earlier run).
        rev_ok=false
        if push_ref "${image}" "${dst_rev}"; then
            rev_ok=true
        elif [[ "${PUSH_OVERWRITE_DENIED}" == true && "$(remote_revision "${dst_rev}")" == "${revision}" ]]; then
            log_warn "${dst_rev} already exists with a build of revision ${revision} — keeping it"
            rev_ok=true
        fi
        if [[ "${rev_ok}" == true ]]; then
            if push_ref "${image}" "${dst}"; then
                log_success "Pushed: ${dst} and :${revision}"
                PUSHED+=("${dst} (+ :${revision})")
            elif [[ "${PUSH_OVERWRITE_DENIED}" == true ]]; then
                log_warn "Pushed ${dst_rev}, but ${dst} already exists and this account may not overwrite it"
                NOT_OVERWRITTEN+=("${dst} (new build is at :${revision})")
            else
                log_error "Push failed: ${dst}"
                FAILED+=("${img_name} (push)")
            fi
        else
            log_error "Push failed: ${dst_rev}"
            FAILED+=("${img_name} (push)")
        fi
    fi

    echo ""
done < <(inventory_rows "${IMAGES_FILE}" build)

# ---------------------------------------------------------------------------
# Wait for restarted deployments to finish rolling out
# ---------------------------------------------------------------------------
if [[ ${#RESTARTED_DEPLOYMENTS[@]} -gt 0 ]]; then
    echo ""
    log_info "Waiting for rollouts to complete ..."
    for target in ${RESTARTED_DEPLOYMENTS[@]+"${RESTARTED_DEPLOYMENTS[@]}"}; do
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
for p in ${PUSHED[@]+"${PUSHED[@]}"}; do
    echo -e "    ${GREEN}✓${NC} $p"
done
if [[ ${#NOT_OVERWRITTEN[@]} -gt 0 ]]; then
    if [[ -n "${ACE_IMAGE_TAG:-}" ]]; then
        echo -e "${YELLOW}  :${ACE_IMAGE_TAG} already exists with a different build — use a new release number (--tag RELEASE-<n+1>):${NC}"
    else
        echo -e "${YELLOW}  Existing tags NOT overwritten (account lacks overwrite permission; use --tag RELEASE-N):${NC}"
    fi
    for p in ${NOT_OVERWRITTEN[@]+"${NOT_OVERWRITTEN[@]}"}; do
        echo -e "    ${YELLOW}!${NC} $p"
    done
    FAILED+=("${#NOT_OVERWRITTEN[@]} moving tag(s) not overwritten — see above")
fi
if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo -e "${GREEN}  All images built successfully!${NC}"
else
    echo -e "${YELLOW}  Completed with failures:${NC}"
    for f in ${FAILED[@]+"${FAILED[@]}"}; do
        echo -e "    ${RED}✗${NC} $f"
    done
fi
echo -e "${CYAN}======================================${NC}"

# Point deployments at the release just pushed.
if [[ -n "${RELEASE_TAG}" && -n "${ONLY}" ]]; then
    log_warn "--only: not every ACE image has :${RELEASE_TAG}, so ACE_IMAGE_TAG in ${ENV_FILE} was left unchanged."
elif [[ -n "${RELEASE_TAG}" && "${LOCAL_ONLY}" == false && ${#FAILED[@]} -eq 0 ]]; then
    python3 - "${ENV_FILE}" "${RELEASE_TAG}" <<'PY'
import re, sys
path, tag = sys.argv[1:3]
lines = open(path).read().splitlines()
for i, l in enumerate(lines):
    if re.match(r"^ACE_IMAGE_TAG=", l):
        lines[i] = f"ACE_IMAGE_TAG={tag}"
        break
else:
    lines.append(f"ACE_IMAGE_TAG={tag}")
open(path, "w").write("\n".join(lines) + "\n")
PY
    log_success "ACE_IMAGE_TAG=${RELEASE_TAG} written to ${ENV_FILE} — the next setup.sh deploys this release."
fi

[[ ${#FAILED[@]} -eq 0 ]]
