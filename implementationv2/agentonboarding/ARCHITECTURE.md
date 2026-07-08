# Agent Onboarding — Architecture

## Executive Summary

Agent onboarding is a multi-layer feature: catalog YAML files on disk, a MongoDB-backed private
registry, a GraphQL API surface, a 7-step registration wizard in the frontend, and a Helm chart
execution path at experiment runtime.

The spec-aligned architecture treats the `agent.yaml` as the source of truth. Private (non-catalog)
agents store the same schema in MongoDB. The Model Library is a separate concern — it manages
LLM credentials and decouples them from the agent spec.

---

## Core Architectural Principles

### 1. Catalog-first, private-second
Official and community agents live in `catalog/agents/<name>/agent.yaml`. Private registrations
store the same structure in MongoDB scoped to a `projectID`. `listAgents` merges both sources.

### 2. Secrets never in Argo YAML
LLM API keys → K8s Secrets in `litmus` namespace.  
Other agent secrets → `ace-agent-secret-<experimentID>` K8s Secret.  
Neither ever appears as a workflow parameter or container arg literal.

### 3. GraphQL schema drives Go code
Schema is in `graphql/definitions/shared/agent_registry.graphqls`. Run `go generate` after every
schema change. Never manually edit `graph/model/models_gen.go`.

### 4. Capabilities from YAML, not code
Capability keys are validated against `catalog/capabilities/*.yaml`. The backend loads these at
startup into an in-memory map. Adding a new capability requires only a YAML file PR.

---

## High-Level Component Diagram

```
┌─────────────────────────────────────────────────────────┐
│  Chaos Studio (React/TypeScript)                         │
│                                                          │
│  ┌──────────────────┐  ┌───────────────────────────┐    │
│  │ Registration      │  │ Model Library Screen       │    │
│  │ Wizard (7 steps)  │  │ (Settings > Model Library) │    │
│  └────────┬─────────┘  └──────────────┬────────────┘    │
│           │ GraphQL mutations          │                  │
└───────────┼────────────────────────────┼─────────────────┘
            │                            │
┌───────────▼────────────────────────────▼─────────────────┐
│  GraphQL Server (Go/gqlgen)                               │
│                                                           │
│  agent_registry.resolvers.go          model_library.resolvers.go
│       │                                     │             │
│  pkg/agent_registry/                  pkg/model_library/  │
│    service.go (business logic)          service.go         │
│    validator.go (caps vocab)            litellm_client.go  │
│    mapper.go (GraphQL ↔ internal)       k8s_secret.go      │
└───────┬────────────────────────────────────┬─────────────┘
        │                                    │
┌───────▼──────────┐              ┌──────────▼────────────┐
│  MongoDB          │              │  Kubernetes (litmus ns)│
│  agent_registry   │              │  Secrets:             │
│  _collection      │              │  ace-model-<alias>-   │
│                   │              │   <projectID>         │
│  model_library    │              │  ace-agent-secret-    │
│  _collection      │              │   <experimentID>      │
└───────────────────┘              └───────────────────────┘
                                            │
                                   ┌────────▼──────────────┐
                                   │  LiteLLM (litmus ns)   │
                                   │  /config/add_model     │
                                   └───────────────────────┘
```

---

## Data Flow Architecture

### Quick Register Flow

```
User fills 7-step wizard
  ↓
registerAgent(projectID, input: RegisterAgentInput!) mutation
  ↓
pkg/agent_registry/service.RegisterAgent()
  ├─ Validate name uniqueness (MongoDB query)
  ├─ Validate capabilities (catalog/capabilities/*.yaml)
  ├─ Validate llmConfig.configRef exists (model_library_collection)
  └─ Insert agent document into agent_registry_collection
  ↓
Return AgentSpec (private, available immediately)
```

### Model Library Save Flow

```
User fills LLM config in Step 3 (or Model Library screen)
  ↓
createModelConfig(projectID, input: ModelConfigInput!) mutation
  ↓
pkg/model_library/service.CreateModelConfig()
  ├─ POST LiteLLM /config/add_model → get litellmDeployId
  ├─ kubectl create secret ace-model-<alias>-<projectID> (API_KEY)
  └─ Insert model_library document
  ↓
Return ModelConfig (alias, provider, model, status)
```

### Experiment Submit + Secret Flow

```
saveChaosExperiment mutation (existing)
  ↓  [new hook]
For each agent input of type: secret:
  kubectl apply ace-agent-secret-<experimentID> -n litmus
  ↓
Argo Workflow submitted with:
  --set agent.secretRef=ace-agent-secret-<experimentID>
  --set agent.notifyId={{workflow.name}}
  --set agent.workflowUid={{workflow.uid}}
  --set sidecar.upstream={{workflow.parameters.litellmUpstream}}
```

---

## MongoDB Document Schemas

### agent_registry_collection

```go
type AgentDocument struct {
    ID              primitive.ObjectID `bson:"_id"`
    AgentID         string             `bson:"agentID"`         // UUID
    ProjectID       string             `bson:"projectID"`
    Tier            string             `bson:"tier"`            // "private"|"community"|"official"
    Name            string             `bson:"name"`            // kebab-case stable key
    DisplayName     string             `bson:"displayName"`
    Version         string             `bson:"version"`         // SemVer
    Description     AgentDescription   `bson:"description"`
    Install         AgentInstall       `bson:"install"`
    LLMConfig       *LLMConfig         `bson:"llmConfig,omitempty"`
    Inputs          []AgentInput       `bson:"inputs"`
    ContextInject   []ContextInject    `bson:"contextInjection"`
    Capabilities    []string           `bson:"capabilities"`
    RequiredTools   []RequiredTool     `bson:"requiredTools"`
    EvalMetrics     []string           `bson:"evaluationMetrics"`
    Compatibility   AgentCompat        `bson:"compatibility"`
    Owner           AgentOwner         `bson:"owner"`
    Tags            []string           `bson:"tags"`
    IsDeleted       bool               `bson:"isDeleted"`
    CreatedAt       int64              `bson:"createdAt"`
    UpdatedAt       int64              `bson:"updatedAt"`
}
```

### model_library_collection

```go
type ModelConfigDocument struct {
    ID              primitive.ObjectID `bson:"_id"`
    ProjectID       string             `bson:"projectID"`
    Alias           string             `bson:"alias"`           // user-chosen, unique per project
    Provider        string             `bson:"provider"`        // openai|anthropic|google|azure|ollama|custom
    Model           string             `bson:"model"`
    BaseURL         *string            `bson:"baseURL,omitempty"`
    SecretRef       string             `bson:"secretRef"`       // ace-model-<alias>-<projectID>
    LiteLLMDeployID string             `bson:"litellmDeployId"` // internal, never exposed
    Status          string             `bson:"status"`          // active|error|untested
    LastTestedAt    *int64             `bson:"lastTestedAt,omitempty"`
    AgentsUsing     []string           `bson:"agentsUsing"`     // agent names referencing this config
    CreatedAt       int64              `bson:"createdAt"`
    UpdatedAt       int64              `bson:"updatedAt"`
}
```

---

## Technology Stack

### Backend
- **Go + gqlgen:** GraphQL schema-first code generation
- **MongoDB:** Agent and model config storage
- **client-go:** K8s Secret CRUD (litmus namespace)
- **LiteLLM HTTP client:** Register/update model configs via LiteLLM REST API
- **gopkg.in/yaml.v3:** Load capabilities vocabulary from YAML files

### Frontend
- **React + TypeScript + Harness UICore:** Wizard steps, form controls
- **Apollo Client (GraphQL):** All API calls
- **react-hook-form or useState:** Multi-step form state

---

## Security

- LLM API keys stored only in K8s Secrets; never returned via GraphQL (write-only on input)
- `isSensitive: true` inputs masked in UI (password field) and logs
- `ace-agent-secret-<experimentID>` scoped to `litmus` namespace
- Model Library Secrets: `ace-model-<alias>-<projectID>` scoped to `litmus` namespace
- Helm chart validation rejects `hostNetwork`, `privileged`, `cluster-admin` ClusterRoleBinding

---

**Version:** 1.0  
**Last Updated:** 2026-07-07
