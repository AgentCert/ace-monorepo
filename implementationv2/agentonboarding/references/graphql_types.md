# Target GraphQL Types Reference

Complete GraphQL type definitions that the schema should match after Stage 1 + Stage 3 are complete.
These align with spec §21.3 exactly.

---

## Agent Types

```graphql
type AgentSpec {
  agentID:          ID!
  projectID:        String!
  name:             String!
  displayName:      String!
  version:          String!
  tier:             String!            # official | community | private
  description:      AgentDescription!
  install:          AgentInstallSpec!
  llmConfig:        LLMConfig
  inputs:           [AgentInput!]!
  contextInjection: [ContextInjection!]!
  capabilities:     [String!]!
  requiredTools:    [RequiredTool!]!
  evaluationMetrics: [String!]!
  compatibility:    AgentCompatibility!
  owner:            AgentOwner!
  tags:             [String!]!
  repository:       String
  license:          String
  schemaVersion:    String!
  agentYAML:        String            # on-demand generated agent.yaml string
  status:           AgentStatus!
  auditInfo:        AuditInfo!
}
```

## Model Library Types

```graphql
type ModelConfig {
  alias:       String!
  provider:    String!
  model:       String!
  baseURL:     String
  secretRef:   String!
  agentsUsing: [String!]!
  status:      String!        # active | error | untested
  lastTested:  String
}

input ModelConfigInput {
  alias:    String!
  provider: String!
  model:    String!
  baseURL:  String
  apiKey:   String!           # write-only
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
```

## MCP Import Types

```graphql
type MCPImportResult {
  tools:  [String!]!
  errors: [String!]!
}
```

## Mutations Reference

```graphql
# Agent Registration
registerAgent(projectID: ID!, input: RegisterAgentInput!): RegisterAgentResponse!
updateAgent(agentID: String!, input: UpdateAgentInput!): Agent!
deleteAgent(agentID: String!, hardDelete: Boolean): DeleteAgentResponse!
importMCPTools(serverURL: String!): MCPImportResult!

# Model Library
createModelConfig(projectID: ID!, input: ModelConfigInput!): ModelConfigResult!
updateModelConfig(projectID: ID!, alias: String!, input: ModelConfigInput!): ModelConfig!
deleteModelConfig(projectID: ID!, alias: String!): Boolean!
testModelConfig(input: ModelConfigInput!): ModelConfigTestResult!
rotateModelConfigKey(projectID: ID!, alias: String!, newApiKey: String!): ModelConfig!
```

## Queries Reference

```graphql
# Agent Registry
listAgents(filter: ListAgentsFilter, pagination: PaginationInput!): AgentListResponse!
getAgent(agentID: String!): Agent
getAgentsByCapabilities(projectID: String!, capabilities: [String!]!): [Agent!]!
getAgentCapabilitiesTaxonomy: [CapabilityDefinition!]!
getAgentYAML(projectID: ID!, agentName: String!): String!

# Model Library
listModelConfigs(projectID: ID!): [ModelConfig!]!
getModelConfig(projectID: ID!, alias: String!): ModelConfig
```

---

**Last Updated:** 2026-07-07
