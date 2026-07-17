#!/usr/bin/env bash
# Sets up sre-agent-qwen harness.
# The Docker image is shared with sre-agent (ace-harness/sre-agent:local).
# Run agents/harness/sre-agent/setup.sh first to build the image.
# This script only verifies that the image exists and that Ollama has the model.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRE_HARNESS_DIR="$(cd "${HARNESS_DIR}/../sre-agent" && pwd)"

echo "[sre-agent-qwen setup] checking Docker image ace-harness/sre-agent:local ..."
if ! docker image inspect ace-harness/sre-agent:local &>/dev/null; then
  echo "[sre-agent-qwen setup] image not found — building via sre-agent/setup.sh ..."
  bash "${SRE_HARNESS_DIR}/setup.sh"
else
  echo "[sre-agent-qwen setup] image already present."
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
