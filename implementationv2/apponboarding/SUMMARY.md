# App Onboarding — Quick Reference Summary

## Overview

12 stages implementing the full App Onboarding Specification on the existing ACE codebase.
Spec-first: all YAML and schema files are written before any code.
Reuse-first: follows existing `apphub`, `AgentOnboarding`, and `apps_registry` patterns.

## Plan Structure

```
implementationv2/apponboarding/
├── README.md          — master plan, stage map, risk management
├── PROGRESS.md        — live tracking
├── ARCHITECTURE.md    — technical decisions, component diagram, data flows
├── SUMMARY.md         — this file
├── stages/            — 12 stage documents
├── references/        — supporting docs
└── tests/             — test scenarios
```

## Stage Summary

| Stage | Phase | Name | Key Deliverables |
|-------|-------|------|------------------|
| 01 | Spec | Catalog Directory + domains.yaml | `catalog/`, `catalog/domains.yaml`, `catalog/CATALOG.md` |
| 02 | Spec | Sock Shop AppCatalogEntry | `catalog/apps/official/sock-shop/app.yaml`, ground truth, README |
| 03 | Spec | JSON Schema + Validation Script | `catalog/app-spec-schema.json`, `catalog/validate.sh` |
| 04 | Backend | CatalogService Go Package | `pkg/catalog/{model,loader,service}.go`, `CATALOG_DIR` config |
| 05 | Backend | GraphQL Schema Extension | New `ApplicationSpec` types + queries, resolvers, mapper |
| 06 | Frontend | API Queries | `api/core/catalog/`, `api/entities/catalog.ts` |
| 07 | Frontend | Catalog Browser View | Rewritten `AppsHub.tsx` with domain filter + tier sections |
| 08 | Frontend | App Detail Panel | Rewritten `AppDetail.tsx` with suitableFor, faults, inputs |
| 09 | Frontend | Wizard Steps 1–3 | Identity, Installation, Service Discovery steps |
| 10 | Frontend | Wizard Steps 4–6 | Health Probe, Load Test, Review & Generate + YAML generator |
| 11 | Backend | Contribution REST Endpoints | `/api/catalog/validate-name`, `/api/catalog/discover-services` |
| 12 | Install | Install Mechanics Audit | PrometheusRule manifest, gap analysis, verify script |

## New Files Created (across all stages)

### Catalog (Stages 01–03)
```
catalog/
├── CATALOG.md
├── domains.yaml
├── app-spec-schema.json
├── validate.sh
└── apps/official/sock-shop/
    ├── app.yaml
    ├── chart-ref.yaml
    ├── ground-truth/ground_truth_v1.yaml
    ├── monitoring/prometheus-rules.yaml
    └── docs/README.md
```

### Backend (Stages 04–05, 11)
```
AgentCert/chaoscenter/graphql/server/pkg/catalog/
├── model.go
├── loader.go
├── service.go
├── mapper.go
└── contribution_handler.go
```

### Frontend (Stages 06–10)
```
AgentCert/chaoscenter/web/src/
├── api/entities/catalog.ts
├── api/core/catalog/
│   ├── index.ts
│   ├── listApplications.ts
│   └── getApplication.ts
└── views/AppsOnboarding/
    ├── types.ts
    ├── generator.ts
    └── steps/
        ├── Step1Identity.tsx
        ├── Step2Installation.tsx
        ├── Step3Services.tsx
        ├── Step4HealthProbe.tsx
        ├── Step5LoadTest.tsx
        └── Step6Review.tsx
```

## Files Modified (across all stages)

| File | Stage | Change |
|------|-------|--------|
| `utils/variables.go` | 04 | Add `CatalogDir` config field |
| `definitions/shared/hubs.graphqls` | 05 | Add `ApplicationSpec` types + queries |
| `graph/resolver.go` | 05 | Wire `catalogService` |
| `graph/hubs.resolvers.go` | 05 | Add `listApplications` + `getApplication` resolvers |
| `api/entities/index.ts` | 06 | Export `catalog.ts` |
| `api/core/index.ts` | 06 | Export `catalog/` |
| `views/AppsHub/AppsHub.tsx` | 07 | Full rewrite — new Catalog Browser |
| `views/AppsHub/AppsHub.module.scss` | 07 | Updated styles |
| `views/AppDetail/AppDetail.tsx` | 08 | Full rewrite — full spec detail panel |
| `views/AppDetail/AppDetail.module.scss` | 08 | Updated styles |
| `views/AppsOnboarding/AppsOnboarding.tsx` | 09–10 | Full rewrite — 6-step wizard shell |
| Server router file | 11 | Register contribution handler routes |
| `views/AppsOnboarding/steps/Step1Identity.tsx` | 11 | Add name availability check |
| `catalog/apps/official/sock-shop/app.yaml` | 12 | Add `additionalManifests` |

## Implementation Order (Critical Path)

```
01 → 02 → 03 → 04 → 05 → 06 → 07 → 08
                              ↓
                     09 → 10 → 11 → 12
```

Stages 07 and 08 can be developed in parallel with 09 and 10 (both depend on 06).

## Getting Started

```bash
cd /srv/projects/ace-monorepo

# 1. Start with Phase 0 — create the spec files
bash implementationv2/apponboarding/stages/STAGE_01.md  # (read it, then implement)

# 2. After Stage 03, validate Sock Shop app.yaml
bash catalog/validate.sh

# 3. After Stage 05, run code generation
cd AgentCert/chaoscenter/graphql/server && go generate ./... && go build ./...

# 4. After Stage 06, run TypeScript check
cd AgentCert/chaoscenter/web && yarn tsc --noEmit

# 5. After Stage 10, test the full wizard
cd AgentCert/chaoscenter/web && yarn start
```

## Key Validation Commands

```bash
# Validate app.yaml schema
python3 -m jsonschema -i catalog/apps/official/sock-shop/app.yaml catalog/app-spec-schema.json

# Run full catalog validation
bash catalog/validate.sh

# Backend build
cd AgentCert/chaoscenter/graphql/server && go build ./...

# Frontend type check
cd AgentCert/chaoscenter/web && yarn tsc --noEmit

# Query the catalog (server running)
curl -s http://localhost:8080/query -X POST \
  -H "Content-Type: application/json" \
  -d '{"query":"{ listApplications(projectID:\"test\") { name tier domain } }"}'
```

---

**Created:** 2026-07-07  
**Total Stages:** 12  
**Status:** Ready for Implementation
