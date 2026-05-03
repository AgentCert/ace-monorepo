#!/usr/bin/env bash
# ============================================================================
# cleanup-litmus-ns.sh — force-clean a stuck namespace
# ============================================================================
# Recovers a namespace that's stuck Terminating because pods, ChaosEngines,
# ChaosResults, or workflows are holding finalizers.
#
# Usage:
#   bash cleanup-litmus-ns.sh                  # cleans default ns "litmus"
#   bash cleanup-litmus-ns.sh <namespace>      # clean a different ns
#   bash cleanup-litmus-ns.sh --dry-run        # show what would be done
#   bash cleanup-litmus-ns.sh --no-finalize    # skip the nuclear ns finalize step
#
# Order of operations (each step is idempotent and safe to re-run):
#   1) Show current state + finalizers
#   2) Force-delete all pods (grace-period=0, --force)
#   3) Strip pod finalizers
#   4) Strip finalizers from chaosengines/chaosresults/workflows
#   5) Strip namespace finalizers via /finalize subresource (nuclear option)
#   6) Verify the namespace is gone
# ============================================================================

set -euo pipefail

NS="litmus"
DRY_RUN=false
SKIP_FINALIZE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=true; shift ;;
    --no-finalize)  SKIP_FINALIZE=true; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *)              NS="$1"; shift ;;
  esac
done

c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel()   { printf '\033[33m%s\033[0m\n' "$*"; }
c_cyn()   { printf '\033[36m%s\033[0m\n' "$*"; }
hdr()     { echo; c_cyn "==> $*"; }
run()     { if $DRY_RUN; then echo "  [dry-run] $*"; else eval "$@"; fi; }

# Pre-flight checks
command -v kubectl >/dev/null || { c_red "[ERROR] kubectl not found in PATH"; exit 1; }
command -v jq >/dev/null      || { c_red "[ERROR] jq not found in PATH (needed for finalize step)"; exit 1; }

if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  c_grn "[OK] Namespace '$NS' does not exist — nothing to clean."
  exit 0
fi

c_yel "Target namespace: $NS"
$DRY_RUN && c_yel "Mode: DRY RUN (no changes will be made)"

# ── Step 1: Diagnose ─────────────────────────────────────────────────────────
hdr "Step 1: current state"
kubectl get all -n "$NS" 2>/dev/null || true
echo
echo "Pods with finalizers:"
kubectl get pods -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.finalizers}{"\n"}{end}' 2>/dev/null || true
echo
echo "Namespace status:"
kubectl get ns "$NS" -o jsonpath='{.status}' 2>/dev/null
echo

# ── Step 2: Force-delete pods ────────────────────────────────────────────────
hdr "Step 2: force-deleting all pods (grace-period=0)"
PODS=$(kubectl get pods -n "$NS" -o name 2>/dev/null || true)
if [[ -n "$PODS" ]]; then
  run "kubectl delete pods --all -n '$NS' --grace-period=0 --force --ignore-not-found 2>&1 | sed 's/^/  /'"
else
  echo "  (no pods)"
fi

# ── Step 3: Strip pod finalizers ─────────────────────────────────────────────
hdr "Step 3: stripping pod finalizers"
PODS=$(kubectl get pods -n "$NS" -o name 2>/dev/null || true)
if [[ -n "$PODS" ]]; then
  while IFS= read -r p; do
    run "kubectl patch -n '$NS' '$p' -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge 2>&1 | sed 's/^/  /' || true"
  done <<< "$PODS"
else
  echo "  (no pods left)"
fi

# ── Step 4: Strip CR finalizers ──────────────────────────────────────────────
hdr "Step 4: stripping finalizers on Litmus + Argo CRs"
for kind in chaosengines chaosresults chaosschedules workflows.argoproj.io cronworkflows.argoproj.io; do
  if ! kubectl api-resources --no-headers 2>/dev/null | awk '{print $NF}' | grep -qx "$kind" && \
     ! kubectl api-resources --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "${kind%%.*}"; then
    echo "  ($kind: kind not registered, skipping)"
    continue
  fi
  RES=$(kubectl get "$kind" -n "$NS" -o name 2>/dev/null || true)
  if [[ -z "$RES" ]]; then
    echo "  ($kind: none in $NS)"
    continue
  fi
  while IFS= read -r r; do
    run "kubectl patch -n '$NS' '$r' -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge 2>&1 | sed 's/^/  /' || true"
  done <<< "$RES"
done

# ── Step 5: Strip namespace finalizers (nuclear) ─────────────────────────────
if $SKIP_FINALIZE; then
  hdr "Step 5: SKIPPED (--no-finalize)"
else
  # Only run if namespace is stuck Terminating
  PHASE=$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "$PHASE" == "Terminating" ]]; then
    hdr "Step 5: namespace is Terminating — clearing namespace finalizers via /finalize"
    if $DRY_RUN; then
      echo "  [dry-run] kubectl get ns '$NS' -o json | jq '.spec.finalizers=[]' | kubectl replace --raw '/api/v1/namespaces/$NS/finalize' -f -"
    else
      kubectl get ns "$NS" -o json \
        | jq '.spec.finalizers = []' \
        | kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - >/dev/null 2>&1 \
        && c_grn "  [OK] Namespace finalizers cleared" \
        || c_yel "  [WARN] /finalize call failed — namespace may already be gone"
    fi
  else
    # Not Terminating yet — initiate normal delete
    hdr "Step 5: namespace not yet Terminating — initiating delete"
    run "kubectl delete ns '$NS' --wait=false 2>&1 | sed 's/^/  /'"
  fi
fi

# ── Step 6: Verify ───────────────────────────────────────────────────────────
hdr "Step 6: verification"
sleep 2
if kubectl get ns "$NS" >/dev/null 2>&1; then
  STILL=$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  c_yel "[WARN] Namespace '$NS' still present (phase=$STILL)."
  echo "       Run again, or inspect with: kubectl get ns '$NS' -o yaml"
  exit 1
else
  c_grn "[OK] Namespace '$NS' is gone."
fi
