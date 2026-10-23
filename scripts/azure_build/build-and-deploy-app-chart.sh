#!/usr/bin/env bash
# Legacy entry point; local-only by default. --push/--deploy are explicit.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/../../app-charts/install-app/build-and-deploy-app-chart.sh" "$@"
