#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# ACE infrastructure teardown
# =============================================================================
# Removes every Docker container, named volume, and KinD cluster that
# setup.sh / start-local-services.sh created for THIS checkout's
# ACE_INSTANCE_NAME.  Never touches resources that belong to another user or
# checkout on this shared host.
#
#   ./scripts/shut_down.sh                       # interactive confirmation
#   ./scripts/shut_down.sh --yes                 # non-interactive (CI / scripted use)
#   ./scripts/shut_down.sh --keep-ollama-model    # preserve the ollama-models-<instance>
#                                                  # volume so pulled models survive teardown
#                                                  # and don't need to be re-downloaded by
#                                                  # the next setup.sh run
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
say()  { echo -e "$*"; }

# ── Parse arguments ───────────────────────────────────────────────────────────
YES=0
KEEP_OLLAMA_MODEL=0
for _arg in "$@"; do
    case "${_arg}" in
        -y|--yes) YES=1 ;;
        -k|--keep-ollama-model) KEEP_OLLAMA_MODEL=1 ;;
        -h|--help)
            say "Usage: $0 [--yes|-y] [--keep-ollama-model|-k]"
            say "  Tears down all ACE infrastructure for the ACE_INSTANCE_NAME in .env."
            say "  --yes / -y               skip the confirmation prompt"
            say "  --keep-ollama-model / -k don't delete the ollama-models-<instance> volume"
            say "                           (preserves already-pulled models for next setup)"
            exit 0 ;;
        *) err "Unknown argument: ${_arg}"; exit 1 ;;
    esac
done
unset _arg

# ── Load .env ─────────────────────────────────────────────────────────────────
if [[ ! -f "${ENV_FILE}" ]]; then
    err ".env not found at ${ENV_FILE}"
    err "This checkout has never been configured by setup.sh — nothing to tear down."
    exit 1
fi

cur() { grep -m1 "^${1}=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true; }

ACE_INSTANCE_NAME="$(cur ACE_INSTANCE_NAME)"
if [[ -z "${ACE_INSTANCE_NAME}" ]]; then
    err "ACE_INSTANCE_NAME is not set in .env."
    err "Cannot determine which resources belong to this checkout."
    exit 1
fi

KIND_CLUSTER_NAME="$(cur KIND_CLUSTER_NAME)"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-agentcert-${ACE_INSTANCE_NAME}}"
CLUSTER_MODE="$(cur CLUSTER_MODE)"; CLUSTER_MODE="${CLUSTER_MODE:-auto}"

INST="${ACE_INSTANCE_NAME}"

echo
say "${CYAN}══════════════════════════════════════════════════════${NC}"
say "${CYAN}  ACE infrastructure teardown — instance: ${BOLD}${INST}${NC}"
say "${CYAN}══════════════════════════════════════════════════════${NC}"
say "${DIM}  Repo root : ${REPO_ROOT}${NC}"
say "${DIM}  .env      : ${ENV_FILE}${NC}"
echo

# ── Ownership helpers ─────────────────────────────────────────────────────────

# Return 0 (safe to proceed) if the named container either does not exist, or
# exists and was created by this checkout.  Return 1 (skip) if it was created
# by a different checkout — prints an error so the caller can skip that stack.
#
# Ownership is determined by comparing the inode of the container's
# com.docker.compose.project.environment_file label against the inode of our
# own ENV_FILE.  Path-string comparison is unreliable here because the host
# exposes the same directory tree under two mount paths (/home/... and
# /Innovation/home/...) — same inode, different strings.  stat -c '%d:%i'
# returns device:inode, which is path-alias-proof.
container_is_ours() {
    local name="$1"
    if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${name}"; then
        return 0   # does not exist — safe to proceed
    fi
    local their_env their_ino our_ino
    their_env="$(docker inspect "${name}" \
        --format '{{index .Config.Labels "com.docker.compose.project.environment_file"}}' \
        2>/dev/null || true)"
    [[ -z "${their_env}" ]] && return 0   # no env-file label — not a managed stack container
    our_ino="$(stat -c '%d:%i' "${ENV_FILE}" 2>/dev/null || true)"
    their_ino="$(stat -c '%d:%i' "${their_env}" 2>/dev/null || true)"
    if [[ -n "${their_ino}" && "${their_ino}" != "${our_ino}" ]]; then
        err "  Container '${name}' belongs to a different checkout: ${their_env}"
        err "  Refusing to touch it. If this is wrong, check ACE_INSTANCE_NAME in .env."
        return 1
    fi
    return 0
}

# Return 0 if ALL containers in a compose project belong to this checkout
# (or the project has no containers at all).  Return 1 otherwise.
project_is_ours() {
    local project="$1"
    local foreign=0
    local our_ino
    our_ino="$(stat -c '%d:%i' "${ENV_FILE}" 2>/dev/null || true)"
    while IFS= read -r cname; do
        [[ -z "${cname}" ]] && continue
        local their_env their_ino
        their_env="$(docker inspect "${cname}" \
            --format '{{index .Config.Labels "com.docker.compose.project.environment_file"}}' \
            2>/dev/null || true)"
        [[ -z "${their_env}" ]] && continue   # no env-file label — skip
        their_ino="$(stat -c '%d:%i' "${their_env}" 2>/dev/null || true)"
        if [[ -n "${their_ino}" && "${their_ino}" != "${our_ino}" ]]; then
            err "  Container '${cname}' (project '${project}') belongs to a different checkout: ${their_env}"
            err "  Refusing to touch this stack. Check ACE_INSTANCE_NAME in .env."
            foreign=1
        fi
    done < <(docker ps -a \
        --filter "label=com.docker.compose.project=${project}" \
        --format '{{.Names}}' 2>/dev/null || true)
    [[ "${foreign}" -eq 1 ]] && return 1
    return 0
}

# Compare two paths for referring to the same directory, alias-proof — the
# same "same tree under two mount paths" issue documented above for
# container_is_ours/project_is_ours also applies to the KinD ownership
# marker, which stores a path string rather than an inode. Compare device:inode
# of the directories instead of the raw strings.
same_dir() {
    local a b
    a="$(stat -c '%d:%i' "$1" 2>/dev/null || true)"
    b="$(stat -c '%d:%i' "$2" 2>/dev/null || true)"
    [[ -n "${a}" && "${a}" == "${b}" ]]
}

# ── Safeguard: verify at least some infra exists on this host ─────────────────
say "${BOLD}Scanning for ACE infrastructure (instance: ${BOLD}${INST}${NC}${BOLD})…${NC}"
echo

FOUND_CONTAINERS=()
FOUND_VOLUMES=()
KEPT_VOLUMES=()
FOUND_KIND=""

# -- Known container names created by setup.sh / start-local-services.sh ------
for cname in \
    "agentcert-mongo-${INST}" \
    "ace-mongo-keyfile-${INST}" \
    "ace-mongo-init-${INST}" \
    "ace-cluster-init-${INST}" \
    "ace-workspace-init-${INST}" \
    "agentcert-auth-${INST}" \
    "agentcert-graphql-${INST}" \
    "agentcert-web-${INST}" \
    "litellm-proxy-${INST}" \
    "certifier_app_${INST}" \
    "ollama-${INST}"; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${cname}"; then
        FOUND_CONTAINERS+=("${cname}")
    fi
done

# -- Langfuse containers are named by Compose (no explicit container_name:) ---
while IFS= read -r cname; do
    [[ -n "${cname}" ]] && FOUND_CONTAINERS+=("${cname} [langfuse]")
done < <(docker ps -a \
    --filter "label=com.docker.compose.project=ace-langfuse-${INST}" \
    --format '{{.Names}}' 2>/dev/null || true)

# -- Named volumes whose names encode ACE_INSTANCE_NAME -----------------------
_OLLAMA_MODELS_VOL="ollama-models-${INST}"
while IFS= read -r vname; do
    [[ -z "${vname}" ]] && continue
    if [[ "${vname}" == "${_OLLAMA_MODELS_VOL}" && "${KEEP_OLLAMA_MODEL}" -eq 1 ]]; then
        KEPT_VOLUMES+=("${vname}")
        continue
    fi
    FOUND_VOLUMES+=("${vname}")
done < <(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E \
    "^(ace-${INST}_|ace-langfuse-${INST}_|ace-litellm-${INST}_|ace-certifier-${INST}_|ollama-models-${INST}$)" \
    || true)

# -- KinD cluster (only count it if this checkout owns it) --------------------
if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
    _owner_marker="ace-kind-owner-${KIND_CLUSTER_NAME}"
    _cluster_owner="$(docker volume inspect "${_owner_marker}" \
        --format '{{index .Labels "ace.kind.owner"}}' 2>/dev/null || true)"
    if same_dir "${_cluster_owner}" "${REPO_ROOT}"; then
        FOUND_KIND="${KIND_CLUSTER_NAME}"
    else
        warn "KinD cluster '${KIND_CLUSTER_NAME}' exists but is owned by a different checkout"
        warn "(owner label: ${_cluster_owner:-none}). It will NOT be deleted."
    fi
    unset _owner_marker _cluster_owner
fi

TOTAL_FOUND=$(( ${#FOUND_CONTAINERS[@]} + ${#FOUND_VOLUMES[@]} ))
[[ -n "${FOUND_KIND}" ]] && TOTAL_FOUND=$(( TOTAL_FOUND + 1 ))

# -- Hard stop if nothing belongs to this checkout ----------------------------
if [[ "${TOTAL_FOUND}" -eq 0 ]]; then
    say "${YELLOW}No ACE infrastructure found for instance '${INST}' on this host.${NC}"
    say "${DIM}Nothing to shut down."
    if [[ ${#KEPT_VOLUMES[@]} -gt 0 ]]; then
        say "${DIM}(${KEPT_VOLUMES[*]} kept as requested via --keep-ollama-model)${NC}"
    fi
    say "If resources were created under a different instance name, check ACE_INSTANCE_NAME in .env.${NC}"
    exit 0
fi

# ── Show the teardown plan ────────────────────────────────────────────────────
say "${BOLD}Found the following resources owned by this checkout:${NC}"
echo

if [[ ${#FOUND_CONTAINERS[@]} -gt 0 ]]; then
    say "  ${CYAN}Containers (${#FOUND_CONTAINERS[@]}):${NC}"
    for c in "${FOUND_CONTAINERS[@]}"; do say "    • ${c}"; done
    echo
fi
if [[ ${#FOUND_VOLUMES[@]} -gt 0 ]]; then
    say "  ${CYAN}Volumes (${#FOUND_VOLUMES[@]}):${NC}"
    for v in "${FOUND_VOLUMES[@]}"; do say "    • ${v}"; done
    echo
fi
if [[ ${#KEPT_VOLUMES[@]} -gt 0 ]]; then
    say "  ${CYAN}Kept (--keep-ollama-model):${NC}"
    for v in "${KEPT_VOLUMES[@]}"; do say "    • ${v} ${DIM}(will NOT be deleted)${NC}"; done
    echo
fi
if [[ -n "${FOUND_KIND}" ]]; then
    say "  ${CYAN}KinD cluster:${NC}  ${FOUND_KIND}"
    echo
fi
if [[ "${CLUSTER_MODE}" == "local" || "${CLUSTER_MODE}" == "cloud" ]]; then
    warn "CLUSTER_MODE=${CLUSTER_MODE} — Kubernetes resources in the external cluster are NOT"
    warn "managed by this script. Run 'helm uninstall ace -n ace' or 'kubectl delete ns ace'"
    warn "manually against that cluster if needed."
    echo
fi

say "${RED}${BOLD}⚠  This permanently deletes all listed containers and their data volumes.${NC}"
say "${DIM}Docker images are NOT removed. Use 'docker image prune' or 'docker rmi' separately.${NC}"
echo

# ── Confirmation ──────────────────────────────────────────────────────────────
if [[ "${YES}" -eq 0 ]]; then
    read -rp "$(echo -e "Type ${BOLD}yes${NC} to proceed, anything else to abort: ")" _confirm
    echo
    if [[ "${_confirm}" != "yes" ]]; then
        say "${DIM}Aborted — nothing was changed.${NC}"
        exit 0
    fi
    unset _confirm
fi

# ── Teardown helper ───────────────────────────────────────────────────────────
# teardown_compose PROJECT COMPOSE_DIR FILE [FILE ...]
#   Stops and removes all containers + declared volumes for a compose project.
#   Falls back to label-based removal if any compose file is missing.
teardown_compose() {
    local project="$1"
    local compose_dir="$2"
    shift 2
    local compose_file_args=()

    # Verify ownership before touching anything in this project.
    if ! project_is_ours "${project}"; then
        warn "  Skipping project '${project}' — see error above."
        return 0
    fi

    # Check whether every supplied compose file actually exists.
    local all_exist=1
    for f in "$@"; do
        if [[ -f "${f}" ]]; then
            compose_file_args+=(-f "${f}")
        else
            all_exist=0
            warn "  Compose file not found: ${f}"
        fi
    done

    if [[ "${all_exist}" -eq 1 && ${#compose_file_args[@]} -gt 0 ]]; then
        if ( cd "${compose_dir}" && \
             COMPOSE_PROJECT_NAME="${project}" \
             docker compose "${compose_file_args[@]}" \
             --env-file "${ENV_FILE}" \
             down -v --remove-orphans 2>/dev/null ); then
            ok "  Project '${project}' stopped and volumes removed."
            return 0
        else
            warn "  'docker compose down' failed for '${project}' — falling back to label-based removal."
        fi
    fi

    # Fallback: remove by project label (handles stopped containers too).
    _remove_by_label "${project}"
}

# Remove all containers in a compose project by label, then prune their volumes.
_remove_by_label() {
    local project="$1"
    local did_something=0

    while IFS= read -r cname; do
        [[ -z "${cname}" ]] && continue
        if docker rm -f "${cname}" >/dev/null 2>&1; then
            ok "  Removed container: ${cname}"
            did_something=1
        else
            warn "  Could not remove container: ${cname}"
        fi
    done < <(docker ps -a \
        --filter "label=com.docker.compose.project=${project}" \
        --format '{{.Names}}' 2>/dev/null || true)

    while IFS= read -r vname; do
        [[ -z "${vname}" ]] && continue
        if docker volume rm "${vname}" >/dev/null 2>&1; then
            ok "  Removed volume: ${vname}"
            did_something=1
        else
            warn "  Could not remove volume: ${vname} (may still be in use)"
        fi
    done < <(docker volume ls --format '{{.Name}}' 2>/dev/null \
        | grep "^${project}_" || true)

    [[ "${did_something}" -eq 0 ]] && say "  ${DIM}Nothing found for project '${project}'.${NC}"
}

# Explicitly remove a single named volume if it exists.
remove_volume() {
    local vname="$1"
    if docker volume inspect "${vname}" >/dev/null 2>&1; then
        if docker volume rm "${vname}" >/dev/null 2>&1; then
            ok "  Removed volume: ${vname}"
        else
            warn "  Could not remove volume: ${vname} (may still be in use)"
        fi
    else
        say "  ${DIM}Volume '${vname}' not found.${NC}"
    fi
}

# ── 1. Certifier ──────────────────────────────────────────────────────────────
echo
say "${CYAN}▸ Certifier stack (ace-certifier-${INST})${NC}"
teardown_compose \
    "ace-certifier-${INST}" \
    "${REPO_ROOT}/certifier" \
    "${REPO_ROOT}/certifier/docker-compose.yml" \
    "${REPO_ROOT}/compose/certifier.override.yml"

# ── 2. LiteLLM ───────────────────────────────────────────────────────────────
echo
say "${CYAN}▸ LiteLLM stack (ace-litellm-${INST})${NC}"
_LITELLM_DIR="${REPO_ROOT}/agentcert-stack/litellm-setup"
teardown_compose \
    "ace-litellm-${INST}" \
    "${_LITELLM_DIR}" \
    "${_LITELLM_DIR}/docker-compose-litellm.yml" \
    "${REPO_ROOT}/compose/litellm.override.yml"
unset _LITELLM_DIR

# ── 3. Langfuse ──────────────────────────────────────────────────────────────
echo
say "${CYAN}▸ Langfuse stack (ace-langfuse-${INST})${NC}"
# start-local-services.sh always clones into .tmp/langfuse — use the same path.
_LANGFUSE_DIR="${REPO_ROOT}/.tmp/langfuse"
teardown_compose \
    "ace-langfuse-${INST}" \
    "${_LANGFUSE_DIR}" \
    "${_LANGFUSE_DIR}/docker-compose.yml" \
    "${REPO_ROOT}/compose/langfuse.override.yml"
unset _LANGFUSE_DIR

# ── 4. Root compose stack (MongoDB, auth, graphql, web, workspace-init …) ────
echo
say "${CYAN}▸ Root stack (ace-${INST}: MongoDB, auth, graphql, web…)${NC}"
# The root docker-compose.yml carries  name: ace-${ACE_INSTANCE_NAME}  so we
# pass --env-file instead of COMPOSE_PROJECT_NAME to let Compose resolve it
# from the file itself (which is how setup.sh originally created everything).
if project_is_ours "ace-${INST}"; then
    if ( cd "${REPO_ROOT}" && \
         docker compose -f docker-compose.yml \
         --env-file "${ENV_FILE}" \
         down -v --remove-orphans 2>/dev/null ); then
        ok "  Root stack stopped and volumes removed."
    else
        warn "  'docker compose down' failed for root stack — falling back to label-based removal."
        _remove_by_label "ace-${INST}"
    fi
else
    warn "  Skipping root stack — see ownership error above."
fi

# ── 5. Ollama (standalone container — started with docker run, not compose) ───
echo
say "${CYAN}▸ Ollama (standalone)${NC}"
_OLLAMA_CONT="ollama-${INST}"
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${_OLLAMA_CONT}"; then
    # Ollama is started with docker run; it carries no compose project label,
    # so ownership is implicit from the name encoding ACE_INSTANCE_NAME.
    if docker rm -f "${_OLLAMA_CONT}" >/dev/null 2>&1; then
        ok "  Removed container: ${_OLLAMA_CONT}"
    else
        warn "  Could not remove container: ${_OLLAMA_CONT}"
    fi
else
    say "  ${DIM}Container '${_OLLAMA_CONT}' not found.${NC}"
fi
unset _OLLAMA_CONT

# The ollama-models volume has an explicit name: override in docker-compose.yml
# (name: ollama-models-${ACE_INSTANCE_NAME}) which bypasses the compose project
# prefix, so it may not have been removed by the root compose down above.
if [[ "${KEEP_OLLAMA_MODEL}" -eq 1 ]]; then
    ok "  Kept volume: ${_OLLAMA_MODELS_VOL} ${DIM}(--keep-ollama-model)${NC}"
else
    remove_volume "${_OLLAMA_MODELS_VOL}"
fi

# ── 6. KinD cluster ───────────────────────────────────────────────────────────
echo
say "${CYAN}▸ KinD cluster${NC}"
_OWNER_MARKER="ace-kind-owner-${KIND_CLUSTER_NAME}"
if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
    _cluster_owner="$(docker volume inspect "${_OWNER_MARKER}" \
        --format '{{index .Labels "ace.kind.owner"}}' 2>/dev/null || true)"
    if same_dir "${_cluster_owner}" "${REPO_ROOT}"; then
        if kind delete cluster --name "${KIND_CLUSTER_NAME}"; then
            ok "  Deleted KinD cluster: ${KIND_CLUSTER_NAME}"
        else
            warn "  Failed to delete KinD cluster: ${KIND_CLUSTER_NAME}"
        fi
        # Remove the ownership marker regardless of whether kind delete succeeded.
        docker volume rm "${_OWNER_MARKER}" >/dev/null 2>&1 \
            && ok "  Removed ownership marker volume: ${_OWNER_MARKER}" || true
    else
        warn "  Cluster '${KIND_CLUSTER_NAME}' is owned by a different checkout"
        warn "  (owner: ${_cluster_owner:-none}). Skipping."
    fi
    unset _cluster_owner
else
    say "  ${DIM}KinD cluster '${KIND_CLUSTER_NAME}' not found.${NC}"
    # Remove a stale ownership marker that points to us (cluster already gone).
    _stale_owner="$(docker volume inspect "${_OWNER_MARKER}" \
        --format '{{index .Labels "ace.kind.owner"}}' 2>/dev/null || true)"
    if same_dir "${_stale_owner}" "${REPO_ROOT}"; then
        docker volume rm "${_OWNER_MARKER}" >/dev/null 2>&1 \
            && ok "  Removed stale ownership marker: ${_OWNER_MARKER}" || true
    fi
    unset _stale_owner
fi
unset _OWNER_MARKER

# ── 7. Final verification ─────────────────────────────────────────────────────
echo
say "${CYAN}▸ Verification${NC}"

_remaining_containers="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E \
    "^(agentcert-mongo|ace-mongo-keyfile|ace-mongo-init|ace-cluster-init|ace-workspace-init|agentcert-auth|agentcert-graphql|agentcert-web)-${INST}$|\
^(litellm-proxy|ollama)-${INST}$|\
^certifier_app_${INST}$" || true)"

# Also check Langfuse containers via project label
_remaining_langfuse="$(docker ps -a \
    --filter "label=com.docker.compose.project=ace-langfuse-${INST}" \
    --format '{{.Names}}' 2>/dev/null || true)"

_remaining_volumes="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E \
    "^(ace-${INST}_|ace-langfuse-${INST}_|ace-litellm-${INST}_|ace-certifier-${INST}_|ollama-models-${INST}$)" \
    || true)"
if [[ "${KEEP_OLLAMA_MODEL}" -eq 1 ]]; then
    _remaining_volumes="$(echo "${_remaining_volumes}" | grep -vx "${_OLLAMA_MODELS_VOL}" || true)"
fi

_all_remaining="${_remaining_containers}${_remaining_langfuse}${_remaining_volumes}"

if [[ -z "${_all_remaining}" ]]; then
    ok "All ACE resources for instance '${INST}' have been removed from this host."
else
    warn "Some resources could not be removed (check errors above):"
    for _r in ${_remaining_containers} ${_remaining_langfuse}; do
        [[ -n "${_r}" ]] && warn "  container: ${_r}"
    done
    for _r in ${_remaining_volumes}; do
        [[ -n "${_r}" ]] && warn "  volume:    ${_r}"
    done
fi
unset _remaining_containers _remaining_langfuse _remaining_volumes _all_remaining

echo
say "${BOLD}Teardown complete.${NC}"
say "${DIM}Docker images were NOT removed. To free image disk space:${NC}"
say "${DIM}  docker rmi agentcert/certifier:latest agentcert/agentcert-flash-agent:latest \\"
say "           agentcert/agent-sidecar:latest agentcert/agentcert-install-agent:latest \\"
say "           agentcert/agentcert-install-app:latest agentcert/cluster-init:latest${NC}"
echo
