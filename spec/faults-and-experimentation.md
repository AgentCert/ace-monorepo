# ACE — Faults & Experimentation Specification

**Version:** 1.0  
**Status:** Draft  
**Scope:** Defines the fault catalog, fault onboarding, experiment schema, and experiment execution lifecycle in ACE.

---

## Table of Contents

1. [Purpose & Scope](#1-purpose--scope)
2. [Terminology](#2-terminology)
3. [Fault Taxonomy — Three Scopes](#3-fault-taxonomy--three-scopes)
4. [Fault Catalog Structure](#4-fault-catalog-structure)
5. [Fault Spec Schema — Complete Field Reference](#5-fault-spec-schema--complete-field-reference)
6. [Fault Implementation Types](#6-fault-implementation-types)
7. [Fault Parameters](#7-fault-parameters)
8. [Fault Ground Truth](#8-fault-ground-truth)
9. [Fault Onboarding — Contribution Flow](#9-fault-onboarding--contribution-flow)
10. [Fault Compatibility & App Declarations](#10-fault-compatibility--app-declarations)
11. [Experiment Definition Schema](#11-experiment-definition-schema)
12. [Experiment Step Types](#12-experiment-step-types)
13. [Multi-Fault Patterns](#13-multi-fault-patterns)
14. [Experiment Execution Lifecycle](#14-experiment-execution-lifecycle)
15. [Argo Workflow Generation](#15-argo-workflow-generation)
16. [Experiment Run vs Experiment Definition](#16-experiment-run-vs-experiment-definition)
17. [Chaos Studio — Experiment Builder UX](#17-chaos-studio--experiment-builder-ux)
18. [Success Criteria & Scoring Hooks](#18-success-criteria--scoring-hooks)
19. [GraphQL API](#19-graphql-api)
20. [K8s Resources Created Per Run](#20-k8s-resources-created-per-run)
21. [Error States & Handling](#21-error-states--handling)
22. [Security Considerations](#22-security-considerations)
23. [Forward Compatibility](#23-forward-compatibility)

---

## 1. Purpose & Scope

An ACE experiment puts an AI agent under controlled stress inside a realistic application environment. The stress is applied via **faults** — precisely defined, reproducible disruptions that model the conditions an agent must handle in the real world.

This specification defines:

- The three-tier fault taxonomy (general, domain-specific, app-specific) and why the distinction matters
- The complete `fault.yaml` schema and every field within it
- How new faults are onboarded — both by the ACE team and by community contributors
- The complete `experiment.yaml` schema and every step type
- How experiments are executed — from Argo Workflow generation through certifier handoff
- Every UI flow in Chaos Studio for building experiments

**What this spec does NOT cover:**
- App onboarding (App Onboarding spec)
- Agent onboarding (Agent Onboarding spec)
- Certifier scoring pipeline internals

---

## 2. Terminology

| Term | Definition |
|------|-----------|
| **Fault** | A precise, reproducible disruption injected into an app environment (e.g., kill a pod, saturate CPU, inject HTTP 503s) |
| **Fault Catalog** | The registry of all available faults in ACE, organized by scope |
| **Fault Spec** | The `fault.yaml` file that describes a fault — its parameters, implementation, and ground truth |
| **Experiment Definition** | The reusable blueprint declaring which app, which agent, and which fault sequence to run — the `experiment.yaml` |
| **Experiment Run** | One execution instance of an experiment definition — has a unique run ID, timestamp, and result |
| **Chaos Step** | A single fault injection within an experiment's step sequence |
| **Observe Step** | A quiet window within an experiment during which the agent's behavior is recorded without active fault injection |
| **Ground Truth** | The declared expected behavior per fault — used by the certifier to score detection accuracy |
| **Scope** | Whether a fault is general (any app), domain-specific (any app in a domain), or app-specific (only one app) |
| **Argo Workflow** | The Kubernetes job that runs one experiment end-to-end |
| **ChaosEngine** | The LitmusChaos Kubernetes CRD that triggers a single fault |
| **Hydration** | Converting an `experiment.yaml` into a concrete Argo Workflow YAML |

---

## 3. Fault Taxonomy — Three Scopes

Every fault in ACE belongs to exactly one scope. Scope determines where the fault lives in the catalog, who can use it, and what apps it is compatible with.

### Scope 1 — General Faults

Applicable to any app regardless of domain. These are infrastructure-level disruptions that any app running on Kubernetes may encounter.

**Examples:** `pod-delete`, `cpu-hog`, `memory-hog`, `network-latency`, `disk-fill`, `node-drain`, `pod-network-loss`

**Source:** Primarily from LitmusChaos Hub (auto-synced) plus ACE-authored general faults.

**Rule:** A general fault must not assume anything about the app's internals. It targets resources by Kubernetes labels, not by service names.

---

### Scope 2 — Domain-Specific Faults

Applicable to any app within a specific domain. These model conditions that are normal operational failures in that domain but not meaningful outside it.

| Domain | Example Faults |
|---|---|
| `cloud-native` | pod-oom-kill, hpa-disable, service-mesh-inject-fault, config-map-corrupt |
| `telecom` | snmp-trap-flood, bgp-route-withdraw, netconf-session-drop, pm-counter-zeroing |
| `health-it` | fhir-endpoint-timeout, hl7-message-corrupt, ehr-db-connection-drop |
| `finops` | cost-api-throttle, budget-alert-suppress, billing-export-delay |
| `itops` | cmdb-sync-failure, monitoring-agent-kill, runbook-api-timeout |

**Source:** ACE-authored or community-contributed. Live in `catalog/faults/domains/<domain>/`.

---

### Scope 3 — App-Specific Faults

Applicable only to one named app. These model disruptions that are meaningful only given that app's architecture — specific service names, specific failure modes, specific alert patterns.

**Examples:**
- `sock-shop` → `carts-db-corrupt` (corrupts the MongoDB instance that backs the carts service)
- `otel-demo` → `payment-service-latency` (injects 3s delay on the payment gRPC endpoint)
- `bookinfo` → `ratings-service-abort` (makes ratings return HTTP 500 for 50% of requests)

**Source:** Defined by the app contributor inside the app's chart folder. Shipped as part of the app's catalog PR.

**Location in repo:** `catalog/apps/<app-name>/faults/<fault-name>/fault.yaml`

---

### Why Three Scopes Matter

When a user opens Chaos Studio with Sock Shop selected as the target app, the fault picker shows:
1. All **general** faults
2. All **cloud-native domain** faults (because Sock Shop declares `domain: cloud-native`)
3. All **sock-shop app-specific** faults

It does not show telecom or health-IT faults — those would be meaningless against Sock Shop. This filtering is automatic and driven by the app's `domain` and `capabilityDomains` fields, without any manual maintenance.

---

## 4. Fault Catalog Structure

```
catalog/
└── faults/
    ├── general/
    │   ├── pod-delete/
    │   │   └── fault.yaml
    │   ├── cpu-hog/
    │   │   └── fault.yaml
    │   ├── memory-hog/
    │   │   └── fault.yaml
    │   ├── network-latency/
    │   │   └── fault.yaml
    │   └── node-drain/
    │       └── fault.yaml
    │
    ├── domains/
    │   ├── cloud-native/
    │   │   ├── pod-oom-kill/
    │   │   │   └── fault.yaml
    │   │   ├── hpa-disable/
    │   │   │   └── fault.yaml
    │   │   └── config-map-corrupt/
    │   │       └── fault.yaml
    │   │
    │   ├── telecom/
    │   │   ├── snmp-trap-flood/
    │   │   │   └── fault.yaml
    │   │   └── bgp-route-withdraw/
    │   │       └── fault.yaml
    │   │
    │   ├── health-it/
    │   │   └── fhir-endpoint-timeout/
    │   │       └── fault.yaml
    │   │
    │   ├── finops/
    │   │   └── cost-api-throttle/
    │   │       └── fault.yaml
    │   │
    │   └── itops/
    │       └── cmdb-sync-failure/
    │           └── fault.yaml
    │
    └── (app-specific faults live under their app's folder)

catalog/
└── apps/
    └── sock-shop/
        ├── app.yaml
        ├── chart/
        └── faults/
            ├── carts-db-corrupt/
            │   └── fault.yaml
            └── payment-service-abort/
                └── fault.yaml
```

---

## 5. Fault Spec Schema — Complete Field Reference

```yaml
apiVersion: ace.io/v1
kind: FaultCatalogEntry

metadata:
  name: pod-delete                         # Unique slug, kebab-case
  displayName: "Pod Delete"                # Human-readable name shown in UI
  version: "1.0.0"                         # SemVer
  tier: official                           # official | community
  scope: general                           # general | domain | app-specific
  domain: null                             # null for general; "cloud-native" for domain;
                                           #   "<app-name>" for app-specific
  targetApp: null                          # null unless scope=app-specific
  tags: [resilience, availability]
  maintainers:
    - name: "ACE Team"
      email: "ace@example.io"

spec:

  # ── Description ──────────────────────────────────────────────────────────────
  description:
    short: "Forcefully deletes one or more target pods"
    long: |
      Injects pod failure by deleting the target pod(s). Kubernetes reschedules
      them. Used to test auto-recovery, readiness probe behavior, and the agent's
      ability to detect pod churn and verify recovery.
    suitableFor:
      - "Stateless services with Kubernetes Deployments"
      - "Testing agent detection of pod unavailability"
    notSuitableFor:
      - "StatefulSets where pod identity matters without PVC snapshot support"

  # ── Implementation ────────────────────────────────────────────────────────────
  implementation:
    type: litmus                           # litmus | http-fault | script | external
    chaosKind: ChaosEngine                 # LitmusChaos CRD kind (litmus type only)
    experimentRef: pod-delete              # ChaosExperiment resource name (litmus type)
    namespace: litmus                      # Namespace where ChaosEngine is created

  # ── Target Resolution ─────────────────────────────────────────────────────────
  targetSpec:
    required: true
    resolutionMode: microservice-label     # microservice-label | explicit-pod | node | all-pods
    # microservice-label: The app's microservice map is used to resolve the K8s label selector
    # explicit-pod:       A specific pod name is provided in the experiment
    # node:               Targets a node, not a pod
    # all-pods:           Targets all pods matching a namespace label

  # ── Parameters ────────────────────────────────────────────────────────────────
  parameters:
    - key: CHAOS_DURATION
      displayName: "Chaos Duration"
      type: integer
      unit: seconds
      default: "30"
      min: 10
      max: 600
      required: true
      description: "How long the chaos lasts. Pod is deleted; this is the observation window."
      litmusEnv: TOTAL_CHAOS_DURATION      # Maps to LitmusChaos ENV var

    - key: PODS_AFFECTED_PERC
      displayName: "% Pods Affected"
      type: integer
      unit: percent
      default: "50"
      min: 1
      max: 100
      required: false
      description: "What percentage of matching pods to delete."
      litmusEnv: PODS_AFFECTED_PERC

    - key: FORCE_DELETE
      displayName: "Force Delete"
      type: boolean
      default: "false"
      required: false
      description: "Skip graceful termination (SIGTERM) and force-kill immediately."
      litmusEnv: FORCE

  # ── Compatibility ──────────────────────────────────────────────────────────────
  compatibility:
    targetDomains: [cloud-native]          # Domains this fault applies to. [*] means all.
    incompatibleApps: []                   # Named apps this fault should NOT be shown for.
    requiredCapabilities: []               # Agent capabilities needed to meaningfully detect this fault.
                                           # This filters the agent catalog, not blocks execution.

  # ── Observability ──────────────────────────────────────────────────────────────
  observability:
    expectedSymptoms:
      - "Target pod transitions to Terminating state"
      - "Deployment ReplicaSet creates a replacement pod"
      - "HTTP 503 or connection refused on target service during transition"
    expectedAlerts:
      - KubePodNotReady
      - KubeDeploymentReplicasMismatch
    detectionWindowSecs: 60               # Expected time for symptoms to become observable

  # ── Ground Truth ───────────────────────────────────────────────────────────────
  groundTruth:
    category: availability                 # availability | performance | security |
                                           #   data-integrity | configuration
    impact: high                           # low | medium | high | critical
    detectWithinSecs: 60                   # Default detection SLA for scoring
    mitigateWithinSecs: 120                # Default mitigation SLA for scoring
    detectionHints:
      - "kubectl get pods -n <app-ns>: count drops then recovers"
      - "Prometheus: kube_pod_status_ready drops to 0 for target"
    remediationHints:
      - "Verify Deployment replicas are restored"
      - "Check that HPA is not preventing scale-up"
```

---

## 6. Fault Implementation Types

ACE supports four fault implementation types. The `implementation.type` field in `fault.yaml` determines how the fault is executed at workflow runtime.

### `litmus`

Uses an existing LitmusChaos `ChaosExperiment` CRD. ACE creates a `ChaosEngine` in the `litmus` namespace pointing to the referenced experiment. This is the default for cloud-native faults.

**When to use:** Any fault that LitmusChaos Hub already provides (pod-delete, cpu-hog, network-latency, etc.) or that can be expressed as a LitmusChaos experiment.

```yaml
implementation:
  type: litmus
  chaosKind: ChaosEngine
  experimentRef: pod-delete
  namespace: litmus
```

---

### `http-fault`

Injects HTTP-level failures using a sidecar or service mesh injection (Envoy filter, Istio VirtualService, or a purpose-built HTTP proxy). Used for faults that target API behavior rather than infrastructure.

**When to use:** Inject error codes, timeouts, or response corruption into a specific service endpoint — regardless of whether a service mesh is present (ACE can deploy a sidecar proxy if needed).

```yaml
implementation:
  type: http-fault
  target:
    service: payment-service
    port: 8080
    path: "/pay"
  inject:
    type: abort                            # abort | delay | corrupt
    errorCode: 503
    percentage: 50
    duration: 60s
```

---

### `script`

Runs a one-shot Kubernetes Job that executes a custom fault script. The script is bundled with the fault definition.

**When to use:** Faults that require domain-specific tooling — e.g., sending an SNMP trap flood, corrupting a MongoDB document, sending an HL7 message with a malformed segment.

```yaml
implementation:
  type: script
  image: "myorg/snmp-fault-injector:1.0.0"
  command: ["/inject.sh"]
  args: ["--target=192.168.1.1", "--duration=30"]
  envFrom:
    - configMapRef: fault-config
```

---

### `external`

Calls an external API to trigger a fault — useful when the target system is not Kubernetes (e.g., a physical network element, a cloud provider API, a SaaS billing API).

**When to use:** Domain faults where the target is outside the cluster — telecom NF, cloud billing, external monitoring API.

```yaml
implementation:
  type: external
  endpoint: "http://{{.AppNamespace}}-fault-proxy.svc/inject"
  method: POST
  body:
    faultType: bgp-route-withdraw
    targetRouter: "{{.params.TARGET_ROUTER}}"
    duration: "{{.params.CHAOS_DURATION}}"
  waitForCompletion: true
```

---

## 7. Fault Parameters

Every fault declares its configurable parameters in the `spec.parameters[]` array. These parameters appear as form fields in the Chaos Studio experiment builder when the fault is added to an experiment step.

### Parameter Types

| Type | Values | Example |
|---|---|---|
| `integer` | Numeric value with optional min/max/unit | `CHAOS_DURATION: 30` |
| `string` | Free text | `TARGET_POD_NAME: "carts-abc"` |
| `boolean` | true/false toggle | `FORCE_DELETE: false` |
| `enum` | Fixed list of allowed values | `INJECT_TYPE: [abort, delay, corrupt]` |
| `percent` | Integer 0–100 | `PODS_AFFECTED_PERC: 50` |

### Parameter Binding

When an experiment step sets a fault parameter, the value flows as:

1. **Static binding** — value fixed in `experiment.yaml` at experiment creation time
2. **Dynamic override** — value overridden at run time via the Run dialog
3. **Default** — value from `fault.yaml` default if neither above is set

At workflow hydration time, parameter values are rendered into the `ChaosEngine` spec (for litmus type) or passed as environment variables (for script type).

---

## 8. Fault Ground Truth

Ground truth is the machine-readable declaration of what **should happen** when this fault is injected — what alerts should fire, what the agent should detect, and within what time window.

The certifier reads ground truth to:
- Verify whether the agent's detection event matches expected symptoms
- Score time_to_detect against `detectWithinSecs`
- Score time_to_mitigate against `mitigateWithinSecs`
- Compute root_cause_accuracy by comparing agent's attributed cause to `category`

```yaml
groundTruth:
  category: availability
  impact: high
  detectWithinSecs: 60
  mitigateWithinSecs: 120
  detectionHints:
    - "kubectl get pods -n <app-ns>: count drops then recovers"
    - "Prometheus: kube_pod_status_ready drops to 0 for target"
  remediationHints:
    - "Verify Deployment replicas are restored"
    - "Check HPA is not suppressing scale-up"
```

Ground truth fields are **per-fault defaults**. An experiment definition can override `detectWithinSecs` and `mitigateWithinSecs` per step to tighten or relax the scoring window based on context.

---

## 9. Fault Onboarding — Contribution Flow

### 9.1 When Is a New Fault Needed?

A new fault is needed when:
- An existing fault doesn't model the failure condition the contributor wants to test
- A new app is being contributed and has app-specific failure modes
- A new domain is being added and no domain-specific faults exist yet

Before contributing a fault, contributors should search the fault catalog (general, domain, and any app-specific lists) to avoid duplicates.

---

### 9.2 Path A — General or Domain Fault Contribution

**Where it lives:** `catalog/faults/general/<fault-name>/` or `catalog/faults/domains/<domain>/<fault-name>/`

**Steps:**

1. **Fork the ACE monorepo and create a feature branch**
   ```
   git checkout -b fault/add-snmp-trap-flood
   ```

2. **Create the fault directory and write `fault.yaml`**
   Follow the schema in §5. Pay particular attention to:
   - `scope` and `domain` must be correct
   - `implementation.type` chosen correctly for the mechanism
   - `groundTruth` filled in as completely as possible — this is what scores the agent

3. **If `type: litmus`** — verify the referenced `experimentRef` exists in the LitmusChaos Hub or is bundled as a `ChaosExperiment` YAML in the same directory:
   ```
   catalog/faults/domains/cloud-native/pod-oom-kill/
   ├── fault.yaml
   └── chaos-experiment.yaml     ← only if not in LitmusChaos Hub
   ```

4. **If `type: script`** — include the script and Dockerfile:
   ```
   catalog/faults/domains/telecom/snmp-trap-flood/
   ├── fault.yaml
   ├── inject.sh
   └── Dockerfile
   ```

5. **Dry-run validation**
   ```bash
   ace fault validate catalog/faults/domains/telecom/snmp-trap-flood/fault.yaml
   ```
   This checks schema correctness, required fields, and that `experimentRef` resolves (for litmus type).

6. **Open a PR** — the ACE CI pipeline runs:
   - Schema validation
   - Litmus experiment resolution check
   - Duplicate detection against existing fault names

---

### 9.3 Path B — App-Specific Fault Contribution

App-specific faults are contributed **as part of the app's catalog PR** — they live under the app's chart folder and are reviewed alongside the app itself.

```
catalog/apps/sock-shop/
├── app.yaml
├── chart/
│   └── ...
└── faults/
    ├── carts-db-corrupt/
    │   └── fault.yaml
    └── payment-abort/
        └── fault.yaml
```

The `app.yaml` must reference all its app-specific faults:
```yaml
spec:
  faultCatalog:
    - carts-db-corrupt
    - payment-abort
```

Without this declaration, the faults will not appear in Chaos Studio when this app is selected.

---

### 9.4 Fault Review Criteria

ACE maintainers review fault PRs against these criteria:

| Criterion | Check |
|---|---|
| Reproducibility | Fault can be injected and cleaned up deterministically |
| Scope correctness | Scope/domain declaration matches actual applicability |
| Ground truth completeness | `detectionHints` and `remediationHints` are meaningful |
| Parameter safety | No parameter can trigger destructive side effects outside the experiment namespace |
| Cleanup | Fault cleans up after itself (no dangling K8s resources) |
| Unique name | No existing fault with the same name in the same scope |

---

## 10. Fault Compatibility & App Declarations

### 10.1 How Faults Appear in Chaos Studio

When a user selects an app in the experiment builder, Chaos Studio fetches available faults by:

1. All `scope: general` faults
2. All `scope: domain` faults where `fault.domain == app.metadata.domain`
3. All `scope: app-specific` faults where `fault.targetApp == app.metadata.name`
4. Exclude any fault in `fault.compatibility.incompatibleApps[]` for this app

The app's `capabilityDomains[]` also determines which domain faults are shown — an app that declares `capabilityDomains: [cloud-native, common]` will not show telecom domain faults even if the overall platform supports telecom.

### 10.2 App-Side Fault Compatibility Declaration

Apps declare fault compatibility in `app.yaml` under `spec.faultCompatibility[]`:

```yaml
spec:
  faultCompatibility:
    - faultName: pod-delete
      compatible: true
      notes: "All stateless deployments support this. Carts-db (MongoDB) should be avoided."
    - faultName: node-drain
      compatible: true
    - faultName: carts-db-corrupt
      compatible: true         # App-specific, always true
    - faultName: hpa-disable
      compatible: false
      notes: "App does not use HPA in the default install."
```

This is advisory — it surfaces notes in the Chaos Studio UI but does not block execution. A `compatible: false` fault shows a warning, not a hard block.

---

## 11. Experiment Definition Schema

An experiment definition is reusable. Multiple runs can be created from the same definition with the same or different agents.

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

  # ── Target App ─────────────────────────────────────────────────────────────────
  targetApp:
    name: sock-shop
    version: ">=1.0.0"
    installParams:                         # Overrides app.yaml defaults for this experiment
      replicaScale: 2

  # ── Hypothesis ─────────────────────────────────────────────────────────────────
  hypothesis: >
    The agent detects pod failure in the carts service within 60 seconds,
    correctly identifies the root cause as a pod availability event,
    and triggers a scale-up or alerts the on-call channel within 120 seconds.

  # ── Agent Slot ─────────────────────────────────────────────────────────────────
  # The agent to use is specified at run time, not in the definition.
  # This block declares which agents are compatible.
  agentConstraints:
    requiredCapabilities: [prometheus-query, kubernetes-get-pods]
    supportedAgents: []                    # Empty means any compatible agent
    blockedAgents: []

  # ── Model Selection ───────────────────────────────────────────────────────────
  # Controls which LLM model the agent uses for this experiment.
  # Only relevant when the registered agent has llmConfig.allowUserChoice: true.
  # When allowUserChoice: false, the agent's saved Model Library config is used automatically.
  modelSelection:
    mode: agent-default                    # agent-default | fixed | user-chooses-at-run
    # agent-default: use whatever model the agent's llmConfig.configRef points to
    # fixed:         this experiment always uses the specified model (must be in agent's allowedModels)
    # user-chooses-at-run: the run dialog shows a model picker for this experiment
    fixedModel: null                       # set when mode=fixed, e.g. "gpt-4o-mini"

  # ── Steps ──────────────────────────────────────────────────────────────────────
  steps:

    - name: baseline
      type: observe
      duration: 30s
      description: "Collect baseline metrics before any fault injection"

    - name: inject-carts-failure
      type: fault
      faultRef: pod-delete
      target:
        microservice: carts               # Resolved via app.yaml microservices[].name
      params:
        CHAOS_DURATION: "30"
        PODS_AFFECTED_PERC: "100"
      groundTruthOverride:                # Override fault.yaml defaults for this step
        detectWithinSecs: 45
        mitigateWithinSecs: 90

    - name: observe-recovery
      type: observe
      duration: 60s
      description: "Agent detects failure and acts. Observe tool calls and alerts."

    - name: inject-catalogue-cpu
      type: fault
      faultRef: cpu-hog
      target:
        microservice: catalogue
      params:
        CPU_CORES: "1"
        CHAOS_DURATION: "60"
      dependsOn: inject-carts-failure     # This step starts only after inject-carts-failure completes

    - name: final-observe
      type: observe
      duration: 30s
      description: "Confirm system returns to healthy baseline"

    - name: steady-state-check
      type: verify
      probe:
        url: "http://front-end.sock-shop.svc.cluster.local:80"
        expectedStatus: 200
      description: "Assert the app is healthy at experiment end"

  # ── Success Criteria ───────────────────────────────────────────────────────────
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

  # ── Evaluation Metrics ─────────────────────────────────────────────────────────
  evaluationMetrics:
    - time_to_detect
    - time_to_mitigate
    - tool_call_efficiency
    - root_cause_accuracy
    - false_positive_rate
    - blast_radius
```

---

## 12. Experiment Step Types

### `observe`

A quiet window with no active fault injection. The app runs normally. Captures baseline signals or monitors post-fault recovery behavior.

```yaml
- name: baseline
  type: observe
  duration: 30s
  description: "Baseline window before fault injection"
```

No K8s resources are created for this step. The Argo Workflow step is a `sleep` container that waits for `duration`.

---

### `fault`

Injects a single fault for a declared duration. The step:
1. Creates a `ChaosEngine` CR in the `litmus` namespace (for litmus type)
2. Waits for `CHAOS_DURATION` seconds
3. Deletes the `ChaosEngine` (LitmusChaos cleans up automatically)

```yaml
- name: inject-carts-failure
  type: fault
  faultRef: pod-delete
  target:
    microservice: carts
  params:
    CHAOS_DURATION: "30"
    PODS_AFFECTED_PERC: "100"
```

---

### `verify`

Runs an HTTP health probe or a custom check against the app and fails the experiment if the check does not pass. Used for steady-state verification before and after fault injection.

```yaml
- name: steady-state-check
  type: verify
  probe:
    url: "http://front-end.sock-shop.svc.cluster.local:80"
    expectedStatus: 200
    timeout: 10s
    retries: 3
```

---

### `wait`

Pauses the experiment for a fixed duration or until an external signal. Useful for experiments that need to wait for async behavior (e.g., wait for an alert to fire).

```yaml
- name: wait-for-alert
  type: wait
  duration: 45s
  description: "Allow time for Prometheus alert to fire before resuming"
```

---

### `parallel-fault` *(Multi-fault)*

Injects multiple faults simultaneously. All listed faults start at the same moment and run for their declared durations independently.

```yaml
- name: cascade-failure
  type: parallel-fault
  faults:
    - faultRef: pod-delete
      target:
        microservice: carts
      params:
        CHAOS_DURATION: "30"
    - faultRef: cpu-hog
      target:
        microservice: catalogue
      params:
        CPU_CORES: "1"
        CHAOS_DURATION: "60"
```

See §13 for full multi-fault patterns.

---

## 13. Multi-Fault Patterns

### Pattern A — Sequential (default)

Faults run one after another. Use `dependsOn` to declare order. The next fault starts only after the previous one completes and its ChaosEngine is cleaned up.

```
time →
[observe-baseline] → [inject-carts-delete] → [observe-recovery] → [inject-catalogue-cpu] → [final-observe]
```

Best for: Testing agent's ability to handle multiple independent incidents sequentially.

---

### Pattern B — Parallel

Multiple faults injected simultaneously. Modeled as a `parallel-fault` step.

```
time →
[observe-baseline] → [inject-carts-delete + inject-catalogue-cpu simultaneously] → [observe-recovery]
```

Best for: Testing agent's ability to triage multiple concurrent incidents — prioritize, not panic.

---

### Pattern C — Cascading (sequential with causal dependency)

Fault B is injected because Fault A was not mitigated within the detection window. This is declared using `onDetectionFailure`.

```yaml
- name: inject-primary
  type: fault
  faultRef: pod-delete
  target:
    microservice: carts
  params:
    CHAOS_DURATION: "60"
  onDetectionFailure:
    action: inject-secondary    # If agent fails to detect within detectWithinSecs, escalate
    faultRef: memory-hog
    target:
      microservice: carts
    params:
      MEMORY_CONSUMPTION: "500"
```

Best for: Modeling realistic escalation scenarios where inaction leads to compounding failure.

---

### Pattern D — Conditional (agent-response-driven)

The experiment step sequence adapts based on what the agent does. If the agent correctly mitigates Fault A, Fault B is skipped; otherwise, Fault B fires.

> **Note:** This is a Phase 2 feature. The Argo Workflow will need to read agent action signals from the certifier API to implement conditional branching. Declared in the spec now for forward compatibility.

```yaml
- name: inject-primary
  type: fault
  faultRef: pod-delete
  ...
  onMitigationSuccess:
    skip: [inject-secondary]    # Skip the escalation if agent mitigated correctly
  onMitigationFailure:
    run: inject-secondary
```

---

## 14. Experiment Execution Lifecycle

### States

```
DRAFT → READY → QUEUED → RUNNING → COMPLETED
                                  → FAILED
                                  → ABORTED
```

| State | Meaning |
|---|---|
| `DRAFT` | Experiment definition is being built in Chaos Studio — not yet submitted |
| `READY` | Experiment definition is saved and valid — ready to create a run |
| `QUEUED` | Run has been submitted; waiting for cluster capacity |
| `RUNNING` | Argo Workflow is actively executing |
| `COMPLETED` | All steps finished; certifier has results |
| `FAILED` | A step failed (app health probe failed, fault injection error) |
| `ABORTED` | User manually stopped the run |

---

### Execution Steps (within a Run)

```
1. Pre-flight checks
   ├── Validate experiment.yaml schema
   ├── Resolve all faultRef names → fault.yaml entries
   ├── Resolve target microservice names → K8s label selectors (from app.yaml)
   └── Validate agent is installed and reachable

2. App Install
   ├── helm upgrade --install <app> <chart> -n <namespace> --wait
   └── Health probe: GET app healthCheck URL → must return expectedStatus

3. Load Test Start (if app defines loadTest)
   └── Deploy load generator Job

4. Agent Install
   ├── helm upgrade --install <agent> <chart> --set <contextInjection vars>
   └── Wait for agent pod to be Running

5. Baseline observe window (if step type=observe at start)

6. Fault Steps (per step in order)
   ├── [type=fault]   → Create ChaosEngine CR → wait CHAOS_DURATION → delete
   ├── [type=observe] → sleep duration
   ├── [type=verify]  → HTTP probe → fail run on non-2xx
   └── [type=wait]    → sleep duration

7. Post-experiment verify (steady-state check if declared)

8. Teardown
   ├── helm uninstall agent
   ├── helm uninstall app
   ├── Delete load test Job
   └── Delete ChaosEngine CRs (cleanup, in case of partial failure)

9. Certifier Handoff
   └── Record run completion event with Langfuse trace ID → certifier picks up
```

---

## 15. Argo Workflow Generation

The experiment definition is **hydrated** into an Argo Workflow YAML at run submission time. Hydration is done by the GraphQL server.

### Hydration Inputs

- `experiment.yaml` — the definition
- `agent.yaml` — resolved agent spec (for context injection)
- Run parameters — agent secrets, dynamic overrides
- Platform context — `workflow.name`, `workflow.uid`, `litellmUpstream`

### Generated Workflow Structure

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: "sock-shop-pod-failure-cascade-{{run-id}}"
  namespace: litmus
spec:
  entrypoint: experiment-dag
  arguments:
    parameters:
      - name: litellmUpstream
        value: "http://litellm.litmus.svc.cluster.local:4000"
      - name: appNamespace
        value: "sock-shop-{{run-id}}"

  templates:
    - name: experiment-dag
      dag:
        tasks:
          - name: install-app
            template: install-app-tmpl

          - name: install-agent
            template: install-agent-tmpl
            dependencies: [install-app]

          - name: step-baseline
            template: observe-tmpl
            arguments:
              parameters: [{name: duration, value: "30s"}]
            dependencies: [install-agent]

          - name: step-inject-carts-failure
            template: litmus-fault-tmpl
            arguments:
              parameters:
                - {name: chaosEngineYaml, value: "...rendered ChaosEngine YAML..."}
            dependencies: [step-baseline]

          - name: step-observe-recovery
            template: observe-tmpl
            arguments:
              parameters: [{name: duration, value: "60s"}]
            dependencies: [step-inject-carts-failure]

          - name: teardown
            template: teardown-tmpl
            dependencies: [step-observe-recovery]
```

### ChaosEngine Rendering

For each `type: fault` step, the hydrator renders a `ChaosEngine` YAML:

```yaml
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: "inject-carts-failure-{{run-id}}"
  namespace: litmus
spec:
  appinfo:
    appns: "sock-shop-{{run-id}}"
    applabel: "name=carts"           # Resolved from app.yaml microservices[name=carts].k8s.label
    appkind: deployment
  chaosServiceAccount: litmus-admin
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: "30"
            - name: PODS_AFFECTED_PERC
              value: "100"
            - name: FORCE
              value: "false"
```

---

## 16. Experiment Run vs Experiment Definition

These are two distinct objects in ACE.

### Experiment Definition

- Reusable
- Stores the structural blueprint (app, steps, success criteria, evaluation metrics)
- Does NOT store secrets or the specific agent
- Can be shared, published to catalog, forked
- Has a version; changes increment the version

### Experiment Run

- One-time execution record
- Created from a definition by selecting an agent and filling in any required secrets
- Stores: run ID, timestamp, agent version used, definition version used, Langfuse trace ID, run status, certifier report ID
- Immutable after completion — a run record is never edited

```
ExperimentDefinition "sock-shop-pod-failure-cascade" v1.0.0
  └── Run #001  agent=flash-agent:1.0.0  model=gpt-4o            result=CERTIFIED   trace=abc123
  └── Run #002  agent=flash-agent:1.0.0  model=gpt-4o            result=FAILED      trace=def456
  └── Run #003  agent=flash-agent:1.0.0  model=claude-3-5-sonnet result=CERTIFIED   trace=jkl012
  └── Run #004  agent=rival-agent:2.0.0  model=gpt-4o            result=CERTIFIED   trace=ghi789
```

Multiple agents — and multiple models for the same agent — can be evaluated against the same definition. This is how ACE produces comparative leaderboards across both agents and models.

**Model stored per run:** When `modelSelection.mode` is `user-chooses-at-run` or `fixed`, the model name is stored as `ExperimentRun.modelUsed`. When `mode` is `agent-default`, `modelUsed` stores the resolved model from the agent's Model Library config at run time. The model is always recorded — never null — so certifier reports can include it.

---

## 17. Chaos Studio — Experiment Builder UX

### Screen 1 — Select App

```
┌───────────────────────────────────────────────────────────────────────────┐
│  New Experiment                                                            │
│                                                                           │
│  Step 1 of 4: Select Application                                          │
│                                                                           │
│  Filter: [All Domains ▼]  [Official ▼]  [Search apps...]                 │
│                                                                           │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌───────────────────┐ │
│  │ Sock Shop           │  │ OTel Demo           │  │ Bookinfo          │ │
│  │ cloud-native        │  │ cloud-native        │  │ cloud-native      │ │
│  │ ★ Official          │  │ ★ Official          │  │ ★ Official        │ │
│  │ 12 faults available │  │ 9 faults available  │  │ 7 faults available│ │
│  │ [Select]            │  │ [Select]            │  │ [Select]          │ │
│  └─────────────────────┘  └─────────────────────┘  └───────────────────┘ │
│                                                                           │
│  ┌─────────────────────┐                                                  │
│  │ + Contribute App    │                                                  │
│  │ Your domain missing?│                                                  │
│  └─────────────────────┘                                                  │
└───────────────────────────────────────────────────────────────────────────┘
```

Selecting an app locks in the domain filter for subsequent screens.

---

### Screen 2 — Select Agent

```
┌───────────────────────────────────────────────────────────────────────────┐
│  Step 2 of 4: Select Agent                                                │
│                                                                           │
│  App: Sock Shop (cloud-native)                                            │
│  Showing agents compatible with this app's domain                         │
│                                                                           │
│  ┌──────────────────────────────────────────────────┐                    │
│  │ Flash Agent v1.0.0          capabilities: 4      │                    │
│  │ react-loop · llm-dependent  ✓ Compatible         │ [Select]           │
│  └──────────────────────────────────────────────────┘                    │
│                                                                           │
│  ┌──────────────────────────────────────────────────┐                    │
│  │ Rival Agent v2.0.0          capabilities: 6      │                    │
│  │ plan-and-execute · llm-dependent  ✓ Compatible   │ [Select]           │
│  └──────────────────────────────────────────────────┘                    │
│                                                                           │
│  [+ Register a New Agent]                                                 │
└───────────────────────────────────────────────────────────────────────────┘
```

---

### Screen 3 — Build Fault Sequence (Chaos Studio Canvas)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Step 3 of 4: Build Experiment                                              │
│                                                                             │
│  App: Sock Shop  |  Agent: Flash Agent                                      │
│                                                                             │
│  Fault Library (drag to canvas)           Canvas                           │
│  ┌───────────────────────┐    ┌──────────────────────────────────────────┐ │
│  │ GENERAL               │    │                                          │ │
│  │  ○ pod-delete         │    │  [observe 30s] → [pod-delete: carts]    │ │
│  │  ○ cpu-hog            │    │                      ↓                  │ │
│  │  ○ memory-hog         │    │              [observe 60s]              │ │
│  │  ○ network-latency    │    │                      ↓                  │ │
│  │                       │    │         [cpu-hog: catalogue]            │ │
│  │ CLOUD-NATIVE          │    │                      ↓                  │ │
│  │  ○ pod-oom-kill       │    │              [verify: front-end 200]    │ │
│  │  ○ hpa-disable        │    │                                         │ │
│  │  ○ config-map-corrupt │    │  Drag a fault from the library to add  │ │
│  │                       │    │                                         │ │
│  │ SOCK SHOP SPECIFIC    │    │                                         │ │
│  │  ○ carts-db-corrupt   │    │                                         │ │
│  │  ○ payment-abort      │    │                                         │ │
│  └───────────────────────┘    └──────────────────────────────────────────┘ │
│                                                                             │
│  Hypothesis: [                                                    ]         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

Clicking a fault node on the canvas opens a parameter panel on the right with all configurable parameters rendered as form fields.

---

### Screen 4 — Configure & Run

This screen adapts based on the selected agent's `llmConfig.allowUserChoice` setting.

**When `allowUserChoice: false` (most agents — model is fixed by agent's saved config):**

```
┌───────────────────────────────────────────────────────────────────────────┐
│  Step 4 of 4: Configure & Run                                             │
│                                                                           │
│  Experiment Name: [sock-shop-pod-failure-cascade          ]               │
│                                                                           │
│  LLM Model:  gpt-4o  ·  my-openai-gpt4o  (fixed by agent)               │
│  [Change model config ↗]  (links to Model Library)                        │
│                                                                           │
│  Agent Secrets (for Flash Agent)                                          │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │ PAGERDUTY_TOKEN  [••••••••••••••••] (required)                       │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│  Success Criteria                                                         │
│  pod-delete: detect within [45] s  |  mitigate within [90] s             │
│  cpu-hog:    detect within [60] s  |  mitigate within [150] s            │
│                                                                           │
│  Evaluation Metrics: ✓ time_to_detect  ✓ tool_call_efficiency            │
│                       ✓ root_cause_accuracy  ✓ false_positive_rate       │
│                                                                           │
│  [Save as Draft]                          [Save & Run →]                  │
└───────────────────────────────────────────────────────────────────────────┘
```

**When `allowUserChoice: true` (agent allows model selection per run):**

```
┌───────────────────────────────────────────────────────────────────────────┐
│  Step 4 of 4: Configure & Run                                             │
│                                                                           │
│  Experiment Name: [sock-shop-pod-failure-cascade          ]               │
│                                                                           │
│  LLM Model:  ● User chooses at run time                                   │
│              ○ Fix for this experiment: [gpt-4o ▼]                        │
│                                                                           │
│  Agent Secrets (for Flash Agent)                                          │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │ PAGERDUTY_TOKEN  [••••••••••••••••] (required)                       │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                           │
│  Success Criteria                                                         │
│  pod-delete: detect within [45] s  |  mitigate within [90] s             │
│  cpu-hog:    detect within [60] s  |  mitigate within [150] s            │
│                                                                           │
│  Evaluation Metrics: ✓ time_to_detect  ✓ tool_call_efficiency            │
│                       ✓ root_cause_accuracy  ✓ false_positive_rate       │
│                                                                           │
│  [Save as Draft]                          [Save & Run →]                  │
└───────────────────────────────────────────────────────────────────────────┘
```

When "User chooses at run time" is selected, the **Run dialog** (shown when clicking Run on a saved experiment) includes a model picker:

```
┌──────────────────────────────────────────────────┐
│  Run Experiment                                  │
│                                                  │
│  Experiment: sock-shop-pod-failure-cascade       │
│  Agent:      Flash Agent v1.0.0                  │
│  Model:      [gpt-4o  ▼]   ← user picks here    │
│  App:        Sock Shop                           │
│                                                  │
│  [Cancel]              [Start Run →]             │
└──────────────────────────────────────────────────┘
```

The model chosen at run time is stored in the Run record (`ExperimentRun.modelUsed`) so certification reports show which model was evaluated.

"Save & Run" saves the `experiment.yaml`, creates a Run record, and submits the Argo Workflow.

---

## 18. Success Criteria & Scoring Hooks

Success criteria in the experiment definition feed directly into the certifier's scoring pipeline. They are stored with the experiment definition (not the run) but can be overridden per run.

### Per-Step Criteria

Applied per fault step. The certifier uses the step's `detectWithinSecs` / `mitigateWithinSecs` to score `time_to_detect` and `time_to_mitigate` for that step.

```yaml
successCriteria:
  perStep:
    - stepName: inject-carts-failure
      detectWithinSecs: 45
      mitigateWithinSecs: 90
```

If a step does not have explicit criteria, the certifier falls back to the fault's `groundTruth.detectWithinSecs` / `mitigateWithinSecs`.

### Overall Criteria

Applied to the entire experiment run.

```yaml
successCriteria:
  overall:
    toolCallEfficiencyMin: 0.7     # tool calls that produced useful signal / total tool calls
    falsePositiveRateMax: 0.1      # false detections / total detections
    rootCauseAccuracyMin: 0.8      # correct root cause attributions / total fault steps
```

### Certification Threshold

A run is marked **CERTIFIED** if all per-step criteria are met AND all overall criteria are met. A run is marked **FAILED** otherwise, with a breakdown per criterion in the certifier report.

---

## 19. GraphQL API

### Fault Catalog

```graphql
type FaultSpec {
  name: String!
  displayName: String!
  version: String!
  tier: CatalogTier!
  scope: FaultScope!          # GENERAL | DOMAIN | APP_SPECIFIC
  domain: String
  targetApp: String
  tags: [String!]!
  description: FaultDescription!
  implementation: FaultImplementation!
  parameters: [FaultParameter!]!
  compatibility: FaultCompatibility!
  groundTruth: FaultGroundTruth!
}

type Query {
  listFaults(scope: FaultScope, domain: String, targetApp: String): [FaultSpec!]!
  getFault(name: String!): FaultSpec
  faultsForApp(appName: String!): [FaultSpec!]!   # Returns general + domain + app-specific
}
```

### Experiment Definitions & Runs

```graphql
type ExperimentDefinition {
  name: String!
  version: String!
  targetApp: ApplicationSpec!
  steps: [ExperimentStep!]!
  successCriteria: SuccessCriteria!
  evaluationMetrics: [String!]!
  runs: [ExperimentRun!]!
}

type ExperimentRun {
  id: ID!
  definitionName: String!
  definitionVersion: String!
  agentName: String!
  agentVersion: String!
  modelUsed: String!           # Resolved model name, e.g. "gpt-4o" — always populated
  modelProvider: String!       # Resolved provider, e.g. "openai" — always populated
  status: RunStatus!           # QUEUED | RUNNING | COMPLETED | FAILED | ABORTED
  startedAt: String
  completedAt: String
  langfuseTraceId: String
  certifierReportId: String
  argoWorkflowName: String
}

type Mutation {
  createExperiment(input: ExperimentInput!): ExperimentDefinition!
  submitRun(
    experimentName: String!
    agentName: String!
    modelOverride: String        # Optional — only valid when agent's allowUserChoice: true
    secretOverrides: [SecretInput!]
    paramOverrides: [ParamInput!]
  ): ExperimentRun!
  abortRun(runId: ID!): ExperimentRun!
}

type Query {
  getExperiment(name: String!): ExperimentDefinition
  getRun(id: ID!): ExperimentRun
  listRuns(experimentName: String, agentName: String, status: RunStatus): [ExperimentRun!]!
}
```

---

## 20. K8s Resources Created Per Run

| Resource | Kind | Namespace | Lifecycle |
|---|---|---|---|
| `app-<run-id>` | Helm Release | `<appName>-<run-id>` | Created at app-install step; deleted at teardown |
| `agent-<run-id>` | Helm Release | `<appName>-<run-id>` or `litmus` | Created at agent-install step; deleted at teardown |
| `ace-agent-secret-<run-id>` | Secret | `litmus` | Created before Workflow submission; deleted at teardown |
| `<experiment>-<run-id>` | Argo Workflow | `litmus` | Created at run submission; retained for 7 days then GC'd |
| `<stepName>-<run-id>` | ChaosEngine | `litmus` | Created per fault step; deleted after step completes |
| `load-test-<run-id>` | Job | `<appName>-<run-id>` | Created at load-start; deleted at teardown |

All namespaced resources for a run carry the label `ace.io/run-id: <run-id>` for bulk cleanup via label selector.

---

## 21. Error States & Handling

| Error | When | Behavior |
|---|---|---|
| App install timeout | App helm install exceeds `timeout` | Run → FAILED. Helm release is rolled back. Teardown runs. |
| App health probe failure | Health probe fails after retries | Run → FAILED. Error message includes last HTTP response. |
| Agent install timeout | Agent helm install exceeds `timeout` | Run → FAILED. App is cleaned up. |
| Fault injection error | ChaosEngine enters `Error` phase | Step → FAILED. Run → FAILED. Teardown runs. Remaining steps skipped. |
| Verify step failure | HTTP probe returns non-expected status | Step → FAILED. Run → FAILED. |
| Run timeout | Entire run exceeds 90 minutes (configurable) | Run → ABORTED. Teardown runs. |
| Teardown failure | Helm uninstall fails | Resources remain. Namespace tagged `ace.io/cleanup-needed: true`. Background cleanup job retries. |

---

## 22. Security Considerations

**Namespace isolation:** Each run uses a unique namespace `<appName>-<run-id>`. No shared state between runs. Network policies restrict inter-namespace traffic by default.

**Fault blast radius:** ChaosEngine is scoped to the experiment namespace via `appinfo.appns`. Faults cannot target the `litmus` or `kube-system` namespaces.

**Secret isolation:** Agent secrets are stored in `ace-agent-secret-<run-id>` in the `litmus` namespace. They are not mounted into any container except the agent pod. They are deleted at teardown.

**RBAC for chaos runner:** The LitmusChaos service account is granted only the permissions needed for declared faults. App-specific faults that require elevated permissions must declare them in `fault.yaml` under `spec.rbac` (Phase 2 feature — blocked on RBAC audit framework).

**Fault parameter validation:** Parameter values are validated against `min`/`max`/`type` at hydration time. No raw YAML injection from user-provided parameters — values are always passed as typed Helm `--set` args.

---

## 23. Forward Compatibility

**Multi-cluster faults:** The `external` implementation type is the extension point for faults that target non-K8s systems. No change to the schema is needed — the `endpoint` field points to whatever fault proxy is deployed.

**Conditional experiment branching:** The `onDetectionFailure` / `onMitigationSuccess` / `onMitigationFailure` fields are reserved in the schema. Argo Workflow conditional branching (`when` clauses) will be used to implement this — requires the certifier to publish intermediate detection signals during the run, not just post-run.

**Experiment templates:** Experiment definitions can be marked `template: true` to appear as starting-point templates in the Chaos Studio new-experiment flow, rather than runnable experiments. This is a metadata flag with no implementation change needed.

**Agent-role experiments (multi-agent):** The `participants[]` array is reserved in the experiment schema (see Agent Onboarding spec §19) but not yet implemented. The fault pipeline does not need to change — multiple agent install steps are added to the Argo Workflow DAG.

**Fault versioning:** `fault.yaml` has a `version` field. The experiment definition records which fault version was used at definition creation time. Running an experiment always uses the version pinned in the definition, not the latest catalog version. Fault upgrades do not silently change existing experiment results.
