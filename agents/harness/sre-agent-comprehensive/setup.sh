#!/usr/bin/env bash
# Build the Docker image for sre-agent-comprehensive.
# Run once before the first benchmark run, and after any agent code change.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "${HARNESS_DIR}/../../sre-agent-comprehensive" && pwd)"

echo "[sre-agent-comprehensive setup] building Docker image ace-harness/sre-agent-comprehensive:local ..."
docker build -t ace-harness/sre-agent-comprehensive:local "${AGENT_DIR}"
echo "[sre-agent-comprehensive setup] done."
