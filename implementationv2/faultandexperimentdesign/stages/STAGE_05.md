# Stage 05: Experiment Definition GraphQL Schema + CRUD

**Phase:** 1 — Experiment Definition  
**Status:** Not Started  
**Estimated Effort:** 1 day  
**Date Added:** 2026-07-07  
**Depends On:** Stage 04 (ExperimentDefinition Go types and MongoDB collection)

---

## Objectives

1. Create `graphql/definitions/shared/experiment_definition.graphqls` with all types and
   CRUD mutations for experiment definitions.
2. Run `gqlgen generate` to produce resolver stubs.
3. Implement the five CRUD resolvers: `createExperiment`, `updateExperiment`, `deleteExperiment`,
   `getExperiment`, `listExperiments`.
4. Wire `experiment_definition.Service` into the resolver.
5. All mutations use the `@authorized` directive.

---

## Current State Analysis

### What Exists
- `graphql/definitions/shared/chaos_experiment.graphqls` — existing `Experiment` type. Do NOT
  touch or reuse. The new `AceExperimentDefinition` type is a different concept.
- `graph/chaos_experiment.resolvers.go` — pattern to follow for CRUD resolver implementation.
- Auth middleware wired via `@authorized` directive throughout existing schema files.

### Key Naming Constraint

The existing `chaos_experiment.graphqls` declares a type named `Experiment`. To avoid a GraphQL
type collision, the new top-level type is named `AceExperimentDefinition`. The new mutation
names `createExperiment`, `updateExperiment`, `deleteExperiment` do NOT collide because they
are added to the existing `Mutation` type via `extend type Mutation`.

---

## Pre-Stage Verification

```bash
# 1. Stage 04 builds
go build ./pkg/experiment_definition/...

# 2. Confirm no type name "AceExperimentDefinition" already in schema
grep -r "AceExperimentDefinition" AgentCert/chaoscenter/graphql/definitions/ 2>/dev/null

# 3. Confirm existing Experiment type name to avoid collision
grep "^type Experiment " AgentCert/chaoscenter/graphql/definitions/shared/chaos_experiment.graphqls
```

---

## Implementation Tasks

### Task 1: Create `graphql/definitions/shared/experiment_definition.graphqls`

```graphql
"""
How ACE selects the LLM model for a run of this experiment.
"""
enum ModelSelectionMode {
  """Use the model configured in the agent's saved Model Library config (default)."""
  AGENT_DEFAULT
  """Always use the model specified in fixedModel — must be in agent's allowedModels."""
  FIXED
  """Show a model picker in the Run dialog — user selects at run time."""
  USER_CHOOSES_AT_RUN
}

"""
Type of a step in the experiment step sequence.
"""
enum StepType {
  """Quiet observation window with no fault injection."""
  OBSERVE
  """Single fault injection (create ChaosEngine, wait, delete)."""
  FAULT
  """HTTP health probe against the app — fails run if non-2xx."""
  VERIFY
  """Pause for a fixed duration."""
  WAIT
  """Multiple faults injected simultaneously."""
  PARALLEL_FAULT
}

"""
Status of an experiment definition.
"""
enum ExperimentDefinitionStatus {
  """Being built in Chaos Studio — not yet committed."""
  DRAFT
  """Saved and valid — ready to create runs."""
  READY
}

"""
Identifies the target microservice within the app.
"""
type StepTarget {
  microservice: String!
  explicitPodName: String
}

"""
HTTP health probe for a verify step.
"""
type StepProbe {
  url: String!
  expectedStatus: Int!
  timeoutSecs: Int
  retries: Int
}

"""
Per-step override of the fault's default detection/mitigation SLAs.
"""
type GroundTruthOverride {
  detectWithinSecs: Int
  mitigateWithinSecs: Int
}

"""
One fault entry within a parallel-fault step.
"""
type ParallelFaultEntry {
  faultRef: String!
  target: StepTarget!
  params: [KeyValuePair!]
}

"""
A single step in the experiment sequence.
"""
type AceExperimentStep {
  name: String!
  type: StepType!
  description: String

  """Duration string for observe/wait steps (e.g. '30s', '2m')."""
  duration: String

  """Reference to a fault in the catalog (for fault steps)."""
  faultRef: String
  target: StepTarget
  params: [KeyValuePair!]
  dependsOn: String
  groundTruthOverride: GroundTruthOverride

  """HTTP probe configuration (for verify steps)."""
  probe: StepProbe

  """Faults to inject simultaneously (for parallel-fault steps)."""
  faults: [ParallelFaultEntry!]
}

"""
Success criteria for a single fault step.
"""
type PerStepCriteria {
  stepName: String!
  detectWithinSecs: Int!
  mitigateWithinSecs: Int!
}

"""
Experiment-level success thresholds applied across all steps.
"""
type OverallCriteria {
  toolCallEfficiencyMin: Float!
  falsePositiveRateMax: Float!
  rootCauseAccuracyMin: Float!
}

"""
Success criteria block for an experiment definition.
"""
type AceSuccessCriteria {
  perStep: [PerStepCriteria!]
  overall: OverallCriteria
}

"""
Agent compatibility constraints for this experiment.
"""
type AgentConstraints {
  requiredCapabilities: [String!]
  supportedAgents: [String!]
  blockedAgents: [String!]
}

"""
Model selection configuration for this experiment.
"""
type AceModelSelection {
  mode: ModelSelectionMode!
  fixedModel: String
}

"""
The app targeted by this experiment.
"""
type AceTargetApp {
  name: String!
  version: String!
  installParams: [KeyValuePair!]
}

"""
An ACE experiment definition — a reusable blueprint for running an
AI agent under controlled fault injection. NOT the same as the existing
Argo-manifest-based Experiment type.
"""
type AceExperimentDefinition {
  name: String!
  displayName: String
  version: String!
  hypothesis: String
  tags: [String!]
  status: ExperimentDefinitionStatus!
  createdAt: String!
  updatedAt: String!
  createdBy: String!

  targetApp: AceTargetApp!
  agentConstraints: AgentConstraints
  modelSelection: AceModelSelection!
  steps: [AceExperimentStep!]!
  successCriteria: AceSuccessCriteria
  evaluationMetrics: [String!]
}

"""
Input for creating a step target.
"""
input StepTargetInput {
  microservice: String!
  explicitPodName: String
}

"""
Input for a parallel fault entry.
"""
input ParallelFaultEntryInput {
  faultRef: String!
  target: StepTargetInput!
  params: [KeyValuePairInput!]
}

"""
Input for a ground truth override.
"""
input GroundTruthOverrideInput {
  detectWithinSecs: Int
  mitigateWithinSecs: Int
}

"""
Input for a health probe.
"""
input StepProbeInput {
  url: String!
  expectedStatus: Int!
  timeoutSecs: Int
  retries: Int
}

"""
Input for a single experiment step.
"""
input AceExperimentStepInput {
  name: String!
  type: StepType!
  description: String
  duration: String
  faultRef: String
  target: StepTargetInput
  params: [KeyValuePairInput!]
  dependsOn: String
  groundTruthOverride: GroundTruthOverrideInput
  probe: StepProbeInput
  faults: [ParallelFaultEntryInput!]
}

"""
Input for per-step success criteria.
"""
input PerStepCriteriaInput {
  stepName: String!
  detectWithinSecs: Int!
  mitigateWithinSecs: Int!
}

"""
Input for overall success criteria.
"""
input OverallCriteriaInput {
  toolCallEfficiencyMin: Float!
  falsePositiveRateMax: Float!
  rootCauseAccuracyMin: Float!
}

"""
Input for the success criteria block.
"""
input AceSuccessCriteriaInput {
  perStep: [PerStepCriteriaInput!]
  overall: OverallCriteriaInput
}

"""
Input for the target app spec.
"""
input AceTargetAppInput {
  name: String!
  version: String!
  installParams: [KeyValuePairInput!]
}

"""
Input for model selection.
"""
input AceModelSelectionInput {
  mode: ModelSelectionMode!
  fixedModel: String
}

"""
Input for agent constraints.
"""
input AgentConstraintsInput {
  requiredCapabilities: [String!]
  supportedAgents: [String!]
  blockedAgents: [String!]
}

"""
Input for creating or updating an experiment definition.
"""
input AceExperimentInput {
  name: String!
  displayName: String
  hypothesis: String
  tags: [String!]
  targetApp: AceTargetAppInput!
  agentConstraints: AgentConstraintsInput
  modelSelection: AceModelSelectionInput!
  steps: [AceExperimentStepInput!]!
  successCriteria: AceSuccessCriteriaInput
  evaluationMetrics: [String!]
}

"""
Filter for listing experiment definitions.
"""
input AceExperimentListFilter {
  targetApp: String
  tags: [String!]
  status: ExperimentDefinitionStatus
}

extend type Mutation {
  """
  Create a new experiment definition. Returns the saved definition.
  """
  createExperiment(
    projectID: ID!
    input: AceExperimentInput!
  ): AceExperimentDefinition! @authorized

  """
  Update an existing experiment definition by name.
  Increments the version. Returns the updated definition.
  """
  updateExperiment(
    projectID: ID!
    name: String!
    input: AceExperimentInput!
  ): AceExperimentDefinition! @authorized

  """
  Delete an experiment definition by name.
  Fails if active runs exist for this definition.
  """
  deleteExperiment(
    projectID: ID!
    name: String!
  ): Boolean! @authorized
}

extend type Query {
  """
  Retrieve an experiment definition by name within a project.
  """
  getExperiment(projectID: ID!, name: String!): AceExperimentDefinition @authorized

  """
  List all experiment definitions in a project, with optional filtering.
  """
  listExperiments(
    projectID: ID!
    filter: AceExperimentListFilter
  ): [AceExperimentDefinition!]! @authorized
}
```

### Task 2: Handle `KeyValuePair` Type

The schema uses `KeyValuePair` and `KeyValuePairInput`. Check if these are already defined in
`common.graphqls`:

```bash
grep -n "KeyValuePair" AgentCert/chaoscenter/graphql/definitions/shared/common.graphqls
```

If not defined, add to `common.graphqls`:
```graphql
type KeyValuePair {
  key: String!
  value: String!
}
input KeyValuePairInput {
  key: String!
  value: String!
}
```

### Task 3: Run `gqlgen generate`

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server
go run github.com/99designs/gqlgen generate
go build ./...
```

### Task 4: Implement `graph/experiment_definition.resolvers.go`

```go
package graph

// CreateExperiment creates a new experiment definition.
func (r *mutationResolver) CreateExperiment(
    ctx context.Context,
    projectID string,
    input model.AceExperimentInput,
) (*model.AceExperimentDefinition, error) {
    doc := experimentInputToDoc(input)
    doc.ProjectID = projectID
    doc.CreatedBy = getUsername(ctx)

    if err := r.ExperimentDefinitionService.Create(ctx, projectID, doc); err != nil {
        return nil, err
    }
    return experimentDocToGraphQL(doc), nil
}

// UpdateExperiment updates an existing experiment definition.
func (r *mutationResolver) UpdateExperiment(
    ctx context.Context,
    projectID string,
    name string,
    input model.AceExperimentInput,
) (*model.AceExperimentDefinition, error) {
    existing, err := r.ExperimentDefinitionService.GetByName(ctx, projectID, name)
    if err != nil {
        return nil, err
    }
    updated := experimentInputToDoc(input)
    updated.ID = existing.ID
    updated.ProjectID = projectID
    updated.CreatedAt = existing.CreatedAt
    updated.CreatedBy = existing.CreatedBy
    updated.Version = bumpVersion(existing.Version)

    if err := r.ExperimentDefinitionService.Update(ctx, projectID, name, updated); err != nil {
        return nil, err
    }
    return experimentDocToGraphQL(updated), nil
}

// DeleteExperiment deletes an experiment definition.
func (r *mutationResolver) DeleteExperiment(
    ctx context.Context,
    projectID string,
    name string,
) (bool, error) {
    if err := r.ExperimentDefinitionService.Delete(ctx, projectID, name); err != nil {
        return false, err
    }
    return true, nil
}

// GetExperiment retrieves a single experiment definition by name.
func (r *queryResolver) GetExperiment(
    ctx context.Context,
    projectID string,
    name string,
) (*model.AceExperimentDefinition, error) {
    doc, err := r.ExperimentDefinitionService.GetByName(ctx, projectID, name)
    if err != nil {
        if _, ok := err.(experiment_definition.ErrExperimentNotFound); ok {
            return nil, nil // GraphQL nullable
        }
        return nil, err
    }
    return experimentDocToGraphQL(doc), nil
}

// ListExperiments lists experiment definitions in a project.
func (r *queryResolver) ListExperiments(
    ctx context.Context,
    projectID string,
    filter *model.AceExperimentListFilter,
) ([]*model.AceExperimentDefinition, error) {
    f := experiment_definition.ListFilter{}
    if filter != nil {
        if filter.TargetApp != nil {
            f.TargetApp = *filter.TargetApp
        }
    }
    docs, err := r.ExperimentDefinitionService.List(ctx, projectID, f)
    if err != nil {
        return nil, err
    }
    return experimentDocsToGraphQL(docs), nil
}
```

Create `graph/experiment_definition_converters.go` with:
- `experimentInputToDoc(input model.AceExperimentInput) *experiment_definition.ExperimentDefinitionDoc`
- `experimentDocToGraphQL(doc *experiment_definition.ExperimentDefinitionDoc) *model.AceExperimentDefinition`
- `experimentDocsToGraphQL(docs []*experiment_definition.ExperimentDefinitionDoc) []*model.AceExperimentDefinition`
- `bumpVersion(v string) string` — increments the patch version (e.g., "1.0.0" → "1.0.1")

---

## Verification Criteria

### Must Pass

1. `gqlgen generate` exits 0 without type collisions.

2. `go build ./...` succeeds.

3. `createExperiment` mutation creates a definition in MongoDB:
   ```bash
   curl -s -X POST http://localhost:8080/query \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{
       "query": "mutation { createExperiment(projectID: \"proj1\", input: {
         name: \"test-exp\",
         targetApp: {name: \"sock-shop\", version: \">=1.0.0\"},
         modelSelection: {mode: AGENT_DEFAULT},
         steps: [{name: \"baseline\", type: OBSERVE, duration: \"30s\"}]
       }) { name version status } }"
     }' | jq .data.createExperiment
   ```

4. `getExperiment` returns the just-created definition.

5. `deleteExperiment` returns `true` and the definition is gone from `getExperiment`.

### Should Pass

6. Creating with an unknown `faultRef` returns a GraphQL error mentioning the unknown fault name.

7. `listExperiments` with `filter: {targetApp: "sock-shop"}` returns only sock-shop experiments.

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server
go test ./graph/... -run TestExperimentDefinition -v
go test ./pkg/experiment_definition/... -v
```

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `KeyValuePair` type redeclared | Already defined in another `.graphqls` file | Remove the duplicate; use the existing type |
| `extend type Mutation` not working | gqlgen requires the base `type Mutation` to be declared somewhere first | Confirm `common.graphqls` or `project.graphqls` declares `type Mutation {}` as the base |
| `@authorized` not applied to generated stubs | gqlgen strips directives during code generation | Directives are enforced at the schema level by the middleware; resolver code doesn't need to re-check |
| Version bump on update fails | `bumpVersion` can't parse the semver string | Use a simple string split/join; handle edge cases like non-semver version strings gracefully |

---

## Rollback Procedure

```bash
rm /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/definitions/shared/experiment_definition.graphqls
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/graph/experiment_definition.resolvers.go
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/graph/experiment_definition_converters.go
mongosh litmus --eval "db.experiment_definitions.drop()"
go run github.com/99designs/gqlgen generate
```

---

## Success Criteria

Stage 05 is complete when:
- `gqlgen generate` and `go build ./...` succeed
- The five CRUD operations work end-to-end via curl
- Unknown `faultRef` in steps returns a meaningful error
- `@authorized` is enforced on all new mutations

**Next Stage:** Stage 06 — App–Fault Compatibility Resolver
