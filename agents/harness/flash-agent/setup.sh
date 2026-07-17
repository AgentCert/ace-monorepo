#!/usr/bin/env bash
# Sets up the Python virtual environment for agents/flash-agent/.
# Run once per machine before the first benchmark.  Safe to re-run.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "${HARNESS_DIR}/../../flash-agent" && pwd)"

echo "[flash-agent setup] agent source: ${AGENT_DIR}"

if [[ ! -f "${AGENT_DIR}/requirements.txt" ]]; then
  echo "ERROR: ${AGENT_DIR}/requirements.txt not found." >&2
  exit 1
fi

cd "${AGENT_DIR}"

PYTHON=$(command -v python3.12 || command -v python3)
PY_VER=$("${PYTHON}" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
echo "[flash-agent setup] using Python ${PY_VER} (${PYTHON})"

if [[ ! -d ".venv" ]]; then
  "${PYTHON}" -m venv .venv
fi

source .venv/bin/activate

pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt

echo "[flash-agent setup] done — smoke test:"
python -c "from flash_agent import FlashAgent; print('  FlashAgent imported OK')"

# ── Docker sandbox image ──────────────────────────────────────────────────────
echo "[flash-agent setup] building Docker image ace-harness/flash-agent:local ..."
docker build -t ace-harness/flash-agent:local "${AGENT_DIR}/"
echo "[flash-agent setup] Docker image ready."
