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
MIN_HELM="3.12.0"
MIN_NODE="20.0.0"

CHECK_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CHECK_REPO_ROOT="$(cd -P "${CHECK_SCRIPT_DIR}/.." && pwd -P)"
FULL_DEP_AUDIT="${ACE_PREREQ_FULL_DEP_AUDIT:-0}"
FAIL_ON_DEP_ISSUES="${ACE_PREREQ_FAIL_ON_DEP_ISSUES:-0}"
PREFERRED_AUDIT_PYTHON="${ACE_PREREQ_PYTHON_BIN:-}"

# Reuse the caller's colors/helpers when sourced from a script that already
# defines them (setup.sh); define our own otherwise so this also works run
# standalone.
if ! declare -F ok >/dev/null 2>&1; then
    BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'
    say()  { echo -e "$*"; }
    ok()   { echo -e "${GREEN}✓${NC} $*"; }
    warn() { echo -e "${YELLOW}!${NC} $*"; }
else
    RED="${RED:-\033[0;31m}"
    NC="${NC:-\033[0m}"
fi
err()  { echo -e "${RED}✗${NC} $*" >&2; }

_extract_ver() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "$1" | head -1; }

# version_ge A B → true if version A >= version B (dotted numeric compare via sort -V)
version_ge() {
    [[ "$1" == "$2" ]] && return 0
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

CHECK_FAILED=0
BASE_REQ_FAILED=0
DEP_AUDIT_FAILED=0
PYTHON312_BIN=""

echo
echo -e "${CYAN}--- Checking prerequisites ---${NC}"

# --- Docker Engine + Compose v2 (hard required) -------------------------------
if ! command -v docker >/dev/null 2>&1; then
    err "docker not found (required)."
    warn "  Ubuntu/Debian:  sudo apt update && sudo apt install -y docker.io && sudo usermod -aG docker \$USER   (then log out/in)"
    warn "  Or: install Docker Desktop with WSL2 integration if running under WSL."
    CHECK_FAILED=1
    BASE_REQ_FAILED=1
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
        BASE_REQ_FAILED=1
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
    BASE_REQ_FAILED=1
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

if ! command -v helm >/dev/null 2>&1; then
    warn "helm not found -- only needed if you plan to deploy to Kubernetes (skip if Compose-only)."
    warn "  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod 700 get_helm.sh && ./get_helm.sh"
else
    _hv="$(_extract_ver "$(helm version --short 2>/dev/null)")"
    if [[ -n "$_hv" ]] && version_ge "$_hv" "$MIN_HELM"; then
        ok "helm ${_hv}"
    else
        warn "helm ${_hv:-unknown} found, but ${MIN_HELM}+ is recommended."
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

# --- Optional: full dependency audits (enabled by setup.sh) -------------------
# Verifies manifest-declared dependencies for Python/Node/Go are available.
# These checks are informational by default so setup can still proceed on hosts
# that only need a subset of the monorepo. Set ACE_PREREQ_FAIL_ON_DEP_ISSUES=1
# to enforce strict failure when any language dependency audit reports gaps.
if [[ "${FULL_DEP_AUDIT}" == "1" ]]; then
    REPORT_DIR="${CHECK_REPO_ROOT}/.tmp/prereq"
    mkdir -p "${REPORT_DIR}"

    pick_python_for_audit() {
        if [[ -n "${PREFERRED_AUDIT_PYTHON}" && -x "${PREFERRED_AUDIT_PYTHON}" ]]; then
            echo "${PREFERRED_AUDIT_PYTHON}"
            return 0
        fi
        if [[ -x "${CHECK_REPO_ROOT}/.venv/bin/python" ]]; then
            echo "${CHECK_REPO_ROOT}/.venv/bin/python"
            return 0
        fi
        if [[ -n "${PYTHON312_BIN}" && -x "${PYTHON312_BIN}" ]]; then
            echo "${PYTHON312_BIN}"
            return 0
        fi
        if command -v python3 >/dev/null 2>&1; then
            command -v python3
            return 0
        fi
        return 1
    }

    PY_AUDIT_BIN=""
    if PY_AUDIT_BIN="$(pick_python_for_audit)"; then
        PY_AUDIT_REPORT="${REPORT_DIR}/python-dependency-audit.txt"
        set +e
        "${PY_AUDIT_BIN}" - "${CHECK_REPO_ROOT}" "${PY_AUDIT_REPORT}" <<'PY'
from __future__ import annotations

import re
import sys
import tomllib
from collections import Counter
from importlib import metadata
from pathlib import Path

from packaging.markers import default_environment
from packaging.requirements import Requirement

repo_root = Path(sys.argv[1])
report_file = Path(sys.argv[2])
env = default_environment()
skip_dirs = {".git", ".venv", "node_modules", "__pycache__", ".pytest_cache", ".tmp", "site-packages"}


def skipped(path: Path) -> bool:
    return any(part in skip_dirs or part.startswith(".venv") for part in path.parts)


def requirement_specs(path: Path):
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith(("-r ", "--requirement ", "-c ", "--constraint ")):
            continue
        line = re.split(r"\s+#", line, 1)[0].strip()
        if line.startswith(("-e ", "--editable ")):
            line = line.split(None, 1)[1].strip() if " " in line else ""
        if line:
            yield line


def pyproject_specs(path: Path):
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    project = data.get("project", {})
    for dep in project.get("dependencies", []) or []:
        yield dep
    for deps in (project.get("optional-dependencies", {}) or {}).values():
        for dep in deps or []:
            yield dep


req_files = sorted(p for p in repo_root.glob("**/requirements*.txt") if not skipped(p))
pyproject_files = sorted(p for p in repo_root.glob("**/pyproject.toml") if not skipped(p))

missing: list[tuple[str, str]] = []
incompatible: list[tuple[str, str, str]] = []
invalid: list[tuple[str, str, str]] = []
parse_errors: list[tuple[str, str]] = []
checked = 0


def audit_spec(src: str, spec: str):
    global checked
    try:
        req = Requirement(spec)
    except Exception as exc:  # pragma: no cover - defensive parse surface
        invalid.append((src, spec, str(exc)))
        return
    if req.marker and not req.marker.evaluate(env):
        return
    checked += 1
    try:
        installed = metadata.version(req.name)
    except metadata.PackageNotFoundError:
        missing.append((src, str(req)))
        return
    if req.specifier and installed not in req.specifier:
        incompatible.append((src, str(req), installed))


for file in req_files:
    for spec in requirement_specs(file):
        audit_spec(str(file.relative_to(repo_root)), spec)

for file in pyproject_files:
    try:
        specs = list(pyproject_specs(file))
    except Exception as exc:
        parse_errors.append((str(file.relative_to(repo_root)), str(exc)))
        continue
    for spec in specs:
        audit_spec(str(file.relative_to(repo_root)), spec)

missing_by_file = Counter(path for path, _ in missing)
incompat_by_file = Counter(path for path, _, _ in incompatible)

lines = [
    f"manifests:req={len(req_files)} pyproject={len(pyproject_files)}",
    f"requirements_checked={checked}",
    f"missing={len(missing)} incompatible={len(incompatible)} invalid={len(invalid)} parse_errors={len(parse_errors)}",
    "",
    "missing_by_file:",
]
for path, count in missing_by_file.most_common():
    lines.append(f"  {path}: {count}")
lines.append("")
lines.append("incompatible_by_file:")
for path, count in incompat_by_file.most_common():
    lines.append(f"  {path}: {count}")

if parse_errors:
    lines.append("")
    lines.append("pyproject_parse_errors:")
    for path, reason in parse_errors:
        lines.append(f"  {path}: {reason}")

if invalid:
    lines.append("")
    lines.append("invalid_specs:")
    for src, spec, reason in invalid:
        lines.append(f"  {src} :: {spec} ({reason})")

if missing:
    lines.append("")
    lines.append("sample_missing:")
    for src, spec in missing[:25]:
        lines.append(f"  {src} :: {spec}")

if incompatible:
    lines.append("")
    lines.append("sample_incompatible:")
    for src, spec, installed in incompatible[:25]:
        lines.append(f"  {src} :: {spec} (installed={installed})")

report_file.write_text("\n".join(lines) + "\n", encoding="utf-8")

print(lines[0])
print(lines[1])
print(lines[2])

if missing or incompatible or invalid or parse_errors:
    raise SystemExit(11)
raise SystemExit(0)
PY
        _py_audit_rc=$?
        set -e
        if [[ ${_py_audit_rc} -eq 0 ]]; then
            ok "python manifest dependency audit passed (${PY_AUDIT_BIN})"
        elif [[ ${_py_audit_rc} -eq 11 ]]; then
            warn "python manifest dependency audit found missing/incompatible packages (details: ${PY_AUDIT_REPORT})"
            DEP_AUDIT_FAILED=1
        else
            warn "python manifest dependency audit failed to run (exit ${_py_audit_rc}); see ${PY_AUDIT_REPORT} if present"
            DEP_AUDIT_FAILED=1
        fi
        unset _py_audit_rc
    else
        warn "Skipped python manifest dependency audit (no usable Python interpreter found)."
        DEP_AUDIT_FAILED=1
    fi

    if [[ -n "${PY_AUDIT_BIN}" && -x "${PY_AUDIT_BIN}" ]]; then
        PY_IMPORT_REPORT="${REPORT_DIR}/python-import-audit.txt"
        set +e
        "${PY_AUDIT_BIN}" - "${CHECK_REPO_ROOT}" "${PY_IMPORT_REPORT}" <<'PY'
from __future__ import annotations

import ast
import importlib.util
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
report_file = Path(sys.argv[2])
skip_dirs = {".git", ".venv", "node_modules", "__pycache__", ".pytest_cache", ".tmp", "site-packages"}
stdlib = set(getattr(sys, "stdlib_module_names", set()))


def is_skipped(path: Path) -> bool:
    return any(part in skip_dirs or part.startswith(".venv") for part in path.parts)


local_module_names = set()
for py_file in repo_root.glob("**/*.py"):
    if is_skipped(py_file):
        continue
    local_module_names.add(py_file.stem)
for pkg_init in repo_root.glob("**/__init__.py"):
    if is_skipped(pkg_init):
        continue
    local_module_names.add(pkg_init.parent.name)

imports: set[str] = set()
parse_errors: list[str] = []

for py_file in repo_root.glob("**/*.py"):
    if is_skipped(py_file):
        continue
    try:
        src = py_file.read_text(encoding="utf-8")
        tree = ast.parse(src, filename=str(py_file))
    except Exception as exc:
        parse_errors.append(f"{py_file.relative_to(repo_root)} :: {exc}")
        continue
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imports.add(alias.name.split(".", 1)[0])
        elif isinstance(node, ast.ImportFrom):
            if node.level and node.module is None:
                continue
            if node.module:
                imports.add(node.module.split(".", 1)[0])

ignored = {
    "__future__",
    "typing_extensions",
}

missing: list[str] = []
checked: list[str] = []
for mod in sorted(imports):
    if not mod or mod in ignored:
        continue
    if mod in stdlib:
        continue
    if mod in local_module_names:
        continue
    checked.append(mod)
    if importlib.util.find_spec(mod) is None:
        missing.append(mod)

lines = [
    f"python_files_scanned={sum(1 for p in repo_root.glob('**/*.py') if not is_skipped(p))}",
    f"imports_checked={len(checked)}",
    f"missing_import_modules={len(missing)}",
    f"parse_errors={len(parse_errors)}",
    "",
    "missing_modules:",
]
for mod in missing:
    lines.append(f"  {mod}")
if parse_errors:
    lines.append("")
    lines.append("parse_errors:")
    lines.extend(f"  {e}" for e in parse_errors[:100])

report_file.write_text("\n".join(lines) + "\n", encoding="utf-8")

print(lines[0])
print(lines[1])
print(lines[2])
print(lines[3])

if missing or parse_errors:
    raise SystemExit(12)
raise SystemExit(0)
PY
        _py_import_rc=$?
        set -e
        if [[ ${_py_import_rc} -eq 0 ]]; then
            ok "python import-surface audit passed (${PY_AUDIT_BIN})"
        elif [[ ${_py_import_rc} -eq 12 ]]; then
            warn "python import-surface audit found missing importable modules (details: ${PY_IMPORT_REPORT})"
            DEP_AUDIT_FAILED=1
        else
            warn "python import-surface audit failed to run (exit ${_py_import_rc}); see ${PY_IMPORT_REPORT} if present"
            DEP_AUDIT_FAILED=1
        fi
        unset _py_import_rc
    fi

    WEB_DIR="${CHECK_REPO_ROOT}/AgentCert/chaoscenter/web"
    if [[ -f "${WEB_DIR}/package.json" ]]; then
        WEB_NPM_REPORT="${REPORT_DIR}/web-npm-audit.txt"
        if ! command -v npm >/dev/null 2>&1; then
            warn "npm not found; cannot audit Node dependencies for AgentCert web (${WEB_DIR})."
            DEP_AUDIT_FAILED=1
        else
            set +e
            (
                cd "${WEB_DIR}"
                npm ls --depth=0 --all
            ) >"${WEB_NPM_REPORT}" 2>&1
            _npm_audit_rc=$?
            set -e
            if [[ ${_npm_audit_rc} -eq 0 ]]; then
                ok "Node dependency audit passed for AgentCert web"
            else
                warn "Node dependency audit found issues in AgentCert web (details: ${WEB_NPM_REPORT})"
                DEP_AUDIT_FAILED=1
            fi
            unset _npm_audit_rc
        fi
    fi

    GO_AUDIT_REPORT="${REPORT_DIR}/go-module-audit.txt"
    if command -v go >/dev/null 2>&1; then
        mapfile -t GO_MOD_FILES < <(
            find "${CHECK_REPO_ROOT}" \
                -type d \( -name .git -o -name .venv -o -name node_modules -o -name __pycache__ -o -name .tmp \) -prune \
                -o -name go.mod -print
        )
        GO_AUDIT_FAIL_COUNT=0
        : > "${GO_AUDIT_REPORT}"
        for _gomod in "${GO_MOD_FILES[@]}"; do
            _gomod_dir="$(dirname "${_gomod}")"
            set +e
            (
                cd "${_gomod_dir}"
                GOFLAGS='-mod=readonly' go list -m all
            ) >>"${GO_AUDIT_REPORT}" 2>&1
            _go_rc=$?
            set -e
            if [[ ${_go_rc} -ne 0 ]]; then
                GO_AUDIT_FAIL_COUNT=$((GO_AUDIT_FAIL_COUNT + 1))
                echo "FAILED: ${_gomod_dir}" >>"${GO_AUDIT_REPORT}"
            fi
        done
        if [[ ${GO_AUDIT_FAIL_COUNT} -eq 0 ]]; then
            ok "Go module audit passed (${#GO_MOD_FILES[@]} module manifests)"
        else
            warn "Go module audit found issues in ${GO_AUDIT_FAIL_COUNT} module(s) (details: ${GO_AUDIT_REPORT})"
            DEP_AUDIT_FAILED=1
        fi
        unset GO_AUDIT_FAIL_COUNT GO_MOD_FILES _gomod _gomod_dir _go_rc
    else
        warn "Skipped Go module audit (go not found)."
        DEP_AUDIT_FAILED=1
    fi

    if [[ ${DEP_AUDIT_FAILED} -eq 1 && "${FAIL_ON_DEP_ISSUES}" == "1" ]]; then
        CHECK_FAILED=1
        err "Full dependency audit found issues and ACE_PREREQ_FAIL_ON_DEP_ISSUES=1 is set."
    elif [[ ${DEP_AUDIT_FAILED} -eq 1 ]]; then
        warn "Full dependency audit found issues. Setup can continue, but some repo workflows may fail until dependencies are installed."
        warn "Set ACE_PREREQ_FAIL_ON_DEP_ISSUES=1 to make dependency-audit issues fail fast."
    fi

    unset REPORT_DIR PY_AUDIT_BIN PY_AUDIT_REPORT PY_IMPORT_REPORT WEB_DIR WEB_NPM_REPORT GO_AUDIT_REPORT
fi

echo -e "${CYAN}-------------------------------${NC}"
if [[ $CHECK_FAILED -eq 1 ]]; then
    if [[ ${BASE_REQ_FAILED} -eq 1 ]]; then
        err "docker, docker compose, and git are required for any setup path. Install the missing ones above, then re-run."
    else
        err "Dependency audits failed in strict mode. Review the .tmp/prereq reports and install/fix all missing or incompatible dependencies, then re-run."
    fi
    unset _dv _kv _kubv _hv _nv
    return 1 2>/dev/null || exit 1
fi
ok "All required prerequisites satisfied."
echo
unset _dv _kv _kubv _hv _nv CHECK_SCRIPT_DIR CHECK_REPO_ROOT FULL_DEP_AUDIT FAIL_ON_DEP_ISSUES PREFERRED_AUDIT_PYTHON BASE_REQ_FAILED DEP_AUDIT_FAILED
