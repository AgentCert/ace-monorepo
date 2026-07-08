# Agent Onboarding — Quick Reference Summary

## Plan at a Glance

| Stage | Phase | Name | Key Deliverables | Risk |
|-------|-------|------|-----------------|------|
| 1 | 1 | Extend Agent GraphQL Schema & MongoDB | Full spec §5 types in `.graphqls`; MongoDB `AgentDocument`; updated mapper | Medium |
| 2 | 1 | Capabilities Vocabulary | `catalog/capabilities/*.yaml`; Go loader; validator rejects unknown keys | Low |
| 3 | 2 | Model Library Backend | `pkg/model_library/`; MongoDB `model_library_collection`; LiteLLM API; K8s Secrets | High |
| 4 | 2 | Model Library Frontend | Settings > Model Library screen; `ModelConfigDialog`; Test Connection | Low |
| 5 | 3 | Registration Wizard Frontend | 7-step wizard in `views/AgentOnboarding/wizard/`; calls `registerAgent` | Medium |
| 6 | 3 | ImportMCPTools + agent.yaml Gen | `importMCPTools` resolver; spec-aligned MongoDB storage; YAML generator | Low |
| 7 | 4 | Secret Handling | K8s Secret per experiment; wired into `saveChaosExperiment`/`deleteExperiment` | High |
| 8 | 4 | Context Injection Wiring | 3 mandatory `--set` args in install-agent step; `litellmUpstream` resolved | High |
| 9 | 4 | install-agent Integration & Smoke Test | End-to-end kind cluster test; env var verification | Medium |

---

## Key Files (Existing → needs change)

| File | Stage | Change |
|------|-------|--------|
| `graphql/definitions/shared/agent_registry.graphqls` | 1, 3 | Add spec §5 + Model Library types |
| `pkg/agent_registry/service.go` | 1, 2, 6 | Extend Agent struct; RegisterAgent uses spec model |
| `pkg/agent_registry/mapper.go` | 1 | Map new fields |
| `pkg/agent_registry/validator.go` | 1, 2 | Use capabilities vocab loader |
| `graph/agent_registry.resolvers.go` | 6 | Implement `importMCPTools` |
| `web/src/views/AgentOnboarding/AgentOnboarding.tsx` | 5 | Add Register Agent button + wizard entry |

---

## Key Files (New → to create)

| File | Stage | Purpose |
|------|-------|---------|
| `catalog/capabilities/*.yaml` (6 files) | 2 | Domain capability vocabulary |
| `pkg/agent_registry/capabilities_loader.go` | 2 | Load YAML vocab at startup |
| `pkg/database/mongodb/agent_registry/` | 1 | Agent BSON schema + operations |
| `pkg/database/mongodb/model_library/` | 3 | ModelConfig BSON schema + operations |
| `pkg/model_library/` (service, litellm, k8s, mapper) | 3 | Model Library business logic |
| `graph/model_library.resolvers.go` | 3 | Model Library GraphQL resolvers |
| `pkg/agent_registry/yaml_generator.go` | 6 | Generate agent.yaml string |
| `web/src/api/core/modelLibrary/` | 4 | Frontend GraphQL hooks |
| `web/src/views/ModelLibrary/` | 4 | Model Library settings screen |
| `web/src/components/ModelConfigDialog/` | 4 | Reusable Add/Test dialog |
| `web/src/views/AgentOnboarding/wizard/` (10 files) | 5 | 7-step registration wizard |

---

## Implementation Order

```
Stage 1 ──> Stage 2
              ↓
           Stage 3 ──> Stage 4
              ↓              ↓
           Stage 5 <─────────┘
              ↓
           Stage 6
              ↓
           Stage 7
              ↓
           Stage 8
              ↓
           Stage 9
```

---

## Quick Commands

```bash
# After any schema change
cd AgentCert/chaoscenter/graphql/server && go generate ./...

# Go tests
cd AgentCert/chaoscenter/graphql/server && go test ./pkg/...

# Frontend typecheck
cd AgentCert/chaoscenter/web && yarn tsc --noEmit

# Validate capabilities YAML files
for f in catalog/capabilities/*.yaml; do
  python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "$f OK"
done

# Check K8s Secrets in litmus namespace
kubectl get secrets -n litmus | grep -E "ace-model|ace-agent-secret"

# Check agent pod env vars (smoke test)
kubectl exec -n litmus <pod> -- env | grep -E "ACE_NOTIFY_ID|ACE_WORKFLOW_UID"
```

---

**Created:** 2026-07-07  
**Total Stages:** 9  
**Status:** Ready for Implementation
