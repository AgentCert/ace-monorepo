#!/bin/bash
# Update image registries in chaos-chart YAML files and optionally apply to cluster.
#
# Reads IMAGE_REGISTRY from .env (default: docker.io). Replaces all known image
# references in fault.yaml and experiment YAML files with the configured registry.
# Idempotent — safe to run multiple times.
#
# Usage:
#   ./scripts/apply-faults.sh                       # update all fault + experiment files
#   ./scripts/apply-faults.sh pod-delete            # update one fault
#   ./scripts/apply-faults.sh --apply               # update all + kubectl apply
#   ./scripts/apply-faults.sh pod-delete --apply    # update one + kubectl apply
#   ./scripts/apply-faults.sh pod-delete sock-shop --apply
#   ./scripts/apply-faults.sh --ns litmus --apply      # all faults → litmus namespace

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read IMAGE_REGISTRY from .env — avoids bash parsing issues with complex
# .env values (e.g. INFRA_DEPLOYMENTS=[...]) that break `source`.
if [[ -f "$REPO_ROOT/.env" ]]; then
  _val="$(grep -m1 '^IMAGE_REGISTRY=' "$REPO_ROOT/.env" | cut -d= -f2-)"
  [[ -n "$_val" ]] && IMAGE_REGISTRY="$_val"
fi

IMAGE_REGISTRY="${IMAGE_REGISTRY:-docker.io}"
FAULT_NAME=""
NAMESPACE="sock-shop"
DO_APPLY=false

# Parse args
SKIP_NEXT=false
ARGS=("$@")
for i in "${!ARGS[@]}"; do
  [[ "$SKIP_NEXT" == true ]] && SKIP_NEXT=false && continue
  arg="${ARGS[$i]}"
  case "$arg" in
    --apply) DO_APPLY=true ;;
    --ns|--namespace)
      NAMESPACE="${ARGS[$((i+1))]:-$NAMESPACE}"
      SKIP_NEXT=true
      ;;
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
EXPERIMENTS_DIR="$REPO_ROOT/chaos-charts/experiments"

# Replace image references in a YAML file with the configured registry.
# Handles both `image: "..."` fields and `value: "..."` env var entries.
update_yaml() {
  local yaml_file="$1"
  local label="$2"

  sed -i \
    -e "s|image: \"[^\"]*litmuschaos/go-runner:|image: \"${IMAGE_REGISTRY}/litmuschaos/go-runner:|g" \
    -e "s|value: \"[^\"]*litmuschaos/go-runner:|value: \"${IMAGE_REGISTRY}/litmuschaos/go-runner:|g" \
    -e "s|image: \"[^\"]*litmuschaos/chaos-runner:|image: \"${IMAGE_REGISTRY}/litmuschaos/chaos-runner:|g" \
    -e "s|value: \"[^\"]*litmuschaos/chaos-runner:|value: \"${IMAGE_REGISTRY}/litmuschaos/chaos-runner:|g" \
    -e "s|image: \"[^\"]*litmuschaos/chaos-operator:|image: \"${IMAGE_REGISTRY}/litmuschaos/chaos-operator:|g" \
    -e "s|value: \"[^\"]*litmuschaos/chaos-operator:|value: \"${IMAGE_REGISTRY}/litmuschaos/chaos-operator:|g" \
    -e "s|image: \"[^\"]*litmuschaos/chaos-exporter:|image: \"${IMAGE_REGISTRY}/litmuschaos/chaos-exporter:|g" \
    -e "s|value: \"[^\"]*litmuschaos/chaos-exporter:|value: \"${IMAGE_REGISTRY}/litmuschaos/chaos-exporter:|g" \
    -e "s|image: \"[^\"]*agentcert/agentcert-install-agent:|image: \"${IMAGE_REGISTRY}/agentcert/agentcert-install-agent:|g" \
    -e "s|value: \"[^\"]*agentcert/agentcert-install-agent:|value: \"${IMAGE_REGISTRY}/agentcert/agentcert-install-agent:|g" \
    -e "s|image: \"[^\"]*agentcert/agentcert-install-app:|image: \"${IMAGE_REGISTRY}/agentcert/agentcert-install-app:|g" \
    -e "s|value: \"[^\"]*agentcert/agentcert-install-app:|value: \"${IMAGE_REGISTRY}/agentcert/agentcert-install-app:|g" \
    -e "s|image: \"[^\"]*agentcert/agentcert-uninstall-agent:|image: \"${IMAGE_REGISTRY}/agentcert/agentcert-uninstall-agent:|g" \
    -e "s|value: \"[^\"]*agentcert/agentcert-uninstall-agent:|value: \"${IMAGE_REGISTRY}/agentcert/agentcert-uninstall-agent:|g" \
    -e "s|image: \"[^\"]*agentcert/agentcert-uninstall-app:|image: \"${IMAGE_REGISTRY}/agentcert/agentcert-uninstall-app:|g" \
    -e "s|value: \"[^\"]*agentcert/agentcert-uninstall-app:|value: \"${IMAGE_REGISTRY}/agentcert/agentcert-uninstall-app:|g" \
    "$yaml_file"

  echo "✓ Updated $label → $IMAGE_REGISTRY"

  if [[ "$DO_APPLY" == true ]]; then
    kubectl apply -n "$NAMESPACE" -f "$yaml_file"
    echo "  ↳ Applied to namespace: $NAMESPACE"
  fi
}

# --- Process fault files ---
if [[ -n "$FAULT_NAME" ]]; then
  if [[ -f "$FAULTS_DIR/$FAULT_NAME/fault.yaml" ]]; then
    update_yaml "$FAULTS_DIR/$FAULT_NAME/fault.yaml" "fault/$FAULT_NAME"
  else
    echo "ERROR: $FAULTS_DIR/$FAULT_NAME/fault.yaml not found" >&2
    exit 1
  fi
else
  echo "Updating fault files..."
  for fault_dir in "$FAULTS_DIR"/*/; do
    [[ -f "$fault_dir/fault.yaml" ]] && update_yaml "$fault_dir/fault.yaml" "fault/$(basename "$fault_dir")"
  done

  echo ""
  echo "Updating experiment files..."
  if [[ -d "$EXPERIMENTS_DIR" ]]; then
    find "$EXPERIMENTS_DIR" -type f -name '*.yaml' | while read -r exp_yaml; do
      local_name="${exp_yaml#$EXPERIMENTS_DIR/}"
      update_yaml "$exp_yaml" "experiment/$local_name"
    done
  fi
fi

echo ""
echo "═══════════════════════════════════════"
echo "  Registry: $IMAGE_REGISTRY"
echo "  Namespace: $NAMESPACE"
if [[ "$DO_APPLY" == true ]]; then
  echo "  Status: Applied to cluster ✓"
else
  echo "  Status: Files updated (run with --apply to also apply to cluster)"
fi
echo "═══════════════════════════════════════"
