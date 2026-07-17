#!/usr/bin/env bash
# Sets up agents/sre-agent/ using uv (installs all deps + nested submodules).
# Run once per machine before the first benchmark.  Safe to re-run.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "${HARNESS_DIR}/../../sre-agent" && pwd)"

echo "[sre-agent setup] agent source: ${AGENT_DIR}"

if [[ ! -f "${AGENT_DIR}/pyproject.toml" ]]; then
  echo "ERROR: ${AGENT_DIR}/pyproject.toml not found." \
       "Run: git submodule update --init agents/sre-agent" >&2
  exit 1
fi

# Ensure nested submodule (mcp-instana) is populated.
if [[ ! -d "${AGENT_DIR}/sre_tools/instana_mcp/mcp-instana/src" ]]; then
  echo "[sre-agent setup] initialising nested submodules …"
  git -C "${AGENT_DIR}" submodule update --init --recursive
fi

if ! command -v uv &>/dev/null; then
  echo "ERROR: uv not found. Install it: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 1
fi

cd "${AGENT_DIR}"
echo "[sre-agent setup] running uv sync …"
uv sync

echo "[sre-agent setup] done — smoke test:"
uv run python -m zero --help 2>&1 | head -5

# ── Docker sandbox image ──────────────────────────────────────────────────────
# Build context is agents/sre-agent/ so the COPY in the Dockerfile picks up
# the agent source (including the populated mcp-instana nested submodule).
echo "[sre-agent setup] building Docker image ace-harness/sre-agent:local ..."
docker build -t ace-harness/sre-agent:local \
  -f "${HARNESS_DIR}/Dockerfile" \
  "${AGENT_DIR}/"
echo "[sre-agent setup] Docker image ready."
