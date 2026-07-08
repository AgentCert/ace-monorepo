# Faults & Experimentation Implementation Plan

## Overview

This plan implements the ACE Faults & Experimentation subsystem as defined in the spec at
`/srv/projects/ace-monorepo/spec/faults-and-experimentation.md`. The subsystem introduces a
three-tier fault catalog, a reusable experiment definition schema, an Argo Workflow hydration
engine, extended run tracking, and the four-screen Chaos Studio UX.

**Total Stages:** 12 stages organized into 4 phases  
**Current Stage:** 0 (Not Started)  
**Date Created:** 2026-07-07  
**Spec Reference:** `/srv/projects/ace-monorepo/spec/faults-and-experimentation.md`  

**Dependencies:**
- App Onboarding plan complete (`catalog/apps/<app>/app.yaml` must exist with `domain` + `microservices[]` map)
- Agent Onboarding plan complete (`agent_registry.listAgents` GraphQL query must work)
- LitmusChaos operator installed in the `litmus` namespace (`kubectl get crd chaosengines.litmuschaos.io` returns a result)
- Argo Workflows controller installed in the `litmus` namespace (`kubectl get crd workflows.argoproj.io` returns a result)
- MongoDB reachable via `pkg/database/mongodb/` infrastructure (existing)
- GraphQL server compiles and serves requests (existing)

---

## What Already Exists (Do NOT re-implement)

| Component | Location | Notes |
|-----------|----------|-------|
| `fault_studio` service | `AgentCert/chaoscenter/graphql/server/pkg/fault_studio/` | Different concept — curated ChaosHub collections. Keep as-is. |
| `fault_studio.graphqls` | `AgentCert/chaoscenter/graphql/definitions/shared/fault_studio.graphqls` | Do not modify. |
| `chaos_experiment` ops | `AgentCert/chaoscenter/graphql/server/pkg/chaos_experiment/` | Existing Argo submit logic; reuse `ops/` for workflow submission. |
| `chaos_experiment_run` | `AgentCert/chaoscenter/graphql/server/pkg/chaos_experiment_run/` | Run tracking; extend with new fields rather than replacing. |
| `apps_registry` | `AgentCert/chaoscenter/graphql/server/pkg/apps_registry/` | App lookup for compatibility filter. |
| `agent_registry` | `AgentCert/chaoscenter/graphql/server/pkg/agent_registry/` | Agent lookup for constraint checks. |
| `apphub` / `agenthub` | `AgentCert/chaoscenter/graphql/server/pkg/apphub/`, `agenthub/` | Pattern to follow for the fault catalog loader (YAML walk + in-memory index). |
| MongoDB infrastructure | `AgentCert/chaoscenter/graphql/server/pkg/database/` | Add new collections, do not rearrange existing ones. |
| Auth middleware | `AgentCert/chaoscenter/graphql/server/api/middleware/` | All new resolvers use `@authorized` directive. |
| `chaos_experiment.graphqls` | `AgentCert/chaoscenter/graphql/definitions/shared/chaos_experiment.graphqls` | Contains `Experiment` / `ExperimentRun` types. Do NOT modify. |

**Key boundary:** The spec's `ExperimentDefinition` is a **new** top-level object, not the same as the
existing `Experiment` (which wraps an Argo YAML manifest). They coexist and serve different purposes.

---

## How to Use This Plan

1. **Read `ARCHITECTURE.md`** to understand the component diagram and data flow before touching code.
2. **Read `SUMMARY.md`** for a one-page stage-to-file-path index.
3. **Work stages in order** — each stage's pre-stage verification section lists what must be green
   before starting.
4. **Update `PROGRESS.md`** as stages complete — mark the status field and note the date.
5. **Reference files** in `references/` for schema details; do not re-read the spec for field-level
   questions — the references mirror the spec and add implementation notes.
6. **Test guidance** lives in `tests/` — run test scenarios in sequence at the end of each stage.

---

## Stage Overview

### Phase 0: Fault Catalog — YAML & Loader (Stages 1–3)

Establishes the `catalog/faults/` directory tree, seeds five representative fault.yamls, builds
the Go loader service (`pkg/fault_catalog/`), and wires the first three GraphQL queries.

| Stage | Name | Estimated Effort |
|-------|------|-----------------|
| 01 | Fault Catalog Directory Structure & Seed Faults | 0.5 day |
| 02 | FaultCatalogEntry Go Types + YAML Loader | 1 day |
| 03 | Fault Catalog GraphQL Schema + Resolvers | 1 day |

### Phase 1: Experiment Definition — Schema & CRUD (Stages 4–6)

Defines the `ExperimentDefinition` Go type, MongoDB collection, GraphQL schema, CRUD mutations,
and the app–fault compatibility resolver.

| Stage | Name | Estimated Effort |
|-------|------|-----------------|
| 04 | ExperimentDefinition Go Types + MongoDB Collection | 1 day |
| 05 | Experiment Definition GraphQL Schema + CRUD | 1 day |
| 06 | App–Fault Compatibility Resolver | 0.5 day |

### Phase 2: Experiment Execution (Stages 7–9)

Implements the Argo Workflow hydrator, extended run tracking, and the `submitRun`/`abortRun`
mutations that tie the whole execution pipeline together.

| Stage | Name | Estimated Effort |
|-------|------|-----------------|
| 07 | Argo Workflow Hydrator (`pkg/experiment_hydrator/`) | 2 days |
| 08 | Extended ExperimentRun Tracking | 1 day |
| 09 | `submitRun` + `abortRun` Mutations | 1.5 days |

### Phase 3: Chaos Studio (Stages 10–12)

Builds the four-screen Chaos Studio UX: Select App, Select Agent, Build Fault Sequence (canvas),
and Configure & Run.

| Stage | Name | Estimated Effort |
|-------|------|-----------------|
| 10 | Chaos Studio — Screen 1 (Select App) + Screen 2 (Select Agent) | 1.5 days |
| 11 | Chaos Studio — Screen 3 (Canvas / Fault Sequence Builder) | 2 days |
| 12 | Chaos Studio — Screen 4 (Configure & Run) + `submitRun` wiring | 1.5 days |

**Total estimated effort:** ~14 developer-days across one or two engineers.

---

## Stage Dependencies

```
Stage 01 (catalog dirs + fault.yamls)
  └─► Stage 02 (loader reads the yamls)
        └─► Stage 03 (GraphQL queries hit the loader)
              └─► Stage 06 (compatibility resolver extends loader)
                    └─► Stage 10 (Select App screen calls faultsForApp)
                          └─► Stage 11 (canvas uses fault library from faultsForApp)
                                └─► Stage 12 (Configure & Run)

Stage 04 (ExperimentDefinition types + MongoDB)
  └─► Stage 05 (GraphQL CRUD mutations use the types)
        └─► Stage 07 (hydrator reads ExperimentDefinition)
              └─► Stage 09 (submitRun calls hydrator)
                    └─► Stage 12 (wires submitRun mutation)

Stage 08 (extended run tracking)
  └─► Stage 09 (submitRun writes the extended run record)
```

---

## Critical Success Factors

1. **Never modify `chaos_experiment.graphqls`** — the existing `Experiment` and `ExperimentRun` types
   must remain untouched. New types live in `experiment_definition.graphqls` and
   `experiment_run_ext.graphqls`.
2. **Loader must be path-agnostic** — `catalog/` path is configured via env var
   `ACE_CATALOG_ROOT` so it works in both dev (local checkout) and in-cluster (mounted ConfigMap).
3. **Hydration is pure** — the `Hydrate()` function must be side-effect-free (no K8s calls); it
   returns a YAML string. Kubernetes API calls happen in the `submitRun` resolver.
4. **Run records are immutable** — after a run reaches COMPLETED, FAILED, or ABORTED, its MongoDB
   document is never updated again. Status transitions are append-only via `$push` to a
   `statusHistory[]` array.
5. **Fault parameters are typed at hydration** — parameter values are validated against
   `min`/`max`/`type` before rendering into ChaosEngine YAML to prevent raw YAML injection.

---

## Quick Reference Commands

```bash
# Validate a fault.yaml
ace fault validate catalog/faults/general/pod-delete/fault.yaml

# Load the fault catalog manually (development)
go run ./cmd/graphql-server --catalog-root=./catalog --log-level=debug 2>&1 | grep "fault_catalog"

# List faults via GraphQL (after Stage 03)
curl -s -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "{ listFaults { name scope domain } }"}' | jq .

# Create an experiment definition (after Stage 05)
curl -s -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "mutation { createExperiment(input: {name: \"test\", targetApp: {name: \"sock-shop\", version: \">=1.0.0\"}}) { name } }"}' | jq .

# Submit a run (after Stage 09)
curl -s -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "mutation { submitRun(experimentName: \"test\", agentName: \"flash-agent\") { id status } }"}' | jq .

# Check all experiment_runs in MongoDB
mongosh mongodb://localhost:27017/litmus --eval \
  'db.experiment_runs.find({}, {id:1, status:1, definitionName:1, agentName:1}).pretty()'
```

---

## Risk Management

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| `chaos_experiment.graphqls` type name collision with new types | Medium | High | Prefix all new types with `Ace` (e.g., `AceExperimentDefinition`) if a name clash is detected. Run `gqlgen generate` and check for duplicate type errors after each new `.graphqls` file is added. |
| Catalog YAML path not mounted in cluster | Medium | High | `ACE_CATALOG_ROOT` env var; fall back to bundling `catalog/` as a Docker layer for the graphql-server image. |
| Argo Workflow hydration produces invalid YAML | Medium | Medium | Add a `HydrateAndValidate()` wrapper that runs `yaml.Unmarshal` on the output before returning — fails fast in unit tests. |
| MongoDB collection name conflicts | Low | Medium | New collections use prefixed names: `experiment_definitions`, `experiment_runs_ext`. Never reuse existing collection names. |
| Frontend drag-and-drop canvas performance with many fault nodes | Low | Medium | Cap max steps at 20 per experiment. Render canvas as SVG, not DOM tree. Use React.memo on step nodes. |
