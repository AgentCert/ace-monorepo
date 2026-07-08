# Test Scenarios

## Overview

This document defines the complete test scenarios for the App Onboarding feature. Tests are grouped by area and ordered from unit → integration → E2E.

Each scenario includes: preconditions, steps, expected results, and the stage that implements the code under test.

---

## Catalog Schema Tests (Stage 03)

### TC-CAT-01: Valid Sock Shop app.yaml passes schema validation

**Stage:** 03  
**Type:** Unit (JSON Schema)

**Preconditions:**
- `catalog/app-spec-schema.json` exists
- `catalog/apps/official/sock-shop/app.yaml` exists

**Steps:**
```bash
python3 -m jsonschema -i catalog/apps/official/sock-shop/app.yaml catalog/app-spec-schema.json
```

**Expected:** Exit code 0, no output

---

### TC-CAT-02: Missing required field fails schema validation

**Stage:** 03  
**Type:** Unit (JSON Schema)

**Preconditions:**
- `catalog/app-spec-schema.json` exists

**Steps:**
```bash
cat > /tmp/bad-app.yaml <<EOF
apiVersion: ace.io/v1
kind: AppCatalogEntry
metadata:
  name: no-spec-app
  version: "1.0.0"
  tier: community
  domain: cloud-native
  maintainer: test@test.com
description:
  short: "Missing spec entirely"
  long: "This app has no spec section."
EOF
python3 -m jsonschema -i /tmp/bad-app.yaml catalog/app-spec-schema.json
```

**Expected:** Non-zero exit code, error mentions missing `spec` property

---

### TC-CAT-03: validate.sh detects missing `{{.AppNamespace}}` in healthProbe.url

**Stage:** 03  
**Type:** Unit (Shell)

**Preconditions:**
- `catalog/validate.sh` exists

**Steps:**
```bash
# Create a minimal app.yaml with bad healthProbe.url
cat > /tmp/bad-probe.yaml <<EOF
apiVersion: ace.io/v1
kind: AppCatalogEntry
metadata:
  name: bad-probe
  version: "1.0.0"
  tier: community
  domain: cloud-native
  maintainer: test@test.com
description:
  short: "Test app"
  long: "Test."
spec:
  install:
    method: external-helm
    chartRef:
      repoURL: https://example.com
      chartName: test
      chartVersion: "1.0.0"
    namespaceSpec: {name: bad-probe, create: true}
    timeoutSeconds: 300
  healthProbe:
    url: "http://front-end.hardcoded-namespace.svc.cluster.local/health"  # WRONG
    intervalSeconds: 10
    timeoutSeconds: 300
    successThreshold: 3
  microservices: []
  suitableFor: []
  faultCompatibility: []
  groundTruth: []
  inputs: []
EOF
bash catalog/validate.sh /tmp/bad-probe.yaml 2>&1 | grep -i "AppNamespace\|FAIL"
```

**Expected:** Output contains "FAIL" or "AppNamespace" error message

---

### TC-CAT-04: validate.sh passes for valid Sock Shop app.yaml

**Stage:** 03  
**Type:** Unit (Shell)

**Steps:**
```bash
bash catalog/validate.sh 2>&1 | grep -E "PASS|FAIL|ERROR"
```

**Expected:** All checks show PASS, exit code 0

---

## CatalogService Tests (Stage 04)

### TC-SVC-01: LoadAll reads Sock Shop app.yaml and returns it

**Stage:** 04  
**Type:** Unit (Go)

**File:** `pkg/catalog/loader_test.go`

```go
func TestLoadAll_SockShop(t *testing.T) {
    entries, err := LoadAll("../../../../../catalog")
    require.NoError(t, err)
    require.Greater(t, len(entries), 0, "expected at least one catalog entry")

    var found *AppCatalogEntry
    for _, e := range entries {
        if e.Metadata.Name == "sock-shop" {
            found = e
            break
        }
    }
    require.NotNil(t, found, "sock-shop not found in catalog")
    assert.Equal(t, "official", found.Metadata.Tier)
    assert.Equal(t, "cloud-native", found.Metadata.Domain)
    assert.Greater(t, len(found.Spec.Microservices), 0)
    assert.Contains(t, found.Spec.HealthProbe.URL, "{{.AppNamespace}}")
}
```

**Expected:** Test passes; sock-shop entry found with correct fields

---

### TC-SVC-02: LoadAll skips app.yaml missing healthProbe.url template variable

**Stage:** 04  
**Type:** Unit (Go)

**Steps:** Create a `catalog/apps/community/bad-app/app.yaml` with `healthProbe.url` without `{{.AppNamespace}}`, run `LoadAll`, confirm the entry is skipped with a WARN log.

**Expected:** `LoadAll` returns no entry for `bad-app`, logs a WARN

---

### TC-SVC-03: GetApplication returns nil for unknown app name

**Stage:** 04  
**Type:** Unit (Go)

```go
func TestGetApplication_NotFound(t *testing.T) {
    svc, err := NewService()
    require.NoError(t, err)
    app, err := svc.GetApplication(context.Background(), "", "nonexistent-app")
    assert.Nil(t, app)
    assert.NoError(t, err) // not found is not an error
}
```

**Expected:** Returns nil, nil

---

### TC-SVC-04: ListApplications returns official entries before community entries

**Stage:** 04  
**Type:** Unit (Go)

**Expected:** First entry has `Tier == "official"` if any official entries exist

---

## GraphQL Resolver Tests (Stage 05)

### TC-GQL-01: listApplications query returns non-empty list

**Stage:** 05  
**Type:** Integration (GraphQL over HTTP)

**Preconditions:** Server running, catalog directory populated

```bash
curl -s http://localhost:8080/query \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"query":"query { listApplications(projectID: \"test\") { name tier domain } }"}' \
  | python3 -m json.tool
```

**Expected:**
```json
{
  "data": {
    "listApplications": [
      {
        "name": "sock-shop",
        "tier": "official",
        "domain": "cloud-native"
      }
    ]
  }
}
```

---

### TC-GQL-02: getApplication returns null for unknown app

**Stage:** 05  
**Type:** Integration (GraphQL over HTTP)

```bash
curl -s http://localhost:8080/query \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"query":"query { getApplication(projectID: \"test\", appName: \"nonexistent\") { name } }"}' \
  | python3 -m json.tool
```

**Expected:**
```json
{
  "data": {
    "getApplication": null
  }
}
```

---

## Frontend API Tests (Stage 06)

### TC-FE-API-01: TypeScript compiles without errors after Stage 06

**Stage:** 06  
**Type:** Compile-time check

```bash
cd AgentCert/chaoscenter/web
yarn tsc --noEmit 2>&1 | head -20
```

**Expected:** Exit code 0, no type errors related to catalog types

---

## Contribution Endpoint Tests (Stage 11)

### TC-CONTRIB-01: validate-name accepts a new unique name

**Stage:** 11  
**Type:** Integration (REST)

```bash
curl -s -X POST http://localhost:8080/api/catalog/validate-name \
  -H "Content-Type: application/json" \
  -d '{"name":"completely-new-app-xyz"}'
```

**Expected:** `{"available":true}`

---

### TC-CONTRIB-02: validate-name rejects an existing catalog app

**Stage:** 11  
**Type:** Integration (REST)

```bash
curl -s -X POST http://localhost:8080/api/catalog/validate-name \
  -H "Content-Type: application/json" \
  -d '{"name":"sock-shop"}'
```

**Expected:** `{"available":false,"error":"...already exists..."}`

---

### TC-CONTRIB-03: validate-name rejects invalid format (spaces)

**Stage:** 11  
**Type:** Integration (REST)

```bash
curl -s -X POST http://localhost:8080/api/catalog/validate-name \
  -H "Content-Type: application/json" \
  -d '{"name":"My App Name"}'
```

**Expected:** `{"available":false,"error":"Name must be kebab-case..."}`

---

### TC-CONTRIB-04: validate-name rejects name > 63 chars

**Stage:** 11  
**Type:** Integration (REST)

```bash
curl -s -X POST http://localhost:8080/api/catalog/validate-name \
  -H "Content-Type: application/json" \
  -d '{"name":"this-is-a-very-long-app-name-that-exceeds-the-maximum-allowed-63-characters-limit"}'
```

**Expected:** `{"available":false,"error":"Name must be kebab-case..."}`

---

### TC-CONTRIB-05: discover-services parses a real public chart

**Stage:** 11  
**Type:** Integration (REST + Helm)

**Preconditions:** `helm` available, internet access

```bash
curl -s -X POST http://localhost:8080/api/catalog/discover-services \
  -H "Content-Type: application/json" \
  -d '{"repoURL":"https://charts.bitnami.com/bitnami","chartName":"nginx","chartVersion":"18.1.7"}'
```

**Expected:** Response contains `services` array with at least one entry

---

### TC-CONTRIB-06: discover-services auto-excludes grafana

**Stage:** 11  
**Type:** Integration (REST + Helm)

**Preconditions:** Use a chart that includes Grafana as a subchart (e.g., kube-prometheus-stack)

**Expected:** Entry for `grafana` has `"autoExcluded": true, "autoExclusionReason": "observability tool"`

---

## Wizard UI Tests (Stages 09–10)

### TC-WIZ-01: Step 1 rejects invalid name on submit

**Stage:** 09  
**Type:** Manual UI

**Steps:**
1. Navigate to Apps Onboarding
2. Enter "My App Name!" in the name field
3. Click Next

**Expected:** Red error text "Name must be lowercase, kebab-case..." appears below the name field. Step does not advance.

---

### TC-WIZ-02: Step 1 rejects name > 63 chars

**Stage:** 09  
**Type:** Manual UI

**Steps:**
1. Enter a 64-character name
2. Click Next

**Expected:** Error "Name must be at most 63 characters"

---

### TC-WIZ-03: Step 2 Quick path requires chartVersion

**Stage:** 09  
**Type:** Manual UI

**Steps:**
1. Complete Step 1 (valid name, domain, description)
2. In Step 2 Quick, fill repoURL and chartName, leave chartVersion empty
3. Click "Discover Services →"

**Expected:** Error: "Chart version is required"

---

### TC-WIZ-04: Step 4 rejects healthProbe.url without template variable

**Stage:** 10  
**Type:** Manual UI

**Steps:**
1. Complete Steps 1–3
2. In Step 4, enter `http://front-end.production.svc.cluster.local/health`
3. Click Next

**Expected:** Error: "URL must contain `{{.AppNamespace}}`"

---

### TC-WIZ-05: Step 6 "Download Files" produces a ZIP

**Stage:** 10  
**Type:** Manual UI

**Steps:**
1. Complete all 5 steps with valid data
2. Click "Download Files" in Step 6

**Expected:**
- Browser downloads a `.zip` file
- ZIP contains `app.yaml` and `README.md`
- `app.yaml` is valid YAML with `apiVersion: ace.io/v1` and `kind: AppCatalogEntry`
- `app.yaml` contains the name, domain, and services entered in the wizard

---

## Catalog Browser UI Tests (Stage 07)

### TC-BROWSER-01: Domain filter "Cloud Native" shows Sock Shop

**Stage:** 07  
**Type:** Manual UI

**Steps:**
1. Navigate to Apps Hub
2. Click "Cloud Native" in the domain filter sidebar

**Expected:** Sock Shop card appears in the grid. Other domain apps are hidden.

---

### TC-BROWSER-02: Search filters apps by name

**Stage:** 07  
**Type:** Manual UI

**Steps:**
1. Type "sock" in the search bar

**Expected:** Only apps whose `name` or `description.short` contains "sock" are shown

---

### TC-BROWSER-03: "Contribute an App" banner links to /apps-onboarding

**Stage:** 07  
**Type:** Manual UI

**Steps:**
1. Navigate to Apps Hub
2. Click the "Contribute an App" button/banner

**Expected:** Browser navigates to the Apps Onboarding route

---

## App Detail UI Tests (Stage 08)

### TC-DETAIL-01: Navigating to App Detail for sock-shop shows all sections

**Stage:** 08  
**Type:** Manual UI

**Steps:**
1. Navigate to Apps Hub
2. Click the Sock Shop card
3. Observe the detail panel

**Expected:**
- `description.long` is rendered (markdown)
- Microservices section shows all services with color-coded criticality tags
- "Suitable For" section shows suitability bullets
- Compatible faults section shows fault names
- Config card shows standard inputs (replicaScale, etc.)
- "Select This App →" button is visible

---

### TC-DETAIL-02: Advanced inputs toggle shows/hides advanced fields

**Stage:** 08  
**Type:** Manual UI

**Steps:**
1. Open Sock Shop detail
2. Click "Show Advanced" toggle in Config card

**Expected:** Additional input fields appear beneath the standard inputs

---

## Install Mechanics Tests (Stage 12)

### TC-INSTALL-01: Sock Shop installs cleanly on first run

**Stage:** 12  
**Type:** E2E (requires kind cluster + ACE stack)

**Steps:**
1. Create a new experiment with Sock Shop as the target application
2. Run the experiment
3. Monitor the `install-application` step in Argo UI

**Expected:**
- Namespace `sock-shop` created
- All 13 Sock Shop deployments reach Ready state within 300s
- Health probe returns HTTP 200 before the step completes

---

### TC-INSTALL-02: Stale namespace is cleaned up before re-install

**Stage:** 12  
**Type:** E2E (requires kind cluster)

**Steps:**
1. Run experiment once (creates `sock-shop` namespace with `ace.io/workflow-uid=uid-1`)
2. Run a second experiment against Sock Shop
3. Observe `install-application` step logs

**Expected:** Logs show "Stale namespace detected — cleaning up" followed by successful re-install

---

### TC-INSTALL-03: PrometheusRule is created after install

**Stage:** 12  
**Type:** E2E (requires kind cluster + Prometheus Operator)

**Steps:**
```bash
# After an experiment install step completes:
kubectl get prometheusrule sock-shop-alerts -n sock-shop
```

**Expected:** PrometheusRule resource exists with `spec.groups[].rules` matching the alert rules in `app.yaml`

---

### TC-INSTALL-04: onExit cleanup removes the Sock Shop namespace

**Stage:** 12  
**Type:** E2E (requires kind cluster)

**Steps:**
1. Run an experiment against Sock Shop
2. Wait for it to complete (success or failure)
3. Check namespace status

**Expected:** `kubectl get ns sock-shop` returns "not found" — the onExit handler cleaned it up

---

## Test Execution Order

For a clean test run across all stages:

```bash
# 1. Schema tests (no server required)
bash catalog/validate.sh

# 2. Go unit tests
cd AgentCert/chaoscenter/graphql/server
go test ./pkg/catalog/... -v

# 3. TypeScript compile check
cd AgentCert/chaoscenter/web
yarn tsc --noEmit

# 4. Start server
# (follow existing startup procedure)

# 5. Integration tests (server running)
bash implementationv2/apponboarding/tests/verify-install-mechanics.sh

# 6. Manual UI tests (server + frontend running)
# Execute TC-BROWSER-01 through TC-DETAIL-02

# 7. E2E tests (kind cluster + full ACE stack)
# Execute TC-INSTALL-01 through TC-INSTALL-04
```
