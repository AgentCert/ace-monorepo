#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# ACE prerequisite check & self-heal
# =============================================================================
# Verifies the tools this monorepo's install-time scripts depend on, and
# auto-fixes what can be fixed WITHOUT sudo (currently: Python 3.12 via uv,
# for hosts where apt doesn't package it -- this happens on brand-new Ubuntu
# releases before deadsnakes has published builds for that codename, which is
# how this script came to exist: apt on Ubuntu 26.04 ships python3.14 as
# default and has no python3.12 package at all yet).
#
# Anything that needs sudo (docker, git, kind, kubectl) is never installed
# silently -- the exact command is printed so the human can review and run it,
# consistent with this repo's rule of not taking privileged actions without
# an explicit, visible step. See CLAUDE.md section 0.
#
# Usage:
#   ./scripts/check-prerequisites.sh        # standalone check, human-readable
#   source scripts/check-prerequisites.sh   # sourced by setup.sh; also sets
#                                            # $PYTHON312_BIN when resolved
#
# Exit/return status: 0 unless docker, docker compose, or git is missing --
# those three are the only tools setup.sh itself cannot proceed without.
# kind/kubectl (K8s-deploy-path only), python3.12 (certifier local-dev-only),
# node/go (frontend/Go-work-only) are checked and reported but never block.
# =============================================================================

# --- minimum versions (mirrors CLAUDE.md section 6 "Prerequisites") --------
MIN_DOCKER="28.0.0"
MIN_KIND="0.20.0"
MIN_KUBECTL="1.27.0"
MIN_NODE="20.0.0"

# Reuse the caller's colors/helpers when sourced from a script that already
# defines them (setup.sh); define our own otherwise so this also works run
# standalone.
if ! declare -F ok >/dev/null 2>&1; then
    BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'
    say()  { echo -e "$*"; }
    ok()   { echo -e "${GREEN}✓${NC} $*"; }
    warn() { echo -e "${YELLOW}!${NC} $*"; }
fi
err()  { echo -e "${RED}✗${NC} $*" >&2; }

_extract_ver() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "$1" | head -1; }

# version_ge A B → true if version A >= version B (dotted numeric compare via sort -V)
version_ge() {
    [[ "$1" == "$2" ]] && return 0
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

CHECK_FAILED=0
PYTHON312_BIN=""

echo
echo -e "${CYAN}--- Checking prerequisites ---${NC}"

# --- Docker Engine + Compose v2 (hard required) -------------------------------
if ! command -v docker >/dev/null 2>&1; then
    err "docker not found (required)."
    warn "  Ubuntu/Debian:  sudo apt update && sudo apt install -y docker.io && sudo usermod -aG docker \$USER   (then log out/in)"
    warn "  Or: install Docker Desktop with WSL2 integration if running under WSL."
    CHECK_FAILED=1
else
    _dv="$(_extract_ver "$(docker --version 2>/dev/null)")"
    if [[ -n "$_dv" ]] && version_ge "$_dv" "$MIN_DOCKER"; then
        ok "docker ${_dv}"
    else
        warn "docker ${_dv:-unknown} found, but ${MIN_DOCKER}+ is recommended (CLAUDE.md §6). Continuing anyway."
    fi
    if ! docker compose version >/dev/null 2>&1; then
        err "'docker compose' (v2 plugin) not found -- this repo's Compose files require v2 syntax."
        warn "  sudo apt update && sudo apt install -y docker-compose-plugin"
        CHECK_FAILED=1
    else
        ok "docker compose $(_extract_ver "$(docker compose version)")"
    fi
    if ! docker ps >/dev/null 2>&1; then
        warn "docker is installed but not reachable by this user (permission denied, or daemon not running)."
        warn "  If you just ran 'usermod -aG docker \$USER', log out and back in (or: newgrp docker)."
    fi
fi

# --- git (hard required) -------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
    err "git not found (required)."
    warn "  sudo apt update && sudo apt install -y git"
    CHECK_FAILED=1
else
    ok "git $(_extract_ver "$(git --version)")"
fi

# --- Python 3.12 (certifier local dev only -- not required for Compose/K8s
# deploy paths, which run certifier from the prebuilt agentcert/certifier
# image; never blocks setup.sh) --------------------------------------------
# apt only packages 3.12 directly on some Ubuntu releases (e.g. 24.04 ships it
# as the system default). On releases where apt's python3 has moved past 3.12
# (26.04 defaults to 3.14) and deadsnakes hasn't published builds for that
# codename yet, there is no apt path to 3.12 at all. uv sidesteps this
# entirely: it ships official python-build-standalone binaries independent of
# any OS package manager, needs no sudo, and is pinned to an exact version
# rather than whatever apt happens to carry.
if command -v python3.12 >/dev/null 2>&1; then
    PYTHON312_BIN="$(command -v python3.12)"
    ok "python3.12 $(_extract_ver "$(python3.12 --version 2>&1)") (${PYTHON312_BIN})"
elif command -v uv >/dev/null 2>&1 && uv python find 3.12 >/dev/null 2>&1; then
    PYTHON312_BIN="$(uv python find 3.12)"
    ok "python3.12 (uv-managed) ${PYTHON312_BIN}"
else
    warn "python3.12 not found (needed only for certifier local dev outside Docker -- CLAUDE.md §6)."
    read -rp "  Bootstrap Python 3.12 via uv now? No sudo required. [Y/n]: " _py_ans
    if [[ ! "${_py_ans,,}" =~ ^n ]]; then
        if ! command -v uv >/dev/null 2>&1; then
            curl -LsSf https://astral.sh/uv/install.sh | sh
            # shellcheck disable=SC1091
            source "${HOME}/.local/bin/env" 2>/dev/null || export PATH="${HOME}/.local/bin:${PATH}"
        fi
        uv python install 3.12
        source "${HOME}/.local/bin/env" 2>/dev/null || export PATH="${HOME}/.local/bin:${PATH}"
        if command -v python3.12 >/dev/null 2>&1; then
            PYTHON312_BIN="$(command -v python3.12)"
            ok "python3.12 $(_extract_ver "$(python3.12 --version 2>&1)") installed via uv"
        else
            warn "uv install ran but python3.12 still not resolvable on PATH -- open a new shell and re-run."
        fi
    else
        warn "Skipped. Re-run this check (or scripts/setup.sh) later to bootstrap it when you need certifier local dev."
    fi
    unset _py_ans
fi

# --- kind + kubectl (only needed for the Kubernetes deploy path; never blocks) -
if ! command -v kind >/dev/null 2>&1; then
    warn "kind not found -- only needed if you plan to deploy to Kubernetes (skip if Compose-only)."
    warn "  curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64 && chmod +x kind && sudo mv kind /usr/local/bin/"
else
    _kv="$(_extract_ver "$(kind version 2>/dev/null)")"
    if [[ -n "$_kv" ]] && version_ge "$_kv" "$MIN_KIND"; then
        ok "kind ${_kv}"
    else
        warn "kind ${_kv:-unknown} found, but ${MIN_KIND}+ is recommended."
    fi
fi

if ! command -v kubectl >/dev/null 2>&1; then
    warn "kubectl not found -- only needed if you plan to deploy to Kubernetes (skip if Compose-only)."
    warn "  curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\" && chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
else
    _kubv="$(_extract_ver "$(kubectl version --client 2>/dev/null)")"
    if [[ -n "$_kubv" ]] && version_ge "$_kubv" "$MIN_KUBECTL"; then
        ok "kubectl ${_kubv}"
    else
        warn "kubectl ${_kubv:-unknown} found, but ${MIN_KUBECTL}+ is recommended."
    fi
fi

# --- Optional: Node.js (web frontend work only) --------------------------------
if command -v node >/dev/null 2>&1; then
    _nv="$(_extract_ver "$(node --version)")"
    if [[ -n "$_nv" ]] && version_ge "$_nv" "$MIN_NODE"; then
        ok "node ${_nv}"
    else
        warn "node ${_nv:-unknown} found, but ${MIN_NODE}+ is needed for the web frontend (sass@1.102.0 fails on Node 18). Not required otherwise."
    fi
else
    say "${DIM}  (node not found -- only needed for AgentCert/chaoscenter/web frontend work)${NC}"
fi

# --- Optional: Go (AgentCert backend work only) --------------------------------
if command -v go >/dev/null 2>&1; then
    ok "go $(_extract_ver "$(go version)")"
else
    say "${DIM}  (go not found -- only needed for AgentCert backend Go work)${NC}"
fi

echo -e "${CYAN}-------------------------------${NC}"
if [[ $CHECK_FAILED -eq 1 ]]; then
    err "docker, docker compose, and git are required for any setup path. Install the missing ones above, then re-run."
    unset _dv _kv _kubv _nv
    return 1 2>/dev/null || exit 1
fi
ok "All required prerequisites satisfied."
echo
unset _dv _kv _kubv _nv
