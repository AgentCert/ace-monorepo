#!/usr/bin/env bash
# Sets up the Python virtual environment for agents/flash-agent/.
# Run once per machine before the first benchmark.  Safe to re-run.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "${HARNESS_DIR}/../../flash-agent" && pwd)"

INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --local) ;;
    -h|--help) echo 'Default: build the harness Docker image locally. --install also installs host development dependencies.'; exit 0 ;;
    *) echo "ERROR: unknown option: $arg" >&2; exit 2 ;;
  esac
done
REPO_ROOT="$(cd "${HARNESS_DIR}/../../.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../scripts/lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"
registry_load "${REPO_ROOT}/.env"

echo "[flash-agent setup] agent source: ${AGENT_DIR}"

if [[ ! -f "${AGENT_DIR}/requirements.txt" ]]; then
  echo "ERROR: ${AGENT_DIR}/requirements.txt not found." >&2
  exit 1
fi

if [[ "${INSTALL}" == true ]]; then
  cd "${AGENT_DIR}"

  PYTHON=$(command -v python3.12 || command -v python3)
  PY_VER=$("${PYTHON}" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
  echo "[flash-agent setup] using Python ${PY_VER} (${PYTHON})"

  if [[ ! -d ".venv" ]]; then
    "${PYTHON}" -m venv .venv
  fi

  # shellcheck source=/dev/null  # created by the venv step above
  source .venv/bin/activate

  pip install --quiet --upgrade pip
  pip install --quiet -r requirements.txt

  echo "[flash-agent setup] done — smoke test:"
  python -c "from flash_agent import FlashAgent; print('  FlashAgent imported OK')"

fi

# ── Docker sandbox image ──────────────────────────────────────────────────────
# With IMAGE_REGISTRY set, docker_build_resolved points the Dockerfile's
# ARG *_IMAGE base images at that registry, so log in first (no-op without
# credentials; a failure only warns, as an earlier docker login may still work).
if [[ -n "${IMAGE_REGISTRY}" ]]; then
  registry_login >/dev/null || echo "[flash-agent setup] WARN: login to $(registry_host) failed — base-image pulls may get 401" >&2
fi
echo "[flash-agent setup] building Docker image ace-harness/flash-agent:local ..."
docker_build_resolved "${AGENT_DIR}/Dockerfile" -t ace-harness/flash-agent:local "${AGENT_DIR}/"
echo "[flash-agent setup] Docker image ready."
