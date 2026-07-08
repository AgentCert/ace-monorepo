# Experiment Definition Schema Reference

**Source:** Spec §11, §12, §13, §18  
**Date:** 2026-07-07

This document is the authoritative field reference for `experiment.yaml` files and the
`AceExperimentInput` GraphQL input type. It mirrors spec §11 and adds implementation notes.

---

## Top-Level Structure

```yaml
apiVersion: ace.io/v1
kind: ExperimentDefinition
metadata: { ... }
spec: { ... }
```

The YAML format is used when importing/exporting experiment definitions. The GraphQL API uses
`AceExperimentInput` for creation and `AceExperimentDefinition` for reads.

---

## Metadata Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `metadata.name` | string | Yes | Unique slug within a project. Kebab-case. Used as the lookup key in MongoDB and GraphQL queries. |
| `metadata.displayName` | string | No | Human-readable name shown in the Chaos Studio experiment list. |
| `metadata.version` | string | Auto | SemVer. Auto-set to `1.0.0` on creation. Auto-incremented on `updateExperiment`. |
| `metadata.tags` | []string | No | Freeform tags for filtering in `listExperiments`. |
| `metadata.author.name` | string | No | Name of the experiment creator. |
| `metadata.author.email` | string | No | Email of the experiment creator. |

---

## Spec Fields

### `spec.targetApp`

| Field | Type | Required | Description | Implementation Notes |
|-------|------|----------|-------------|---------------------|
| `spec.targetApp.name` | string | Yes | App name matching a `catalog/apps/` entry. | Validated against `apps_registry` at `submitRun` time. |
| `spec.targetApp.version` | string | Yes | SemVer range string, e.g. `">=1.0.0"`. | The hydrator selects the app chart version matching this range. |
| `spec.targetApp.installParams` | map | No | Key-value pairs overriding the app chart's default values. | Passed as `--set key=value` to `helm upgrade --install`. |

---

### `spec.hypothesis`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `spec.hypothesis` | string | No | Free-text statement of what the experiment is testing. Displayed in the experiment detail view. Useful for lab reports. |

---

### `spec.agentConstraints`

| Field | Type | Required | Description | Implementation Notes |
|-------|------|----------|-------------|---------------------|
| `spec.agentConstraints.requiredCapabilities` | []string | No | Capabilities the agent must have (from its `capabilities[]` in `agent_registry`). | Checked at `submitRun` time. If the selected agent lacks a required capability, `submitRun` returns a validation error. |
| `spec.agentConstraints.supportedAgents` | []string | No | If non-empty, only agents in this list can run this experiment. | An empty list means any compatible agent can run it. |
| `spec.agentConstraints.blockedAgents` | []string | No | Agents explicitly blocked from running this experiment. | Checked at `submitRun` time; returns error if selected agent is in this list. |

---

### `spec.modelSelection`

| Field | Type | Required | Description | Implementation Notes |
|-------|------|----------|-------------|---------------------|
| `spec.modelSelection.mode` | enum | Yes | `agent-default`, `fixed`, or `user-chooses-at-run` | Determines how the model is resolved at run time. |
| `spec.modelSelection.fixedModel` | string | Conditional | Required when `mode=fixed`. Model name, e.g. `"gpt-4o"`. | Must be in the agent's `allowedModels` list. Validated at `submitRun` time. |

**Mode resolution logic:**
1. `agent-default`: Use the model from the agent's saved Model Library config (`llmConfig.configRef → defaultModel`).
2. `fixed`: Use `fixedModel`. Validated against `agent.llmConfig.allowedModels`.
3. `user-chooses-at-run`: The run dialog shows a model picker. The selected model is passed as `modelOverride` in `submitRun`. Only valid when `agent.llmConfig.allowUserChoice: true`.

**modelUsed is always populated:** At run creation time, the resolved model is stored in `AceExperimentRunDoc.modelUsed` regardless of mode. It is never null in the run record.

---

### `spec.steps[]`

The step sequence is an ordered list. Steps execute sequentially unless `dependsOn` creates a
custom order or `parallel-fault` injects simultaneous execution.

#### Common fields (all step types)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Unique step name within the experiment. Kebab-case. Used in `dependsOn` references and per-step success criteria. |
| `type` | enum | Yes | `observe`, `fault`, `verify`, `wait`, or `parallel-fault`. |
| `description` | string | No | Human-readable description of the step's purpose. |

---

#### `type: observe`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `duration` | string | Yes | Duration string, e.g. `"30s"`, `"2m"`. The step is a sleep; no fault is injected. |

Argo implementation: `observe-tmpl` sleep container. No ChaosEngine created.

---

#### `type: fault`

| Field | Type | Required | Description | Implementation Notes |
|-------|------|----------|-------------|---------------------|
| `faultRef` | string | Yes | Name of a fault in the catalog. Validated against the fault catalog at `createExperiment` time. | |
| `target.microservice` | string | Yes (when `targetSpec.required=true`) | Name of the microservice to target, matching `app.yaml microservices[].name`. | Resolved to a K8s label selector at hydration time via the microservice map. |
| `params` | map | No | Parameter key-value pairs overriding the fault's defaults. | Validated against fault parameter types and bounds at hydration time. |
| `dependsOn` | string | No | Name of a preceding step that must complete before this step starts. | Rendered as `Dependencies` in the Argo DAG. If omitted, the step runs after the immediately preceding step. |
| `groundTruthOverride.detectWithinSecs` | int | No | Override the fault's default detection SLA for this step. | |
| `groundTruthOverride.mitigateWithinSecs` | int | No | Override the fault's default mitigation SLA for this step. | |

Argo implementation: `litmus-fault-tmpl` container that applies and then deletes the ChaosEngine.

---

#### `type: verify`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `probe.url` | string | Yes | Full URL of the HTTP health endpoint to probe. |
| `probe.expectedStatus` | int | Yes | Expected HTTP status code. Non-matching status fails the step and the run. |
| `probe.timeout` | string | No | Timeout per probe attempt. Default: `10s`. |
| `probe.retries` | int | No | Number of retries before declaring failure. Default: 3. |

Argo implementation: `http-probe-tmpl` using `curl`. A non-zero exit code fails the Argo task.

---

#### `type: wait`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `duration` | string | Yes | Duration to pause, e.g. `"45s"`. Useful for waiting for async events like alert firing. |

Argo implementation: same `observe-tmpl` sleep container as observe.

---

#### `type: parallel-fault`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `faults[].faultRef` | string | Yes | Fault catalog reference for each parallel fault. |
| `faults[].target.microservice` | string | Yes | Microservice for each parallel fault. |
| `faults[].params` | map | No | Per-fault parameter overrides. |

Argo implementation: DAG fan-out — one `litmus-fault-tmpl` task per entry in `faults[]`, all
with the same dependencies. The next sequential step depends on all fan-out tasks.

---

### `spec.successCriteria`

| Field | Type | Required | Description | Implementation Notes |
|-------|------|----------|-------------|---------------------|
| `spec.successCriteria.perStep[].stepName` | string | Yes | Name of the fault step these criteria apply to. | Must match a step `name` of type `fault` or `parallel-fault`. |
| `spec.successCriteria.perStep[].detectWithinSecs` | int | Yes | Detection SLA for this step. | Overrides `fault.groundTruth.detectWithinSecs`. Takes precedence over `groundTruthOverride` in the step itself (step-level `groundTruthOverride` takes precedence over catalog default; success criteria takes precedence over `groundTruthOverride`). |
| `spec.successCriteria.perStep[].mitigateWithinSecs` | int | Yes | Mitigation SLA for this step. | |
| `spec.successCriteria.overall.toolCallEfficiencyMin` | float | No | Minimum ratio of useful tool calls / total tool calls. Range: 0.0–1.0. | |
| `spec.successCriteria.overall.falsePositiveRateMax` | float | No | Maximum ratio of false detections / total detections. Range: 0.0–1.0. | |
| `spec.successCriteria.overall.rootCauseAccuracyMin` | float | No | Minimum ratio of correct root cause attributions / total fault steps. Range: 0.0–1.0. | |

---

### `spec.evaluationMetrics`

An array of metric names to include in the certifier report for this experiment.

| Metric Name | Description |
|-------------|-------------|
| `time_to_detect` | Elapsed time from fault injection start to agent's first detection event. |
| `time_to_mitigate` | Elapsed time from fault injection start to mitigation completion. |
| `tool_call_efficiency` | Ratio of tool calls that produced a useful signal to total tool calls. |
| `root_cause_accuracy` | Ratio of fault steps where the agent correctly identified the root cause. |
| `false_positive_rate` | Ratio of false detections (agent detected an incident when none existed) to total detections. |
| `blast_radius` | Number of unintended services affected during the experiment (measured post-fault). |

---

## Experiment Status Lifecycle

| Status | Trigger | Meaning |
|--------|---------|---------|
| `DRAFT` | Default on creation | Experiment saved but not validated as runnable. |
| `READY` | Updated by `updateExperiment` after all required fields are set | Experiment can create runs. |

Note: `DRAFT` and `READY` are statuses of the **definition**, not of a run. Run statuses are
`QUEUED`, `RUNNING`, `COMPLETED`, `FAILED`, `ABORTED`.

---

## Full Example

```yaml
apiVersion: ace.io/v1
kind: ExperimentDefinition

metadata:
  name: sock-shop-pod-failure-cascade
  displayName: "Sock Shop — Pod Failure Cascade"
  version: "1.0.0"
  tags: [availability, cascade, cloud-native]
  author:
    name: "Ujjwal Tiwari"
    email: "ujjwal@example.io"

spec:
  targetApp:
    name: sock-shop
    version: ">=1.0.0"
    installParams:
      replicaScale: "2"

  hypothesis: >
    The agent detects pod failure in the carts service within 60 seconds,
    correctly identifies the root cause as a pod availability event,
    and triggers a scale-up or alerts the on-call channel within 120 seconds.

  agentConstraints:
    requiredCapabilities: [prometheus-query, kubernetes-get-pods]
    supportedAgents: []
    blockedAgents: []

  modelSelection:
    mode: agent-default
    fixedModel: null

  steps:
    - name: baseline
      type: observe
      duration: 30s
      description: "Collect baseline metrics before any fault injection"

    - name: inject-carts-failure
      type: fault
      faultRef: pod-delete
      target:
        microservice: carts
      params:
        CHAOS_DURATION: "30"
        PODS_AFFECTED_PERC: "100"
      groundTruthOverride:
        detectWithinSecs: 45
        mitigateWithinSecs: 90

    - name: observe-recovery
      type: observe
      duration: 60s
      description: "Agent detects failure and acts"

    - name: inject-catalogue-cpu
      type: fault
      faultRef: cpu-hog
      target:
        microservice: catalogue
      params:
        CPU_CORES: "1"
        CHAOS_DURATION: "60"
      dependsOn: inject-carts-failure

    - name: final-observe
      type: observe
      duration: 30s

    - name: steady-state-check
      type: verify
      probe:
        url: "http://front-end.sock-shop.svc.cluster.local:80"
        expectedStatus: 200
        timeout: 10s
        retries: 3

  successCriteria:
    perStep:
      - stepName: inject-carts-failure
        detectWithinSecs: 45
        mitigateWithinSecs: 90
      - stepName: inject-catalogue-cpu
        detectWithinSecs: 60
        mitigateWithinSecs: 150
    overall:
      toolCallEfficiencyMin: 0.7
      falsePositiveRateMax: 0.1
      rootCauseAccuracyMin: 0.8

  evaluationMetrics:
    - time_to_detect
    - time_to_mitigate
    - tool_call_efficiency
    - root_cause_accuracy
    - false_positive_rate
    - blast_radius
```
