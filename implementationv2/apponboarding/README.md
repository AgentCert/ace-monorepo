# App Onboarding — Implementation Plan

## Overview

Implements the full [App Onboarding Specification](../../spec/app-onboarding.md) on top of the existing ACE codebase, following a spec-first, reuse-first approach.

**Total Stages:** 12 across 5 phases  
**Current Stage:** 0 (Not Started)  
**Dependencies:** Existing AgentCert GraphQL server, apphub service, AppsHub frontend, app-charts Helm repo, install-app image

---

## How to Use This Plan

### For Each Stage
1. Read `stages/STAGE_NN.md`
2. Review objectives and what already exists (reuse-first)
3. Implement following the tasks in order
4. Run the verification commands in the stage doc
5. Mark complete in `PROGRESS.md`
6. Move to next stage only after all verifications pass

### Resuming
Provide:
- Current stage (from `PROGRESS.md`)
- Path to this README: `implementationv2/apponboarding/README.md`
- Any blockers encountered

---

## Existing Code to Reuse (Mandatory Reading Before Starting)

| Component | Location | Used In |
|-----------|----------|---------|
| `apphub.Service` | `AgentCert/chaoscenter/graphql/server/pkg/apphub/` | Pattern for CatalogService |
| `AppHubEntry`, `AppHubCategory` GraphQL types | `graphql/definitions/shared/hubs.graphqls` | Extended, not replaced |
| `AppsHub` view | `web/src/views/AppsHub/` | Replaced/upgraded Stage 7 |
| `AppDetail` view | `web/src/views/AppDetail/` | Upgraded Stage 8 |
| `AppsOnboarding` view | `web/src/views/AppsOnboarding/` | Replaced Stage 9–10 |
| `AgentOnboarding` view | `web/src/views/AgentOnboarding/` | Reference pattern for wizard |
| `apps_registry` handler | `graphql/server/pkg/apps_registry/` | REST API for contribution submit |
| `sock-shop` Helm chart | `app-charts/charts/sock-shop/` | First official catalog entry |
| `install-application` Argo step | `graphql/server/pkg/chaos_experiment/ops/service.go` | Referenced in Stage 12 |
| Route definitions | `web/src/routes/RouteDefinitions.ts` | Extended Stage 6 |

---

## Phase Overview

### Phase 0: Full Spec Creation (Stages 01–03)
**Goal:** The entire machine-readable spec (catalog directory, domains.yaml, Sock Shop app.yaml, JSON schema) exists before any code is touched.

- **Stage 01:** Catalog directory skeleton + `domains.yaml`
- **Stage 02:** Sock Shop `app.yaml` (complete `AppCatalogEntry`)
- **Stage 03:** App spec JSON Schema for CI validation

### Phase 1: Backend — CatalogService (Stages 04–05)
**Goal:** The GraphQL server can serve `listApplications` and `getApplication` from the new catalog directory.

- **Stage 04:** `CatalogService` Go package — reads `catalog/apps/**/*.yaml`, builds in-memory index
- **Stage 05:** GraphQL schema extension — `ApplicationSpec` types + new queries wired to `CatalogService`

### Phase 2: Frontend — Catalog Browser (Stages 06–08)
**Goal:** User Journey A fully works: browse catalog by domain/tier, view app detail, configure install params.

- **Stage 06:** `listApplications` / `getApplication` Apollo queries in frontend
- **Stage 07:** Catalog Browser view (domain filter sidebar, Official/Community tiers)
- **Stage 08:** App Detail panel (suitableFor, faultCompatibility, inputs with Advanced toggle)

### Phase 3: Frontend — Contribution Wizard (Stages 09–10)
**Goal:** User Journey B works: 6-step wizard generates a valid app.yaml + README.md for download.

- **Stage 09:** Contribution wizard Steps 1–3 (Identity, Installation, Service Discovery)
- **Stage 10:** Contribution wizard Steps 4–6 (Health Probe, Load Test, Review & Generate)

### Phase 4: Backend — Contribution Endpoints (Stage 11)
**Goal:** Backend supports name uniqueness check, service discovery (helm show), and app.yaml file generation.

- **Stage 11:** Contribution REST endpoints (validate name, discover services, generate files)

### Phase 5: Install Mechanics (Stage 12)
**Goal:** `install-app` respects the full spec — PrometheusRule, RBAC, namespace annotation, fresh-install guarantee.

- **Stage 12:** Install mechanics verification + PrometheusRule/RBAC injection patch

---

## Directory Structure Created by This Plan

```
catalog/                          # CREATED by Stage 01-02
├── CATALOG.md
├── domains.yaml
└── apps/
    ├── official/
    │   └── sock-shop/
    │       ├── app.yaml          # CREATED by Stage 02
    │       ├── chart/            # symlink to app-charts/charts/sock-shop
    │       ├── ground-truth/
    │       │   └── ground_truth_v1.yaml
    │       └── docs/
    │           └── README.md
    └── community/                # empty, ready for contributions

AgentCert/chaoscenter/graphql/
├── definitions/shared/
│   └── hubs.graphqls             # EXTENDED by Stage 05
└── server/
    ├── graph/
    │   ├── hubs.resolvers.go     # EXTENDED by Stage 05
    │   └── resolver.go           # EXTENDED by Stage 05
    └── pkg/
        └── catalog/              # CREATED by Stage 04
            ├── service.go
            ├── loader.go
            └── model.go

AgentCert/chaoscenter/web/src/
├── api/core/
│   └── catalog/                  # CREATED by Stage 06
│       ├── listApplications.ts
│       └── getApplication.ts
└── views/
    ├── AppsHub/AppsHub.tsx       # REPLACED by Stage 07
    ├── AppDetail/AppDetail.tsx   # REPLACED by Stage 08
    └── AppsOnboarding/           # REPLACED by Stage 09-10
        └── AppsOnboarding.tsx
```

---

## Stage Dependencies

```
Stage 01 (catalog dirs + domains.yaml)
    ↓
Stage 02 (Sock Shop app.yaml)
    ↓
Stage 03 (JSON Schema for CI)
    ↓
Stage 04 (CatalogService Go package)
    ↓
Stage 05 (GraphQL schema + resolvers)
    ↓
Stage 06 (Frontend API queries)
    ↓
Stage 07 (Catalog Browser UI)    Stage 09 (Wizard Steps 1-3)
    ↓                                ↓
Stage 08 (App Detail UI)         Stage 10 (Wizard Steps 4-6)
                                     ↓
                                 Stage 11 (Contribution endpoints)
                                     ↓
                                 Stage 12 (Install mechanics)
```

---

## Critical Success Factors

1. **Spec-first:** Stages 01–03 must be complete and reviewed before any code is written. The `app.yaml` for Sock Shop is the reference truth that all backend/frontend code is validated against.
2. **Reuse-first:** The existing `apphub` service, `AppsHub` view, and `AgentOnboarding` wizard are the patterns to follow — extend rather than rewrite.
3. **Non-breaking:** The existing `listAppHubCategories` / `getAppHubStatus` GraphQL queries MUST continue to work after Stage 05 (the new queries are additive).
4. **Template variables:** Every `healthProbe.url` and alert rule `expr` MUST use `{{.AppNamespace}}`, never a hardcoded namespace. This is enforced by the JSON schema in Stage 03 and checked in Stage 12.

---

## Quick Reference Commands

```bash
# Validate an app.yaml against the JSON schema
cd /srv/projects/ace-monorepo
jsonschema -i catalog/apps/official/sock-shop/app.yaml catalog/app-spec-schema.json

# Run GraphQL server locally (check if catalog loads)
cd AgentCert/chaoscenter/graphql/server && go run .

# Run frontend dev server
cd AgentCert/chaoscenter/web && yarn start

# Lint a Helm chart
helm lint app-charts/charts/sock-shop/

# Test service discovery (Stage 11)
curl -X POST http://localhost:8080/api/catalog/discover-services \
  -H "Content-Type: application/json" \
  -d '{"repoURL":"...","chartName":"...","version":"..."}'
```

---

## Risk Management

### High-Risk Stages
- **Stage 05** (GraphQL schema): Generated code (`models_gen.go`, `generated.go`) must be regenerated after schema changes. Go generate must be run — failing to regenerate will break the build.
- **Stage 09–10** (Wizard): Service discovery depends on the cluster having Helm CLI available in the GraphQL server pod. If not available, the discovery step degrades gracefully (manual entry).
- **Stage 12** (Install mechanics): Changes to the Argo workflow template patching logic (`ops/service.go`) affect all experiments, not just new ones. Must be tested with an end-to-end experiment run.

### Mitigation
- Stage 05: Run `go generate ./...` from `graphql/server/` after any `.graphqls` file change
- Stage 09–10: Implement manual-entry fallback for service discovery before the helm-based auto-discovery
- Stage 12: Add the RBAC/PrometheusRule injection behind a feature flag tied to app spec version

---

**Last Updated:** 2026-07-07  
**Plan Version:** 1.0  
**Status:** Ready for implementation
