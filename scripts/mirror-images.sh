#!/usr/bin/env bash
# =============================================================================
# mirror-images.sh — copy every third-party image in deploy/images.txt from its
# upstream home into the registry ACE pulls from (naming rule:
# scripts/lib/registry.sh):
#   IMAGE_REGISTRY set   -> <IMAGE_REGISTRY>/<public name>      (e.g. JFrog)
#   IMAGE_REGISTRY empty -> docker.io/<IMAGE_MIRROR_NAMESPACE>/<flat name>
#                           (frozen open-source copies, default agentcert/)
# =============================================================================
# Run on a machine that can reach the public registries (Docker Hub, quay.io,
# ghcr.io, registry.k8s.io, ...) AND the target registry. After this, a cluster
# that can only reach IMAGE_REGISTRY has every third-party image it needs.
#
# ACE's own images ("build" rows) are not copied here — scripts/build-and-push.sh
# builds them from this checkout and pushes them.
#
# Usage:
#   ./scripts/mirror-images.sh [--env-file PATH] [--images PATH]
#                              [--include-optional] [--force] [--dry-run]
#                              [--platform linux/amd64] [--jobs N] [--only REGEX]
#
#   --force      re-copy even when the image already exists in the registry
#   --dry-run    print what would be copied, change nothing
#   --platform   platform to copy (default linux/amd64; AKS and KinD nodes here
#                are amd64). Copying one platform keeps the shared registry small.
#   --jobs N     copy N images at a time (default 3)
#   --only RE    only images whose public name matches the regex
#
# Images already in the registry are skipped, so re-running is cheap and safe.
# Local copies pulled by this script are removed after a successful push;
# images that were already in the local Docker cache are left alone.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/registry.sh
source "${SCRIPT_DIR}/lib/registry.sh"

ENV_FILE="${REPO_ROOT}/.env"
IMAGES_FILE="${REPO_ROOT}/deploy/images.txt"
INCLUDE_OPTIONAL=0
FORCE=0
DRY_RUN=0
PLATFORM="linux/amd64"
JOBS=3
ONLY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)         ENV_FILE="$2"; shift 2 ;;
        --images)           IMAGES_FILE="$2"; shift 2 ;;
        --include-optional) INCLUDE_OPTIONAL=1; shift ;;
        --force)            FORCE=1; shift ;;
        --dry-run)          DRY_RUN=1; shift ;;
        --platform)         PLATFORM="$2"; shift 2 ;;
        --jobs)             JOBS="$2"; shift 2 ;;
        --only)             ONLY="$2"; shift 2 ;;
        -h|--help)          sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
export INCLUDE_OPTIONAL
[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || { echo "--jobs must be a positive integer" >&2; exit 2; }

[[ -f "${IMAGES_FILE}" ]] || { echo "Inventory not found: ${IMAGES_FILE}" >&2; exit 2; }
registry_load "${ENV_FILE}" || exit 2
if [[ -z "${IMAGE_REGISTRY}" && "${IMAGE_MIRROR_NAMESPACE}" == none ]]; then
    echo "IMAGE_REGISTRY is empty and IMAGE_MIRROR_NAMESPACE=none — ACE pulls upstream images directly, nothing to mirror."
    exit 0
fi
TARGET="${IMAGE_REGISTRY:-docker.io/${IMAGE_MIRROR_NAMESPACE}}"

echo "Mirroring third-party images into ${TARGET} (platform ${PLATFORM}, ${JOBS} at a time)"
if [[ "${DRY_RUN}" -eq 0 ]]; then
    registry_login || exit 1
fi
echo

LOG_DIR="${REPO_ROOT}/.tmp/mirror-logs"
RESULT_DIR="$(mkdir -p "${REPO_ROOT}/.tmp" && mktemp -d "${REPO_ROOT}/.tmp/mirror-results.XXXXXX")"
mkdir -p "${LOG_DIR}"

# docker push of one platform: needed with the containerd image store, where a
# pulled image keeps its multi-platform index. Older Docker CLIs have no
# --platform for push (and use the classic store, where it is not needed).
push_platform() {
    if docker push --help 2>/dev/null | grep -q -- '--platform'; then
        docker push --platform "${PLATFORM}" "$1"
    else
        docker push "$1"
    fi
}

# Copy one image. Writes "<status> <src> -> <dst>" to the result dir.
mirror_one() {
    local src dst log had_local=0 status idx="$2"
    src="$(upstream_ref "$1")"
    dst="$(registry_ref "$1")"
    log="${LOG_DIR}/$(printf '%s' "${src}" | tr '/:@' '___').log"

    if [[ "${FORCE}" -eq 0 ]] && image_exists "${dst}"; then
        status="SKIP"
    elif [[ "${DRY_RUN}" -eq 1 ]]; then
        status="WOULD-COPY"
    else
        docker image inspect "${src}" >/dev/null 2>&1 && had_local=1
        if docker pull --platform "${PLATFORM}" "${src}" >"${log}" 2>&1 \
            && docker tag "${src}" "${dst}" >>"${log}" 2>&1 \
            && push_platform "${dst}" >>"${log}" 2>&1; then
            status="COPIED"
            docker rmi "${dst}" >/dev/null 2>&1 || true
            [[ "${had_local}" -eq 0 ]] && docker rmi "${src}" >/dev/null 2>&1
        else
            status="FAILED"
        fi
    fi
    printf '%s %s -> %s\n' "${status}" "${src}" "${dst}" | tee "${RESULT_DIR}/${idx}"
}

declare -A SEEN=()
idx=0
running=0
while IFS='|' read -r _kind _group image _ctx _recipe _flags; do
    canon="$(image_canonical "${image}")"
    [[ -n "${SEEN[${canon}]:-}" ]] && continue
    SEEN[${canon}]=1
    [[ -n "${ONLY}" && ! "${image}" =~ ${ONLY} ]] && continue
    idx=$((idx + 1))
    mirror_one "${image}" "${idx}" &
    running=$((running + 1))
    if [[ "${running}" -ge "${JOBS}" ]]; then
        wait -n
        running=$((running - 1))
    fi
done < <(inventory_rows "${IMAGES_FILE}" mirror)
wait

echo
copied=$(cat "${RESULT_DIR}"/* 2>/dev/null | grep -c '^COPIED' || true)
skipped=$(cat "${RESULT_DIR}"/* 2>/dev/null | grep -c '^SKIP' || true)
would=$(cat "${RESULT_DIR}"/* 2>/dev/null | grep -c '^WOULD-COPY' || true)
failed=$(cat "${RESULT_DIR}"/* 2>/dev/null | grep '^FAILED' || true)
echo "Summary: ${copied} copied, ${skipped} already present, ${would} would copy, $(printf '%s' "${failed}" | grep -c . || true) failed"
if [[ -n "${failed}" ]]; then
    echo "Failures (logs in ${LOG_DIR}):"
    printf '  %s\n' "${failed}"
    rm -rf "${RESULT_DIR}"
    exit 1
fi
rm -rf "${RESULT_DIR}"
