# Test Scenarios — Agent Onboarding

---

## Stage 1: Schema Extension

### Unit Tests
- [ ] `MapRegisterAgentInputToRequest` maps all new fields correctly
- [ ] `MapAgentToModel` returns non-nil `install`, `llmConfig`, `compatibility` fields
- [ ] Validator rejects `install.method = "invalid-method"`

### Integration Tests
- [ ] POST `registerAgent` with full spec input → 200, agent has `requiredTools` in response
- [ ] GET `getAgent` → returns `contextInjection`, `evaluationMetrics`

---

## Stage 2: Capabilities Vocabulary

### Unit Tests
- [ ] `LoadCapabilitiesFromDir("catalog/capabilities")` loads ≥ 40 keys
- [ ] `vocab.IsValid("prometheus-query")` returns `true`
- [ ] `vocab.IsValid("made-up-key")` returns `false`

### Integration Tests
- [ ] Register with `capabilities: ["prometheus-query"]` → succeeds
- [ ] Register with `capabilities: ["made-up-capability"]` → 400 with error message

---

## Stage 3: Model Library Backend

### Unit Tests (mock K8s, mock LiteLLM)
- [ ] `CreateModelConfig` creates MongoDB doc + calls LiteLLM `add_model`
- [ ] `DeleteModelConfig` with `agentsUsing: ["flash-agent"]` returns error
- [ ] `DeleteModelConfig` with empty `agentsUsing` deletes doc + K8s secret
- [ ] `TestModelConfig` with invalid API key returns `success: false` + error message
- [ ] K8s Secret name sanitisation: alias `my-openai/key` → `ace-model-my-openai-key-<projectID>`

### Integration Tests (real LiteLLM in kind cluster)
- [ ] `createModelConfig` mutation → K8s Secret exists in litmus namespace
- [ ] `testModelConfig` with valid OpenAI key → `success: true`, `latencyMs > 0`
- [ ] `rotateModelConfigKey` → K8s Secret updated in-place

---

## Stage 4: Model Library Frontend

### Manual Tests
1. Navigate to Settings > Model Library
2. Click `[+ Add Model]`
3. Select OpenAI, enter gpt-4o, enter a valid API key
4. Click `[Test Connection]` → green ✓ with latency
5. Check `[Save as my-openai-gpt4o]`, click Save
6. Model appears in table with status `✓ Active`
7. Click row to expand → agents: [], last tested timestamp shown
8. Click `[Rotate Key]` → enter new key → test → rotate → no alias/model change

---

## Stage 5: Registration Wizard Frontend

### Manual Tests — Quick Register (Full 7-step flow)
1. Navigate to Agents, click `[Register Agent]`
2. Select "Quick Register"
3. Step 1: fill all required identity fields; check agent name validation (try invalid chars)
4. Step 2: enter `myorg/flash-agent:1.0.0` → no warning. Enter `myorg/flash-agent:latest` → yellow warning
5. Step 3: select saved model from dropdown (from Stage 4)
6. Step 4: add 2 inputs — one `type: secret` (PAGERDUTY_TOKEN), one `type: string` (SCAN_INTERVAL, default 30)
7. Step 5: check `prometheus-query`, `kubernetes-get-pods`. Add MCP tool manually: `Execute PromQL Query`. Select `time_to_detect` and `tool_call_efficiency` metrics.
8. Step 6: select "Compatible with all apps"
9. Step 7: review summary, select "Private", click Register Agent
10. Success toast + redirect to agent list → new agent appears

### Manual Tests — Advanced Register
1. Click `[Register Agent]` → select "Advanced Register"
2. Existing Helm form loads → fill fields → deploy

---

## Stage 6: ImportMCPTools + agent.yaml

### Unit Tests
- [ ] `GenerateAgentYAML` produces valid YAML with `apiVersion: ace.io/v1`
- [ ] `GenerateAgentYAML` includes mandatory contextInjection entries
- [ ] `importMCPTools` with unreachable URL returns `errors: ["could not reach..."]` not a 500

### Integration Tests
- [ ] After register: `getAgent` returns `contextInjection` with 3 mandatory entries
- [ ] `getAgentYAML` returns YAML that passes `catalog/validate.sh`

---

## Stage 7: Secret Handling

### Integration Tests
- [ ] Save experiment with agent secret input → K8s Secret `ace-agent-secret-<expID>` exists in litmus
- [ ] Re-save with different key value → Secret updated, old value gone
- [ ] Delete experiment → Secret deleted
- [ ] Check server logs → no API key values printed

---

## Stage 8: Context Injection

### Integration Tests
- [ ] Generated Argo Workflow contains `{{workflow.name}}` in install-agent args
- [ ] `litellmUpstream` workflow parameter is set to correct LiteLLM URL
- [ ] `argo lint` passes on generated workflow

---

## Stage 9: End-to-End Smoke Test

### Full Flow Test
1. Register `smoke-test-agent` (non-LLM-dependent, busybox image)
2. Save chaos experiment referencing this agent
3. Run experiment in kind cluster
4. Verify:
   - install-agent step succeeds
   - Agent pod starts: `kubectl get pods -n litmus`
   - `ACE_NOTIFY_ID` env var set in pod: `kubectl exec ... env | grep ACE_NOTIFY_ID`
   - Pod annotated with `ace.io/workflow-uid`
5. Wait for workflow completion
6. Verify cleanup: pod removed, Helm release removed
7. Agent Secret persists (not deleted on run end)

---

## Compatibility Testing

| Scenario | Expected |
|----------|----------|
| LLM-dependent agent, no model config saved | Registration fails with clear error |
| Agent with `capability: bookinfo-only` + bookinfo app | Warning shown in Chaos Studio |
| Agent with `install.method: helm` but no `folder` | Validation error |
| Duplicate agent name in same project | `ErrDuplicateAgentName` |

---

**Last Updated:** 2026-07-07
