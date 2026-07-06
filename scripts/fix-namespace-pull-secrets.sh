#!/bin/bash
# =============================================================================
# fix-namespace-pull-secrets.sh — Patch ALL ServiceAccounts in litmus and
# sock-shop namespaces with jfrog-registry imagePullSecrets.
#
# Run this AFTER enabling chaos infrastructure from the UI (which dynamically
# creates SAs like litmus, argo-chaos, mcp-server, etc.)
#
# Usage:
#   ./scripts/fix-namespace-pull-secrets.sh
# =============================================================================

set -uo pipefail

GREEN='\033[0;32m'; NC='\033[0m'
ok() { echo -e "${GREEN}✓${NC} $*"; }

SECRET_NAME="${IMAGE_PULL_SECRET_NAME:-jfrog-registry}"

patch_all_sas() {
    local ns="$1"
    echo "── Patching all ServiceAccounts in namespace: $ns ──"

    # Get all SAs in the namespace
    local sas
    sas=$(kubectl get sa -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    if [[ -z "$sas" ]]; then
        echo "  No ServiceAccounts found in $ns"
        return
    fi

    for sa in $sas; do
        # Check if already patched
        local existing
        existing=$(kubectl get sa "$sa" -n "$ns" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null)
        if [[ "$existing" == *"$SECRET_NAME"* ]]; then
            echo "  $sa — already has $SECRET_NAME"
        else
            kubectl patch sa "$sa" -n "$ns" --type=json \
                -p "[{\"op\":\"add\",\"path\":\"/imagePullSecrets/-\",\"value\":{\"name\":\"$SECRET_NAME\"}}]" \
                2>/dev/null || \
            kubectl patch sa "$sa" -n "$ns" --type=merge \
                -p "{\"imagePullSecrets\":[{\"name\":\"$SECRET_NAME\"}]}" 2>/dev/null || true
            ok "$sa — patched"
        fi
    done

    # Restart any pods in ImagePullBackOff or ErrImagePull
    local failing_pods
    failing_pods=$(kubectl get pods -n "$ns" --field-selector=status.phase!=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [[ -n "$failing_pods" ]]; then
        echo "  Restarting failing pods..."
        kubectl delete pods -n "$ns" --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true
        ok "Failing pods restarted"
    fi
}

# Verify secret exists in both namespaces
for ns in litmus sock-shop; do
    if ! kubectl get secret "$SECRET_NAME" -n "$ns" &>/dev/null; then
        echo "ERROR: $SECRET_NAME secret not found in $ns. Run ./scripts/apply-cluster-prereqs.sh first."
        exit 1
    fi
done

patch_all_sas "litmus"
echo
patch_all_sas "sock-shop"

echo
ok "Done — all SAs in litmus and sock-shop patched with $SECRET_NAME"
