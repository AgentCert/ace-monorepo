#!/usr/bin/env bash
# Sets up the Python virtual environment for agents/ciso-agent/.
# Run once per machine before the first benchmark.  Safe to re-run.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "${HARNESS_DIR}/../../ciso-agent" && pwd)"

echo "[ciso-agent setup] agent source: ${AGENT_DIR}"

if [[ ! -f "${AGENT_DIR}/pyproject.toml" ]]; then
  echo "ERROR: ${AGENT_DIR}/pyproject.toml not found." \
       "Run: git submodule update --init agents/ciso-agent" >&2
  exit 1
fi

cd "${AGENT_DIR}"

# Require Python 3.10–3.12 (crewai 0.95.0 does not support 3.13+).
PYTHON=$(command -v python3.12 || command -v python3.11 || command -v python3.10 || command -v python3)
PY_VER=$("${PYTHON}" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
echo "[ciso-agent setup] using Python ${PY_VER} (${PYTHON})"

if [[ ! -d ".venv" ]]; then
  "${PYTHON}" -m venv .venv
fi

source .venv/bin/activate

pip install --quiet --upgrade pip
pip install --quiet -r requirements-dev.txt
pip install --quiet -e .

echo "[ciso-agent setup] done — smoke test:"
python -c "from ciso_agent.main import run; print('  ciso_agent.main imported OK')"

# ── Docker sandbox image ──────────────────────────────────────────────────────
echo "[ciso-agent setup] building Docker image ace-harness/ciso-agent:local ..."
docker build -t ace-harness/ciso-agent:local "${AGENT_DIR}/"
echo "[ciso-agent setup] Docker image ready."
