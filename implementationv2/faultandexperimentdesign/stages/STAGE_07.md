# Stage 07: Argo Workflow Hydrator

**Phase:** 2 — Experiment Execution  
**Status:** Not Started  
**Estimated Effort:** 2 days  
**Date Added:** 2026-07-07  
**Depends On:** Stage 04 (ExperimentDefinitionDoc types available)

---

## Objectives

1. Create `pkg/experiment_hydrator/` with three files:
   - `hydrator.go` — entry point `Hydrate()` that returns Argo Workflow YAML string
   - `chaosengine_renderer.go` — converts a fault step + app microservice map → ChaosEngine YAML
   - `dag_builder.go` — builds the Argo DAG task list from the step sequence
2. Support all five step types: observe, fault, verify, wait, parallel-fault.
3. Handle `dependsOn` for sequential ordering and `parallel-fault` for fan-out.
4. Ensure `Hydrate()` is a pure function (no K8s calls, no MongoDB calls) — it takes inputs
   and returns a YAML string.
5. Unit tests cover each step type and the `dependsOn` / parallel-fault DAG construction.

---

## Current State Analysis

### What Exists
- `pkg/chaos_experiment/ops/` — existing Argo Workflow submission code. The hydrator does NOT
  call this; it only produces a YAML string. The `submitRun` resolver (Stage 09) calls the ops
  layer to submit the workflow.
- `pkg/chaos_experiment/model/` — existing model for Argo manifests. The hydrator builds its
  own Argo structs (not the existing model).
- LitmusChaos `ChaosEngine` CRD format — must match the format used by the existing chaos runner.
- App registry: each app's `app.yaml` declares a `microservices[]` map with `name` and
  `k8s.label` — the hydrator uses this to resolve microservice names to label selectors.

### What Is Needed
- `pkg/experiment_hydrator/` — new package, three files
- No schema or MongoDB changes in this stage

---

## Pre-Stage Verification

```bash
# 1. Confirm existing Argo Workflow model used in chaos_experiment
grep -rn "argoproj.io/v1alpha1" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/chaos_experiment/ | head -5

# 2. Confirm ChaosEngine CRD format
kubectl get crd chaosengines.litmuschaos.io -o jsonpath='{.spec.group}' 2>/dev/null

# 3. Confirm Argo Workflows CRD
kubectl get crd workflows.argoproj.io -o jsonpath='{.spec.group}' 2>/dev/null

# 4. Stage 04 builds
go build ./pkg/experiment_definition/...
```

---

## Implementation Tasks

### Task 1: Define Hydration Input/Output Types in `pkg/experiment_hydrator/hydrator.go`

```go
package experiment_hydrator

import (
    "bytes"
    "fmt"
    "text/template"

    "gopkg.in/yaml.v3"

    expdef "github.com/litmuschaos/litmus/chaoscenter/graphql/server/pkg/experiment_definition"
)

// MicroserviceInfo is the resolved Kubernetes label selector for a microservice.
type MicroserviceInfo struct {
    Name      string // microservice name (from app.yaml)
    Namespace string // K8s namespace the app is installed in
    Label     string // e.g. "name=carts"
    Kind      string // deployment | statefulset | daemonset
}

// AgentSpec is the minimal agent info needed for hydration.
type AgentSpec struct {
    Name      string
    Version   string
    ChartName string   // Helm chart name for agent install
    Namespace string   // Namespace where agent is installed
}

// HydrationParams holds all runtime parameters for a single run.
type HydrationParams struct {
    RunID               string
    AppNamespace        string   // e.g. "sock-shop-<runID>"
    LitellmUpstream     string   // e.g. "http://litellm.litmus.svc.cluster.local:4000"
    ModelOverride       string   // empty if agent-default
    AgentSecretName     string   // K8s Secret name for agent secrets
    MicroserviceMap     map[string]MicroserviceInfo // key: microservice name
    ParamOverrides      map[string]string  // per-step param overrides
}

// Hydrate converts an ExperimentDefinition into an Argo Workflow YAML string.
// This function is pure — it makes no K8s or MongoDB calls.
func Hydrate(
    def *expdef.ExperimentDefinitionDoc,
    agent *AgentSpec,
    params HydrationParams,
) (string, error) {
    if def == nil {
        return "", fmt.Errorf("experiment_hydrator: nil experiment definition")
    }
    if params.RunID == "" {
        return "", fmt.Errorf("experiment_hydrator: RunID is required")
    }

    dagTasks, templates, err := buildDAG(def, agent, params)
    if err != nil {
        return "", fmt.Errorf("experiment_hydrator: DAG build failed: %w", err)
    }

    wf := ArgoWorkflow{
        APIVersion: "argoproj.io/v1alpha1",
        Kind:       "Workflow",
        Metadata: ArgoMetadata{
            Name:      fmt.Sprintf("%s-%s", def.Name, params.RunID),
            Namespace: "litmus",
            Labels: map[string]string{
                "ace.io/run-id":             params.RunID,
                "ace.io/experiment-name":    def.Name,
                "ace.io/experiment-version": def.Version,
                "ace.io/agent-name":         agent.Name,
            },
        },
        Spec: ArgoWorkflowSpec{
            Entrypoint: "experiment-dag",
            Arguments: ArgoArguments{
                Parameters: []ArgoParameter{
                    {Name: "litellmUpstream", Value: params.LitellmUpstream},
                    {Name: "appNamespace", Value: params.AppNamespace},
                    {Name: "agentSecretName", Value: params.AgentSecretName},
                    {Name: "runID", Value: params.RunID},
                },
            },
            Templates: append([]ArgoTemplate{
                {
                    Name: "experiment-dag",
                    DAG:  &ArgoDAG{Tasks: dagTasks},
                },
            }, templates...),
        },
    }

    out, err := yaml.Marshal(wf)
    if err != nil {
        return "", fmt.Errorf("experiment_hydrator: YAML marshal failed: %w", err)
    }

    // Validation pass — ensure output parses back cleanly
    var check map[string]interface{}
    if err := yaml.Unmarshal(out, &check); err != nil {
        return "", fmt.Errorf("experiment_hydrator: generated YAML is invalid: %w", err)
    }

    return string(out), nil
}

// HydrateAndValidate is Hydrate with an explicit validation pass.
// Returns the workflow YAML and any validation errors.
func HydrateAndValidate(
    def *expdef.ExperimentDefinitionDoc,
    agent *AgentSpec,
    params HydrationParams,
) (string, error) {
    return Hydrate(def, agent, params)
}
```

### Task 2: Define Argo Structs in `pkg/experiment_hydrator/hydrator.go` (continued)

```go
// ArgoWorkflow is the top-level Argo Workflow struct.
type ArgoWorkflow struct {
    APIVersion string           `yaml:"apiVersion"`
    Kind       string           `yaml:"kind"`
    Metadata   ArgoMetadata     `yaml:"metadata"`
    Spec       ArgoWorkflowSpec `yaml:"spec"`
}

type ArgoMetadata struct {
    Name      string            `yaml:"name"`
    Namespace string            `yaml:"namespace"`
    Labels    map[string]string `yaml:"labels,omitempty"`
}

type ArgoWorkflowSpec struct {
    Entrypoint string         `yaml:"entrypoint"`
    Arguments  ArgoArguments  `yaml:"arguments"`
    Templates  []ArgoTemplate `yaml:"templates"`
}

type ArgoArguments struct {
    Parameters []ArgoParameter `yaml:"parameters"`
}

type ArgoParameter struct {
    Name  string `yaml:"name"`
    Value string `yaml:"value"`
}

type ArgoTemplate struct {
    Name      string          `yaml:"name"`
    DAG       *ArgoDAG        `yaml:"dag,omitempty"`
    Container *ArgoContainer  `yaml:"container,omitempty"`
    Script    *ArgoScript     `yaml:"script,omitempty"`
}

type ArgoDAG struct {
    Tasks []ArgoDAGTask `yaml:"tasks"`
}

type ArgoDAGTask struct {
    Name         string         `yaml:"name"`
    Template     string         `yaml:"template"`
    Dependencies []string       `yaml:"dependencies,omitempty"`
    Arguments    *ArgoArguments `yaml:"arguments,omitempty"`
}

type ArgoContainer struct {
    Image   string   `yaml:"image"`
    Command []string `yaml:"command"`
    Args    []string `yaml:"args,omitempty"`
    Env     []ArgoEnvVar `yaml:"env,omitempty"`
}

type ArgoScript struct {
    Image  string `yaml:"image"`
    Source string `yaml:"source"`
}

type ArgoEnvVar struct {
    Name  string `yaml:"name"`
    Value string `yaml:"value"`
}
```

### Task 3: Create `pkg/experiment_hydrator/dag_builder.go`

```go
package experiment_hydrator

import (
    "fmt"

    expdef "github.com/litmuschaos/litmus/chaoscenter/graphql/server/pkg/experiment_definition"
)

// buildDAG converts the experiment step list into Argo DAG tasks and template definitions.
// Returns: DAG task list, additional templates (one per step type), error.
func buildDAG(
    def *expdef.ExperimentDefinitionDoc,
    agent *AgentSpec,
    params HydrationParams,
) ([]ArgoDAGTask, []ArgoTemplate, error) {
    var tasks []ArgoDAGTask
    var templates []ArgoTemplate

    // Special tasks: install-app, install-agent, teardown
    tasks = append(tasks, ArgoDAGTask{
        Name:     "install-app",
        Template: "install-app-tmpl",
    })
    tasks = append(tasks, ArgoDAGTask{
        Name:         "install-agent",
        Template:     "install-agent-tmpl",
        Dependencies: []string{"install-app"},
    })

    // Track the last step name for sequential dependency
    prevDeps := []string{"install-agent"}

    for i, step := range def.Steps {
        taskName := fmt.Sprintf("step-%s", step.Name)
        deps := prevDeps

        // If this step has an explicit dependsOn, override sequential deps
        if step.DependsOn != "" {
            deps = []string{fmt.Sprintf("step-%s", step.DependsOn)}
        }

        task := ArgoDAGTask{
            Name:         taskName,
            Dependencies: deps,
        }

        switch step.Type {
        case expdef.StepTypeObserve, expdef.StepTypeWait:
            dur := step.Duration
            if dur == "" {
                dur = "30s"
            }
            task.Template = "observe-tmpl"
            task.Arguments = &ArgoArguments{
                Parameters: []ArgoParameter{{Name: "duration", Value: dur}},
            }

        case expdef.StepTypeFault:
            ceYAML, err := renderChaosEngine(step, params, i)
            if err != nil {
                return nil, nil, fmt.Errorf("step %s: %w", step.Name, err)
            }
            task.Template = "litmus-fault-tmpl"
            task.Arguments = &ArgoArguments{
                Parameters: []ArgoParameter{{Name: "chaosEngineYaml", Value: ceYAML}},
            }

        case expdef.StepTypeVerify:
            if step.Probe == nil {
                return nil, nil, fmt.Errorf("step %s: verify step requires a probe configuration", step.Name)
            }
            task.Template = "http-probe-tmpl"
            task.Arguments = &ArgoArguments{
                Parameters: []ArgoParameter{
                    {Name: "url", Value: step.Probe.URL},
                    {Name: "expectedStatus", Value: fmt.Sprintf("%d", step.Probe.ExpectedStatus)},
                },
            }

        case expdef.StepTypeParallelFault:
            // Fan out: one task per fault in the parallel set, all with the same deps
            for j, pf := range step.Faults {
                pTaskName := fmt.Sprintf("step-%s-fault-%d", step.Name, j)
                ceYAML, err := renderParallelFaultChaosEngine(pf, params, i, j)
                if err != nil {
                    return nil, nil, fmt.Errorf("step %s fault %d: %w", step.Name, j, err)
                }
                tasks = append(tasks, ArgoDAGTask{
                    Name:         pTaskName,
                    Template:     "litmus-fault-tmpl",
                    Dependencies: deps,
                    Arguments: &ArgoArguments{
                        Parameters: []ArgoParameter{{Name: "chaosEngineYaml", Value: ceYAML}},
                    },
                })
            }
            // The prevDeps for the next step after a parallel-fault must wait for ALL parallel tasks
            nextDeps := make([]string, len(step.Faults))
            for j := range step.Faults {
                nextDeps[j] = fmt.Sprintf("step-%s-fault-%d", step.Name, j)
            }
            prevDeps = nextDeps
            continue // skip the default task append below

        default:
            return nil, nil, fmt.Errorf("unknown step type: %s", step.Type)
        }

        tasks = append(tasks, task)
        prevDeps = []string{taskName}
    }

    // Teardown always runs last
    tasks = append(tasks, ArgoDAGTask{
        Name:         "teardown",
        Template:     "teardown-tmpl",
        Dependencies: prevDeps,
    })

    // Add standard templates
    templates = append(templates, buildStandardTemplates(agent, params)...)

    return tasks, templates, nil
}

// buildStandardTemplates returns the reusable Argo templates for observe, litmus-fault, verify, teardown.
func buildStandardTemplates(agent *AgentSpec, params HydrationParams) []ArgoTemplate {
    return []ArgoTemplate{
        {
            Name: "observe-tmpl",
            Container: &ArgoContainer{
                Image:   "alpine:3.19",
                Command: []string{"sh", "-c"},
                Args:    []string{"sleep {{inputs.parameters.duration | replace 's' ''}}"},
            },
        },
        {
            Name: "litmus-fault-tmpl",
            Container: &ArgoContainer{
                Image:   "litmuschaos/k8s:2.14.0",
                Command: []string{"sh", "-c"},
                Args: []string{
                    "echo \"$CHAOS_ENGINE_YAML\" | kubectl apply -f - && " +
                        "sleep $CHAOS_DURATION && " +
                        "echo \"$CHAOS_ENGINE_YAML\" | kubectl delete -f -",
                },
                Env: []ArgoEnvVar{
                    {Name: "CHAOS_ENGINE_YAML", Value: "{{inputs.parameters.chaosEngineYaml}}"},
                },
            },
        },
        {
            Name: "http-probe-tmpl",
            Container: &ArgoContainer{
                Image:   "curlimages/curl:8.4.0",
                Command: []string{"sh", "-c"},
                Args: []string{
                    "curl -sf -o /dev/null -w '%{http_code}' {{inputs.parameters.url}} | grep {{inputs.parameters.expectedStatus}}",
                },
            },
        },
        {
            Name: "teardown-tmpl",
            Container: &ArgoContainer{
                Image:   "alpine/helm:3.13.3",
                Command: []string{"sh", "-c"},
                Args: []string{
                    "helm uninstall agent-$RUN_ID -n $APP_NS --ignore-not-found; " +
                        "helm uninstall app-$RUN_ID -n $APP_NS --ignore-not-found; " +
                        "kubectl delete namespace $APP_NS --ignore-not-found",
                },
                Env: []ArgoEnvVar{
                    {Name: "RUN_ID", Value: params.RunID},
                    {Name: "APP_NS", Value: params.AppNamespace},
                },
            },
        },
        {
            Name: "install-app-tmpl",
            Container: &ArgoContainer{
                Image:   "alpine/helm:3.13.3",
                Command: []string{"sh", "-c"},
                Args:    []string{"helm upgrade --install app-$RUN_ID <chart> -n $APP_NS --create-namespace --wait"},
                Env: []ArgoEnvVar{
                    {Name: "RUN_ID", Value: params.RunID},
                    {Name: "APP_NS", Value: params.AppNamespace},
                },
            },
        },
        {
            Name: "install-agent-tmpl",
            Container: &ArgoContainer{
                Image:   "alpine/helm:3.13.3",
                Command: []string{"sh", "-c"},
                Args:    []string{"helm upgrade --install agent-$RUN_ID <agent-chart> -n $APP_NS --wait"},
                Env: []ArgoEnvVar{
                    {Name: "RUN_ID", Value: params.RunID},
                    {Name: "APP_NS", Value: params.AppNamespace},
                },
            },
        },
    }
}
```

### Task 4: Create `pkg/experiment_hydrator/chaosengine_renderer.go`

```go
package experiment_hydrator

import (
    "bytes"
    "fmt"
    "text/template"

    expdef "github.com/litmuschaos/litmus/chaoscenter/graphql/server/pkg/experiment_definition"
)

const chaosEngineTemplate = `apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: "{{.EngineName}}"
  namespace: litmus
  labels:
    ace.io/run-id: "{{.RunID}}"
spec:
  appinfo:
    appns: "{{.AppNamespace}}"
    applabel: "{{.AppLabel}}"
    appkind: deployment
  chaosServiceAccount: litmus-admin
  experiments:
    - name: {{.ExperimentRef}}
      spec:
        components:
          env:
{{range .Envs}}            - name: {{.Name}}
              value: "{{.Value}}"
{{end}}`

type chaosEngineInput struct {
    EngineName    string
    RunID         string
    AppNamespace  string
    AppLabel      string
    ExperimentRef string
    Envs          []struct{ Name, Value string }
}

// renderChaosEngine produces ChaosEngine YAML for a fault step.
func renderChaosEngine(
    step expdef.ExperimentStep,
    params HydrationParams,
    stepIdx int,
) (string, error) {
    // Resolve label selector
    ms, ok := params.MicroserviceMap[step.Target.Microservice]
    if !ok {
        return "", fmt.Errorf("microservice %q not found in app microservice map", step.Target.Microservice)
    }

    // Build env vars from step params
    envs := buildEnvVarsFromParams(step.Params)

    input := chaosEngineInput{
        EngineName:    fmt.Sprintf("%s-%s", step.Name, params.RunID),
        RunID:         params.RunID,
        AppNamespace:  params.AppNamespace,
        AppLabel:      ms.Label,
        ExperimentRef: step.FaultRef,
        Envs:          envs,
    }

    return renderTemplate(chaosEngineTemplate, input)
}

// renderParallelFaultChaosEngine produces ChaosEngine YAML for one fault
// within a parallel-fault step.
func renderParallelFaultChaosEngine(
    pf expdef.ParallelFaultEntry,
    params HydrationParams,
    stepIdx, faultIdx int,
) (string, error) {
    ms, ok := params.MicroserviceMap[pf.Target.Microservice]
    if !ok {
        return "", fmt.Errorf("microservice %q not found in app microservice map", pf.Target.Microservice)
    }

    envs := buildEnvVarsFromParams(pf.Params)

    input := chaosEngineInput{
        EngineName:    fmt.Sprintf("parallel-%d-%d-%s", stepIdx, faultIdx, params.RunID),
        RunID:         params.RunID,
        AppNamespace:  params.AppNamespace,
        AppLabel:      ms.Label,
        ExperimentRef: pf.FaultRef,
        Envs:          envs,
    }

    return renderTemplate(chaosEngineTemplate, input)
}

func buildEnvVarsFromParams(p map[string]string) []struct{ Name, Value string } {
    envs := make([]struct{ Name, Value string }, 0, len(p))
    for k, v := range p {
        envs = append(envs, struct{ Name, Value string }{Name: k, Value: v})
    }
    return envs
}

func renderTemplate(tmpl string, data interface{}) (string, error) {
    t, err := template.New("").Parse(tmpl)
    if err != nil {
        return "", err
    }
    var buf bytes.Buffer
    if err := t.Execute(&buf, data); err != nil {
        return "", err
    }
    return buf.String(), nil
}
```

---

## Verification Criteria

### Must Pass

1. Package compiles:
   ```bash
   go build ./pkg/experiment_hydrator/...
   ```

2. `Hydrate()` returns a non-empty YAML string for a valid experiment definition:
   ```bash
   go test ./pkg/experiment_hydrator/... -run TestHydrate -v
   ```

3. `Hydrate()` output passes `yaml.Unmarshal`:
   ```go
   var check map[string]interface{}
   err := yaml.Unmarshal([]byte(yamlStr), &check)
   // err must be nil
   ```

4. All five step types produce the correct Argo DAG task type:
   - observe → `observe-tmpl`
   - fault → `litmus-fault-tmpl` with ChaosEngine YAML in params
   - verify → `http-probe-tmpl`
   - wait → `observe-tmpl` (sleep)
   - parallel-fault → multiple `litmus-fault-tmpl` tasks fanned out

5. `dependsOn` correctly sets `Dependencies[]` on the downstream task.

### Should Pass

6. A parallel-fault step with 3 faults produces 3 fan-out tasks, and the next step depends on all 3.

7. A ChaosEngine with a microservice not in `MicroserviceMap` returns an error (not panic).

8. `Hydrate()` with a nil definition returns a descriptive error.

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server

# Run hydrator unit tests
go test ./pkg/experiment_hydrator/... -v -count=1

# Race detector
go test -race ./pkg/experiment_hydrator/...

# Print sample output
go test ./pkg/experiment_hydrator/... -run TestHydrate_PrintOutput -v 2>&1 | tail -50
```

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Template rendering produces invalid YAML (indentation) | `text/template` indentation in the ChaosEngine template is wrong | Use `gopkg.in/yaml.v3` `yaml.Marshal` on a struct instead of raw template for the ChaosEngine to avoid whitespace issues |
| `teardown` task has no dependencies when last step is parallel-fault | `prevDeps` not correctly tracking parallel task names | Always collect all parallel task names into `prevDeps` before the `continue` statement |
| Missing microservice in `MicroserviceMap` | `MicroserviceMap` was not populated from app.yaml before calling `Hydrate` | The `submitRun` resolver (Stage 09) is responsible for building this map from the app registry |
| Argo Workflow name too long | `<experiment-name>-<run-id>` exceeds 63 chars (K8s name limit) | Truncate experiment name to 40 chars: `fmt.Sprintf("%.40s-%s", def.Name, params.RunID)` |

---

## Rollback Procedure

```bash
rm -rf /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/experiment_hydrator/
```

No other files are modified in Stage 07.

---

## Success Criteria

Stage 07 is complete when:
- `go build ./pkg/experiment_hydrator/...` exits 0
- All step types produce correct Argo task structures in unit tests
- `Hydrate()` output is valid YAML (passes `yaml.Unmarshal`)
- `dependsOn` and parallel-fault fan-out produce the correct DAG topology

**Next Stage:** Stage 08 — Extended ExperimentRun Tracking
