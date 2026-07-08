# Stage 09: `submitRun` + `abortRun` Mutations

**Phase:** 2 — Experiment Execution  
**Status:** Not Started  
**Estimated Effort:** 1.5 days  
**Date Added:** 2026-07-07  
**Depends On:** Stages 07 + 08 (hydrator + run tracking both complete)

---

## Objectives

1. Implement the `submitRun` mutation resolver end-to-end:
   validate definition → resolve agent → build microservice map → call hydrator → create K8s secret
   → submit Argo Workflow → save run record → return.
2. Implement the `abortRun` mutation resolver:
   look up run → stop Argo Workflow → update status to ABORTED → return.
3. Implement the `getRun` and `listRuns` query resolvers.
4. Integration test: `submitRun` against a local kind cluster produces a Queued run record
   and an Argo Workflow in the `litmus` namespace.

---

## Current State Analysis

### What Exists
- `pkg/chaos_experiment/ops/` — Argo Workflow submission code (create Workflow via K8s client).
  Reuse `SubmitWorkflow(ctx, namespace, manifest string)` from this package.
- `pkg/chaos_experiment/ops/` — likely has `DeleteWorkflow` or `StopWorkflow` — check for abort.
- `pkg/agent_registry/` — `GetAgent(ctx, projectID, agentName)` returns agent record with
  `llmConfig.allowUserChoice`, `allowedModels`, `version`, Helm chart details.
- K8s client is already initialized in the server — find the injection point (check `resolver.go`
  or `graph/resolver.go` for `k8sClient` or `kubeClient` field).

### What Is Needed
- `graph/experiment_run.resolvers.go` — new resolver file implementing all four operations
- `graph/experiment_run_converters.go` — `AceExperimentRunDoc → model.AceExperimentRun`
- K8s secret creation helper (inline or in a new `pkg/experiment_hydrator/secrets.go`)

---

## Pre-Stage Verification

```bash
# 1. Stages 07 + 08 compile
go build ./pkg/experiment_hydrator/... ./pkg/experiment_definition/...

# 2. Argo Workflow submission in chaos_experiment ops
ls /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/chaos_experiment/ops/

# 3. Agent registry service interface
grep -n "func.*GetAgent\|func.*FindAgent" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/agent_registry/*.go

# 4. K8s client in resolver
grep -n "k8sClient\|kubeClient\|kubernetes.Interface" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/graph/resolver.go

# 5. Kind cluster running
kubectl cluster-info --context kind-AgentCert 2>/dev/null || echo "Kind cluster not running"
```

---

## Implementation Tasks

### Task 1: Create `graph/experiment_run.resolvers.go`

```go
package graph

import (
    "context"
    "fmt"
    "time"

    "github.com/google/uuid"
    corev1 "k8s.io/api/core/v1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

    "github.com/litmuschaos/litmus/chaoscenter/graphql/server/graph/model"
    expdef "github.com/litmuschaos/litmus/chaoscenter/graphql/server/pkg/experiment_definition"
    "github.com/litmuschaos/litmus/chaoscenter/graphql/server/pkg/experiment_hydrator"
)

// SubmitRun implements the submitRun GraphQL mutation.
func (r *mutationResolver) SubmitRun(
    ctx context.Context,
    projectID string,
    experimentName string,
    agentName string,
    modelOverride *string,
    secretOverrides []*model.AceSecretInput,
    paramOverrides []*model.AceParamInput,
) (*model.AceExperimentRun, error) {
    // ── Step 1: Validate experiment definition ──────────────────────────────
    def, err := r.ExperimentDefinitionService.GetByName(ctx, projectID, experimentName)
    if err != nil {
        return nil, fmt.Errorf("submitRun: experiment not found: %w", err)
    }

    // ── Step 2: Resolve agent ───────────────────────────────────────────────
    agent, err := r.AgentRegistryService.GetAgent(ctx, projectID, agentName)
    if err != nil {
        return nil, fmt.Errorf("submitRun: agent not found: %w", err)
    }

    // ── Step 3: Determine model ─────────────────────────────────────────────
    modelUsed, modelProvider, err := resolveModel(def, agent, modelOverride)
    if err != nil {
        return nil, fmt.Errorf("submitRun: model resolution: %w", err)
    }

    // ── Step 4: Build microservice map from app registry ────────────────────
    msMap, err := r.buildMicroserviceMap(ctx, def.TargetApp.Name)
    if err != nil {
        return nil, fmt.Errorf("submitRun: microservice map: %w", err)
    }

    // ── Step 5: Generate run ID ─────────────────────────────────────────────
    runID := fmt.Sprintf("run-%s", uuid.New().String()[:8])
    appNamespace := fmt.Sprintf("%s-%s", def.TargetApp.Name, runID)
    secretName := fmt.Sprintf("ace-agent-secret-%s", runID)

    // ── Step 6: Build param overrides map ───────────────────────────────────
    paramMap := make(map[string]string)
    for _, p := range paramOverrides {
        if p != nil {
            paramMap[fmt.Sprintf("%s/%s", p.StepName, p.Key)] = p.Value
        }
    }

    // ── Step 7: Hydrate experiment → Argo Workflow YAML ────────────────────
    hydratorAgent := &experiment_hydrator.AgentSpec{
        Name:    agent.Name,
        Version: agent.Version,
    }
    hydrationParams := experiment_hydrator.HydrationParams{
        RunID:           runID,
        AppNamespace:    appNamespace,
        LitellmUpstream: "http://litellm.litmus.svc.cluster.local:4000",
        ModelOverride:   getStringPtr(modelOverride),
        AgentSecretName: secretName,
        MicroserviceMap: msMap,
        ParamOverrides:  paramMap,
    }
    workflowYAML, err := experiment_hydrator.Hydrate(def, hydratorAgent, hydrationParams)
    if err != nil {
        return nil, fmt.Errorf("submitRun: hydration failed: %w", err)
    }

    // ── Step 8: Create K8s Secret for agent secrets ─────────────────────────
    secretData := make(map[string][]byte)
    for _, s := range secretOverrides {
        if s != nil {
            secretData[s.Key] = []byte(s.Value)
        }
    }
    secret := &corev1.Secret{
        ObjectMeta: metav1.ObjectMeta{
            Name:      secretName,
            Namespace: "litmus",
            Labels: map[string]string{
                "ace.io/run-id": runID,
            },
        },
        Data: secretData,
    }
    if _, err := r.KubeClient.CoreV1().Secrets("litmus").Create(ctx, secret, metav1.CreateOptions{}); err != nil {
        return nil, fmt.Errorf("submitRun: failed to create agent secret: %w", err)
    }

    // ── Step 9: Submit Argo Workflow ────────────────────────────────────────
    wfName, err := r.submitArgoWorkflow(ctx, workflowYAML)
    if err != nil {
        // Clean up secret on Argo failure
        _ = r.KubeClient.CoreV1().Secrets("litmus").Delete(ctx, secretName, metav1.DeleteOptions{})
        return nil, fmt.Errorf("submitRun: Argo submission failed: %w", err)
    }

    // ── Step 10: Save run record to MongoDB ─────────────────────────────────
    now := time.Now()
    runDoc := &expdef.AceExperimentRunDoc{
        RunID:             runID,
        ProjectID:         projectID,
        DefinitionName:    def.Name,
        DefinitionVersion: def.Version,
        AgentName:         agent.Name,
        AgentVersion:      agent.Version,
        ModelUsed:         modelUsed,
        ModelProvider:     modelProvider,
        ArgoWorkflowName:  wfName,
        Status:            expdef.RunStatusQueued,
        CreatedAt:         now,
        CreatedBy:         getUsername(ctx),
    }
    if err := r.RunRepository.Create(ctx, runDoc); err != nil {
        return nil, fmt.Errorf("submitRun: failed to persist run record: %w", err)
    }

    return runDocToGraphQL(runDoc), nil
}

// AbortRun implements the abortRun GraphQL mutation.
func (r *mutationResolver) AbortRun(
    ctx context.Context,
    projectID string,
    runID string,
) (*model.AceExperimentRun, error) {
    // Fetch run record
    run, err := r.RunRepository.GetByID(ctx, runID)
    if err != nil {
        return nil, fmt.Errorf("abortRun: %w", err)
    }
    if run.IsTerminal() {
        // Idempotent: already terminated
        return runDocToGraphQL(run), nil
    }

    // Stop Argo Workflow
    if err := r.stopArgoWorkflow(ctx, run.ArgoWorkflowName); err != nil {
        return nil, fmt.Errorf("abortRun: failed to stop Argo Workflow: %w", err)
    }

    // Update status
    if err := r.RunRepository.UpdateStatus(ctx, runID, expdef.RunStatusAborted, "user requested abort"); err != nil {
        return nil, fmt.Errorf("abortRun: failed to update run status: %w", err)
    }

    run.Status = expdef.RunStatusAborted
    return runDocToGraphQL(run), nil
}

// GetRun implements the getRun GraphQL query.
func (r *queryResolver) GetRun(
    ctx context.Context,
    projectID string,
    runID string,
) (*model.AceExperimentRun, error) {
    run, err := r.RunRepository.GetByID(ctx, runID)
    if err != nil {
        if _, ok := err.(expdef.ErrRunNotFound); ok {
            return nil, nil
        }
        return nil, err
    }
    return runDocToGraphQL(run), nil
}

// ListRuns implements the listRuns GraphQL query.
func (r *queryResolver) ListRuns(
    ctx context.Context,
    projectID string,
    experimentName *string,
    agentName *string,
    status *model.AceRunStatus,
) ([]*model.AceExperimentRun, error) {
    filter := expdef.RunListFilter{ProjectID: projectID}
    if experimentName != nil {
        filter.DefinitionName = *experimentName
    }
    if agentName != nil {
        filter.AgentName = *agentName
    }
    if status != nil {
        filter.Status = graphqlRunStatusToService(*status)
    }
    runs, err := r.RunRepository.List(ctx, filter)
    if err != nil {
        return nil, err
    }
    return runDocsToGraphQL(runs), nil
}
```

### Task 2: Create `graph/experiment_run_converters.go`

Key conversion functions:

```go
package graph

func runDocToGraphQL(doc *expdef.AceExperimentRunDoc) *model.AceExperimentRun {
    events := make([]*model.RunStatusEvent, len(doc.StatusHistory))
    for i, e := range doc.StatusHistory {
        events[i] = &model.RunStatusEvent{
            Status:    serviceRunStatusToGraphQL(e.Status),
            Timestamp: e.Timestamp.Format(time.RFC3339),
            Reason:    &e.Reason,
        }
    }
    run := &model.AceExperimentRun{
        RunID:             doc.RunID,
        ProjectID:         doc.ProjectID,
        DefinitionName:    doc.DefinitionName,
        DefinitionVersion: doc.DefinitionVersion,
        AgentName:         doc.AgentName,
        AgentVersion:      doc.AgentVersion,
        ModelUsed:         doc.ModelUsed,
        ModelProvider:     doc.ModelProvider,
        ArgoWorkflowName:  doc.ArgoWorkflowName,
        Status:            serviceRunStatusToGraphQL(doc.Status),
        StatusHistory:     events,
        CreatedAt:         doc.CreatedAt.Format(time.RFC3339),
        CreatedBy:         doc.CreatedBy,
    }
    if doc.LangfuseTraceID != "" {
        run.LangfuseTraceID = &doc.LangfuseTraceID
    }
    if doc.CertifierReportID != "" {
        run.CertifierReportID = &doc.CertifierReportID
    }
    if doc.StartedAt != nil {
        t := doc.StartedAt.Format(time.RFC3339)
        run.StartedAt = &t
    }
    if doc.CompletedAt != nil {
        t := doc.CompletedAt.Format(time.RFC3339)
        run.CompletedAt = &t
    }
    return run
}
```

### Task 3: Helper Functions

```go
// resolveModel determines which model and provider to use for this run.
func resolveModel(
    def *expdef.ExperimentDefinitionDoc,
    agent *agentRegistryModel.Agent,
    override *string,
) (modelUsed, modelProvider string, err error) {
    // If the experiment has a fixed model, use it
    if def.ModelSelection.Mode == expdef.ModelSelectionFixed && def.ModelSelection.FixedModel != "" {
        return def.ModelSelection.FixedModel, inferProvider(def.ModelSelection.FixedModel), nil
    }

    // If user override is provided and agent allows it
    if override != nil && *override != "" {
        if agent.LLMConfig != nil && agent.LLMConfig.AllowUserChoice {
            return *override, inferProvider(*override), nil
        }
        return "", "", fmt.Errorf("agent %q does not allow model override (allowUserChoice: false)", agent.Name)
    }

    // Default: use agent's default model from its LLM config
    if agent.LLMConfig != nil {
        return agent.LLMConfig.DefaultModel, agent.LLMConfig.Provider, nil
    }

    return "unknown", "unknown", nil
}

// inferProvider guesses the provider from the model name.
func inferProvider(model string) string {
    switch {
    case strings.HasPrefix(model, "gpt-"):
        return "openai"
    case strings.HasPrefix(model, "claude-"):
        return "anthropic"
    case strings.HasPrefix(model, "gemini-"):
        return "google"
    default:
        return "unknown"
    }
}

// submitArgoWorkflow calls the existing chaos_experiment ops to submit the workflow.
func (r *mutationResolver) submitArgoWorkflow(ctx context.Context, yaml string) (string, error) {
    // Reuse existing argo client — check chaos_experiment/ops for the exact function signature
    // e.g.: ops.SubmitWorkflow(ctx, r.K8sClient, "litmus", yaml)
    // Returns the workflow name.
    panic("implement me: check chaos_experiment/ops for the argo submit function")
}

// stopArgoWorkflow stops a running Argo Workflow.
func (r *mutationResolver) stopArgoWorkflow(ctx context.Context, workflowName string) error {
    // Use the Argo Workflow API or kubectl to stop the workflow
    // e.g.: patch the workflow with `spec.shutdown: Stop`
    panic("implement me: check chaos_experiment/ops for abort/stop function")
}
```

> **Note:** Replace the panic stubs with actual calls to the Argo Workflow submission and stop
> functions found in `pkg/chaos_experiment/ops/`. The exact function signatures must be verified
> against the current codebase.

### Task 4: Update `graph/resolver.go`

Add `RunRepository` and other new dependencies:

```go
type Resolver struct {
    // ... existing fields ...
    FaultCatalogService        fault_catalog.Service
    ExperimentDefinitionService experiment_definition.Service
    RunRepository              experiment_definition.RunRepository
    KubeClient                 kubernetes.Interface  // likely already present
}
```

---

## Verification Criteria

### Must Pass

1. `go build ./...` succeeds.

2. `submitRun` mutation creates a run record:
   ```bash
   curl -s -X POST http://localhost:8080/query \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{
       "query": "mutation { submitRun(projectID: \"proj1\", experimentName: \"test-exp\", agentName: \"flash-agent\") { runID status argoWorkflowName } }"
     }' | jq .
   ```

3. Run record appears in MongoDB:
   ```bash
   mongosh litmus --eval "db.experiment_runs_ext.findOne({}, {runID:1, status:1})"
   ```

4. Argo Workflow appears in the `litmus` namespace:
   ```bash
   kubectl get workflows -n litmus
   ```

5. `abortRun` stops a RUNNING workflow and updates status to ABORTED.

6. `getRun` returns the created run.

### Should Pass

7. `submitRun` with `modelOverride` when `allowUserChoice: false` returns a GraphQL error.

8. K8s Secret `ace-agent-secret-<runID>` is created in `litmus` namespace before Argo submission.

9. If Argo submission fails, the K8s Secret is cleaned up before returning the error.

---

## Testing Commands

```bash
# Integration test (kind cluster required)
export KUBECONFIG=$(kind get kubeconfig --name AgentCert 2>/dev/null)
export TOKEN=$(curl -s -X POST http://localhost:8080/auth/login \
  -d '{"username":"admin","password":"litmus"}' | jq -r .accessToken)

# First create an experiment
curl -s -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { createExperiment(projectID: \"proj1\", input: {name: \"e2e-test\", targetApp: {name: \"sock-shop\", version: \">=1.0.0\"}, modelSelection: {mode: AGENT_DEFAULT}, steps: [{name: \"baseline\", type: OBSERVE, duration: \"30s\"}]}) { name } }"}' | jq .

# Then submit a run
curl -s -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { submitRun(projectID: \"proj1\", experimentName: \"e2e-test\", agentName: \"flash-agent\") { runID status } }"}' | jq .
```

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Argo submit function signature mismatch | `chaos_experiment/ops` has a different signature than expected | Grep the ops package: `grep -n "func Submit\|func Create" pkg/chaos_experiment/ops/*.go` |
| `KubeClient` not in `Resolver` struct | Resolver doesn't currently have a K8s client field | Check how existing code (chaos_infrastructure, etc.) gets the K8s client — it may be a global or injected differently |
| K8s Secret creation fails with "already exists" | Previous test run left a secret | Add `--ignore-not-found` in the cleanup or use `CreateOrUpdate` pattern |
| `buildMicroserviceMap` not implemented | The method is referenced but not written in the task list | Implement it by calling `apps_registry.GetApp(ctx, appName)` and iterating its `microservices[]` to build `map[string]MicroserviceInfo` |
| Model inference for Claude returns "unknown" | `inferProvider` only checks prefixes | Add `case strings.HasPrefix(model, "claude-")` to return `"anthropic"` |

---

## Rollback Procedure

```bash
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/graph/experiment_run.resolvers.go
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/graph/experiment_run_converters.go
git checkout graph/resolver.go
```

---

## Success Criteria

Stage 09 is complete when:
- `submitRun` produces a valid run record in MongoDB and an Argo Workflow in the `litmus` namespace
- `abortRun` stops the Argo Workflow and updates run status
- `getRun` and `listRuns` return correct data
- Integration test against the kind cluster passes end-to-end

**Next Stage:** Stage 10 — Chaos Studio Screens 1 & 2
