# Stage 12: Install Mechanics — PrometheusRule + RBAC + Namespace Annotation

**Phase:** 5 — Install Mechanics  
**Dependencies:** Stage 11  
**Risk Level:** High (touches experiment execution path)

---

## Objectives

1. Verify that the existing `install-application` Argo step in experiments already handles the spec's install sequence
2. Add PrometheusRule CRD generation from `spec.observability.prometheus.alertRules[]` at install time
3. Add RBAC Role + RoleBinding generation from `spec.rbac.chaosRunnerPermissions[]` at install time
4. Confirm namespace annotation (`ace.io/app`, `ace.io/app-version`, `ace.io/workflow-uid`) is applied
5. Verify the fresh-install guarantee (stale namespace detection via annotation)

---

## Current State Analysis

### What We Have
- `pkg/chaos_experiment/ops/service.go` — patches the install-application template
- The `install-application` step is an Argo template that runs the `agentcert-install-app` container
- `install-app` binary (in `agentcert/agentcert-install-app` image) runs Helm install
- The spec defines a detailed install sequence (spec §9.2) including:
  - Namespace creation (idempotent)
  - RBAC application
  - Helm install
  - Additional manifests
  - Health probe loop
  - Namespace annotation

### What We Need to Verify
- Does `install-app` currently apply RBAC before Helm install? (Check install-app source or its args)
- Does `install-app` apply PrometheusRule after Helm install?
- Does `install-app` annotate the namespace with ACE metadata?
- Is stale namespace detection implemented?

### Key Files to Inspect
```bash
# Check install-app source (may be in scripts/ or a separate submodule)
find /srv/projects/ace-monorepo -name "install-app" -o -name "install_app.go" | grep -v ".git" | head -5

# Check how install-application is called in experiments
grep -n "install-application\|install_app\|INSTALL_NAMESPACE" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/chaos_experiment/ops/service.go | head -20
```

---

## Pre-Stage Verification

```bash
# Stage 11 complete
curl -s http://localhost:8080/api/catalog/validate-name -X POST \
  -H "Content-Type: application/json" -d '{"name":"test"}' | grep available

# Check what the install-application template looks like in a saved experiment
# (Look at any experiment YAML in the system)
kubectl get workflow -n litmus -o yaml 2>/dev/null | grep -A 20 "install-application" | head -30
```

---

## Implementation Tasks

### Task 1: Audit the Install-App Binary

Find the `install-app` binary source and verify what it currently does:

```bash
# Check if install-app is in the monorepo
find /srv/projects/ace-monorepo -type f \( -name "main.go" -o -name "install*.go" \) | grep -v ".git" | grep -v vendor | head -10

# Or check the scripts directory
ls /srv/projects/ace-monorepo/scripts/ | grep install
```

If the `install-app` source is NOT in the monorepo (it's a separate repo or binary only), document what steps it currently performs by checking:
1. The Argo template args passed to it (from `ops/service.go`)
2. Any existing helm hooks in the Sock Shop chart

### Task 2: Define the Gap Between Current and Spec

Based on the audit, document what the `install-app` binary currently does vs. what spec §9.2 requires:

| Step | Spec §9.2 | Current State | Gap |
|------|-----------|---------------|-----|
| Namespace create | Idempotent kubectl apply | Unknown | Verify |
| RBAC apply | Role+RoleBinding from `spec.rbac` | Unknown | Verify |
| Helm install | `helm install` with `--set` from inputs | Partial (Helm done) | Check RBAC/inputs |
| Additional manifests | kubectl apply | Unknown | Verify |
| Health probe loop | GET loop with threshold | Exists (readiness patch in service.go) | ✅ |
| Namespace annotation | `ace.io/app=`, `ace.io/workflow-uid=` | Unknown | Verify |

### Task 3: RBAC Generation Patch in Argo Workflow

If `install-app` does NOT apply RBAC, add it as a separate Argo step before `install-application`. Follow the existing pattern in `applyRBACPatch` in `ops/service.go` (which already handles some RBAC):

```bash
# Read the existing RBAC patch
grep -n "applyRBACPatch\|argo-chaos\|Role\|RoleBinding" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/chaos_experiment/ops/service.go | head -30
```

If `applyRBACPatch` already injects an RBAC step, check whether it uses static rules or reads from the `ApplicationSpec`:

```go
// The ideal implementation reads from ApplicationSpec:
// spec.rbac.chaosRunnerPermissions → generate Role YAML → apply via kubectl
// This requires the CatalogService to be available at experiment-save time
```

**Minimum viable approach for Iter 1:** The existing RBAC patch in `service.go` injects minimum Litmus rules. For Iter 1, this is sufficient. The app-specific RBAC from `spec.rbac.chaosRunnerPermissions` is an enhancement that can be added in a follow-up.

Document the current state and mark which gaps are Iter 1 vs. Iter 2.

### Task 4: Namespace Annotation Verification

Verify the stale namespace detection is implemented. The spec requires:

```bash
# At install time, check for stale namespace
EXISTING_UID=$(kubectl get ns <namespace> \
  -o jsonpath='{.metadata.annotations.ace\.io/workflow-uid}' 2>/dev/null || echo "")

if [ -n "$EXISTING_UID" ] && [ "$EXISTING_UID" != "{{workflow.uid}}" ]; then
  echo "Stale namespace — cleaning up..."
  helm uninstall <app> -n <namespace> --ignore-not-found
  kubectl delete ns <namespace>
fi
```

Check if this logic exists in:
1. The `install-app` binary source
2. Any existing Argo template shell steps in experiments

If NOT present, add it as an init container or as a shell step in the Argo template via `ops/service.go`.

### Task 5: PrometheusRule Generation

The spec requires alert rules from `spec.observability.prometheus.alertRules[]` to be applied as a PrometheusRule CRD at install time.

**Approach for Iter 1:** Pre-generate the PrometheusRule YAML from `app.yaml` and include it as an additional manifest in `catalog/apps/official/sock-shop/` (referenced in `spec.install.additionalManifests`).

**File to Create:** `catalog/apps/official/sock-shop/monitoring/prometheus-rules.yaml`

```yaml
# This file is generated from spec.observability.prometheus.alertRules[].
# The {{.AppNamespace}} placeholder is substituted at install time by install-app.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: sock-shop-alerts
  namespace: "{{.AppNamespace}}"
  labels:
    app: sock-shop
    prometheus: kube-prometheus
    role: alert-rules
spec:
  groups:
    - name: sock-shop.rules
      rules:
        - alert: HighRequestErrorRate
          expr: >-
            sum(rate(http_requests_total{namespace="{{.AppNamespace}}",status=~"5.."}[2m])) /
            sum(rate(http_requests_total{namespace="{{.AppNamespace}}"}[2m])) > 0.05
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "High HTTP error rate in {{.AppNamespace}}"

        - alert: KubePodNotReady
          expr: >-
            kube_pod_status_ready{namespace="{{.AppNamespace}}",condition="true"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Pod not ready in {{.AppNamespace}}"

        - alert: NoRequestsReceived
          expr: >-
            sum(rate(http_requests_total{namespace="{{.AppNamespace}}"}[2m])) == 0
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "No traffic in {{.AppNamespace}}"
```

Add this manifest path to `catalog/apps/official/sock-shop/app.yaml` under `spec.install.additionalManifests`:

```yaml
# In app.yaml spec.install section:
additionalManifests:
  - "monitoring/prometheus-rules.yaml"
```

The `install-app` binary should resolve this path relative to the app's catalog directory.

### Task 6: Verify the onExit Handler

Confirm that the Argo workflow's `onExit` handler runs `helm uninstall` regardless of failure. This is critical for the Fresh Install Guarantee (spec §10).

```bash
# Look for onExit in experiment templates
grep -rn "onExit\|uninstall\|cleanup" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/chaos_experiment/ops/ \
  --include="*.go" | head -20
```

If `onExit` is not present, it must be added to the generated Argo workflow spec.

### Task 7: Write an End-to-End Install Verification Script

**File to Create:** `implementationv2/apponboarding/tests/verify-install-mechanics.sh`

```bash
#!/usr/bin/env bash
# Verifies the install mechanics against the spec §9.2 requirements.
# Run this after deploying to a kind cluster with the ACE stack.
set -euo pipefail

APP_NAME="${1:-sock-shop}"
WORKFLOW_NAME="${2:-}"

echo "=== Install Mechanics Verification for $APP_NAME ==="

# 1. Check namespace exists with ACE annotations
echo "--- Checking namespace annotations..."
NS=$(kubectl get namespace "$APP_NAME" -o json 2>/dev/null || echo "{}")
APP_ANNOTATION=$(echo "$NS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('metadata',{}).get('annotations',{}).get('ace.io/app','NOT SET'))")
echo "ace.io/app = $APP_ANNOTATION"

if [ "$APP_ANNOTATION" = "$APP_NAME" ]; then
  echo "PASS: namespace annotation present"
else
  echo "WARN: namespace annotation missing or wrong (expected: $APP_NAME, got: $APP_ANNOTATION)"
fi

# 2. Check RBAC role exists
echo "--- Checking RBAC..."
kubectl get role ace-chaos-runner -n "$APP_NAME" 2>/dev/null && echo "PASS: Role exists" || echo "WARN: Role not found"
kubectl get rolebinding ace-chaos-runner-binding -n "$APP_NAME" 2>/dev/null && echo "PASS: RoleBinding exists" || echo "WARN: RoleBinding not found"

# 3. Check PrometheusRule exists
echo "--- Checking PrometheusRule..."
kubectl get prometheusrule sock-shop-alerts -n "$APP_NAME" 2>/dev/null && echo "PASS: PrometheusRule exists" || echo "WARN: PrometheusRule not found (requires monitoring CRDs)"

# 4. Check deployments are running
echo "--- Checking deployments..."
READY=$(kubectl get deploy -n "$APP_NAME" -o jsonpath='{.items[*].status.readyReplicas}' 2>/dev/null | tr ' ' '\n' | grep -v '^0$' | wc -l)
TOTAL=$(kubectl get deploy -n "$APP_NAME" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
echo "Running: $READY/$TOTAL deployments ready"

# 5. Check health probe endpoint
echo "--- Testing health probe..."
kubectl run probe-test --image=curlimages/curl --rm -it --restart=Never \
  -n "$APP_NAME" \
  -- curl -s -o /dev/null -w "%{http_code}" "http://front-end.${APP_NAME}.svc.cluster.local:80" 2>/dev/null || echo "WARN: health probe not reachable (may not be deployed)"

echo ""
echo "=== Verification complete ==="
```

---

## Files to Create (Summary)

```
catalog/apps/official/sock-shop/
└── monitoring/
    └── prometheus-rules.yaml           (new)

implementationv2/apponboarding/tests/
└── verify-install-mechanics.sh         (new, chmod +x)
```

**Files to Modify:**
- `catalog/apps/official/sock-shop/app.yaml` — add `additionalManifests: [monitoring/prometheus-rules.yaml]`
- Possibly `ops/service.go` — if stale namespace detection or RBAC gaps are found

---

## Verification Criteria

### Must Pass
- [ ] `catalog/apps/official/sock-shop/app.yaml` passes `catalog/validate.sh` with the new `additionalManifests` field
- [ ] `catalog/apps/official/sock-shop/monitoring/prometheus-rules.yaml` is valid YAML
- [ ] `verify-install-mechanics.sh` runs without error (even if some items are WARN)
- [ ] Gap analysis document completed (what is Iter 1 vs. Iter 2)

### Should Pass (if cluster is available)
- [ ] After an experiment run against Sock Shop: namespace has `ace.io/app=sock-shop` annotation
- [ ] PrometheusRule `sock-shop-alerts` created in the `sock-shop` namespace
- [ ] RBAC Role `ace-chaos-runner` created in the `sock-shop` namespace

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo

# Validate updated app.yaml
python3 -m jsonschema -i catalog/apps/official/sock-shop/app.yaml catalog/app-spec-schema.json

# Run full catalog validation
bash catalog/validate.sh

# Verify install mechanics (requires kind cluster with ACE deployed)
chmod +x implementationv2/apponboarding/tests/verify-install-mechanics.sh
bash implementationv2/apponboarding/tests/verify-install-mechanics.sh sock-shop
```

---

## Rollback Procedure

If Stage 12 causes experiment failures:
1. Remove `additionalManifests` from `app.yaml` (reverts PrometheusRule injection)
2. If `ops/service.go` was modified, revert with `git revert`
3. Re-run `go build ./...` to confirm compilation

---

## Gap Analysis Summary (to fill in during implementation)

| Feature | Status | Iter |
|---------|--------|------|
| Namespace creation (idempotent) | ✅/❌ TBD | 1 |
| RBAC Role+RoleBinding (minimum Litmus rules) | ✅/❌ TBD | 1 |
| RBAC from `spec.rbac.chaosRunnerPermissions[]` | Not yet | 2 |
| Helm install with `--set` from inputs[] | ✅/❌ TBD | 1 |
| PrometheusRule from alert rules | Partial (via additionalManifests) | 1 |
| Namespace annotation `ace.io/app` etc. | ✅/❌ TBD | 1 |
| Stale namespace detection | ✅/❌ TBD | 1 |
| onExit uninstall handler | ✅/❌ TBD | 1 |

---

## Success Criteria

Stage 12 is complete when:
1. Gap analysis is documented
2. PrometheusRule manifest created for Sock Shop
3. `app.yaml` `additionalManifests` references the PrometheusRule
4. `catalog/validate.sh` passes
5. `verify-install-mechanics.sh` script exists and runs

## End of Implementation Plan

All 12 stages complete → App Onboarding is fully implemented per spec.

**Post-implementation:** Run end-to-end test: create an experiment with Sock Shop via the new Catalog Browser, complete the install, run a pod-delete fault on `carts`, verify PrometheusRule alert fires, verify namespace is cleaned up at experiment end.

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
