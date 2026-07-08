# Faults & Experimentation — Technical Architecture

**Date:** 2026-07-07  
**Spec Reference:** `/srv/projects/ace-monorepo/spec/faults-and-experimentation.md`

---

## Core Principles

### 1. Catalog-First

Every fault that can appear in an experiment must have a `fault.yaml` entry in the catalog. The
GraphQL server's fault catalog service reads these YAML files at startup into an in-memory index.
No faults are hard-coded in Go. Adding a new fault requires only a new directory + `fault.yaml`.

### 2. Hydration at Submit Time

An `ExperimentDefinition` is a human-readable YAML blueprint stored in MongoDB. It is not an Argo
Workflow. Conversion to an Argo Workflow YAML happens in the GraphQL server at run-submission time
(the `submitRun` mutation). This keeps the definition stable and makes run parameters dynamic.

### 3. ExperimentDefinition vs ExperimentRun

These are distinct objects with different lifecycles:

- `ExperimentDefinition`: reusable, versioned, stored in MongoDB `experiment_definitions` collection.
  Changes create a new version. Never deleted if runs reference it.
- `ExperimentRun`: one execution instance. Created at submit time. Immutable after reaching a
  terminal state (COMPLETED, FAILED, ABORTED). Stored in MongoDB `experiment_runs_ext`.

The existing `Experiment` and `ExperimentRun` types in `chaos_experiment.graphqls` wrap Argo YAML
manifests and are a completely separate concept. They are not used by this plan.

### 4. Fault Scope Filtering

The fault library shown to a user is always filtered to the selected app's context:
- All `scope: general` faults (universal)
- All `scope: domain` faults where `domain == app.domain`
- All `scope: app-specific` faults where `targetApp == app.name`
- Minus any fault in `fault.compatibility.incompatibleApps[]`

This filtering is done by `fault_catalog.Service.FaultsForApp()` and is the backend for the
`faultsForApp(appName)` GraphQL query. The frontend never manually computes scope.

### 5. Parameter Safety

At hydration time, all parameter values are:
1. Type-checked against the fault's declared `parameters[].type`
2. Bounds-checked against `min` and `max` for numeric types
3. Escaped as typed Helm `--set` arguments — never injected as raw YAML strings

---

## Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Chaos Studio (Frontend)                           │
│  SelectApp.tsx → SelectAgent.tsx → ExperimentCanvas.tsx → ConfigureAndRun  │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │ GraphQL mutations + queries
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     GraphQL Server (Go)                                     │
│                                                                             │
│  ┌──────────────────┐  ┌───────────────────┐  ┌────────────────────────┐  │
│  │  fault_catalog   │  │experiment_defn     │  │   submitRun resolver   │  │
│  │  pkg/            │  │pkg/                │  │   (new resolver file)  │  │
│  │  • loader.go     │  │• model.go          │  │                        │  │
│  │  • service.go    │  │• repository.go     │  │  1. validate defn      │  │
│  │  • model.go      │  │• service.go        │  │  2. resolve agent      │  │
│  └────────┬─────────┘  └─────────┬──────────┘  │  3. call hydrator     │  │
│           │                      │              │  4. create K8s secret │  │
│           │ reads at startup      │ CRUD         │  5. submit Argo WF   │  │
│           ▼                      ▼              │  6. save run record   │  │
│    catalog/faults/          MongoDB              └───────────┬────────────┘  │
│    (YAML files)             experiment_definitions           │               │
│                             experiment_runs_ext              │               │
│                                                              ▼               │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    experiment_hydrator pkg/                          │  │
│  │  Hydrate(def, agent, runID, params) → Argo Workflow YAML string      │  │
│  │  chaosengine_renderer.go → ChaosEngine YAML per fault step           │  │
│  │  dag_builder.go → Argo DAG tasks with dependsOn + parallel-fault     │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │ kubectl apply / Argo submit API
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Kubernetes (kind / production)                       │
│                                                                             │
│  namespace: litmus                                                          │
│  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────────────┐   │
│  │  Argo Workflow   │  │  ChaosEngine CRs │  │  ace-agent-secret-     │   │
│  │  <exp>-<run-id>  │  │  <step>-<run-id> │  │  <run-id>   (Secret)   │   │
│  └──────────────────┘  └──────────────────┘  └────────────────────────┘   │
│                                                                             │
│  namespace: <appName>-<run-id>                                              │
│  ┌──────────────────┐  ┌──────────────────┐                                │
│  │  App Helm Release│  │  Agent Helm       │                                │
│  │  app-<run-id>    │  │  Release          │                                │
│  │                  │  │  agent-<run-id>   │                                │
│  └──────────────────┘  └──────────────────┘                                │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow

### Fault Discovery Flow

```
User opens Chaos Studio → selects "Sock Shop"
  │
  ▼
Frontend calls: faultsForApp(appName: "sock-shop")
  │
  ▼
GraphQL resolver → fault_catalog.Service.FaultsForApp("sock-shop")
  │
  ├─ 1. Load app.yaml from apphub/apps_registry → get domain: "cloud-native"
  │
  ├─ 2. Index lookup: all scope=general faults        (e.g., pod-delete, cpu-hog)
  │
  ├─ 3. Index lookup: all scope=domain, domain="cloud-native"  (e.g., pod-oom-kill)
  │
  ├─ 4. Index lookup: all scope=app-specific, targetApp="sock-shop"  (e.g., carts-db-corrupt)
  │
  ├─ 5. Exclude faults in incompatibleApps[]
  │
  └─ Returns: merged []FaultSpec
```

### Experiment Hydration Flow

```
User clicks "Save & Run" in Screen 4
  │
  ▼
Frontend calls: submitRun(experimentName, agentName, modelOverride?, secretOverrides?)
  │
  ▼
submitRun resolver:
  ├─ 1. experiment_definition.Service.GetByName(experimentName)
  │      → validate all faultRef names resolve in fault catalog
  │
  ├─ 2. agent_registry.GetAgent(agentName)
  │      → validate agent exists + check requiredCapabilities
  │
  ├─ 3. experiment_hydrator.Hydrate(def, agent, runID, params)
  │      → returns Argo Workflow YAML string
  │      → internally calls chaosengine_renderer per fault step
  │      → internally calls dag_builder to wire DAG tasks
  │
  ├─ 4. Create K8s Secret: ace-agent-secret-<runID> in litmus namespace
  │
  ├─ 5. Submit Argo Workflow via ArgoWorkflowsClient (reuse chaos_experiment/ops)
  │
  ├─ 6. Create ExperimentRunDoc in MongoDB experiment_runs_ext
  │      → status: QUEUED, argoWorkflowName, agentName, modelUsed, etc.
  │
  └─ Returns ExperimentRun {id, status: QUEUED, ...}
```

### Run Lifecycle Flow

```
DRAFT (in Chaos Studio, not yet saved)
  │
  ▼ (createExperiment mutation)
READY (ExperimentDefinition saved to MongoDB)
  │
  ▼ (submitRun mutation)
QUEUED (run record created, Argo Workflow submitted)
  │
  ▼ (Argo picks up the Workflow)
RUNNING (Argo Workflow executing steps)
  │
  ├─► COMPLETED (all steps finish, certifier receives Langfuse trace ID)
  ├─► FAILED (app probe fails, fault injection error, verify step fails)
  └─► ABORTED (user calls abortRun, or run exceeds 90-minute timeout)
```

---

## MongoDB Collections

| Collection | Managed By | Description |
|------------|-----------|-------------|
| `experiment_definitions` | Stage 04 | One document per `ExperimentDefinition`. Indexed on `{name, projectID}` unique. |
| `experiment_runs_ext` | Stage 08 | One document per run. Immutable after terminal state. Indexed on `{definitionName, status, agentName}`. |

**Existing collections (do not modify their schemas):**

| Collection | Managed By | Description |
|------------|-----------|-------------|
| `chaosExperiments` | `pkg/chaos_experiment/` | Argo YAML manifest-wrapped experiments |
| `chaosExperimentRuns` | `pkg/chaos_experiment_run/` | Existing run records |
| `agentRegistry` | `pkg/agent_registry/` | Agent onboarding records |
| `appsRegistry` | `pkg/apps_registry/` | App onboarding records |

**Note:** The fault catalog is **in-memory only**. It is rebuilt from YAML files at server startup
and is never stored in MongoDB. This makes catalog updates a server restart (or live-reload via
`SIGHUP`) rather than a database migration.

---

## GraphQL Schema Organization

New schema files added by this plan:

| File | Stage | Purpose |
|------|-------|---------|
| `graphql/definitions/shared/fault_catalog.graphqls` | 03 | `FaultSpec`, `FaultScope`, `FaultImplementationType`, `listFaults`, `getFault`, `faultsForApp` |
| `graphql/definitions/shared/experiment_definition.graphqls` | 05 | `AceExperimentDefinition`, `ExperimentStep`, `StepType`, `SuccessCriteria`, `ModelSelection`, CRUD mutations, `getExperiment`, `listExperiments` |
| `graphql/definitions/shared/experiment_run_ext.graphqls` | 08 | `AceExperimentRun`, `RunStatus`, `submitRun`, `abortRun`, `getRun`, `listRuns` |

Existing files that are NOT modified:
- `chaos_experiment.graphqls` — existing `Experiment` type
- `chaos_experiment_run.graphqls` — existing `ExperimentRun` type
- `fault_studio.graphqls` — fault studio (ChaosHub collections concept)

The `Ace` prefix on new types (`AceExperimentDefinition`, `AceExperimentRun`) is used only if a
name collision is detected during `gqlgen generate`. Otherwise the shorter names
`ExperimentDefinition` and `ExperimentRun` are used in separate schema files with distinct
type names.

---

## Go Package Layout

New packages introduced by this plan:

```
AgentCert/chaoscenter/graphql/server/pkg/
├── fault_catalog/              ← Stage 02
│   ├── model.go                   FaultCatalogEntry struct + sub-structs
│   ├── loader.go                  Startup YAML walk, in-memory index
│   ├── service.go                 ListFaults, GetFault, FaultsForApp
│   └── errors.go                  ErrFaultNotFound, ErrInvalidScope
│
├── experiment_definition/      ← Stage 04
│   ├── model.go                   ExperimentDefinitionDoc, ExperimentStep, etc.
│   ├── repository.go              MongoDB CRUD (experiment_definitions collection)
│   └── service.go                 Business logic, faultRef validation
│
└── experiment_hydrator/        ← Stage 07
    ├── hydrator.go                Hydrate() entry point
    ├── chaosengine_renderer.go    Fault step → ChaosEngine YAML
    └── dag_builder.go             Step list → Argo DAG tasks
```

New resolver files:

```
AgentCert/chaoscenter/graphql/server/graph/
├── fault_catalog.resolvers.go      ← Stage 03
├── experiment_definition.resolvers.go  ← Stage 05
└── experiment_run.resolvers.go     ← Stage 09
```

---

## Frontend Component Layout

```
AgentCert/chaoscenter/web/src/views/ChaosStudio/
├── index.tsx                   ← wizard shell (step router)
├── SelectApp.tsx               ← Screen 1 (Stage 10)
├── SelectAgent.tsx             ← Screen 2 (Stage 10)
├── ExperimentCanvas.tsx        ← Screen 3 canvas (Stage 11)
├── FaultLibraryPanel.tsx       ← Screen 3 left panel (Stage 11)
├── FaultParameterPanel.tsx     ← Screen 3 right panel (Stage 11)
├── ConfigureAndRun.tsx         ← Screen 4 (Stage 12)
└── RunDialog.tsx               ← Run dialog with model picker (Stage 12)
```

New GraphQL queries/mutations used by the frontend:

| Query / Mutation | Used In | Stage |
|-----------------|---------|-------|
| `faultsForApp(appName)` | SelectApp (fault count), ExperimentCanvas (library) | 06, 10, 11 |
| `listAgents` | SelectAgent | 10 |
| `createExperiment` | ConfigureAndRun "Save as Draft" | 12 |
| `submitRun` | ConfigureAndRun "Save & Run" + RunDialog "Start Run" | 12 |
| `abortRun` | Run detail page "Stop" button | 12 |
| `listRuns` | Experiment detail run history | 12 |
