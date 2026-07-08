# Stage 1: Extend Agent GraphQL Schema & MongoDB Model

**Phase:** 1 — Spec-Aligned Backend Model  
**Dependencies:** None (this is the foundation)  
**Risk Level:** Medium — changes to generated models affect all existing resolvers

---

## Objectives

1. Align `agent_registry.graphqls` with the spec's full `AgentSpec` type (§5 of spec)
2. Add the MongoDB BSON struct that mirrors the new GraphQL types
3. Update the mapper functions so existing resolvers still compile
4. Run `go generate` to regenerate `models_gen.go` without breaking existing code

---

## Current State Analysis

### What We Have
- `graphql/definitions/shared/agent_registry.graphqls` — simplified schema (no `llmConfig`, `inputs[]`, `contextInjection[]`, `requiredTools[]`, `evaluationMetrics[]`, `compatibility`)
- `pkg/agent_registry/service.go` — `Agent` struct uses `Capabilities []string`, `ContainerImage`, `Endpoint` (Helm-deploy model)
- `graph/model/models_gen.go` — generated from the current schema; will be regenerated

### What We Need
- Extended GraphQL schema matching spec §5
- New Go types: `AgentInput`, `ContextInjection`, `RequiredTool`, `AgentCompatibility`, `LLMConfig`, `AgentOwner`
- Extended `Agent` internal struct in service layer
- MongoDB BSON document struct matching the new model
- Updated mapper functions (`MapAgentToModel`, `MapRegisterAgentInputToRequest`)

---

## Pre-Stage Verification

```bash
# Confirm current schema location
ls AgentCert/chaoscenter/graphql/definitions/shared/agent_registry.graphqls

# Confirm go generate works today (baseline)
cd AgentCert/chaoscenter/graphql/server && go generate ./...

# Check existing tests pass
cd AgentCert/chaoscenter/graphql/server && go test ./pkg/agent_registry/...
```

---

## Implementation Tasks

### Task 1: Extend `agent_registry.graphqls`

**Objective:** Add all spec §5 types. Keep existing types intact; extend them.

**File to Modify:**
- `AgentCert/chaoscenter/graphql/definitions/shared/agent_registry.graphqls`

**Changes — add new types after existing `Agent` type:**

```graphql
# --- Spec §5.3 description sub-object ---
type AgentDescription {
  short:        String!
  long:         String!
  approach:     String       # react-loop | plan-and-execute | chain-of-thought | rule-based | custom
  llmDependent: Boolean!
}

input AgentDescriptionInput {
  short:        String!
  long:         String!
  approach:     String
  llmDependent: Boolean
}

# --- Spec §5.4 install block ---
type AgentInstallSpec {
  method:       String!       # generic-wrapper | helm | external-helm
  image:        String        # required for generic-wrapper
  folder:       String        # required for helm
  namespace:    String!
  timeout:      String!
  resources:    ResourceSpec!
  replicas:     Int!
}

type ResourceSpec {
  requests: ResourceQuantity!
  limits:   ResourceQuantity!
}

type ResourceQuantity {
  cpu:    String!
  memory: String!
}

input AgentInstallInput {
  method:    String!
  image:     String
  folder:    String
  namespace: String
  timeout:   String
  cpu:       String
  memory:    String
}

# --- Spec §5.5 inputs[] ---
type AgentInput {
  key:         String!
  displayName: String!
  description: String
  type:        String!   # secret | string | integer | boolean | enum
  required:    Boolean!
  default:     String
  placeholder: String
  helmPath:    String!
  values:      [String!]
  min:         Int
  max:         Int
  unit:        String
  advanced:    Boolean!
  group:       String
}

input AgentInputDefinition {
  key:         String!
  displayName: String!
  description: String
  type:        String!
  required:    Boolean
  default:     String
  placeholder: String
  helmPath:    String!
  values:      [String!]
  min:         Int
  max:         Int
  unit:        String
  advanced:    Boolean
  group:       String
}

# --- Spec §5.6 contextInjection[] ---
type ContextInjection {
  helmPath:    String!
  source:      String!      # {{workflow.name}} | {{workflow.uid}} | etc.
  required:    Boolean!
  description: String
}

input ContextInjectionInput {
  helmPath:    String!
  source:      String!
  required:    Boolean
  description: String
}

# --- Spec §5.8 requiredTools[] ---
type RequiredTool {
  name:         String!
  purpose:      String
  critical:     Boolean!
  minCallCount: Int!
  maxCallCount: Int
}

input RequiredToolInput {
  name:         String!
  purpose:      String
  critical:     Boolean
  minCallCount: Int
  maxCallCount: Int
}

# --- Spec §5.10 compatibility block ---
type AgentCompatibility {
  supportedApps:     [String!]!
  unsupportedApps:   [String!]!
  minimumFaultCount: Int!
  maximumFaultCount: Int!
}

input AgentCompatibilityInput {
  supportedApps:     [String!]
  unsupportedApps:   [String!]
  minimumFaultCount: Int
  maximumFaultCount: Int
}

# --- Spec §5.11 llmConfig block ---
type LLMConfig {
  configRef:      String     # alias in Model Library
  provider:       String     # openai|anthropic|google|azure|ollama|custom
  model:          String
  allowUserChoice: Boolean!
  allowedModels:  [String!]!
  defaultModel:   String
  llmDependent:   Boolean!
}

input LLMConfigInput {
  configRef:      String
  provider:       String
  model:          String
  allowUserChoice: Boolean
  allowedModels:  [String!]
  defaultModel:   String
  llmDependent:   Boolean
}

# --- Spec §5.2 metadata block additions ---
type AgentOwner {
  name:  String!
  email: String!
  org:   String
}

input AgentOwnerInput {
  name:  String!
  email: String!
  org:   String
}
```

**Changes — extend the existing `Agent` type** (add fields to the existing type):

```graphql
type Agent {
  # ... existing fields ...
  displayName:       String!
  tier:              String!        # official | community | private
  agentDescription:  AgentDescription!
  install:           AgentInstallSpec!
  llmConfig:         LLMConfig
  inputs:            [AgentInput!]!
  contextInjection:  [ContextInjection!]!
  requiredTools:     [RequiredTool!]!
  evaluationMetrics: [String!]!
  compatibility:     AgentCompatibility!
  owner:             AgentOwner!
  repository:        String
  license:           String
  schemaVersion:     String!
}
```

**Changes — extend `RegisterAgentInput`:**

```graphql
input RegisterAgentInput {
  # ... existing fields ...
  displayName:       String
  description:       AgentDescriptionInput
  install:           AgentInstallInput
  llmConfig:         LLMConfigInput
  inputs:            [AgentInputDefinition!]
  contextInjection:  [ContextInjectionInput!]
  requiredTools:     [RequiredToolInput!]
  evaluationMetrics: [String!]
  compatibility:     AgentCompatibilityInput
  owner:             AgentOwnerInput
  tags:              [String!]
  repository:        String
  license:           String
}
```

**Also add the `ImportMCPTools` mutation** (spec §21.2):

```graphql
type MCPImportResult {
  tools:  [String!]!
  errors: [String!]!
}

extend type Mutation {
  importMCPTools(serverURL: String!): MCPImportResult!
}
```

**Verification:**
```bash
cd AgentCert/chaoscenter/graphql/server && go generate ./...
# Must complete without errors
```

---

### Task 2: Add MongoDB BSON Document Struct

**Objective:** Create the database schema package for agent registry.

**Files to Create:**
- `AgentCert/chaoscenter/graphql/server/pkg/database/mongodb/agent_registry/schema.go`
- `AgentCert/chaoscenter/graphql/server/pkg/database/mongodb/agent_registry/operations.go`

**schema.go:**

```go
package agent_registry_db

import "go.mongodb.org/mongo-driver/bson/primitive"

const CollectionName = "agent_registry_collection"

type AgentDocument struct {
    ID              primitive.ObjectID    `bson:"_id"`
    AgentID         string                `bson:"agentID"`
    ProjectID       string                `bson:"projectID"`
    Tier            string                `bson:"tier"`
    Name            string                `bson:"name"`
    DisplayName     string                `bson:"displayName"`
    Version         string                `bson:"version"`
    Description     AgentDescDoc          `bson:"description"`
    Install         AgentInstallDoc       `bson:"install"`
    LLMConfig       *LLMConfigDoc         `bson:"llmConfig,omitempty"`
    Inputs          []AgentInputDoc       `bson:"inputs"`
    ContextInject   []ContextInjectDoc    `bson:"contextInjection"`
    Capabilities    []string              `bson:"capabilities"`
    RequiredTools   []RequiredToolDoc     `bson:"requiredTools"`
    EvalMetrics     []string              `bson:"evaluationMetrics"`
    Compatibility   AgentCompatDoc        `bson:"compatibility"`
    Owner           AgentOwnerDoc         `bson:"owner"`
    Tags            []string              `bson:"tags"`
    Repository      string                `bson:"repository,omitempty"`
    License         string                `bson:"license,omitempty"`
    IsDeleted       bool                  `bson:"isDeleted"`
    CreatedAt       int64                 `bson:"createdAt"`
    UpdatedAt       int64                 `bson:"updatedAt"`
    SchemaVersion   string                `bson:"schemaVersion"`
}

type AgentDescDoc struct {
    Short       string `bson:"short"`
    Long        string `bson:"long"`
    Approach    string `bson:"approach,omitempty"`
    LLMDependent bool  `bson:"llmDependent"`
}

type AgentInstallDoc struct {
    Method    string `bson:"method"`
    Image     string `bson:"image,omitempty"`
    Folder    string `bson:"folder,omitempty"`
    Namespace string `bson:"namespace"`
    Timeout   string `bson:"timeout"`
    CPUReq    string `bson:"cpuRequest,omitempty"`
    MemReq    string `bson:"memRequest,omitempty"`
    Replicas  int    `bson:"replicas"`
}

type LLMConfigDoc struct {
    ConfigRef       string   `bson:"configRef,omitempty"`
    Provider        string   `bson:"provider,omitempty"`
    Model           string   `bson:"model,omitempty"`
    AllowUserChoice bool     `bson:"allowUserChoice"`
    AllowedModels   []string `bson:"allowedModels"`
    DefaultModel    string   `bson:"defaultModel,omitempty"`
    LLMDependent    bool     `bson:"llmDependent"`
}

type AgentInputDoc struct {
    Key         string   `bson:"key"`
    DisplayName string   `bson:"displayName"`
    Description string   `bson:"description,omitempty"`
    Type        string   `bson:"type"`
    Required    bool     `bson:"required"`
    Default     string   `bson:"default,omitempty"`
    Placeholder string   `bson:"placeholder,omitempty"`
    HelmPath    string   `bson:"helmPath"`
    Values      []string `bson:"values,omitempty"`
    Min         *int     `bson:"min,omitempty"`
    Max         *int     `bson:"max,omitempty"`
    Unit        string   `bson:"unit,omitempty"`
    Advanced    bool     `bson:"advanced"`
    Group       string   `bson:"group,omitempty"`
}

type ContextInjectDoc struct {
    HelmPath    string `bson:"helmPath"`
    Source      string `bson:"source"`
    Required    bool   `bson:"required"`
    Description string `bson:"description,omitempty"`
}

type RequiredToolDoc struct {
    Name         string `bson:"name"`
    Purpose      string `bson:"purpose,omitempty"`
    Critical     bool   `bson:"critical"`
    MinCallCount int    `bson:"minCallCount"`
    MaxCallCount *int   `bson:"maxCallCount,omitempty"`
}

type AgentCompatDoc struct {
    SupportedApps     []string `bson:"supportedApps"`
    UnsupportedApps   []string `bson:"unsupportedApps"`
    MinFaultCount     int      `bson:"minimumFaultCount"`
    MaxFaultCount     int      `bson:"maximumFaultCount"`
}

type AgentOwnerDoc struct {
    Name  string `bson:"name"`
    Email string `bson:"email"`
    Org   string `bson:"org,omitempty"`
}
```

**operations.go** — mirror the pattern from `pkg/database/mongodb/chaos_experiment/operations.go`:
- `InsertAgent(ctx, doc AgentDocument) error`
- `GetAgentByID(ctx, agentID string) (*AgentDocument, error)`
- `GetAgentByProjectAndName(ctx, projectID, name string) (*AgentDocument, error)`
- `ListAgentsByProject(ctx, projectID string, filter AgentFilter, pagination Pagination) ([]AgentDocument, int64, error)`
- `UpdateAgent(ctx, agentID string, update bson.D) error`
- `SoftDeleteAgent(ctx, agentID string) error`

---

### Task 3: Update the Internal Agent Struct and Mapper

**Objective:** Extend the internal `Agent` struct in `service.go` to carry the new spec fields. Update the mapper in `mapper.go` so the new GraphQL fields are populated.

**Files to Modify:**
- `AgentCert/chaoscenter/graphql/server/pkg/agent_registry/service.go`
- `AgentCert/chaoscenter/graphql/server/pkg/agent_registry/mapper.go`

**service.go changes:** Add to the `Agent` struct:

```go
type Agent struct {
    // existing fields ...
    DisplayName       string
    Tier              string            // official | community | private
    AgentDescription  AgentDescription
    Install           AgentInstall
    LLMConfig         *LLMConfig
    Inputs            []AgentInputDef
    ContextInjection  []ContextInject
    RequiredTools     []RequiredTool
    EvalMetrics       []string
    Compatibility     AgentCompat
    Owner             AgentOwner
    Repository        string
    License           string
    Tags              []string
    SchemaVersion     string
}

type AgentDescription struct {
    Short        string
    Long         string
    Approach     string
    LLMDependent bool
}

type AgentInstall struct {
    Method    string
    Image     string
    Folder    string
    Namespace string
    Timeout   string
    CPUReq    string
    MemReq    string
    Replicas  int
}

type LLMConfig struct {
    ConfigRef       string
    Provider        string
    Model           string
    AllowUserChoice bool
    AllowedModels   []string
    DefaultModel    string
    LLMDependent    bool
}

type AgentInputDef struct {
    Key         string
    DisplayName string
    Description string
    Type        string
    Required    bool
    Default     string
    Placeholder string
    HelmPath    string
    Values      []string
    Min         *int
    Max         *int
    Unit        string
    Advanced    bool
    Group       string
}

type ContextInject struct {
    HelmPath    string
    Source      string
    Required    bool
    Description string
}

type RequiredTool struct {
    Name         string
    Purpose      string
    Critical     bool
    MinCallCount int
    MaxCallCount *int
}

type AgentCompat struct {
    SupportedApps     []string
    UnsupportedApps   []string
    MinFaultCount     int
    MaxFaultCount     int
}

type AgentOwner struct {
    Name  string
    Email string
    Org   string
}
```

**mapper.go changes:** Update `MapAgentToModel` to populate the new GraphQL fields from the extended struct.
Update `MapRegisterAgentInputToRequest` to extract the new input fields into `RegisterAgentRequest`.

---

### Task 4: Update `RegisterAgentRequest` and Validator

**Objective:** `RegisterAgentRequest` must carry the spec fields; `ValidateRegistration` must check them.

**Files to Modify:**
- `pkg/agent_registry/service.go` (RegisterAgentRequest struct)
- `pkg/agent_registry/validator.go` (ValidateRegistration)

**RegisterAgentRequest additions:**

```go
type RegisterAgentRequest struct {
    // existing fields ...
    DisplayName       string
    Tier              string
    AgentDescription  *AgentDescription
    Install           *AgentInstall
    LLMConfig         *LLMConfig
    Inputs            []AgentInputDef
    ContextInjection  []ContextInject
    RequiredTools     []RequiredTool
    EvalMetrics       []string
    Compatibility     *AgentCompat
    Owner             *AgentOwner
    Repository        string
    License           string
    Tags              []string
}
```

**Validation additions in `ValidateRegistration`:**
- `install.method` must be one of: `generic-wrapper`, `helm`, `external-helm`
- If `install.method == "generic-wrapper"`: `install.image` must be non-empty
- If `install.method == "helm"`: `install.folder` must be non-empty
- `llmConfig.provider` if set must be one of: `openai`, `anthropic`, `google`, `azure`, `ollama`, `custom`
- `requiredTools[].name` must be non-empty (no further validation at registration time)

---

## Files to Create (Summary)

```
AgentCert/chaoscenter/graphql/server/pkg/database/mongodb/agent_registry/
├── schema.go
└── operations.go
```

## Files to Modify

- `graphql/definitions/shared/agent_registry.graphqls` — extend types
- `pkg/agent_registry/service.go` — extend Agent struct + RegisterAgentRequest
- `pkg/agent_registry/mapper.go` — update MapAgentToModel, MapRegisterAgentInputToRequest
- `pkg/agent_registry/validator.go` — add install method + llmConfig validation

---

## Verification Criteria

### Must Pass
- [ ] `go generate ./...` completes without errors
- [ ] `go build ./...` compiles without errors
- [ ] `go test ./pkg/agent_registry/...` all tests pass
- [ ] `RegisterAgentInput` in GraphQL Playground accepts `llmConfig`, `inputs`, `requiredTools` fields
- [ ] `Agent` type in GraphQL response includes `install`, `compatibility`, `owner` fields

### Should Pass
- [ ] MongoDB document for a new agent stores `llmConfig`, `inputs`, `compatibility` sub-documents

---

## Testing Commands

```bash
# After changes
cd AgentCert/chaoscenter/graphql/server
go generate ./...
go build ./...
go test ./pkg/agent_registry/...
go vet ./...
```

---

## Common Issues and Solutions

### Issue 1: Compile error after `go generate`
**Symptom:** `models_gen.go` refers to types that don't match the internal structs
**Solution:** Check `mapper.go` — add any missing fields; the generated model must be satisfied by the mapper return.

### Issue 2: `extend type` collision in `.graphqls`
**Symptom:** `go generate` fails with "type Agent already defined"  
**Solution:** Do not re-declare `type Agent` — only add fields to the existing declaration. There is one `type Agent` block; extend it in place.

---

## Success Criteria

Stage 1 is complete when:
1. `go generate`, `go build`, `go test` all pass
2. GraphQL playground shows new fields on `Agent` type
3. `RegisterAgentInput` accepts the spec's full field set without error

## Next Stage

Proceed to: **Stage 2: Capabilities Vocabulary**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
