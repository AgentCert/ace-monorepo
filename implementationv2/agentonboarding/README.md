# Agent Onboarding Implementation Plan

## Overview

Spec-driven implementation of the ACE Agent Onboarding flow as defined in `spec/agent-onboarding.md`.
Covers the full flow from "I have a Docker image" to "my agent is running in a certifiable experiment."

**Total Stages:** 9 stages organized into 4 phases  
**Current Stage:** 0 (Not Started)  
**Spec Reference:** `/srv/projects/ace-monorepo/spec/agent-onboarding.md`  
**Dependencies:**
- App Onboarding spec (app catalog must have at least one app for compatibility step)
- LiteLLM deployment running in `litmus` namespace (for Model Library)
- Existing `pkg/agent_registry` package (partial foundation — see §What Already Exists)

---

## What Already Exists (Do NOT re-implement)

| Component | Location | Status |
|-----------|----------|--------|
| Service interface + impl | `AgentCert/chaoscenter/graphql/server/pkg/agent_registry/service.go` | Partial — Helm-deploy focused, not spec-aligned |
| GraphQL resolvers | `graph/agent_registry.resolvers.go` | Partial — covers Helm-deploy path only |
| GraphQL schema | `graphql/definitions/shared/agent_registry.graphqls` | Partial — missing spec types |
| Frontend agent list + Helm deploy | `web/src/views/AgentOnboarding/AgentOnboarding.tsx` | Replace with 7-step wizard |
| Helm deploy in resolver | `DeployAgentWithHelm`, `ValidateHelmDeployment` | Keep as Advanced Register path |
| MongoDB collections | `pkg/database/mongodb/` | Missing `agent_registry` and `model_library` collections |
| Catalog structure | `catalog/apps/` | Exists; need `catalog/agents/` and `catalog/capabilities/` |

---

## How to Use This Plan

### For Each Stage:
1. Read `STAGE_XX.md` in `stages/`
2. Review objectives and the "What Already Exists" section
3. Implement only what the stage says — do not gold-plate
4. Run verification commands from the stage doc
5. Mark complete in `PROGRESS.md`
6. Move to next stage only after all Must Pass verifications pass

### Resuming Implementation:
Provide:
- Current stage number from `PROGRESS.md`
- Path to this README: `implementationv2/agentonboarding/README.md`
- Any blockers from `PROGRESS.md`

---

## Stage Overview

### Phase 1: Spec-Aligned Backend Model (Stages 1–2)
**Goal:** Make the database and GraphQL layer speak the full agent spec from §5–§11 of the spec.

- **Stage 1:** Extend Agent GraphQL Schema & MongoDB Model
- **Stage 2:** Capabilities Vocabulary — YAML files + backend loader

### Phase 2: Model Library (Stages 3–4)
**Goal:** LLM credential management decoupled from agent YAML; LiteLLM registration.

- **Stage 3:** Model Library Backend (GraphQL + MongoDB + LiteLLM API)
- **Stage 4:** Model Library Frontend (Settings screen + Add/Test/Rotate dialogs)

### Phase 3: Registration Wizard (Stages 5–6)
**Goal:** The 7-step Chaos Studio wizard that produces a valid agent.yaml and private DB record.

- **Stage 5:** Registration Wizard Frontend (Steps 1–7)
- **Stage 6:** ImportMCPTools mutation + agent.yaml generation & storage

### Phase 4: Experiment Wiring (Stages 7–9)
**Goal:** Secrets, context injection, and install-agent mechanics so a registered agent can actually run.

- **Stage 7:** Secret Handling — K8s Secrets for experiments and model API keys
- **Stage 8:** Context Injection — wire llmConfig.configRef → sidecar.upstream at submit time
- **Stage 9:** install-agent Integration — full end-to-end smoke test

---

## Directory Structure

```
implementationv2/agentonboarding/
├── README.md                  (this file — entry point)
├── PROGRESS.md                (stage completion tracking)
├── ARCHITECTURE.md            (technical decisions)
├── SUMMARY.md                 (one-page quick reference)
├── stages/
│   ├── STAGE_01.md            Extend Agent GraphQL Schema & MongoDB
│   ├── STAGE_02.md            Capabilities Vocabulary
│   ├── STAGE_03.md            Model Library Backend
│   ├── STAGE_04.md            Model Library Frontend
│   ├── STAGE_05.md            Registration Wizard Frontend
│   ├── STAGE_06.md            ImportMCPTools + agent.yaml generation
│   ├── STAGE_07.md            Secret Handling
│   ├── STAGE_08.md            Context Injection wiring
│   └── STAGE_09.md            install-agent integration + smoke test
├── references/
│   ├── agent_spec_schema.md   Full agent.yaml field reference
│   ├── graphql_types.md       Target GraphQL type definitions
│   ├── model_library.md       Model Library DB + K8s layout
│   └── capabilities_vocab.md  Capabilities domain vocabulary summary
└── tests/
    ├── test_scenarios.md
    └── integration_tests.md
```

---

## Stage Dependencies

```
Stage 1 (Schema + DB)
  ↓
Stage 2 (Capabilities Vocab)
  ↓
Stage 3 (Model Library Backend) ──> Stage 4 (Model Library Frontend)
  ↓                                               ↓
Stage 5 (Registration Wizard) <──────────────────┘
  ↓
Stage 6 (MCP Import + agent.yaml gen)
  ↓
Stage 7 (Secret Handling)
  ↓
Stage 8 (Context Injection)
  ↓
Stage 9 (End-to-end smoke test)
```

---

## Critical Success Factors

1. **Schema first:** Every stage that touches the backend starts by updating the `.graphqls` file, then runs `go generate` to regenerate models. Never hand-edit `models_gen.go`.
2. **Additive changes:** The existing Helm-deploy path (`DeployAgentWithHelm`) must keep working throughout. Stages 1–8 extend; they do not break.
3. **Secret safety:** LLM API keys must never appear in Argo Workflow YAML, server logs, or GraphQL query responses.
4. **Catalog-first capabilities:** Capability keys must be validated against `catalog/capabilities/*.yaml`, not a hardcoded list.

---

## Quick Reference

```bash
# Regenerate GraphQL models after schema change
cd AgentCert/chaoscenter/graphql/server && go generate ./...

# Run Go tests for agent_registry
cd AgentCert/chaoscenter/graphql/server && go test ./pkg/agent_registry/...

# Run frontend type check
cd AgentCert/chaoscenter/web && yarn tsc --noEmit

# Apply a K8s secret (for testing secret handling)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ace-agent-secret-test
  namespace: litmus
type: Opaque
stringData:
  OPENAI_API_KEY: sk-test
EOF

# Check LiteLLM is running
kubectl get pods -n litmus -l app=litellm
```

---

## Risk Management

### High-Risk Stages
- **Stage 3:** LiteLLM API integration — LiteLLM's `/config/add_model` API is internal and may change. Pin to the LiteLLM version deployed in the cluster.
- **Stage 8:** Context injection at workflow submit time — Argo template variable syntax must be exactly right; test with a real Argo workflow.

### Mitigation
- Stage 3: Wrap LiteLLM calls in an interface so they can be mocked in tests.
- Stage 8: Validate injected YAML renders correctly with `argo lint` before marking complete.

---

**Last Updated:** 2026-07-07  
**Plan Version:** 1.0  
**Status:** Ready for implementation
