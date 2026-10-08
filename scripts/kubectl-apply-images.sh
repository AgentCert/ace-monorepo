#!/usr/bin/env bash
# kubectl-apply-images.sh — `kubectl apply -f` for plain manifests, with every
# image resolved for IMAGE_REGISTRY / the frozen agentcert/ Docker Hub copies
# and the registry pull secret added to each pod (same rule as the Helm chart;
# scripts/lib/resolve_image_env.py). Use it for hand-applied manifests such as
# agent-charts/litellm/*.yaml or deploy/k8s/*.yaml.
#
# Usage: ./scripts/kubectl-apply-images.sh [--env-file PATH] -f FILE [-f FILE ...] [kubectl apply args]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
files=(); pass=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file) ENV_FILE="$2"; shift 2 ;;
        -f|--filename) files+=("$2"); shift 2 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) pass+=("$1"); shift ;;
    esac
done
[[ ${#files[@]} -gt 0 ]] || { echo "usage: $0 -f FILE [...]" >&2; exit 2; }
for f in "${files[@]}"; do
    python3 "${REPO_ROOT}/scripts/lib/resolve_image_env.py" --rewrite-manifests "${ENV_FILE}" < "${f}" \
        | kubectl apply "${pass[@]}" -f -
done
