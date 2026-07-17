#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "${HARNESS_DIR}/../../sre-agent-crewai" && pwd)"

echo "[sre-agent-crewai setup] building Docker image ace-harness/sre-agent-crewai:local ..."
docker build -t ace-harness/sre-agent-crewai:local "${AGENT_DIR}"
echo "[sre-agent-crewai setup] done."
