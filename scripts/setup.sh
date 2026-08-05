#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# ACE first-time setup wizard
# =============================================================================
# Creates and fills the monorepo-root .env for a brand-new user, prompting ONLY
# for what actually matters (Azure OpenAI) and defaulting everything else.
#
#   ./scripts/setup.sh
#
# Idempotent: re-run any time. It reads your current .env (or .env.example) for
# defaults, so pressing Enter keeps the existing value. Nothing is committed —
# .env is gitignored.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
EXAMPLE_FILE="${REPO_ROOT}/.env.example"

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'

say()  { echo -e "$*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }

# --- Invocation mode ----------------------------------------------------------
#   --setup    (default) full first-time wizard: prompts, writes .env, deploys
#   --restart  skip all prompts and .env edits; just re-apply the stack
SETUP_MODE="setup"
BUILD_MODE="prompt"   # "local" pre-answers the build prompt; "prompt" = ask interactively
for _arg in "$@"; do
    case "$_arg" in
        --restart)     SETUP_MODE="restart" ;;
        --setup)       SETUP_MODE="setup"   ;;
        --local-build) BUILD_MODE="local"   ;;
    esac
done
unset _arg

# --- prep .env -------------------------------------------------------------
if [[ ! -f "${EXAMPLE_FILE}" ]]; then
    echo "ERROR: ${EXAMPLE_FILE} not found — run from a full checkout." >&2
    exit 1
fi
if [[ ! -f "${ENV_FILE}" ]]; then
    cp "${EXAMPLE_FILE}" "${ENV_FILE}"
    ok "Created .env from .env.example"
else
    ok "Using existing .env (press Enter at each prompt to keep current values)"
fi

# current value of KEY in .env (empty if unset)
cur() { grep -m1 "^$1=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true; }

# Backfill ACE_INSTANCE_NAME if this .env doesn't have one yet. Every
# host-wide unique resource this script creates (kind cluster name, and via
# scripts/start-local-services.sh: container/volume/compose-project names)
# is suffixed with this so two checkouts of this monorepo on the same shared
# host never collide by defaulting to the same name -- see CLAUDE.md
# section 0. Runs unconditionally (both --setup and --restart) so an
# existing .env missing this (e.g. from before this check existed) gets
# fixed on the next run without the user having to do anything.
if ! grep -q '^ACE_INSTANCE_NAME=.\+' "${ENV_FILE}" 2>/dev/null; then
    _default_instance_name="$(id -un | tr '[:upper:].' '[:lower:]-')"
    if grep -q '^ACE_INSTANCE_NAME=' "${ENV_FILE}" 2>/dev/null; then
        sed -i "s|^ACE_INSTANCE_NAME=.*|ACE_INSTANCE_NAME=${_default_instance_name}|" "${ENV_FILE}"
    else
        echo "ACE_INSTANCE_NAME=${_default_instance_name}" >> "${ENV_FILE}"
    fi
    ok "Set ACE_INSTANCE_NAME=${_default_instance_name} in .env (keeps this checkout's shared-host resources unique)"
    unset _default_instance_name
fi

# Backfill OLLAMA_PORT if missing/empty. Derived from UID so each user on
# this shared host gets a distinct port and never collides with the system
# Ollama on :11434. Range: 11440–15535 (4096 slots). Runs unconditionally
# (both --setup and --restart) so an existing .env missing this key gets
# fixed on the next run. Also keeps OLLAMA_BASE_URL in sync if it still
# points at an old default port (11434 or 11435).
if ! grep -q '^OLLAMA_PORT=[0-9]' "${ENV_FILE}" 2>/dev/null; then
    # Start from a UID-derived candidate so two users rarely pick the same
    # port even before the availability check. Then walk forward until we find
    # one that is genuinely free on this host right now.
    _candidate=$(( 11440 + $(id -u) % 4096 ))
    _checked=0
    while ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ":${_candidate}$"; do
        _candidate=$(( _candidate + 1 ))
        _checked=$(( _checked + 1 ))
        if (( _checked >= 100 )); then
            echo "ERROR: could not find a free OLLAMA_PORT after 100 attempts (tried $(( _candidate - 100 ))–${_candidate})." >&2
            echo "ERROR: Set OLLAMA_PORT manually in .env to a free port, then re-run." >&2
            unset _candidate _checked
            exit 1
        fi
    done
    if grep -q '^OLLAMA_PORT=' "${ENV_FILE}" 2>/dev/null; then
        sed -i "s|^OLLAMA_PORT=.*|OLLAMA_PORT=${_candidate}|" "${ENV_FILE}"
    else
        echo "OLLAMA_PORT=${_candidate}" >> "${ENV_FILE}"
    fi
    # Sync OLLAMA_BASE_URL only when it still holds one of the two
    # placeholder defaults (11434 = system Ollama, 11435 = .env.example
    # fallback). A user who manually set a different URL must not have it
    # silently overwritten.
    if grep -qE '^OLLAMA_BASE_URL=http://host\.docker\.internal:(11434|11435)$' "${ENV_FILE}" 2>/dev/null; then
        sed -i "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=http://host.docker.internal:${_candidate}|" "${ENV_FILE}"
    fi
    ok "Set OLLAMA_PORT=${_candidate} in .env (UID-derived + verified free on this host)"
    unset _candidate _checked
fi

# Backfill AGENT_CHARTS_ROOT and APP_CHARTS_ROOT to this checkout's actual paths.
# Backfill KIND_CLUSTER_NAME if the value in .env names a cluster that doesn't
# exist. This happens when ACE_INSTANCE_NAME is renamed (e.g. during a shared-host
# refactor) while the KinD cluster was created under the old name. Detect the
# mismatch by checking `kind get clusters`, then fall back to the current kubectl
# context (kind-<name>) so the existing running cluster is adopted automatically.
# Runs unconditionally (both --setup and --restart).
_configured_cluster="$(cur KIND_CLUSTER_NAME)"
if [[ -n "${_configured_cluster}" ]] && ! kind get clusters 2>/dev/null | grep -qx "${_configured_cluster}"; then
    _context_cluster="$(kubectl config current-context 2>/dev/null | sed 's/^kind-//' || true)"
    if [[ -n "${_context_cluster}" ]] && kind get clusters 2>/dev/null | grep -qx "${_context_cluster}"; then
        sed -i "s|^KIND_CLUSTER_NAME=.*|KIND_CLUSTER_NAME=${_context_cluster}|" "${ENV_FILE}"
        ok "KIND_CLUSTER_NAME corrected: '${_configured_cluster}' not found, adopted running cluster '${_context_cluster}' from current kubectl context"
    fi
fi
unset _configured_cluster _context_cluster

# Runs unconditionally (both --setup and --restart) so a .env copied from another
# checkout (e.g. /srv/projects/ace-monorepo) gets corrected automatically.
for _charts_var in AGENT_CHARTS_ROOT APP_CHARTS_ROOT; do
    _charts_subdir="${_charts_var//_CHARTS_ROOT/}"; _charts_subdir="${_charts_subdir,,}-charts"
    _expected_path="${REPO_ROOT}/${_charts_subdir}"
    _current_val="$(grep -m1 "^${_charts_var}=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
    if [[ "${_current_val}" != "${_expected_path}" ]]; then
        if grep -q "^${_charts_var}=" "${ENV_FILE}" 2>/dev/null; then
            sed -i "s|^${_charts_var}=.*|${_charts_var}=${_expected_path}|" "${ENV_FILE}"
        else
            echo "${_charts_var}=${_expected_path}" >> "${ENV_FILE}"
        fi
        ok "Set ${_charts_var}=${_expected_path}"
    fi
done
unset _charts_var _charts_subdir _expected_path _current_val

# Backfill CHAOS_CHARTS_ROOT separately — the subdir name (chaos-charts-default)
# does not follow the AGENT/APP pattern so it can't use the loop above.
_expected_chaos="${REPO_ROOT}/chaos-charts-default"
_current_chaos="$(grep -m1 "^CHAOS_CHARTS_ROOT=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
if [[ "${_current_chaos}" != "${_expected_chaos}" ]]; then
    if grep -q "^CHAOS_CHARTS_ROOT=" "${ENV_FILE}" 2>/dev/null; then
        sed -i "s|^CHAOS_CHARTS_ROOT=.*|CHAOS_CHARTS_ROOT=${_expected_chaos}|" "${ENV_FILE}"
    else
        echo "CHAOS_CHARTS_ROOT=${_expected_chaos}" >> "${ENV_FILE}"
    fi
    ok "Set CHAOS_CHARTS_ROOT=${_expected_chaos}"
fi
unset _expected_chaos _current_chaos

# Self-heal FLASH_AGENT_MODEL if it points at a provider that isn't actually
# configured (or whose credentials are still a copy-pasted placeholder, e.g.
# .env.example's https://YOUR_RESOURCE.openai.azure.com/). Runs unconditionally
# (both --setup and --restart) by reading .env directly, so this corrects
# itself on every run — including plain `--restart` runs where the interactive
# provider prompts never execute and the guided/express-mode fixes above don't
# apply. Without this, a value written once (e.g. while trying Azure) sticks
# forever even after switching entirely to another provider, because the
# provider check in the interactive prompts only fires in --setup mode.
_az_key="$(cur AZURE_OPENAI_KEY)"
_az_endpoint="$(cur AZURE_OPENAI_ENDPOINT)"
_az_alias="$(cur AZURE_OPENAI_DEPLOYMENT)"
_gemini_key="$(cur GEMINI_API_KEY)"
_openrouter_key="$(cur OPENROUTER_API_KEY)"
_ollama_model_cur="$(cur OLLAMA_MODEL)"
_ollama_alias_cur=""
[[ -n "${_ollama_model_cur}" ]] && _ollama_alias_cur="$(echo "${_ollama_model_cur}" | tr ':' '-')"

# Ollama is checked first and wins ties: it's the only provider whose
# "health" this script can actually confirm end-to-end (a real, running,
# ownership-guarded local container — see the Ollama-ensure-running block
# below), whereas Azure/Gemini/OpenRouter health here is just "looks like a
# real key/endpoint was typed in," not a verified live credential.
declare -a _healthy_aliases=()
[[ -n "${_ollama_alias_cur}" ]] && _healthy_aliases+=("${_ollama_alias_cur}")
if [[ -n "${_az_key}" && -n "${_az_endpoint}" && "${_az_endpoint}" != *YOUR_RESOURCE* && "${_az_endpoint}" != *CHANGE_ME* ]]; then
    _healthy_aliases+=("${_az_alias:-gpt-4o}")
fi
[[ -n "${_gemini_key}" ]] && _healthy_aliases+=("gemini-3-flash" "gemini-2.5-flash" "gemini-2.5-flash-lite")
[[ -n "${_openrouter_key}" ]] && _healthy_aliases+=("auto-free")

_cur_flash="$(cur FLASH_AGENT_MODEL)"
if [[ ${#_healthy_aliases[@]} -gt 0 && -n "${_cur_flash}" ]]; then
    _flash_is_healthy=0
    for _a in "${_healthy_aliases[@]}"; do
        [[ "${_a}" == "${_cur_flash}" ]] && _flash_is_healthy=1 && break
    done
    if [[ "${_flash_is_healthy}" -eq 0 ]]; then
        warn "FLASH_AGENT_MODEL='${_cur_flash}' doesn't match any configured provider (available: ${_healthy_aliases[*]}) — correcting to '${_healthy_aliases[0]}'"
        if grep -q '^FLASH_AGENT_MODEL=' "${ENV_FILE}" 2>/dev/null; then
            sed -i "s|^FLASH_AGENT_MODEL=.*|FLASH_AGENT_MODEL=${_healthy_aliases[0]}|" "${ENV_FILE}"
        else
            echo "FLASH_AGENT_MODEL=${_healthy_aliases[0]}" >> "${ENV_FILE}"
        fi
    fi
fi
unset _az_key _az_endpoint _az_alias _gemini_key _openrouter_key _ollama_model_cur _ollama_alias_cur _cur_flash _flash_is_healthy _a _healthy_aliases

# Image build definitions — available to both --setup (interactive) and --restart --local-build
declare -a ALL_BUILD_IMAGES=(
    "1|flash-agent|agentcert/agentcert-flash-agent|${REPO_ROOT}/agents/flash-agent|Dockerfile|direct"
    "2|agent-sidecar|agentcert/agent-sidecar|${REPO_ROOT}/agent-sidecar|Dockerfile|direct"
    "3|install-agent|agentcert/agentcert-install-agent|${REPO_ROOT}/agent-charts|install-agent/Dockerfile|direct"
    "4|install-app|agentcert/agentcert-install-app|${REPO_ROOT}/app-charts|install-app/Dockerfile|direct"
    "5|certifier|agentcert/certifier|${REPO_ROOT}/certifier|Dockerfile|direct"
    "6|auth|agentcert/agentcert-auth|${REPO_ROOT}/AgentCert/chaoscenter/authentication|Dockerfile|direct"
    "7|graphql|agentcert/agentcert-graphql|${REPO_ROOT}/AgentCert/chaoscenter/graphql|server/Dockerfile|direct"
    "8|web|agentcert/agentcert-web|||compose:agentcert-web"
    "9|cluster-init|agentcert/cluster-init|${REPO_ROOT}/compose/cluster-init|Dockerfile|direct"
)

if [[ "$SETUP_MODE" == "restart" ]]; then
    EXPRESS_MODE=0   # restart never runs the interactive express/guided wizard
    CLUSTER_MODE="$(cur CLUSTER_MODE)"; CLUSTER_MODE="${CLUSTER_MODE:-auto}"
    PLATFORM_IMAGE_SOURCE="$(cur PLATFORM_IMAGE_SOURCE)"; PLATFORM_IMAGE_SOURCE="${PLATFORM_IMAGE_SOURCE:-skip}"
    DO_BUILD=0; DO_LOCAL_BUILD=0; DH_USER=""; DH_TOKEN=""
    declare -a SELECTED_BUILD_IMAGES=()

    echo
    echo -e "${CYAN}=======================================================${NC}"
    echo -e "${CYAN}  ACE restart — re-applying stack${NC}"
    echo -e "${CYAN}=======================================================${NC}"
    echo -e "${DIM}  CLUSTER_MODE=${CLUSTER_MODE}  ·  image policy: ${PLATFORM_IMAGE_SOURCE}  ·  .env: ${ENV_FILE}${NC}"
    echo
    read -rp "$(echo -e "  ${BOLD}r${NC} Reconfigure all choices  |  Enter = Continue with policy above  [r/Enter]: ")" _restart_choice
    echo
    if [[ "${_restart_choice,,}" == "r" ]]; then
        SETUP_MODE="setup"
    else
        # Apply persisted platform image build policy
        case "${PLATFORM_IMAGE_SOURCE}" in
            local)
                DO_LOCAL_BUILD=1
                SELECTED_BUILD_IMAGES=("${ALL_BUILD_IMAGES[@]}")
                ;;
            push)
                DH_USER="$(cur DOCKERHUB_USERNAME)"
                DH_TOKEN="$(cur DOCKERHUB_TOKEN)"
                if [[ -n "${DH_USER}" && -n "${DH_TOKEN}" ]]; then
                    DO_BUILD=1
                    SELECTED_BUILD_IMAGES=("${ALL_BUILD_IMAGES[@]}")
                else
                    warn "PLATFORM_IMAGE_SOURCE=push but DOCKERHUB_USERNAME/TOKEN not set — skipping build."
                fi
                ;;
        esac
        # --local-build CLI flag always overrides persisted policy
        if [[ "${BUILD_MODE}" == "local" ]]; then
            DO_LOCAL_BUILD=1
            SELECTED_BUILD_IMAGES=("${ALL_BUILD_IMAGES[@]}")
        fi
    fi
    unset _restart_choice
fi

# ask "KEY" "Prompt label" → echoes chosen value (default = current .env value)
ask() {
    local key="$1" label="$2" def reply
    def="$(cur "$key")"
    if [[ -n "$def" && "$def" != CHANGE_ME && "$def" != REPLACE_ME && "$def" != *YOUR_RESOURCE* ]]; then
        read -rp "$(echo -e "  ${BOLD}${label}${NC} ${DIM}[${def}]${NC}: ")" reply
        echo "${reply:-$def}"
    else
        read -rp "$(echo -e "  ${BOLD}${label}${NC}: ")" reply
        echo "${reply}"
    fi
}

if [[ "$SETUP_MODE" == "setup" ]]; then

echo
echo -e "${CYAN}=======================================================${NC}"
echo -e "${CYAN}  ACE setup — fill the few values that matter${NC}"
echo -e "${CYAN}=======================================================${NC}"
echo -e "${DIM}Everything not asked here has a working default for the${NC}"
echo -e "${DIM}all-local 'docker compose up' flow. Only Azure OpenAI is${NC}"
echo -e "${DIM}required for the agent's LLM calls to actually work.${NC}"
echo

# --- Setup style: express (all questions now) or guided (section by section) --
EXPRESS_MODE=0
_DEPLOY_CHOICE=""
echo -e "${BOLD}Setup style${NC}"
echo -e "   ${BOLD}e${NC}  Express — answer every question now, then the script runs unattended"
echo -e "   ${BOLD}g${NC}  Guided  — answer questions one section at a time ${DIM}(default)${NC}"
read -rp "$(echo -e "  Choice ${DIM}[e/G]${NC}: ")" _style_ans
[[ "${_style_ans,,}" == "e" ]] && EXPRESS_MODE=1
unset _style_ans
echo

if [[ $EXPRESS_MODE -eq 1 ]]; then
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Express setup — all questions upfront${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${DIM}  Press Enter to keep the value shown in [brackets].${NC}"
    echo

    # Build
    echo -e "${BOLD}▸ Build images?${NC}  p=push to Docker Hub  l=build locally  n=skip"
    DO_BUILD=0; DO_LOCAL_BUILD=0; DH_USER=""; DH_TOKEN=""
    declare -a SELECTED_BUILD_IMAGES=()
    read -rp "  Choice [p/l/N]: " _eb
    case "${_eb,,}" in
        p)  DH_USER="$(ask DOCKERHUB_USERNAME 'Docker Hub username')"
            DH_TOKEN="$(ask DOCKERHUB_TOKEN   'Docker Hub token')"
            DH_USER="$(echo "${DH_USER}" | tr -d '[:space:]')"
            DH_TOKEN="$(echo "${DH_TOKEN}" | tr -d '[:space:]')"
            if [[ -n "$DH_USER" && -n "$DH_TOKEN" ]]; then
                DO_BUILD=1; SELECTED_BUILD_IMAGES=("${ALL_BUILD_IMAGES[@]}")
            else
                warn "Credentials missing — skipping build."
            fi ;;
        l)  DO_LOCAL_BUILD=1; SELECTED_BUILD_IMAGES=("${ALL_BUILD_IMAGES[@]}") ;;
    esac
    _pis="skip"; [[ $DO_BUILD -eq 1 ]] && _pis="push"; [[ $DO_LOCAL_BUILD -eq 1 ]] && _pis="local"
    if grep -q '^PLATFORM_IMAGE_SOURCE=' "${ENV_FILE}" 2>/dev/null; then
        sed -i "s|^PLATFORM_IMAGE_SOURCE=.*|PLATFORM_IMAGE_SOURCE=${_pis}|" "${ENV_FILE}"
    else
        echo "PLATFORM_IMAGE_SOURCE=${_pis}" >> "${ENV_FILE}"
    fi
    unset _pis
    echo

    # Image sources
    echo -e "${BOLD}▸ Experiment image sources${NC}  d=Docker Hub  j=JFrog  l=local build"
    read -rp "  install-application  (agentcert-install-app)   [d/j/l, Enter=d]: " _ans
    case "${_ans,,}" in j) _INSTALL_APP_SRC="jfrog" ;; l) _INSTALL_APP_SRC="local" ;; *) _INSTALL_APP_SRC="dockerhub" ;; esac
    read -rp "  install-agent        (agentcert-install-agent) [d/j/l, Enter=d]: " _ans
    case "${_ans,,}" in j) _INSTALL_AGENT_SRC="jfrog" ;; l) _INSTALL_AGENT_SRC="local" ;; *) _INSTALL_AGENT_SRC="dockerhub" ;; esac
    read -rp "  litmuschaos helpers  (k8s/checker/deployer)    [d/l,   Enter=d]: " _ans
    case "${_ans,,}" in l) _LITMUS_SRC="local" ;; *) _LITMUS_SRC="dockerhub" ;; esac
    unset _ans
    if [[ "${_INSTALL_APP_SRC}" == "jfrog" || "${_INSTALL_AGENT_SRC}" == "jfrog" ]]; then
        echo -e "  ${BOLD}JFrog credentials${NC}"
        _JFROG_HOST="$(ask JFROG_HOST          'JFrog host')"
        _JFROG_PATH="$(ask JFROG_REGISTRY_PATH 'Registry path')"
        _JFROG_USER="$(ask JFROG_USER          'Username')"
        _JFROG_TOKEN="$(ask JFROG_TOKEN        'Token / password')"
    fi
    echo

    # LiteLLM / Azure OpenAI
    echo -e "${BOLD}▸ Azure OpenAI${NC}  ${DIM}(certifier + flash-agent; Enter to skip)${NC}"
    AZ_KEY="$(ask AZURE_OPENAI_KEY 'API key')"
    AZ_ENDPOINT=""; AZ_DEPLOY=""; AZ_DEPLOY_GPT5=""; AZ_DEPLOY_EMBED=""; AZ_ALIAS=""; AZ_APIVER=""
    if [[ -n "$AZ_KEY" ]]; then
        AZ_ENDPOINT="$(ask AZURE_OPENAI_ENDPOINT                  'Endpoint (https://<resource>.openai.azure.com/)')"
        AZ_APIVER="$(ask   AZURE_OPENAI_API_VERSION                'API version')"
        AZ_DEPLOY="$(ask   AZURE_OPENAI_CHAT_DEPLOYMENT_NAME       'Standard deployment (certifier gpt-4o)')"
        AZ_DEPLOY_GPT5="$(ask AZURE_OPENAI_GPT5_CHAT_DEPLOYMENT_NAME 'Reasoning deployment (Enter=same as above)')"
        AZ_DEPLOY_EMBED="$(ask AZURE_EMBEDDING_MODEL               'Embedding deployment (Enter to skip)')"
        AZ_ALIAS="$(ask    AZURE_OPENAI_DEPLOYMENT                 'LiteLLM alias (e.g. gpt-4o)')"
        AZ_ENDPOINT="$(echo "${AZ_ENDPOINT}" | tr -d '[:space:]')"; AZ_ENDPOINT="${AZ_ENDPOINT%]}"
        AZ_DEPLOY="$(echo "${AZ_DEPLOY}" | tr -d '[:space:]')"
        AZ_DEPLOY_GPT5="$(echo "${AZ_DEPLOY_GPT5:-${AZ_DEPLOY}}" | tr -d '[:space:]')"
        AZ_DEPLOY_EMBED="$(echo "${AZ_DEPLOY_EMBED}" | tr -d '[:space:]')"
        AZ_ALIAS="$(echo "${AZ_ALIAS:-gpt-4o}" | tr -d '[:space:]')"
        AZ_APIVER="$(echo "${AZ_APIVER}" | tr -d '[:space:]')"
    fi

    echo -e "${BOLD}▸ Google Gemini${NC}  ${DIM}(Enter to skip)${NC}"
    GEMINI_KEY="$(ask GEMINI_API_KEY 'API key')"; GEMINI_KEY="$(echo "${GEMINI_KEY}" | tr -d '[:space:]')"

    echo -e "${BOLD}▸ OpenRouter${NC}  ${DIM}(Enter to skip)${NC}"
    OPENROUTER_KEY="$(ask OPENROUTER_API_KEY 'API key')"; OPENROUTER_KEY="$(echo "${OPENROUTER_KEY}" | tr -d '[:space:]')"

    echo -e "${BOLD}▸ Ollama${NC}  ${DIM}(local open-weight model; Enter to skip)${NC}"
    _cur_ollama="$(cur OLLAMA_MODEL)"
    if   [[ -n "$_cur_ollama" ]]; then _ollama_def="${_cur_ollama}"
    elif [[ -z "$AZ_KEY" && -z "$GEMINI_KEY" && -z "$OPENROUTER_KEY" ]]; then _ollama_def="qwen2.5:32b-instruct"
    else _ollama_def=""; fi
    if [[ -n "${_ollama_def}" ]]; then
        read -rp "$(echo -e "  Model ${DIM}[${_ollama_def}]${NC}: ")" _or; OLLAMA_MODEL_TAG="${_or:-${_ollama_def}}"
    else
        read -rp "$(echo -e "  Model ${DIM}(Enter to skip)${NC}: ")" _or; OLLAMA_MODEL_TAG="${_or}"
    fi
    OLLAMA_MODEL_TAG="$(echo "${OLLAMA_MODEL_TAG}" | tr -d '[:space:]')"
    [[ "${OLLAMA_MODEL_TAG,,}" == "none" || "${OLLAMA_MODEL_TAG,,}" == "skip" ]] && OLLAMA_MODEL_TAG=""
    [[ -n "${OLLAMA_MODEL_TAG}" ]] && OLLAMA_ALIAS="$(echo "${OLLAMA_MODEL_TAG}" | tr ':' '-')" || OLLAMA_ALIAS=""
    echo

    # Flash-agent model — Ollama first: matches the --restart self-heal
    # priority below (it's the only provider whose health is actually
    # verified end-to-end, not just "a key was typed in").
    CONFIGURED_MODELS=()
    [[ -n "${OLLAMA_MODEL_TAG}" ]] && CONFIGURED_MODELS+=("${OLLAMA_ALIAS}")
    [[ -n "$AZ_KEY" ]]           && CONFIGURED_MODELS+=("${AZ_ALIAS:-gpt-4o}")
    [[ -n "$GEMINI_KEY" ]]       && CONFIGURED_MODELS+=("gemini-3-flash" "gemini-2.5-flash" "gemini-2.5-flash-lite")
    [[ -n "$OPENROUTER_KEY" ]]   && CONFIGURED_MODELS+=("auto-free")
    _flash_def="${CONFIGURED_MODELS[0]:-$(cur FLASH_AGENT_MODEL)}"; _flash_def="${_flash_def:-gpt-4o}"
    echo -e "${BOLD}▸ Flash-agent model alias${NC}  ${DIM}${CONFIGURED_MODELS[*]:+(available: ${CONFIGURED_MODELS[*]})}${NC}"
    # See guided-mode comment: not using ask() so a stale .env value can't
    # override the freshly-computed _flash_def every run.
    read -rp "$(echo -e "  Model alias ${DIM}[${_flash_def}]${NC}: ")" FLASH_MODEL
    FLASH_MODEL="$(echo "${FLASH_MODEL:-${_flash_def}}" | tr -d '[:space:]')"
    echo

    # Cluster + CA cert
    echo -e "${BOLD}▸ Cluster mode${NC}  ${DIM}auto=reuse/create kind  local=existing  cloud=AKS/EKS/GKE  fresh=new kind${NC}"
    CLUSTER_MODE="$(ask CLUSTER_MODE 'CLUSTER_MODE')"; CLUSTER_MODE="${CLUSTER_MODE:-auto}"
    CUSTOM_CA_CERT_PATH="$(ask CUSTOM_CA_CERT_PATH 'Corporate CA cert path (Enter to skip)')"
    CUSTOM_CA_CERT_PATH="$(echo "${CUSTOM_CA_CERT_PATH}" | tr -d '[:space:]')"
    [[ -n "${CUSTOM_CA_CERT_PATH}" && ! -f "${CUSTOM_CA_CERT_PATH}" ]] \
        && { warn "File not found — will skip CA cert."; CUSTOM_CA_CERT_PATH=""; }
    echo

    # Deploy choice (asked now so the rest runs unattended)
    echo -e "${BOLD}▸ Deploy to Kubernetes?${NC}  k=kubectl  h=helm  n=skip"
    read -rp "  Choice [k/h/N]: " _DEPLOY_CHOICE
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    ok "All answers collected — script will now run unattended."
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo
fi

# --- Build: push to Docker Hub or build locally (optional) ------------------
if [[ $EXPRESS_MODE -eq 0 ]]; then
DO_BUILD=0; DO_LOCAL_BUILD=0; DH_USER=""; DH_TOKEN=""
declare -a SELECTED_BUILD_IMAGES=()

if [[ "${BUILD_MODE}" == "local" ]]; then
    # --local-build flag: skip prompt, build all images locally
    SELECTED_BUILD_IMAGES=("${ALL_BUILD_IMAGES[@]}")
    DO_LOCAL_BUILD=1
else
    echo -e "${BOLD}Build Docker images?${NC}"
    echo -e "   ${BOLD}p${NC}  Build and push to Docker Hub"
    echo -e "   ${BOLD}l${NC}  Build locally only  ${DIM}(loads into KinD — no Docker Hub account needed)${NC}"
    echo -e "   ${BOLD}n${NC}  Skip"
    read -rp "$(echo -e "Choice ${DIM}[p/l/N]${NC}: ")" _build_ans
    _sel_mode="none"
    case "${_build_ans,,}" in
        p) _sel_mode="push"  ;;
        l) _sel_mode="local" ;;
    esac
    if [[ "${_sel_mode}" != "none" ]]; then
        echo
        echo -e "   Select services to build ${DIM}(space-separated numbers, or Enter for all):${NC}"
        for _entry in "${ALL_BUILD_IMAGES[@]}"; do
            IFS='|' read -r _num _label _img _ _ _method <<< "$_entry"
            [[ "$_method" == compose:* ]] && _note="via compose" || _note="direct"
            echo -e "     ${BOLD}${_num})${NC} ${_label}  ${DIM}(${_img}:latest, ${_note})${NC}"
        done
        read -rp "   Selection [all]: " _sel
        for _entry in "${ALL_BUILD_IMAGES[@]}"; do
            IFS='|' read -r _num _ _ _ _ _ <<< "$_entry"
            if [[ -z "$_sel" ]] || echo " ${_sel} " | grep -qw "${_num}"; then
                SELECTED_BUILD_IMAGES+=("$_entry")
            fi
        done
    fi
    if [[ "${_sel_mode}" == "push" && ${#SELECTED_BUILD_IMAGES[@]} -gt 0 ]]; then
        echo
        DH_USER="$(ask DOCKERHUB_USERNAME 'Docker Hub username')"
        DH_TOKEN="$(ask DOCKERHUB_TOKEN 'Docker Hub token (dckr_pat_...)')"
        DH_USER="$(echo "${DH_USER}" | tr -d '[:space:]')"
        DH_TOKEN="$(echo "${DH_TOKEN}" | tr -d '[:space:]')"
        [[ -n "$DH_USER" && -n "$DH_TOKEN" ]] && DO_BUILD=1 \
            || warn "Docker Hub credentials missing — skipping build."
    elif [[ "${_sel_mode}" == "local" && ${#SELECTED_BUILD_IMAGES[@]} -gt 0 ]]; then
        DO_LOCAL_BUILD=1
    fi
    unset _build_ans _sel_mode _sel
fi
_pis="skip"; [[ $DO_BUILD -eq 1 ]] && _pis="push"; [[ $DO_LOCAL_BUILD -eq 1 ]] && _pis="local"
if grep -q '^PLATFORM_IMAGE_SOURCE=' "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^PLATFORM_IMAGE_SOURCE=.*|PLATFORM_IMAGE_SOURCE=${_pis}|" "${ENV_FILE}"
else
    echo "PLATFORM_IMAGE_SOURCE=${_pis}" >> "${ENV_FILE}"
fi
unset _pis
echo
fi # EXPRESS_MODE -eq 0 (build section)

# --- Experiment image sources -----------------------------------------------
# Wizard is skipped in --restart mode (sources are already in .env).
_INSTALL_APP_SRC=""; _INSTALL_AGENT_SRC=""; _LITMUS_SRC=""
_JFROG_HOST=""; _JFROG_PATH=""; _JFROG_USER=""; _JFROG_TOKEN=""
if [[ "$SETUP_MODE" == "setup" && $EXPRESS_MODE -eq 0 ]]; then
    echo -e "${BOLD}Experiment image sources${NC}"
    echo -e "   ${DIM}The graphql server injects these into every Argo Workflow it creates,${NC}"
    echo -e "   ${DIM}overriding whatever image the ChaosHub template carries.${NC}"
    echo
    echo -e "   ${BOLD}d${NC}  Docker Hub   ${DIM}public images, no credentials needed${NC}"
    echo -e "   ${BOLD}j${NC}  JFrog        ${DIM}Infosys Artifactory — requires credentials${NC}"
    echo -e "   ${BOLD}l${NC}  Local build  ${DIM}build from source in this repo, loaded into KinD — no network${NC}"
    echo
    read -rp "$(echo -e "  install-application  ${DIM}(agentcert-install-app)   [d/j/l, Enter=d]${NC}: ")" _ans
    case "${_ans,,}" in j) _INSTALL_APP_SRC="jfrog" ;; l) _INSTALL_APP_SRC="local" ;; *) _INSTALL_APP_SRC="dockerhub" ;; esac
    read -rp "$(echo -e "  install-agent        ${DIM}(agentcert-install-agent) [d/j/l, Enter=d]${NC}: ")" _ans
    case "${_ans,,}" in j) _INSTALL_AGENT_SRC="jfrog" ;; l) _INSTALL_AGENT_SRC="local" ;; *) _INSTALL_AGENT_SRC="dockerhub" ;; esac
    read -rp "$(echo -e "  litmus helper images ${DIM}(k8s/checker/deployer)    [d/l, Enter=d]${NC}: ")" _ans
    case "${_ans,,}" in l) _LITMUS_SRC="local" ;; *) _LITMUS_SRC="dockerhub" ;; esac
    unset _ans

    if [[ "${_INSTALL_APP_SRC}" == "jfrog" || "${_INSTALL_AGENT_SRC}" == "jfrog" ]]; then
        echo
        echo -e "  ${BOLD}JFrog Artifactory credentials${NC}"
        _JFROG_HOST="$(ask JFROG_HOST   'JFrog host')"
        _JFROG_PATH="$(ask JFROG_REGISTRY_PATH 'Registry path')"
        _JFROG_USER="$(ask JFROG_USER   'Username')"
        _JFROG_TOKEN="$(ask JFROG_TOKEN 'Token / password')"
    fi
    echo
fi
export _INSTALL_APP_SRC _INSTALL_AGENT_SRC _LITMUS_SRC \
       _JFROG_HOST _JFROG_PATH _JFROG_USER _JFROG_TOKEN

# --- Sections 1-4: LiteLLM, Flash, Cluster, CA cert (guided mode only) ------
if [[ $EXPRESS_MODE -eq 0 ]]; then
# --- Section 1: LiteLLM model configuration --------------------------------
echo -e "${BOLD}1) LiteLLM models${NC} ${DIM}(configure which providers the proxy can reach; press Enter to skip a provider)${NC}"
echo

echo -e "   ${BOLD}a) Azure OpenAI${NC}"
echo -e "      ${DIM}Used by: LiteLLM proxy (flash-agent) + certifier (direct SDK calls)${NC}"
echo -e "      ${DIM}Certifier needs Azure regardless of which model the flash-agent uses.${NC}"
AZ_KEY="$(ask AZURE_OPENAI_KEY 'API key (Enter to skip)')"
AZ_ENDPOINT=""; AZ_DEPLOY=""; AZ_DEPLOY_GPT5=""; AZ_DEPLOY_EMBED=""
AZ_ALIAS=""; AZ_APIVER=""
if [[ -n "$AZ_KEY" ]]; then
    AZ_ENDPOINT="$(ask AZURE_OPENAI_ENDPOINT 'Endpoint (https://<resource>.openai.azure.com/)')"
    AZ_APIVER="$(ask AZURE_OPENAI_API_VERSION 'API version (Enter for default)')"
    echo -e "      ${DIM}-- Certifier model deployments (exact names in Azure Portal) --${NC}"
    AZ_DEPLOY="$(ask AZURE_OPENAI_CHAT_DEPLOYMENT_NAME 'Standard model deployment (certifier gpt-4o, e.g. gpt4o)')"
    AZ_DEPLOY_GPT5="$(ask AZURE_OPENAI_GPT5_CHAT_DEPLOYMENT_NAME 'Reasoning model deployment (certifier gpt-5.2, Enter = same as above)')"
    AZ_DEPLOY_EMBED="$(ask AZURE_EMBEDDING_MODEL 'Embedding deployment (Enter to skip embeddings)')"
    echo -e "      ${DIM}-- LiteLLM alias --${NC}"
    AZ_ALIAS="$(ask AZURE_OPENAI_DEPLOYMENT 'Model alias in LiteLLM (what agents call it, e.g. gpt-4o)')"
    # Sanitize: strip whitespace and a stray trailing ']' that easily sneaks in on paste.
    AZ_ENDPOINT="$(echo "${AZ_ENDPOINT}" | tr -d '[:space:]')"; AZ_ENDPOINT="${AZ_ENDPOINT%]}"
    AZ_DEPLOY="$(echo "${AZ_DEPLOY}" | tr -d '[:space:]')"
    AZ_DEPLOY_GPT5="$(echo "${AZ_DEPLOY_GPT5:-${AZ_DEPLOY}}" | tr -d '[:space:]')"
    AZ_DEPLOY_EMBED="$(echo "${AZ_DEPLOY_EMBED}" | tr -d '[:space:]')"
    AZ_ALIAS="$(echo "${AZ_ALIAS:-gpt-4o}" | tr -d '[:space:]')"
    AZ_APIVER="$(echo "${AZ_APIVER}" | tr -d '[:space:]')"
fi
echo

echo -e "   ${BOLD}b) Google Gemini${NC} ${DIM}(provides: gemini-3-flash  gemini-2.5-flash  gemini-2.5-flash-lite)${NC}"
GEMINI_KEY="$(ask GEMINI_API_KEY 'API key (Enter to skip)')"
GEMINI_KEY="$(echo "${GEMINI_KEY}" | tr -d '[:space:]')"
echo

echo -e "   ${BOLD}c) OpenRouter${NC} ${DIM}(provides: auto-free)${NC}"
OPENROUTER_KEY="$(ask OPENROUTER_API_KEY 'API key (Enter to skip)')"
OPENROUTER_KEY="$(echo "${OPENROUTER_KEY}" | tr -d '[:space:]')"
echo

echo -e "   ${BOLD}d) Ollama${NC} ${DIM}(local open-weight model — no external API key required)${NC}"
echo -e "      ${DIM}The model is pulled automatically via 'ollama pull'. Press Enter for the default,${NC}"
echo -e "      ${DIM}or leave blank (type a space then Enter, or 'none') to skip Ollama.${NC}"
# Smart default: offer the qwen2.5 32b only when no external provider is configured
# (or when the user already has OLLAMA_MODEL set in .env). If they have API keys, skip.
_cur_ollama="$(cur OLLAMA_MODEL)"
if [[ -n "$_cur_ollama" ]]; then
    _ollama_def="${_cur_ollama}"
elif [[ -z "$AZ_KEY" && -z "$GEMINI_KEY" && -z "$OPENROUTER_KEY" ]]; then
    _ollama_def="qwen2.5:32b-instruct"
else
    _ollama_def=""
fi
if [[ -n "${_ollama_def}" ]]; then
    read -rp "$(echo -e "  ${BOLD}Ollama model${NC} ${DIM}[${_ollama_def}]${NC}: ")" _ollama_reply
    OLLAMA_MODEL_TAG="${_ollama_reply:-${_ollama_def}}"
else
    read -rp "$(echo -e "  ${BOLD}Ollama model${NC} ${DIM}(Enter to skip; or e.g. qwen2.5:32b-instruct, llama3.3:70b)${NC}: ")" _ollama_reply
    OLLAMA_MODEL_TAG="${_ollama_reply}"
fi
OLLAMA_MODEL_TAG="$(echo "${OLLAMA_MODEL_TAG}" | tr -d '[:space:]')"
[[ "${OLLAMA_MODEL_TAG,,}" == "none" || "${OLLAMA_MODEL_TAG,,}" == "skip" ]] && OLLAMA_MODEL_TAG=""
OLLAMA_ALIAS=""
[[ -n "${OLLAMA_MODEL_TAG}" ]] && OLLAMA_ALIAS="$(echo "${OLLAMA_MODEL_TAG}" | tr ':' '-')"
echo

# --- Section 2: Flash-agent model selection --------------------------------
# Build the list of active model aliases from whatever was just configured.
# Ollama first — matches the --restart self-heal priority (it's the only
# provider whose health is actually verified end-to-end, not just "a key was
# typed in").
CONFIGURED_MODELS=()
[[ -n "${OLLAMA_MODEL_TAG}" ]] && CONFIGURED_MODELS+=("${OLLAMA_ALIAS}")
[[ -n "$AZ_KEY" ]] && CONFIGURED_MODELS+=("${AZ_ALIAS:-gpt-4o}")
[[ -n "$GEMINI_KEY" ]] && CONFIGURED_MODELS+=("gemini-3-flash" "gemini-2.5-flash" "gemini-2.5-flash-lite")
[[ -n "$OPENROUTER_KEY" ]] && CONFIGURED_MODELS+=("auto-free")

echo -e "${BOLD}2) Flash-agent model${NC} ${DIM}(which LiteLLM alias the agent will request)${NC}"
if [[ ${#CONFIGURED_MODELS[@]} -gt 0 ]]; then
    echo -e "   ${DIM}Configured: ${CONFIGURED_MODELS[*]}${NC}"
    DEFAULT_FLASH="${CONFIGURED_MODELS[0]}"
else
    warn "   No providers configured — flash-agent won't be able to make LLM calls. Re-run to add one."
    DEFAULT_FLASH="$(cur FLASH_AGENT_MODEL)"; DEFAULT_FLASH="${DEFAULT_FLASH:-gpt-4o}"
fi
# NOTE: deliberately not using ask() here — ask() defaults to whatever
# FLASH_AGENT_MODEL already is in .env, which silently overrides DEFAULT_FLASH
# (the alias actually backed by a configured provider this run) and lets a
# stale/broken choice (e.g. "gpt-4o" from a long-abandoned Azure attempt)
# stick forever across every future run, even after switching providers.
read -rp "$(echo -e "  ${BOLD}Flash-agent model alias${NC} ${DIM}[${DEFAULT_FLASH}]${NC}: ")" FLASH_MODEL
FLASH_MODEL="$(echo "${FLASH_MODEL:-${DEFAULT_FLASH}}" | tr -d '[:space:]')"
echo

# --- OPTIONAL: cluster + infra modes ---------------------------------------
echo -e "${BOLD}3) How should Kubernetes be sourced?${NC} ${DIM}(Enter = auto)${NC}"
echo -e "   ${DIM}auto=reuse/create kind  local=existing cluster  cloud=AKS/EKS/GKE  fresh=new kind${NC}"
CLUSTER_MODE="$(ask CLUSTER_MODE 'CLUSTER_MODE (auto/local/cloud/fresh)')"
CLUSTER_MODE="${CLUSTER_MODE:-auto}"
echo

# --- Corporate proxy CA certificate ----------------------------------------
echo -e "${BOLD}4) Corporate proxy CA certificate${NC} ${DIM}(needed for git clone inside containers on proxy networks)${NC}"
echo -e "   ${DIM}Leave blank to use the host system bundle (/etc/ssl/certs/ca-certificates.crt).${NC}"
CUSTOM_CA_CERT_PATH="$(ask CUSTOM_CA_CERT_PATH 'Path to root CA cert file (.pem/.crt, Enter to skip)')"
CUSTOM_CA_CERT_PATH="$(echo "${CUSTOM_CA_CERT_PATH}" | tr -d '[:space:]')"
if [[ -n "${CUSTOM_CA_CERT_PATH}" && ! -f "${CUSTOM_CA_CERT_PATH}" ]]; then
    warn "File not found: ${CUSTOM_CA_CERT_PATH} — will fall back to host bundle at deploy time."
    CUSTOM_CA_CERT_PATH=""
fi
echo

fi # EXPRESS_MODE -eq 0 (sections 1-4)

# The kind docker-network gateway is the address in-cluster pods use to reach
# host services. Its subnet is assigned PER-BOX (NOT always 172.26.0.1 — it
# depends on how many docker networks already exist), so detect it rather than
# hardcoding. Empty if the kind network doesn't exist yet (fresh VM); we
# re-detect after bring-up below.
detect_kind_gw() {
    docker network inspect kind \
        -f '{{range .IPAM.Config}}{{.Gateway}}
{{end}}' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.' | head -1
}

# k3s uses a CNI bridge (cni0) whose host-side IP is the gateway pods use to
# reach host services. Detect it from the cni0 interface so the IP is derived
# from the actual environment rather than hardcoded.
detect_k3s_gw() {
    ip addr show cni0 2>/dev/null \
        | awk '/inet / {split($2,a,"/"); print a[1]; exit}'
}

if [[ "${CLUSTER_MODE}" == "cloud" ]]; then
    # Cloud clusters have no kind network; SUBSCRIBER_CALLBACK_URL/SERVER_ADDR will be
    # set to K8s service DNS by k8s_env_patch, and PORTAL_ENDPOINT to the LB IP by
    # post_cloud_setup. A placeholder is written for now and overwritten at deploy time.
    CALLBACK_HOST=""
    echo -e "${DIM}Cloud mode — skipping kind gateway detection; endpoints will be resolved at deploy time.${NC}"
else
    # Try k3s first (cni0 bridge); fall back to KIND docker network.
    CALLBACK_HOST="$(detect_k3s_gw || true)"
    if [[ -n "${CALLBACK_HOST}" ]]; then
        echo -e "${DIM}Detected k3s CNI gateway for pod->host callbacks: ${CALLBACK_HOST}${NC}"
    else
        CALLBACK_HOST="$(detect_kind_gw || true)"
        if [[ -n "${CALLBACK_HOST}" ]]; then
            echo -e "${DIM}Detected kind gateway for pod->host callbacks: ${CALLBACK_HOST}${NC}"
        else
            CALLBACK_HOST="172.26.0.1"
            warn "No kind/k3s gateway found — using ${CALLBACK_HOST} as fallback; re-run after cluster is up."
        fi
    fi
fi
echo

# --- write values (robust; values can contain / and special chars) ---------
export _AZ_KEY="$AZ_KEY" _AZ_ENDPOINT="$AZ_ENDPOINT" _AZ_DEPLOY="$AZ_DEPLOY" \
       _AZ_DEPLOY_GPT5="$AZ_DEPLOY_GPT5" _AZ_DEPLOY_EMBED="$AZ_DEPLOY_EMBED" \
       _AZ_ALIAS="$AZ_ALIAS" _AZ_APIVER="$AZ_APIVER" \
       _GEMINI_KEY="$GEMINI_KEY" _OPENROUTER_KEY="$OPENROUTER_KEY" \
       _OLLAMA_MODEL_TAG="${OLLAMA_MODEL_TAG:-}" _OLLAMA_ALIAS="${OLLAMA_ALIAS:-}" \
       _CLUSTER_MODE="$CLUSTER_MODE" _CALLBACK_HOST="$CALLBACK_HOST" \
       _FLASH_MODEL="$FLASH_MODEL" _DH_USER="$DH_USER" _DH_TOKEN="$DH_TOKEN" \
       _CUSTOM_CA_CERT_PATH="${CUSTOM_CA_CERT_PATH:-}" \
       _INSTALL_APP_SRC="${_INSTALL_APP_SRC:-}" _INSTALL_AGENT_SRC="${_INSTALL_AGENT_SRC:-}" \
       _LITMUS_SRC="${_LITMUS_SRC:-}" \
       _JFROG_HOST="${_JFROG_HOST:-}" _JFROG_PATH="${_JFROG_PATH:-}" \
       _JFROG_USER="${_JFROG_USER:-}" _JFROG_TOKEN="${_JFROG_TOKEN:-}"
python3 - "${ENV_FILE}" <<'PY'
import os, sys, re
path = sys.argv[1]
cm   = os.environ["_CLUSTER_MODE"]

sets = {"CLUSTER_MODE": cm}

# ── Azure OpenAI ──────────────────────────────────────────────────────────────
key         = os.environ.get("_AZ_KEY", "")
ep          = os.environ.get("_AZ_ENDPOINT", "")
dep         = os.environ.get("_AZ_DEPLOY", "")
dep_gpt5    = os.environ.get("_AZ_DEPLOY_GPT5", "") or dep   # falls back to standard if not set
dep_embed   = os.environ.get("_AZ_DEPLOY_EMBED", "")
az_alias    = os.environ.get("_AZ_ALIAS", "")
ver         = os.environ.get("_AZ_APIVER", "")
if key:
    # Fan the same key/endpoint to all Azure consumers — certifier standard, reasoning, embedding.
    for k in ("AZURE_OPENAI_KEY","AZURE_OPENAI_API_KEY","AZURE_OPENAI_GPT5_API_KEY","AZURE_EMBEDDING_API_KEY"):
        sets[k] = key
if ep:
    for k in ("AZURE_OPENAI_ENDPOINT","AZURE_OPENAI_GPT5_ENDPOINT","AZURE_EMBEDDING_ENDPOINT"):
        sets[k] = ep
if dep:
    # Certifier standard model (gpt-4o in configs.json) — actual Azure deployment name.
    sets["AZURE_OPENAI_CHAT_DEPLOYMENT_NAME"] = dep
    # LiteLLM backend: full "azure/<deployment>" string for litellm_config.yaml.
    sets["LITELLM_AZURE_CHAT_MODEL"] = f"azure/{dep}"
if dep_gpt5:
    # Certifier reasoning model (gpt-5.2 in configs.json) — may differ from standard.
    sets["AZURE_OPENAI_GPT5_CHAT_DEPLOYMENT_NAME"] = dep_gpt5
if dep_embed:
    # Certifier embedding model — only set if user provided a deployment.
    sets["AZURE_EMBEDDING_MODEL"] = dep_embed
if az_alias:
    # LiteLLM model_name for the Azure entry (litellm_config.yaml reads via os.environ).
    sets["AZURE_OPENAI_DEPLOYMENT"] = az_alias
if ver:
    for k in ("AZURE_OPENAI_API_VERSION", "AZURE_OPENAI_GPT5_API_VERSION"):
        sets[k] = ver

# ── Gemini ────────────────────────────────────────────────────────────────────
gemini_key = os.environ.get("_GEMINI_KEY", "")
if gemini_key:
    sets["GEMINI_API_KEY"] = gemini_key

# ── OpenRouter ────────────────────────────────────────────────────────────────
openrouter_key = os.environ.get("_OPENROUTER_KEY", "")
if openrouter_key:
    sets["OPENROUTER_API_KEY"] = openrouter_key

# ── Flash-agent model alias ───────────────────────────────────────────────────
flash_model = os.environ.get("_FLASH_MODEL", "")
if flash_model:
    sets["FLASH_AGENT_MODEL"] = flash_model

# ── Ollama model ──────────────────────────────────────────────────────────────
ollama_model = os.environ.get("_OLLAMA_MODEL_TAG", "")
if ollama_model:
    sets["OLLAMA_MODEL"] = ollama_model
    # Set sensible defaults for OLLAMA_BASE_URL and OPENAI_COMPATIBLE_BASE_URL
    # if not already in .env. Both use the UID-derived OLLAMA_PORT (written to
    # .env by the backfill block earlier in this script) so they reach THIS
    # checkout's ACE-owned Ollama container, not the system Ollama on :11434.
    # k8s_env_patch overwrites both with in-cluster Service names at K8s deploy.
    cur_lines = open(path).read()
    m = re.search(r'^OLLAMA_PORT=(\d+)', cur_lines, re.MULTILINE)
    ollama_port = m.group(1) if m else "11434"
    if "OLLAMA_BASE_URL=" not in cur_lines:
        sets.setdefault("OLLAMA_BASE_URL", f"http://host.docker.internal:{ollama_port}")
    if "OPENAI_COMPATIBLE_BASE_URL=" not in cur_lines:
        sets.setdefault("OPENAI_COMPATIBLE_BASE_URL", f"http://host.docker.internal:{ollama_port}/v1")

# ── Docker Hub ────────────────────────────────────────────────────────────────
dh_user = os.environ.get("_DH_USER", "")
dh_token = os.environ.get("_DH_TOKEN", "")
if dh_user:
    sets["DOCKERHUB_USERNAME"] = dh_user
if dh_token:
    sets["DOCKERHUB_TOKEN"] = dh_token

# ── Corporate proxy CA cert path ─────────────────────────────────────────────
custom_ca = os.environ.get("_CUSTOM_CA_CERT_PATH", "")
if custom_ca:
    sets["CUSTOM_CA_CERT_PATH"] = custom_ca

# ── Experiment image sources ──────────────────────────────────────────────────
# Only update when the wizard ran (SETUP_MODE=setup); in --restart mode all three
# source vars are empty strings and we leave .env unchanged.
app_src    = os.environ.get("_INSTALL_APP_SRC",   "")
agent_src  = os.environ.get("_INSTALL_AGENT_SRC", "")
litmus_src = os.environ.get("_LITMUS_SRC",        "")
jfrog_host = os.environ.get("_JFROG_HOST", "") or "infyartifactory.jfrog.io"
jfrog_path = os.environ.get("_JFROG_PATH", "") or "docker-local"
jfrog_user = os.environ.get("_JFROG_USER",  "")
jfrog_tok  = os.environ.get("_JFROG_TOKEN", "")

if app_src:
    sets["INSTALL_APP_IMAGE_SOURCE"] = app_src
    if app_src == "jfrog":
        sets["INSTALL_APPLICATION_IMAGE"]             = f"{jfrog_host}/{jfrog_path}/agentcert/agentcert-install-app:latest"
        sets["INSTALL_APPLICATION_IMAGE_PULL_POLICY"] = "Always"
    else:
        # Both "local" and "dockerhub" use the same Docker Hub image name.
        # For "local", prepare-images.sh builds and kind-loads it under that name.
        # IfNotPresent means KinD uses the pre-loaded copy when available.
        sets["INSTALL_APPLICATION_IMAGE"]             = "agentcert/agentcert-install-app:latest"
        sets["INSTALL_APPLICATION_IMAGE_PULL_POLICY"] = "IfNotPresent"

if agent_src:
    sets["INSTALL_AGENT_IMAGE_SOURCE"] = agent_src
    if agent_src == "jfrog":
        sets["INSTALL_AGENT_IMAGE"]             = f"{jfrog_host}/{jfrog_path}/agentcert/agentcert-install-agent:latest"
        sets["INSTALL_AGENT_IMAGE_PULL_POLICY"] = "Always"
    else:
        sets["INSTALL_AGENT_IMAGE"]             = "agentcert/agentcert-install-agent:latest"
        sets["INSTALL_AGENT_IMAGE_PULL_POLICY"] = "IfNotPresent"

if litmus_src:
    sets["LITMUS_IMAGES_SOURCE"] = litmus_src
    if litmus_src == "jfrog":
        # GraphQL server will rewrite all litmus helper image refs to JFrog URLs at
        # workflow submission time (applyLitmusHelperImageOverrides).
        sets["LITMUS_HELPER_IMAGES_REGISTRY_PREFIX"] = f"{jfrog_host}/{jfrog_path}/"
        sets["LITMUS_HELPER_IMAGES_PULL_POLICY"]     = "Always"
    elif litmus_src == "local":
        # Images are pre-loaded into KinD under their Docker Hub names; IfNotPresent
        # means the node uses the cached copy and never contacts the registry.
        # docker.io prefix normalises any registry prefix in the source YAML
        # (JFrog, Scarf, bare Docker Hub) to a canonical docker.io/ ref so the
        # lookup always hits the KinD image cache regardless of what branch the
        # ChaosHub is cloned from.
        sets["LITMUS_HELPER_IMAGES_REGISTRY_PREFIX"] = "docker.io"
        sets["LITMUS_HELPER_IMAGES_PULL_POLICY"]     = "IfNotPresent"
    else:  # dockerhub
        # Normalise to explicit docker.io prefix so the pull always goes to
        # Docker Hub even when the source YAML carries a different registry.
        sets["LITMUS_HELPER_IMAGES_REGISTRY_PREFIX"] = "docker.io"
        sets["LITMUS_HELPER_IMAGES_PULL_POLICY"]     = "Always"

if jfrog_user:  sets["JFROG_USER"]          = jfrog_user
if jfrog_tok:   sets["JFROG_TOKEN"]         = jfrog_tok
if app_src == "jfrog" or agent_src == "jfrog":
    sets["JFROG_HOST"]          = jfrog_host
    sets["JFROG_REGISTRY_PATH"] = jfrog_path

# Network endpoints in-cluster pods use to reach the control plane on this host
# (so SUBSCRIBER_CALLBACK_URL is never left as the YOUR_HOST_LAN_IP placeholder).
cb = os.environ.get("_CALLBACK_HOST", "")
if cb:
    sets["SUBSCRIBER_CALLBACK_URL"] = f"http://{cb}:8081"
    sets["SERVER_ADDR"]             = f"http://{cb}:8081/query"
    sets["PORTAL_ENDPOINT"]         = f"http://{cb}:8081"
    # The chaos/flash agent runs INSIDE the cluster, so it reaches the host's
    # LiteLLM gateway and Langfuse via the same pod->host gateway IP.
    sets["LITELLM_HOST"]            = f"http://{cb}:14000"
    sets["LANGFUSE_HOST"]           = f"http://{cb}:4000"

# WebSocket origin allow-list (graphql checks the subscriber's Host against this).
# Must include the host IP in-cluster pods connect from — kind gateway (172.*),
# pod CIDR (10.*), LAN (192.168.*). Otherwise the subscriber gets "websocket: bad handshake".
host_alt = ("|" + re.escape(cb)) if cb else ""
sets["ALLOWED_ORIGINS"] = (
    r"^(http://|https://|)((localhost|host\.docker\.internal|host\.minikube\.internal|[a-z0-9.-]+\.svc\.cluster\.local)"
    r"|172\.[0-9]+\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+"
    + host_alt + r")(:[0-9]+|)$"
)

lines = open(path).read().splitlines()
seen = set()
for i, ln in enumerate(lines):
    m = re.match(r'^([A-Z0-9_]+)=', ln)
    if m and m.group(1) in sets:
        k = m.group(1)
        lines[i] = f"{k}={sets[k]}"
        seen.add(k)
# append any keys that weren't present
for k, v in sets.items():
    if k not in seen:
        lines.append(f"{k}={v}")
open(path, "w").write("\n".join(lines) + "\n")
PY

ok "Wrote LiteLLM model config, flash-agent model, and CLUSTER_MODE=${CLUSTER_MODE} to .env"

# --- patch litellm_config.yaml with the chosen Ollama model -----------------
if [[ -n "${OLLAMA_MODEL_TAG:-}" ]]; then
    _litellm_cfg="${REPO_ROOT}/agentcert-stack/litellm-setup/litellm_config.yaml"
    if [[ -f "${_litellm_cfg}" ]]; then
        python3 - "${_litellm_cfg}" <<'PY'
import sys, re, os
path  = sys.argv[1]
tag   = os.environ["_OLLAMA_MODEL_TAG"]   # e.g. qwen2.5:32b-instruct
alias = os.environ["_OLLAMA_ALIAS"]        # e.g. qwen2.5-32b-instruct
content = open(path).read()
# Replace the Ollama entry's model_name alias and ollama_chat model tag.
content = re.sub(
    r'(  - model_name: )[\w.\-:]+(\n    litellm_params:\n      model: ollama_chat/)[\w.\-:]+',
    lambda m: m.group(1) + alias + m.group(2) + tag,
    content,
)
open(path, "w").write(content)
PY
        ok "litellm_config.yaml → Ollama model: ${OLLAMA_MODEL_TAG}  (alias: ${OLLAMA_ALIAS})"
    else
        warn "litellm_config.yaml not found — run: git submodule update --init agentcert-stack"
    fi
fi

# --- summary + sanity -------------------------------------------------------
echo
echo -e "${CYAN}-------------------------------------------------------${NC}"
if [[ -n "$AZ_KEY" ]]; then
    ok "Azure OpenAI"
    echo -e "   LiteLLM alias   : ${BOLD}${AZ_ALIAS}${NC}  →  deployment ${BOLD}${AZ_DEPLOY}${NC}"
    echo -e "   Certifier std   : ${BOLD}${AZ_DEPLOY}${NC}"
    echo -e "   Certifier reason: ${BOLD}${AZ_DEPLOY_GPT5:-${AZ_DEPLOY}}${NC}"
    [[ -n "$AZ_DEPLOY_EMBED" ]] && echo -e "   Certifier embed : ${BOLD}${AZ_DEPLOY_EMBED}${NC}" \
                                || echo -e "   Certifier embed : ${DIM}(skipped)${NC}"
fi
if [[ -n "$GEMINI_KEY" ]]; then
    ok "Gemini         gemini-3-flash  gemini-2.5-flash  gemini-2.5-flash-lite"
fi
if [[ -n "$OPENROUTER_KEY" ]]; then
    ok "OpenRouter     auto-free"
fi
if [[ -n "${OLLAMA_MODEL_TAG:-}" ]]; then
    ok "Ollama         ${OLLAMA_ALIAS}  (model: ${OLLAMA_MODEL_TAG})"
fi
if [[ -z "$AZ_KEY" && -z "$GEMINI_KEY" && -z "$OPENROUTER_KEY" && -z "${OLLAMA_MODEL_TAG:-}" ]]; then
    warn "No LLM providers configured — agents won't be able to make LLM calls (re-run to add one)."
fi
echo -e "  Flash-agent model : ${BOLD}${FLASH_MODEL}${NC}"
echo -e "  Cluster mode      : ${BOLD}${CLUSTER_MODE}${NC}"
echo -e "  Infra             : MongoDB + Langfuse + LiteLLM run locally ${DIM}(defaults; edit .env to change)${NC}"
echo -e "${CYAN}-------------------------------------------------------${NC}"
echo
echo -e "Next:  ${BOLD}./scripts/setup.sh${NC} then answer Y to deploy, or run ${BOLD}kubectl get pods -n ace${NC}"
echo -e "       Re-deploy without re-entering values: ${BOLD}./scripts/setup.sh --restart${NC}"
echo -e "Docs:  ${DIM}docs/setup/  ·  configuration & ports: docs/setup/configuration.md${NC}"
echo

fi  # end SETUP_MODE=setup

# --- Ensure this checkout's Ollama container is actually running, and pull ---
# the configured model into it. Runs unconditionally (both --setup and
# --restart): OLLAMA_MODEL_TAG is only populated by the interactive prompts in
# --setup mode, so fall back to whatever is already recorded in .env for
# --restart. This used to just check for a system-wide `ollama` CLI and run
# `ollama pull` against WHATEVER daemon that CLI happened to reach — not
# necessarily this checkout's instance-scoped container (ollama-<ACE_INSTANCE_
# NAME>, port $OLLAMA_PORT). On a host with no system Ollama installed (the
# common case for a fresh host), that check silently no-opped: OLLAMA_MODEL
# ended up configured end-to-end (litellm-config, K8s Service) with nothing
# actually listening behind it. Delegate the container lifecycle to
# start-local-services.sh, which already has the ownership-guarded
# create/start logic for this exact container, then pull directly into it.
_ollama_tag_final="${OLLAMA_MODEL_TAG:-$(cur OLLAMA_MODEL)}"
_OLLAMA_PULL_PID=""
_OLLAMA_PULL_LOG=""
_OLLAMA_PULL_RETRY_CMD=""
if [[ -n "${_ollama_tag_final}" ]]; then
    _ollama_container="ollama-$(cur ACE_INSTANCE_NAME)"
    echo
    echo -e "${DIM}Ensuring this checkout's Ollama container ('${_ollama_container}') is up …${NC}"
    if "${SCRIPT_DIR}/start-local-services.sh" --only-ollama --env-file "${ENV_FILE}"; then
        # Container is up — pull the model in the background so the rest of
        # setup (K8s deploy, image builds) can proceed concurrently. The pull
        # has no data dependency on anything that follows: K8s/Helm only needs
        # the URL + alias (already in .env), and Docker builds are independent.
        _OLLAMA_PULL_LOG="${REPO_ROOT}/.tmp/ollama-pull.log"
        _OLLAMA_PULL_RETRY_CMD="docker exec ${_ollama_container} ollama pull ${_ollama_tag_final}"
        mkdir -p "${REPO_ROOT}/.tmp"
        echo -e "${DIM}Pulling '${_ollama_tag_final}' into '${_ollama_container}' in the background — setup continues …${NC}"
        echo -e "${DIM}  Progress: tail -f ${_OLLAMA_PULL_LOG}${NC}"
        ( docker exec "${_ollama_container}" ollama pull "${_ollama_tag_final}" ) \
            >"${_OLLAMA_PULL_LOG}" 2>&1 &
        _OLLAMA_PULL_PID=$!
    else
        warn "Could not bring up ${_ollama_container} — flash-agent's Ollama route will not work until this is resolved."
        warn "Retry with: ./scripts/start-local-services.sh --only-ollama"
    fi
    unset _ollama_container
fi
unset _ollama_tag_final

# --- K8s deployment helpers -------------------------------------------------

# dedup_env PATH — deduplicate .env in-place, keeping the LAST value for each
# key. Blank lines and comments are preserved; only duplicate KEY= lines are
# collapsed. This prevents `kubectl create secret --from-env-file` from failing
# with "another key by that name already exists".
dedup_env() {
    python3 - "$1" <<'PY'
import sys, re
path = sys.argv[1]
lines = open(path).read().splitlines()
# Two-pass: first collect last-seen index for each key
last = {}
for i, ln in enumerate(lines):
    m = re.match(r'^([A-Za-z0-9_.]+)=', ln)
    if m:
        last[m.group(1)] = i
out = []
for i, ln in enumerate(lines):
    m = re.match(r'^([A-Za-z0-9_.]+)=', ln)
    if m and last[m.group(1)] != i:
        continue  # drop earlier duplicate
    out.append(ln)
open(path, "w").write("\n".join(out) + "\n")
PY
}

# set_env KEY VALUE — set or replace a key in .env
set_env() {
    local k="$1" v="$2"
    if grep -qE "^${k}=" "${ENV_FILE}"; then
        python3 - "${ENV_FILE}" "$k" "$v" <<'PY'
import sys, re
path, k, v = sys.argv[1:4]
ls = open(path).read().splitlines()
for i, l in enumerate(ls):
    if re.match(rf'^{re.escape(k)}=', l):
        ls[i] = f"{k}={v}"
open(path, "w").write("\n".join(ls) + "\n")
PY
    else
        printf '%s=%s\n' "$k" "$v" >> "${ENV_FILE}"
    fi
}

# pick_kind_hostport VAR_NAME PREFERRED_DEFAULT
# Resolves a KinD hostPort to a value that is free on this host right now.
# Precedence: existing .env value → preferred default → walk forward.
# Skips ports already claimed in the current setup pass (_KIND_CLAIMED_PORTS).
# Persists the chosen port to .env (adds if absent; updates only if changed).
# Logs a warning when the preferred port was already in use.
# Result is written to _HP_RESULT (not stdout) so callers do NOT use $() —
# that would create a subshell and break the _KIND_CLAIMED_PORTS side-effect.
pick_kind_hostport() {
    local var="$1" preferred="$2"
    local current; current="$(cur "$var")"
    local candidate="${current:-$preferred}"

    local checked=0
    while true; do
        if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ":${candidate}$"; then
            : # port bound on the host
        elif echo " ${_KIND_CLAIMED_PORTS} " | grep -q " ${candidate} "; then
            : # already assigned to another service in this setup pass
        else
            break
        fi
        candidate=$(( candidate + 1 ))
        checked=$(( checked + 1 ))
        if (( checked >= 200 )); then
            echo "ERROR: could not find a free host port for ${var} after 200 attempts." >&2
            echo "ERROR: Set ${var} manually in .env to a free port, then re-run." >&2
            exit 1
        fi
    done

    if [[ -z "$current" ]] || [[ "$candidate" != "$current" ]]; then
        set_env "$var" "$candidate"
        if [[ "$candidate" != "${current:-$preferred}" ]]; then
            warn "  ${var}: ${current:-$preferred} in use — assigned ${candidate} (saved to .env)"
        fi
    fi
    _KIND_CLAIMED_PORTS="${_KIND_CLAIMED_PORTS} ${candidate}"
    _HP_RESULT="$candidate"
}

# apply_ace_env_secret — dedup .env then create/update the ace-env Secret
apply_ace_env_secret() {
    local ns="${1:-ace}"
    dedup_env "${ENV_FILE}"
    kubectl create secret generic ace-env \
        --namespace "${ns}" \
        --from-env-file="${ENV_FILE}" \
        --dry-run=client -o yaml \
        | kubectl apply -f - >/dev/null
    ok "ace-env Secret up to date."
}

# create_ca_configmap — create/update ace-ca-certs ConfigMap from local cert bundle.
# If CUSTOM_CA_CERT_PATH is set in .env, uses that file; else falls back to the
# host system bundle. The ConfigMap is mounted into the graphql clone-charts
# initContainer so git clone works behind a corporate proxy.
create_ca_configmap() {
    local ns="${1:-ace}"
    local custom_ca
    custom_ca="$(grep -m1 '^CUSTOM_CA_CERT_PATH=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
    local ca_src
    if [[ -n "${custom_ca}" && -f "${custom_ca}" ]]; then
        ca_src="${custom_ca}"
        ok "Using custom CA cert: ${ca_src}"
    elif [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
        ca_src="/etc/ssl/certs/ca-certificates.crt"
    else
        warn "No CA cert bundle found — git clone may fail in proxy environments."
        return 0
    fi
    kubectl create configmap ace-ca-certs \
        --namespace "${ns}" \
        --from-file=ca-certificates.crt="${ca_src}" \
        --dry-run=client -o yaml \
        | kubectl apply -f - >/dev/null
    ok "ace-ca-certs ConfigMap up to date (${ca_src})."
}

# post_cloud_setup — after a cloud deployment, poll for the web service LoadBalancer
# IP/hostname. The web pod's nginx is the only external entry point: browsers hit
# <web-lb>:2001, nginx proxies /api/ → graphql:8081 and /auth/ → auth:3000 via
# K8s service DNS. Graphql never needs to be externally reachable.
#
# What this function does:
#   1. Polls the web service LB until it gets an IP/hostname.
#   2. Adds it to ALLOWED_ORIGINS so graphql accepts the browser Origin header
#      that nginx forwards through (Origin: http://<web-lb>:2001).
#   3. Re-applies the ace-env Secret and restarts graphql to pick up the new regex.
post_cloud_setup() {
    local ns="${1:-ace}"
    echo
    echo -e "${DIM}Cloud mode: polling web LoadBalancer for external IP/hostname (up to 5 min)…${NC}"
    local lb_ip="" attempts=0
    while [[ -z "${lb_ip}" && ${attempts} -lt 60 ]]; do
        lb_ip="$(kubectl get svc web -n "${ns}" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
        if [[ -z "${lb_ip}" ]]; then
            lb_ip="$(kubectl get svc web -n "${ns}" \
                -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
        fi
        if [[ -z "${lb_ip}" ]]; then sleep 5; (( attempts++ )); fi
    done
    if [[ -z "${lb_ip}" ]]; then
        warn "Web LoadBalancer IP/hostname not yet assigned. Add it to ALLOWED_ORIGINS in .env, then re-run:"
        warn "  ALLOWED_ORIGINS=<existing-value>|^(http://|https://|)<lb-ip>(:[0-9]+)?\$"
        warn "  Then: ./scripts/setup.sh --restart"
        return 0
    fi
    ok "web LoadBalancer: ${lb_ip}"
    # Extend ALLOWED_ORIGINS so graphql accepts WebSocket upgrade requests that nginx
    # forwards with the browser's original Origin: http://<web-lb>:2001 header.
    local cur_origins
    cur_origins="$(grep -m1 '^ALLOWED_ORIGINS=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
    local escaped_lb
    escaped_lb="$(python3 -c "import re,sys; print(re.escape(sys.argv[1]))" "${lb_ip}")"
    if [[ -n "${cur_origins}" ]] && ! echo "${cur_origins}" | grep -qF "${lb_ip}"; then
        set_env ALLOWED_ORIGINS "${cur_origins}|^(http://|https://|)${escaped_lb}(:[0-9]+)?\$"
    fi
    apply_ace_env_secret "${ns}"
    # Restart graphql so it reloads ALLOWED_ORIGINS from the updated secret
    kubectl rollout restart deployment/graphql -n "${ns}" >/dev/null 2>&1 || true
    ok "Updated ALLOWED_ORIGINS and restarted graphql."
    echo -e "  ${BOLD}AgentCert UI${NC}  http://${lb_ip}:2001"
}

# Patch .env so in-cluster pods use K8s service DNS names instead of host IPs.
# This must run before the Secret is created from .env.
k8s_env_patch() {
    local mn_user mn_pass mn_db
    mn_user="$(grep -m1 '^MONGODB_USERNAME=' "${ENV_FILE}" | cut -d= -f2- || echo admin)"
    mn_pass="$(grep -m1 '^MONGODB_PASSWORD=' "${ENV_FILE}" | cut -d= -f2- || echo 1234)"
    mn_db="$(grep  -m1 '^MONGODB_DATABASE=' "${ENV_FILE}" | cut -d= -f2- || echo agentcert)"

    # MongoDB: replace host IP with K8s service name; keep directConnection=true
    set_env DB_SERVER \
        "mongodb://${mn_user}:${mn_pass}@mongodb:27017/?replicaSet=rs0&authSource=admin"
    set_env MONGODB_CONNECTION_STRING \
        "mongodb://${mn_user}:${mn_pass}@mongodb:27017/${mn_db}?authSource=admin&directConnection=true"
    set_env CERTIFIER_MONGODB_URI \
        "mongodb://${mn_user}:${mn_pass}@mongodb:27017/${mn_db}?authSource=admin&directConnection=true"

    # In-cluster agents call back to graphql via the K8s service
    set_env SUBSCRIBER_CALLBACK_URL "http://graphql.ace.svc.cluster.local:8081"
    set_env SERVER_ADDR             "http://graphql.ace.svc.cluster.local:8081/query"
    set_env PORTAL_ENDPOINT         "http://graphql.ace.svc.cluster.local:8081"

    # Auth gRPC: graphql talks to auth by service name, not localhost
    set_env LITMUS_AUTH_GRPC_ENDPOINT "auth"

    # LiteLLM: in-cluster pods reach it by service name (container port 4000,
    # but the K8s service exposes port 14000 → targetPort 4000)
    set_env LITELLM_HOST "http://litellm:14000"

    # Langfuse: certifier/litellm reach it by service name (container port 3000)
    set_env LANGFUSE_HOST         "http://langfuse-web:3000"
    set_env LANGFUSE_HOST_COMPOSE "http://langfuse-web:3000"

    # Certifier: graphql calls back to certifier by service name
    set_env CERTIFIER_BASE_URL       "http://certifier:8000"
    set_env CERTIFICATE_PDF_BASE_URL "http://certifier:8000"

    # Ollama: in-cluster pods reach the host Ollama server via the ollama Service
    # created by helm_deploy (selector-less Service + manual Endpoints → host gateway IP).
    set_env OLLAMA_BASE_URL           "http://ollama.ace.svc.cluster.local:11434"
    # Certifier's direct OpenAI-compatible connection bypasses LiteLLM — wire it
    # to the same in-cluster Service so it reaches the right Ollama instance.
    set_env OPENAI_COMPATIBLE_BASE_URL "http://ollama.ace.svc.cluster.local:11434/v1"

    # Postgres (Langfuse): default dev credentials
    set_env POSTGRES_USER     "postgres"
    set_env POSTGRES_PASSWORD "postgres"
    set_env POSTGRES_DB       "postgres"

    # ClickHouse (Langfuse): default dev credentials
    set_env CLICKHOUSE_USER     "default"
    set_env CLICKHOUSE_PASSWORD "clickhouse"

    # Redis (Langfuse): must match --requirepass arg on the redis server
    set_env REDIS_AUTH "myredissecret"

    # Langfuse web (Next.js Auth)
    set_env NEXTAUTH_URL    "http://localhost:4000"
    set_env NEXTAUTH_SECRET "mysecret"
    set_env SALT            "mysalt"
    set_env ENCRYPTION_KEY  "0000000000000000000000000000000000000000000000000000000000000000"

    # MinIO (Langfuse S3 storage)
    set_env MINIO_ROOT_USER     "minio"
    set_env MINIO_ROOT_PASSWORD "miniosecret"
    set_env LANGFUSE_S3_EVENT_UPLOAD_BUCKET             "langfuse"
    set_env LANGFUSE_S3_EVENT_UPLOAD_REGION             "auto"
    set_env LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID      "minio"
    set_env LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY  "miniosecret"
    set_env LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE   "true"
    set_env LANGFUSE_S3_EVENT_UPLOAD_PREFIX             "events/"
    set_env LANGFUSE_S3_MEDIA_UPLOAD_BUCKET             "langfuse"
    set_env LANGFUSE_S3_MEDIA_UPLOAD_REGION             "auto"
    set_env LANGFUSE_S3_MEDIA_UPLOAD_ACCESS_KEY_ID      "minio"
    set_env LANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY  "miniosecret"
    set_env LANGFUSE_S3_MEDIA_UPLOAD_FORCE_PATH_STYLE   "true"
    set_env LANGFUSE_S3_MEDIA_UPLOAD_PREFIX             "media/"
    set_env LANGFUSE_S3_BATCH_EXPORT_ENABLED            "false"
    set_env LANGFUSE_S3_BATCH_EXPORT_BUCKET             "langfuse"
    set_env LANGFUSE_S3_BATCH_EXPORT_REGION             "auto"
    set_env LANGFUSE_S3_BATCH_EXPORT_ACCESS_KEY_ID      "minio"
    set_env LANGFUSE_S3_BATCH_EXPORT_SECRET_ACCESS_KEY  "miniosecret"
    set_env LANGFUSE_S3_BATCH_EXPORT_FORCE_PATH_STYLE   "true"
    set_env LANGFUSE_S3_BATCH_EXPORT_PREFIX             "exports/"

    ok "Patched .env with K8s service DNS names."
}

# Ownership marker for a kind cluster THIS checkout created: a docker volume
# labelled with this checkout's REPO_ROOT. A kind cluster (like a docker
# container name) is a host-wide unique resource, not scoped to a checkout or
# user -- two engineers' checkouts on the same shared host can both default
# to a cluster named "agentcert". Before this script reuses, restarts, or
# deletes a cluster by name, it refuses unless this marker proves THIS
# checkout created it. This is the kind-cluster equivalent of
# assert_not_foreign_container() in scripts/start-local-services.sh -- see
# CLAUDE.md section 0 for the incident that safety net was built to prevent.
kind_owner_marker() { echo "ace-kind-owner-$1"; }

assert_kind_cluster_ownership() {
    local cluster_name="$1"
    kind get clusters 2>/dev/null | grep -qx "${cluster_name}" || return 0   # doesn't exist yet -- nothing to protect
    local marker; marker="$(kind_owner_marker "${cluster_name}")"
    if ! docker volume inspect "${marker}" >/dev/null 2>&1; then
        warn "kind cluster '${cluster_name}' exists but has no ACE ownership marker (${marker})."
        warn "It may belong to another checkout or user on this shared host. Refusing to reuse, restart, or delete it."
        warn "Set a unique KIND_CLUSTER_NAME in .env for this checkout, or if you are CERTAIN this cluster is yours, run:"
        warn "  docker volume create --label ace.kind.owner=${REPO_ROOT} ${marker}"
        return 1
    fi
    local owner
    owner="$(docker volume inspect "${marker}" --format '{{index .Labels "ace.kind.owner"}}' 2>/dev/null)"
    if [[ "${owner}" != "${REPO_ROOT}" ]]; then
        warn "kind cluster '${cluster_name}' is owned by a different checkout (working_dir: ${owner:-unknown}, ours: ${REPO_ROOT})."
        warn "Refusing to touch it. Set a unique KIND_CLUSTER_NAME in .env for this checkout."
        return 1
    fi
    return 0
}

mark_kind_cluster_owned()   { docker volume create --label "ace.kind.owner=${REPO_ROOT}" "$(kind_owner_marker "$1")" >/dev/null; }
unmark_kind_cluster_owned() { docker volume rm "$(kind_owner_marker "$1")" >/dev/null 2>&1 || true; }

# Ensure the kind cluster exists and has the port mappings required for the
# K8s deployment. Recreates the cluster if the config has changed.
ensure_kind_cluster() {
    # Precedence matches the rest of this script's env handling: an explicit
    # process env var wins, then the value already in .env, then an
    # instance-scoped default -- NEVER the bare "agentcert" default, since
    # that's exactly the name any other checkout on this host also defaults
    # to (see the ownership check above for what happens if it collides).
    local ace_instance_name
    ace_instance_name="$(cur ACE_INSTANCE_NAME)"
    ace_instance_name="${ace_instance_name:-$(id -un | tr '[:upper:].' '[:lower:]-')}"

    local cluster_name="${KIND_CLUSTER_NAME:-$(cur KIND_CLUSTER_NAME)}"
    cluster_name="${cluster_name:-agentcert-${ace_instance_name}}"

    # Hard stop before touching ANYTHING by this name -- see CLAUDE.md section 0.
    assert_kind_cluster_ownership "${cluster_name}" || return 1

    # --- Early-exit if cluster is already running with ACE port mappings --------
    # Must run BEFORE pick_kind_hostport so we don't walk ports forward past the
    # ports the running cluster has already bound on the host — that causes .env
    # to drift away from the cluster's actual bindings on every --restart.
    #
    # Multi-port canary: ≥3 of the 16 ACE containerPorts must be present in
    # PortBindings. A single-port check (32001/tcp only) is too fragile — it
    # matches any cluster that happens to have something on that NodePort.
    local _inspect_json has_ace_ports
    _inspect_json="$(docker inspect "${cluster_name}-control-plane" 2>/dev/null || true)"
    has_ace_ports="no"
    if [[ -n "${_inspect_json}" ]]; then
        has_ace_ports="$(echo "${_inspect_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data:
    print('no'); sys.exit()
pb = data[0].get('HostConfig', {}).get('PortBindings', {})
ace = {'80/tcp','32001/tcp','32003/tcp','32030/tcp','32081/tcp','32082/tcp',
       '32080/tcp','31400/tcp','32400/tcp','32017/tcp','32090/tcp',
       '31085/tcp','31086/tcp','31090/tcp','31687/tcp','32000/tcp'}
print('yes' if sum(1 for p in ace if p in pb) >= 3 else 'no')
" 2>/dev/null || echo "no")"
    fi

    if [[ "${has_ace_ports}" == "yes" ]]; then
        ok "kind cluster '${cluster_name}' already running — reconciling .env to actual port bindings."
        # Read actual host ports from docker inspect and write them back to .env.
        # Guard: only overwrite a .env value if it is absent OR within ±10 of the
        # actual port (the bounded drift window from pick_kind_hostport walking
        # past a single occupied port). Values outside ±10 are left untouched —
        # they are assumed to be intentional manual overrides (e.g. an SSH-tunnel
        # port or a value set by a different tool).
        export _ACE_INSPECT_JSON="${_inspect_json}"
        python3 - "${ENV_FILE}" <<'PY'
import json, os, re, sys

env_path = sys.argv[1]
data = json.loads(os.environ['_ACE_INSPECT_JSON'])
pb   = data[0].get('HostConfig', {}).get('PortBindings', {})

PORT_MAP = {
    '80/tcp':    ('KIND_HOSTPORT_INGRESS',       8088),
    '32001/tcp': ('KIND_HOSTPORT_WEB',           2001),
    '32003/tcp': ('KIND_HOSTPORT_AUTH_REST',     3005),
    '32030/tcp': ('KIND_HOSTPORT_AUTH_GRPC',     3030),
    '32081/tcp': ('KIND_HOSTPORT_GRAPHQL_REST',  8081),
    '32082/tcp': ('KIND_HOSTPORT_GRAPHQL_GRPC',  8082),
    '32080/tcp': ('KIND_HOSTPORT_CERTIFIER',    18000),
    '31400/tcp': ('KIND_HOSTPORT_LITELLM',      14000),
    '32400/tcp': ('KIND_HOSTPORT_LANGFUSE',      4002),
    '32017/tcp': ('KIND_HOSTPORT_MONGO',        27017),
    '32090/tcp': ('KIND_HOSTPORT_MINIO',        19090),
    '31085/tcp': ('KIND_HOSTPORT_OTEL_PROM_MCP',31085),
    '31086/tcp': ('KIND_HOSTPORT_OTEL_K8S_MCP', 31086),
    '31090/tcp': ('KIND_HOSTPORT_PROMETHEUS',   31090),
    '31687/tcp': ('KIND_HOSTPORT_GRAFANA',      31687),
    '32000/tcp': ('KIND_HOSTPORT_DEX',          32000),
}

lines = open(env_path).read().splitlines()
env = {}
for ln in lines:
    m = re.match(r'^([A-Za-z0-9_]+)=(.*)', ln)
    if m:
        env[m.group(1)] = m.group(2)

updated = {}
for cport, (var, _) in PORT_MAP.items():
    bindings = pb.get(cport)
    if not bindings:
        continue
    actual = int(bindings[0]['HostPort'])
    cur_str = env.get(var, '')
    cur = int(cur_str) if cur_str.isdigit() else None
    # Only reconcile if: no .env value yet, or within the ±10 drift window.
    if cur is None or abs(actual - cur) <= 10:
        if cur != actual:
            updated[var] = str(actual)

if updated:
    out, seen = [], set()
    for ln in lines:
        m = re.match(r'^([A-Za-z0-9_]+)=', ln)
        if m and m.group(1) in updated:
            k = m.group(1)
            out.append(f'{k}={updated[k]}')
            seen.add(k)
        else:
            out.append(ln)
    for k, v in updated.items():
        if k not in seen:
            out.append(f'{k}={v}')
    open(env_path, 'w').write('\n'.join(out) + '\n')
    for k, v in sorted(updated.items()):
        print(f'  {k}: {env.get(k, "(unset)")} -> {v}')
PY
        unset _ACE_INSPECT_JSON
        kubectl config use-context "kind-${cluster_name}" >/dev/null 2>&1 || true
        return 0
    fi

    # --- Cluster not running or lacks ACE ports: resolve host ports then create ---
    # Resolve all 16 KinD hostPorts: check each against live host bindings and
    # intra-batch claims, walk forward to a free slot where needed, and persist
    # the chosen values to .env so reruns stay stable.
    # NOTE: pick_kind_hostport writes to _HP_RESULT (not stdout) so that
    # _KIND_CLAIMED_PORTS side-effects survive across calls in the same shell.
    _KIND_CLAIMED_PORTS="" _HP_RESULT=""
    local _hp_ingress _hp_web _hp_auth_rest _hp_auth_grpc
    local _hp_gql_rest _hp_gql_grpc _hp_certifier _hp_litellm
    local _hp_langfuse _hp_mongo _hp_minio
    local _hp_otel_prom _hp_otel_k8s _hp_prom _hp_grafana _hp_dex
    pick_kind_hostport KIND_HOSTPORT_INGRESS       8088;  _hp_ingress="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_WEB           2001;  _hp_web="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_AUTH_REST     3005;  _hp_auth_rest="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_AUTH_GRPC     3030;  _hp_auth_grpc="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_GRAPHQL_REST  8081;  _hp_gql_rest="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_GRAPHQL_GRPC  8082;  _hp_gql_grpc="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_CERTIFIER     18000; _hp_certifier="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_LITELLM       14000; _hp_litellm="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_LANGFUSE      4002;  _hp_langfuse="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_MONGO         27017; _hp_mongo="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_MINIO         19090; _hp_minio="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_OTEL_PROM_MCP 31085; _hp_otel_prom="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_OTEL_K8S_MCP  31086; _hp_otel_k8s="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_PROMETHEUS    31090; _hp_prom="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_GRAFANA       31687; _hp_grafana="$_HP_RESULT"
    pick_kind_hostport KIND_HOSTPORT_DEX           32000; _hp_dex="$_HP_RESULT"
    unset _KIND_CLAIMED_PORTS _HP_RESULT

    # Render a per-checkout kind config: instance-scoped cluster name + host
    # ports, so two checkouts on this host never fight over the same
    # extraPortMappings (kind can only bind a given hostPort to one node).
    local kind_cfg="${REPO_ROOT}/.tmp/kind-agentcert.rendered.yaml"
    KIND_CLUSTER_NAME="${cluster_name}" \
    KIND_HOSTPORT_INGRESS="${_hp_ingress}" \
    KIND_HOSTPORT_WEB="${_hp_web}" \
    KIND_HOSTPORT_AUTH_REST="${_hp_auth_rest}" \
    KIND_HOSTPORT_AUTH_GRPC="${_hp_auth_grpc}" \
    KIND_HOSTPORT_GRAPHQL_REST="${_hp_gql_rest}" \
    KIND_HOSTPORT_GRAPHQL_GRPC="${_hp_gql_grpc}" \
    KIND_HOSTPORT_CERTIFIER="${_hp_certifier}" \
    KIND_HOSTPORT_LITELLM="${_hp_litellm}" \
    KIND_HOSTPORT_LANGFUSE="${_hp_langfuse}" \
    KIND_HOSTPORT_MONGO="${_hp_mongo}" \
    KIND_HOSTPORT_MINIO="${_hp_minio}" \
    KIND_HOSTPORT_OTEL_PROM_MCP="${_hp_otel_prom}" \
    KIND_HOSTPORT_OTEL_K8S_MCP="${_hp_otel_k8s}" \
    KIND_HOSTPORT_PROMETHEUS="${_hp_prom}" \
    KIND_HOSTPORT_GRAFANA="${_hp_grafana}" \
    KIND_HOSTPORT_DEX="${_hp_dex}" \
    "${REPO_ROOT}/deploy/kind/render-kind-config.sh" "${kind_cfg}"

    if kind get clusters 2>/dev/null | grep -qx "${cluster_name}"; then
        warn "kind cluster '${cluster_name}' exists but lacks the ACE port mappings."
        warn "It must be recreated (extraPortMappings can only be set at creation time)."
        read -rp "$(echo -e "Delete and recreate cluster '${cluster_name}'? ${DIM}[y/N]${NC}: ")" _ans
        if [[ ! "${_ans}" =~ ^[Yy] ]]; then
            warn "Skipped cluster recreation — port mappings will NOT work until recreated."
            return 0
        fi
        kind delete cluster --name "${cluster_name}"
        unmark_kind_cluster_owned "${cluster_name}"
    fi

    echo -e "${DIM}Creating kind cluster '${cluster_name}' (this takes ~1-2 min)…${NC}"
    echo -e "${DIM}Using kind config: ${kind_cfg}${NC}"
    kind create cluster --name "${cluster_name}" --config "${kind_cfg}"
    mark_kind_cluster_owned "${cluster_name}"
    kubectl config use-context "kind-${cluster_name}" >/dev/null 2>&1 || true
    ok "Kind cluster '${cluster_name}' created."
}

# Inject the real litellm_config.yaml into the litellm ConfigMap manifest
# before applying, so model aliases and env-var references are up to date.
patch_litellm_configmap() {
    local src="${REPO_ROOT}/agentcert-stack/litellm-setup/litellm_config.yaml"
    local dst="${REPO_ROOT}/deploy/k8s/litellm.yaml"
    if [[ ! -f "${src}" ]]; then
        warn "litellm_config.yaml not found at ${src} — skipping ConfigMap patch."
        return 0
    fi
    # Replace the placeholder value in the ConfigMap with the real config,
    # indented by 4 spaces to match the YAML data block.
    python3 - "${src}" "${dst}" <<'PY'
import sys, re, textwrap
src_path, dst_path = sys.argv[1], sys.argv[2]
cfg = open(src_path).read()
# indent every line by 4 spaces for the ConfigMap data block
indented = textwrap.indent(cfg, "    ")
dst = open(dst_path).read()
dst = re.sub(
    r'(  litellm_config\.yaml: \|)\n    # Placeholder.*?(?=\n---|\Z)',
    r'\1\n' + indented.rstrip(),
    dst,
    flags=re.DOTALL,
)
open(dst_path, "w").write(dst)
PY
    ok "Injected litellm_config.yaml into ConfigMap."
}

# Sync the LitmusChaos subscriber-secret with the active infra credentials stored
# in MongoDB.  Must be called after MongoDB is running and a chaos infrastructure
# has been registered via the LitmusChaos UI.  Safe to call repeatedly — uses
# kubectl apply --dry-run so it is idempotent.
sync_subscriber_secret() {
    local LITMUS_NS="litmus"
    local ACE_NS="ace"
    local mongo_user mongo_pass mongo_output infra_id access_key

    mongo_user="$(cur MONGODB_USERNAME)"; mongo_user="${mongo_user:-admin}"
    mongo_pass="$(cur MONGODB_PASSWORD)"; mongo_pass="${mongo_pass:-1234}"

    echo -e "${DIM}Syncing LitmusChaos subscriber-secret from active chaos infrastructure…${NC}"

    # Query the MongoDB the graphql server actually uses, so the subscriber-secret
    # matches what VerifyInfra() looks up at connection time.  In the k8s deployment
    # graphql, mongodb, and the litmus subscriber all run in-cluster, so the source
    # of truth is the mongodb-0 pod in the ace namespace.  Filter on is_registered
    # (set once at registration, stable) rather than is_active (flaps to false on
    # disconnect) — we are syncing precisely to recover from a disconnect.
    mongo_output="$(kubectl exec mongodb-0 -n "${ACE_NS}" -- mongosh \
        "mongodb://${mongo_user}:${mongo_pass}@localhost:27017/?authSource=admin&directConnection=true" \
        --quiet --eval \
        'var doc = db.getSiblingDB("litmus").chaosInfrastructures.findOne({is_registered:true});
         if(doc){ print("infra_id=" + doc.infra_id + "\naccess_key=" + doc.access_key); }' \
        2>/dev/null)" || true

    if [[ -z "$mongo_output" ]]; then
        warn "No active chaos infrastructure found in MongoDB — skipping subscriber-secret sync."
        warn "Register an infrastructure via the LitmusChaos UI, then re-run: ./scripts/setup.sh --restart"
        return 0
    fi

    infra_id="$(echo "$mongo_output" | grep '^infra_id=' | cut -d= -f2-)"
    access_key="$(echo "$mongo_output" | grep '^access_key=' | cut -d= -f2-)"

    if [[ -z "$infra_id" || -z "$access_key" ]]; then
        warn "Could not parse infra_id or access_key from MongoDB output — skipping sync."
        return 0
    fi

    kubectl create secret generic subscriber-secret \
        -n "${LITMUS_NS}" \
        --from-literal=INFRA_ID="${infra_id}" \
        --from-literal=ACCESS_KEY="${access_key}" \
        --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null \
        && ok "subscriber-secret synced (INFRA_ID=${infra_id})" \
        || warn "Failed to sync subscriber-secret — verify the '${LITMUS_NS}' namespace exists"

    # The Argo workflow controller only executes workflows whose
    # controller-instanceid label matches the instanceID in its ConfigMap.
    # The subscriber labels submitted workflows with its own INFRA_ID, so the
    # ConfigMap instanceID must match the active infra_id — otherwise every
    # submitted experiment workflow is silently ignored and stays Queued.
    kubectl patch configmap workflow-controller-configmap \
        -n "${LITMUS_NS}" \
        --type merge \
        -p "{\"data\":{\"instanceID\":\"${infra_id}\"}}" 2>/dev/null \
        && ok "workflow-controller-configmap instanceID synced (${infra_id})" \
        || warn "Failed to patch workflow-controller-configmap — verify the '${LITMUS_NS}' namespace exists"

    if kubectl get deployment subscriber -n "${LITMUS_NS}" >/dev/null 2>&1; then
        kubectl rollout restart deployment/subscriber -n "${LITMUS_NS}" >/dev/null 2>&1 \
            && ok "Subscriber deployment restarted." \
            || warn "Subscriber deployment restart failed."
    fi

    if kubectl get deployment workflow-controller -n "${LITMUS_NS}" >/dev/null 2>&1; then
        kubectl rollout restart deployment/workflow-controller -n "${LITMUS_NS}" >/dev/null 2>&1 \
            && ok "Workflow controller restarted to pick up new instanceID." \
            || warn "Workflow controller restart failed."
    fi
}

# load_images_into_kind CLUSTER_NAME
# Loads every image in LOCAL_BUILT_IMAGES into the named KinD cluster so pods
# use the locally built copy instead of pulling from Docker Hub.
load_images_into_kind() {
    local cluster_name="$1"
    if [[ ${#LOCAL_BUILT_IMAGES[@]} -eq 0 ]]; then
        warn "No locally built images to load into KinD."
        return 0
    fi
    echo
    echo -e "${DIM}Loading ${#LOCAL_BUILT_IMAGES[@]} local image(s) into KinD cluster '${cluster_name}'…${NC}"
    for _img in "${LOCAL_BUILT_IMAGES[@]}"; do
        if kind load docker-image "${_img}" --name "${cluster_name}"; then
            ok "  Loaded: ${_img}"
        else
            warn "  Failed to load ${_img} — pods may pull from Docker Hub instead"
        fi
    done
}

# Deploy all K8s manifests into the cluster.
k8s_deploy() {
    local K8S_DIR="${REPO_ROOT}/deploy/k8s"
    local NS="ace"
    local envval
    envval() { grep -m1 "^$1=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true; }

    echo
    echo -e "${CYAN}=======================================================${NC}"
    echo -e "${CYAN}  Deploying ACE stack to Kubernetes cluster${NC}"
    echo -e "${CYAN}=======================================================${NC}"
    echo

    # 1) Patch .env with K8s-specific service DNS names
    k8s_env_patch

    # 2) Ensure kind cluster (skip for cloud/local — they supply their own kubeconfig)
    if [[ "${CLUSTER_MODE}" == "local" || "${CLUSTER_MODE}" == "cloud" ]]; then
        ok "CLUSTER_MODE=${CLUSTER_MODE} — skipping kind cluster creation, using existing kubeconfig."
    else
        ensure_kind_cluster
    fi

    # 2b) Load locally built images into KinD (only when --local-build was used)
    if [[ "${DO_LOCAL_BUILD:-0}" -eq 1 && "${CLUSTER_MODE}" != "cloud" && "${CLUSTER_MODE}" != "local" ]]; then
        local _ace_inst; _ace_inst="$(cur ACE_INSTANCE_NAME)"
        local _k8s_cluster; _k8s_cluster="${KIND_CLUSTER_NAME:-$(cur KIND_CLUSTER_NAME)}"
        _k8s_cluster="${_k8s_cluster:-agentcert-${_ace_inst}}"
        load_images_into_kind "${_k8s_cluster}"
        unset _ace_inst _k8s_cluster
    fi

    # 3) Verify kubectl is connected
    if ! kubectl cluster-info >/dev/null 2>&1; then
        warn "kubectl cannot reach the cluster. Check KUBECONFIG or re-run after fixing the cluster."
        return 1
    fi

    # 4) Inject real litellm_config into the ConfigMap manifest
    patch_litellm_configmap

    # 5) Apply namespace first
    kubectl apply -f "${K8S_DIR}/00-namespace.yaml"

    # 5b) Create CA cert ConfigMap before pods start (graphql initContainer mounts it)
    echo -e "${DIM}Creating/updating ace-ca-certs ConfigMap…${NC}"
    create_ca_configmap "${NS}"

    # 6) Create (or update) the ace-env Secret from .env
    echo -e "${DIM}Creating/updating ace-env Secret from .env…${NC}"
    apply_ace_env_secret "${NS}"

    # 7) Apply RBAC
    kubectl apply -f "${K8S_DIR}/01-rbac.yaml"

    # 8) Apply all remaining manifests (alphabetical = deterministic order)
    for f in "${K8S_DIR}"/mongodb.yaml \
              "${K8S_DIR}"/auth.yaml \
              "${K8S_DIR}"/graphql.yaml \
              "${K8S_DIR}"/web.yaml \
              "${K8S_DIR}"/litellm.yaml \
              "${K8S_DIR}"/certifier.yaml \
              "${K8S_DIR}"/langfuse.yaml; do
        [[ -f "$f" ]] && kubectl apply -f "$f"
    done
    # For cloud clusters, switch the web service to LoadBalancer so browsers can reach it.
    # graphql stays NodePort — it is internal-only, reached via the web pod's nginx proxy.
    if [[ "${CLUSTER_MODE}" == "cloud" ]]; then
        kubectl patch svc web -n "${NS}" \
            -p '{"spec":{"type":"LoadBalancer","ports":[{"port":2001,"targetPort":2001,"protocol":"TCP"}]}}' \
            2>/dev/null && ok "web service patched to LoadBalancer." || true
    fi
    ok "Manifests applied."

    # 9) Wait for core services to become ready (best-effort; don't abort on timeout)
    echo
    echo -e "${DIM}Waiting for MongoDB, auth, graphql, web, certifier to be ready (up to 5 min)…${NC}"
    local svc
    for svc in mongodb auth graphql web certifier; do
        kubectl rollout status \
            "$(kubectl get statefulset,deployment -n "${NS}" \
                -o name 2>/dev/null | grep "/${svc}$" | head -1)" \
            -n "${NS}" --timeout=300s 2>/dev/null \
            && ok "${svc} ready" || warn "${svc} not yet ready — check: kubectl get pods -n ${NS}"
    done

    # 9b) Cloud: poll LB IP, update .env with real external endpoint, restart pods
    if [[ "${CLUSTER_MODE}" == "cloud" ]]; then
        post_cloud_setup "${NS}"
    fi

    # 9c) Sync LitmusChaos subscriber-secret from MongoDB (no-op if not yet registered)
    sync_subscriber_secret

    # 10) Print access URLs
    local admu admp luser lpass
    admu="$(envval ADMIN_USERNAME)";              admu="${admu:-admin}"
    admp="$(envval ADMIN_PASSWORD)";              admp="${admp:-litmus}"
    luser="$(envval LANGFUSE_INIT_USER_EMAIL)";   luser="${luser:-admin@agentcert.local}"
    lpass="$(envval LANGFUSE_INIT_USER_PASSWORD)";lpass="${lpass:-agentcert-admin}"
    local _hp_web _hp_langfuse _hp_certifier _hp_litellm _hp_mongo
    _hp_web="$(envval KIND_HOSTPORT_WEB)";             _hp_web="${_hp_web:-2001}"
    _hp_langfuse="$(envval KIND_HOSTPORT_LANGFUSE)";   _hp_langfuse="${_hp_langfuse:-4002}"
    _hp_certifier="$(envval KIND_HOSTPORT_CERTIFIER)"; _hp_certifier="${_hp_certifier:-18000}"
    _hp_litellm="$(envval KIND_HOSTPORT_LITELLM)";     _hp_litellm="${_hp_litellm:-14000}"
    _hp_mongo="$(envval KIND_HOSTPORT_MONGO)";         _hp_mongo="${_hp_mongo:-27017}"
    echo
    echo -e "${GREEN}=======================================================${NC}"
    echo -e "${GREEN}  ✓ ACE stack deployed to cluster${NC}"
    echo -e "${GREEN}=======================================================${NC}"
    if [[ "${CLUSTER_MODE}" == "cloud" ]]; then
        echo -e "  ${BOLD}AgentCert UI${NC}  (check LB IP above)          login: ${BOLD}${admu}${NC} / ${BOLD}${admp}${NC}"
    else
        echo -e "  ${BOLD}AgentCert UI${NC}  http://localhost:${_hp_web}          login: ${BOLD}${admu}${NC} / ${BOLD}${admp}${NC}"
    fi
    echo -e "  ${BOLD}Langfuse${NC}      http://localhost:${_hp_langfuse}          login: ${BOLD}${luser}${NC} / ${BOLD}${lpass}${NC}"
    echo -e "  ${BOLD}Certifier${NC}     http://localhost:${_hp_certifier}/docs"
    echo -e "  ${BOLD}LiteLLM${NC}       http://localhost:${_hp_litellm}"
    echo -e "  ${BOLD}MongoDB${NC}       localhost:${_hp_mongo}"
    echo
    echo -e "  ${DIM}status:  kubectl get pods -n ace${NC}"
    echo -e "  ${DIM}logs:    kubectl logs -n ace deploy/graphql -f${NC}"
    if [[ "${CLUSTER_MODE}" != "cloud" ]]; then
        echo -e "  ${DIM}teardown: kind delete cluster --name ${KIND_CLUSTER_NAME:-agentcert}${NC}"
    fi
    echo -e "${GREEN}=======================================================${NC}"
}

# Generate deploy/helm/ace/values-env.yaml from .env (and litellm config) so
# the chart owns the ace-env Secret. The file is gitignored — never committed.
# After running this, the only helm command needed is:
#   helm upgrade --install ace deploy/helm/ace --create-namespace -f deploy/helm/ace/values-env.yaml
generate_helm_values_env() {
    local out="${REPO_ROOT}/deploy/helm/ace/values-env.yaml"
    local litellm_cfg="${REPO_ROOT}/agentcert-stack/litellm-setup/litellm_config.yaml"
    dedup_env "${ENV_FILE}"
    python3 - "${ENV_FILE}" "${out}" "${litellm_cfg}" <<'PY'
import sys, re, os
env_path, out_path, litellm_cfg = sys.argv[1], sys.argv[2], sys.argv[3]
# collect keys in order, last value wins
keys_order, seen = [], {}
for ln in open(env_path).read().splitlines():
    m = re.match(r'^([A-Za-z0-9_.]+)=(.*)', ln)
    if not m:
        continue
    k, v = m.group(1), m.group(2)
    if k not in seen:
        keys_order.append(k)
    seen[k] = v
lines = ["env:"]
for k in keys_order:
    v = seen[k].replace("'", "''")
    lines.append(f"  {k}: '{v}'")
# litellm config (inline so --set-file is not needed)
if os.path.isfile(litellm_cfg):
    cfg = open(litellm_cfg).read()
    lines += ["", "litellm:", "  config: |"]
    lines += ["    " + l for l in cfg.splitlines()]
open(out_path, "w").write("\n".join(lines) + "\n")
PY
    ok "Generated values-env.yaml (env + litellm config)."
}

# Deploy via Helm — helm owns everything: namespace, secret, all workloads.
helm_deploy() {
    local CHART_DIR="${REPO_ROOT}/deploy/helm/ace"
    local VALUES_ENV="${CHART_DIR}/values-env.yaml"
    local NS="ace"
    local LITELLM_CFG="${REPO_ROOT}/agentcert-stack/litellm-setup/litellm_config.yaml"
    local envval
    envval() { grep -m1 "^$1=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true; }

    echo
    echo -e "${CYAN}=======================================================${NC}"
    echo -e "${CYAN}  Deploying ACE stack via Helm${NC}"
    echo -e "${CYAN}=======================================================${NC}"
    echo

    # 1) Patch .env with K8s-specific service DNS names
    k8s_env_patch

    # 2) Ensure kind cluster (skip for cloud/local — they supply their own kubeconfig)
    if [[ "${CLUSTER_MODE}" == "local" || "${CLUSTER_MODE}" == "cloud" ]]; then
        ok "CLUSTER_MODE=${CLUSTER_MODE} — skipping kind cluster creation, using existing kubeconfig."
    else
        ensure_kind_cluster
    fi

    # 2b) Load locally built images into KinD (only when --local-build was used)
    if [[ "${DO_LOCAL_BUILD:-0}" -eq 1 && "${CLUSTER_MODE}" != "cloud" && "${CLUSTER_MODE}" != "local" ]]; then
        local _ace_inst; _ace_inst="$(cur ACE_INSTANCE_NAME)"
        local _helm_cluster; _helm_cluster="${KIND_CLUSTER_NAME:-$(cur KIND_CLUSTER_NAME)}"
        _helm_cluster="${_helm_cluster:-agentcert-${_ace_inst}}"
        load_images_into_kind "${_helm_cluster}"
        unset _ace_inst _helm_cluster
    fi

    # 3) Verify kubectl is connected
    if ! kubectl cluster-info >/dev/null 2>&1; then
        warn "kubectl cannot reach the cluster. Check KUBECONFIG or re-run after fixing the cluster."
        return 1
    fi

    # 4) Generate values-env.yaml (helm reads this to create the ace-env Secret)
    echo -e "${DIM}Generating values-env.yaml from .env…${NC}"
    generate_helm_values_env

    # 4b) Create namespace + CA cert ConfigMap before helm installs pods
    kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo -e "${DIM}Creating/updating ace-ca-certs ConfigMap…${NC}"
    create_ca_configmap "${NS}"

    # 5) Run helm — it owns namespace, secret, and all workloads
    local helm_cmd=(
        helm upgrade --install ace "${CHART_DIR}"
        --namespace "${NS}"
        --create-namespace
        -f "${VALUES_ENV}"
        --timeout 10m
    )
    # Cloud clusters need the web service on a LoadBalancer so browsers can reach the UI.
    # graphql stays NodePort — it is internal-only, reached via the web pod's nginx proxy.
    if [[ "${CLUSTER_MODE}" == "cloud" ]]; then
        helm_cmd+=(--set web.serviceType=LoadBalancer)
    fi
    # On KinD (auto/fresh), always use IfNotPresent so locally built images take effect
    # without being overwritten by a Docker Hub pull.  Always is only appropriate for
    # remote registries (cloud clusters) where images are never kind-loaded.
    if [[ "${DO_LOCAL_BUILD:-0}" -eq 1 || ( "${CLUSTER_MODE}" != "cloud" && "${CLUSTER_MODE}" != "local" ) ]]; then
        helm_cmd+=(--set imagePullPolicy=IfNotPresent)
    fi

    echo -e "${DIM}Running: ${helm_cmd[*]}${NC}"
    echo
    # The chart has a post-install/post-upgrade hook (mongodb-rs-init Job) that
    # initialises the replica set.  Helm blocks until this hook completes — this
    # is normal and takes 2-5 min on first install while MongoDB starts up.
    # Watch pod status in a background loop so the terminal is not silent.
    ( while true; do
        sleep 15
        kubectl get pods -n ace --no-headers 2>/dev/null \
            | awk '{printf "  %-45s %s/%s  %s\n", $1, $2, $3, $4}' \
            | grep -v "^$" || true
        echo "  (helm is waiting for the mongodb-rs-init hook to complete…)"
      done ) &
    _HELM_WATCH_PID=$!
    "${helm_cmd[@]}"
    kill "${_HELM_WATCH_PID}" 2>/dev/null; unset _HELM_WATCH_PID

    # 5b) Cloud: poll LB IP, update .env with real external endpoint, restart pods
    if [[ "${CLUSTER_MODE}" == "cloud" ]]; then
        post_cloud_setup "${NS}"
    fi

    # 5c) Wire host services (LiteLLM, Ollama) into the cluster via selector-less
    #     Services + manual Endpoints so pods can reach them by stable DNS name.
    #     The endpoint IP is the pod->host gateway detected above (k3s cni0 or kind bridge).
    #     This step is skipped for cloud mode (host services not applicable there).
    if [[ "${CLUSTER_MODE}" != "cloud" && -n "${CALLBACK_HOST}" ]]; then
        # Read the per-instance Ollama host port. The system Ollama owns :11434;
        # each checkout's containerized Ollama publishes on OLLAMA_PORT (auto-
        # derived earlier in this script from the user's UID). In-cluster pods
        # still connect to ollama.ace.svc.cluster.local:11434 (the Service's
        # virtual port); kube-proxy routes that to CALLBACK_HOST:ollama_port via
        # the Endpoints below.
        local ollama_port
        ollama_port="$(envval OLLAMA_PORT)"; ollama_port="${ollama_port:-11435}"

        echo -e "${DIM}Wiring host services into cluster (gateway: ${CALLBACK_HOST})…${NC}"
        # litellm: in-cluster DNS name for the Docker-compose LiteLLM proxy
        kubectl apply -f - >/dev/null <<LITELLM_EOF
apiVersion: v1
kind: Endpoints
metadata:
  name: litellm
  namespace: ${NS}
subsets:
  - addresses:
      - ip: ${CALLBACK_HOST}
    ports:
      - port: 14000
        name: http
        protocol: TCP
LITELLM_EOF
        # ollama: in-cluster DNS name for THIS checkout's Ollama container.
        # Service port 11434 is the stable in-cluster virtual port; Endpoints
        # port ${ollama_port} is the actual host port where the ACE-owned
        # Ollama container (ollama-${ACE_INSTANCE_NAME}) is published.
        kubectl apply -f - >/dev/null <<OLLAMA_SVC_EOF
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: ollama
    app.kubernetes.io/managed-by: setup.sh
spec:
  ports:
    - port: 11434
      targetPort: ${ollama_port}
      protocol: TCP
      name: ollama
---
apiVersion: v1
kind: Endpoints
metadata:
  name: ollama
  namespace: ${NS}
subsets:
  - addresses:
      - ip: ${CALLBACK_HOST}
    ports:
      - port: ${ollama_port}
        name: ollama
        protocol: TCP
OLLAMA_SVC_EOF
        ok "Host services wired: litellm.${NS}.svc.cluster.local:14000, ollama.${NS}.svc.cluster.local:11434 → host:${ollama_port}"
    fi

    # 6) Print access URLs
    local admu admp luser lpass
    admu="$(envval ADMIN_USERNAME)";              admu="${admu:-admin}"
    admp="$(envval ADMIN_PASSWORD)";              admp="${admp:-litmus}"
    luser="$(envval LANGFUSE_INIT_USER_EMAIL)";   luser="${luser:-admin@agentcert.local}"
    lpass="$(envval LANGFUSE_INIT_USER_PASSWORD)";lpass="${lpass:-agentcert-admin}"
    local _hp_web _hp_langfuse _hp_certifier _hp_litellm _hp_mongo
    _hp_web="$(envval KIND_HOSTPORT_WEB)";             _hp_web="${_hp_web:-2001}"
    _hp_langfuse="$(envval KIND_HOSTPORT_LANGFUSE)";   _hp_langfuse="${_hp_langfuse:-4002}"
    _hp_certifier="$(envval KIND_HOSTPORT_CERTIFIER)"; _hp_certifier="${_hp_certifier:-18000}"
    _hp_litellm="$(envval KIND_HOSTPORT_LITELLM)";     _hp_litellm="${_hp_litellm:-14000}"
    _hp_mongo="$(envval KIND_HOSTPORT_MONGO)";         _hp_mongo="${_hp_mongo:-27017}"
    echo
    echo -e "${GREEN}=======================================================${NC}"
    echo -e "${GREEN}  ✓ ACE stack deployed via Helm${NC}"
    echo -e "${GREEN}=======================================================${NC}"
    echo -e "  ${BOLD}Release${NC}       ace  (namespace: ${NS})"
    if [[ "${CLUSTER_MODE}" == "cloud" ]]; then
        echo -e "  ${BOLD}AgentCert UI${NC}  (check LB IP above)          login: ${BOLD}${admu}${NC} / ${BOLD}${admp}${NC}"
    else
        echo -e "  ${BOLD}AgentCert UI${NC}  http://localhost:${_hp_web}          login: ${BOLD}${admu}${NC} / ${BOLD}${admp}${NC}"
    fi
    echo -e "  ${BOLD}Langfuse${NC}      http://localhost:${_hp_langfuse}          login: ${BOLD}${luser}${NC} / ${BOLD}${lpass}${NC}"
    echo -e "  ${BOLD}Certifier${NC}     http://localhost:${_hp_certifier}/docs"
    echo -e "  ${BOLD}LiteLLM${NC}       http://localhost:${_hp_litellm}"
    echo -e "  ${BOLD}MongoDB${NC}       localhost:${_hp_mongo}"
    echo
    echo -e "  ${DIM}status:   kubectl get pods -n ace${NC}"
    echo -e "  ${DIM}upgrade:  helm upgrade --install ace deploy/helm/ace --create-namespace -f deploy/helm/ace/values-env.yaml --timeout 10m${NC}"
    echo -e "  ${DIM}rollback: helm rollback ace -n ace${NC}"
    echo -e "  ${DIM}teardown: helm uninstall ace -n ace${NC}"
    echo -e "${GREEN}=======================================================${NC}"
}

# --- build (push to Docker Hub or local) ------------------------------------
declare -a LOCAL_BUILT_IMAGES=()   # tracks successfully built images for kind load

if [[ "${DO_BUILD}" -eq 1 || "${DO_LOCAL_BUILD}" -eq 1 ]]; then
    echo
    echo -e "${CYAN}=======================================================${NC}"
    [[ "${DO_BUILD}" -eq 1 ]] \
        && echo -e "${CYAN}  Build & push selected images${NC}" \
        || echo -e "${CYAN}  Build selected images locally${NC}"
    echo -e "${CYAN}=======================================================${NC}"
    echo
    _build_ready=1
    if [[ "${DO_BUILD}" -eq 1 ]]; then
        if echo "${DH_TOKEN}" | docker login -u "${DH_USER}" --password-stdin 2>&1; then
            ok "Logged in to Docker Hub as ${DH_USER}"
        else
            warn "Docker Hub login failed — images were NOT built."
            _build_ready=0
        fi
    fi
    if [[ "${_build_ready}" -eq 1 ]]; then
        BUILD_FAILED=()
        for _entry in "${SELECTED_BUILD_IMAGES[@]}"; do
            IFS='|' read -r _num _label _img _ctx _df _method <<< "$_entry"
            echo
            echo -e "${CYAN}▸${NC} ${BOLD}${_img}:latest${NC}  ${DIM}(${_label})${NC}"
            if [[ "$_method" == compose:* ]]; then
                # inline dockerfile or compose-managed build — delegate to docker compose
                _svc="${_method#compose:}"
                if ( cd "${REPO_ROOT}" && docker compose build "${_svc}" ); then
                    ok "  Built ${_img}:latest"
                    LOCAL_BUILT_IMAGES+=("${_img}:latest")
                else
                    warn "  Build failed: ${_label}"
                    BUILD_FAILED+=("${_label} (build)"); continue
                fi
            else
                if [[ ! -f "${_ctx}/${_df}" ]]; then
                    warn "  Dockerfile not found: ${_ctx}/${_df} — skipping"
                    BUILD_FAILED+=("${_label} (no Dockerfile)"); continue
                fi
                if docker build -t "${_img}:latest" -f "${_ctx}/${_df}" "${_ctx}"; then
                    ok "  Built ${_img}:latest"
                    LOCAL_BUILT_IMAGES+=("${_img}:latest")
                else
                    warn "  Build failed: ${_label}"
                    BUILD_FAILED+=("${_label} (build)"); continue
                fi
            fi
            if [[ "${DO_BUILD}" -eq 1 ]]; then
                if docker push "${_img}:latest"; then
                    ok "  Pushed ${_img}:latest"
                else
                    warn "  Push failed: ${_label}"
                    BUILD_FAILED+=("${_label} (push)")
                fi
            fi
        done
        echo
        if [[ ${#BUILD_FAILED[@]} -eq 0 ]]; then
            if [[ "${DO_BUILD}" -eq 1 ]]; then
                ok "All selected images built and pushed successfully."
            else
                ok "All selected images built locally (${#LOCAL_BUILT_IMAGES[@]} images ready for KinD load)."
            fi
        else
            warn "Completed with failures: ${BUILD_FAILED[*]}"
        fi
    fi
    unset _build_ready
    echo -e "${CYAN}=======================================================${NC}"
    echo
fi

# --- charts world-readable (graphql runs as uid 65534) ----------------------
# git clones on hosts with umask 0077 create directories as 700, which blocks
# uid 65534 from traversing into the repo at all.  Fix: repo root needs o+x
# (traversal) so the container can reach the bind-mounted files; the .env also
# needs o+r so the container can re-read it via the hostPath volume; and the
# charts subdirs need o+rX so ReadDir succeeds.  All idempotent.
chmod o+x  "${REPO_ROOT}"          2>/dev/null && ok "Made repo root traversable for uid 65534 (graphql)" || true
chmod o+r  "${ENV_FILE}"           2>/dev/null || true
for _charts_dir in "${REPO_ROOT}/agent-charts/charts" "${REPO_ROOT}/app-charts/charts"; do
    if [[ -d "${_charts_dir}" ]]; then
        chmod -R o+rX "${_charts_dir}" 2>/dev/null && ok "Made ${_charts_dir} world-readable (uid 65534 / graphql)" || true
    fi
done

if [[ $EXPRESS_MODE -eq 0 ]]; then
    echo -e "${BOLD}Deploy the stack to the Kubernetes cluster now?${NC}"
    echo -e "   ${BOLD}k${NC}  kubectl apply  ${DIM}(plain manifests — no release tracking)${NC}"
    echo -e "   ${BOLD}h${NC}  helm install   ${DIM}(Helm release — supports upgrade/rollback)${NC}"
    echo -e "   ${BOLD}n${NC}  skip for now"
    read -rp "$(echo -e "Choice ${DIM}[k/h/N]${NC}: ")" deploy_choice
fi
deploy_choice="${deploy_choice:-${_DEPLOY_CHOICE:-n}}"
case "${deploy_choice,,}" in
    k) k8s_deploy ;;
    h) helm_deploy ;;
    *) echo -e "${DIM}Skipped — run './scripts/setup.sh' again and choose k or h to deploy.${NC}" ;;
esac

# --- Prepare experiment images -----------------------------------------------
# Runs whenever any image source is non-default (local or jfrog).
# In --restart mode this reads the current .env values directly.
_cur_app_src="$(cur INSTALL_APP_IMAGE_SOURCE)"
_cur_agent_src="$(cur INSTALL_AGENT_IMAGE_SOURCE)"
_cur_litmus_src="$(cur LITMUS_IMAGES_SOURCE)"
if [[ "${_cur_app_src}"   == "local" || "${_cur_app_src}"   == "jfrog" || \
      "${_cur_agent_src}" == "local" || "${_cur_agent_src}" == "jfrog" || \
      "${_cur_litmus_src}" == "local" ]]; then
    echo
    "${REPO_ROOT}/scripts/prepare-images.sh"
fi
unset _cur_app_src _cur_agent_src _cur_litmus_src

# --- Wait for background Ollama model pull ----------------------------------
if [[ -n "${_OLLAMA_PULL_PID}" ]]; then
    echo
    echo -e "${DIM}Waiting for Ollama model pull to complete (PID ${_OLLAMA_PULL_PID}) …${NC}"
    if wait "${_OLLAMA_PULL_PID}"; then
        ok "Ollama model pull complete."
    else
        warn "Ollama pull failed. Check log: ${_OLLAMA_PULL_LOG}"
        warn "Retry: ${_OLLAMA_PULL_RETRY_CMD}"
    fi
fi
unset _OLLAMA_PULL_PID _OLLAMA_PULL_LOG _OLLAMA_PULL_RETRY_CMD
