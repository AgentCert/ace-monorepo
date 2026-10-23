#!/usr/bin/env bash
# Install dependencies for the A2A/MCP adapter harness.
# Requires Python 3.10+ and pip in PATH.
#
# Usage: setup.sh [--install | --local | --help]
#   (no option), --install, --local
#       Create ./.venv with the adapter's dependencies. This adapter uses no
#       Docker image, so there is nothing else to build; the venv is local to
#       this checkout and touches no registry or cluster. scripts/ace-bench.py
#       runs this script with no arguments, and agent-harness.yaml activates
#       the venv it creates.
#   --help
#       Show this help.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  ""|--install|--local) [[ $# -le 1 ]] || { echo 'Usage: setup.sh [--install | --local | --help]' >&2; exit 2; } ;;
  --help|-h) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo 'Usage: setup.sh [--install | --local | --help]' >&2; exit 2 ;;
esac

python3 -m venv "${SCRIPT_DIR}/.venv"
"${SCRIPT_DIR}/.venv/bin/pip" install --quiet --upgrade pip
"${SCRIPT_DIR}/.venv/bin/pip" install --quiet "httpx>=0.27" "tenacity>=8.2"

echo "[setup] a2a-mcp-agent harness ready (venv: ${SCRIPT_DIR}/.venv)"
