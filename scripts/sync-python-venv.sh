#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"

VENV_PATH="${REPO_ROOT}/.venv"
DRY_RUN=0
LOG_DIR="${REPO_ROOT}/.tmp/prereq"
LOG_FILE="${LOG_DIR}/python-venv-sync.log"

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=1 ;;
        --venv=*) VENV_PATH="${arg#--venv=}" ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            echo "Usage: bash scripts/sync-python-venv.sh [--dry-run] [--venv=/path/to/venv]" >&2
            exit 2
            ;;
    esac
done

if command -v python3.12 >/dev/null 2>&1; then
    HOST_PYTHON="$(command -v python3.12)"
elif command -v python3 >/dev/null 2>&1; then
    HOST_PYTHON="$(command -v python3)"
else
    echo "ERROR: python3.12/python3 not found on PATH." >&2
    exit 1
fi

if [[ ! -x "${VENV_PATH}/bin/python" ]]; then
    echo "Creating venv at ${VENV_PATH} using ${HOST_PYTHON}"
    "${HOST_PYTHON}" -m venv "${VENV_PATH}"
fi

VENV_PYTHON="${VENV_PATH}/bin/python"
VENV_PIP="${VENV_PATH}/bin/pip"

if [[ ! -x "${VENV_PYTHON}" || ! -x "${VENV_PIP}" ]]; then
    echo "ERROR: venv appears broken at ${VENV_PATH}" >&2
    exit 1
fi

render_progress() {
    local current="$1" total="$2"
    local width=28
    local filled=$((current * width / total))
    local empty=$((width - filled))
    local bar=""
    local i
    for ((i = 0; i < filled; i++)); do bar+="#"; done
    for ((i = 0; i < empty; i++)); do bar+="-"; done
    printf '\r\033[2K[%s] %d/%d' "${bar}" "${current}" "${total}"
}

finish_progress_line() {
    printf '\n'
}

run_quiet_step() {
    local current="$1" total="$2" label="$3"
    shift 3
    local -a cmd=("$@")

    render_progress "${current}" "${total}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        return 0
    fi

    {
        printf '\n### %s\n' "${label}"
        printf '$'
        printf ' %q' "${cmd[@]}"
        printf '\n'
    } >> "${LOG_FILE}"

    if ! "${cmd[@]}" >> "${LOG_FILE}" 2>&1; then
        local rc=$?
        finish_progress_line
        echo "ERROR: dependency install step failed: ${label}" >&2
        echo "See pip log: ${LOG_FILE}" >&2
        return "${rc}"
    fi
}

mkdir -p "${LOG_DIR}"
: > "${LOG_FILE}"

echo "Using venv python: ${VENV_PYTHON}"
echo "Writing pip output to: ${LOG_FILE}"

REQ_FILES_TMP="$(mktemp)"
PYPROJECT_DEPS_TMP="$(mktemp)"
trap 'rm -f "${REQ_FILES_TMP}" "${PYPROJECT_DEPS_TMP}"' EXIT

"${VENV_PYTHON}" - "${REPO_ROOT}" "${REQ_FILES_TMP}" "${PYPROJECT_DEPS_TMP}" <<'PY'
from __future__ import annotations

from pathlib import Path
import tomllib

repo_root = Path(__import__("sys").argv[1])
req_out = Path(__import__("sys").argv[2])
dep_out = Path(__import__("sys").argv[3])

skip_dirs = {".git", "node_modules", "__pycache__", ".pytest_cache", ".tmp"}


def skipped(path: Path) -> bool:
    return any(part in skip_dirs or part == ".venv" or part.startswith(".venv-") for part in path.parts)

req_files = sorted(
    p for p in repo_root.glob("**/requirements*.txt")
    if not skipped(p)
)

pyproject_files = sorted(
    p for p in repo_root.glob("**/pyproject.toml")
    if not skipped(p)
)

req_out.write_text("\n".join(str(p) for p in req_files) + "\n", encoding="utf-8")

deps: list[str] = []
for f in pyproject_files:
    try:
        data = tomllib.loads(f.read_text(encoding="utf-8"))
    except Exception:
        continue
    project = data.get("project", {})
    deps.extend(project.get("dependencies", []) or [])
    for opt in (project.get("optional-dependencies", {}) or {}).values():
        deps.extend(opt or [])

dep_out.write_text("\n".join(dict.fromkeys(dep.strip() for dep in deps if dep and dep.strip())) + "\n", encoding="utf-8")
PY

if [[ -s "${PYPROJECT_DEPS_TMP}" ]]; then
    PYPROJECT_STEP_COUNT=1
else
    PYPROJECT_STEP_COUNT=0
fi

mapfile -t REQ_FILES < <(grep -v '^$' "${REQ_FILES_TMP}" || true)
TOTAL_STEPS=$((1 + ${#REQ_FILES[@]} + PYPROJECT_STEP_COUNT))
CURRENT_STEP=1

run_quiet_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "bootstrap pip tooling" \
    "${VENV_PIP}" install --disable-pip-version-check --progress-bar off --upgrade pip setuptools wheel packaging

for req_file in "${REQ_FILES[@]}"; do
    [[ -f "${req_file}" ]] || continue
    CURRENT_STEP=$((CURRENT_STEP + 1))
    run_quiet_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "$(realpath --relative-to="${REPO_ROOT}" "${req_file}")" \
        "${VENV_PIP}" install --disable-pip-version-check --progress-bar off -r "${req_file}"
done

if [[ -s "${PYPROJECT_DEPS_TMP}" ]]; then
    CURRENT_STEP=$((CURRENT_STEP + 1))
    run_quiet_step "${CURRENT_STEP}" "${TOTAL_STEPS}" "pyproject.toml dependencies" \
        "${VENV_PIP}" install --disable-pip-version-check --progress-bar off -r "${PYPROJECT_DEPS_TMP}"
fi

finish_progress_line
echo "Done. Venv dependency sync completed for ${VENV_PATH}. Full pip log: ${LOG_FILE}"
