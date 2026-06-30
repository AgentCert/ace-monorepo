#!/bin/bash
# =============================================================================
# update-all-registries.sh — Replace ALL Docker Hub image references with JFrog
# =============================================================================
# Run this on the VM after git pull. Updates image references everywhere:
#   - app-charts/ (sock-shop, monitoring, MCP tools)
#   - agent-charts/ (flash-agent, k8s-agent, litellm)
#   - chaos-charts/ (faults + experiments)
#   - AgentCert/ (chaoscenter backend code .env defaults)
#
# Reads IMAGE_REGISTRY from .env (default: infyartifactory.jfrog.io/docker-local)
# Idempotent — safe to run multiple times (won't double-prefix).
#
# Usage:
#   ./scripts/update-all-registries.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read IMAGE_REGISTRY from .env
if [[ -f "$REPO_ROOT/.env" ]]; then
  _val="$(grep -m1 '^IMAGE_REGISTRY=' "$REPO_ROOT/.env" | cut -d= -f2-)"
  [[ -n "$_val" ]] && IMAGE_REGISTRY="$_val"
fi
IMAGE_REGISTRY="${IMAGE_REGISTRY:-infyartifactory.jfrog.io/docker-local}"

echo "═══════════════════════════════════════"
echo "  Updating all image registries"
echo "  Registry: $IMAGE_REGISTRY"
echo "═══════════════════════════════════════"
echo

# Helper: replace image refs in a file, avoiding double-prefix
patch_file() {
  local file="$1"
  shift
  for pattern in "$@"; do
    sed -i "$pattern" "$file"
  done
  # Remove double-prefix if accidentally applied
  sed -i "s|${IMAGE_REGISTRY}/${IMAGE_REGISTRY}/|${IMAGE_REGISTRY}/|g" "$file"
}

# ── 1) app-charts/charts/sock-shop/values.yaml ──────────────────────────────
SOCK_SHOP_VALUES="$REPO_ROOT/app-charts/charts/sock-shop/values.yaml"
if [[ -f "$SOCK_SHOP_VALUES" ]]; then
  echo "▸ app-charts/charts/sock-shop/values.yaml"
  patch_file "$SOCK_SHOP_VALUES" \
    "s|image: weaveworksdemos/|image: ${IMAGE_REGISTRY}/weaveworksdemos/|g" \
    "s|image: mongo$|image: ${IMAGE_REGISTRY}/mongo|g" \
    "s|image: mongo\b|image: ${IMAGE_REGISTRY}/mongo|g" \
    "s|image: rabbitmq:|image: ${IMAGE_REGISTRY}/rabbitmq:|g" \
    "s|image: prom/prometheus:|image: ${IMAGE_REGISTRY}/prom/prometheus:|g" \
    "s|image: grafana/grafana:|image: ${IMAGE_REGISTRY}/grafana/grafana:|g" \
    "s|image: registry.k8s.io/|image: ${IMAGE_REGISTRY}/|g" \
    "s|image: quay.io/containers/|image: ${IMAGE_REGISTRY}/|g" \
    "s|image: agentcert/|image: ${IMAGE_REGISTRY}/agentcert/|g" \
    "s|image: docker.io/|image: ${IMAGE_REGISTRY}/|g"
  echo "  ✓ Updated"
fi

# ── 2) agent-charts — flash-agent, k8s-agent values.yaml ────────────────────
for values_file in "$REPO_ROOT"/agent-charts/charts/*/values.yaml; do
  if [[ -f "$values_file" ]]; then
    if grep -q "registry: docker.io" "$values_file" 2>/dev/null; then
      echo "▸ ${values_file#$REPO_ROOT/}"
      sed -i "s|registry: docker.io|registry: ${IMAGE_REGISTRY}|g" "$values_file"
      echo "  ✓ Updated registry"
    fi
    # Also handle quoted form
    if grep -q 'registry: "docker.io"' "$values_file" 2>/dev/null; then
      sed -i "s|registry: \"docker.io\"|registry: \"${IMAGE_REGISTRY}\"|g" "$values_file"
    fi
  fi
done

# ── 3) agent-charts/litellm/deployment.yaml ──────────────────────────────────
LITELLM_DEPLOY="$REPO_ROOT/agent-charts/litellm/deployment.yaml"
if [[ -f "$LITELLM_DEPLOY" ]]; then
  echo "▸ agent-charts/litellm/deployment.yaml"
  patch_file "$LITELLM_DEPLOY" \
    "s|image: docker.io/|image: ${IMAGE_REGISTRY}/|g" \
    "s|image: litellm/|image: ${IMAGE_REGISTRY}/litellm/|g"
  echo "  ✓ Updated"
fi

# ── 4) chaos-charts (faults + experiments) ───────────────────────────────────
echo "▸ chaos-charts/"
FAULTS_DIR="$REPO_ROOT/chaos-charts/faults/kubernetes"
EXPERIMENTS_DIR="$REPO_ROOT/chaos-charts/experiments"
_update_chaos_yaml() {
  local f="$1"
  sed -i \
    -e "s|image: \"[^\"]*litmuschaos/go-runner:|image: \"${IMAGE_REGISTRY}/litmuschaos/go-runner:|g" \
    -e "s|value: \"[^\"]*litmuschaos/go-runner:|value: \"${IMAGE_REGISTRY}/litmuschaos/go-runner:|g" \
    -e "s|image: \"[^\"]*litmuschaos/chaos-runner:|image: \"${IMAGE_REGISTRY}/litmuschaos/chaos-runner:|g" \
    -e "s|value: \"[^\"]*litmuschaos/chaos-runner:|value: \"${IMAGE_REGISTRY}/litmuschaos/chaos-runner:|g" \
    -e "s|image: \"[^\"]*litmuschaos/chaos-operator:|image: \"${IMAGE_REGISTRY}/litmuschaos/chaos-operator:|g" \
    -e "s|value: \"[^\"]*litmuschaos/chaos-operator:|value: \"${IMAGE_REGISTRY}/litmuschaos/chaos-operator:|g" \
    -e "s|image: \"[^\"]*litmuschaos/chaos-exporter:|image: \"${IMAGE_REGISTRY}/litmuschaos/chaos-exporter:|g" \
    -e "s|value: \"[^\"]*litmuschaos/chaos-exporter:|value: \"${IMAGE_REGISTRY}/litmuschaos/chaos-exporter:|g" \
    -e "s|image: \"[^\"]*agentcert/|image: \"${IMAGE_REGISTRY}/agentcert/|g" \
    -e "s|value: \"[^\"]*agentcert/|value: \"${IMAGE_REGISTRY}/agentcert/|g" \
    "$f"
  sed -i "s|${IMAGE_REGISTRY}/${IMAGE_REGISTRY}/|${IMAGE_REGISTRY}/|g" "$f"
}
if [[ -d "$FAULTS_DIR" ]]; then
  find "$FAULTS_DIR" -name "fault.yaml" | while read -r f; do _update_chaos_yaml "$f"; done
  echo "  ✓ Updated fault files"
fi
if [[ -d "$EXPERIMENTS_DIR" ]]; then
  find "$EXPERIMENTS_DIR" -name "*.yaml" | while read -r f; do _update_chaos_yaml "$f"; done
  echo "  ✓ Updated experiment files"
fi

# ── 5) AgentCert submodule — chaoscenter default env/config ──────────────────
# Update any hardcoded docker.io references in graphql/auth env defaults
for f in $(find "$REPO_ROOT/AgentCert/chaoscenter" -name "*.go" -exec grep -l "docker.io" {} \; 2>/dev/null | head -20); do
  echo "▸ ${f#$REPO_ROOT/}"
  sed -i "s|docker.io/litmuschaos/|${IMAGE_REGISTRY}/litmuschaos/|g" "$f"
  sed -i "s|docker.io/agentcert/|${IMAGE_REGISTRY}/agentcert/|g" "$f"
  sed -i "s|${IMAGE_REGISTRY}/${IMAGE_REGISTRY}/|${IMAGE_REGISTRY}/|g" "$f"
  echo "  ✓ Updated"
done

# ── 6) .env — ensure IMAGE_REGISTRY is set ──────────────────────────────────
if [[ -f "$REPO_ROOT/.env" ]]; then
  if grep -q "^IMAGE_REGISTRY=" "$REPO_ROOT/.env"; then
    sed -i "s|^IMAGE_REGISTRY=.*|IMAGE_REGISTRY=${IMAGE_REGISTRY}|" "$REPO_ROOT/.env"
  else
    echo "IMAGE_REGISTRY=${IMAGE_REGISTRY}" >> "$REPO_ROOT/.env"
  fi
  echo "  ✓ .env: IMAGE_REGISTRY=${IMAGE_REGISTRY}"
fi

echo
echo "═══════════════════════════════════════"
echo "  ✓ All registries → $IMAGE_REGISTRY"
echo "═══════════════════════════════════════"
echo
echo "If pods fail with ImagePullBackOff, push the missing image:"
echo "  docker pull <image> && docker tag <image> ${IMAGE_REGISTRY}/<image> && docker push ${IMAGE_REGISTRY}/<image>"
