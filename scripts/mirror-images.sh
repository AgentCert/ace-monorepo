#!/usr/bin/env bash
# =============================================================================
# mirror-images.sh — cache third-party images locally by default; --push copies
# every selected third-party image from its
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
#                              [--local | --push] [--platform linux/amd64] [--jobs N] [--only REGEX]
#
#   --force      re-copy even when the image already exists in the registry
#   --dry-run    print what would be copied, change nothing
#   --platform   platform to copy (default linux/amd64; AKS and KinD nodes here
#                are amd64). Copying one platform keeps the shared registry small.
#   --jobs N     copy N images at a time (default 3)
#   --only RE    only images whose public name matches the regex
#
# Images already in the registry are skipped, so re-running is cheap and safe.
#
# Default (no --push): pull each upstream image into the local Docker cache
# under its upstream name only. It is deliberately NOT tagged with its
# registry name: with IMAGE_REGISTRY empty that name is the frozen Docker Hub
# copy (mongo:5 -> agentcert/mongo:5), and a local tag would make that name
# resolve to today's upstream content for every local consumer (docker build
# FROM, compose, kind load) — exactly the drift the frozen copies prevent.
# Images already cached locally are skipped.
#
# --push: pull, tag with the registry name, push, then remove the local copies
# this run created (the registry tag, and the upstream image when it was not
# cached before the run). Images that existed locally before the run are kept.
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
PUSH=0
LOCAL_REQUESTED=0
PLATFORM="linux/amd64"
JOBS=3
ONLY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file|--images|--platform|--jobs|--only)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "$1 requires a value" >&2; exit 2; } ;;
    esac
    case "$1" in
        --push)            PUSH=1; shift ;;
        --local)           LOCAL_REQUESTED=1; shift ;;
        --env-file)         ENV_FILE="$2"; shift 2 ;;
        --images)           IMAGES_FILE="$2"; shift 2 ;;
        --include-optional) INCLUDE_OPTIONAL=1; shift ;;
        --force)            FORCE=1; shift ;;
        --dry-run)          DRY_RUN=1; shift ;;
        --platform)         PLATFORM="$2"; shift 2 ;;
        --jobs)             JOBS="$2"; shift 2 ;;
        --only)             ONLY="$2"; shift 2 ;;
        -h|--help)          sed -n '2,/^set -uo pipefail/{/^set -uo pipefail/d;p}' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [[ "${LOCAL_REQUESTED}" -eq 1 ]] && [[ "${PUSH}" -eq 1 ]]; then
    echo 'ERROR: --local cannot be combined with --push.' >&2
    exit 2
fi

export INCLUDE_OPTIONAL
[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || { echo "--jobs must be a positive integer" >&2; exit 2; }

[[ -f "${IMAGES_FILE}" ]] || { echo "Inventory not found: ${IMAGES_FILE}" >&2; exit 2; }
registry_load "${ENV_FILE}" || exit 2
if [[ -n "${ONLY}" ]]; then
    regex_status=0
    [[ "" =~ ${ONLY} ]] || regex_status=$?
    [[ "${regex_status}" -ne 2 ]] || { echo "Invalid --only regex: ${ONLY}" >&2; exit 2; }
fi
MIRROR_ROWS=()
while IFS= read -r row; do
    IFS='|' read -r _ _ selected_image _ <<< "${row}"
    [[ -n "${ONLY}" && ! "${selected_image}" =~ ${ONLY} ]] && continue
    MIRROR_ROWS+=("${row}")
done < <(inventory_rows "${IMAGES_FILE}" mirror)
[[ ${#MIRROR_ROWS[@]} -gt 0 ]] || { echo 'No images match the mirror selection' >&2; exit 2; }
if [[ -z "${IMAGE_REGISTRY}" && "${IMAGE_MIRROR_NAMESPACE}" == none ]]; then
    echo "IMAGE_REGISTRY is empty and IMAGE_MIRROR_NAMESPACE=none — ACE pulls upstream images directly, nothing to mirror."
    exit 0
fi
TARGET="${IMAGE_REGISTRY:-docker.io/${IMAGE_MIRROR_NAMESPACE}}"

echo "Mirroring third-party images into ${TARGET} (platform ${PLATFORM}, ${JOBS} at a time)"
if [[ "${DRY_RUN}" -eq 0 && "${PUSH}" -eq 1 ]]; then
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
    local src dst log status idx="$2" had_src=0 had_dst=0
    src="$(upstream_ref "$1")"
    dst="$(registry_ref "$1")"
    log="${LOG_DIR}/$(printf '%s' "${src}" | tr '/:@' '___').log"
    # What is in the local cache before this run touches it: only images this
    # run creates are removed afterwards.
    docker image inspect "${src}" >/dev/null 2>&1 && had_src=1
    docker image inspect "${dst}" >/dev/null 2>&1 && had_dst=1

    if [[ "${FORCE}" -eq 0 ]] && {
        if [[ "${PUSH}" -eq 1 ]]; then image_exists "${dst}"
        else [[ "${had_src}" -eq 1 ]]; fi
    }; then
        status="SKIP"
    elif [[ "${DRY_RUN}" -eq 1 ]]; then
        status="WOULD-COPY"
    elif ! docker pull --platform "${PLATFORM}" "${src}" >"${log}" 2>&1; then
        status="FAILED"
    elif [[ "${PUSH}" -eq 0 ]]; then
        status="CACHED"
    else
        if docker tag "${src}" "${dst}" >>"${log}" 2>&1 && push_platform "${dst}" >>"${log}" 2>&1; then
            status="COPIED"
        else
            status="FAILED"
        fi
        # Pushed or not, drop the copies this run added (a shared host's disk
        # is not a cache for ~100 third-party images). src == dst when the
        # image already lives in the target namespace.
        if [[ "${had_dst}" -eq 0 ]]; then docker rmi "${dst}" >>"${log}" 2>&1 || true; fi
        if [[ "${had_src}" -eq 0 && "${src}" != "${dst}" ]]; then docker rmi "${src}" >>"${log}" 2>&1 || true; fi
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
done < <(printf '%s\n' "${MIRROR_ROWS[@]}")
wait

echo
copied=$(cat "${RESULT_DIR}"/* 2>/dev/null | grep -c '^COPIED' || true)
cached=$(cat "${RESULT_DIR}"/* 2>/dev/null | grep -c '^CACHED' || true)
skipped=$(cat "${RESULT_DIR}"/* 2>/dev/null | grep -c '^SKIP' || true)
would=$(cat "${RESULT_DIR}"/* 2>/dev/null | grep -c '^WOULD-COPY' || true)
failed=$(cat "${RESULT_DIR}"/* 2>/dev/null | grep '^FAILED' || true)
echo "Summary: ${cached} cached locally, ${copied} pushed, ${skipped} already present, ${would} would copy, $(printf '%s' "${failed}" | grep -c . || true) failed"
if [[ -n "${failed}" ]]; then
    echo "Failures (logs in ${LOG_DIR}):"
    printf '  %s\n' "${failed}"
    rm -rf "${RESULT_DIR}"
    exit 1
fi
rm -rf "${RESULT_DIR}"
