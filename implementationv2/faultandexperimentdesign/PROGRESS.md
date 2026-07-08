# Faults & Experimentation — Progress Tracker

**Plan created:** 2026-07-07  
**Last updated:** 2026-07-07  
**Overall status:** Not Started

---

## Phase 0: Fault Catalog — YAML & Loader

| Stage | Name | Status | Assignee | Started | Completed | Notes |
|-------|------|--------|----------|---------|-----------|-------|
| 01 | Fault Catalog Directory Structure & Seed Faults | [ ] Not Started | — | — | — | |
| 02 | FaultCatalogEntry Go Types + YAML Loader | [ ] Not Started | — | — | — | Depends on Stage 01 |
| 03 | Fault Catalog GraphQL Schema + Resolvers | [ ] Not Started | — | — | — | Depends on Stage 02 |

### Stage 01 Checklist
- [ ] `catalog/faults/general/pod-delete/fault.yaml` created
- [ ] `catalog/faults/general/cpu-hog/fault.yaml` created
- [ ] `catalog/faults/domains/cloud-native/pod-oom-kill/fault.yaml` created
- [ ] `catalog/faults/domains/telecom/snmp-trap-flood/fault.yaml` created
- [ ] `catalog/apps/official/sock-shop/faults/carts-db-corrupt/fault.yaml` created
- [ ] `catalog/validate.sh` updated with `fault validate` subcommand
- [ ] All fault.yamls pass `ace fault validate` dry-run

### Stage 02 Checklist
- [ ] `pkg/fault_catalog/model.go` created
- [ ] `pkg/fault_catalog/loader.go` created — walks catalog dirs at startup
- [ ] `pkg/fault_catalog/service.go` created — `ListFaults`, `GetFault`, `FaultsForApp`
- [ ] `pkg/fault_catalog/errors.go` created
- [ ] Loader wired into `main.go` service initialization
- [ ] Unit tests pass: `go test ./pkg/fault_catalog/...`

### Stage 03 Checklist
- [ ] `graphql/definitions/shared/fault_catalog.graphqls` created
- [ ] Resolver stubs generated (`gqlgen generate`)
- [ ] `listFaults` resolver implemented and tested
- [ ] `getFault` resolver implemented and tested
- [ ] `faultsForApp` resolver stub in place (full filter in Stage 06)
- [ ] Integration test: `curl` query returns ≥1 fault

---

## Phase 1: Experiment Definition — Schema & CRUD

| Stage | Name | Status | Assignee | Started | Completed | Notes |
|-------|------|--------|----------|---------|-----------|-------|
| 04 | ExperimentDefinition Go Types + MongoDB Collection | [ ] Not Started | — | — | — | Depends on Stage 03 |
| 05 | Experiment Definition GraphQL Schema + CRUD | [ ] Not Started | — | — | — | Depends on Stage 04 |
| 06 | App–Fault Compatibility Resolver | [ ] Not Started | — | — | — | Depends on Stages 03 + 05 |

### Stage 04 Checklist
- [ ] `pkg/experiment_definition/model.go` created
- [ ] `pkg/experiment_definition/repository.go` created — MongoDB CRUD on `experiment_definitions`
- [ ] `pkg/experiment_definition/service.go` created — business logic + faultRef validation
- [ ] MongoDB index on `{name: 1, projectID: 1}` with `unique: true` created
- [ ] Unit tests for service layer pass

### Stage 05 Checklist
- [ ] `graphql/definitions/shared/experiment_definition.graphqls` created
- [ ] `createExperiment` mutation implemented
- [ ] `updateExperiment` mutation implemented
- [ ] `deleteExperiment` mutation implemented
- [ ] `getExperiment` query implemented
- [ ] `listExperiments` query implemented
- [ ] All mutations use `@authorized` directive

### Stage 06 Checklist
- [ ] `FaultsForApp` in `fault_catalog.Service` extended with domain + app-specific merge
- [ ] `incompatibleApps` filter applied
- [ ] `faultsForApp(appName)` GraphQL resolver wired to extended service method
- [ ] Manual test: `faultsForApp("sock-shop")` returns general + cloud-native + sock-shop faults

---

## Phase 2: Experiment Execution

| Stage | Name | Status | Assignee | Started | Completed | Notes |
|-------|------|--------|----------|---------|-----------|-------|
| 07 | Argo Workflow Hydrator | [ ] Not Started | — | — | — | Depends on Stage 04 |
| 08 | Extended ExperimentRun Tracking | [ ] Not Started | — | — | — | Depends on Stage 04 |
| 09 | `submitRun` + `abortRun` Mutations | [ ] Not Started | — | — | — | Depends on Stages 07 + 08 |

### Stage 07 Checklist
- [ ] `pkg/experiment_hydrator/hydrator.go` created — `Hydrate()` returns Argo Workflow YAML string
- [ ] `pkg/experiment_hydrator/chaosengine_renderer.go` created — per-step ChaosEngine YAML
- [ ] `pkg/experiment_hydrator/dag_builder.go` created — Argo DAG from step list + `dependsOn`
- [ ] `parallel-fault` step type produces fan-out DAG tasks
- [ ] `Hydrate()` output passes `yaml.Unmarshal` validation
- [ ] Unit tests cover: observe, fault, verify, wait, parallel-fault step types

### Stage 08 Checklist
- [ ] `experiment_run_ext.graphqls` created — extends `ExperimentRun` with new fields
- [ ] MongoDB `experiment_runs_ext` collection schema defined
- [ ] `agentName`, `agentVersion`, `modelUsed`, `modelProvider`, `langfuseTraceId`, `certifierReportId`, `definitionName`, `definitionVersion` fields all present

### Stage 09 Checklist
- [ ] `submitRun` mutation resolver implemented
- [ ] `abortRun` mutation resolver implemented
- [ ] `submitRun` flow: validate def → resolve agent → hydrate → create K8s secret → submit Argo → save run record
- [ ] `abortRun` flow: look up Argo Workflow → `workflow.stop()` → update run status to ABORTED
- [ ] Integration test: submit a dry-run against a local kind cluster

---

## Phase 3: Chaos Studio

| Stage | Name | Status | Assignee | Started | Completed | Notes |
|-------|------|--------|----------|---------|-----------|-------|
| 10 | Chaos Studio — Screen 1 (Select App) + Screen 2 (Select Agent) | [ ] Not Started | — | — | — | Depends on Stage 06 |
| 11 | Chaos Studio — Screen 3 (Canvas / Fault Sequence Builder) | [ ] Not Started | — | — | — | Depends on Stage 10 |
| 12 | Chaos Studio — Screen 4 (Configure & Run) + `submitRun` wiring | [ ] Not Started | — | — | — | Depends on Stages 09 + 11 |

### Stage 10 Checklist
- [ ] `web/src/views/ChaosStudio/SelectApp.tsx` created
- [ ] `web/src/views/ChaosStudio/SelectAgent.tsx` created
- [ ] `SelectApp` calls `faultsForApp` to show fault count per app card
- [ ] `SelectAgent` filters by app domain compatibility
- [ ] Route `/chaos-studio/new` renders the 4-step wizard shell

### Stage 11 Checklist
- [ ] `web/src/views/ChaosStudio/ExperimentCanvas.tsx` created — SVG canvas with step nodes
- [ ] `web/src/views/ChaosStudio/FaultLibraryPanel.tsx` created — grouped by scope
- [ ] `web/src/views/ChaosStudio/FaultParameterPanel.tsx` created — right-side parameter form
- [ ] Drag-and-drop from library to canvas works
- [ ] Step types supported: observe, fault, verify, wait, parallel-fault

### Stage 12 Checklist
- [ ] `web/src/views/ChaosStudio/ConfigureAndRun.tsx` created
- [ ] `web/src/views/ChaosStudio/RunDialog.tsx` created
- [ ] `llmConfig.allowUserChoice` drives model selector rendering
- [ ] `submitRun` mutation called on "Save & Run"
- [ ] Run status polling after submit
- [ ] E2E test: full 4-screen wizard flow completes without errors

---

## Milestone Summary

| Milestone | Stages | Target |
|-----------|--------|--------|
| Fault catalog queryable via GraphQL | 01–03 | — |
| Experiment definitions persisted + queryable | 04–06 | — |
| Argo Workflow submission working end-to-end | 07–09 | — |
| Chaos Studio screens 1–4 working | 10–12 | — |
| Full integration smoke test passes | All | — |
