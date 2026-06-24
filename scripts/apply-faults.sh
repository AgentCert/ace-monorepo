#!/bin/bash
# Update image registries in fault.yaml files and optionally apply to cluster.
#
# Usage:
#   ./scripts/apply-faults.sh                       # update all fault files
#   ./scripts/apply-faults.sh pod-delete            # update one fault file
#   ./scripts/apply-faults.sh --apply               # update all + kubectl apply
#   ./scripts/apply-faults.sh pod-delete --apply    # update one + kubectl apply
#   ./scripts/apply-faults.sh pod-delete sock-shop --apply

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read IMAGE_REGISTRY from .env via grep — avoids bash parsing issues with complex
# .env values (e.g. INFRA_DEPLOYMENTS=[...]) that break `source` under set -euo pipefail.
if [[ -f "$REPO_ROOT/.env" ]]; then
  _val="$(grep -m1 '^IMAGE_REGISTRY=' "$REPO_ROOT/.env" | cut -d= -f2-)"
  [[ -n "$_val" ]] && IMAGE_REGISTRY="$_val"
fi

IMAGE_REGISTRY="${IMAGE_REGISTRY:-docker.io}"
FAULT_NAME=""
NAMESPACE="sock-shop"
DO_APPLY=false

# Parse args
for arg in "$@"; do
  case "$arg" in
    --apply) DO_APPLY=true ;;
    --*) ;;
    *)
      if [[ -z "$FAULT_NAME" ]]; then
        FAULT_NAME="$arg"
      else
        NAMESPACE="$arg"
      fi
      ;;
  esac
done

FAULTS_DIR="$REPO_ROOT/chaos-charts/faults/kubernetes"

update_fault() {
  local fault_yaml="$1"
  local name
  name="$(basename "$(dirname "$fault_yaml")")"

  # Sed patterns match any registry prefix before the image name — idempotent,
  # works correctly even if the file was already updated by a previous run.
  sed -i \
    -e "s|image: \"[^\"]*litmuschaos/go-runner:|image: \"${IMAGE_REGISTRY}/litmuschaos/go-runner:|g" \
    -e "s|image: \"[^\"]*agentcert/agentcert-install-agent:|image: \"${IMAGE_REGISTRY}/agentcert/agentcert-install-agent:|g" \
    -e "s|image: \"[^\"]*agentcert/agentcert-install-app:|image: \"${IMAGE_REGISTRY}/agentcert/agentcert-install-app:|g" \
    -e "s|image: \"[^\"]*agentcert/agentcert-uninstall-agent:|image: \"${IMAGE_REGISTRY}/agentcert/agentcert-uninstall-agent:|g" \
    -e "s|image: \"[^\"]*agentcert/agentcert-uninstall-app:|image: \"${IMAGE_REGISTRY}/agentcert/agentcert-uninstall-app:|g" \
    "$fault_yaml"

  echo "✓ Updated $name → $IMAGE_REGISTRY"

  if [[ "$DO_APPLY" == true ]]; then
    kubectl apply -n "$NAMESPACE" -f "$fault_yaml"
    echo "  ↳ Applied to namespace: $NAMESPACE"
  fi
}

if [[ -n "$FAULT_NAME" ]]; then
  update_fault "$FAULTS_DIR/$FAULT_NAME/fault.yaml"
else
  for fault_dir in "$FAULTS_DIR"/*/; do
    [[ -f "$fault_dir/fault.yaml" ]] && update_fault "$fault_dir/fault.yaml"
  done
fi

echo ""
echo "Registry set to: $IMAGE_REGISTRY"
if [[ "$DO_APPLY" == false ]]; then
  echo "Run with --apply to also apply to the cluster."
fi
