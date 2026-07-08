# Agent Onboarding — Progress Tracker

## Current Status
- **Current Stage:** Complete
- **Last Updated:** 2026-07-07
- **Overall Progress:** 9/9 stages complete (100%)

---

## Stage Completion Status

### Phase 1: Spec-Aligned Backend Model

- [x] **Stage 1:** Extend Agent GraphQL Schema & MongoDB Model
  - Status: Complete
  - Started: 2026-07-07
  - Completed: 2026-07-07
  - Verified: Yes — go generate + go build clean
  - Notes: 21 new GQL types added; Agent type extended with 14 nullable fields; RegisterAgentInput extended; new queries/mutations declared.

- [x] **Stage 2:** Capabilities Vocabulary
  - Status: Complete
  - Started: 2026-07-07
  - Completed: 2026-07-07
  - Verified: Yes — LoadCapabilitiesFromDir compiled and wired into resolver
  - Notes: 6 YAML capability files created in catalog/capabilities/; domains.yaml updated; CapabilityVocab struct with nil-safe IsValid(); wired into validator and service.

### Phase 2: Model Library

- [x] **Stage 3:** Model Library Backend
  - Status: Complete
  - Started: 2026-07-07
  - Completed: 2026-07-07
  - Verified: Yes — go generate + go build + go vet clean
  - Notes: MongoDB ops, LiteLLM client, K8s secret helpers, service, all 7 GraphQL resolvers. model_library.resolvers.go was merged into agent_registry.resolvers.go (gqlgen schema-file ownership).

- [x] **Stage 4:** Model Library Frontend
  - Status: Complete
  - Started: 2026-07-07
  - Completed: 2026-07-07
  - Verified: Yes — tsc --noEmit: zero new errors
  - Notes: 5 GraphQL hooks in api/core/modelLibrary/; ModelConfigDialog with test-before-save flow; ModelLibrary settings screen with table + delete confirmation. ConfirmationDialog has single onClose callback (no onConfirm).

### Phase 3: Registration Wizard

- [x] **Stage 5:** Registration Wizard Frontend (7-step)
  - Status: Complete
  - Started: 2026-07-07
  - Completed: 2026-07-07
  - Verified: Yes — tsc --noEmit: zero new errors in wizard files
  - Notes: 9 wizard files in views/AgentOnboarding/wizard/; AgentOnboarding.tsx updated with Register Agent button. RadioGroup replaced with native radio inputs; Switch/Checkbox onChange uses FormEvent.

- [x] **Stage 6:** ImportMCPTools + agent.yaml Generation
  - Status: Complete
  - Started: 2026-07-07
  - Completed: 2026-07-07
  - Verified: Yes — go build + go vet clean; 5/5 checks passed
  - Notes: ImportMCPTools does real HTTP GET /tools; GetAgentByName added to service interface; yaml_generator.go + pr_template.go created. Field names corrected against actual Agent struct (no bare Description, Tags absent).

### Phase 4: Experiment Wiring

- [x] **Stage 7:** Secret Handling
  - Status: Complete
  - Started: 2026-07-07
  - Completed: 2026-07-07
  - Verified: Yes — go generate + go build clean
  - Notes: AgentSecretInput/AgentConfigNode added to chaos_experiment.graphqls; agentConfig field in SaveChaosExperimentRequest; experiment_secret.go with UpsertExperimentSecret/DeleteExperimentSecret helpers; hooks in SaveChaosExperiment + DeleteChaosExperiment resolvers; --set agent.secretRef=ace-agent-secret-{{workflow.labels.workflow_id}} added to injectExperimentContextArgs.

- [x] **Stage 8:** Context Injection Wiring
  - Status: Complete
  - Started: 2026-07-07
  - Completed: 2026-07-07
  - Verified: Yes — go build + go vet clean
  - Notes: context_injection.go with DefaultContextInjections(), MergeContextInjections(), BuildInstallAgentContextArgs(), BuildLiteLLMWorkflowParam(); RegisterAgent auto-merges 3 mandatory context injections (agent.notifyId={{workflow.name}}, agent.workflowUid={{workflow.uid}}, sidecar.upstream={{workflow.parameters.litellmUpstream}}).

- [x] **Stage 9:** install-agent Integration & Chart Updates
  - Status: Complete
  - Started: 2026-07-07
  - Completed: 2026-07-07
  - Verified: Yes — helm template renders correctly
  - Notes: flash-agent chart already had agent.notifyId, agent.workflowUid, sidecar.upstream wired via ConfigMap/sidecar. Added agent.secretRef to values.yaml; added conditional envFrom.secretRef in deployment.yaml; added app.kubernetes.io/name label + ace.io/notify-id + ace.io/workflow-uid annotations to pod template. install-agent binary already supports --set flag (no changes needed). Smoke test steps documented in STAGE_09.md.

---

## Issues and Blockers

### Active Issues
None

### Resolved Issues
None

---

## Notes and Observations

### General Notes
- Existing `DeployAgentWithHelm` / `ValidateHelmDeployment` resolvers serve as the Advanced Register
  path in the spec. Do NOT remove them — the new Quick Register path is additive.
- `AgentOnboarding.tsx` currently handles Helm-deploy list + form; Stage 5 will replace it with
  the 7-step wizard while keeping the existing Helm path accessible via "Advanced Register."

### Decisions Made
- MongoDB collection for agents: reuse `agent_registry_collection` constant already defined in
  `pkg/agent_registry/constants.go`; extend the schema document rather than a new collection.
- Model Library: new collection `model_library_collection` in a new `pkg/database/mongodb/model_library/`
  package following the existing pattern.

### Changes to Plan
None yet.
