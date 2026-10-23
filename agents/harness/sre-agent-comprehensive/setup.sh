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
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../scripts/lib/registry.sh
source "${REPO_ROOT}/scripts/lib/registry.sh"
registry_load "${REPO_ROOT}/.env"

# With IMAGE_REGISTRY set, docker_build_resolved points the Dockerfile's
# ARG *_IMAGE base images at that registry, so log in first (no-op without
# credentials; a failure only warns, as an earlier docker login may still work).
if [[ -n "${IMAGE_REGISTRY}" ]]; then
  registry_login >/dev/null || echo "[sre-agent-comprehensive setup] WARN: login to $(registry_host) failed — base-image pulls may get 401" >&2
fi
echo "[sre-agent-comprehensive setup] building Docker image ace-harness/sre-agent-comprehensive:local ..."
docker_build_resolved "${AGENT_DIR}/Dockerfile" -t ace-harness/sre-agent-comprehensive:local "${AGENT_DIR}"
echo "[sre-agent-comprehensive setup] done."
