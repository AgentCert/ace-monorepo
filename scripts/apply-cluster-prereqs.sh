#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# apply-faults.sh — Pre-deploy fixes for AKS behind corporate proxy (Zscaler)
# =============================================================================
# Run ONCE before helm install/upgrade on a fresh cluster. Creates:
#   1. jfrog-registry imagePullSecret (for pulling from JFrog Artifactory)
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
JFROG_USER="${JFROG_USER:-}"
JFROG_TOKEN="${JFROG_TOKEN:-}"

if [[ -z "$JFROG_USER" ]]; then
    read -rp "  JFrog username: " JFROG_USER
fi
if [[ -z "$JFROG_TOKEN" ]]; then
    read -rsp "  JFrog token/password: " JFROG_TOKEN
    echo
fi

if [[ -n "$JFROG_USER" && -n "$JFROG_TOKEN" ]]; then
    kubectl create secret docker-registry jfrog-registry \
        --namespace "${NS}" \
        --docker-server="infyartifactory.jfrog.io" \
        --docker-username="${JFROG_USER}" \
        --docker-password="${JFROG_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    ok "jfrog-registry secret created/updated in '${NS}'."
else
    warn "JFrog credentials not provided — skipping secret creation."
fi

# ── 3) CA Certificates ConfigMap ─────────────────────────────────────────────
echo
echo -e "${BOLD}2) Corporate CA Certificates${NC}"
if [[ -d "$CA_DIR" ]] && ls "$CA_DIR"/*.crt >/dev/null 2>&1; then
    # Ensure certs are readable without sudo
    chmod a+r "$CA_DIR"/*.crt 2>/dev/null || true
    # Create ConfigMap from all .crt files in the directory
    kubectl create configmap ca-certs \
        --namespace "${NS}" \
        --from-file="$CA_DIR" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    ok "ca-certs ConfigMap created from ${CA_DIR}/*.crt"
else
    warn "No .crt files found in ${CA_DIR} — skipping CA ConfigMap."
    echo -e "  ${DIM}Set CORPORATE_CA_CERT_DIR to your cert directory and re-run.${NC}"
fi

# ── 4) IMAGE_REGISTRY in .env ────────────────────────────────────────────────
echo
echo -e "${BOLD}3) IMAGE_REGISTRY in .env${NC}"
if [[ -f "$ENV_FILE" ]]; then
    if grep -q "^IMAGE_REGISTRY=" "$ENV_FILE"; then
        sed -i "s|^IMAGE_REGISTRY=.*|IMAGE_REGISTRY=${REGISTRY}|" "$ENV_FILE"
    else
        echo "IMAGE_REGISTRY=${REGISTRY}" >> "$ENV_FILE"
    fi
    ok "IMAGE_REGISTRY=${REGISTRY} in .env"
else
    warn ".env not found — run scripts/setup.sh first."
fi

# ── 5) Patch default ServiceAccount for imagePullSecrets ─────────────────────
echo
echo -e "${BOLD}4) Patch default ServiceAccount${NC}"
kubectl patch serviceaccount default -n "${NS}" \
    -p '{"imagePullSecrets": [{"name": "jfrog-registry"}]}' 2>/dev/null \
    && ok "default SA patched with jfrog-registry imagePullSecret." \
    || warn "Could not patch default SA (may not exist yet — will work after first deploy)."

echo
echo -e "${GREEN}=== Pre-deploy fixes applied ===${NC}"
echo -e "${DIM}Now run: helm upgrade --install ace deploy/helm/ace -n ace -f deploy/helm/ace/values-env.yaml --timeout 10m${NC}"
