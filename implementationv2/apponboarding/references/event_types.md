# Event Types & State Transitions Reference

## Catalog Events

These events occur during the lifecycle of the CatalogService and catalog entries.

### CatalogLoadEvent

Fired on server startup and on SIGHUP reload.

```
Source:    pkg/catalog/service.go :: LoadAll()
Trigger:   Server start OR kill -SIGHUP <pid>
Effect:    In-memory index rebuilt from catalog/ directory
Log:       INFO  catalog: loaded N applications (M official, K community)
```

### CatalogReloadEvent

```
Source:    pkg/catalog/service.go :: reloadLoop()
Trigger:   SIGHUP signal
Effect:    Atomic swap of in-memory index (no downtime)
Log:       INFO  catalog: reloaded — N applications
```

### CatalogLoadError

```
Source:    pkg/catalog/loader.go :: LoadAll()
Trigger:   Malformed app.yaml, missing required fields
Effect:    Entry skipped, error logged; other entries still loaded
Log:       WARN  catalog: skipping <path>: <reason>
```

---

## Contribution Wizard State Transitions

The wizard uses a step counter (0-indexed) and a `ContributionFormData` object threaded through all steps.

```
STEP 0: Idle (radio: HELM_CHART | CLOUD_MANAGED selected)
  → user clicks "Contribute an App"
STEP 1: Identity (name, domain, short description, long description, maintainer, version)
  → user clicks "Next"
  → validation: name kebab-case ✓, name available ✓, domain selected ✓, short desc 10–120 chars ✓
STEP 2: Installation (install method, chart URL/name/version or git URL)
  → user clicks "Discover Services →"
  → POST /api/catalog/discover-services
  → response populates discoveredServices[]
STEP 3: Service Discovery (review/edit discovered services, set criticality)
  → user clicks "Next"
STEP 4: Health Probe (URL with {{.AppNamespace}}, intervals, timeout)
  → user clicks "Next"
  → validation: URL contains {{.AppNamespace}} ✓
STEP 5: Load Test (method radio, duration, RPS, custom YAML for custom-job)
  → user clicks "Next"
STEP 6: Review & Generate (summary, YAML preview, download)
  → user clicks "Download Files"
  → client-side ZIP generated with app.yaml + README.md
  → wizard resets to STEP 0
```

### Step Navigation Events

| Event | Transition | Side Effect |
|-------|------------|-------------|
| `onNext` from Step 1 | 1 → 2 | Validate Formik fields |
| `onNext` from Step 2 (Quick) | 2 → 3 | POST /api/catalog/discover-services |
| `onNext` from Step 2 (Full) | 2 → 3 | POST /api/catalog/discover-services |
| `onNext` from Step 3 | 3 → 4 | None |
| `onNext` from Step 4 | 4 → 5 | None |
| `onNext` from Step 5 | 5 → 6 | None |
| `onDownload` from Step 6 | — | Generate ZIP, reset to Step 0 |
| `onBack` from any step N | N → N-1 | None |

---

## Install Mechanics Events (Spec §9.2)

These are events within the Argo Workflow `install-application` step.

```
EVENT: install-application step starts
  → Check namespace annotation ace.io/workflow-uid
  → If stale (different UID): helm uninstall + kubectl delete ns
  → kubectl create ns <namespace> (idempotent)
  → kubectl label ns <namespace> ace.io/app=<name> ace.io/app-version=<version>
  → kubectl annotate ns <namespace> ace.io/workflow-uid=<uid>
  → Apply RBAC Role + RoleBinding from spec.rbac.chaosRunnerPermissions
  → helm install <chart> -n <namespace> --set <inputs...>
  → kubectl apply -f additionalManifests (e.g. PrometheusRule)
  → Health probe loop: GET healthProbe.url every intervalSeconds
    → If HTTP 200: increment success counter
    → If success counter >= successThreshold: mark READY
    → If totalElapsed > timeoutSeconds: FAIL step

EVENT: onExit handler fires (regardless of workflow success/failure)
  → helm uninstall <app> -n <namespace> --ignore-not-found
  → kubectl delete ns <namespace> (optional — or leave for next-run stale check)
```

---

## GraphQL Resolver Events

These are non-error log events from the catalog resolvers.

```
INFO  resolver: listApplications called (projectID=<pid>)
INFO  resolver: listApplications returning N applications
INFO  resolver: getApplication called (appName=<name>)
INFO  resolver: getApplication found <name>
WARN  resolver: getApplication not found (appName=<name>)
```

---

## Validation Events (catalog/validate.sh)

```
CHECK 1: Schema validation
  PASS: app.yaml passes JSON Schema
  FAIL: Invalid field or missing required field

CHECK 2: healthProbe.url template variable
  PASS: URL contains {{.AppNamespace}}
  FAIL: URL missing {{.AppNamespace}} — namespace would be hardcoded

CHECK 3: alert rule expr template variable
  PASS: all exprs contain {{.AppNamespace}}
  FAIL: expr missing {{.AppNamespace}} in <file>

CHECK 4: domain validity
  PASS: domain is one of the 6 defined domains
  FAIL: unknown domain "<value>"

CHECK 5: version pin for external-helm
  PASS: chartVersion is a pinned SemVer
  FAIL: chartVersion contains wildcard (^, ~, *, latest, >)

CHECK 6: maintainer email format
  PASS: maintainer contains @
  FAIL: maintainer does not look like an email

CHECK 7: ground-truth directory for official tier
  PASS: ground-truth/ directory exists for official app
  FAIL: official app missing ground-truth/ directory
```

---

## HTTP Error Codes

| Endpoint | Error | HTTP Status | Cause |
|----------|-------|-------------|-------|
| POST /api/catalog/validate-name | invalid JSON body | 400 | Malformed request |
| POST /api/catalog/validate-name | name invalid | 200 + `available: false` | Format violation |
| POST /api/catalog/validate-name | name taken | 200 + `available: false` | Catalog collision |
| POST /api/catalog/discover-services | invalid JSON body | 400 | Malformed request |
| POST /api/catalog/discover-services | missing fields | 400 | repoURL/chartName/chartVersion absent |
| POST /api/catalog/discover-services | helm failure | 500 | helm CLI error |
| GraphQL listApplications | auth failure | 401 | Missing/invalid token |
| GraphQL getApplication | app not found | 200 + `null` | App not in catalog |
