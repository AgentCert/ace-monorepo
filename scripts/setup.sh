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
#
#   ./scripts/setup.sh --rootless-docker            (combine with --setup, the default)
#   ./scripts/setup.sh --restart --rootless-docker
#
# Modifier flag, not a standalone action: bootstraps a private, per-user
# rootless Docker daemon and switches the Docker CLI's default context to it
# — so this checkout's containers/images/volumes/KinD cluster land under
# $HOME/.local/share/docker instead of the shared host daemon's data-root —
# then falls straight through into the wizard (or --restart) under that new
# context, no separate follow-up invocation needed. No sudo, and zero impact
# on other users' containers on this shared host — see CLAUDE.md section 6,
# "Personal rootless Docker (avoiding the shared host's data-root)".
#
# Plain `./scripts/setup.sh` (--setup, no flag) asks this as a y/N question
# instead, right at the start, before anything else. `--restart` never asks —
# it skips all prompts by design — so pass the flag explicitly there.
#
#   ./scripts/setup.sh --agent=<name>
#   ./scripts/setup.sh --restart --agent=<name>
#
# Sets BENCHMARK_AGENT in .env — which agent (a subfolder of agents/, e.g.
# flash-agent, ciso-agent, sre-agent, sre-agent-crewai) `scripts/ace-bench.py`
# should target. Pre-answers the interactive "Agent to benchmark" question
# asked during --setup; combine with --restart to switch it with no other
# prompts. Invalid names (anything not a folder under agents/) fail fast with
# the list of valid choices.
# =============================================================================

# `pwd -P` (not plain `pwd`) is required here: plain `pwd` returns whatever
# symlink alias the CWD was reached through, while the KinD ownership marker
# (assert_kind_cluster_ownership below) records/compares REPO_ROOT as a
# literal string. On hosts where the repo is reachable through more than one
# symlinked path (e.g. /home/<user>/... symlinked to
# /Innovation/home/<user>/...), running this script through a different alias
# than whatever created the cluster would make that comparison see two
# spellings of the SAME checkout and wrongly refuse it as foreign. See the
# matching fix/comment in scripts/start-local-services.sh.
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"
ENV_FILE="${REPO_ROOT}/.env"
EXAMPLE_FILE="${REPO_ROOT}/.env.example"

# Force UTF-8 as Python's default text encoding (PEP 540) for every embedded
# `${SETUP_PYTHON} - <<'PY'` heredoc below. Without this, Python on Windows opens
# files (.env, litellm_config.yaml, ...) using the OS codepage (e.g. cp1252)
# instead of UTF-8, and decoding fails with UnicodeDecodeError on this
# repo's box-drawing/arrow characters (→ ─ ▸ ✓) the moment any open(path)
# call reads a file containing them. No-op on Linux/Mac, which already
# default to UTF-8.
export PYTHONUTF8=1
# Third-party packages in setup venv can emit SyntaxWarning for legacy
# escape sequences (e.g. '\s') that are non-fatal and noise for this workflow.
export PYTHONWARNINGS="${PYTHONWARNINGS:-ignore::SyntaxWarning}"

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'

say()  { echo -e "$*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }

# --- Prerequisite check & self-heal ------------------------------------------
# Runs unconditionally (both --setup and --restart), before anything else
# touches .env, so a fresh host/VM missing tools this script depends on is
# guided to a working state (or auto-fixed, for what can be fixed without
# sudo) instead of failing deep into the wizard with an opaque error. See
# scripts/check-prerequisites.sh for what's checked and why.
export ACE_PREREQ_FULL_DEP_AUDIT=1
export ACE_PREREQ_FAIL_ON_DEP_ISSUES="${ACE_PREREQ_FAIL_ON_DEP_ISSUES:-0}"
export ACE_PREREQ_PYTHON_BIN="${REPO_ROOT}/.venv/bin/python"
# shellcheck source=scripts/check-prerequisites.sh
source "${SCRIPT_DIR}/check-prerequisites.sh"

# Use the workspace venv interpreter for every setup-time Python snippet when
# available, so setup follows the same import environment developers use.
SETUP_PYTHON="${REPO_ROOT}/.venv/bin/python"
if [[ -x "${SETUP_PYTHON}" ]]; then
    ok "Using workspace venv Python for setup helpers: ${SETUP_PYTHON}"
elif command -v python3 >/dev/null 2>&1; then
    SETUP_PYTHON="$(command -v python3)"
    warn "Workspace venv Python not found at ${REPO_ROOT}/.venv/bin/python; falling back to ${SETUP_PYTHON}."
else
    echo "ERROR: no Python interpreter available for setup helper scripts (expected ${REPO_ROOT}/.venv/bin/python or python3 on PATH)." >&2
    exit 1
fi

# --- prep .env -------------------------------------------------------------
# Moved ahead of the rootless Docker bootstrap (below) so it can read/write
# .env (DOCKER_HOST_SOCK) even on a brand-new checkout that has never run the
# full wizard yet.
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

# current value of KEY in .env (empty if unset). Defined here (ahead of
# --rootless-docker below) so that action can read/write .env too.
cur() { grep -m1 "^$1=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true; }

# set_env KEY VALUE — set or replace a key in .env. Defined early because
# host-local setup choices (rootless Docker, temp directories, ports) are
# persisted before the later deployment helper section is reached.
set_env() {
    local k="$1" v="$2"
    if grep -qE "^${k}=" "${ENV_FILE}"; then
        "${SETUP_PYTHON}" - "${ENV_FILE}" "$k" "$v" <<'PY'
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

# Kind cluster names (and every Docker/K8s resource name derived from
# ACE_INSTANCE_NAME) must be RFC-1123 safe: lowercase alphanumeric + hyphen
# only, short enough that "agentcert-<name>-control-plane" fits the ~64-char
# Linux hostname limit kind's node containers use. A raw `id -un` (or a
# hand-edited .env value) can contain other characters or run long;
# sanitize instead of letting `kind create cluster` fail on it.
sanitize_instance_name() {
    local clean
    clean="$(printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9-' '-' \
        | tr -s '-' \
        | sed -e 's/^-*//' -e 's/-*$//' \
        | cut -c1-20 \
        | sed -e 's/-*$//')"
    echo "${clean:-instance}"
}

report_preserved_langfuse_traces() {
    command -v docker >/dev/null 2>&1 || return 0
    local inst; inst="$(cur ACE_INSTANCE_NAME)"
    [[ -z "${inst}" ]] && return 0

    local -a lf_volumes=()
    while IFS= read -r _lfv; do
        [[ -n "${_lfv}" ]] && lf_volumes+=("${_lfv}")
    done < <(docker volume ls --format '{{.Name}}' 2>/dev/null \
        | grep -E "^(ace-${inst}|ace-langfuse-${inst})_langfuse_(postgres_data|clickhouse_data|clickhouse_logs|minio_data|redis_data)$" \
        | sort || true)
    [[ ${#lf_volumes[@]} -eq 0 ]] && return 0

    echo
    echo -e "${CYAN}▸ Preserved Langfuse traces${NC}"
    echo -e "  ${DIM}Found ${#lf_volumes[@]} Langfuse data volume(s) for ACE_INSTANCE_NAME=${inst}.${NC}"
    echo -e "  ${DIM}The next local Langfuse compose bring-up reattaches these volumes automatically, so prior traces should reappear.${NC}"
    for _lfv in "${lf_volumes[@]}"; do
        echo -e "    ${DIM}• ${_lfv}${NC}"
    done
    unset _lfv lf_volumes inst
}

# --- Available agents (subfolders of agents/, excluding the harness/ dir) ---
# Single source of truth for "which agent can be benchmarked" — matches what
# `python scripts/ace-bench.py <agent>` accepts (agents/harness/<agent>/bench.yaml
# must also exist, but agents/<name>/ is the human-facing list). Recomputed
# every run (cheap directory listing) so a newly added agent folder shows up
# with no script change needed.
discover_agents() {
    local d b
    for d in "${REPO_ROOT}"/agents/*/; do
        b="$(basename "$d")"
        [[ "$b" == "harness" ]] && continue
        echo "$b"
    done | sort
}
mapfile -t AVAILABLE_AGENTS < <(discover_agents)

# agent_is_available NAME — 0 if NAME is one of AVAILABLE_AGENTS, else 1
agent_is_available() {
    local want="$1" a
    for a in "${AVAILABLE_AGENTS[@]}"; do
        [[ "$a" == "$want" ]] && return 0
    done
    return 1
}

# --- Invocation mode ----------------------------------------------------------
#   --setup            (default) full first-time wizard: prompts, writes .env, deploys
#   --restart          skip all prompts and .env edits; just re-apply the stack
#   --rootless-docker   modifier, see header comment above; runs before --setup/--restart, does not exit
#   --agent=<name>      pre-answers "which agent to benchmark" (BENCHMARK_AGENT in .env);
#                       name must be a subfolder of agents/ (see AVAILABLE_AGENTS above).
#                       Combine with --restart for a quick switch with no other prompts:
#                         ./scripts/setup.sh --restart --agent=ciso-agent
#   --allow-build-cache opt-out of the --no-cache forced on every local image build (see
#                       _build_one_entry() below). Local builds are --no-cache by default
#                       because BuildKit was twice observed silently replaying a stale
#                       `COPY .`/`go build` layer across --local-build runs even when the
#                       source had genuinely changed, shipping old code with a fresh-looking
#                       build timestamp and no error (2026-08-25, see
#                       OPEN_WEIGHT_CERTIFICATION_HANDOFF.md §82). --no-cache is the only
#                       reliable fix found so far, but it's real overhead every time: ~3m30s
#                       wall-clock for a full 12-image local build (measured on this host,
#                       parallelism=6) vs. near-instant when Docker's normal cache applies
#                       cleanly. Pass --allow-build-cache for a fast inner dev loop when
#                       you're confident the change you're iterating on doesn't risk hitting
#                       that bug (e.g. you're bisecting something unrelated to the image
#                       you're rebuilding) — it restores normal Docker layer caching. Do not
#                       default to this for a build whose result matters (verifying an actual
#                       fix landed, cutting a build to hand off, etc.).
#   --record-image-baseline  resolve the current registry digests of the monitored
#                       third-party service images and (re)write deploy/image-baseline.tsv,
#                       then exit. Run this once after confirming a new set of pinned
#                       versions works, so fresh checkouts on other hosts compare against
#                       it. Every normal run also warns when a floating tag (:latest, a
#                       bare major, no tag) has drifted since this host's last setup —
#                       silence that with ACE_SKIP_IMAGE_DRIFT_CHECK=1.
SETUP_MODE="setup"
BUILD_MODE="prompt"   # "local" pre-answers the build prompt; "prompt" = ask interactively
ROOTLESS_DOCKER_ACTION=0
ALLOW_BUILD_CACHE=0
AGENT_FLAG=""
RECORD_IMAGE_BASELINE=0   # --record-image-baseline: refresh deploy/image-baseline.tsv from what this host resolves now
for _arg in "$@"; do
    case "$_arg" in
        --restart)            SETUP_MODE="restart" ;;
        --setup)               SETUP_MODE="setup"   ;;
        --local-build)         BUILD_MODE="local"   ;;
        --rootless-docker)     ROOTLESS_DOCKER_ACTION=1 ;;
        --allow-build-cache)   ALLOW_BUILD_CACHE=1 ;;
        --agent=*)             AGENT_FLAG="${_arg#--agent=}" ;;
        --record-image-baseline) RECORD_IMAGE_BASELINE=1 ;;
    esac
done
unset _arg

# --agent=<name> is applied immediately and unconditionally (before the
# --setup/--restart branch below), so it works as a standalone quick-switch
# even under a plain `--restart` that would otherwise skip every prompt.
if [[ -n "${AGENT_FLAG}" ]]; then
    if ! agent_is_available "${AGENT_FLAG}"; then
        echo "ERROR: --agent=${AGENT_FLAG} is not a known agent." >&2
        echo "Available agents (subfolders of agents/): ${AVAILABLE_AGENTS[*]}" >&2
        exit 1
    fi
    if grep -q '^BENCHMARK_AGENT=' "${ENV_FILE}" 2>/dev/null; then
        sed -i "s|^BENCHMARK_AGENT=.*|BENCHMARK_AGENT=${AGENT_FLAG}|" "${ENV_FILE}"
    else
        echo "BENCHMARK_AGENT=${AGENT_FLAG}" >> "${ENV_FILE}"
    fi
    ok "BENCHMARK_AGENT set to '${AGENT_FLAG}' (via --agent)"
fi

# --- Rootless Docker bootstrap (opt-in modifier — runs before --setup/--restart) --
# Sets up a private, per-user Docker daemon via dockerd-rootless-setuptool.sh
# and switches the CLI's default context to it. Rationale: the shared system
# dockerd on this host backs EVERY user's containers/images/volumes with one
# data-root (typically /var/lib/docker on the host's root filesystem, not
# /Innovation — verify with `docker info | grep "Docker Root Dir"`).
# Relocating that data-root means stopping the daemon for the whole host,
# which stops every other user's running containers too — see CLAUDE.md
# section 0. Rootless mode sidesteps that: a private daemon, socket, and
# data-root scoped to this OS user (defaults to $HOME/.local/share/docker),
# set up and torn down with zero sudo and zero effect on the shared daemon or
# anyone else's resources. Docker CLI context selection (`docker context
# use`) persists in ~/.docker/config.json, so every later `docker`/`kind`/
# `docker compose` invocation — from this script, start-local-services.sh,
# compose-up-guard.sh, or a fresh shell — transparently targets the rootless
# daemon afterward.
#
# One thing context-switching does NOT cover: docker-compose.yml's
# cluster-init service bind-mounts the Docker socket by host path
# (`/var/run/docker.sock`) so `kind create` can run inside that container.
# A bind-mount source is a literal filesystem path, not context-aware — left
# alone it would keep resolving to the SHARED root daemon's socket even after
# `docker context use rootless`, silently defeating the whole point. This
# block writes the rootless daemon's real socket path to .env as
# DOCKER_HOST_SOCK, and docker-compose.yml reads that instead of hardcoding
# the path (see the cluster-init service).
#
# Also generates a personal CDI (Container Device Interface) GPU spec under
# $HOME/.config/cdi and a per-user ~/.config/docker/daemon.json pointing only
# at that directory, when an NVIDIA GPU + nvidia-ctk are present — this is
# what lets Ollama's `devices: ["nvidia.com/gpu=all"]` request (see
# docker-compose.yml) resolve under the rootless daemon. Deliberately never
# touches the shared /etc/cdi or /etc/nvidia-container-runtime/config.toml —
# those affect every other user's containers on this host too.
#
# Idempotent: safe to re-run; skips straight to the context switch if the
# rootless daemon is already installed and running.
#
# When --rootless-docker wasn't passed on the command line, the first-time
# wizard (--setup) asks this as a plain y/N question instead — before
# anything else, so a "yes" here still runs ahead of the .env backfills below
# (KIND_CLUSTER_NAME detection etc.) just like the flag path does. --restart
# never asks (it skips all prompts by design); pass the flag explicitly if
# you want rootless there.
if [[ "${ROOTLESS_DOCKER_ACTION}" -ne 1 && "${SETUP_MODE}" == "setup" ]]; then
    echo
    echo -e "${BOLD}Personal rootless Docker?${NC} ${DIM}(sudo-free daemon isolated from other users on this shared host — see CLAUDE.md §6)${NC}"
    echo -ne "  Set up and use rootless Docker for this checkout? ${DIM}[y/N]${NC}: "
    read -r _rootless_ans
    case "${_rootless_ans}" in
        [Yy]*) ROOTLESS_DOCKER_ACTION=1 ;;
    esac
    unset _rootless_ans
fi

if [[ "${ROOTLESS_DOCKER_ACTION}" -eq 1 ]]; then
    echo
    echo -e "${CYAN}=======================================================${NC}"
    echo -e "${CYAN}  Rootless Docker setup (personal, sudo-free)${NC}"
    echo -e "${CYAN}=======================================================${NC}"
    echo

    if ! command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
        echo "ERROR: dockerd-rootless-setuptool.sh not found (docker-ce-rootless-extras package)." >&2
        echo "ERROR: this is a one-time host-admin install (needs sudo): sudo apt install -y docker-ce-rootless-extras" >&2
        echo "ERROR: ask a host admin, then re-run ./scripts/setup.sh --rootless-docker" >&2
        exit 1
    fi
    if ! grep -q "^$(id -un):" /etc/subuid 2>/dev/null || ! grep -q "^$(id -un):" /etc/subgid 2>/dev/null; then
        echo "ERROR: no subuid/subgid range provisioned for $(id -un) (required for rootless mode)." >&2
        echo "ERROR: ask a host admin to run: sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 $(id -un)" >&2
        exit 1
    fi
    # newuidmap/newgidmap (uidmap package) are a separate, also-sudo-required
    # prerequisite from docker-ce-rootless-extras above — RootlessKit needs them
    # to apply the subuid/subgid mapping just verified. Without this check,
    # dockerd-rootless-setuptool.sh install (below) fails on it deep inside the
    # third-party tool with a raw, non-ACE-styled error instead of the clean
    # early-exit pattern used by the other checks here.
    if ! command -v newuidmap >/dev/null 2>&1 || ! command -v newgidmap >/dev/null 2>&1; then
        echo "ERROR: newuidmap/newgidmap not found (uidmap package) — required for rootless Docker." >&2
        echo "ERROR: this is a one-time host-admin install (needs sudo): sudo apt install -y uidmap" >&2
        echo "ERROR: ask a host admin, then re-run ./scripts/setup.sh --rootless-docker" >&2
        exit 1
    fi

    # MTU fix, checked/applied on EVERY run (not just first install), matching
    # the linger pattern below. dockerd-rootless.sh's own default for the
    # slirp4netns network driver is an unconditional 65520, regardless of the
    # host's actual interface MTU (see /usr/bin/dockerd-rootless.sh, "if [ -z
    # "$mtu" ]" block). That default assumes slirp4netns's userspace
    # fragmentation absorbs the mismatch transparently; in practice, on any
    # network where routers/firewalls drop ICMP "fragmentation needed"
    # messages (common), TCP flows through the tap device silently blackhole
    # instead of erroring at the real 1500-ish MTU hop, rather than just
    # running slower. Symptom: large image/model layers complete (masked by
    # retries/reconnects), a small layer or manifest request hangs
    # indefinitely mid-pull. Detected fresh from the live default route on
    # every run so this stays correct if the checkout (or this script) moves
    # to a different host/network — never hardcode a specific MTU value here.
    _rootless_iface="$(ip -o route get 8.8.8.8 2>/dev/null | grep -oP '(?<=dev )\S+' | head -1 || true)"
    _rootless_mtu="$(ip -o link show dev "${_rootless_iface}" 2>/dev/null | grep -oP '(?<=mtu )\d+' | head -1 || true)"
    _rootless_mtu="${_rootless_mtu:-1500}"
    _rootless_dropin_dir="${HOME}/.config/systemd/user/docker.service.d"
    _rootless_dropin="${_rootless_dropin_dir}/10-ace-mtu.conf"
    _rootless_dropin_desired="[Service]
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_MTU=${_rootless_mtu}
"
    _rootless_mtu_changed=0
    if [[ ! -f "${_rootless_dropin}" ]] || [[ "$(cat "${_rootless_dropin}" 2>/dev/null)" != "${_rootless_dropin_desired}" ]]; then
        mkdir -p "${_rootless_dropin_dir}"
        printf '%s' "${_rootless_dropin_desired}" > "${_rootless_dropin}"
        _rootless_mtu_changed=1
        systemctl --user daemon-reload
        say "Pinned rootless Docker MTU to ${_rootless_mtu} (detected from ${_rootless_iface:-default route}) — overrides dockerd-rootless.sh's slirp4netns default of 65520, which blackholes on networks that drop ICMP frag-needed."
    fi
    unset _rootless_dropin_desired

    if systemctl --user is-active --quiet docker 2>/dev/null; then
        if [[ "${_rootless_mtu_changed}" -eq 1 ]]; then
            say "Restarting rootless Docker to apply the corrected MTU..."
            systemctl --user restart docker
            for _i in $(seq 1 30); do
                systemctl --user is-active --quiet docker 2>/dev/null && break
                sleep 1
            done
            unset _i
            ok "Rootless Docker restarted with MTU=${_rootless_mtu}"
        else
            ok "Rootless Docker already running for $(id -un)"
        fi
    else
        say "Installing rootless Docker for $(id -un) — no sudo, doesn't touch the shared daemon..."
        # --force: dockerd-rootless-setuptool.sh refuses by default when a
        # rootful daemon is already reachable, assuming that's a mistake. On
        # this shared host it's the opposite of a mistake — the rootful
        # daemon stays up for every other user's checkout, and this rootless
        # one is meant to run alongside it, not replace it. Without --force
        # this fails identically on every rerun since rootful Docker is
        # always present here, not just on a first attempt.
        # install --force regenerates the base docker.service unit but never
        # touches docker.service.d/ drop-ins, so the MTU pin above survives it.
        dockerd-rootless-setuptool.sh install --force
        systemctl --user enable --now docker
        ok "Rootless Docker installed and running (MTU=${_rootless_mtu})"
    fi
    unset _rootless_iface _rootless_mtu _rootless_mtu_changed

    # Linger is a hard requirement, not a nice-to-have: without it, the rootless
    # daemon -- and everything running under it (KinD nodes, Ollama) -- dies the
    # moment this login session ends, silently killing anything mid-run (e.g. an
    # N=30 certification sweep). Verified on EVERY run (not just first install),
    # so a host where a previous enable-linger attempt silently failed doesn't
    # keep reporting success on every subsequent re-run.
    if command -v loginctl >/dev/null 2>&1 && ! loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q "Linger=yes"; then
        loginctl enable-linger "$(id -un)" 2>/dev/null || true
        if ! loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q "Linger=yes"; then
            echo "ERROR: linger is not enabled for $(id -un) — the rootless daemon would stop at logout, silently killing anything running under it (KinD cluster, Ollama, an in-progress N=30 run)." >&2
            echo "ERROR: this is a one-time host-admin step (needs sudo): sudo loginctl enable-linger $(id -un)" >&2
            echo "ERROR: ask a host admin, then re-run ./scripts/setup.sh --rootless-docker" >&2
            exit 1
        fi
    fi

    # Pinned containerd (personal, not the system package) — works around a
    # confirmed upstream regression in containerd >=2.3.0: the shim bootstrap
    # handshake leaks a raw, un-decoded protobuf Address message where a plain
    # "unix://..." string is expected, so EVERY container fails to start with
    # "failed to create TTRPC connection: unsupported protocol:Yunix" (the
    # "Y" is literally a protobuf length-prefix byte, 0x59, misread as text —
    # not corruption). Reported independently against containerd 2.3.0-2.3.3
    # on Arch/EndeavourOS/Gentoo; documented workaround is the 2.2.x line.
    # There is no newer fixed release to upgrade to yet.
    #
    # dockerd resolves "containerd" (which in turn resolves
    # "containerd-shim-runc-v2") via a plain $PATH lookup — visible in any
    # running rootless daemon's process tree as `containerd --config <path>`
    # with no absolute path. That means this can be fixed for ONLY this
    # personal daemon by putting a matched, known-good containerd + shim pair
    # ahead of /usr/bin in this unit's PATH, via a drop-in that sorts after
    # 10-ace-mtu.conf (systemd: the later Environment=KEY=... for a given key
    # wins). The system containerd.io package — and therefore the SHARED root
    # daemon every other user on this host relies on — is never touched.
    # Self-healing: if the system containerd is later fixed/updated past the
    # buggy range, this removes its own pin and reverts to it automatically.
    _civ_pin_version="2.2.6"
    _civ_arch="$(uname -m)"; case "${_civ_arch}" in x86_64) _civ_arch="amd64" ;; aarch64) _civ_arch="arm64" ;; esac
    _civ_pin_dir="${HOME}/.local/share/ace-rootless-docker/containerd-pin"
    _civ_sys_ver="$(containerd --version 2>/dev/null | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    _civ_sys_major="${_civ_sys_ver%%.*}"
    _civ_sys_rest="${_civ_sys_ver#*.}"
    _civ_sys_minor="${_civ_sys_rest%%.*}"
    _civ_dropin_dir="${HOME}/.config/systemd/user/docker.service.d"
    _civ_dropin="${_civ_dropin_dir}/20-ace-containerd-pin.conf"

    if [[ -n "${_civ_sys_major}" && -n "${_civ_sys_minor}" && "${_civ_sys_major}" -eq 2 && "${_civ_sys_minor}" -ge 3 ]]; then
        _civ_dropin_desired="[Service]
Environment=PATH=${_civ_pin_dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
"
        _civ_need_restart=0
        if [[ ! -x "${_civ_pin_dir}/bin/containerd" ]] || [[ "$("${_civ_pin_dir}/bin/containerd" --version 2>/dev/null | grep -oP 'v\K[0-9.]+' | head -1)" != "${_civ_pin_version}" ]]; then
            say "System containerd is ${_civ_sys_ver} — affected by a confirmed upstream shim-bootstrap regression (breaks ALL container starts, including KinD). Pinning a personal containerd ${_civ_pin_version} for this rootless daemon only (system package untouched)..."
            mkdir -p "${_civ_pin_dir}/bin"
            _civ_tmp="$(mktemp -d)"
            _civ_asset="containerd-${_civ_pin_version}-linux-${_civ_arch}.tar.gz"
            _civ_url="https://github.com/containerd/containerd/releases/download/v${_civ_pin_version}/${_civ_asset}"
            if curl -fsSL -o "${_civ_tmp}/${_civ_asset}" "${_civ_url}" \
               && curl -fsSL -o "${_civ_tmp}/${_civ_asset}.sha256sum" "${_civ_url}.sha256sum" \
               && (cd "${_civ_tmp}" && sha256sum -c "${_civ_asset}.sha256sum"); then
                tar -xzf "${_civ_tmp}/${_civ_asset}" -C "${_civ_tmp}"
                install -m 755 "${_civ_tmp}/bin/containerd" "${_civ_tmp}/bin/containerd-shim-runc-v2" "${_civ_pin_dir}/bin/"
                ok "Downloaded and checksum-verified containerd ${_civ_pin_version} (${_civ_arch}) to ${_civ_pin_dir}/bin"
            else
                warn "Failed to download/verify pinned containerd ${_civ_pin_version} — leaving system containerd ${_civ_sys_ver} in place. KinD cluster creation under this rootless daemon will likely fail with 'unsupported protocol:Yunix' until this is resolved."
            fi
            rm -rf "${_civ_tmp}"
            unset _civ_tmp _civ_asset _civ_url
        fi
        if [[ -x "${_civ_pin_dir}/bin/containerd" ]]; then
            if [[ ! -f "${_civ_dropin}" ]] || [[ "$(cat "${_civ_dropin}" 2>/dev/null)" != "${_civ_dropin_desired}" ]]; then
                mkdir -p "${_civ_dropin_dir}"
                printf '%s' "${_civ_dropin_desired}" > "${_civ_dropin}"
                _civ_need_restart=1
                systemctl --user daemon-reload
            fi
            if [[ "${_civ_need_restart}" -eq 1 ]]; then
                say "Restarting rootless Docker to pick up pinned containerd ${_civ_pin_version}..."
                systemctl --user restart docker
                for _i in $(seq 1 30); do
                    systemctl --user is-active --quiet docker 2>/dev/null && break
                    sleep 1
                done
                unset _i
                ok "Rootless Docker now running on personal containerd ${_civ_pin_version} (system containerd.io ${_civ_sys_ver} untouched, shared daemon unaffected)"
            else
                ok "Rootless Docker already pinned to containerd ${_civ_pin_version}"
            fi
        fi
        unset _civ_dropin_desired _civ_need_restart
    elif [[ -f "${_civ_dropin}" ]]; then
        say "System containerd ${_civ_sys_ver} is no longer in the buggy >=2.3.0 range — removing this checkout's containerd pin and reverting to it..."
        rm -f "${_civ_dropin}"
        systemctl --user daemon-reload
        systemctl --user restart docker
        for _i in $(seq 1 30); do
            systemctl --user is-active --quiet docker 2>/dev/null && break
            sleep 1
        done
        unset _i
        ok "Reverted to system containerd ${_civ_sys_ver}"
    fi
    unset _civ_pin_version _civ_arch _civ_pin_dir _civ_sys_ver _civ_sys_major _civ_sys_minor _civ_sys_rest _civ_dropin_dir _civ_dropin

    docker context use rootless >/dev/null
    ok "Docker CLI default context switched to 'rootless' — persists across shells."
    say "   (switch back any time with: docker context use default)"

    _rootless_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "${HOME}/.local/share/docker")"
    echo
    say "  Data root: ${_rootless_root}"
    df -h "${_rootless_root}" 2>/dev/null | tail -1
    unset _rootless_root

    # DOCKER_HOST_SOCK: real host-side path to the rootless daemon's socket.
    # docker-compose.yml's cluster-init service bind-mounts this instead of a
    # hardcoded /var/run/docker.sock — see comment above.
    echo
    _rootless_sock="$(docker context inspect rootless --format '{{.Endpoints.docker.Host}}' 2>/dev/null)"
    _rootless_sock="${_rootless_sock#unix://}"
    if [[ -n "${_rootless_sock}" ]]; then
        if grep -q '^DOCKER_HOST_SOCK=' "${ENV_FILE}" 2>/dev/null; then
            sed -i "s|^DOCKER_HOST_SOCK=.*|DOCKER_HOST_SOCK=${_rootless_sock}|" "${ENV_FILE}"
        else
            echo "DOCKER_HOST_SOCK=${_rootless_sock}" >> "${ENV_FILE}"
        fi
        ok "Set DOCKER_HOST_SOCK=${_rootless_sock} in .env — cluster-init's kind create will now target this daemon, not the shared root one."
    else
        warn "Could not detect the rootless socket path automatically — DOCKER_HOST_SOCK left unset (docker-compose.yml falls back to /var/run/docker.sock, the SHARED root daemon)."
        warn "Set it manually: check 'docker context inspect rootless --format \"{{.Endpoints.docker.Host}}\"' and add DOCKER_HOST_SOCK=<path> to .env"
    fi
    unset _rootless_sock

    # Personal CDI GPU spec (opt-in, only if an NVIDIA GPU + nvidia-ctk exist).
    # Writes only under $HOME — never touches /etc/cdi or
    # /etc/nvidia-container-runtime/config.toml (shared, affects other users).
    echo
    if command -v nvidia-ctk >/dev/null 2>&1 && compgen -G "/dev/nvidia[0-9]*" >/dev/null 2>&1; then
        say "NVIDIA GPU detected — setting up a personal CDI device spec (needed for Ollama GPU access under rootless)..."
        mkdir -p "${HOME}/.config/cdi" "${HOME}/.config/docker"
        if nvidia-ctk cdi generate --output="${HOME}/.config/cdi/nvidia.yaml" >/dev/null 2>&1; then
            ok "Generated ${HOME}/.config/cdi/nvidia.yaml"
            _daemon_json="${HOME}/.config/docker/daemon.json"
            _before="$(cat "${_daemon_json}" 2>/dev/null || true)"
            "${SETUP_PYTHON}" - "${_daemon_json}" "${HOME}/.config/cdi" <<'PY'
import json, os, sys
path, cdi_dir = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            cfg = json.load(f)
    except json.JSONDecodeError:
        cfg = {}
cfg.setdefault("features", {})["cdi"] = True
dirs = cfg.get("cdi-spec-dirs", [])
if cdi_dir not in dirs:
    dirs.append(cdi_dir)
cfg["cdi-spec-dirs"] = dirs
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
            _after="$(cat "${_daemon_json}" 2>/dev/null || true)"
            if [[ "${_before}" != "${_after}" ]]; then
                ok "Configured ${_daemon_json} (cdi-spec-dirs -> ${HOME}/.config/cdi only)"
                systemctl --user restart docker
                ok "Rootless daemon restarted — GPU now available via CDI device 'nvidia.com/gpu=all'"
            else
                ok "${_daemon_json} already configured for CDI — no restart needed"
            fi
            unset _daemon_json _before _after
        else
            warn "nvidia-ctk cdi generate failed — GPU passthrough under rootless won't work until this is resolved manually."
        fi
    else
        say "No NVIDIA GPU / nvidia-ctk detected — skipping personal CDI GPU setup (Ollama will run CPU-only under this daemon)."
    fi

    echo
    warn "Your existing shared-daemon containers (this checkout's KinD cluster, Ollama) are untouched and still running there."
    warn "They won't show up under 'docker ps' / 'kind get clusters' anymore (those now talk to the rootless daemon) until you switch back."
    say "(optional) tear down the old shared-daemon ones once you've confirmed the new context works:"
    say "  docker context use default && kind delete cluster --name \$(grep -m1 '^KIND_CLUSTER_NAME=' \"${ENV_FILE}\" 2>/dev/null | cut -d= -f2-) && docker context use rootless"
    echo
    say "Continuing into $( [[ "${SETUP_MODE}" == restart ]] && echo "--restart" || echo "the wizard" ) under the rootless context..."
    echo
fi

# Backfill ACE_INSTANCE_NAME if this .env doesn't have one yet. Every
# host-wide unique resource this script creates (kind cluster name, and via
# scripts/start-local-services.sh: container/volume/compose-project names)
# is suffixed with this so two checkouts of this monorepo on the same shared
# host never collide by defaulting to the same name -- see CLAUDE.md
# section 0. Runs unconditionally (both --setup and --restart) so an
# existing .env missing this (e.g. from before this check existed) gets
# fixed on the next run without the user having to do anything.
if ! grep -q '^ACE_INSTANCE_NAME=.\+' "${ENV_FILE}" 2>/dev/null; then
    _default_instance_name="$(sanitize_instance_name "$(id -un)")"
    if grep -q '^ACE_INSTANCE_NAME=' "${ENV_FILE}" 2>/dev/null; then
        sed -i "s|^ACE_INSTANCE_NAME=.*|ACE_INSTANCE_NAME=${_default_instance_name}|" "${ENV_FILE}"
    else
        echo "ACE_INSTANCE_NAME=${_default_instance_name}" >> "${ENV_FILE}"
    fi
    ok "Set ACE_INSTANCE_NAME=${_default_instance_name} in .env (keeps this checkout's shared-host resources unique)"
    unset _default_instance_name
fi

# Re-validate whatever ended up in .env (just-backfilled values are already
# safe, but a pre-existing or hand-edited one might not be -- e.g. copied
# from before this check existed, or typed in directly with an underscore).
# Runs unconditionally so `kind create cluster` never fails on this instead
# of a clear message here.
_configured_instance_name="$(cur ACE_INSTANCE_NAME)"
_sanitized_instance_name="$(sanitize_instance_name "${_configured_instance_name}")"
if [[ -n "${_configured_instance_name}" && "${_configured_instance_name}" != "${_sanitized_instance_name}" ]]; then
    sed -i "s|^ACE_INSTANCE_NAME=.*|ACE_INSTANCE_NAME=${_sanitized_instance_name}|" "${ENV_FILE}"
    warn "ACE_INSTANCE_NAME='${_configured_instance_name}' isn't safe for kind/Kubernetes resource names (lowercase alphanumeric + hyphen only, ≤20 chars) -- corrected to '${_sanitized_instance_name}' in .env."
fi
unset _configured_instance_name _sanitized_instance_name

# Backfill HOST_KUBE_DIR if this .env doesn't have one yet, pinned to THIS
# interactive shell's real ~/.kube. docker-compose.yml's cluster-init service
# mounts ${HOST_KUBE_DIR:-${HOME}/.kube} -- when unset, that default is
# re-resolved from whatever $HOME is active at `docker compose up` time, not
# necessarily this shell's. If those two ever differ (sudo, a service
# account, a wrapper script), `kind create cluster` inside that container
# happily writes a fully-merged, working kubeconfig into a DIFFERENT physical
# file than the one this operator's own `kubectl` reads by default -- the
# cluster is healthy, cluster-init reports success, and kubectl still can't
# see it, with no error anywhere. Pinning an explicit absolute path here once
# removes that ambiguity for every later `docker compose up` of this
# checkout's stack, regardless of what environment triggers it. Runs
# unconditionally (both --setup and --restart) so an existing .env missing
# this gets fixed automatically. Only backfills when unset -- unlike
# AGENT_CHARTS_ROOT/APP_CHARTS_ROOT below, this is a legitimate manual
# override knob (e.g. a non-standard home layout), not something with one
# unambiguous correct value to keep reconciling to.
if ! grep -q '^HOST_KUBE_DIR=.\+' "${ENV_FILE}" 2>/dev/null; then
    _default_kube_dir="${HOME}/.kube"
    set_env HOST_KUBE_DIR "${_default_kube_dir}"
    ok "Set HOST_KUBE_DIR=${_default_kube_dir} in .env (pins cluster-init's kubeconfig mount so it can't drift to a different \$HOME on a later 'docker compose up')"
    unset _default_kube_dir
fi

# KinD's `kind load docker-image` exports each local image through `docker save`
# before importing it into the node. By default kind stages that tarball in
# /tmp, which is often on the host root filesystem even when Docker's own
# image store is on a large disk (or in a rootless data-root). Persist a
# host-local staging directory so first-time setup asks once, saves the choice,
# and all later --restart / prepare-images runs reuse it.
default_kind_load_tmpdir() {
    local innovation_user_dir="/Innovation/home/$(id -un)"
    if [[ -d "${innovation_user_dir}" && -w "${innovation_user_dir}" ]]; then
        printf '%s\n' "${innovation_user_dir}/.tmp/kind-load"
    elif [[ -d /Innovation && -w /Innovation ]]; then
        printf '%s\n' "/Innovation/ace-$(id -un)/kind-load-tmp"
    else
        printf '%s\n' "${REPO_ROOT}/.tmp/kind-load"
    fi
}

configure_kind_load_tmpdir() {
    local current default selected
    current="$(cur ACE_KIND_LOAD_TMPDIR)"
    if [[ -n "${current}" ]]; then
        selected="${current}"
    else
        default="$(default_kind_load_tmpdir)"
        if [[ "${SETUP_MODE}" == "setup" ]]; then
            echo
            echo -e "${BOLD}Local image staging directory${NC} ${DIM}(used by kind load docker-image / docker save)${NC}"
            read -rp "$(echo -e "  Directory ${DIM}[${default}]${NC}: ")" selected
            selected="${selected:-${default}}"
        else
            selected="${default}"
            warn "ACE_KIND_LOAD_TMPDIR was unset; defaulting to ${selected} for non-interactive setup."
        fi
    fi
    if [[ "${selected}" != /* ]]; then
        echo "ERROR: ACE_KIND_LOAD_TMPDIR must be an absolute path; got '${selected}'." >&2
        echo "ERROR: Set ACE_KIND_LOAD_TMPDIR in .env, then re-run setup." >&2
        exit 1
    fi
    mkdir -p "${selected}" || {
        echo "ERROR: could not create ACE_KIND_LOAD_TMPDIR='${selected}'." >&2
        exit 1
    }
    set_env ACE_KIND_LOAD_TMPDIR "${selected}"
    export ACE_KIND_LOAD_TMPDIR="${selected}"
    ok "Set ACE_KIND_LOAD_TMPDIR=${selected} in .env (KinD image-load tarballs will not use /tmp)"
    unset current default selected
}
configure_kind_load_tmpdir

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

# --- Floating-tag image drift warning --------------------------------------
# The third-party service images in deploy/helm/ace/values.yaml that are pinned
# only to a mutable tag (:latest, a bare major/minor, or no tag at all) can
# silently change what they resolve to between one setup and the next. That is
# exactly how the ClickHouse container rolled from 25.x onto 26.8 and broke
# Langfuse trace ingestion — every trace landed with timestamp 9999-12-31 and
# vanished from the UI and the certifier (OPEN_WEIGHT_CERTIFICATION_HANDOFF.md
# §108).
#
# On every run (both --setup and --restart) this resolves each such image's
# current registry manifest digest and compares it against, in order:
#   1. this host's record from its last setup  → .tmp/image-digests-<inst>.tsv
#   2. failing that (fresh host/checkout), the checked-in reference list
#      → deploy/image-baseline.tsv  (generated from a known-good local setup)
# and warns about anything that moved. Best-effort and non-fatal: silently
# skipped offline or when the registry can't be reached. Disable entirely with
# ACE_SKIP_IMAGE_DRIFT_CHECK=1. After confirming a new set of versions is good,
# refresh the checked-in reference list with:
#   ./scripts/setup.sh --record-image-baseline
IMAGE_BASELINE_FILE="${REPO_ROOT}/deploy/image-baseline.tsv"
_inst_for_state="$(cur ACE_INSTANCE_NAME)"; _inst_for_state="${_inst_for_state:-unconfigured}"
IMAGE_DIGEST_STATE_FILE="${REPO_ROOT}/.tmp/image-digests-${_inst_for_state}.tsv"
unset _inst_for_state

# Prints "<image><TAB><digest>" for each monitored image: every value in the
# `images:` map of the helm values file that is not one of the repo's own
# agentcert/* builds. <digest> is the sha256 of the tag's current registry
# manifest (empty when it can't be resolved).
_resolve_monitored_image_digests() {
    local values_file="${REPO_ROOT}/deploy/helm/ace/values.yaml"
    [[ -r "${values_file}" ]] || return 0
    local imgs img
    imgs="$(sed -n '/^images:/,/^[^[:space:]#]/p' "${values_file}" \
            | sed -n 's/^[[:space:]]\+[a-zA-Z0-9_-]\+:[[:space:]]*\([^[:space:]#]\+\).*/\1/p' \
            | { grep -v '^agentcert/' || true; } | sort -u)"
    [[ -n "${imgs}" ]] || return 0
    # Resolve all of them in parallel — each is an independent registry round-trip.
    _one_image_digest() {
        # `imagetools inspect --raw` emits the raw manifest (index) bytes for the
        # tag; its sha256 is that tag's current digest. `docker manifest inspect`
        # is the fallback. `timeout` guards a hanging/unreachable registry. Every
        # step is `|| d=""` so an offline run just yields an empty digest here
        # (not a `set -e` abort).
        local i="$1" d=""
        d="$(timeout 25 docker buildx imagetools inspect "${i}" --raw 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')" || d=""
        [[ -n "${d}" ]] || d="$(timeout 25 docker manifest inspect "${i}" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')" || d=""
        printf '%s\t%s\n' "${i}" "${d}"
    }
    for img in ${imgs}; do _one_image_digest "${img}" & done
    wait || true
    unset -f _one_image_digest
}

check_image_drift() {
    [[ "${ACE_SKIP_IMAGE_DRIFT_CHECK:-0}" == 1 ]] && return 0
    command -v docker >/dev/null 2>&1 || return 0

    local current=""
    current="$(_resolve_monitored_image_digests)" || current=""
    [[ -n "${current}" ]] || return 0
    # If not one image resolved, we're almost certainly offline — stay quiet.
    awk -F'\t' 'NF>=2 && $2!=""{f=1} END{exit f?0:1}' <<<"${current}" || return 0

    local baseline_src="" ref_label=""
    if [[ -r "${IMAGE_DIGEST_STATE_FILE}" ]]; then
        baseline_src="${IMAGE_DIGEST_STATE_FILE}"
        ref_label="this host's last setup"
    elif [[ -r "${IMAGE_BASELINE_FILE}" ]]; then
        baseline_src="${IMAGE_BASELINE_FILE}"
        ref_label="the repo's checked-in baseline (deploy/image-baseline.tsv)"
    fi

    local drift=0 img cur_dig old_dig
    while IFS=$'\t' read -r img cur_dig; do
        [[ -n "${img}" && -n "${cur_dig}" ]] || continue
        old_dig=""
        if [[ -n "${baseline_src}" ]]; then
            old_dig="$(awk -F'\t' -v i="${img}" '$1==i{print $2; exit}' "${baseline_src}")" || old_dig=""
        fi
        [[ -n "${old_dig}" && "${old_dig}" != "${cur_dig}" ]] || continue
        if [[ ${drift} -eq 0 ]]; then
            echo
            warn "Floating-tag image drift vs ${ref_label}:"
            drift=1
        fi
        echo -e "    ${YELLOW}${img}${NC}"
        echo -e "      ${DIM}was ${old_dig:0:16}…   now ${cur_dig:0:16}…${NC}"
        case "${img}" in
            *clickhouse-server*)
                echo -e "      ${DIM}CH >= 26.8 changed JSON-insert DateTime parsing; the clickhouse-ace-settings${NC}"
                echo -e "      ${DIM}drop-in (templates/langfuse.yaml) restores it and needs CH >= 26.8 — HANDOFF §108/§110.${NC}" ;;
            *langfuse/langfuse*)
                echo -e "      ${DIM}A Langfuse major bump changes the supported ClickHouse range and the DB schema.${NC}" ;;
        esac
    done <<<"${current}" || true

    if [[ ${drift} -eq 1 ]]; then
        echo -e "    ${DIM}A mutable tag moved under you. If the stack misbehaves, suspect this first.${NC}"
        echo -e "    ${DIM}Once the new versions are confirmed good: ./scripts/setup.sh --record-image-baseline${NC}"
        echo
    elif [[ -n "${baseline_src}" ]]; then
        ok "Service image digests unchanged since ${ref_label}."
    fi

    # Always refresh this host's record so the next run compares against "now".
    mkdir -p "$(dirname "${IMAGE_DIGEST_STATE_FILE}")"
    { printf '# <image>\t<sha256 of registry manifest>   (written by setup.sh %s)\n' "$(date -u +%FT%TZ)"
      awk -F'\t' 'NF>=2 && $2!=""' <<<"${current}"; } > "${IMAGE_DIGEST_STATE_FILE}"

    # Seed the checked-in reference list the first time (fresh checkout with no
    # baseline yet) or rewrite it on explicit --record-image-baseline.
    if [[ "${RECORD_IMAGE_BASELINE:-0}" == 1 || ! -e "${IMAGE_BASELINE_FILE}" ]]; then
        local _now; _now="$(date -u +%FT%TZ)"
        { printf '# ACE monitored third-party service images — reference digests for the floating-tag\n'
          printf '# drift check in scripts/setup.sh. Columns: <image>\\t<sha256 of registry manifest>\\t<recorded UTC>\n'
          printf '# Regenerate from a known-good local setup: ./scripts/setup.sh --record-image-baseline\n'
          awk -F'\t' -v d="${_now}" 'NF>=2 && $2!=""{printf "%s\t%s\t%s\n",$1,$2,d}' <<<"${current}"
        } > "${IMAGE_BASELINE_FILE}"
        ok "Recorded image baseline → deploy/image-baseline.tsv ($(awk -F'\t' 'NF>=2 && $2!=""{n++} END{print n+0}' <<<"${current}") images)"
    fi
}
check_image_drift
if [[ "${RECORD_IMAGE_BASELINE:-0}" == 1 ]]; then
    say "Done (--record-image-baseline)."
    exit 0
fi

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

# Ollama is checked first and wins ties when it IS actually up: it's the only
# provider whose "health" this script can confirm end-to-end against a real,
# running, ownership-guarded local container (ollama-${ACE_INSTANCE_NAME}),
# whereas Azure/Gemini/OpenRouter health here is just "looks like a real
# key/endpoint was typed in," not a verified live credential. Previously this
# only checked that OLLAMA_MODEL was a non-empty string in .env -- true even
# when the container is stopped or was never started this session -- so a
# FLASH_AGENT_MODEL left pointing at Ollama from an earlier run was never
# corrected back to a working Azure/Gemini/OpenRouter config that was added
# later, and experiments failed with "could not access Ollama" despite valid
# Azure credentials sitting right next to it in .env.
declare -a _healthy_aliases=()
if [[ -n "${_ollama_alias_cur}" ]]; then
    _ollama_container_name="ollama-$(cur ACE_INSTANCE_NAME)"
    if [[ "$(docker inspect -f '{{.State.Running}}' "${_ollama_container_name}" 2>/dev/null)" == "true" ]]; then
        _healthy_aliases+=("${_ollama_alias_cur}")
    fi
    unset _ollama_container_name
fi
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

# The kind docker-network gateway is the address in-cluster pods use to reach
# host services. Its subnet is assigned PER-BOX (NOT always 172.26.0.1 — it
# depends on how many docker networks already exist), so detect it rather than
# hardcoding. Empty if the kind network doesn't exist yet (fresh VM); we
# re-detect after bring-up below. Defined unconditionally (both --setup and
# --restart) since --restart without reconfiguring needs it too — see the
# CALLBACK_HOST fallback below.
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

# subscriber is baked into every infra-connect manifest at whatever tag
# SUBSCRIBER_IMAGE names (see .env.example) — rebuild under that exact tag
# rather than ":latest" so already-connected infra (which has that tag
# hardcoded into its already-created Deployment) picks up the rebuild after a
# rollout restart, with no manifest regeneration or reconnect required.
_SUBSCRIBER_IMAGE_TAG="$(cur SUBSCRIBER_IMAGE)"
_SUBSCRIBER_IMAGE_TAG="${_SUBSCRIBER_IMAGE_TAG:-agentcert/litmusportal-subscriber:3.0.0}"

# Image build definitions — available to both --setup (interactive) and --restart --local-build
declare -a ALL_BUILD_IMAGES=(
    "1|flash-agent|agentcert/agentcert-flash-agent|${REPO_ROOT}/agents/flash-agent|Dockerfile|direct"
    "2|agent-sidecar|agentcert/agent-sidecar|${REPO_ROOT}/agent-sidecar|Dockerfile|direct"
    "3|install-agent|agentcert/agentcert-install-agent|${REPO_ROOT}/agent-charts|install-agent/Dockerfile|direct"
    "4|install-app|agentcert/agentcert-install-app|${REPO_ROOT}/app-charts|install-app/Dockerfile|direct"
    "5|certifier|agentcert/certifier|${REPO_ROOT}/certifier|Dockerfile|direct"
    "6|auth|agentcert/agentcert-auth|${REPO_ROOT}/AgentCert/chaoscenter/authentication|Dockerfile|direct"
    "7|graphql|agentcert/agentcert-graphql|${REPO_ROOT}/AgentCert/chaoscenter/graphql|server/Dockerfile|direct"
    "8|web|agentcert/agentcert-web|||compose:web"
    "9|cluster-init|agentcert/cluster-init|${REPO_ROOT}/compose/cluster-init|Dockerfile|direct"
    "10|subscriber|${_SUBSCRIBER_IMAGE_TAG}|${REPO_ROOT}/AgentCert/chaoscenter/subscriber|Dockerfile|direct"
    "11|sre-agent-comprehensive|agentcert/sre-agent-comprehensive|${REPO_ROOT}/agents/sre-agent-comprehensive|Dockerfile|direct"
    "12|sre-agent-crewai|agentcert/sre-agent-crewai|${REPO_ROOT}/agents/sre-agent-crewai|Dockerfile|direct"
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

        # --- Stale-image detection (closes the documented gotcha: CLAUDE.md
        # §6 "`--restart` without `--local-build` silently skips Go rebuilds")
        # -------------------------------------------------------------------
        # If this run isn't rebuilding anything (persisted policy resolved to
        # nothing, e.g. "skip", or push creds went missing above), compare
        # each image's source dir against the fingerprint recorded the last
        # time it was actually built (written near the end of the build
        # section below, into .tmp/ace-build-fingerprints.env). Previously
        # this case just redeployed whatever image was already running with
        # zero signal that the source had moved on -- this only warns, it
        # never blocks or rebuilds automatically.
        if [[ "${DO_BUILD}" -eq 0 && "${DO_LOCAL_BUILD}" -eq 0 ]]; then
            _fp_file="${REPO_ROOT}/.tmp/ace-build-fingerprints.env"
            if [[ -f "${_fp_file}" ]]; then
                declare -a _stale_images=()
                for _entry in "${ALL_BUILD_IMAGES[@]}"; do
                    IFS='|' read -r _fnum _flabel _fimg _fctx _fdf _fmethod <<< "$_entry"
                    [[ -z "${_fctx}" || ! -d "${_fctx}" ]] && continue
                    _frecorded="$(grep -m1 "^IMG_${_fnum}=" "${_fp_file}" 2>/dev/null | cut -d= -f2- || true)"
                    [[ -z "${_frecorded}" ]] && continue
                    _fsha="$(git -C "${_fctx}" rev-parse HEAD 2>/dev/null || echo unknown)"
                    _fdirty="$(git -C "${_fctx}" status --porcelain -- . 2>/dev/null | wc -l | tr -d ' ')"
                    [[ "${_fsha}:${_fdirty}" != "${_frecorded}" ]] && _stale_images+=("${_flabel}")
                done
                if [[ ${#_stale_images[@]} -gt 0 ]]; then
                    warn "Source changed since the last local build for: ${_stale_images[*]} — the currently running image(s) are stale."
                    warn "This --restart isn't rebuilding anything (image policy: ${PLATFORM_IMAGE_SOURCE}). To pick up the change:"
                    warn "  ./scripts/setup.sh --restart --local-build"
                fi
                unset _stale_images
            fi
            unset _fp_file
        fi
        unset _entry _fnum _flabel _fimg _fctx _fdf _fmethod _frecorded _fsha _fdirty

        # CALLBACK_HOST (pod->host gateway IP) is normally (re)detected further
        # below, but that logic lives inside the interactive SETUP_MODE=setup
        # block, which this restart-without-reconfiguring path never enters —
        # leaving CALLBACK_HOST completely unset. k8s_deploy() dereferences it
        # unconditionally under `set -u`, which crashes the script *after* the
        # Helm upgrade has already gone through, only skipping the trailing
        # "wire host services into cluster" step. Detect it here too so a
        # plain `--restart` (Enter) stays self-healing like the other
        # unconditional fixups above.
        if [[ "${CLUSTER_MODE}" == "cloud" ]]; then
            CALLBACK_HOST=""
        else
            CALLBACK_HOST="$(detect_k3s_gw || true)"
            [[ -z "${CALLBACK_HOST}" ]] && CALLBACK_HOST="$(detect_kind_gw || true)"
            CALLBACK_HOST="${CALLBACK_HOST:-172.26.0.1}"
        fi
    fi
    unset _restart_choice
fi

# True if $1 is empty or looks like an unfilled .env.example placeholder
# (CHANGE_ME, REPLACE_ME, dckr_pat_REPLACE_ME, YOUR_RESOURCE, YOUR_DOCKERHUB_...,
# YOUR_HOST_LAN_IP, etc.) rather than a real value someone actually typed in.
is_placeholder() {
    local v="$1"
    [[ -z "$v" ]] && return 0
    case "$v" in
        CHANGE_ME|REPLACE_ME|*REPLACE_ME|YOUR_*|*YOUR_RESOURCE*) return 0 ;;
        *) return 1 ;;
    esac
}

# ask "KEY" "Prompt label" → echoes chosen value (default = current .env value).
# When .env already holds a real (non-placeholder) value for KEY, that's
# flagged inline with "already set" so it's obvious the bracketed default is
# an existing credential to keep (Enter) or overwrite — not a guess.
ask() {
    local key="$1" label="$2" def reply
    def="$(cur "$key")"
    if ! is_placeholder "$def"; then
        read -rp "$(echo -e "  ${BOLD}${label}${NC} ${GREEN}✓ already set${NC} ${DIM}[${def}]${NC}: ")" reply
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
    echo -e "${BOLD}▸ Build images?${NC}  p=push to Docker Hub  l=build locally  a=build ALL locally (platform + experiment images)  n=skip"
    DO_BUILD=0; DO_LOCAL_BUILD=0; DH_USER=""; DH_TOKEN=""; _ALL_LOCAL=0
    declare -a SELECTED_BUILD_IMAGES=()
    read -rp "  Choice [p/l/A/n]: " _eb
    case "${_eb,,}" in
        "") DO_LOCAL_BUILD=1; SELECTED_BUILD_IMAGES=("${ALL_BUILD_IMAGES[@]}"); _ALL_LOCAL=1 ;;
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
        a)  DO_LOCAL_BUILD=1; SELECTED_BUILD_IMAGES=("${ALL_BUILD_IMAGES[@]}"); _ALL_LOCAL=1 ;;
    esac
    _pis="skip"; [[ $DO_BUILD -eq 1 ]] && _pis="push"; [[ $DO_LOCAL_BUILD -eq 1 ]] && _pis="local"
    if grep -q '^PLATFORM_IMAGE_SOURCE=' "${ENV_FILE}" 2>/dev/null; then
        sed -i "s|^PLATFORM_IMAGE_SOURCE=.*|PLATFORM_IMAGE_SOURCE=${_pis}|" "${ENV_FILE}"
    else
        echo "PLATFORM_IMAGE_SOURCE=${_pis}" >> "${ENV_FILE}"
    fi
    unset _pis
    echo

    # Image sources — "a" above already answers these; only ask when it wasn't chosen.
    if [[ ${_ALL_LOCAL} -eq 1 ]]; then
        echo -e "${BOLD}▸ Experiment image sources${NC}  ${DIM}auto-set to local — \"a\" (build ALL locally) was selected above${NC}"
        _INSTALL_APP_SRC="local"; _INSTALL_AGENT_SRC="local"; _LITMUS_SRC="local"
    else
        echo -e "${BOLD}▸ Experiment image sources${NC}  d=Docker Hub  j=JFrog  l=local build"
        read -rp "  install-application  (agentcert-install-app)   [d/j/l, Enter=d]: " _ans
        case "${_ans,,}" in j) _INSTALL_APP_SRC="jfrog" ;; l) _INSTALL_APP_SRC="local" ;; *) _INSTALL_APP_SRC="dockerhub" ;; esac
        read -rp "  install-agent        (agentcert-install-agent) [d/j/l, Enter=d]: " _ans
        case "${_ans,,}" in j) _INSTALL_AGENT_SRC="jfrog" ;; l) _INSTALL_AGENT_SRC="local" ;; *) _INSTALL_AGENT_SRC="dockerhub" ;; esac
        read -rp "  litmuschaos helpers  (k8s/checker/deployer)    [d/l,   Enter=d]: " _ans
        case "${_ans,,}" in l) _LITMUS_SRC="local" ;; *) _LITMUS_SRC="dockerhub" ;; esac
        unset _ans
    fi
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

    echo -e "${BOLD}▸ Ollama${NC}  ${DIM}(local open-weight model — pulls a multi-GB image + model; can take a long time)${NC}"
    _cur_ollama="$(cur OLLAMA_MODEL)"
    _last_ollama="$(cur OLLAMA_MODEL_LAST_USED)"
    if   [[ -n "$_cur_ollama" ]]; then _ollama_def="${_cur_ollama}"; _ollama_use_def="y"
    elif [[ -z "$AZ_KEY" && -z "$GEMINI_KEY" && -z "$OPENROUTER_KEY" ]]; then _ollama_def="${_last_ollama:-qwen2.5:32b-instruct}"; _ollama_use_def="y"
    else _ollama_def="${_last_ollama}"; _ollama_use_def="n"; fi
    _ollama_use_hint="y/N"; [[ "${_ollama_use_def}" == "y" ]] && _ollama_use_hint="Y/n"
    read -rp "$(echo -e "  Set up Ollama? ${DIM}[${_ollama_use_hint}]${NC}: ")" _ollama_use
    _ollama_use="${_ollama_use:-${_ollama_use_def}}"
    if [[ "${_ollama_use,,}" == y* ]]; then
        read -rp "$(echo -e "  Model ${DIM}[${_ollama_def:-qwen2.5:32b-instruct}]${NC}: ")" _or
        OLLAMA_MODEL_TAG="${_or:-${_ollama_def:-qwen2.5:32b-instruct}}"
    else
        OLLAMA_MODEL_TAG=""
    fi
    OLLAMA_MODEL_TAG="$(echo "${OLLAMA_MODEL_TAG}" | tr -d '[:space:]')"
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

    # Agent to benchmark
    _bench_def="$(cur BENCHMARK_AGENT)"
    if [[ -z "${_bench_def}" ]] || ! agent_is_available "${_bench_def}"; then
        agent_is_available "flash-agent" && _bench_def="flash-agent" || _bench_def="${AVAILABLE_AGENTS[0]:-flash-agent}"
    fi
    echo -e "${BOLD}▸ Agent to benchmark${NC}  ${DIM}(agents/<name> — used by scripts/ace-bench.py; available: ${AVAILABLE_AGENTS[*]})${NC}"
    if [[ -n "${AGENT_FLAG}" ]]; then
        BENCHMARK_AGENT="${AGENT_FLAG}"
        ok "  Using --agent=${BENCHMARK_AGENT}"
    else
        read -rp "$(echo -e "  Agent ${DIM}[${_bench_def}]${NC}: ")" _bench_ans
        BENCHMARK_AGENT="${_bench_ans:-${_bench_def}}"
        if ! agent_is_available "${BENCHMARK_AGENT}"; then
            warn "  '${BENCHMARK_AGENT}' is not under agents/ — keeping '${_bench_def}'."
            BENCHMARK_AGENT="${_bench_def}"
        fi
    fi
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
    read -rp "  Choice [k/H/n]: " _DEPLOY_CHOICE
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    ok "All answers collected — script will now run unattended."
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo
fi

# --- Build: push to Docker Hub or build locally (optional) ------------------
if [[ $EXPRESS_MODE -eq 0 ]]; then
DO_BUILD=0; DO_LOCAL_BUILD=0; DH_USER=""; DH_TOKEN=""; _ALL_LOCAL=0
declare -a SELECTED_BUILD_IMAGES=()

if [[ "${BUILD_MODE}" == "local" ]]; then
    # --local-build flag: skip prompt, build all images locally
    SELECTED_BUILD_IMAGES=("${ALL_BUILD_IMAGES[@]}")
    DO_LOCAL_BUILD=1
else
    echo -e "${BOLD}Build Docker images?${NC}"
    echo -e "   ${BOLD}p${NC}  Build and push to Docker Hub"
    echo -e "   ${BOLD}l${NC}  Build locally only  ${DIM}(loads into KinD — no Docker Hub account needed)${NC}"
    echo -e "   ${BOLD}a${NC}  Build ALL locally   ${DIM}(platform + experiment images — also auto-fills and skips the image-source questions below)${NC}"
    echo -e "   ${BOLD}n${NC}  Skip"
    read -rp "$(echo -e "Choice ${DIM}[p/l/A/n]${NC}: ")" _build_ans
    _sel_mode="none"
    case "${_build_ans,,}" in
        "") _sel_mode="local"; _ALL_LOCAL=1 ;;
        p) _sel_mode="push"  ;;
        l) _sel_mode="local" ;;
        a) _sel_mode="local"; _ALL_LOCAL=1 ;;
    esac
    if [[ "${_sel_mode}" != "none" ]]; then
        echo
        echo -e "   Select services to build ${DIM}(space-separated numbers, or Enter for all):${NC}"
        for _entry in "${ALL_BUILD_IMAGES[@]}"; do
            IFS='|' read -r _num _label _img _ _ _method <<< "$_entry"
            [[ "$_method" == compose:* ]] && _note="via compose" || _note="direct"
            [[ "${_img}" == *:* ]] && _disp_tag="${_img}" || _disp_tag="${_img}:latest"
            echo -e "     ${BOLD}${_num})${NC} ${_label}  ${DIM}(${_disp_tag}, ${_note})${NC}"
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
# Wizard is skipped in --restart mode (sources are already in .env), and also
# skipped here — auto-filled to local instead — when "a" (build ALL locally)
# was chosen in the build prompt above.
_INSTALL_APP_SRC=""; _INSTALL_AGENT_SRC=""; _LITMUS_SRC=""
_JFROG_HOST=""; _JFROG_PATH=""; _JFROG_USER=""; _JFROG_TOKEN=""
if [[ "$SETUP_MODE" == "setup" && $EXPRESS_MODE -eq 0 ]]; then
    if [[ "${_ALL_LOCAL:-0}" -eq 1 ]]; then
        echo -e "${BOLD}Experiment image sources${NC}  ${DIM}auto-set to local — \"a\" (build ALL locally) was selected above${NC}"
        _INSTALL_APP_SRC="local"; _INSTALL_AGENT_SRC="local"; _LITMUS_SRC="local"
        echo
    else
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
echo -e "      ${DIM}Pulls a multi-GB image + model via 'ollama pull' — can take a long time on a slow link.${NC}"
# Smart default: offer the qwen2.5 32b only when no external provider is configured
# (or when the user already has OLLAMA_MODEL set in .env). If they have API keys, skip.
_cur_ollama="$(cur OLLAMA_MODEL)"
_last_ollama="$(cur OLLAMA_MODEL_LAST_USED)"
if [[ -n "$_cur_ollama" ]]; then
    _ollama_def="${_cur_ollama}"; _ollama_use_def="y"
elif [[ -z "$AZ_KEY" && -z "$GEMINI_KEY" && -z "$OPENROUTER_KEY" ]]; then
    _ollama_def="${_last_ollama:-qwen2.5:32b-instruct}"; _ollama_use_def="y"
else
    _ollama_def="${_last_ollama}"; _ollama_use_def="n"
fi
_ollama_use_hint="y/N"; [[ "${_ollama_use_def}" == "y" ]] && _ollama_use_hint="Y/n"
read -rp "$(echo -e "  ${BOLD}Set up Ollama?${NC} ${DIM}[${_ollama_use_hint}]${NC}: ")" _ollama_use
_ollama_use="${_ollama_use:-${_ollama_use_def}}"
if [[ "${_ollama_use,,}" == y* ]]; then
    read -rp "$(echo -e "  ${BOLD}Ollama model${NC} ${DIM}[${_ollama_def:-qwen2.5:32b-instruct}]${NC}: ")" _ollama_reply
    OLLAMA_MODEL_TAG="${_ollama_reply:-${_ollama_def:-qwen2.5:32b-instruct}}"
else
    OLLAMA_MODEL_TAG=""
fi
OLLAMA_MODEL_TAG="$(echo "${OLLAMA_MODEL_TAG}" | tr -d '[:space:]')"
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

# --- Section 3: Agent to benchmark ------------------------------------------
_bench_def="$(cur BENCHMARK_AGENT)"
if [[ -z "${_bench_def}" ]] || ! agent_is_available "${_bench_def}"; then
    agent_is_available "flash-agent" && _bench_def="flash-agent" || _bench_def="${AVAILABLE_AGENTS[0]:-flash-agent}"
fi
echo -e "${BOLD}3) Agent to benchmark${NC} ${DIM}(agents/<name> — used by scripts/ace-bench.py)${NC}"
echo -e "   ${DIM}Available: ${AVAILABLE_AGENTS[*]}${NC}"
if [[ -n "${AGENT_FLAG}" ]]; then
    BENCHMARK_AGENT="${AGENT_FLAG}"
    ok "  Using --agent=${BENCHMARK_AGENT}"
else
    read -rp "$(echo -e "  Agent ${DIM}[${_bench_def}]${NC}: ")" _bench_ans
    BENCHMARK_AGENT="${_bench_ans:-${_bench_def}}"
    if ! agent_is_available "${BENCHMARK_AGENT}"; then
        warn "  '${BENCHMARK_AGENT}' is not under agents/ — keeping '${_bench_def}'."
        BENCHMARK_AGENT="${_bench_def}"
    fi
fi
echo

# --- OPTIONAL: cluster + infra modes ---------------------------------------
echo -e "${BOLD}4) How should Kubernetes be sourced?${NC} ${DIM}(Enter = auto)${NC}"
echo -e "   ${DIM}auto=reuse/create kind  local=existing cluster  cloud=AKS/EKS/GKE  fresh=new kind${NC}"
CLUSTER_MODE="$(ask CLUSTER_MODE 'CLUSTER_MODE (auto/local/cloud/fresh)')"
CLUSTER_MODE="${CLUSTER_MODE:-auto}"
echo

# --- Corporate proxy CA certificate ----------------------------------------
echo -e "${BOLD}5) Corporate proxy CA certificate${NC} ${DIM}(needed for git clone inside containers on proxy networks)${NC}"
echo -e "   ${DIM}Leave blank to use the host system bundle (/etc/ssl/certs/ca-certificates.crt).${NC}"
CUSTOM_CA_CERT_PATH="$(ask CUSTOM_CA_CERT_PATH 'Path to root CA cert file (.pem/.crt, Enter to skip)')"
CUSTOM_CA_CERT_PATH="$(echo "${CUSTOM_CA_CERT_PATH}" | tr -d '[:space:]')"
if [[ -n "${CUSTOM_CA_CERT_PATH}" && ! -f "${CUSTOM_CA_CERT_PATH}" ]]; then
    warn "File not found: ${CUSTOM_CA_CERT_PATH} — will fall back to host bundle at deploy time."
    CUSTOM_CA_CERT_PATH=""
fi
echo

fi # EXPRESS_MODE -eq 0 (sections 1-4)

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
       _BENCHMARK_AGENT="${BENCHMARK_AGENT:-}" \
       _CUSTOM_CA_CERT_PATH="${CUSTOM_CA_CERT_PATH:-}" \
       _INSTALL_APP_SRC="${_INSTALL_APP_SRC:-}" _INSTALL_AGENT_SRC="${_INSTALL_AGENT_SRC:-}" \
       _LITMUS_SRC="${_LITMUS_SRC:-}" \
       _JFROG_HOST="${_JFROG_HOST:-}" _JFROG_PATH="${_JFROG_PATH:-}" \
       _JFROG_USER="${_JFROG_USER:-}" _JFROG_TOKEN="${_JFROG_TOKEN:-}"
"${SETUP_PYTHON}" - "${ENV_FILE}" <<'PY'
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

# ── Agent to benchmark ────────────────────────────────────────────────────────
benchmark_agent = os.environ.get("_BENCHMARK_AGENT", "")
if benchmark_agent:
    sets["BENCHMARK_AGENT"] = benchmark_agent

# ── Ollama model ──────────────────────────────────────────────────────────────
# OLLAMA_MODEL is the "live" tag: non-empty means setup.sh actively manages
# the container (ensures it's running, pulls this tag, wires litellm_config
# and flash-agent). OLLAMA_MODEL_LAST_USED is a separate, purely cosmetic
# memory of the most recent real tag typed in, used ONLY to pre-fill the
# wizard's prompt default after a decline — it never drives any deploy
# behavior on its own, so remembering it doesn't resurrect anything.
ollama_model = os.environ.get("_OLLAMA_MODEL_TAG", "")
cur_lines = open(path).read()
if ollama_model:
    sets["OLLAMA_MODEL"] = ollama_model
    sets["OLLAMA_MODEL_LAST_USED"] = ollama_model
    # Set sensible defaults for OLLAMA_BASE_URL and OPENAI_COMPATIBLE_BASE_URL
    # if not already in .env. Both use the UID-derived OLLAMA_PORT (written to
    # .env by the backfill block earlier in this script) so they reach THIS
    # checkout's ACE-owned Ollama container, not the system Ollama on :11434.
    # k8s_env_patch overwrites both with in-cluster Service names at K8s deploy.
    m = re.search(r'^OLLAMA_PORT=(\d+)', cur_lines, re.MULTILINE)
    ollama_port = m.group(1) if m else "11434"
    if "OLLAMA_BASE_URL=" not in cur_lines:
        sets.setdefault("OLLAMA_BASE_URL", f"http://host.docker.internal:{ollama_port}")
    if "OPENAI_COMPATIBLE_BASE_URL=" not in cur_lines:
        sets.setdefault("OPENAI_COMPATIBLE_BASE_URL", f"http://host.docker.internal:{ollama_port}/v1")
else:
    # The user was asked "Set up Ollama?" this run and declined — clear any
    # OLLAMA_MODEL left over from a previous run. Without this, a stale value
    # from an earlier setup keeps flash-agent's Ollama route "configured" and
    # the Ollama-ensure-running block below (which falls back to reading
    # OLLAMA_MODEL straight from .env for --restart) would resurrect the
    # container + model pull despite the explicit "no" just given. Before
    # clearing it, stash whatever it was into OLLAMA_MODEL_LAST_USED (if not
    # already blank) so the next wizard run still pre-fills the same tag
    # instead of making the user retype it — the container/volume with the
    # actual downloaded model is untouched either way.
    prev_m = re.search(r'^OLLAMA_MODEL=(.+)$', cur_lines, re.MULTILINE)
    prev_ollama_model = prev_m.group(1).strip() if prev_m else ""
    if prev_ollama_model:
        sets["OLLAMA_MODEL_LAST_USED"] = prev_ollama_model
    sets["OLLAMA_MODEL"] = ""

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
    elif app_src == "local":
        # "local" means prepare-images.sh built and kind-loaded this image under
        # this tag and nothing else should ever be pulled for it -- but the same
        # tag also exists as a real published image on Docker Hub. IfNotPresent
        # is not safe here: kubelet's own image GC can evict a kind-loaded image
        # at any time (it doesn't know or care that it was locally loaded rather
        # than pulled), and the next pod using this tag would then silently
        # fall back to pulling the stale public Docker Hub image instead of
        # failing -- which is exactly what happened mid-session (see
        # OPEN_WEIGHT_CERTIFICATION_HANDOFF.md, ITBench 36-experiment entry):
        # delete-agent started failing with "flag provided but not defined:
        # -delete" hours after an explicit `kind load` had already fixed it,
        # because the loaded image had been evicted and silently replaced.
        # Never makes a missing/evicted local image fail loudly
        # (ErrImageNeverPull) instead of quietly running stale logic.
        sets["INSTALL_APPLICATION_IMAGE"]             = "agentcert/agentcert-install-app:latest"
        sets["INSTALL_APPLICATION_IMAGE_PULL_POLICY"] = "Never"
    else:
        # "dockerhub": production/default mode genuinely wants the registry copy
        # and should refresh the public :latest tag at run time.
        sets["INSTALL_APPLICATION_IMAGE"]             = "agentcert/agentcert-install-app:latest"
        sets["INSTALL_APPLICATION_IMAGE_PULL_POLICY"] = "Always"

if agent_src:
    sets["INSTALL_AGENT_IMAGE_SOURCE"] = agent_src
    if agent_src == "jfrog":
        sets["INSTALL_AGENT_IMAGE"]             = f"{jfrog_host}/{jfrog_path}/agentcert/agentcert-install-agent:latest"
        sets["INSTALL_AGENT_IMAGE_PULL_POLICY"] = "Always"
    elif agent_src == "local":
        # See the matching "local" branch above for install-app -- same
        # kind-loaded-image-vs-Docker-Hub-tag-collision reasoning applies here,
        # and this is in fact the exact image/flag this bit itself was found on.
        sets["INSTALL_AGENT_IMAGE"]             = "agentcert/agentcert-install-agent:latest"
        sets["INSTALL_AGENT_IMAGE_PULL_POLICY"] = "Never"
    else:
        sets["INSTALL_AGENT_IMAGE"]             = "agentcert/agentcert-install-agent:latest"
        sets["INSTALL_AGENT_IMAGE_PULL_POLICY"] = "Always"

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

ok "Wrote LiteLLM model config, flash-agent model, BENCHMARK_AGENT=${BENCHMARK_AGENT}, and CLUSTER_MODE=${CLUSTER_MODE} to .env"
report_preserved_langfuse_traces

# --- patch litellm_config.yaml with the chosen Ollama model -----------------
if [[ -n "${OLLAMA_MODEL_TAG:-}" ]]; then
    _litellm_cfg="${REPO_ROOT}/agentcert-stack/litellm-setup/litellm_config.yaml"
    if [[ -f "${_litellm_cfg}" ]]; then
        "${SETUP_PYTHON}" - "${_litellm_cfg}" <<'PY'
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
else
    echo -e "  ${DIM}Ollama         skipped — no local container will be created or model pulled${NC}"
fi
if [[ -z "$AZ_KEY" && -z "$GEMINI_KEY" && -z "$OPENROUTER_KEY" && -z "${OLLAMA_MODEL_TAG:-}" ]]; then
    warn "No LLM providers configured — agents won't be able to make LLM calls (re-run to add one)."
fi
echo -e "  Flash-agent model : ${BOLD}${FLASH_MODEL}${NC}"
echo -e "  Benchmark agent   : ${BOLD}${BENCHMARK_AGENT}${NC}"
echo -e "  Cluster mode      : ${BOLD}${CLUSTER_MODE}${NC}"
echo -e "  Infra             : MongoDB + Langfuse + LiteLLM run locally ${DIM}(defaults; edit .env to change)${NC}"
echo -e "${CYAN}-------------------------------------------------------${NC}"
echo
echo -e "Next:  ${BOLD}./scripts/setup.sh${NC} then answer Y to deploy, or run ${BOLD}kubectl get pods -n ace${NC}"
echo -e "       Re-deploy without re-entering values: ${BOLD}./scripts/setup.sh --restart${NC}"
echo -e "       Run the benchmark: ${BOLD}python scripts/ace-bench.py ${BENCHMARK_AGENT}${NC}"
echo -e "       Switch the benchmark agent: ${BOLD}./scripts/setup.sh --restart --agent=<name>${NC}  ${DIM}(available: ${AVAILABLE_AGENTS[*]})${NC}"
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
    "${SETUP_PYTHON}" - "$1" <<'PY'
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
        if [[ -z "${lb_ip}" ]]; then sleep 5; attempts=$(( attempts + 1 )); fi
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
    escaped_lb="$("${SETUP_PYTHON}" -c "import re,sys; print(re.escape(sys.argv[1]))" "${lb_ip}")"
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

# kind node images default the `iptables` alternative to the nft backend. On
# this host's kernel/iptables toolchain, nft's netlink-based rule loading has
# a hard per-message size ceiling that kube-proxy's normal Service ruleset
# exceeds -- every periodic resync then fails with
# "sendmsg() failed: Message too long" (kube-proxy retries every 30s, forever,
# and never once succeeds again after the first sync that happened to fit).
# The practical effect: Service routing silently freezes at whatever ruleset
# loaded at the very first successful sync. Any Service whose backing pod
# later restarts (gets a new IP) is blackholed from that point on -- new
# connections to its ClusterIP get NATed to a now-dead pod IP and silently
# dropped -- while every other Service keeps "working" purely by accident
# (their stale rules still happen to be correct). This is exactly what broke
# the ChaosCenter UI's GraphQL calls after a graphql pod restart; see
# OPEN_WEIGHT_CERTIFICATION_HANDOFF.md for the live incident this was found in.
#
# iptables-legacy sidesteps the bug entirely -- it programs the kernel via a
# setsockopt() ruleset replace, not one giant batched netlink message, so
# there's no comparable size ceiling to hit.
#
# kube-proxy bundles its own copy of the iptables tools (it does not use the
# node's /usr/sbin), so flipping the node's own `update-alternatives` default
# has no effect on it. kube-proxy instead auto-detects nft vs legacy at its
# own startup by counting which backend currently has MORE rules already
# loaded in the kernel (ties favor legacy) -- so the only way to make it
# actually choose legacy is to zero out nft's rule count *before* kube-proxy
# starts (fresh cluster) or before it next restarts (existing cluster), so
# legacy's smaller-or-equal count wins that tie-break. Everything here is
# scoped to nftables tables inside this one kind node container's own network
# namespace -- it never touches the shared host's kernel state or any other
# checkout's containers.
steer_kube_proxy_onto_iptables_legacy() {
    local cluster_name="$1" node
    for node in $(docker ps --format '{{.Names}}' | grep -E "^${cluster_name}-(control-plane|worker)" || true); do
        docker exec "${node}" sh -c '
            update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1 || true
            update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
            for t in "ip nat" "ip mangle" "ip filter" "ip6 nat" "ip6 mangle" "ip6 filter"; do
                nft delete table ${t} >/dev/null 2>&1 || true
            done
        ' 2>/dev/null || warn "Could not steer ${node} onto iptables-legacy -- kube-proxy may hit the nft message-size bug (see innovation.md)."
    done
    # kube-proxy only auto-detects once, at its own startup -- bounce it now
    # so it re-evaluates against the rule counts set up above.
    if kubectl -n kube-system get daemonset kube-proxy >/dev/null 2>&1; then
        kubectl -n kube-system delete pod -l k8s-app=kube-proxy >/dev/null 2>&1 || true
        kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-proxy --timeout=60s >/dev/null 2>&1 \
            || warn "kube-proxy did not report Ready within 60s after the iptables-backend fix -- check manually (kubectl -n kube-system logs -l k8s-app=kube-proxy)."
    fi
}

# Cheap, read-only check so the "reuse an existing cluster" path only pays for
# the (mildly disruptive -- it bounces kube-proxy) fix above when the cluster
# is actually hitting the bug, e.g. one created before this fix existed.
# Freshly created clusters always get the fix unconditionally, since they
# always start out on the broken nft default.
kube_proxy_iptables_broken() {
    kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=20 2>/dev/null | grep -q "Message too long"
}

# kind's node entrypoint rewrites each node's /etc/resolv.conf to point at
# the node's own docker-network gateway IP (e.g. 172.18.0.1:53) whenever it
# detects the host's own resolv.conf uses a loopback resolver -- true on this
# fleet, since it uses systemd-resolved's 127.0.0.53 stub. Under the ROOTFUL
# daemon that gateway IP is transparently proxied through to the host's real
# resolver (iptables DNAT the rootful daemon sets up) and everything just
# works. Under a PERSONAL ROOTLESS daemon (see CLAUDE.md §6 "Personal
# rootless Docker") RootlessKit/slirp4netns does not replicate that DNAT, so
# the gateway IP is simply unreachable on :53 and EVERY external DNS lookup
# inside every node times out -- this includes containerd's own image pulls
# (it reads the node container's /etc/resolv.conf directly) and CoreDNS's
# upstream forwarding (its default Corefile is `forward . /etc/resolv.conf`,
# inherited from the node via dnsPolicy: Default). The practical symptom:
# any chaos-infrastructure connect (subscriber/chaos-exporter/chaos-operator)
# -- or any other in-cluster image pull -- sits in ImagePullBackOff forever,
# and the ChaosCenter UI shows the infra stuck "Pending" indefinitely with no
# error surfaced anywhere in the UI itself. Fix: detect the broken gateway
# resolver per-node and fall back to public resolvers, which rootless
# networking (slirp4netns) CAN reach directly as ordinary outbound traffic.
node_dns_broken() {
    local node="$1"
    ! docker exec "${node}" timeout 3 getent hosts registry-1.docker.io >/dev/null 2>&1
}

fix_node_dns() {
    local node="$1"
    if docker exec "${node}" sh -c 'printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf'; then
        ok "Rewrote ${node}'s /etc/resolv.conf to public resolvers (gateway-IP resolver unreachable under rootless Docker)."
    else
        warn "Could not patch ${node}'s /etc/resolv.conf -- image pulls and in-cluster DNS may keep failing."
    fi
}

ensure_node_dns() {
    local cluster_name="$1" node any_fixed=0
    for node in $(docker ps --format '{{.Names}}' | grep -E "^${cluster_name}-(control-plane|worker)" || true); do
        if node_dns_broken "${node}"; then
            warn "${node} cannot resolve external DNS (gateway-IP resolver unreachable) -- patching ..."
            fix_node_dns "${node}"
            any_fixed=1
        fi
    done
    if [[ "${any_fixed}" == "1" ]] && kubectl -n kube-system get deployment coredns >/dev/null 2>&1; then
        kubectl -n kube-system delete pod -l k8s-app=kube-dns >/dev/null 2>&1 || true
        kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=60s >/dev/null 2>&1 \
            || warn "CoreDNS did not report Ready within 60s after the DNS fix -- check manually (kubectl -n kube-system logs -l k8s-app=kube-dns)."
    fi
}

# Force kubectl to point at this cluster, regardless of what its kubeconfig
# entry currently looks like. `kind create cluster`'s automatic merge-on-create
# is not reliable in every environment on this host -- observed case: a
# rootless-Docker checkout whose $KUBECONFIG never gained a kind-<cluster>
# entry at all, so a best-effort `kubectl config use-context ... || true`
# silently no-op'd every time (the context didn't exist to switch to) and
# kubectl fell back to the http://localhost:8080 default, with setup.sh still
# reporting success. `kind export kubeconfig` re-derives the entry directly
# from the running container and unconditionally sets current-context, so it
# self-heals this on every run -- not just at cluster-creation time -- and we
# fail loudly here instead of swallowing it like before.
ensure_kubeconfig_context() {
    local cluster_name="$1"
    if ! kind export kubeconfig --name "${cluster_name}" >/dev/null 2>&1; then
        warn "kind export kubeconfig failed for cluster '${cluster_name}' -- is it actually running? (kind get clusters)"
        return 1
    fi
    if ! kubectl cluster-info >/dev/null 2>&1; then
        warn "kubectl still cannot reach cluster '${cluster_name}' after 'kind export kubeconfig'."
        warn "Check KUBECONFIG (currently: ${KUBECONFIG:-\$HOME/.kube/config}) and 'kubectl config get-contexts'."
        return 1
    fi
    return 0
}

# Warn (never abort) if the KinD node is at or near disk-pressure eviction.
# kind-agentcert.yaml pins kubelet's eviction floors to absolute values
# (nodefs.available<5Gi, imagefs.available<5Gi — see CLAUDE.md §4.5 "KinD
# eviction thresholds") specifically because the shared host's Docker
# data-root can read as nearly full by PERCENTAGE while tens of GB remain in
# absolute terms, and kubelet's stock percentage-based thresholds fire on
# that alone. Those absolute floors only help if there's actually more than
# ~5Gi free when the cluster starts doing real work; this checks that instead
# of silently reporting "cluster created" into a node that starts evicting
# every pod moments later. Also checks the node's live conditions, which
# catches eviction already in progress on a long-running cluster whose host
# filled up after creation, not just a bad state at creation time.
check_kind_disk_pressure() {
    local cluster_name="$1" docker_root avail_kb avail_gi conditions
    docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
    if [[ -n "${docker_root}" ]]; then
        avail_kb="$(df -Pk "${docker_root}" 2>/dev/null | awk 'NR==2{print $4}' || true)"
        if [[ "${avail_kb}" =~ ^[0-9]+$ ]]; then
            avail_gi=$(( avail_kb / 1024 / 1024 ))
            if (( avail_gi < 8 )); then
                warn "Docker data-root (${docker_root}) has only ~${avail_gi}Gi free — close to the 5Gi kubelet eviction floor (CLAUDE.md §4.5)."
                warn "Pods on '${cluster_name}' may start getting evicted. Check: df -h ${docker_root}   (and verify it's really where you think it is — CLAUDE.md §6 'Docker data-root may not actually be on /Innovation')"
            fi
        fi
    fi
    conditions="$(kubectl get nodes "${cluster_name}-control-plane" \
        -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}' 2>/dev/null || true)"
    if [[ "${conditions}" == *DiskPressure* || "${conditions}" == *MemoryPressure* ]]; then
        warn "Node '${cluster_name}-control-plane' is reporting pressure conditions right now: ${conditions}"
        warn "Pods are likely being evicted. Free up space on the Docker data-root or add more (CLAUDE.md §4.5/§6)."
    fi
}

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
    ace_instance_name="${ace_instance_name:-$(sanitize_instance_name "$(id -un)")}"

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
        has_ace_ports="$(echo "${_inspect_json}" | "${SETUP_PYTHON}" -c "
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
        "${SETUP_PYTHON}" - "${ENV_FILE}" <<'PY'
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
        ensure_kubeconfig_context "${cluster_name}" || return 1
        check_kind_disk_pressure "${cluster_name}"
        if kube_proxy_iptables_broken; then
            warn "kube-proxy on '${cluster_name}' is hitting the iptables-nft message-size bug (Service routing silently stale) — fixing ..."
            steer_kube_proxy_onto_iptables_legacy "${cluster_name}"
        fi
        ensure_node_dns "${cluster_name}"
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
    if ! kind create cluster --name "${cluster_name}" --config "${kind_cfg}"; then
        warn "kind create cluster failed for '${cluster_name}' (config: ${kind_cfg})."
        warn "Common causes: one of the KIND_HOSTPORT_* ports picked above got taken by something else"
        warn "between the pick and cluster creation; the containerd 2.3 shim bug on this host"
        warn "(--rootless-docker only -- see CLAUDE.md §6, 'unsupported protocol:Yunix'); or the active"
        warn "docker context ($(docker context show 2>/dev/null || echo unknown)) not reaching a working daemon."
        return 1
    fi
    mark_kind_cluster_owned "${cluster_name}"
    ensure_kubeconfig_context "${cluster_name}" || return 1
    # A brand-new cluster always starts on the broken nft default (see the
    # comment on steer_kube_proxy_onto_iptables_legacy above) -- fix it now,
    # before anything else depends on Service routing actually working.
    echo -e "${DIM}Steering kube-proxy onto iptables-legacy to avoid the nft netlink message-size bug…${NC}"
    steer_kube_proxy_onto_iptables_legacy "${cluster_name}"
    # A brand-new node always starts with whatever resolv.conf kind's own
    # entrypoint wrote -- check and patch it now, before anything (image
    # pulls, CoreDNS) depends on external DNS actually working.
    echo -e "${DIM}Checking node DNS reaches the outside world (rootless Docker can't proxy the gateway-IP resolver)…${NC}"
    ensure_node_dns "${cluster_name}"
    ok "Kind cluster '${cluster_name}' created."
    check_kind_disk_pressure "${cluster_name}"
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
    "${SETUP_PYTHON}" - "${src}" "${dst}" <<'PY'
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
    local ACE_NS="ace"
    local mongo_user mongo_pass mongo_output infra_id access_key LITMUS_NS

    mongo_user="$(cur MONGODB_USERNAME)"; mongo_user="${mongo_user:-admin}"
    mongo_pass="$(cur MONGODB_PASSWORD)"; mongo_pass="${mongo_pass:-1234}"

    echo -e "${DIM}Syncing LitmusChaos subscriber-secret from active chaos infrastructure…${NC}"

    # Query the MongoDB the graphql server actually uses, so the subscriber-secret
    # matches what VerifyInfra() looks up at connection time.  In the k8s deployment
    # graphql, mongodb, and the litmus subscriber all run in-cluster, so the source
    # of truth is the mongodb-0 pod in the ace namespace.  Filter on is_registered
    # (set once at registration, stable) rather than is_active (flaps to false on
    # disconnect) — we are syncing precisely to recover from a disconnect. A given
    # infra can be re-registered multiple times over a cluster's life (each attempt
    # leaves behind a prior is_registered:true document with a stale infra_id that
    # is_registered alone can't distinguish from the current one), so sort by
    # created_at descending and take the newest non-removed match. Also pull
    # infra_namespace instead of assuming "litmus" — this infra may have been
    # connected into any namespace (e.g. "itbench").
    mongo_output="$(kubectl exec mongodb-0 -n "${ACE_NS}" -- mongosh \
        "mongodb://${mongo_user}:${mongo_pass}@localhost:27017/?authSource=admin&directConnection=true" \
        --quiet --eval \
        'var doc = db.getSiblingDB("litmus").chaosInfrastructures
             .find({is_registered:true, is_removed:{$ne:true}})
             .sort({created_at:-1}).limit(1).next();
         if(doc){ print("infra_id=" + doc.infra_id + "\naccess_key=" + doc.access_key + "\ninfra_namespace=" + doc.infra_namespace); }' \
        2>/dev/null)" || true

    if [[ -z "$mongo_output" ]]; then
        warn "No active chaos infrastructure found in MongoDB — skipping subscriber-secret sync."
        warn "Register an infrastructure via the LitmusChaos UI, then re-run: ./scripts/setup.sh --restart"
        return 0
    fi

    infra_id="$(echo "$mongo_output" | grep '^infra_id=' | cut -d= -f2- || true)"
    access_key="$(echo "$mongo_output" | grep '^access_key=' | cut -d= -f2- || true)"
    LITMUS_NS="$(echo "$mongo_output" | grep '^infra_namespace=' | cut -d= -f2- || true)"
    LITMUS_NS="${LITMUS_NS:-litmus}"

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

# _seed_flash_agent_experiment NAME DESCRIPTION EXPERIMENT_ID MANIFEST_TEMPLATE [CES_FILE]
# Idempotent: creates/updates a flash-agent ITBench experiment in ChaosCenter.
# Steps: (1) pull infra_id + project_id from MongoDB, (2) upsert the flash-agent-comprehensive-ces
# ConfigMap in itbench namespace (skipped if CES_FILE omitted — reuses whatever another seed call
# already applied, since the ConfigMap holds all 46 known ChaosExperiment CRDs), (3) register/update
# the experiment via saveChaosExperiment. Silently skips (with a warning) if the chaos
# infrastructure is not yet registered — the operator can re-run `./scripts/setup.sh --restart`
# after registering via the UI.
_seed_flash_agent_experiment() {
    local exp_name="$1" exp_description="$2" exp_id="$3" manifest_template="$4" ces_file="${5:-}"
    local ACE_NS="itbench"
    local PLATFORM_NS="ace"

    if [[ ! -f "${manifest_template}" ]] || { [[ -n "${ces_file}" ]] && [[ ! -f "${ces_file}" ]]; }; then
        warn "_seed_flash_agent_experiment(${exp_name}): source files missing from agents/harness/flash-agent/ — skipping"
        return 0
    fi

    echo -e "${DIM}Seeding ${exp_name} experiment…${NC}"

    # --- Step 1: infra_id + project_id from MongoDB ---
    # Pulled from the SAME chaosInfrastructures document (it already carries the
    # infra's own project_id) rather than a second, independent `auth.project`
    # lookup — a standalone project.findOne() would be just as non-deterministic
    # under multiple projects as the old infra lookup was under multiple
    # registrations, and worse, could return a project unrelated to the infra
    # actually being seeded against. Same is_registered + is_removed + newest
    # created_at selection as sync_subscriber_secret, for the same reason: an
    # infra can be re-registered multiple times, leaving stale documents behind.
    local mongo_user mongo_pass mongo_uri mongo_output infra_id project_id
    mongo_user="$(cur MONGODB_USERNAME)"; mongo_user="${mongo_user:-admin}"
    mongo_pass="$(cur MONGODB_PASSWORD)"; mongo_pass="${mongo_pass:-1234}"
    mongo_uri="mongodb://${mongo_user}:${mongo_pass}@localhost:27017/?authSource=admin&directConnection=true"

    mongo_output="$(kubectl exec mongodb-0 -n "${PLATFORM_NS}" -- \
        mongosh "${mongo_uri}" --quiet --eval \
        'var doc = db.getSiblingDB("litmus").chaosInfrastructures
             .find({is_registered:true, is_removed:{$ne:true}})
             .sort({created_at:-1}).limit(1).next();
         if(doc){ print("infra_id=" + doc.infra_id + "\nproject_id=" + doc.project_id); }' \
        2>/dev/null)" || true

    infra_id="$(echo "$mongo_output" | grep '^infra_id=' | cut -d= -f2- || true)"
    project_id="$(echo "$mongo_output" | grep '^project_id=' | cut -d= -f2- || true)"

    if [[ -z "${infra_id}" ]]; then
        warn "_seed_flash_agent_experiment(${exp_name}): no registered chaos infrastructure found."
        warn "  Register an infrastructure via the UI, then re-run: ./scripts/setup.sh --restart"
        return 0
    fi

    if [[ -z "${project_id}" ]]; then
        warn "_seed_flash_agent_experiment(${exp_name}): could not determine project ID — skipping."
        return 0
    fi

    # --- Step 2: upsert ConfigMap in itbench namespace ---
    if [[ -n "${ces_file}" ]]; then
        if kubectl get namespace "${ACE_NS}" >/dev/null 2>&1; then
            kubectl create configmap flash-agent-comprehensive-ces \
                --from-file=ces.yaml="${ces_file}" \
                -n "${ACE_NS}" \
                --dry-run=client -o yaml \
            | kubectl apply --server-side -f - >/dev/null 2>&1 \
            && ok "flash-agent-comprehensive-ces ConfigMap applied in namespace ${ACE_NS}" \
            || warn "_seed_flash_agent_experiment(${exp_name}): failed to apply ConfigMap — continuing"
        else
            warn "_seed_flash_agent_experiment(${exp_name}): namespace ${ACE_NS} not found — ConfigMap skipped"
        fi
    fi

    # --- Step 3: get JWT ---
    local auth_port admin_user admin_pass jwt
    auth_port="$(cur KIND_HOSTPORT_AUTH_REST)"; auth_port="${auth_port:-3000}"
    admin_user="$(cur ADMIN_USERNAME)"; admin_user="${admin_user:-admin}"
    admin_pass="$(cur ADMIN_PASSWORD)"; admin_pass="${admin_pass:-litmus}"

    jwt="$(curl -sf -X POST "http://localhost:${auth_port}/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${admin_user}\",\"password\":\"${admin_pass}\"}" \
        2>/dev/null \
        | "${SETUP_PYTHON}" -c "import sys,json; print(json.load(sys.stdin).get('accessToken',''))")" || true

    if [[ -z "${jwt}" ]]; then
        warn "_seed_flash_agent_experiment(${exp_name}): auth service login failed — experiment not registered."
        return 0
    fi

    # --- Step 4: saveChaosExperiment mutation ---
    local gql_port result
    gql_port="$(cur KIND_HOSTPORT_GRAPHQL_REST)"; gql_port="${gql_port:-8081}"

    result="$(INFRA_ID="${infra_id}" PROJECT_ID="${project_id}" JWT="${jwt}" \
        GQL_PORT="${gql_port}" MANIFEST_TEMPLATE="${manifest_template}" \
        EXP_NAME="${exp_name}" EXP_DESCRIPTION="${exp_description}" EXP_ID="${exp_id}" \
        "${SETUP_PYTHON}" - <<'PYEOF'
import json, sys, os, urllib.request, urllib.error

infra_id        = os.environ["INFRA_ID"]
project_id      = os.environ["PROJECT_ID"]
jwt             = os.environ["JWT"]
gql_port        = os.environ["GQL_PORT"]
manifest_tpl    = os.environ["MANIFEST_TEMPLATE"]
exp_name        = os.environ["EXP_NAME"]
exp_description = os.environ["EXP_DESCRIPTION"]
exp_id          = os.environ["EXP_ID"]

with open(manifest_tpl) as f:
    manifest = f.read().replace("__INFRA_ID__", infra_id)

payload = json.dumps({
    "query": (
        "mutation saveChaosExperiment($request: SaveChaosExperimentRequest!, $projectID: ID!) {"
        "  saveChaosExperiment(request: $request, projectID: $projectID)"
        "}"
    ),
    "variables": {
        "projectID": project_id,
        "request": {
            "id": exp_id,
            "type": "Experiment",
            "name": exp_name,
            "description": exp_description,
            "manifest": manifest,
            "infraID": infra_id,
            "tags": []
        }
    }
}).encode()

req = urllib.request.Request(
    f"http://localhost:{gql_port}/query",
    data=payload,
    headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {jwt}",
    }
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        d = json.loads(resp.read())
        if "errors" in d:
            print(f"ERROR: {d['errors'][0]['message']}", file=sys.stderr)
            sys.exit(1)
        print(d["data"]["saveChaosExperiment"])
except urllib.error.HTTPError as e:
    print(f"ERROR: HTTP {e.code} — {e.read().decode()[:200]}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    )" || { warn "_seed_flash_agent_experiment(${exp_name}): experiment registration failed (see above)."; return 0; }

    ok "${exp_name} registered in ChaosCenter (infra=${infra_id}, project=${project_id})"
}

# seed_flash_agent_comprehensive
# Registers flash-agent-comprehensive-30 (53-fault benchmark, 46 unique ChaosExperiment CRDs).
# Owns applying the flash-agent-comprehensive-ces ConfigMap — other seed_* callers that need a
# subset of the same CRDs rely on this one having run first (order in the caller below matters).
seed_flash_agent_comprehensive() {
    _seed_flash_agent_experiment \
        "flash-agent-comprehensive-30" \
        "Flash-agent 53-fault benchmark (30 runs per fault)" \
        "333bf972-dd5e-4d5a-96c2-92f10e668126" \
        "${REPO_ROOT}/agents/harness/flash-agent/flash-agent-comprehensive-30-manifest.json" \
        "${REPO_ROOT}/agents/harness/flash-agent/ces_for_apply.yaml"
}

# seed_flash_agent_5scenario
# Registers flash-agent-5scenario (5-fault ITBench spot-check: scaled-to-zero, nonexistent
# image, misconfigured readiness probe, modified target port, feature-flag flood). Unlike
# comprehensive-30, its 5 ChaosExperiment CRDs are embedded directly as inline workflow
# artifacts in the manifest itself (Chaos-Studio-editable shape — see install-chaos-experiments'
# inputs.artifacts) rather than applied from the external flash-agent-comprehensive-ces
# ConfigMap, so this has no dependency on seed_flash_agent_comprehensive having run first.
seed_flash_agent_5scenario() {
    _seed_flash_agent_experiment \
        "flash-agent-5scenario" \
        "Flash-agent 5-fault ITBench spot-check (scaled-to-zero, nonexistent image, readiness probe, target port, feature-flag flood)" \
        "c533c74e-c7e9-4ba8-ab96-7c29f191d6a8" \
        "${REPO_ROOT}/agents/harness/flash-agent/flash-agent-5scenario-manifest.json"
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
    local _kind_tmpdir; _kind_tmpdir="${ACE_KIND_LOAD_TMPDIR:-$(cur ACE_KIND_LOAD_TMPDIR)}"
    if [[ -n "${_kind_tmpdir}" ]]; then
        mkdir -p "${_kind_tmpdir}" || {
            warn "Could not create ACE_KIND_LOAD_TMPDIR='${_kind_tmpdir}' — falling back to kind's default temp directory."
            _kind_tmpdir=""
        }
    fi
    echo
    echo -e "${DIM}Loading ${#LOCAL_BUILT_IMAGES[@]} local image(s) into KinD cluster '${cluster_name}'…${NC}"
    for _img in "${LOCAL_BUILT_IMAGES[@]}"; do
        if TMPDIR="${_kind_tmpdir:-${TMPDIR:-/tmp}}" kind load docker-image "${_img}" --name "${cluster_name}"; then
            ok "  Loaded: ${_img}"
        else
            warn "  Failed to load ${_img} — pods may pull from Docker Hub instead"
        fi
    done
    unset _kind_tmpdir
}

# restart_locally_built_deployments NAMESPACE
# All agentcert/* images keep the ":latest" tag whether they were built locally
# or pulled from Docker Hub, and every Deployment uses imagePullPolicy:
# IfNotPresent (see deploy/helm/ace/values.yaml and deploy/k8s/*.yaml). That
# combination means a `helm upgrade`/`kubectl apply` that only rebuilds the
# same tag produces byte-identical manifests — Helm/kubectl see no diff and
# leave already-running pods alone, so freshly built local images sit unused
# in the node's containerd cache until something explicitly recreates the pod.
# Force that recreation here for every long-running platform Deployment we
# just rebuilt so `--local-build` actually reaches a cluster that was already
# up (first-time installs are unaffected since there's no prior pod to keep).
restart_locally_built_deployments() {
    local ns="$1"
    [[ "${DO_LOCAL_BUILD:-0}" -eq 1 ]] || return 0
    [[ ${#LOCAL_BUILT_IMAGES[@]} -eq 0 ]] && return 0
    local -A _img_to_deploy=(
        ["agentcert/agentcert-graphql"]="graphql"
        ["agentcert/agentcert-auth"]="auth"
        ["agentcert/agentcert-web"]="web"
        ["agentcert/certifier"]="certifier"
    )
    local _img _repo _dep
    for _img in "${LOCAL_BUILT_IMAGES[@]}"; do
        _repo="${_img%%:*}"
        _dep="${_img_to_deploy[${_repo}]:-}"
        [[ -z "${_dep}" ]] && continue
        if kubectl get deployment "${_dep}" -n "${ns}" >/dev/null 2>&1; then
            kubectl rollout restart "deployment/${_dep}" -n "${ns}" >/dev/null 2>&1 \
                && ok "  Restarted deployment/${_dep} to pick up freshly built local image" \
                || warn "  Failed to restart deployment/${_dep} — it may still be running the old image"
        fi
    done
}

# restart_subscriber_deployments
# Unlike graphql/auth/web/certifier (all fixed, single deployments in the
# "ace" namespace), the subscriber runs once per connected chaos infra, each
# in whatever namespace that infra was registered into — there is no single
# namespace to target. Roll out every subscriber Deployment cluster-wide so
# each already-connected infra picks up a freshly built local image; imagePullPolicy:
# Always on that container (see AgentCert manifests/namespace/3b_agents_deployment.yaml)
# means the restart alone is enough to re-pull, no reconnect/manifest regen needed.
restart_subscriber_deployments() {
    [[ "${DO_LOCAL_BUILD:-0}" -eq 1 ]] || return 0
    local _built
    for _built in "${LOCAL_BUILT_IMAGES[@]}"; do
        [[ "${_built%%:*}" == "agentcert/litmusportal-subscriber" ]] && break
        _built=""
    done
    [[ -z "${_built}" ]] && return 0

    local _targets
    _targets="$(kubectl get deployment -A -l app=subscriber -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
    [[ -z "${_targets}" ]] && return 0

    while read -r _sns _sdep; do
        [[ -z "${_sns}" ]] && continue
        kubectl rollout restart "deployment/${_sdep}" -n "${_sns}" >/dev/null 2>&1 \
            && ok "  Restarted deployment/${_sdep} in ${_sns} to pick up freshly built subscriber image" \
            || warn "  Failed to restart deployment/${_sdep} in ${_sns} — it may still be running the old image"
    done <<< "${_targets}"
}

# Offers to restore one of shut_down.sh's automatic MongoDB backups (see that
# script's header comment) into the MongoDB that was just deployed by
# helm_deploy/k8s_deploy. Each teardown leaves its own independent, timestamped
# archive rather than one shared file, so this lists all of them (newest
# first) and lets the user pick a specific generation — not just "the last
# one" — or start with a brand-new empty database instead. Only relevant right
# after a fresh KinD cluster + fresh MongoDB StatefulSet come up:
# dynamically-provisioned PVs get a brand-new, empty on-disk path every time a
# cluster is recreated, so PVC/PV *configuration* surviving does not carry
# data forward on its own — this is the actual restore side of that gap.
# Gated at the call site to SETUP_MODE=setup (never --restart) and
# EXPRESS_MODE=0 (interactive only, same visibility as the deploy_choice
# k/h/n prompt) so it never surprises a scripted/express run by silently
# overwriting a fresh database. Also records how the resulting database was
# started ("scratch" or a specific backup's filename) to a small marker file
# next to the backups, so the *next* backup shut_down.sh takes can say what
# it was started from — each entry in the list below shows that lineage for
# every existing backup, not just its timestamp/size.
offer_mongodb_restore() {
    local ns="ace"
    local inst; inst="$(cur ACE_INSTANCE_NAME)"
    local backup_dir="${REPO_ROOT}/.tmp/mongodb-backups/${inst}"
    # Where this function records how the currently-running database was
    # brought up ("scratch" or a backup filename) — shut_down.sh reads this
    # when it next takes a backup, so that backup's own .meta sidecar can say
    # what it was started from. Same file shut_down.sh's header comment
    # documents as MONGO_LINEAGE_FILE.
    local lineage_file="${backup_dir}/current-started-from"

    if ! kubectl get pod mongodb-0 -n "${ns}" >/dev/null 2>&1; then
        return 0   # nothing deployed (or deploy failed) — nothing to restore into, nothing to record
    fi

    local -a backups=()
    while IFS= read -r _f; do
        [[ -n "${_f}" ]] && backups+=("${_f}")
    done < <(ls -1t "${backup_dir}"/mongodb-*.archive.gz 2>/dev/null || true)
    if [[ ${#backups[@]} -eq 0 ]]; then
        # Nothing to offer, but the database is still definitionally starting
        # from scratch — record that so a later backup of it says so too.
        mkdir -p "${backup_dir}"
        echo "scratch" > "${lineage_file}"
        return 0
    fi

    echo
    echo -e "${CYAN}▸ Found ${#backups[@]} MongoDB backup(s) for this instance${NC}"
    echo -e "  ${BOLD}0${NC}) Start with a brand-new, empty database ${DIM}(default)${NC}"
    local _i _size _mtime _from
    for _i in "${!backups[@]}"; do
        _size="$(du -h "${backups[$_i]}" 2>/dev/null | cut -f1)"
        _mtime="$(date -r "${backups[$_i]}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || true)"
        _from="unknown"
        [[ -f "${backups[$_i]}.meta" ]] && _from="$(grep -m1 '^started_from=' "${backups[$_i]}.meta" 2>/dev/null | cut -d= -f2- || true)"
        [[ -z "${_from}" ]] && _from="unknown"
        echo -e "  ${BOLD}$((_i + 1))${NC}) $(basename "${backups[$_i]}")  ${DIM}(${_size:-?}, saved ${_mtime:-unknown time}$( [[ $_i -eq 0 ]] && echo ", most recent" ); started from: ${_from})${NC}"
    done
    unset _i _size _mtime _from

    local _choice _selected
    read -rp "$(echo -e "Restore which one into the freshly deployed MongoDB? ${DIM}[0-${#backups[@]}, default 0]${NC}: ")" _choice
    _choice="${_choice:-0}"
    if [[ "${_choice}" == "0" ]]; then
        say "${DIM}Skipped — the freshly deployed database stays empty.${NC}"
        echo "scratch" > "${lineage_file}"
        return 0
    fi
    if ! [[ "${_choice}" =~ ^[0-9]+$ ]] || [[ "${_choice}" -lt 1 || "${_choice}" -gt ${#backups[@]} ]]; then
        warn "  Invalid choice '${_choice}' — skipping restore. The freshly deployed database stays empty."
        echo "scratch" > "${lineage_file}"
        return 0
    fi
    _selected="${backups[$((_choice - 1))]}"
    # Recorded now, at the point of intent, not gated on mongorestore below
    # actually succeeding — if it fails, the warning already printed makes
    # that clear; this isn't a strict transactional guarantee, just provenance.
    echo "$(basename "${_selected}")" > "${lineage_file}"

    # k8s_deploy's rollout-status wait (and helm's post-install hook, for the
    # helm path) only confirm the mongodb Pod/StatefulSet is Ready, not that
    # mongodb-rs-init's replica-set initiation has actually finished — on the
    # kubectl-apply path that Job runs async, independent of k8s_deploy's own
    # wait. Poll directly instead of assuming either path's timing.
    local _mongo_user _mongo_pass _tries=0
    _mongo_user="$(cur MONGODB_USERNAME)"; _mongo_user="${_mongo_user:-admin}"
    _mongo_pass="$(cur MONGODB_PASSWORD)"; _mongo_pass="${_mongo_pass:-1234}"
    echo -e "${DIM}Waiting for MongoDB replica set to be ready…${NC}"
    until kubectl exec -n "${ns}" mongodb-0 -- mongosh --quiet \
            -u "${_mongo_user}" -p "${_mongo_pass}" --authenticationDatabase admin \
            --eval "db.adminCommand('ping').ok" 2>/dev/null | grep -q 1; do
        _tries=$((_tries + 1))
        if [[ ${_tries} -ge 20 ]]; then
            warn "  MongoDB never became ready — skipping restore. Restore manually once it is:"
            warn "  kubectl exec -n ${ns} mongodb-0 -- mongorestore --archive --gzip --drop -u ${_mongo_user} -p '<password>' --authenticationDatabase admin < ${_selected}"
            unset _mongo_user _mongo_pass _tries _choice _selected
            return 1
        fi
        sleep 3
    done

    if kubectl exec -i -n "${ns}" mongodb-0 -- mongorestore --archive --gzip --drop \
            -u "${_mongo_user}" -p "${_mongo_pass}" --authenticationDatabase admin \
            < "${_selected}" >/dev/null 2>&1; then
        ok "  MongoDB restored from $(basename "${_selected}")"
    else
        warn "  mongorestore failed — check: kubectl logs -n ${ns} mongodb-0"
    fi
    unset _mongo_user _mongo_pass _tries _choice _selected
}

# --- Overlap prepare-images.sh with the deploy's own long blocking wait -----
# (helm's mongodb-rs-init hook, ~2-5 min; k8s_deploy's "wait for core
# services" rollout, up to 5 min). prepare-images.sh only needs kubectl
# reachable + the KinD cluster to exist (both already true by the time these
# are called below) -- it does NOT need mongodb/graphql/anything the blocking
# wait is actually waiting on, so there is no reason to make it wait in line
# behind them. This only ever matters when INSTALL_APP_IMAGE_SOURCE/
# INSTALL_AGENT_IMAGE_SOURCE/LITMUS_IMAGES_SOURCE is local or jfrog -- the
# default (dockerhub for all three) makes this a no-op, same as before.
# _PREPARE_IMAGES_LAUNCHED keeps this from running twice: once here in the
# background, and once more via the old unconditional call further down in
# the outer script (which still runs it -- synchronously, via the same two
# functions -- for the deploy_choice=skip case, where there's nothing to
# overlap with).
_PREPARE_IMAGES_LAUNCHED=0
_PREPARE_IMAGES_PID=""
_PREPARE_IMAGES_LOG=""
maybe_launch_prepare_images_bg() {
    [[ "${_PREPARE_IMAGES_LAUNCHED}" -eq 1 ]] && return 0
    _PREPARE_IMAGES_LAUNCHED=1
    local app_src agent_src litmus_src
    app_src="$(cur INSTALL_APP_IMAGE_SOURCE)"
    agent_src="$(cur INSTALL_AGENT_IMAGE_SOURCE)"
    litmus_src="$(cur LITMUS_IMAGES_SOURCE)"
    if [[ "${app_src}" == "local" || "${app_src}" == "jfrog" || \
          "${agent_src}" == "local" || "${agent_src}" == "jfrog" || \
          "${litmus_src}" == "local" ]]; then
        mkdir -p "${REPO_ROOT}/.tmp"
        _PREPARE_IMAGES_LOG="${REPO_ROOT}/.tmp/prepare-images.log"
        echo -e "${DIM}Preparing experiment images in the background while the cluster comes up ...${NC}"
        echo -e "${DIM}  Progress: tail -f ${_PREPARE_IMAGES_LOG}${NC}"
        "${REPO_ROOT}/scripts/prepare-images.sh" >"${_PREPARE_IMAGES_LOG}" 2>&1 &
        _PREPARE_IMAGES_PID=$!
    fi
}
wait_for_prepare_images_bg() {
    if [[ -n "${_PREPARE_IMAGES_PID}" ]]; then
        echo -e "${DIM}Waiting for background experiment-image prep (PID ${_PREPARE_IMAGES_PID})...${NC}"
        if wait "${_PREPARE_IMAGES_PID}"; then
            ok "Experiment images prepared."
        else
            warn "Background experiment-image prep failed (see ${_PREPARE_IMAGES_LOG}) -- re-run scripts/prepare-images.sh manually."
        fi
        _PREPARE_IMAGES_PID=""
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
    elif [[ -n "${_KIND_PREWARM_PID:-}" ]]; then
        echo -e "${DIM}Waiting for background kind cluster pre-warm (PID ${_KIND_PREWARM_PID})…${NC}"
        if wait "${_KIND_PREWARM_PID}"; then
            ok "kind cluster pre-warmed while images were building."
        else
            warn "Background kind cluster pre-warm failed (see .tmp/kind-prewarm.log) — retrying in the foreground."
            ensure_kind_cluster
        fi
        unset _KIND_PREWARM_PID
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

    # 3b) Kick off experiment-image prep now so it overlaps with the long
    # "wait for core services" rollout below instead of running after it.
    maybe_launch_prepare_images_bg

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

    # 8b) --local-build against an already-running cluster: force a restart so
    # the freshly built/kind-loaded images are actually picked up (see comment
    # on restart_locally_built_deployments — same tag + IfNotPresent means
    # `kubectl apply` alone leaves existing pods on the old image).
    restart_locally_built_deployments "${NS}"
    restart_subscriber_deployments

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

    # 9a) Reap the experiment-image prep kicked off in the background above.
    wait_for_prepare_images_bg

    # 9b) Cloud: poll LB IP, update .env with real external endpoint, restart pods
    if [[ "${CLUSTER_MODE}" == "cloud" ]]; then
        post_cloud_setup "${NS}"
    fi

    # 9c) Sync LitmusChaos subscriber-secret from MongoDB (no-op if not yet registered)
    sync_subscriber_secret

    # 9d) Seed flash-agent-comprehensive-30 experiment (idempotent; no-op if infra not yet registered)
    seed_flash_agent_comprehensive

    # 9e) Seed flash-agent-5scenario experiment (idempotent; self-contained, no ConfigMap needed)
    seed_flash_agent_5scenario

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
    "${SETUP_PYTHON}" - "${ENV_FILE}" "${out}" "${litellm_cfg}" <<'PY'
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
    elif [[ -n "${_KIND_PREWARM_PID:-}" ]]; then
        echo -e "${DIM}Waiting for background kind cluster pre-warm (PID ${_KIND_PREWARM_PID})…${NC}"
        if wait "${_KIND_PREWARM_PID}"; then
            ok "kind cluster pre-warmed while images were building."
        else
            warn "Background kind cluster pre-warm failed (see .tmp/kind-prewarm.log) — retrying in the foreground."
            ensure_kind_cluster
        fi
        unset _KIND_PREWARM_PID
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

    # 3b) Kick off experiment-image prep now so it overlaps with the
    # mongodb-rs-init helm hook wait below instead of running after it.
    maybe_launch_prepare_images_bg

    # 4) Generate values-env.yaml (helm reads this to create the ace-env Secret)
    echo -e "${DIM}Generating values-env.yaml from .env…${NC}"
    generate_helm_values_env

    # 4b) Create namespace + CA cert ConfigMap before helm installs pods
    kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo -e "${DIM}Creating/updating ace-ca-certs ConfigMap…${NC}"
    create_ca_configmap "${NS}"

    # 5) Run helm — it owns namespace, secret, and all workloads
    if ! command -v helm >/dev/null 2>&1; then
        warn "helm not found on PATH — cannot deploy. Install it, e.g.:"
        warn "  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod 700 get_helm.sh && ./get_helm.sh"
        return 1
    fi
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
    # The certifier's cert-report-export hostPath volume only makes sense against a
    # KinD cluster this repo's own render-kind-config.sh created (its extraMounts
    # bridge the node path to a real host directory) — an existing/external
    # kubeconfig (cloud or a pre-existing local cluster) has no such bridge, so
    # disable it there rather than mounting an unbridged, node-ephemeral path.
    if [[ "${CLUSTER_MODE}" == "cloud" || "${CLUSTER_MODE}" == "local" ]]; then
        helm_cmd+=(--set certHostExport.enabled=false)
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
    local helm_rc=0
    set +e
    "${helm_cmd[@]}"
    helm_rc=$?
    # Stop the pod-watch loop. `wait` on a just-killed job returns 143
    # (128+SIGTERM); the `2>/dev/null` only hides its stderr, so with `set -e`
    # already restored this line would abort the whole script *right after a
    # successful Helm deploy* — silently skipping every post-deploy step
    # (restart_locally_built_deployments, host-service wiring, subscriber-secret
    # sync, experiment seeding). Reap it while -e is still off and swallow the
    # signal exit explicitly.
    kill "${_HELM_WATCH_PID}" 2>/dev/null || true
    wait "${_HELM_WATCH_PID}" 2>/dev/null || true
    unset _HELM_WATCH_PID
    set -e
    if [[ ${helm_rc} -ne 0 ]]; then
        warn "helm upgrade --install failed (exit ${helm_rc})."
        return 1
    fi

    # 5a0) Reap the experiment-image prep kicked off in the background above.
    wait_for_prepare_images_bg

    # 5a) --local-build against an already-running release: force a restart so
    # the freshly built/kind-loaded images are actually picked up (see comment
    # on restart_locally_built_deployments — same tag + IfNotPresent means a
    # no-diff `helm upgrade` leaves existing pods on the old image).
    restart_locally_built_deployments "${NS}"
    restart_subscriber_deployments

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
        #
        # Preferred wiring (KinD): attach the Ollama container directly to the
        # cluster's own Docker network and point the Endpoints at its address on
        # that network, port 11434. The obvious-looking alternative — Endpoints →
        # ${CALLBACK_HOST}:${ollama_port} (the host-published port) — does NOT
        # work on every host: a KinD node container reaching the host bridge
        # gateway on a *published* port depends on Docker's inter-bridge
        # forwarding rules, which some hosts' firewall/DOCKER-USER config drops
        # silently (curl from the node just times out). Joining the same network
        # sidesteps the host hop entirely. Falls back to ${CALLBACK_HOST}:${ollama_port}
        # when the container or network can't be resolved (e.g. k3s, where the
        # cni0-gateway path does work).
        # NB: every substitution below is `|| true`-guarded and pipe-free — this
        # runs under `set -euo pipefail`, so a failing `docker inspect` or a
        # `grep|head` SIGPIPE would otherwise abort the whole deploy here.
        local ollama_ctr ollama_net ollama_ep_ip ollama_ep_port _oip
        ollama_ctr="ollama-${ACE_INSTANCE_NAME:-$(id -un || true)}"
        ollama_net="$(docker inspect "${KIND_CLUSTER_NAME:-agentcert}-control-plane" \
            --format '{{range $n,$_ := .NetworkSettings.Networks}}{{$n}} {{end}}' 2>/dev/null || true)"
        ollama_net="${ollama_net%% *}"   # first network name (KinD node → "kind"); no pipeline
        ollama_ep_ip="${CALLBACK_HOST}"
        ollama_ep_port="${ollama_port}"
        if [[ -n "${ollama_net}" ]] && docker inspect "${ollama_ctr}" >/dev/null 2>&1; then
            docker network connect "${ollama_net}" "${ollama_ctr}" >/dev/null 2>&1 || true
            _oip="$(docker inspect "${ollama_ctr}" \
                --format "{{with index .NetworkSettings.Networks \"${ollama_net}\"}}{{.IPAddress}}{{end}}" 2>/dev/null || true)"
            if [[ -n "${_oip}" ]]; then
                ollama_ep_ip="${_oip}"
                ollama_ep_port="11434"
                echo -e "${DIM}  Ollama container '${ollama_ctr}' attached to '${ollama_net}' network → ${ollama_ep_ip}:11434${NC}"
            fi
            unset _oip
        fi
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
      targetPort: ${ollama_ep_port}
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
      - ip: ${ollama_ep_ip}
    ports:
      - port: ${ollama_ep_port}
        name: ollama
        protocol: TCP
OLLAMA_SVC_EOF
        # Verify both objects actually landed rather than trusting a silent
        # success. This step has previously gone missing from a live cluster
        # with no error anywhere (e.g. after a raw `helm upgrade` bypassing
        # setup.sh, or a namespace recreate) -- the Ollama-routed model alias
        # then fails in-cluster with a DNS lookup failure that looks nothing
        # like "the wiring step never ran," costing real debugging time. Fail
        # loudly here instead so a broken/missing wiring is caught at deploy
        # time, not discovered later via a failed experiment run.
        if ! kubectl get endpoints litellm -n "${NS}" >/dev/null 2>&1; then
            warn "litellm.${NS}.svc.cluster.local Endpoints missing after apply — host LiteLLM will be unreachable in-cluster."
        fi
        if ! kubectl get svc ollama -n "${NS}" >/dev/null 2>&1 || ! kubectl get endpoints ollama -n "${NS}" >/dev/null 2>&1; then
            warn "ollama.${NS}.svc.cluster.local Service/Endpoints missing after apply — any FLASH_AGENT_MODEL/MODEL_ALIAS routed to the Ollama alias will fail in-cluster with a DNS lookup failure, even if AZURE/GEMINI credentials are also configured. Re-run ./scripts/setup.sh --restart, or apply this section manually."
        else
            ok "Host services wired: litellm.${NS}.svc.cluster.local:14000, ollama.${NS}.svc.cluster.local:11434 → ${ollama_ep_ip}:${ollama_ep_port}"
        fi
    fi

    # 5d) Sync LitmusChaos subscriber-secret from MongoDB (no-op if not yet registered).
    # Mirrors k8s_deploy's step 9c — without this, helm_deploy (the default deploy
    # path: deploy_choice defaults to "h") never runs the instanceID self-heal at
    # all, silently leaving a re-registered chaos infrastructure's workflow-controller
    # pinned to a stale instanceID with every submitted experiment workflow orphaned.
    sync_subscriber_secret

    # 5e) Seed flash-agent-comprehensive-30 experiment (idempotent; no-op if infra not yet registered)
    seed_flash_agent_comprehensive

    # 5f) Seed flash-agent-5scenario experiment (idempotent; self-contained, no ConfigMap needed)
    seed_flash_agent_5scenario

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

# --- Pre-warm KinD cluster in background (express mode only) ----------------
# ensure_kind_cluster's `kind create cluster` step (~1-2 min) has no
# dependency on the Docker builds below — images are only kind-loaded AFTER
# the cluster exists (see step 2b inside k8s_deploy/helm_deploy). Only
# express mode has resolved both the deploy target (_DEPLOY_CHOICE) and
# CLUSTER_MODE before builds start; guided mode still asks "deploy now?"
# after the build loop finishes, so there's nothing to pre-warm against here
# — it keeps calling ensure_kind_cluster in the foreground as before.
# k8s_deploy/helm_deploy below pick this job up instead of re-running
# ensure_kind_cluster from scratch. stdin is redirected from /dev/null so a
# background hit of the "recreate cluster?" prompt inside ensure_kind_cluster
# can't contend with the foreground shell for the terminal — it resolves to
# the same safe non-destructive default (skip recreation) that an unattended
# EOF would give it either way.
_KIND_PREWARM_PID=""
if [[ ${EXPRESS_MODE} -eq 1 && ( "${_DEPLOY_CHOICE,,}" == "h" || "${_DEPLOY_CHOICE,,}" == "k" ) \
      && "${CLUSTER_MODE}" != "local" && "${CLUSTER_MODE}" != "cloud" ]]; then
    mkdir -p "${REPO_ROOT}/.tmp"
    _KIND_PREWARM_LOG="${REPO_ROOT}/.tmp/kind-prewarm.log"
    echo -e "${DIM}Pre-warming kind cluster in the background while images build …${NC}"
    echo -e "${DIM}  Progress: tail -f ${_KIND_PREWARM_LOG}${NC}"
    ( ensure_kind_cluster ) </dev/null >"${_KIND_PREWARM_LOG}" 2>&1 &
    _KIND_PREWARM_PID=$!
fi

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
        # Fingerprint file consumed by the --restart staleness check above
        # (git SHA + dirty-file-count per image's source dir, keyed by the
        # ALL_BUILD_IMAGES entry number). Reset on every real build attempt so
        # it only ever reflects sources actually rebuilt just now.
        _FP_FILE="${REPO_ROOT}/.tmp/ace-build-fingerprints.env"
        mkdir -p "${REPO_ROOT}/.tmp"
        : > "${_FP_FILE}"

        # Images build (and push) in parallel, bounded, instead of one at a
        # time -- each entry is an independent Dockerfile/context (or
        # docker-compose service) with zero dependency on any other, so
        # serializing them was pure wall-clock waste. Bounded rather than
        # unbounded because this is frequently a shared host (CLAUDE.md §0)
        # and unlimited concurrent `docker build`/`docker push` can thrash
        # disk I/O for everyone else on it. The default is derived from this
        # host's own CPU count (CLAUDE.md §0.1: detect host-specific
        # variability rather than hardcoding an observed value) -- half of
        # nproc, floored at 1 and capped at 6, so a small VM doesn't get
        # oversubscribed and a big shared box doesn't get hammered by one
        # checkout's build. Override via ACE_BUILD_PARALLELISM if a given
        # host needs something else. Each build runs in its own background
        # subshell -- variables it sets do NOT survive back to this shell --
        # so results are hand-off via small per-image files in a scratch
        # dir, then reassembled into LOCAL_BUILT_IMAGES/BUILD_FAILED/the
        # fingerprint file below, once every job is done.
        _BUILD_CPU_COUNT="$(nproc 2>/dev/null || echo 4)"
        _BUILD_PARALLELISM_DEFAULT=$(( _BUILD_CPU_COUNT / 2 ))
        (( _BUILD_PARALLELISM_DEFAULT < 1 )) && _BUILD_PARALLELISM_DEFAULT=1
        (( _BUILD_PARALLELISM_DEFAULT > 6 )) && _BUILD_PARALLELISM_DEFAULT=6
        _BUILD_PARALLELISM="${ACE_BUILD_PARALLELISM:-${_BUILD_PARALLELISM_DEFAULT}}"
        # Per-image build-log location. Overridable so a host whose checkout
        # root is on a small/cramped filesystem can send these elsewhere
        # (CLAUDE.md §0.1: encode host-specific variability rather than
        # hardcoding an observed path): ACE_BUILD_LOG_DIR in the environment
        # wins, then the same key in .env, then the in-checkout default. Must
        # be an absolute path — the resolved dir is wiped and recreated on
        # every build, so a handful of obviously-catastrophic values (/,
        # $HOME, the repo root itself, a bare relative name) are rejected
        # back to the default rather than rm -rf'd.
        _BUILD_LOG_DIR="${ACE_BUILD_LOG_DIR:-$(cur ACE_BUILD_LOG_DIR)}"
        _BUILD_LOG_DIR="${_BUILD_LOG_DIR:-${REPO_ROOT}/.tmp/build-logs}"
        _BUILD_LOG_DIR="${_BUILD_LOG_DIR%/}"
        case "${_BUILD_LOG_DIR}" in
            ""|/|"${HOME}"|"${REPO_ROOT}")
                warn "ACE_BUILD_LOG_DIR resolves to an unsafe path ('${_BUILD_LOG_DIR}') — it is wiped on every build; using ${REPO_ROOT}/.tmp/build-logs instead"
                _BUILD_LOG_DIR="${REPO_ROOT}/.tmp/build-logs" ;;
            /*) : ;;
            *)
                warn "ACE_BUILD_LOG_DIR='${_BUILD_LOG_DIR}' is not an absolute path — using ${REPO_ROOT}/.tmp/build-logs instead"
                _BUILD_LOG_DIR="${REPO_ROOT}/.tmp/build-logs" ;;
        esac
        _BUILD_RESULTS_DIR="$(mktemp -d "${REPO_ROOT}/.tmp/build-results.XXXXXX")"
        rm -rf "${_BUILD_LOG_DIR}"; mkdir -p "${_BUILD_LOG_DIR}"

        _build_one_entry() {
            # Runs in a background subshell (see caller) — every line of
            # output goes to this image's own log file so N concurrent builds
            # don't interleave garbage on the terminal.
            local entry="$1" idx="$2"
            local num label img ctx df method tag svc build_ok=0
            IFS='|' read -r num label img ctx df method <<< "${entry}"
            if [[ "${img}" == *:* ]]; then tag="${img}"; else tag="${img}:latest"; fi
            {
                echo "▸ ${tag}  (${label})"
                # --no-cache on every path below by default: BuildKit was observed
                # reusing a stale `COPY . .` (and even downstream RUN, e.g. `go
                # build`) layer across --local-build runs even though the source
                # tree had genuinely changed between them — the resulting image
                # silently shipped old code with a fresh-looking build timestamp
                # and no error of any kind. Originally worked around for "web"
                # only (compose build method) on the assumption it was specific to
                # compose's bake driver; confirmed 2026-08-25 that the identical
                # symptom hits the plain `docker build` path too (graphql's build
                # replayed a fully cached layer graph — including `COPY . /gql-server`
                # and the `go build` step — despite the submodule genuinely being at
                # a newer commit), so this is now applied to both paths rather than
                # just compose:*. --allow-build-cache (see flag docs above) opts back
                # into normal caching for a faster inner dev loop, at the cost of
                # reintroducing the staleness risk this exists to close — off by
                # default on purpose.
                _no_cache_flag="--no-cache"
                [[ "${ALLOW_BUILD_CACHE:-0}" -eq 1 ]] && _no_cache_flag=""
                if [[ "${method}" == compose:* ]]; then
                    svc="${method#compose:}"
                    ( cd "${REPO_ROOT}" && docker compose build ${_no_cache_flag} "${svc}" ) && build_ok=1
                elif [[ ! -f "${ctx}/${df}" ]]; then
                    echo "Dockerfile not found: ${ctx}/${df}"
                else
                    docker build ${_no_cache_flag} -t "${tag}" -f "${ctx}/${df}" "${ctx}" && build_ok=1
                fi
                if [[ "${build_ok}" -eq 1 ]]; then
                    echo "${tag}" > "${_BUILD_RESULTS_DIR}/${idx}.built"
                    # Fingerprint for the --restart staleness check (see
                    # above) — ctx is empty for the compose:web entry (built
                    # via docker-compose.yml, not a single source dir), so
                    # there's nothing meaningful to fingerprint there.
                    if [[ -n "${ctx}" && -d "${ctx}" ]]; then
                        echo "IMG_${num}=$(git -C "${ctx}" rev-parse HEAD 2>/dev/null || echo unknown):$(git -C "${ctx}" status --porcelain -- . 2>/dev/null | wc -l | tr -d ' ')" \
                            > "${_BUILD_RESULTS_DIR}/${idx}.fp"
                    fi
                    if [[ "${DO_BUILD}" -eq 1 ]]; then
                        if docker push "${tag}"; then
                            echo pushed > "${_BUILD_RESULTS_DIR}/${idx}.status"
                        else
                            echo "push-failed" > "${_BUILD_RESULTS_DIR}/${idx}.status"
                            echo "${label} (push)" > "${_BUILD_RESULTS_DIR}/${idx}.reason"
                        fi
                    else
                        echo built > "${_BUILD_RESULTS_DIR}/${idx}.status"
                    fi
                else
                    echo "build-failed" > "${_BUILD_RESULTS_DIR}/${idx}.status"
                    echo "${label} (build)" > "${_BUILD_RESULTS_DIR}/${idx}.reason"
                fi
            } >"${_BUILD_LOG_DIR}/${idx}.log" 2>&1
        }

        echo -e "${DIM}Building ${#SELECTED_BUILD_IMAGES[@]} image(s), up to ${_BUILD_PARALLELISM} at a time — per-image logs: ${_BUILD_LOG_DIR}/${NC}"
        _idx=0
        # Bare `wait -n` (no PID/jobspec args) waits for ANY background job of
        # this shell -- not just the build jobs launched in this loop. Other
        # long-lived untracked background jobs (_KIND_PREWARM_PID, launched
        # above; _OLLAMA_PULL_PID, launched much earlier during the interactive
        # prompts) are frequently still in flight here and aren't reaped until
        # long after this loop returns. If one of THOSE finishes first with a
        # non-zero exit (e.g. the kind-prewarm ownership guard refusing an
        # unmarked cluster), `wait -n` returns that unrelated failure, and
        # under `set -euo pipefail` with no ERR trap this loop -- and the
        # entire script -- dies silently mid-build with no message at all,
        # having built only whichever images happened to be in the first
        # batch. Track this loop's own job PIDs explicitly and pass them to
        # `wait -n` so it can only ever observe jobs this loop actually
        # launched.
        _build_pids=()
        for _entry in "${SELECTED_BUILD_IMAGES[@]}"; do
            _build_one_entry "${_entry}" "${_idx}" &
            _build_pids+=("$!")
            _idx=$(( _idx + 1 ))
            if (( ${#_build_pids[@]} >= _BUILD_PARALLELISM )); then
                wait -n "${_build_pids[@]}" || true
                _still_running=()
                for _pid in "${_build_pids[@]}"; do
                    kill -0 "${_pid}" 2>/dev/null && _still_running+=("${_pid}")
                done
                _build_pids=("${_still_running[@]}")
            fi
        done
        # Wait only for this loop's own remaining build jobs -- NOT a bare
        # `wait`, which would also block on unrelated long-lived background
        # jobs (_OLLAMA_PULL_PID, _KIND_PREWARM_PID) that aren't reaped until
        # much later in the script.
        [[ ${#_build_pids[@]} -gt 0 ]] && wait "${_build_pids[@]}"
        echo

        # Reassemble each job's outcome, in original selection order, into
        # the same state the old sequential loop produced (LOCAL_BUILT_IMAGES,
        # BUILD_FAILED, the fingerprint file), so everything downstream of
        # this block — kind load, the --restart staleness check, the
        # ACE_ALREADY_BUILT_IMAGES export — is unaffected by the parallelism.
        for (( _i = 0; _i < _idx; _i++ )); do
            IFS='|' read -r _num _label _img _ctx _df _method <<< "${SELECTED_BUILD_IMAGES[_i]}"
            if [[ "${_img}" == *:* ]]; then _tag="${_img}"; else _tag="${_img}:latest"; fi
            _status="$(cat "${_BUILD_RESULTS_DIR}/${_i}.status" 2>/dev/null || echo "")"
            case "${_status}" in
                built)  ok "  Built ${_tag}  (${_label})" ;;
                pushed) ok "  Built + pushed ${_tag}  (${_label})" ;;
                *)
                    _reason="$(cat "${_BUILD_RESULTS_DIR}/${_i}.reason" 2>/dev/null || echo "${_label}")"
                    warn "  Failed: ${_tag}  (${_label}) — log: ${_BUILD_LOG_DIR}/${_i}.log"
                    BUILD_FAILED+=("${_reason}")
                    ;;
            esac
            [[ -f "${_BUILD_RESULTS_DIR}/${_i}.built" ]] && LOCAL_BUILT_IMAGES+=("$(cat "${_BUILD_RESULTS_DIR}/${_i}.built")")
            [[ -f "${_BUILD_RESULTS_DIR}/${_i}.fp" ]] && cat "${_BUILD_RESULTS_DIR}/${_i}.fp" >> "${_FP_FILE}"
        done
        rm -rf "${_BUILD_RESULTS_DIR}"
        unset -f _build_one_entry
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
    unset _build_ready _FP_FILE _fp_sha _fp_dirty _BUILD_PARALLELISM _BUILD_LOG_DIR _BUILD_RESULTS_DIR _idx _i _status _reason _build_pids _still_running _pid
    echo -e "${CYAN}=======================================================${NC}"
    echo
fi

# Tell prepare-images.sh (invoked below, for LITMUS_IMAGES_SOURCE=local or
# JFrog secret setup) which images this run already built + kind-loaded, so
# its own "local" branches for install-app/install-agent don't redundantly
# rebuild + reload images the loop above just built. Confirmed redundancy:
# choosing "a" (build ALL locally) sets INSTALL_APP_IMAGE_SOURCE=local and
# INSTALL_AGENT_IMAGE_SOURCE=local *and* includes those same two images in
# ALL_BUILD_IMAGES (entries 3/4) — without this, agentcert-install-app and
# agentcert-install-agent were `docker build`+`kind load`ed once here and
# then a second time, from scratch, inside prepare-images.sh, on every "build
# ALL locally" run. Empty when nothing was built this run (e.g. plain
# --restart), which leaves prepare-images.sh's standalone behavior unchanged.
export ACE_ALREADY_BUILT_IMAGES="${LOCAL_BUILT_IMAGES[*]:-}"

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
    read -rp "$(echo -e "Choice ${DIM}[k/H/n]${NC}: ")" deploy_choice
fi
deploy_choice="${deploy_choice:-${_DEPLOY_CHOICE:-h}}"
case "${deploy_choice,,}" in
    k) k8s_deploy ;;
    h) helm_deploy ;;
    *) echo -e "${DIM}Skipped — run './scripts/setup.sh' again and choose k or h to deploy.${NC}" ;;
esac

# Offer to restore a shut_down.sh MongoDB backup — only in the interactive,
# non---restart wizard (never surprise an express/scripted/--restart run),
# and only when something was actually deployed this run.
if [[ "${SETUP_MODE}" == "setup" && $EXPRESS_MODE -eq 0 \
      && ( "${deploy_choice,,}" == "h" || "${deploy_choice,,}" == "k" ) ]]; then
    offer_mongodb_restore
fi

# --- Prepare experiment images -----------------------------------------------
# Runs whenever any image source is non-default (local or jfrog). If the
# stack was actually deployed just now (choice k/h above), this already ran
# in the background — overlapped with that deploy's own long blocking wait
# (mongodb-rs-init hook for helm, "wait for core services" for kubectl) via
# maybe_launch_prepare_images_bg/wait_for_prepare_images_bg inside
# k8s_deploy/helm_deploy — so both calls below are then a no-op
# (_PREPARE_IMAGES_LAUNCHED is already 1, _PREPARE_IMAGES_PID already reaped).
# When deploy was skipped (choice n) neither ran yet, so this launches +
# immediately waits, i.e. behaves exactly like the old synchronous call.
maybe_launch_prepare_images_bg
wait_for_prepare_images_bg

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
