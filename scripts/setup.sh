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

# --- REQUIRED: Azure OpenAI -------------------------------------------------
echo -e "${BOLD}1) Azure OpenAI${NC} ${DIM}(required for real agent runs)${NC}"
AZ_KEY="$(ask AZURE_OPENAI_KEY 'API key')"
AZ_ENDPOINT="$(ask AZURE_OPENAI_ENDPOINT 'Endpoint URL (https://<resource>.openai.azure.com/)')"
AZ_DEPLOY="$(ask AZURE_OPENAI_CHAT_DEPLOYMENT_NAME 'Chat deployment name (e.g. gpt4o)')"
echo

# --- OPTIONAL: cluster + infra modes ---------------------------------------
echo -e "${BOLD}2) How should Kubernetes be sourced?${NC} ${DIM}(Enter = auto)${NC}"
echo -e "   ${DIM}auto=reuse kubeconfig or create kind · local=existing cluster · fresh=new kind · cloud=AKS/EKS/GKE${NC}"
CLUSTER_MODE="$(ask CLUSTER_MODE 'CLUSTER_MODE (auto/local/fresh/cloud)')"
CLUSTER_MODE="${CLUSTER_MODE:-auto}"
echo

# --- write values (robust; values can contain / and special chars) ---------
export _AZ_KEY="$AZ_KEY" _AZ_ENDPOINT="$AZ_ENDPOINT" _AZ_DEPLOY="$AZ_DEPLOY" _CLUSTER_MODE="$CLUSTER_MODE"
python3 - "${ENV_FILE}" <<'PY'
import os, sys, re
path = sys.argv[1]
key  = os.environ["_AZ_KEY"]
ep   = os.environ["_AZ_ENDPOINT"]
dep  = os.environ["_AZ_DEPLOY"]
cm   = os.environ["_CLUSTER_MODE"]

# Azure resource is reused across the main, certifier-reasoning, and embedding
# model configs by default, so fan the same key/endpoint out to all of them.
sets = {"CLUSTER_MODE": cm}
if key:
    for k in ("AZURE_OPENAI_KEY","AZURE_OPENAI_API_KEY","AZURE_OPENAI_GPT5_API_KEY","AZURE_EMBEDDING_API_KEY"):
        sets[k] = key
if ep:
    for k in ("AZURE_OPENAI_ENDPOINT","AZURE_OPENAI_GPT5_ENDPOINT","AZURE_EMBEDDING_ENDPOINT"):
        sets[k] = ep
if dep:
    for k in ("AZURE_OPENAI_DEPLOYMENT","AZURE_OPENAI_CHAT_DEPLOYMENT_NAME","AZURE_OPENAI_GPT5_CHAT_DEPLOYMENT_NAME"):
        sets[k] = dep

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

ok "Wrote Azure OpenAI settings + CLUSTER_MODE=${CLUSTER_MODE} to .env"

# --- summary + sanity -------------------------------------------------------
echo
echo -e "${CYAN}-------------------------------------------------------${NC}"
if [[ -z "$AZ_KEY" || -z "$AZ_ENDPOINT" || -z "$AZ_DEPLOY" ]]; then
    warn "Azure OpenAI is not fully set — the stack will still start, but the"
    warn "agent's LLM calls will fail until you set AZURE_OPENAI_* (re-run this)."
else
    ok "Azure OpenAI configured."
fi
echo -e "  Cluster mode : ${BOLD}${CLUSTER_MODE}${NC}"
echo -e "  Infra        : MongoDB + Langfuse + LiteLLM run locally ${DIM}(defaults; edit .env to change)${NC}"
echo -e "${CYAN}-------------------------------------------------------${NC}"
echo
echo -e "Next:  ${BOLD}docker compose up -d${NC}    ${DIM}then open http://localhost:2001 (admin / litmus)${NC}"
echo -e "Docs:  ${DIM}docs/setup/  ·  configuration & ports: docs/setup/configuration.md${NC}"
echo

# --- optional: bring it up now ---------------------------------------------
read -rp "$(echo -e "Bring the stack up now with 'docker compose up -d'? ${DIM}[y/N]${NC}: ")" go
if [[ "$go" =~ ^[Yy] ]]; then
    ( cd "${REPO_ROOT}" && docker compose up -d )
fi
