#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# apply-faults.sh — Pre-deploy fixes for AKS behind corporate proxy (Zscaler)
# =============================================================================
# Run ONCE before helm install/upgrade on a fresh cluster. Creates:
#   1. $SECRET_NAME imagePullSecret (for pulling from JFrog Artifactory)
#   2. ca-certs ConfigMap (corporate CA bundle for TLS interception)
#   3. Ensures IMAGE_REGISTRY is set in .env
#
# Usage:
#   ./scripts/apply-faults.sh
#
# Requires:
#   - kubectl configured for the target AKS cluster
#   - JFROG_USER / JFROG_TOKEN env vars (or prompted)
#   - Corporate CA certs in /usr/local/share/ca-certificates/*.crt (or $CORPORATE_CA_CERT_DIR)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
NS="${ACE_NAMESPACE:-ace}"
REGISTRY="${IMAGE_REGISTRY:-infyartifactory.jfrog.io/docker-local}"
# Extract docker server from IMAGE_REGISTRY (host part before first /)
DOCKER_SERVER="${DOCKER_SERVER:-$(echo "$REGISTRY" | cut -d/ -f1)}"
# Secret name for image pulls — read from .env or default
SECRET_NAME="${IMAGE_PULL_SECRET_NAME:-jfrog-registry}"
CA_DIR="${CORPORATE_CA_CERT_DIR:-/usr/local/share/ca-certificates}"

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }

echo -e "${BOLD}ACE Pre-deploy Fixes (AKS + Corporate Proxy)${NC}"
echo

# ── 1) Namespace ──────────────────────────────────────────────────────────────
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "Namespace '${NS}' exists."

# ── 2) JFrog Registry Secret ─────────────────────────────────────────────────
echo
echo -e "${BOLD}1) JFrog Registry Secret${NC}"
# Read from environment, then .env file, then prompt as last resort
JFROG_USER="${JFROG_USER:-}"
JFROG_TOKEN="${JFROG_TOKEN:-}"
if [[ -z "$JFROG_USER" || -z "$JFROG_TOKEN" ]] && [[ -f "$ENV_FILE" ]]; then
    [[ -z "$JFROG_USER" ]] && JFROG_USER="$(grep -m1 '^JFROG_USER=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)" || true
    [[ -z "$JFROG_TOKEN" ]] && JFROG_TOKEN="$(grep -m1 '^JFROG_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)" || true
fi

if [[ -z "$JFROG_USER" ]]; then
    read -rp "  JFrog username: " JFROG_USER
fi
if [[ -z "$JFROG_TOKEN" ]]; then
    read -rsp "  JFrog token/password: " JFROG_TOKEN
    echo
fi

if [[ -n "$JFROG_USER" && -n "$JFROG_TOKEN" ]]; then
    kubectl create secret docker-registry "$SECRET_NAME" \
        --namespace "${NS}" \
        --docker-server="${DOCKER_SERVER}" \
        --docker-username="${JFROG_USER}" \
        --docker-password="${JFROG_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    ok "$SECRET_NAME secret created/updated in '${NS}'."

    # Create master copy in kube-system (used by jfrog-secret-sync to replicate to all namespaces)
    kubectl create secret docker-registry "$SECRET_NAME" \
        --namespace kube-system \
        --docker-server="${DOCKER_SERVER}" \
        --docker-username="${JFROG_USER}" \
        --docker-password="${JFROG_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    ok "$SECRET_NAME master secret created in kube-system."
else
    warn "JFrog credentials not provided — skipping secret creation."
fi

# ── 3) CA Certificates ConfigMap ─────────────────────────────────────────────
echo
echo -e "${BOLD}2) Corporate CA Certificates${NC}"
if [[ -d "$CA_DIR" ]] && ls "$CA_DIR"/*.crt >/dev/null 2>&1; then
    # Ensure certs are readable without sudo
    chmod a+r "$CA_DIR"/*.crt 2>/dev/null || true
    # Build a single CA bundle (system + corporate certs)
    bundle="/tmp/ace-ca-bundle.pem"
    cp /etc/ssl/certs/ca-certificates.crt "$bundle" 2>/dev/null || : > "$bundle"
    cat "$CA_DIR"/*.crt >> "$bundle" 2>/dev/null || true
    # Create ConfigMap with single key 'ca-certificates.crt' (what SSL_CERT_FILE expects)
    kubectl create configmap ca-certs \
        --namespace "${NS}" \
        --from-file=ca-certificates.crt="$bundle" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    rm -f "$bundle"
    ok "ca-certs ConfigMap created (system + corporate bundle)"
else
    warn "No .crt files found in ${CA_DIR} — skipping CA ConfigMap."
    echo -e "  ${DIM}Set CORPORATE_CA_CERT_DIR to your cert directory and re-run.${NC}"
fi

# ── 4) IMAGE_REGISTRY in .env ────────────────────────────────────────────────
echo
echo -e "${BOLD}3) IMAGE_REGISTRY in .env${NC}"
# Ensure .env exists — copy from .env.example if missing
if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "${REPO_ROOT}/.env.example" ]]; then
        cp "${REPO_ROOT}/.env.example" "$ENV_FILE"
        ok "Created .env from .env.example"
    else
        warn ".env.example not found — creating empty .env"
        touch "$ENV_FILE"
    fi
    # Inject chaos infra image defaults (used by graphql server to deploy litmus components)
    grep -q "^SUBSCRIBER_IMAGE=" "$ENV_FILE" || echo "SUBSCRIBER_IMAGE=${REGISTRY}/agentcert/litmusportal-subscriber:3.0.0" >> "$ENV_FILE"
    grep -q "^EVENT_TRACKER_IMAGE=" "$ENV_FILE" || echo "EVENT_TRACKER_IMAGE=${REGISTRY}/litmuschaos/litmusportal-event-tracker:3.0.0" >> "$ENV_FILE"
    grep -q "^ARGO_WORKFLOW_CONTROLLER_IMAGE=" "$ENV_FILE" || echo "ARGO_WORKFLOW_CONTROLLER_IMAGE=${REGISTRY}/litmuschaos/workflow-controller:v3.3.1" >> "$ENV_FILE"
    grep -q "^ARGO_WORKFLOW_EXECUTOR_IMAGE=" "$ENV_FILE" || echo "ARGO_WORKFLOW_EXECUTOR_IMAGE=${REGISTRY}/litmuschaos/argoexec:v3.3.1" >> "$ENV_FILE"
    grep -q "^CHAOS_OPERATOR_IMAGE=" "$ENV_FILE" || echo "CHAOS_OPERATOR_IMAGE=${REGISTRY}/litmuschaos/chaos-operator:3.0.0" >> "$ENV_FILE"
    grep -q "^CHAOS_RUNNER_IMAGE=" "$ENV_FILE" || echo "CHAOS_RUNNER_IMAGE=${REGISTRY}/litmuschaos/chaos-runner:3.0.0" >> "$ENV_FILE"
    grep -q "^CHAOS_EXPORTER_IMAGE=" "$ENV_FILE" || echo "CHAOS_EXPORTER_IMAGE=${REGISTRY}/litmuschaos/chaos-exporter:3.0.0" >> "$ENV_FILE"
    grep -q "^KUBERNETES_MCP_SERVER_IMAGE=" "$ENV_FILE" || echo "KUBERNETES_MCP_SERVER_IMAGE=${REGISTRY}/kubernetes_mcp_server:latest" >> "$ENV_FILE"
    grep -q "^PROMETHEUS_MCP_SERVER_IMAGE=" "$ENV_FILE" || echo "PROMETHEUS_MCP_SERVER_IMAGE=${REGISTRY}/agentcert/prometheus-mcp-server:latest" >> "$ENV_FILE"
fi
if grep -q "^IMAGE_REGISTRY=" "$ENV_FILE"; then
    sed -i "s|^IMAGE_REGISTRY=.*|IMAGE_REGISTRY=${REGISTRY}|" "$ENV_FILE"
else
    echo "IMAGE_REGISTRY=${REGISTRY}" >> "$ENV_FILE"
fi
ok "IMAGE_REGISTRY=${REGISTRY} in .env"

# ── 5) Patch default ServiceAccount for imagePullSecrets ─────────────────────
echo
echo -e "${BOLD}4) Patch default ServiceAccount${NC}"
kubectl patch serviceaccount default -n "${NS}" \
    -p '{"imagePullSecrets": [{"name": "'$SECRET_NAME'"}]}' 2>/dev/null \
    && ok "default SA patched with $SECRET_NAME imagePullSecret." \
    || warn "Could not patch default SA (may not exist yet — will work after first deploy)."

echo
echo -e "${GREEN}=== Pre-deploy fixes applied ===${NC}"
echo -e "${DIM}Now run: helm upgrade --install ace deploy/helm/ace -n ace -f deploy/helm/ace/values-env.yaml --timeout 10m${NC}"

# ── 6) Setup litmus namespace for JFrog image pulls ──────────────────────────
echo
echo -e "${BOLD}5) Litmus namespace setup${NC}"
kubectl create namespace litmus --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if [[ -n "$JFROG_USER" && -n "$JFROG_TOKEN" ]]; then
    kubectl create secret docker-registry "$SECRET_NAME" \
        --namespace litmus \
        --docker-server="${DOCKER_SERVER}" \
        --docker-username="${JFROG_USER}" \
        --docker-password="${JFROG_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi
kubectl patch serviceaccount default -n litmus \
    -p '{"imagePullSecrets": [{"name": "'$SECRET_NAME'"}]}' 2>/dev/null || true
# litmus-admin SA is created by the chaos infra — patch it if it exists
kubectl patch serviceaccount litmus-admin -n litmus \
    -p '{"imagePullSecrets": [{"name": "'$SECRET_NAME'"}]}' 2>/dev/null || true
# argo SA is created by Argo Workflows (used by chaos-runner and experiment pods)
kubectl patch serviceaccount argo -n litmus \
    -p '{"imagePullSecrets": [{"name": "'$SECRET_NAME'"}]}' 2>/dev/null || true
# argo-chaos SA used by some ChaosEngine configurations
kubectl patch serviceaccount argo-chaos -n litmus \
    -p '{"imagePullSecrets": [{"name": "'$SECRET_NAME'"}]}' 2>/dev/null || true
ok "litmus namespace ready with $SECRET_NAME secret."

# ── 7) Setup sock-shop namespace for JFrog image pulls ───────────────────────
echo
echo -e "${BOLD}6) Sock-shop namespace setup${NC}"
kubectl create namespace sock-shop --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Add Helm ownership labels so helm install doesn't conflict with pre-created namespace
kubectl label namespace sock-shop app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
kubectl annotate namespace sock-shop meta.helm.sh/release-name=sock-shop --overwrite 2>/dev/null || true
kubectl annotate namespace sock-shop meta.helm.sh/release-namespace=sock-shop --overwrite 2>/dev/null || true
if [[ -n "$JFROG_USER" && -n "$JFROG_TOKEN" ]]; then
    kubectl create secret docker-registry "$SECRET_NAME" \
        --namespace sock-shop \
        --docker-server="${DOCKER_SERVER}" \
        --docker-username="${JFROG_USER}" \
        --docker-password="${JFROG_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi
kubectl patch serviceaccount default -n sock-shop \
    -p '{"imagePullSecrets": [{"name": "'$SECRET_NAME'"}]}' 2>/dev/null || true
# flash-agent-sa is created by the helm chart — patch it if it exists
kubectl patch serviceaccount flash-agent-sa -n sock-shop \
    -p '{"imagePullSecrets": [{"name": "'$SECRET_NAME'"}]}' 2>/dev/null || true
ok "sock-shop namespace ready with $SECRET_NAME secret."

# ── 8) Setup litellm namespace for JFrog image pulls ─────────────────────────
echo
echo -e "${BOLD}7) Litellm namespace setup${NC}"
kubectl create namespace litellm --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace litellm app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
kubectl annotate namespace litellm meta.helm.sh/release-name=litellm --overwrite 2>/dev/null || true
kubectl annotate namespace litellm meta.helm.sh/release-namespace=litellm --overwrite 2>/dev/null || true
if [[ -n "$JFROG_USER" && -n "$JFROG_TOKEN" ]]; then
    kubectl create secret docker-registry "$SECRET_NAME" \
        --namespace litellm \
        --docker-server="${DOCKER_SERVER}" \
        --docker-username="${JFROG_USER}" \
        --docker-password="${JFROG_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi
kubectl patch serviceaccount default -n litellm \
    -p '{"imagePullSecrets": [{"name": "'$SECRET_NAME'"}]}' 2>/dev/null || true
ok "litellm namespace ready with $SECRET_NAME secret."

echo
echo -e "${GREEN}=== All namespace prerequisites applied ===${NC}"

# ── 8) Deploy JFrog Secret Sync Deployment (cluster-wide) ──────────────────
echo
echo -e "${BOLD}7) JFrog Secret Sync (cluster-wide auto-replication)${NC}"
if [[ -f "$REPO_ROOT/deploy/jfrog-secret-sync.yaml" ]]; then
    # Migrate: remove old CronJob if present (replaced by always-running Deployment).
    kubectl delete cronjob jfrog-secret-sync -n kube-system --ignore-not-found >/dev/null 2>&1 || true

    kubectl apply -f "$REPO_ROOT/deploy/jfrog-secret-sync.yaml" >/dev/null
    ok "jfrog-secret-sync Deployment deployed in kube-system."
    echo -e "  ${DIM}Watches namespace events — syncs $SECRET_NAME within seconds of creation.${NC}"
    echo -e "  ${DIM}Also reconciles all namespaces every 60s (safety net / credential rotation).${NC}"
    # Wait for the Deployment to be ready; it begins syncing immediately on startup.
    kubectl rollout status deployment/jfrog-secret-sync -n kube-system --timeout=60s >/dev/null 2>&1 \
        && ok "jfrog-secret-sync Deployment ready — initial sync underway." \
        || warn "jfrog-secret-sync Deployment not yet ready (check: kubectl get pod -n kube-system -l app=jfrog-secret-sync)."
else
    warn "deploy/jfrog-secret-sync.yaml not found — skipping cluster-wide sync."
fi

echo
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  All prerequisites complete.${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
