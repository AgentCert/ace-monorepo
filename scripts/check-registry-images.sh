#!/usr/bin/env bash
# =============================================================================
# check-registry-images.sh — is every image in deploy/images.txt present in
# IMAGE_REGISTRY under the expected name?
# =============================================================================
# Usage:
#   ./scripts/check-registry-images.sh [--env-file PATH] [--images PATH]
#                                      [--include-optional] [--kind build|mirror]
#                                      [--markdown FILE]
#
#   --markdown FILE  also write a Markdown table of every image with its status
#                    and, for JFrog registries, a direct Artifactory UI link
#
# Reads IMAGE_REGISTRY and credentials from .env (see scripts/lib/registry.sh).
# With IMAGE_REGISTRY empty it checks the public names instead, which is the
# open-source path.
#
# Status per image:
#   OK       present at the expected name (and, for ACE images, built from the
#            current source revision)
#   OLD      ACE image present but built from a different revision than this
#            checkout — re-run scripts/build-and-push.sh
#   MISSING  not present — run scripts/mirror-images.sh (third-party) or
#            scripts/build-and-push.sh (ACE images)
#
# Exit status: 0 when every row is OK, 1 otherwise.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/registry.sh
source "${SCRIPT_DIR}/lib/registry.sh"

ENV_FILE="${REPO_ROOT}/.env"
IMAGES_FILE="${REPO_ROOT}/deploy/images.txt"
KIND_FILTER="all"
INCLUDE_OPTIONAL=0
MARKDOWN_OUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --markdown)         MARKDOWN_OUT="$2"; shift 2 ;;
        --env-file)         ENV_FILE="$2"; shift 2 ;;
        --images)           IMAGES_FILE="$2"; shift 2 ;;
        --include-optional) INCLUDE_OPTIONAL=1; shift ;;
        --kind)             KIND_FILTER="$2"; shift 2 ;;
        -h|--help)          sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
export INCLUDE_OPTIONAL

[[ -f "${IMAGES_FILE}" ]] || { echo "Inventory not found: ${IMAGES_FILE}" >&2; exit 2; }
registry_load "${ENV_FILE}" || exit 2

echo "Registry: ${IMAGE_REGISTRY:-docker.io/${IMAGE_MIRROR_NAMESPACE} (IMAGE_REGISTRY empty)}"
registry_login || true
echo

# Artifactory UI link for a registry path, or "" for non-JFrog registries.
# <host>/<repo>/<path>:<tag> -> https://<host>/ui/native/<repo>/<path>/<tag>/
ui_link() {
    local ref="$1" host rest repo path tag
    host="${ref%%/*}"
    [[ "${host}" == *jfrog.io ]] || return 0
    rest="${ref#*/}"; repo="${rest%%/*}"; path="${rest#*/}"
    tag="${path##*:}"; path="${path%:*}"
    printf 'https://%s/ui/native/%s/%s/%s/' "${host}" "${repo}" "${path}" "${tag}"
}

MD_ROWS=()
md_row() {  # status kind group image ref [revision-ref]
    local link rlink cell
    link="$(ui_link "$5")"
    if [[ -n "${link}" ]]; then cell="[\`$5\`](${link})"; else cell="\`$5\`"; fi
    if [[ -n "${6:-}" ]]; then
        rlink="$(ui_link "$6")"
        [[ -n "${rlink}" ]] && cell="${cell}<br>new build: [\`:${6##*:}\`](${rlink})"
    fi
    MD_ROWS+=("| $1 | $2 | $3 | \`$4\` | ${cell} |")
}

declare -A SEEN=()
n_ok=0 n_old=0 n_missing=0
printf '%-8s %-7s %-10s %s\n' STATUS KIND GROUP "IMAGE -> DETAIL"
while IFS='|' read -r kind group image ctx recipe _flags; do
    canon="$(image_canonical "${image}")"
    [[ -n "${SEEN[${canon}]:-}" ]] && continue
    SEEN[${canon}]=1
    ref="$(registry_ref "${image}")"

    if ! image_exists "${ref}"; then
        printf '%-8s %-7s %-10s %s\n' MISSING "${kind}" "${group}" "${ref}"
        md_row MISSING "${kind}" "${group}" "${canon}" "${ref}"
        n_missing=$((n_missing + 1))
        continue
    fi

    if [[ "${kind}" == build ]]; then
        want="$(source_revision "${REPO_ROOT}" "${ctx}" "${recipe}")"
        have="$(remote_revision "${ref}")"
        if [[ "${have}" != "${want}" ]]; then
            printf '%-8s %-7s %-10s %s (registry: %s, source: %s)\n' OLD "${kind}" "${group}" "${ref}" "${have:-unlabelled}" "${want}"
            # Point at the revision-tagged build when it exists (pushed by
            # build-and-push.sh even when the moving tag could not be replaced).
            rev_ref="${ref%:*}:${want%-dirty}"
            if image_exists "${rev_ref}"; then
                md_row OLD "${kind}" "${group}" "${canon}" "${ref}" "${rev_ref}"
            else
                md_row OLD "${kind}" "${group}" "${canon}" "${ref}"
            fi
            n_old=$((n_old + 1))
            continue
        fi
    fi
    printf '%-8s %-7s %-10s %s\n' OK "${kind}" "${group}" "${ref}"
    md_row OK "${kind}" "${group}" "${canon}" "${ref}"
    n_ok=$((n_ok + 1))
done < <(inventory_rows "${IMAGES_FILE}" "${KIND_FILTER}")

echo
echo "Summary: ${n_ok} OK, ${n_old} OLD, ${n_missing} MISSING"

if [[ -n "${MARKDOWN_OUT}" ]]; then
    {
        echo "# ACE images in ${IMAGE_REGISTRY:-docker.io/${IMAGE_MIRROR_NAMESPACE} (frozen open-source copies)}"
        echo
        echo "Generated $(date -u '+%Y-%m-%d %H:%M UTC') by \`scripts/check-registry-images.sh --markdown\` from \`deploy/images.txt\`."
        echo "Re-run that command to refresh this file."
        echo
        echo "**Summary:** ${n_ok} OK, ${n_old} OLD, ${n_missing} MISSING"
        echo
        echo "- **OK**: present at the expected name (ACE images: built from the current source)."
        echo "- **OLD**: ACE image whose moving tag (\`:latest\`) is an older build; the current build is linked as *new build*."
        echo "- **MISSING**: not in the registry."
        echo "- **build** = built from this repo by \`scripts/build-and-push.sh\`; **mirror** = third-party copy made by \`scripts/mirror-images.sh\`."
        echo
        echo "| Status | Kind | Group | Image | Registry location |"
        echo "|---|---|---|---|---|"
        printf '%s\n' "${MD_ROWS[@]}"
    } > "${MARKDOWN_OUT}"
    echo "Wrote ${MARKDOWN_OUT}"
fi
[[ $((n_old + n_missing)) -eq 0 ]]
