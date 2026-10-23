#!/usr/bin/env bash
# Build the Docker image for sre-agent-comprehensive.
# Run once before the first benchmark run, and after any agent code change.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(cd "${HARNESS_DIR}/../../sre-agent-comprehensive" && pwd)"

for arg in "$@"; do
  case "$arg" in
    --install) ;;
    --local) ;;
    -h|--help) echo 'Build the harness Docker image locally. Dependencies are installed inside the image.'; exit 0 ;;
    *) echo "ERROR: unknown option: $arg" >&2; exit 2 ;;
  esac
done
REPO_ROOT="$(cd "${HARNESS_DIR}/../../.." && pwd)"
# shellcheck source=../../../scripts/lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"
registry_load "${REPO_ROOT}/.env"

echo "[sre-agent-comprehensive setup] building Docker image ace-harness/sre-agent-comprehensive:local ..."
docker_build_resolved "${AGENT_DIR}/Dockerfile" -t ace-harness/sre-agent-comprehensive:local "${AGENT_DIR}"
echo "[sre-agent-comprehensive setup] done."
