#!/usr/bin/env bash
# Install dependencies for the A2A/MCP adapter harness.
# Requires Python 3.10+ and pip in PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 -m venv "${SCRIPT_DIR}/.venv"
"${SCRIPT_DIR}/.venv/bin/pip" install --quiet --upgrade pip
"${SCRIPT_DIR}/.venv/bin/pip" install --quiet "httpx>=0.27" "tenacity>=8.2"

echo "[setup] a2a-mcp-agent harness ready (venv: ${SCRIPT_DIR}/.venv)"
