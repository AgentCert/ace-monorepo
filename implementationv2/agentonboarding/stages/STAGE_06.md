# Stage 6: ImportMCPTools + agent.yaml Generation & Storage

**Phase:** 3 — Registration Wizard  
**Dependencies:** Stage 5 complete (registration wizard calls registerAgent mutation)  
**Risk Level:** Low–Medium

---

## Objectives

1. Implement `importMCPTools` mutation backend — HTTP call to MCP server `/tools` endpoint
2. Implement `agent.yaml` generation from registered agent data
3. Store private agents in MongoDB with the full spec-aligned document
4. Optionally: generate a community PR template (stub for now)

---

## Current State Analysis

### What We Have
- `importMCPTools` mutation declared in schema (Stage 1) but not implemented
- `registerAgent` mutation implemented but stores simplified model (no spec fields)
- No agent.yaml generation logic

### What We Need
- Backend implementation of `importMCPTools`
- Backend implementation of `registerAgent` that uses the spec-aligned document structure (Stage 1's extended MongoDB schema)
- A `GenerateAgentYAML` function to produce the `agent.yaml` string from a registered agent
- Storage: private agents in MongoDB, community agents flagged for PR generation

---

## Implementation Tasks

### Task 1: Implement `importMCPTools` Resolver

**Objective:** Hit `GET <serverURL>/tools`, parse tool names.

**File to Modify:** `graph/agent_registry.resolvers.go`

```go
func (r *mutationResolver) ImportMCPTools(ctx context.Context, serverURL string) (*model.MCPImportResult, error) {
    // Validate URL is http/https only (security: prevent SSRF to internal IPs in prod)
    // In dev/kind clusters this is intentionally permissive; enforce via env flag STRICT_URL_VALIDATION
    
    client := &http.Client{Timeout: 10 * time.Second}
    resp, err := client.Get(serverURL + "/tools")
    if err != nil {
        return &model.MCPImportResult{
            Tools:  []string{},
            Errors: []string{fmt.Sprintf("could not reach MCP server: %v", err)},
        }, nil
    }
    defer resp.Body.Close()

    var payload struct {
        Tools []struct {
            Name        string `json:"name"`
            Description string `json:"description"`
        } `json:"tools"`
    }
    if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
        return &model.MCPImportResult{
            Tools:  []string{},
            Errors: []string{fmt.Sprintf("failed to parse MCP response: %v", err)},
        }, nil
    }

    names := make([]string, 0, len(payload.Tools))
    for _, t := range payload.Tools {
        names = append(names, t.Name)
    }
    return &model.MCPImportResult{Tools: names, Errors: []string{}}, nil
}
```

**Verification:**
```bash
# With a local MCP server running on port 8080:
curl -s http://localhost:8080/tools | jq '.tools[].name'
# Call via GraphQL:
mutation { importMCPTools(serverURL: "http://localhost:8080") { tools errors } }
```

---

### Task 2: Update `RegisterAgent` to Use Spec-Aligned MongoDB Schema

**Objective:** The `registerAgent` mutation must now store the full spec document (from Stage 1's `AgentDocument` struct) rather than the simplified model.

**File to Modify:** `pkg/agent_registry/service.go` — `RegisterAgent` method

Changes needed:
1. Map `RegisterAgentRequest` (extended in Stage 1) to `agent_registry_db.AgentDocument`
2. Call `agent_registry_db.InsertAgent(ctx, doc)` instead of the old operator
3. Default `Tier` to `"private"` for all wizard-registered agents
4. Default `SchemaVersion` to `"ace.io/v1"`
5. Auto-populate mandatory `contextInjection[]` if not provided by caller:

```go
// Mandatory context injections (spec §5.6)
defaultContextInjections := []agent_registry_db.ContextInjectDoc{
    {HelmPath: "agent.notifyId",    Source: "{{workflow.name}}", Required: true,
     Description: "Workflow name — agent uses this as the experiment correlation ID"},
    {HelmPath: "agent.workflowUid", Source: "{{workflow.uid}}", Required: true,
     Description: "Workflow UID — certifier uses this to match agent events to runs"},
    {HelmPath: "sidecar.upstream",  Source: "{{workflow.parameters.litellmUpstream}}", Required: true,
     Description: "LiteLLM proxy — routes LLM API calls through ACE for tracing"},
}
// Merge caller-provided contextInjection with defaults (caller additions are appended)
```

6. If `llmConfig.configRef` is set, call `model_library.AddAgentReference(projectID, alias, agentName)` to track usage

---

### Task 3: `GenerateAgentYAML` Function

**Objective:** Produce a `agent.yaml` string from an `AgentDocument`. Used for:
- Displaying the generated YAML in the wizard's Step 7 review
- Community contribution PR generation (future)

**File to Create:** `pkg/agent_registry/yaml_generator.go`

```go
// GenerateAgentYAML produces the canonical agent.yaml string from a registered agent.
// The output matches the spec §5 AgentCatalogEntry schema.
func GenerateAgentYAML(agent *Agent) (string, error) {
    // Build a map matching the agent.yaml structure
    doc := map[string]interface{}{
        "apiVersion": "ace.io/v1",
        "kind":       "AgentCatalogEntry",
        "metadata": map[string]interface{}{
            "name":        agent.Name,
            "displayName": agent.DisplayName,
            "version":     agent.Version,
            "tier":        agent.Tier,
            "owner": map[string]interface{}{
                "name":  agent.Owner.Name,
                "email": agent.Owner.Email,
                "org":   agent.Owner.Org,
            },
            "tags": agent.Tags,
        },
        "spec": map[string]interface{}{
            "description": map[string]interface{}{
                "short":        agent.AgentDescription.Short,
                "long":         agent.AgentDescription.Long,
                "approach":     agent.AgentDescription.Approach,
                "llmDependent": agent.AgentDescription.LLMDependent,
            },
            "install": map[string]interface{}{
                "method":    agent.Install.Method,
                "image":     agent.Install.Image,
                "namespace": agent.Install.Namespace,
                "timeout":   agent.Install.Timeout,
            },
            // llmConfig, inputs, contextInjection, capabilities, requiredTools,
            // evaluationMetrics, compatibility — all mapped similarly
        },
    }
    out, err := yaml.Marshal(doc)
    return string(out), err
}
```

**Expose via a new GraphQL query** (optional — add to schema if desired):

```graphql
extend type Query {
  getAgentYAML(projectID: ID!, agentName: String!): String!
}
```

---

### Task 4: Add `agentYAML` Field to `Agent` GraphQL Type (optional, for review step)

**File to Modify:** `graphql/definitions/shared/agent_registry.graphqls`

```graphql
type Agent {
  # ... existing fields ...
  agentYAML: String   # on-demand generated YAML string (nullable)
}
```

Populate it in `MapAgentToModel` by calling `GenerateAgentYAML`.

---

### Task 5: Community PR Template Generation (stub)

**Objective:** When `registrationMode: "community"` is selected in Step 7, generate a PR template string.

**File to Create:** `pkg/agent_registry/pr_template.go`

```go
// GenerateCommunityPRTemplate returns a Markdown PR description for a community catalog contribution.
func GenerateCommunityPRTemplate(agent *Agent) string {
    return fmt.Sprintf(`## New Community Agent: %s

### Summary
- **Agent Name:** %s
- **Domain:** %s
- **Version:** %s
- **Owner:** %s <%s>

### Agent Description
%s

### Capabilities
%s

### Review Checklist
- [ ] agent.yaml is valid (run \`catalog/validate.sh\`)
- [ ] All capability keys exist in \`catalog/capabilities/\`
- [ ] No hardcoded secrets in values.yaml (if Helm chart provided)
- [ ] Image is publicly pullable
- [ ] Owner has been notified of review requirements
`,
        agent.DisplayName, agent.Name,
        extractDomains(agent.Capabilities),
        agent.Version, agent.Owner.Name, agent.Owner.Email,
        agent.AgentDescription.Long,
        formatCapabilities(agent.Capabilities),
    )
}
```

The `RegisterAgentResponse.prURL` field (from spec §21.3) remains `nil` until the PR automation is built in a future iteration. Return the template as a message instead.

---

## Files to Create (Summary)

```
AgentCert/chaoscenter/graphql/server/pkg/agent_registry/
├── yaml_generator.go
└── pr_template.go
```

## Files to Modify

- `graph/agent_registry.resolvers.go` — implement `ImportMCPTools`
- `pkg/agent_registry/service.go` — update `RegisterAgent` to use spec schema
- `graphql/definitions/shared/agent_registry.graphqls` — add `agentYAML` field (optional), `getAgentYAML` query (optional)

---

## Verification Criteria

### Must Pass
- [ ] `importMCPTools("http://localhost:8080")` returns tool names or a graceful error message
- [ ] `registerAgent` stores the full spec document in MongoDB (check with `mongosh`)
- [ ] `getAgent` returns `install`, `llmConfig`, `inputs`, `contextInjection`, `requiredTools`, `capabilities` populated
- [ ] `GenerateAgentYAML` produces valid YAML with `apiVersion: ace.io/v1`

### Should Pass
- [ ] Community registration mode returns a PR template in the response message
- [ ] `agentYAML` field on `Agent` returns the agent.yaml string

---

## Testing Commands

```bash
cd AgentCert/chaoscenter/graphql/server
go test ./pkg/agent_registry/... -run TestGenerateAgentYAML

# Manual: register an agent, then query it and check all fields
# Manual: call importMCPTools with a mock MCP server
python3 -c "
import json, http.server, threading

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps({'tools': [
            {'name': 'Execute PromQL Query', 'description': 'Run PromQL'},
            {'name': 'Pods: List in Namespace', 'description': 'List pods'},
        ]}).encode())

s = http.server.HTTPServer(('', 8877), H)
print('MCP mock on :8877')
s.serve_forever()
"
# Then call: mutation { importMCPTools(serverURL: "http://localhost:8877") { tools } }
```

---

## Success Criteria

Stage 6 is complete when:
1. `importMCPTools` returns tool names from a real or mock MCP server
2. `registerAgent` stores the full spec-aligned document in MongoDB
3. `getAgent` returns the complete spec-aligned agent object
4. Generated `agent.yaml` passes `catalog/validate.sh`

## Next Stage

Proceed to: **Stage 7: Secret Handling**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
