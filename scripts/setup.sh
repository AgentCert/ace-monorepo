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
for _arg in "$@"; do
    case "$_arg" in
        --restart) SETUP_MODE="restart" ;;
        --setup)   SETUP_MODE="setup"   ;;
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

if [[ "$SETUP_MODE" == "restart" ]]; then
    CLUSTER_MODE="$(cur CLUSTER_MODE)"; CLUSTER_MODE="${CLUSTER_MODE:-auto}"
    DO_BUILD=0; DH_USER=""; DH_TOKEN=""
    declare -a SELECTED_BUILD_IMAGES=()
    echo
    echo -e "${CYAN}=======================================================${NC}"
    echo -e "${CYAN}  ACE restart — re-applying stack (no .env changes)${NC}"
    echo -e "${CYAN}=======================================================${NC}"
    echo -e "${DIM}  CLUSTER_MODE=${CLUSTER_MODE}  ·  .env: ${ENV_FILE}${NC}"
    echo
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
       _CLUSTER_MODE="$CLUSTER_MODE" _CALLBACK_HOST="$CALLBACK_HOST" \
       _FLASH_MODEL="$FLASH_MODEL" _DH_USER="$DH_USER" _DH_TOKEN="$DH_TOKEN" \
       _CUSTOM_CA_CERT_PATH="${CUSTOM_CA_CERT_PATH:-}"
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

# ── Corporate proxy CA cert path ─────────────────────────────────────────────
custom_ca = os.environ.get("_CUSTOM_CA_CERT_PATH", "")
if custom_ca:
    sets["CUSTOM_CA_CERT_PATH"] = custom_ca

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
echo -e "Next:  ${BOLD}./scripts/setup.sh${NC} then answer Y to deploy, or run ${BOLD}kubectl get pods -n ace${NC}"
echo -e "       Re-deploy without re-entering values: ${BOLD}./scripts/setup.sh --restart${NC}"
echo -e "Docs:  ${DIM}docs/setup/  ·  configuration & ports: docs/setup/configuration.md${NC}"
echo

fi  # end SETUP_MODE=setup

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

# Ensure the kind cluster exists and has the port mappings required for the
# K8s deployment. Recreates the cluster if the config has changed.
ensure_kind_cluster() {
    local kind_cfg="${REPO_ROOT}/deploy/kind/kind-agentcert.yaml"
    local cluster_name="${KIND_CLUSTER_NAME:-agentcert}"

    # Check whether the current cluster node already has the ACE port bindings
    # (nodePort 32001 → host 2001 is the canary). If not, recreate the cluster.
    local has_ace_ports
    has_ace_ports="$(docker inspect "${cluster_name}-control-plane" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin)[0]; \
          print('yes' if '32001/tcp' in d.get('HostConfig',{}).get('PortBindings',{}) else 'no')" \
        2>/dev/null || echo "no")"

    if [[ "${has_ace_ports}" == "yes" ]]; then
        ok "kind cluster '${cluster_name}' already has ACE port mappings — reusing it."
        kubectl config use-context "kind-${cluster_name}" >/dev/null 2>&1 || true
        return 0
    fi

    if kind get clusters 2>/dev/null | grep -qx "${cluster_name}"; then
        warn "kind cluster '${cluster_name}' exists but lacks the ACE port mappings."
        warn "It must be recreated (extraPortMappings can only be set at creation time)."
        read -rp "$(echo -e "Delete and recreate cluster '${cluster_name}'? ${DIM}[y/N]${NC}: ")" _ans
        if [[ ! "${_ans}" =~ ^[Yy] ]]; then
            warn "Skipped cluster recreation — port mappings will NOT work until recreated."
            return 0
        fi
        kind delete cluster --name "${cluster_name}"
    fi

    echo -e "${DIM}Creating kind cluster '${cluster_name}' (this takes ~1-2 min)…${NC}"
    echo -e "${DIM}Using kind config: ${kind_cfg}${NC}"
    kind create cluster --name "${cluster_name}" --config "${kind_cfg}"
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
    echo
    echo -e "${GREEN}=======================================================${NC}"
    echo -e "${GREEN}  ✓ ACE stack deployed to cluster${NC}"
    echo -e "${GREEN}=======================================================${NC}"
    if [[ "${CLUSTER_MODE}" == "cloud" ]]; then
        echo -e "  ${BOLD}AgentCert UI${NC}  (check LB IP above)          login: ${BOLD}${admu}${NC} / ${BOLD}${admp}${NC}"
    else
        echo -e "  ${BOLD}AgentCert UI${NC}  http://localhost:2001          login: ${BOLD}${admu}${NC} / ${BOLD}${admp}${NC}"
    fi
    echo -e "  ${BOLD}Langfuse${NC}      http://localhost:4000          login: ${BOLD}${luser}${NC} / ${BOLD}${lpass}${NC}"
    echo -e "  ${BOLD}Certifier${NC}     http://localhost:18000/docs"
    echo -e "  ${BOLD}LiteLLM${NC}       http://localhost:14000"
    echo -e "  ${BOLD}MongoDB${NC}       localhost:27017"
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

    echo -e "${DIM}Running: ${helm_cmd[*]}${NC}"
    echo
    "${helm_cmd[@]}"

    # 5b) Cloud: poll LB IP, update .env with real external endpoint, restart pods
    if [[ "${CLUSTER_MODE}" == "cloud" ]]; then
        post_cloud_setup "${NS}"
    fi

    # 5c) Wire host services (LiteLLM, Ollama) into the cluster via selector-less
    #     Services + manual Endpoints so pods can reach them by stable DNS name.
    #     The endpoint IP is the pod->host gateway detected above (k3s cni0 or kind bridge).
    #     This step is skipped for cloud mode (host services not applicable there).
    if [[ "${CLUSTER_MODE}" != "cloud" && -n "${CALLBACK_HOST}" ]]; then
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
        # ollama: in-cluster DNS name for the host Ollama inference server
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
      targetPort: 11434
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
      - port: 11434
        name: ollama
        protocol: TCP
OLLAMA_SVC_EOF
        ok "Host services wired: litellm.${NS}.svc.cluster.local:14000, ollama.${NS}.svc.cluster.local:11434"
    fi

    # 6) Print access URLs
    local admu admp luser lpass
    admu="$(envval ADMIN_USERNAME)";              admu="${admu:-admin}"
    admp="$(envval ADMIN_PASSWORD)";              admp="${admp:-litmus}"
    luser="$(envval LANGFUSE_INIT_USER_EMAIL)";   luser="${luser:-admin@agentcert.local}"
    lpass="$(envval LANGFUSE_INIT_USER_PASSWORD)";lpass="${lpass:-agentcert-admin}"
    echo
    echo -e "${GREEN}=======================================================${NC}"
    echo -e "${GREEN}  ✓ ACE stack deployed via Helm${NC}"
    echo -e "${GREEN}=======================================================${NC}"
    echo -e "  ${BOLD}Release${NC}       ace  (namespace: ${NS})"
    if [[ "${CLUSTER_MODE}" == "cloud" ]]; then
        echo -e "  ${BOLD}AgentCert UI${NC}  (check LB IP above)          login: ${BOLD}${admu}${NC} / ${BOLD}${admp}${NC}"
    else
        echo -e "  ${BOLD}AgentCert UI${NC}  http://localhost:2001          login: ${BOLD}${admu}${NC} / ${BOLD}${admp}${NC}"
    fi
    echo -e "  ${BOLD}Langfuse${NC}      http://localhost:4000          login: ${BOLD}${luser}${NC} / ${BOLD}${lpass}${NC}"
    echo -e "  ${BOLD}Certifier${NC}     http://localhost:18000/docs"
    echo -e "  ${BOLD}LiteLLM${NC}       http://localhost:14000"
    echo -e "  ${BOLD}MongoDB${NC}       localhost:27017"
    echo
    echo -e "  ${DIM}status:   kubectl get pods -n ace${NC}"
    echo -e "  ${DIM}upgrade:  helm upgrade --install ace deploy/helm/ace --create-namespace -f deploy/helm/ace/values-env.yaml --timeout 10m${NC}"
    echo -e "  ${DIM}rollback: helm rollback ace -n ace${NC}"
    echo -e "  ${DIM}teardown: helm uninstall ace -n ace${NC}"
    echo -e "${GREEN}=======================================================${NC}"
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

echo -e "${BOLD}Deploy the stack to the Kubernetes cluster now?${NC}"
echo -e "   ${BOLD}k${NC}  kubectl apply  ${DIM}(plain manifests — no release tracking)${NC}"
echo -e "   ${BOLD}h${NC}  helm install   ${DIM}(Helm release — supports upgrade/rollback)${NC}"
echo -e "   ${BOLD}n${NC}  skip for now"
read -rp "$(echo -e "Choice ${DIM}[k/h/N]${NC}: ")" deploy_choice
case "${deploy_choice,,}" in
    k) k8s_deploy ;;
    h) helm_deploy ;;
    *) echo -e "${DIM}Skipped — run './scripts/setup.sh' again and choose k or h to deploy.${NC}" ;;
esac
