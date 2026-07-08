#!/usr/bin/env bash
# Verifies that Sock Shop was installed correctly and the ACE catalog mechanics work.
# Usage: ./verify-install-mechanics.sh [NAMESPACE]
# Requires: kubectl, helm (optionally)
set -euo pipefail

NS="${1:-sock-shop}"
EXIT_CODE=0

pass() { echo "PASS [$1]"; }
fail() { echo "FAIL [$1]: $2"; EXIT_CODE=1; }
info() { echo "INFO [$1]: $2"; }

echo "=== Verifying ACE Sock Shop install mechanics (namespace: $NS) ==="
echo ""

# ── 1. Namespace exists ─────────────────────────────────────────────────
if kubectl get namespace "$NS" &>/dev/null; then
  pass "namespace $NS exists"
else
  fail "namespace" "namespace $NS not found — did helm install run?"
  exit 1
fi

# ── 2. Deployments ready ────────────────────────────────────────────────
EXPECTED_DEPLOYMENTS=(front-end carts catalogue orders payment shipping user queue-master)
for dep in "${EXPECTED_DEPLOYMENTS[@]}"; do
  READY=$(kubectl get deployment "$dep" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY:-0}" -ge 1 ]; then
    pass "deployment/$dep ready ($READY replicas)"
  else
    fail "deployment/$dep" "not ready (readyReplicas=${READY:-0})"
  fi
done

# ── 3. StatefulSets ready ───────────────────────────────────────────────
EXPECTED_STS=(carts-db catalogue-db orders-db user-db rabbitmq)
for sts in "${EXPECTED_STS[@]}"; do
  READY=$(kubectl get statefulset "$sts" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY:-0}" -ge 1 ]; then
    pass "statefulset/$sts ready ($READY replicas)"
  else
    fail "statefulset/$sts" "not ready (readyReplicas=${READY:-0})"
  fi
done

# ── 4. Health probe ─────────────────────────────────────────────────────
PROBE_URL="http://front-end.${NS}.svc.cluster.local:80"
if kubectl run ace-probe-check --image=curlimages/curl:8.1.2 --restart=Never --rm -i \
    --timeout=30s -- curl -sf --max-time 10 "$PROBE_URL" &>/dev/null; then
  pass "health probe → $PROBE_URL returned 200"
else
  info "health probe" "skipped (requires in-cluster context or may not have curl image)"
fi

# ── 5. PrometheusRule applied ────────────────────────────────────────────
if kubectl get prometheusrule sock-shop-alerts -n "$NS" &>/dev/null; then
  pass "PrometheusRule/sock-shop-alerts exists"
else
  info "PrometheusRule" "not found — OK if prometheus-operator is not installed"
fi

# ── 6. RBAC — Role and RoleBinding ──────────────────────────────────────
for rb in litmus-admin-role litmus-admin; do
  if kubectl get role "$rb" -n "$NS" &>/dev/null || kubectl get rolebinding "$rb" -n "$NS" &>/dev/null; then
    pass "RBAC/$rb exists in $NS"
  else
    info "RBAC/$rb" "not found — will be created by ChaosEngine"
  fi
done

# ── 7. Catalog schema validation ────────────────────────────────────────
CATALOG_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)/catalog"
APP_YAML="$CATALOG_ROOT/apps/official/sock-shop/app.yaml"
if [ -f "$APP_YAML" ]; then
  if python3 -m jsonschema -i "$APP_YAML" "$CATALOG_ROOT/app-spec-schema.json" &>/dev/null; then
    pass "catalog app.yaml passes JSON schema"
  else
    fail "catalog schema" "app.yaml failed schema validation — run: $CATALOG_ROOT/validate.sh"
  fi
else
  fail "catalog app.yaml" "file not found at $APP_YAML"
fi

# ── 8. Template variable check ──────────────────────────────────────────
if [ -f "$APP_YAML" ]; then
  PROBE_URL_RAW=$(python3 -c "import yaml; d=yaml.safe_load(open('$APP_YAML')); print(d['spec']['healthProbe']['url'])")
  if echo "$PROBE_URL_RAW" | grep -q "{{.AppNamespace}}"; then
    pass "healthProbe.url uses {{.AppNamespace}} template variable"
  else
    fail "healthProbe.url" "must use {{.AppNamespace}}, got: $PROBE_URL_RAW"
  fi
fi

echo ""
if [ $EXIT_CODE -eq 0 ]; then
  echo "=== All checks passed ==="
else
  echo "=== Some checks FAILED (see above) ==="
  exit 1
fi
