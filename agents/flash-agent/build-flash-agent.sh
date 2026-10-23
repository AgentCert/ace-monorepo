#!/usr/bin/env bash
# Build this component locally. --push publishes; --kind-load explicitly loads KinD.
# Other options are shared with scripts/build-and-push.sh, including --help.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILDER="${REPO_ROOT}/scripts/build-and-push.sh"
[[ -f "${BUILDER}" ]] || { echo "ERROR: run this wrapper from an ace-monorepo checkout." >&2; exit 1; }
exec bash "${BUILDER}" "$@" --only '^agentcert/agentcert-flash-agent:'
