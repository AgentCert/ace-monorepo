#!/usr/bin/env bash
# Install dependencies for the A2A/MCP adapter harness.
# Requires Python 3.10+ and pip in PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:---help}" in
  --install) [[ $# -eq 1 ]] || { echo 'Usage: setup.sh --install' >&2; exit 2; } ;;
  --help|-h|--local) echo 'No Docker image is used by this adapter. Use --install to create its local Python environment.'; exit 0 ;;
  *) echo 'Usage: setup.sh [--install]' >&2; exit 2 ;;
esac

python3 -m venv "${SCRIPT_DIR}/.venv"
"${SCRIPT_DIR}/.venv/bin/pip" install --quiet --upgrade pip
"${SCRIPT_DIR}/.venv/bin/pip" install --quiet "httpx>=0.27" "tenacity>=8.2"

echo "[setup] a2a-mcp-agent harness ready (venv: ${SCRIPT_DIR}/.venv)"
