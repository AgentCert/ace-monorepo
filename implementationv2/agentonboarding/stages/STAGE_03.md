# Stage 3: Model Library Backend

**Phase:** 2 — Model Library  
**Dependencies:** Stage 2 complete  
**Risk Level:** High — integrates with LiteLLM HTTP API and K8s client-go

---

## Objectives

1. Add Model Library GraphQL types and mutations/queries to the schema
2. Create the `model_library` MongoDB package (schema + operations)
3. Create `pkg/model_library/` service (CreateModelConfig, TestModelConfig, etc.)
4. Integrate with LiteLLM's `/config/add_model` API
5. Create and delete K8s Secrets for API keys in `litmus` namespace

---

## Current State Analysis

### What We Have
- No model library code exists anywhere
- LiteLLM is running in the cluster (see `agent-charts/litellm/`)
- `client-go` is already a dependency (used in `pkg/agent_registry/service.go` for K8s namespaces)
- `pkg/database/mongodb/` pattern established by other packages

### What We Need
- New GraphQL types: `ModelConfig`, `ModelConfigInput`, `ModelConfigResult`, `ModelConfigTestResult`
- New mutations: `createModelConfig`, `updateModelConfig`, `deleteModelConfig`, `testModelConfig`
- New queries: `listModelConfigs`, `getModelConfig`
- `pkg/database/mongodb/model_library/` package
- `pkg/model_library/` service package
- K8s Secret name pattern: `ace-model-<alias>-<projectID>` in `litmus` namespace

---

## Pre-Stage Verification

```bash
# Confirm LiteLLM is accessible
kubectl get svc -n litmus -l app=litellm 2>/dev/null || echo "Check LiteLLM namespace/label"

# Confirm client-go is in go.mod
grep "k8s.io/client-go" AgentCert/chaoscenter/graphql/server/go.mod
```

---

## Implementation Tasks

### Task 1: Extend GraphQL Schema with Model Library Types

**File to Modify:** `graphql/definitions/shared/agent_registry.graphqls`

**Add new types:**

```graphql
"""
ModelConfig represents a saved LLM model configuration in the Model Library.
API keys are write-only and never returned via GraphQL.
"""
type ModelConfig {
  alias:           String!        # User-chosen alias, e.g. "my-openai-gpt4o"
  provider:        String!        # openai|anthropic|google|azure|ollama|custom
  model:           String!
  baseURL:         String
  secretRef:       String!        # K8s Secret name; never contains the key value
  agentsUsing:     [String!]!     # Agent names referencing this config
  status:          String!        # active|error|untested
  lastTested:      String         # ISO timestamp
}

input ModelConfigInput {
  alias:    String!
  provider: String!
  model:    String!
  baseURL:  String
  apiKey:   String!               # Write-only; stored in K8s Secret
}

type ModelConfigResult {
  config:  ModelConfig!
  message: String!
}

type ModelConfigTestResult {
  success:      Boolean!
  latencyMs:    Int
  errorMessage: String
}

extend type Query {
  listModelConfigs(projectID: ID!): [ModelConfig!]!
  getModelConfig(projectID: ID!, alias: String!): ModelConfig
}

extend type Mutation {
  createModelConfig(projectID: ID!, input: ModelConfigInput!): ModelConfigResult!
  updateModelConfig(projectID: ID!, alias: String!, input: ModelConfigInput!): ModelConfig!
  deleteModelConfig(projectID: ID!, alias: String!): Boolean!
  testModelConfig(input: ModelConfigInput!): ModelConfigTestResult!
  rotateModelConfigKey(projectID: ID!, alias: String!, newApiKey: String!): ModelConfig!
}
```

Run `go generate ./...` after this change.

---

### Task 2: Create `pkg/database/mongodb/model_library/` Package

**Files to Create:**
- `AgentCert/chaoscenter/graphql/server/pkg/database/mongodb/model_library/schema.go`
- `AgentCert/chaoscenter/graphql/server/pkg/database/mongodb/model_library/operations.go`

**schema.go:**

```go
package model_library_db

import "go.mongodb.org/mongo-driver/bson/primitive"

const CollectionName = "model_library_collection"

type ModelConfigDocument struct {
    ID              primitive.ObjectID `bson:"_id"`
    ProjectID       string             `bson:"projectID"`
    Alias           string             `bson:"alias"`
    Provider        string             `bson:"provider"`
    Model           string             `bson:"model"`
    BaseURL         *string            `bson:"baseURL,omitempty"`
    SecretRef       string             `bson:"secretRef"`       // ace-model-<alias>-<projectID>
    LiteLLMDeployID string             `bson:"litellmDeployId"` // internal only
    Status          string             `bson:"status"`
    LastTestedAt    *int64             `bson:"lastTestedAt,omitempty"`
    AgentsUsing     []string           `bson:"agentsUsing"`
    CreatedAt       int64              `bson:"createdAt"`
    UpdatedAt       int64              `bson:"updatedAt"`
}
```

**operations.go** — provide:
- `InsertModelConfig(ctx, doc) error`
- `GetModelConfigByAlias(ctx, projectID, alias) (*ModelConfigDocument, error)`
- `ListModelConfigsByProject(ctx, projectID) ([]ModelConfigDocument, error)`
- `UpdateModelConfig(ctx, projectID, alias string, update bson.D) error`
- `DeleteModelConfig(ctx, projectID, alias string) error`
- `AddAgentReference(ctx, projectID, alias, agentName string) error`
- `RemoveAgentReference(ctx, projectID, alias, agentName string) error`

---

### Task 3: Create `pkg/model_library/` Service Package

**Files to Create:**
- `AgentCert/chaoscenter/graphql/server/pkg/model_library/service.go`
- `AgentCert/chaoscenter/graphql/server/pkg/model_library/litellm_client.go`
- `AgentCert/chaoscenter/graphql/server/pkg/model_library/k8s_secret.go`
- `AgentCert/chaoscenter/graphql/server/pkg/model_library/mapper.go`
- `AgentCert/chaoscenter/graphql/server/pkg/model_library/errors.go`

**service.go — ModelLibraryService interface:**

```go
type ModelLibraryService interface {
    CreateModelConfig(ctx context.Context, projectID string, input CreateModelConfigRequest) (*ModelConfig, error)
    UpdateModelConfig(ctx context.Context, projectID, alias string, input UpdateModelConfigRequest) (*ModelConfig, error)
    DeleteModelConfig(ctx context.Context, projectID, alias string) error
    GetModelConfig(ctx context.Context, projectID, alias string) (*ModelConfig, error)
    ListModelConfigs(ctx context.Context, projectID string) ([]*ModelConfig, error)
    TestModelConfig(ctx context.Context, input TestModelConfigRequest) (*ModelConfigTestResult, error)
    RotateAPIKey(ctx context.Context, projectID, alias, newAPIKey string) (*ModelConfig, error)
    GetLiteLLMUpstreamForAlias(ctx context.Context, projectID, alias string) (string, error)
}
```

**CreateModelConfig flow:**

```
1. Check alias uniqueness for projectID (MongoDB)
2. secretRef = "ace-model-" + sanitize(alias) + "-" + sanitize(projectID)
3. kubectl create/apply Secret in litmus namespace:
   ace-model-<alias>-<projectID> → data.API_KEY = base64(apiKey)
4. POST LiteLLM /config/add_model:
   {
     "model_name": "<alias>",
     "litellm_params": {
       "model": "<provider>/<model>",
       "api_key": "os.environ/ACE_MODEL_<ALIAS>",
       "api_base": "<baseURL or provider default>"
     }
   }
   → returns { "model_id": "<litellmDeployId>" }
5. Insert ModelConfigDocument in MongoDB
6. Return ModelConfig (without apiKey)
```

**litellm_client.go:**

```go
type LiteLLMClient interface {
    AddModel(ctx context.Context, req AddModelRequest) (string, error)   // returns deployID
    UpdateModel(ctx context.Context, deployID string, req AddModelRequest) error
    DeleteModel(ctx context.Context, deployID string) error
    TestCompletion(ctx context.Context, req TestRequest) (*TestResult, error)
}

type AddModelRequest struct {
    ModelName    string
    Provider     string
    Model        string
    APIKeyEnvVar string  // "os.environ/ACE_MODEL_<ALIAS>"
    BaseURL      string
}
```

LiteLLM base URL: read from env `LITELLM_ADMIN_URL` (e.g., `http://litellm.litmus.svc.cluster.local:4000`).
Admin key: read from env `LITELLM_ADMIN_KEY`.

**k8s_secret.go:**

```go
// CreateOrUpdateSecret creates or updates a K8s Secret in the litmus namespace.
// Uses server-side apply (idempotent).
func CreateOrUpdateSecret(ctx context.Context, client kubernetes.Interface, name, namespace string, data map[string][]byte) error

// DeleteSecret deletes a K8s Secret.
func DeleteSecret(ctx context.Context, client kubernetes.Interface, name, namespace string) error
```

---

### Task 4: Add Model Library Resolvers

**File to Create:** `AgentCert/chaoscenter/graphql/server/graph/model_library.resolvers.go`

Wire `createModelConfig`, `updateModelConfig`, `deleteModelConfig`, `testModelConfig`,
`rotateModelConfigKey`, `listModelConfigs`, `getModelConfig` to the ModelLibraryService.

Add `modelLibraryService ModelLibraryService` to the `Resolver` struct in `graph/resolver.go`.

Initialise in `server.go` and inject.

---

## Files to Create (Summary)

```
AgentCert/chaoscenter/graphql/server/pkg/database/mongodb/model_library/
├── schema.go
└── operations.go

AgentCert/chaoscenter/graphql/server/pkg/model_library/
├── service.go
├── litellm_client.go
├── k8s_secret.go
├── mapper.go
└── errors.go

AgentCert/chaoscenter/graphql/server/graph/
└── model_library.resolvers.go
```

## Files to Modify

- `graphql/definitions/shared/agent_registry.graphqls` — add Model Library types
- `graph/resolver.go` — add `modelLibraryService` field
- `AgentCert/chaoscenter/graphql/server/server.go` — initialise ModelLibraryService + inject

---

## Verification Criteria

### Must Pass
- [ ] `go generate ./...` and `go build ./...` succeed
- [ ] `createModelConfig` mutation stores a document in MongoDB with `litellmDeployId` populated
- [ ] K8s Secret `ace-model-test-<projectID>` is created in `litmus` namespace after `createModelConfig`
- [ ] `testModelConfig` mutation returns `success: true` for a valid OpenAI key
- [ ] `deleteModelConfig` deletes both MongoDB record and K8s Secret
- [ ] `getModelConfig` never returns the API key value

### Should Pass
- [ ] `listModelConfigs` returns all configs for a project
- [ ] `agentsUsing` is updated when an agent is registered with a `configRef`

---

## Testing Commands

```bash
cd AgentCert/chaoscenter/graphql/server
go generate ./...
go build ./...
go test ./pkg/model_library/...

# Manual: test createModelConfig via GraphQL playground
# Then verify K8s Secret
kubectl get secret -n litmus -l ace.io/type=model-config
```

---

## Common Issues and Solutions

### Issue 1: LiteLLM API key env var naming
**Symptom:** LiteLLM can't find the API key at runtime  
**Solution:** The env var ACE injects into LiteLLM must match the `os.environ/` reference used in `litellm_params.api_key`. Convention: `ACE_MODEL_<ALIAS_UPPERCASED_UNDERSCORED>`.

### Issue 2: `deleteModelConfig` blocked — agents using it
**Symptom:** User tries to delete a config with `agentsUsing: ["flash-agent"]`  
**Solution:** Return an error: "Cannot delete — agents [flash-agent] are referencing this config." Only allow delete when `agentsUsing` is empty.

---

## Success Criteria

Stage 3 is complete when:
1. Full CRUD for Model Library works via GraphQL
2. K8s Secrets are created/deleted alongside DB records
3. LiteLLM model entry is registered on `createModelConfig`
4. `testModelConfig` makes a live LLM call and returns latency

## Next Stage

Proceed to: **Stage 4: Model Library Frontend**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
