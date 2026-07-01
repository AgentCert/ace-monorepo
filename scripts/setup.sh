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

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'

say()  { echo -e "$*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }

# --- prep .env -------------------------------------------------------------
# .env must already exist (created by apply-cluster-prereqs.sh)
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: ${ENV_FILE} not found." >&2
    echo "       Run 'scripts/apply-cluster-prereqs.sh' first (it creates .env from .env.example)." >&2
    exit 1
fi
ok "Using existing .env (press Enter at each prompt to keep current values)"

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
echo -e "   ${DIM}auto=reuse kubeconfig or create kind · local=existing cluster · fresh=new kind${NC}"
CLUSTER_MODE="$(ask CLUSTER_MODE 'CLUSTER_MODE (auto/local/fresh)')"
CLUSTER_MODE="${CLUSTER_MODE:-auto}"
echo

# --- Section 4: JFrog Registry credentials --------------------------------
echo -e "${BOLD}4) JFrog Artifactory credentials${NC} ${DIM}(for pulling images from infyartifactory.jfrog.io)${NC}"
echo -e "   ${DIM}Set JFROG_USER/JFROG_TOKEN env vars to skip prompts.${NC}"
JFROG_USER="${JFROG_USER:-$(cur JFROG_USER)}"
JFROG_TOKEN="${JFROG_TOKEN:-$(cur JFROG_TOKEN)}"
if [[ -z "$JFROG_USER" ]]; then
    JFROG_USER="$(ask JFROG_USER 'JFrog username')"
fi
if [[ -z "$JFROG_TOKEN" ]]; then
    read -rsp "$(echo -e "  ${BOLD}JFrog token/password${NC}: ")" JFROG_TOKEN
    echo
fi

# Log in to JFrog immediately so the session persists for the entire setup
if [[ -n "${JFROG_USER:-}" && -n "${JFROG_TOKEN:-}" ]]; then
    echo "${JFROG_TOKEN}" | docker login infyartifactory.jfrog.io -u "${JFROG_USER}" --password-stdin 2>&1 \
        && ok "Logged in to JFrog (infyartifactory.jfrog.io)" \
        || warn "JFrog docker login failed — image pushes may fail later."
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

CALLBACK_HOST="$(detect_kind_gw || true)"
if [[ -n "${CALLBACK_HOST}" ]]; then
    echo -e "${DIM}Detected kind gateway for pod->host callbacks: ${CALLBACK_HOST}${NC}"
else
    CALLBACK_HOST="172.26.0.1"
    warn "kind network not up yet — using ${CALLBACK_HOST} for now; will re-detect after bring-up."
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

# WebSocket origin allow-list (graphql checks the subscriber's Host against this).
# Must include the host IP in-cluster pods connect from — kind gateway (172.*),
# pod CIDR (10.*), LAN (192.168.*). Otherwise the subscriber gets "websocket: bad handshake".
host_alt = ("|" + re.escape(cb)) if cb else ""
sets["ALLOWED_ORIGINS"] = (
    r"^(http://|https://|ws://|wss://|)((localhost|host\.docker\.internal|host\.minikube\.internal)"
    r"|172\.[0-9]+\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+"
    r"|100\.78\.[0-9]+\.[0-9]+|100\.104\.[0-9]+\.[0-9]+"
    r"|[a-z0-9.-]+\.svc\.cluster\.local"
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
echo -e "Docs:  ${DIM}docs/setup/  ·  configuration & ports: docs/setup/configuration.md${NC}"
echo

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

# Build and apply the ca-certs ConfigMap from the system CA bundle + any
# corporate proxy certs pointed to by CORPORATE_CA_CERT_DIR in .env.
# This ConfigMap is mounted into pods (graphql, etc.) that need to make
# outbound HTTPS calls (e.g. cloning chaos-charts from GitHub).
apply_ca_certs_configmap() {
    local ns="$1"
    local ca_dir
    ca_dir="$(grep -m1 '^CORPORATE_CA_CERT_DIR=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"

    local bundle="/tmp/ace-ca-bundle.pem"

    # Start with the system CA bundle
    if [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
        cp /etc/ssl/certs/ca-certificates.crt "${bundle}"
    else
        : > "${bundle}"
    fi

    # Append corporate proxy certs if CORPORATE_CA_CERT_DIR is set
    if [[ -n "${ca_dir}" && -d "${ca_dir}" ]]; then
        local cert_count=0
        for crt in "${ca_dir}"/*.crt "${ca_dir}"/*.pem; do
            if [[ -f "${crt}" ]]; then
                cat "${crt}" >> "${bundle}" 2>/dev/null || true
                cert_count=$((cert_count + 1))
            fi
        done
        if [[ ${cert_count} -gt 0 ]]; then
            ok "Appended ${cert_count} corporate CA cert(s) from ${ca_dir}"
        else
            warn "CORPORATE_CA_CERT_DIR=${ca_dir} set but no .crt/.pem files found."
        fi
    fi

    # Create/update the ConfigMap
    if [[ -s "${bundle}" ]]; then
        kubectl create configmap ca-certs -n "${ns}" \
            --from-file=ca-certificates.crt="${bundle}" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        ok "ca-certs ConfigMap created/updated in namespace '${ns}'."
    else
        warn "No CA bundle found — ca-certs ConfigMap not created."
    fi
    rm -f "${bundle}"
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

    # 2) Ensure kind cluster is up (skip when pointing at an external cluster)
    if [[ "${CLUSTER_MODE}" != "local" ]]; then
        ensure_kind_cluster
    else
        ok "CLUSTER_MODE=local — skipping kind cluster creation, using existing kubeconfig."
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
    echo -e "  ${BOLD}AgentCert UI${NC}  http://localhost:2001          login: ${BOLD}${admu}${NC} / ${BOLD}${admp}${NC}"
    echo -e "  ${BOLD}Langfuse${NC}      http://localhost:4000          login: ${BOLD}${luser}${NC} / ${BOLD}${lpass}${NC}"
    echo -e "  ${BOLD}Certifier${NC}     http://localhost:18000/docs"
    echo -e "  ${BOLD}LiteLLM${NC}       http://localhost:14000"
    echo -e "  ${BOLD}MongoDB${NC}       localhost:27017"
    echo
    echo -e "  ${DIM}status:  kubectl get pods -n ace${NC}"
    echo -e "  ${DIM}logs:    kubectl logs -n ace deploy/graphql -f${NC}"
    echo -e "  ${DIM}teardown: kind delete cluster --name ${KIND_CLUSTER_NAME:-agentcert}${NC}"
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
    ok "Generated values-env.yaml (env + litellm config + hostPath)."
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

    # 2) Ensure kind cluster is up with the right port mappings
    ensure_kind_cluster

    # 3) Verify kubectl is connected
    if ! kubectl cluster-info >/dev/null 2>&1; then
        warn "kubectl cannot reach the cluster. Check KUBECONFIG or re-run after fixing the cluster."
        return 1
    fi

    # 4) Generate values-env.yaml (helm reads this to create the ace-env Secret)
    echo -e "${DIM}Generating values-env.yaml from .env…${NC}"
    generate_helm_values_env

    # 4b) ca-certs ConfigMap — run ./scripts/apply-cluster-prereqs.sh separately (needs sudo)
    # Skipped here to avoid hanging on sudo password prompt.

    # 5) Run helm — it owns namespace, secret, and all workloads
    local helm_cmd=(
        helm upgrade --install ace "${CHART_DIR}"
        --namespace "${NS}"
        --create-namespace
        -f "${VALUES_ENV}"
        --timeout 10m
    )

    echo -e "${DIM}Running: ${helm_cmd[*]}${NC}"
    echo
    "${helm_cmd[@]}" || warn "Helm install timed out — will continue setup (MongoDB RS likely needs init)."

    # 5b) JFrog Registry — cluster-wide secret sync
    echo
    echo -e "${BOLD}Setting up JFrog registry credentials (cluster-wide)…${NC}"
    if [[ -n "${JFROG_USER:-}" && -n "${JFROG_TOKEN:-}" ]]; then
        # Master secret in kube-system (source for the sync CronJob)
        kubectl create secret docker-registry jfrog-registry \
            --namespace kube-system \
            --docker-server="infyartifactory.jfrog.io" \
            --docker-username="${JFROG_USER}" \
            --docker-password="${JFROG_TOKEN}" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        # Also in ace namespace immediately
        kubectl create secret docker-registry jfrog-registry \
            --namespace "${NS}" \
            --docker-server="infyartifactory.jfrog.io" \
            --docker-username="${JFROG_USER}" \
            --docker-password="${JFROG_TOKEN}" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        kubectl patch serviceaccount default -n "${NS}" \
            -p '{"imagePullSecrets": [{"name": "jfrog-registry"}]}' 2>/dev/null || true
        ok "jfrog-registry secret in kube-system + ${NS}"

        # Deploy the sync Deployment (replaces old CronJob)
        if [[ -f "${REPO_ROOT}/deploy/jfrog-secret-sync.yaml" ]]; then
            kubectl delete cronjob jfrog-secret-sync -n kube-system --ignore-not-found >/dev/null 2>&1 || true
            kubectl apply -f "${REPO_ROOT}/deploy/jfrog-secret-sync.yaml" >/dev/null
            ok "jfrog-secret-sync Deployment deployed (watches namespaces + syncs secret within seconds)"
            kubectl rollout status deployment/jfrog-secret-sync -n kube-system --timeout=60s >/dev/null 2>&1 || true
        fi
    else
        warn "JFrog credentials not provided — pods may fail to pull images."
    fi

    # 5c) MongoDB RS initialization (localhost exception — no auth needed on fresh DB)
    echo
    echo -e "${DIM}Waiting for MongoDB pod to be ready…${NC}"
    kubectl wait --for=condition=ready pod/mongodb-0 -n "${NS}" --timeout=120s 2>/dev/null || true
    # Check if RS is already initialized
    local rs_status
    rs_status="$(kubectl exec mongodb-0 -n "${NS}" -- mongosh --quiet --eval 'rs.status().ok' 2>/dev/null || echo 0)"
    if [[ "$rs_status" != "1" ]]; then
        echo -e "${DIM}Initializing MongoDB replica set…${NC}"
        kubectl exec mongodb-0 -n "${NS}" -- mongosh --quiet --eval '
          rs.initiate({
            _id: "rs0",
            members: [{ _id: 0, host: "mongodb-0.mongodb-headless.'"${NS}"'.svc.cluster.local:27017" }]
          })
        ' 2>/dev/null || true
        sleep 5
        # Create admin user via localhost exception
        kubectl exec mongodb-0 -n "${NS}" -- mongosh --quiet --eval '
          db.getSiblingDB("admin").createUser({
            user: "admin",
            pwd: "1234",
            roles: [{ role: "root", db: "admin" }]
          })
        ' 2>/dev/null || true
        ok "MongoDB RS initialized + admin user created."
    else
        ok "MongoDB RS already initialized."
    fi

    # 5d) Brief pause for jfrog-secret-sync Deployment to complete its initial sync
    sleep 5

    # Resolve image registry once (used by all subsequent deploys)
    local img_reg
    img_reg="$(envval IMAGE_REGISTRY)"; img_reg="${img_reg:-infyartifactory.jfrog.io/docker-local}"

    # Ensure submodules are up-to-date (chart sources)
    echo -e "${DIM}Syncing git submodules…${NC}"
    ( cd "${REPO_ROOT}" && git submodule update --init --recursive 2>/dev/null ) || true

    # 5e) Deploy sock-shop
    echo
    echo -e "${BOLD}Deploying sock-shop…${NC}"
    local SOCK_SHOP_CHART="${REPO_ROOT}/app-charts/charts/sock-shop"
    if [[ -d "${SOCK_SHOP_CHART}" ]]; then
        kubectl create namespace sock-shop --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        kubectl label namespace sock-shop app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
        kubectl annotate namespace sock-shop meta.helm.sh/release-name=sock-shop --overwrite 2>/dev/null || true
        kubectl annotate namespace sock-shop meta.helm.sh/release-namespace=sock-shop --overwrite 2>/dev/null || true
        helm upgrade --install sock-shop "${SOCK_SHOP_CHART}" \
            --namespace sock-shop \
            --set global.imageRegistry="${img_reg}" \
            --timeout 10m || warn "sock-shop helm install had issues — check pods."
        ok "sock-shop deployed."
    else
        warn "app-charts/charts/sock-shop not found — skipping."
    fi

    # 5f) Deploy litellm (standalone namespace)
    echo
    echo -e "${BOLD}Deploying litellm proxy…${NC}"
    local LITELLM_DIR="${REPO_ROOT}/agent-charts/litellm"
    if [[ -d "${LITELLM_DIR}" ]]; then
        kubectl create namespace litellm --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        # Create litellm secrets from .env values
        local az_key az_base az_model az_ver lm_master lf_pub lf_sec lf_host
        az_key="$(envval AZURE_OPENAI_KEY)";       az_key="${az_key:-$(envval AZURE_OPENAI_API_KEY)}"
        az_base="$(envval AZURE_OPENAI_ENDPOINT)"
        az_model="$(envval AZURE_OPENAI_CHAT_DEPLOYMENT_NAME)"; az_model="${az_model:-gpt4o}"
        az_ver="$(envval AZURE_OPENAI_API_VERSION)"; az_ver="${az_ver:-2024-12-01-preview}"
        lm_master="sk-litellm-master-key"
        lf_pub="$(envval LANGFUSE_PUBLIC_KEY)";    lf_pub="${lf_pub:-placeholder}"
        lf_sec="$(envval LANGFUSE_SECRET_KEY)";    lf_sec="${lf_sec:-placeholder}"
        lf_host="$(envval LANGFUSE_HOST)";         lf_host="${lf_host:-http://langfuse-web.ace.svc.cluster.local:3000}"
        kubectl create secret generic litellm-secrets \
            --namespace litellm \
            --from-literal=AZURE_API_KEY="${az_key}" \
            --from-literal=AZURE_API_BASE="${az_base}" \
            --from-literal=AZURE_MODEL="${az_model}" \
            --from-literal=AZURE_API_VERSION="${az_ver}" \
            --from-literal=LITELLM_MASTER_KEY="${lm_master}" \
            --from-literal=LANGFUSE_PUBLIC_KEY="${lf_pub}" \
            --from-literal=LANGFUSE_SECRET_KEY="${lf_sec}" \
            --from-literal=LANGFUSE_HOST="${lf_host}" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        kubectl apply -f "${LITELLM_DIR}/configmap.yaml" >/dev/null
        kubectl apply -f "${LITELLM_DIR}/deployment.yaml" >/dev/null
        ok "litellm deployed in litellm namespace."
    else
        warn "agent-charts/litellm not found — skipping."
    fi

    # 5g) Deploy flash-agent
    echo
    echo -e "${BOLD}Deploying flash-agent…${NC}"
    local FLASH_CHART="${REPO_ROOT}/agent-charts/charts/flash-agent"
    if [[ -d "${FLASH_CHART}" ]]; then
        helm upgrade --install flash-agent "${FLASH_CHART}" \
            --namespace sock-shop \
            --timeout 5m || warn "flash-agent deploy had issues."
        ok "flash-agent deployed in sock-shop namespace."
    else
        warn "agent-charts/charts/flash-agent not found — skipping."
    fi

    # 5h) Update fault registries
    echo
    echo -e "${BOLD}Updating chaos-chart image registries…${NC}"
    if [[ -x "${REPO_ROOT}/scripts/update-all-registries.sh" ]]; then
        "${REPO_ROOT}/scripts/update-all-registries.sh" || true
        ok "Image registries updated."
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
    echo -e "  ${BOLD}AgentCert UI${NC}  http://localhost:2001          login: ${BOLD}${admu}${NC} / ${BOLD}${admp}${NC}"
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
    # Resolve JFrog registry for tagging
    img_reg="$(cur IMAGE_REGISTRY)"; img_reg="${img_reg:-infyartifactory.jfrog.io/docker-local}"
    # Login to JFrog for push
    if [[ -n "${JFROG_USER:-}" && -n "${JFROG_TOKEN:-}" ]]; then
        echo "${JFROG_TOKEN}" | docker login infyartifactory.jfrog.io -u "${JFROG_USER}" --password-stdin 2>&1 \
            && ok "Logged in to JFrog (infyartifactory.jfrog.io)" \
            || warn "JFrog login failed — images won't be pushed to JFrog."
    fi
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
                ok "  Pushed ${_img}:latest to Docker Hub"
            else
                warn "  Push to Docker Hub failed: ${_label}"
                BUILD_FAILED+=("${_label} (push)")
            fi
            # Also push to JFrog if credentials are available
            if [[ -n "${JFROG_USER:-}" && -n "${JFROG_TOKEN:-}" ]]; then
                local _jfrog_img="${img_reg}/${_img}"
                docker tag "${_img}:latest" "${_jfrog_img}:latest"
                if docker push "${_jfrog_img}:latest"; then
                    ok "  Pushed ${_jfrog_img}:latest"
                else
                    warn "  Push to JFrog failed: ${_label}"
                    BUILD_FAILED+=("${_label} (jfrog push)")
                fi
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
