# GraphQL API Reference

**Source:** Spec §19, implementation plan Stages 03, 05, 08, 09  
**Date:** 2026-07-07

This document lists all new GraphQL types, enums, queries, and mutations introduced by the
Faults & Experimentation implementation. It does NOT include existing types from
`chaos_experiment.graphqls`, `chaos_experiment_run.graphqls`, or `fault_studio.graphqls`.

---

## New Schema Files

| File | Stage | Description |
|------|-------|-------------|
| `fault_catalog.graphqls` | 03 | Fault catalog enums, types, and queries |
| `experiment_definition.graphqls` | 05 | Experiment definition types, mutations, queries |
| `experiment_run_ext.graphqls` | 08 | AceExperimentRun type, submitRun/abortRun mutations |

---

## Fault Catalog API (fault_catalog.graphqls)

### Enums

```graphql
enum FaultScope {
  GENERAL       # Applicable to any app
  DOMAIN        # Applicable to any app in a specific domain
  APP_SPECIFIC  # Applicable only to one named app
}

enum FaultImplementationType {
  LITMUS      # Uses a LitmusChaos ChaosEngine
  HTTP_FAULT  # Injects HTTP-level failures
  SCRIPT      # Runs a custom Kubernetes Job
  EXTERNAL    # Calls an external API
}

enum GroundTruthCategory {
  AVAILABILITY
  PERFORMANCE
  SECURITY
  DATA_INTEGRITY
  CONFIGURATION
}

enum CatalogTier {
  OFFICIAL    # Maintained by ACE team
  COMMUNITY   # Community-contributed
}

enum FaultParameterType {
  INTEGER
  STRING
  BOOLEAN
  ENUM
  PERCENT
}
```

### Types

```graphql
type FaultDescription {
  short: String!
  long: String!
  suitableFor: [String!]!
  notSuitableFor: [String!]!
}

type FaultImplementation {
  type: FaultImplementationType!
  chaosKind: String      # For LITMUS type
  experimentRef: String  # For LITMUS type
  namespace: String      # For LITMUS type
  image: String          # For SCRIPT type
  endpoint: String       # For EXTERNAL type
}

type FaultParameter {
  key: String!
  displayName: String!
  type: FaultParameterType!
  unit: String
  default: String!
  min: Int
  max: Int
  required: Boolean!
  description: String!
  litmusEnv: String
  allowedValues: [String!]
}

type FaultCompatibility {
  targetDomains: [String!]!
  incompatibleApps: [String!]!
  requiredCapabilities: [String!]!
}

type FaultObservability {
  expectedSymptoms: [String!]!
  expectedAlerts: [String!]!
  detectionWindowSecs: Int!
}

type FaultGroundTruth {
  category: GroundTruthCategory!
  impact: String!               # "low" | "medium" | "high" | "critical"
  detectWithinSecs: Int!
  mitigateWithinSecs: Int!
  detectionHints: [String!]!
  remediationHints: [String!]!
}

type FaultSpec {
  name: String!
  displayName: String!
  version: String!
  tier: CatalogTier!
  scope: FaultScope!
  domain: String
  targetApp: String
  tags: [String!]!
  filePath: String!
  description: FaultDescription!
  implementation: FaultImplementation!
  parameters: [FaultParameter!]!
  compatibility: FaultCompatibility!
  observability: FaultObservability!
  groundTruth: FaultGroundTruth!
}
```

### Queries

```graphql
extend type Query {
  listFaults(
    scope: FaultScope       # Optional filter by scope
    domain: String          # Optional filter by domain (for DOMAIN scope)
    targetApp: String       # Optional filter by targetApp (for APP_SPECIFIC scope)
  ): [FaultSpec!]! @authorized

  getFault(name: String!): FaultSpec @authorized  # Returns null if not found

  faultsForApp(appName: String!): [FaultSpec!]! @authorized
  # Returns: general + domain-matching + app-specific faults, minus incompatibleApps
  # This is the primary query for Chaos Studio's fault library panel (Screen 3)
}
```

---

## Experiment Definition API (experiment_definition.graphqls)

### Enums

```graphql
enum ModelSelectionMode {
  AGENT_DEFAULT        # Use agent's saved Model Library config
  FIXED                # Always use fixedModel
  USER_CHOOSES_AT_RUN  # Model picker shown in Run dialog
}

enum StepType {
  OBSERVE         # Quiet observation window (no fault)
  FAULT           # Single fault injection
  VERIFY          # HTTP health probe
  WAIT            # Fixed pause duration
  PARALLEL_FAULT  # Multiple simultaneous faults
}

enum ExperimentDefinitionStatus {
  DRAFT   # Being built; not yet runnable
  READY   # Saved and valid; runs can be created
}
```

### Types

```graphql
type StepTarget {
  microservice: String!
  explicitPodName: String
}

type StepProbe {
  url: String!
  expectedStatus: Int!
  timeoutSecs: Int
  retries: Int
}

type GroundTruthOverride {
  detectWithinSecs: Int
  mitigateWithinSecs: Int
}

type ParallelFaultEntry {
  faultRef: String!
  target: StepTarget!
  params: [KeyValuePair!]
}

type AceExperimentStep {
  name: String!
  type: StepType!
  description: String
  duration: String
  faultRef: String
  target: StepTarget
  params: [KeyValuePair!]
  dependsOn: String
  groundTruthOverride: GroundTruthOverride
  probe: StepProbe
  faults: [ParallelFaultEntry!]
}

type PerStepCriteria {
  stepName: String!
  detectWithinSecs: Int!
  mitigateWithinSecs: Int!
}

type OverallCriteria {
  toolCallEfficiencyMin: Float!
  falsePositiveRateMax: Float!
  rootCauseAccuracyMin: Float!
}

type AceSuccessCriteria {
  perStep: [PerStepCriteria!]
  overall: OverallCriteria
}

type AgentConstraints {
  requiredCapabilities: [String!]
  supportedAgents: [String!]
  blockedAgents: [String!]
}

type AceModelSelection {
  mode: ModelSelectionMode!
  fixedModel: String
}

type AceTargetApp {
  name: String!
  version: String!
  installParams: [KeyValuePair!]
}

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
```

### Input Types

```graphql
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

input AceExperimentListFilter {
  targetApp: String
  tags: [String!]
  status: ExperimentDefinitionStatus
}
```

### Mutations

```graphql
extend type Mutation {
  createExperiment(projectID: ID!, input: AceExperimentInput!): AceExperimentDefinition! @authorized
  updateExperiment(projectID: ID!, name: String!, input: AceExperimentInput!): AceExperimentDefinition! @authorized
  deleteExperiment(projectID: ID!, name: String!): Boolean! @authorized
}
```

### Queries

```graphql
extend type Query {
  getExperiment(projectID: ID!, name: String!): AceExperimentDefinition @authorized
  listExperiments(projectID: ID!, filter: AceExperimentListFilter): [AceExperimentDefinition!]! @authorized
}
```

---

## Experiment Run API (experiment_run_ext.graphqls)

### Enums

```graphql
enum AceRunStatus {
  QUEUED     # Argo Workflow submitted; waiting for cluster
  RUNNING    # Argo Workflow actively executing
  COMPLETED  # All steps finished; certifier handed off
  FAILED     # A step failed
  ABORTED    # User stopped or timeout reached
}
```

### Types

```graphql
type RunStatusEvent {
  status: AceRunStatus!
  timestamp: String!
  reason: String
}

type AceExperimentRun {
  runID: String!
  projectID: String!
  definitionName: String!
  definitionVersion: String!
  agentName: String!
  agentVersion: String!
  modelUsed: String!        # Always populated; never null
  modelProvider: String!    # e.g. "openai", "anthropic"
  argoWorkflowName: String!
  langfuseTraceId: String
  certifierReportId: String
  status: AceRunStatus!
  statusHistory: [RunStatusEvent!]!
  startedAt: String
  completedAt: String
  createdAt: String!
  createdBy: String!
}
```

### Input Types

```graphql
input AceSecretInput {
  key: String!
  value: String!
}

input AceParamInput {
  stepName: String!
  key: String!
  value: String!
}
```

### Mutations

```graphql
extend type Mutation {
  submitRun(
    projectID: ID!
    experimentName: String!
    agentName: String!
    modelOverride: String          # Only when agent.llmConfig.allowUserChoice: true
    secretOverrides: [AceSecretInput!]
    paramOverrides: [AceParamInput!]
  ): AceExperimentRun! @authorized

  abortRun(projectID: ID!, runID: String!): AceExperimentRun! @authorized
}
```

### Queries

```graphql
extend type Query {
  getRun(projectID: ID!, runID: String!): AceExperimentRun @authorized
  listRuns(
    projectID: ID!
    experimentName: String
    agentName: String
    status: AceRunStatus
  ): [AceExperimentRun!]! @authorized
}
```

---

## Shared Types (common.graphqls additions if not already present)

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

---

## Error Handling

All mutations and queries follow the standard ACE GraphQL error pattern:
- GraphQL `errors[]` array is populated with a `message` on failure.
- HTTP status is always 200 (errors are in the GraphQL response body).
- `@authorized` directive: unauthenticated or unauthorized requests return error
  `"permission denied: insufficient project access"`.

Common error messages:

| Operation | Error Condition | Error Message |
|-----------|----------------|---------------|
| `getFault("bad-name")` | Fault not in catalog | Returns `null` (no error) |
| `createExperiment` with invalid `faultRef` | `faultRef: "nonexistent"` | `"experiment definition references unknown fault(s): nonexistent"` |
| `submitRun` with `modelOverride` when `allowUserChoice: false` | Model override not allowed | `"agent \"flash-agent\" does not allow model override (allowUserChoice: false)"` |
| `submitRun` experiment not found | Definition name doesn't exist | `"submitRun: experiment not found: \"my-exp\""` |
| `abortRun` on terminal run | Run already COMPLETED | Returns the run as-is (idempotent, no error) |
