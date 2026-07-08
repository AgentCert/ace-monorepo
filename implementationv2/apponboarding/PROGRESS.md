# App Onboarding — Progress Tracker

## Current Status
- **Current Stage:** 12 (Install Mechanics)
- **Last Updated:** 2026-07-07
- **Overall Progress:** 1/12 stages complete (8%)

---

## Stage Completion Status

### Phase 0: Full Spec Creation
- [ ] **Stage 01:** Catalog Directory Skeleton + domains.yaml
  - Status: Not Started | Started: — | Completed: — | Verified: No
  - Notes:

- [ ] **Stage 02:** Sock Shop AppCatalogEntry (app.yaml + ground truth)
  - Status: Not Started | Started: — | Completed: — | Verified: No
  - Notes:

- [ ] **Stage 03:** App Spec JSON Schema for CI Validation
  - Status: Not Started | Started: — | Completed: — | Verified: No
  - Notes:

### Phase 1: Backend — CatalogService
- [ ] **Stage 04:** CatalogService Go Package
  - Status: Not Started | Started: — | Completed: — | Verified: No
  - Notes:

- [ ] **Stage 05:** GraphQL Schema Extension + Resolvers
  - Status: Not Started | Started: — | Completed: — | Verified: No
  - Notes:

### Phase 2: Frontend — Catalog Browser
- [ ] **Stage 06:** Frontend API Queries (listApplications / getApplication)
  - Status: Not Started | Started: — | Completed: — | Verified: No
  - Notes:

- [ ] **Stage 07:** Catalog Browser View (domain filters, tier separation)
  - Status: Not Started | Started: — | Completed: — | Verified: No
  - Notes:

- [ ] **Stage 08:** App Detail Panel (full spec: suitableFor, faults, inputs)
  - Status: Not Started | Started: — | Completed: — | Verified: No
  - Notes:

### Phase 3: Frontend — Contribution Wizard
- [ ] **Stage 09:** Contribution Wizard Steps 1–3 (Identity, Installation, Service Discovery)
  - Status: Not Started | Started: — | Completed: — | Verified: No
  - Notes:

- [ ] **Stage 10:** Contribution Wizard Steps 4–6 (Health Probe, Load Test, Review & Generate)
  - Status: Not Started | Started: — | Completed: — | Verified: No
  - Notes:

### Phase 4: Backend — Contribution Endpoints
- [ ] **Stage 11:** Contribution REST Endpoints (validate, discover, generate)
  - Status: Not Started | Started: — | Completed: — | Verified: No
  - Notes:

### Phase 5: Install Mechanics
- [x] **Stage 12:** Install Mechanics — PrometheusRule + RBAC + Namespace Annotation
  - Status: Complete | Started: 2026-07-07 | Completed: 2026-07-07 | Verified: No
  - Notes: Created catalog/apps/official/sock-shop/monitoring/prometheus-rules.yaml (PrometheusRule CRD with {{.AppNamespace}} template vars); replaced implementationv2/apponboarding/tests/verify-install-mechanics.sh with full 8-check verification script.

---

## Issues and Blockers

### Active Issues
None

### Resolved Issues
None

---

## Notes and Observations

### Key Decisions Made at Planning Time
- Existing `listAppHubCategories` GraphQL query is **not replaced** — new `listApplications` query is additive
- `catalog/` directory lives at monorepo root (not inside AgentCert submodule) — catalog is content, not service code
- `app-charts/charts/sock-shop/` Helm chart is symlinked from `catalog/apps/official/sock-shop/chart/` to avoid duplication
- `AppsOnboarding` view (skeleton with mock data) is **replaced** by the 6-step wizard in Stage 09-10
- `AppsHub` view (existing) is **replaced** by the spec-compliant catalog browser in Stage 07
- Contribution wizard generates files for download only (Iter 1) — GitHub PR integration is Iter 2

### Changes to Plan
None yet
