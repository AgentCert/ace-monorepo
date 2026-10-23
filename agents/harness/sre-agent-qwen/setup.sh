#!/usr/bin/env bash
# Sets up the sre-agent-qwen harness. Its Docker image is shared with sre-agent
# (ace-harness/sre-agent:local).
# Default (what scripts/ace-bench.py runs): build that image locally through
#   agents/harness/sre-agent/setup.sh if it is not present yet.
# --install      also install sre-agent's host development dependencies (runs
#                sre-agent/setup.sh --install, which rebuilds the image too).
# --check-model  also check that the Ollama service on localhost:11434 has
#                qwen2.5:7b-instruct.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRE_HARNESS_DIR="$(cd "${HARNESS_DIR}/../sre-agent" && pwd)"

INSTALL=false
CHECK_MODEL=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --check-model) CHECK_MODEL=true ;;
    --local) ;;
    -h|--help) echo 'Default: build the shared SRE harness Docker image locally if missing. --install also installs host development dependencies. --check-model also checks the running Ollama service.'; exit 0 ;;
    *) echo "ERROR: unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ "${INSTALL}" == true ]]; then
  echo "[sre-agent-qwen setup] installing via sre-agent/setup.sh --install ..."
  bash "${SRE_HARNESS_DIR}/setup.sh" --install
else
  echo "[sre-agent-qwen setup] checking Docker image ace-harness/sre-agent:local ..."
  if ! docker image inspect ace-harness/sre-agent:local &>/dev/null; then
    echo "[sre-agent-qwen setup] image not found — building via sre-agent/setup.sh ..."
    bash "${SRE_HARNESS_DIR}/setup.sh"
  else
    echo "[sre-agent-qwen setup] image already present."
  fi
fi

if [[ "${CHECK_MODEL}" == false ]]; then
  exit 0
fi

echo "[sre-agent-qwen setup] checking Ollama model qwen2.5:7b-instruct (used via LiteLLM proxy) ..."
if ! curl -s http://localhost:11434/api/tags | python3 -c "
import json, sys
models = json.load(sys.stdin).get('models', [])
names = [m['name'] for m in models]
found = any('qwen2.5:7b-instruct' in n or 'qwen2.5:7b' in n for n in names)
print('models:', names)
sys.exit(0 if found else 1)
"; then
  echo "ERROR: qwen2.5:7b-instruct not found in Ollama. Pull it first:" >&2
  echo "  ollama pull qwen2.5:7b-instruct" >&2
  exit 1
fi

echo "[sre-agent-qwen setup] done — Ollama + Docker image ready."
