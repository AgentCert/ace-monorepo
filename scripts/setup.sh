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

echo
echo -e "${CYAN}=======================================================${NC}"
echo -e "${CYAN}  ACE setup — fill the few values that matter${NC}"
echo -e "${CYAN}=======================================================${NC}"
echo -e "${DIM}Everything not asked here has a working default for the${NC}"
echo -e "${DIM}all-local 'docker compose up' flow. Only Azure OpenAI is${NC}"
echo -e "${DIM}required for the agent's LLM calls to actually work.${NC}"
echo

# --- Build & push (optional) ------------------------------------------------
declare -a ALL_BUILD_IMAGES=(
    "1|flash-agent|agentcert/agentcert-flash-agent|${REPO_ROOT}/flash-agent|Dockerfile|direct"
    "2|agent-sidecar|agentcert/agent-sidecar|${REPO_ROOT}/agent-sidecar|Dockerfile|direct"
    "3|install-agent|agentcert/agentcert-install-agent|${REPO_ROOT}/agent-charts|install-agent/Dockerfile|direct"
    "4|install-app|agentcert/agentcert-install-app|${REPO_ROOT}/app-charts|install-app/Dockerfile|direct"
    "5|certifier|agentcert/certifier|${REPO_ROOT}/certifier|Dockerfile|direct"
    "6|auth|agentcert/agentcert-auth|${REPO_ROOT}/AgentCert/chaoscenter/authentication|Dockerfile|direct"
    "7|graphql|agentcert/agentcert-graphql|${REPO_ROOT}/AgentCert/chaoscenter/graphql|server/Dockerfile|direct"
    "8|web|agentcert/agentcert-web|||compose:agentcert-web"
    "9|cluster-init|agentcert/cluster-init|${REPO_ROOT}/compose/cluster-init|Dockerfile|direct"
)
DO_BUILD=0; DH_USER=""; DH_TOKEN=""
declare -a SELECTED_BUILD_IMAGES=()

read -rp "$(echo -e "${BOLD}Build and push Docker images to Docker Hub?${NC} ${DIM}[y/N]${NC}: ")" _build_ans
if [[ "$_build_ans" =~ ^[Yy] ]]; then
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
    if [[ ${#SELECTED_BUILD_IMAGES[@]} -gt 0 ]]; then
        echo
        DH_USER="$(ask DOCKERHUB_USERNAME 'Docker Hub username')"
        DH_TOKEN="$(ask DOCKERHUB_TOKEN 'Docker Hub token (dckr_pat_...)')"
        DH_USER="$(echo "${DH_USER}" | tr -d '[:space:]')"
        DH_TOKEN="$(echo "${DH_TOKEN}" | tr -d '[:space:]')"
        [[ -n "$DH_USER" && -n "$DH_TOKEN" ]] && DO_BUILD=1 \
            || warn "Docker Hub credentials missing — skipping build."
    fi
fi
echo

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

# --- Section 2: Flash-agent model selection --------------------------------
# Build the list of active model aliases from whatever was just configured.
CONFIGURED_MODELS=()
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
FLASH_MODEL="$(ask FLASH_AGENT_MODEL 'Flash-agent model alias')"
FLASH_MODEL="$(echo "${FLASH_MODEL:-${DEFAULT_FLASH}}" | tr -d '[:space:]')"
echo

# --- OPTIONAL: cluster + infra modes ---------------------------------------
echo -e "${BOLD}3) How should Kubernetes be sourced?${NC} ${DIM}(Enter = auto)${NC}"
echo -e "   ${DIM}auto=reuse kubeconfig or create kind · local=existing cluster · fresh=new kind · cloud=AKS/EKS/GKE${NC}"
CLUSTER_MODE="$(ask CLUSTER_MODE 'CLUSTER_MODE (auto/local/fresh/cloud)')"
CLUSTER_MODE="${CLUSTER_MODE:-auto}"
echo

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

# In-cluster pods call back to the control plane on this host. For kind/local
# that's the kind-network gateway; for cloud the VM must be reachable at a
# routable IP, so ask for it.
if [[ "${CLUSTER_MODE}" == cloud ]]; then
    CALLBACK_HOST="$(ask HOST_PUBLIC_IP 'VM public/reachable IP (in-cluster pods call back here)')"
    CALLBACK_HOST="$(echo "${CALLBACK_HOST}" | tr -d '[:space:]')"
else
    CALLBACK_HOST="$(detect_kind_gw || true)"
    if [[ -n "${CALLBACK_HOST}" ]]; then
        echo -e "${DIM}Detected kind gateway for pod->host callbacks: ${CALLBACK_HOST}${NC}"
    else
        CALLBACK_HOST="172.26.0.1"
        warn "kind network not up yet — using ${CALLBACK_HOST} for now; will re-detect after bring-up."
    fi
fi
echo

# --- write values (robust; values can contain / and special chars) ---------
export _AZ_KEY="$AZ_KEY" _AZ_ENDPOINT="$AZ_ENDPOINT" _AZ_DEPLOY="$AZ_DEPLOY" \
       _AZ_DEPLOY_GPT5="$AZ_DEPLOY_GPT5" _AZ_DEPLOY_EMBED="$AZ_DEPLOY_EMBED" \
       _AZ_ALIAS="$AZ_ALIAS" _AZ_APIVER="$AZ_APIVER" \
       _GEMINI_KEY="$GEMINI_KEY" _OPENROUTER_KEY="$OPENROUTER_KEY" \
       _CLUSTER_MODE="$CLUSTER_MODE" _CALLBACK_HOST="$CALLBACK_HOST" \
       _FLASH_MODEL="$FLASH_MODEL" _DH_USER="$DH_USER" _DH_TOKEN="$DH_TOKEN"
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

# ── Docker Hub ────────────────────────────────────────────────────────────────
dh_user = os.environ.get("_DH_USER", "")
dh_token = os.environ.get("_DH_TOKEN", "")
if dh_user:
    sets["DOCKERHUB_USERNAME"] = dh_user
if dh_token:
    sets["DOCKERHUB_TOKEN"] = dh_token

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
    if cm == "cloud":
        sets["HOST_PUBLIC_IP"] = cb

# WebSocket origin allow-list (graphql checks the subscriber's Host against this).
# Must include the host IP in-cluster pods connect from — kind gateway (172.*),
# pod CIDR (10.*), LAN (192.168.*), plus the explicit callback host (e.g. a cloud
# public IP). Otherwise the subscriber gets "websocket: bad handshake".
host_alt = ("|" + re.escape(cb)) if cb else ""
sets["ALLOWED_ORIGINS"] = (
    r"^(http://|https://|)((localhost|host\.docker\.internal|host\.minikube\.internal)"
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
if [[ -z "$AZ_KEY" && -z "$GEMINI_KEY" && -z "$OPENROUTER_KEY" ]]; then
    warn "No LLM providers configured — agents won't be able to make LLM calls (re-run to add one)."
fi
echo -e "  Flash-agent model : ${BOLD}${FLASH_MODEL}${NC}"
echo -e "  Cluster mode      : ${BOLD}${CLUSTER_MODE}${NC}"
echo -e "  Infra             : MongoDB + Langfuse + LiteLLM run locally ${DIM}(defaults; edit .env to change)${NC}"
echo -e "${CYAN}-------------------------------------------------------${NC}"
echo
echo -e "Next:  ${BOLD}docker compose up -d${NC}    ${DIM}then open http://localhost:2001 (admin / litmus)${NC}"
echo -e "Docs:  ${DIM}docs/setup/  ·  configuration & ports: docs/setup/configuration.md${NC}"
echo

# --- optional: bring it up now ---------------------------------------------
# Set or replace KEY=VALUE in .env (used to remap ports on conflict).
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

# Replace ONLY the host in an http(s)/mongodb URL env var, preserving the
# scheme, any user:pass@, the port and path. Used to retarget pod->host
# callback URLs at the real kind gateway without clobbering remapped ports.
rehost() {
    local k="$1" h="$2"
    grep -qE "^${k}=" "${ENV_FILE}" || return 0
    python3 - "${ENV_FILE}" "$k" "$h" <<'PY'
import sys, re
path, k, h = sys.argv[1:4]
ls = open(path).read().splitlines()
for i, l in enumerate(ls):
    m = re.match(rf'^{re.escape(k)}=(.*)$', l)
    if m:
        v = re.sub(r'(//(?:[^/@]+@)?)[^:/]+', r'\g<1>' + h, m.group(1), count=1)
        ls[i] = f"{k}={v}"
open(path, "w").write("\n".join(ls) + "\n")
PY
}

# Runs `docker compose up -d` and, on failure, resolves the three common causes:
# container-name conflicts (auto-remove + retry), host-port conflicts (offer to
# stop the holder OR remap to a free port written into .env), and dependency
# failures (report + point at logs). Loops until clean or the user opts out.
compose_up() {
    # Stream live progress (tee) so a slow fresh bring-up — kind creation, mongo
    # health, image pulls — never looks frozen, while capturing the log to detect
    # container-name conflicts. Compose reports conflicts a few at a time, so we
    # LOOP: clear each round's conflicts and retry until the up is conflict-free.
    # One confirmation up front, then it auto-clears subsequent conflicts.
    local log auto=0 tries=0 conflicts c owner ans ports result=ok svc up_flags=""
    log="$(mktemp)"
    echo -e "${DIM}(streaming docker compose output — a fresh kind bring-up can take several minutes)${NC}"
    while true; do
        tries=$((tries + 1))
        if [[ "${tries}" -gt 20 ]]; then
            warn "Giving up after ${tries} attempts — resolve the issues above, then: docker compose up -d"
            result=stuck; break
        fi
        # ${up_flags} becomes --force-recreate after a port is freed/remapped, so
        # the new binding is applied instead of reusing a stale container.
        ( cd "${REPO_ROOT}" && docker compose up -d ${up_flags} ) 2>&1 | tee "${log}" || true

        # (a) container NAME conflict → remove the offending container(s) + retry
        if grep -q 'is already in use' "${log}"; then
            if [[ "${tries}" -ge 12 ]]; then
                warn "Still hitting name conflicts after ${tries} attempts — resolve manually."
                result=namestuck; break
            fi
            mapfile -t conflicts < <(grep -oE 'container name "/[^"]+"' "${log}" \
                | sed -E 's#.*"/([^"]+)".*#\1#' | sort -u)
            if [[ "${auto}" -eq 0 ]]; then
                echo
                warn "Container name(s) already in use by other containers:"
                for c in "${conflicts[@]}"; do
                    owner="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null)"
                    echo -e "    ${BOLD}${c}${NC} ${DIM}(project: ${owner:-standalone})${NC}"
                done
                echo -e "${DIM}(more may surface as the bring-up proceeds; answering yes clears them too)${NC}"
                read -rp "$(echo -e "Remove conflicting container(s) and retry until clean? ${DIM}[y/N]${NC}: ")" ans
                [[ "${ans}" =~ ^[Yy] ]] || { warn "Left in place. Remove/rename them, then: docker compose up -d"; result=declined; break; }
                auto=1
            fi
            docker rm -f "${conflicts[@]}" >/dev/null 2>&1 || true
            ok "Removed: ${conflicts[*]} — retrying…"
            continue
        fi

        # (b) host PORT conflict → per port, offer to stop the holder OR remap to
        #     a free port (written into .env), then retry.
        if grep -qE 'port is already allocated|Bind for [0-9.]+:[0-9]+ failed' "${log}"; then
            mapfile -t ports < <(grep -oE 'Bind for [0-9.]+:[0-9]+ failed' "${log}" \
                | grep -oE ':[0-9]+ ' | tr -d ': ' | sort -u)
            local pchanged=0 p holder pvar pvar2 pdesc newp
            for p in "${ports[@]}"; do
                # map the busy host port → the .env knob(s) that control it
                pvar=""; pvar2=""; pdesc=""
                case "$p" in
                    4000)  pvar=LANGFUSE_PORT; pvar2=LANGFUSE_HOST;  pdesc="Langfuse UI/API" ;;
                    9090)  pvar=MINIO_API_PORT;                      pdesc="Langfuse MinIO" ;;
                    14000) pvar=LITELLM_PORT;  pvar2=LITELLM_HOST;   pdesc="LiteLLM proxy" ;;
                    27017) pvar=MONGO_PORT;     pvar2=DB_SERVER;     pdesc="MongoDB" ;;
                    8000)  pvar=API_PORT;                            pdesc="Certifier API" ;;
                    *)     pdesc="(no .env knob)" ;;
                esac
                holder="$(docker ps --filter "publish=${p}" --format '{{.Names}}' 2>/dev/null | head -1)"
                echo
                warn "Port ${p} (${pdesc}) is in use${holder:+ by container '${holder}'}."
                if [[ -z "$pvar" ]]; then
                    echo -e "  ${DIM}No .env port knob for ${p} — free it manually, then re-run.${NC}"
                    continue
                fi
                echo -e "    ${BOLD}m${NC} = move ACE to a free port (sets ${pvar} in .env)"
                [[ -n "$holder" ]] && echo -e "    ${BOLD}s${NC} = stop the container '${holder}' that holds ${p}"
                echo -e "    ${BOLD}k${NC} = skip"
                read -rp "  choice for ${p} [m/s/k]: " ans
                case "$ans" in
                    m|M)
                        read -rp "  new ${pvar} (free port): " newp
                        newp="$(echo "${newp}" | tr -d '[:space:]')"
                        if [[ -n "$newp" ]]; then
                            set_env "$pvar" "$newp"
                            # keep the matching host/URL var in sync
                            case "$pvar2" in
                                LANGFUSE_HOST) set_env LANGFUSE_HOST "http://${CALLBACK_HOST:-172.26.0.1}:${newp}" ;;
                                LITELLM_HOST)  set_env LITELLM_HOST  "http://${CALLBACK_HOST:-172.26.0.1}:${newp}" ;;
                                DB_SERVER)     warn "  Remember to update the port in DB_SERVER (Mongo client URL) to ${newp}." ;;
                            esac
                            ok "  Set ${pvar}=${newp}"; pchanged=1
                        fi ;;
                    s|S)
                        if [[ -n "$holder" ]] && docker stop "$holder" >/dev/null 2>&1; then
                            ok "  Stopped ${holder}"; pchanged=1
                        else
                            warn "  Could not stop ${holder:-(host process — free it manually)}"
                        fi ;;
                    *) warn "  Skipped ${p}." ;;
                esac
            done
            if [[ "$pchanged" -eq 1 ]]; then
                up_flags="--force-recreate"   # ensure freed/remapped ports are applied (no stale-container reuse)
                ok "Retrying with updated config (force-recreate)…"; continue
            fi
            warn "No changes made — resolve the port(s) above, then: docker compose up -d"
            echo -e "  ${DIM}(or set *_MODE=external to reuse an existing service — see docs/setup/configuration.md)${NC}"
            result=port; break
        fi

        # (c) a dependency/one-shot failed (e.g. cluster-init couldn't reach k8s)
        if grep -qE "didn't complete successfully|dependency failed to start" "${log}"; then
            svc="$(grep -oE 'service "[^"]+" didn'"'"'t complete successfully' "${log}" \
                | sed -E 's/service "([^"]+)".*/\1/' | sort -u | tr '\n' ' ')"
            echo
            warn "A dependency failed to start: ${svc:-see output above}"
            if echo "${svc}" | grep -q cluster-init; then
                echo -e "  cluster-init couldn't get a working Kubernetes context. Check it:"
                echo -e "    ${BOLD}docker logs ace-cluster-init${NC}"
                echo -e "  Common cause: CLUSTER_MODE=local/cloud but no reachable cluster, or a"
                echo -e "  stopped kind cluster. For a fresh local cluster: ${BOLD}kind delete cluster --name agentcert${NC} then re-run,"
                echo -e "  or set ${BOLD}CLUSTER_MODE=fresh${NC} in .env."
            else
                echo -e "  Inspect it: ${BOLD}docker logs <that-container>${NC}"
            fi
            result=svcfail; break
        fi

        # (d) compose reported success — but a container can still crash-loop on an
        #     INTERNAL error (e.g. a port already bound *inside* host networking),
        #     which never shows in the `up` output. Poll the actual states.
        echo -e "${DIM}(verifying services stay healthy…)${NC}"
        sleep 8
        local bad
        # `|| true` so a clean stack (grep finds nothing → exit 1) doesn't trip
        # `set -e` and abort before the success summary.
        bad="$( { cd "${REPO_ROOT}" && docker compose ps -a --format '{{.Name}}\t{{.State}}\t{{.Status}}' 2>/dev/null \
            | grep -iE 'restarting|exited' \
            | grep -viE 'cluster-init|mongo-init|mongo-keyfile'; } || true)"   # one-shots exit 0 on purpose
        if [[ -n "$bad" ]]; then
            echo
            warn "These services started but are NOT staying up (crash-looping / exited):"
            echo "${bad}" | sed -E 's/^/    /'
            echo -e "  Inspect the failing one(s): ${BOLD}docker compose logs <name>${NC}  (e.g. docker logs agentcert-auth)"
            echo -e "  ${DIM}Common cause on a shared box: a host port (3000/3030/8081/…) is held by another process — free it or move the matching *_PORT.${NC}"
            result=unhealthy
        fi
        break
    done
    rm -f "${log}"

    # Re-detect the kind gateway now that bring-up has created the kind network
    # (on a fresh VM it didn't exist when we wrote .env). If it differs from what
    # we wrote, retarget the pod->host callback URLs and recreate graphql so the
    # in-cluster subscriber/agent use the correct per-VM address.
    if [[ "${result}" == ok && "${CLUSTER_MODE}" != cloud ]]; then
        local gw_now
        gw_now="$(detect_kind_gw || true)"
        if [[ -n "${gw_now}" && "${gw_now}" != "${CALLBACK_HOST}" ]]; then
            warn "kind gateway is ${gw_now} (placeholder was ${CALLBACK_HOST}) — retargeting pod->host callbacks in .env."
            rehost SUBSCRIBER_CALLBACK_URL "${gw_now}"
            rehost SERVER_ADDR             "${gw_now}"
            rehost PORTAL_ENDPOINT         "${gw_now}"
            rehost LITELLM_HOST            "${gw_now}"
            rehost LANGFUSE_HOST           "${gw_now}"
            CALLBACK_HOST="${gw_now}"
            ( cd "${REPO_ROOT}" && docker compose up -d --force-recreate graphql >/dev/null 2>&1 ) || true
            ok "Retargeted callbacks at ${gw_now} and recreated graphql."
        fi
    fi
    echo
    if [[ "${result}" == ok ]]; then
        local lport luser lpass admu admp lmode
        envval() { grep -m1 "^$1=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true; }
        lport="$(envval LANGFUSE_PORT)";              lport="${lport:-4000}"
        luser="$(envval LANGFUSE_INIT_USER_EMAIL)";   luser="${luser:-admin@agentcert.local}"
        lpass="$(envval LANGFUSE_INIT_USER_PASSWORD)";lpass="${lpass:-agentcert-admin}"
        admu="$(envval ADMIN_USERNAME)";              admu="${admu:-admin}"
        admp="$(envval ADMIN_PASSWORD)";              admp="${admp:-litmus}"
        lmode="$(envval LANGFUSE_MODE)";              lmode="${lmode:-local}"
        echo -e "${GREEN}=======================================================${NC}"
        echo -e "${GREEN}  ✓ Stack is up${NC}"
        echo -e "${GREEN}=======================================================${NC}"
        echo -e "  ${BOLD}AgentCert UI${NC}  http://localhost:2001        login: ${BOLD}${admu}${NC} / ${BOLD}${admp}${NC}"
        if [[ "${lmode}" == local ]]; then
            echo -e "  ${BOLD}Langfuse${NC}      http://localhost:${lport}        login: ${BOLD}${luser}${NC} / ${BOLD}${lpass}${NC}"
        else
            echo -e "  ${BOLD}Langfuse${NC}      external (LANGFUSE_HOST in .env)"
        fi
        echo -e "  ${BOLD}Certifier${NC}     http://localhost:8000/docs"
        echo
        echo -e "  ${DIM}status: docker compose ps   ·   logs: docker compose logs -f graphql${NC}"
        echo -e "  ${DIM}stop:   docker compose down   (add -v to wipe data)${NC}"
        echo -e "${GREEN}=======================================================${NC}"
    else
        warn "Bring-up did NOT fully succeed (see above). After fixing, re-run: docker compose up -d"
    fi
}

# --- build and push (if requested earlier) ----------------------------------
if [[ "${DO_BUILD}" -eq 1 ]]; then
    echo
    echo -e "${CYAN}=======================================================${NC}"
    echo -e "${CYAN}  Build & push selected images${NC}"
    echo -e "${CYAN}=======================================================${NC}"
    echo
    if echo "${DH_TOKEN}" | docker login -u "${DH_USER}" --password-stdin 2>&1; then
        ok "Logged in to Docker Hub as ${DH_USER}"
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
                else
                    warn "  Build failed: ${_label}"
                    BUILD_FAILED+=("${_label} (build)"); continue
                fi
            fi
            if docker push "${_img}:latest"; then
                ok "  Pushed ${_img}:latest"
            else
                warn "  Push failed: ${_label}"
                BUILD_FAILED+=("${_label} (push)")
            fi
        done
        echo
        if [[ ${#BUILD_FAILED[@]} -eq 0 ]]; then
            ok "All selected images built and pushed successfully."
        else
            warn "Completed with failures: ${BUILD_FAILED[*]}"
        fi
    else
        warn "Docker Hub login failed — images were NOT built."
    fi
    echo -e "${CYAN}=======================================================${NC}"
    echo
fi

read -rp "$(echo -e "Bring the stack up now with 'docker compose up -d'? ${DIM}[y/N]${NC}: ")" go
if [[ "$go" =~ ^[Yy] ]]; then
    compose_up
fi
