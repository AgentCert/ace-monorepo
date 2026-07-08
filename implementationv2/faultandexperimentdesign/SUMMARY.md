# Faults & Experimentation — Implementation Plan Summary

**Spec:** `/srv/projects/ace-monorepo/spec/faults-and-experimentation.md`  
**Total Stages:** 12 across 4 phases  
**Created:** 2026-07-07

---

## Stage Summary

| Stage | Phase | Name | Key New Files |
|-------|-------|------|--------------|
| 01 | 0 | Fault Catalog Directory | `catalog/faults/general/pod-delete/fault.yaml`, `cpu-hog/fault.yaml`, `catalog/faults/domains/cloud-native/pod-oom-kill/fault.yaml`, `domains/telecom/snmp-trap-flood/fault.yaml`, `catalog/apps/official/sock-shop/faults/carts-db-corrupt/fault.yaml` |
| 02 | 0 | FaultCatalogEntry Loader | `pkg/fault_catalog/model.go`, `loader.go`, `service.go`, `errors.go` |
| 03 | 0 | Fault Catalog GraphQL | `graphql/definitions/shared/fault_catalog.graphqls`, `graph/fault_catalog.resolvers.go` |
| 04 | 1 | ExperimentDefinition Types | `pkg/experiment_definition/model.go`, `repository.go`, `service.go`, `errors.go` |
| 05 | 1 | Experiment Definition GraphQL | `graphql/definitions/shared/experiment_definition.graphqls`, `graph/experiment_definition.resolvers.go` |
| 06 | 1 | App–Fault Compatibility | Extends `pkg/fault_catalog/service.go` + `graph/fault_catalog.resolvers.go` |
| 07 | 2 | Argo Workflow Hydrator | `pkg/experiment_hydrator/hydrator.go`, `chaosengine_renderer.go`, `dag_builder.go` |
| 08 | 2 | Extended Run Tracking | `graphql/definitions/shared/experiment_run_ext.graphqls`, `pkg/experiment_definition/run_model.go`, `run_repository.go` |
| 09 | 2 | submitRun + abortRun | `graph/experiment_run.resolvers.go`, `graph/experiment_run_converters.go` |
| 10 | 3 | Chaos Studio: App + Agent Select | `web/src/views/ChaosStudio/index.tsx`, `SelectApp.tsx`, `SelectAgent.tsx` |
| 11 | 3 | Chaos Studio: Canvas | `web/src/views/ChaosStudio/ExperimentCanvas.tsx`, `FaultLibraryPanel.tsx`, `FaultParameterPanel.tsx` |
| 12 | 3 | Chaos Studio: Configure & Run | `web/src/views/ChaosStudio/ConfigureAndRun.tsx`, `RunDialog.tsx`, `RunStatusPage.tsx`, `web/src/api/experiments.ts` |

---

## Phase Overview

```
Phase 0: Fault Catalog (Stages 01–03)
  ↓
Phase 1: Experiment Definition CRUD (Stages 04–06)
  ↓
Phase 2: Execution Pipeline (Stages 07–09)
  ↓
Phase 3: Chaos Studio UI (Stages 10–12)
```

---

## Key Reuse (Do NOT Duplicate)

| Existing asset | Used by |
|---|---|
| `pkg/fault_studio/` | Leave as-is; different concept from fault catalog |
| `pkg/chaos_experiment/ops/` | Stage 09 — reuse Argo submit mechanics |
| `pkg/apps_registry/` | Stage 06 — app.yaml lookup for compatibility filter |
| `pkg/agent_registry/` | Stage 09 — agent lookup for constraint validation |
| `pkg/apphub/` | Stage 02 — pattern for catalog YAML loader |
| `chaos_experiment.graphqls` | Do not modify; new `experiment_definition.graphqls` is separate |

---

## Getting Started

```bash
# 1. Read the spec
cat /srv/projects/ace-monorepo/spec/faults-and-experimentation.md

# 2. Confirm dependencies
kubectl get pods -n litmus | grep argo
kubectl get pods -n litmus | grep litmus

# 3. Start Stage 01
cat implementationv2/faultandexperimentdesign/stages/STAGE_01.md

# 4. After each stage, update PROGRESS.md
```

---

**Status:** Ready for Implementation
