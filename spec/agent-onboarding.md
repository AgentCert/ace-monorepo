# ACE — Agent Onboarding Specification

**Version:** 1.0  
**Status:** Draft  
**Scope:** Defines the complete flow for registering an AI agent with ACE — from bringing a Docker image through the Chaos Studio UI to a running, certifiable experiment.

---

## Table of Contents

1. [Purpose & Scope](#1-purpose--scope)
2. [Terminology](#2-terminology)
3. [User Personas](#3-user-personas)
4. [Agent Model](#4-agent-model)
5. [Agent Spec Schema — Complete Field Reference](#5-agent-spec-schema--complete-field-reference)
6. [Registration Methods](#6-registration-methods)
7. [User Journey — Quick Register (Generic Wrapper)](#7-user-journey--quick-register-generic-wrapper)
8. [User Journey — Advanced Register (Custom Helm Chart)](#8-user-journey--advanced-register-custom-helm-chart)
9. [Registration Form — Every Field](#9-registration-form--every-field)
10. [Capabilities System](#10-capabilities-system)
11. [Required Tools — MCP Integration](#11-required-tools--mcp-integration)
12. [Evaluation Metrics](#12-evaluation-metrics)
13. [Secret Handling](#13-secret-handling)
14. [Context Injection](#14-context-injection)
15. [Generic Agent Wrapper Chart](#15-generic-agent-wrapper-chart)
16. [Custom Helm Chart Requirements](#16-custom-helm-chart-requirements)
17. [Agent Install Mechanics](#17-agent-install-mechanics)
18. [Agent Lifecycle in an Experiment](#18-agent-lifecycle-in-an-experiment)
19. [Multi-Agent Experiments](#19-multi-agent-experiments)
20. [Agent Versioning](#20-agent-versioning)
21. [GraphQL API](#21-graphql-api)
22. [K8s Resources Created Per Run](#22-k8s-resources-created-per-run)
23. [Error States & Handling](#23-error-states--handling)
24. [Security Considerations](#24-security-considerations)
25. [Forward Compatibility](#25-forward-compatibility)
26. [Model Library](#26-model-library)

---

## 1. Purpose & Scope

ACE certifies AI agents by running them inside realistic application environments (from the app catalog) under controlled conditions. The agent is the primary artifact that users bring to ACE. An agent can be of any type — an SRE agent, a telecom NOC agent, a health IT agent, a FinOps agent, or any other autonomous decision-making program that observes an environment and takes action.

This specification defines:

- Every field in the agent spec schema
- Both registration paths (quick via generic wrapper, advanced via custom Helm chart)
- Every UI screen in the registration wizard
- How secrets are collected, stored, and injected without ever appearing in Argo Workflow YAML
- How capabilities and required tools map to certifier scoring
- The complete install and lifecycle mechanics for an agent in an experiment

**What this spec does NOT cover:**
- The certifier scoring pipeline
- Experiment creation (Phase 3 spec)
- App catalog (App Onboarding spec)

---

## 2. Terminology

| Term | Definition |
|------|-----------|
| **Agent** | An AI program of any domain type that observes signals from an application environment and takes action — remediation, escalation, reconfiguration, or notification |
| **Agent Spec** | The `agent.yaml` file that describes an agent to ACE — the machine-readable contract |
| **Generic Wrapper** | ACE's built-in Helm chart template that can run any agent image with minimal configuration |
| **Custom Helm Chart** | A contributor-provided Helm chart for agents with complex deployment requirements (sidecars, custom RBAC, init containers) |
| **Capability** | A declared skill from the domain-grouped vocabulary — what the agent can perceive or do (e.g., `prometheus-query` for cloud-native, `snmp-query` for telecom, `fhir-read` for health IT) |
| **Required Tool** | An exact MCP tool name that the agent is expected to call during an experiment. The certifier validates actual calls against this list. |
| **Evaluation Metric** | A certifier scoring dimension applicable to this agent (e.g., `time_to_detect`, `tool_call_efficiency`) |
| **Context Injection** | Runtime values (workflow UID, notify ID, LiteLLM proxy URL) injected into the agent's Helm install at experiment submission time |
| **Secret** | A sensitive input (API key, token) collected in the registration form but stored in a K8s Secret in the `litmus` namespace — never in Argo Workflow YAML |
| **SecretRef** | The name of the K8s Secret that the agent Helm chart mounts at runtime (`ace-agent-secret-<experimentID>`) |
| **notifyId** | The Argo workflow name injected into the agent so it can tag its event notifications back to the correct experiment run |
| **install-agent** | The ACE binary that installs/uninstalls an agent using its Helm chart (generic wrapper or custom) |
| **MCP** | Model Context Protocol — the tool interface standard used by ACE agents |
| **Model Library** | ACE's central registry of LLM model configurations — provider, model name, and API key secret. Shared across agents within a project. Users configure it once; agents reference it by alias. |
| **Model Configuration** | A saved entry in the Model Library: one provider + model + API key, identified by a user-chosen alias (e.g., `my-openai-gpt4o`). |
| **llmConfig** | The `agent.yaml` block that declares the agent's LLM model requirements — which saved configuration to use, whether users can pick the model at run time, and which models are allowed. |

---

## 3. User Personas

### 3.1 The Agent Developer (primary user)

A developer or research team that has built an AI agent and wants to certify it. They understand their agent's domain and architecture but may not know Kubernetes chaos engineering or Helm chart authoring. Their agent could be a telecom NOC agent, a cloud-native SRE agent, a health IT agent, or anything else.

**What they need:** A registration flow that asks only what their agent needs — image, API key, model settings — and handles all K8s complexity behind the scenes. They should be able to go from "I have a Docker image" to "my agent is running in an experiment" in under 10 minutes.

### 3.2 The Advanced Contributor

An agent developer whose agent has non-standard deployment requirements: a sidecar proxy, custom RBAC for direct K8s access, init containers for pre-warming, or multi-container pods. They need to bring their own Helm chart.

**What they need:** Clear documentation of what the chart must provide and what ACE expects to inject (context injection, secret reference). A validation tool that confirms their chart will work.

### 3.3 The Evaluator

A user (not the agent developer) who wants to run an existing registered agent against a catalog app to evaluate its performance. They did not build the agent — they are using one that someone else registered.

**What they need:** A simple picker in Chaos Studio. They may need to provide a new API key if the original registration's key has expired.

---

## 4. Agent Model

### 4.1 What ACE Expects From an Agent

ACE makes no assumptions about how an agent is implemented internally. The only interface requirements are:

1. **The agent is a Docker image.** It must be pullable from a registry (public or the project's configured private registry).

2. **The agent is configured entirely via environment variables.** Configuration (API key, model name, scan interval, etc.) is passed through K8s Secret and ConfigMap env injection — not via config files, not via command-line args, not via mounted volumes (unless the custom Helm chart handles that).

3. **The agent exposes tool calls via MCP.** The certifier observes the agent's MCP tool calls to score `tool_call_efficiency` and verify `requiredTools`. Agents that do not use MCP cannot be scored on tool-based metrics.

4. **The agent emits a notify event when it starts working.** ACE needs to know when the agent detected an anomaly. The `notifyId` (Argo workflow name) is injected and the agent uses it to tag its notification. Without this, `time_to_detect` cannot be measured.

5. **The agent terminates gracefully.** When `uninstall-agent` runs, the Helm uninstall must cleanly remove the agent pod. Agents that create their own persistent resources (PVCs, CRDs) must clean them up in the chart's Helm pre-delete hook.

### 4.2 What ACE Does NOT Require

- A specific programming language or framework
- A specific LLM provider (LiteLLM proxy normalizes model APIs)
- A specific observability stack connection (Prometheus, Loki, Jaeger — agent connects to what it needs)
- Cluster-admin permissions (agents should work with namespace-scoped read + limited write RBAC)

---

## 5. Agent Spec Schema — Complete Field Reference

The `agent.yaml` file is the machine-readable contract. It lives in `catalog/agents/<name>/agent.yaml` (for community/official agents) or is loaded from a user's private registration.

### 5.1 Top-Level Structure

```yaml
apiVersion: ace.io/v1
kind: AgentCatalogEntry
metadata: { ... }       # identity & provenance
spec:
  description: { ... }  # human-facing + AI engine data
  install: { ... }      # how to deploy the agent
  llmConfig: { ... }    # LLM provider, model, and run-time model selection (see §5.11)
  inputs: [ ... ]       # configurable parameters (non-LLM secrets and config)
  contextInjection: [ ... ] # runtime values injected at experiment start
  capabilities: [ ... ] # what the agent can perceive/do
  requiredTools: [ ... ] # MCP tool names expected to be called
  evaluationMetrics: [ ... ] # which certifier metrics apply
  compatibility: { ... } # which catalog apps this agent works with
```

### 5.2 `metadata` Block

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `metadata.name` | string | ✓ | Kebab-case. Stable primary key. Cannot change after any experiment references this agent. Used in saved experiments, certifier reports, and certification badges. |
| `metadata.displayName` | string | ✓ | Human-readable. Shown in Chaos Studio agent picker. |
| `metadata.version` | string | ✓ | SemVer string (e.g., `"1.0.0"`). Bumped by owner when agent image, schema, or capabilities change. |
| `metadata.tier` | enum | auto | `official`, `community`, or `private`. Set by registration path — private agents (not in git catalog) are always `private`. |
| `metadata.owner` | object | ✓ | `name`, `email`, `org`. The person or team who maintains this agent. |
| `metadata.license` | string | — | SPDX identifier. Required for public catalog agents. |
| `metadata.repository` | string | — | URL to the agent source code. Shown in Chaos Studio detail view. |
| `metadata.tags` | string[] | — | Free-form searchable tags. e.g., `["react-loop", "cloud-native", "gpt-4"]` or `["telecom", "noc", "netconf"]` |

### 5.3 `spec.description` Block

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description.short` | string | ✓ | ≤ 120 chars. Shown in Chaos Studio agent card. |
| `description.long` | string | ✓ | Full description. Markdown. Shown in agent detail page. Should cover: what the agent does, its decision-making approach, what it is NOT designed to handle. The AI experiment generation engine consumes this field. |
| `description.approach` | string | — | The agent's reasoning strategy: `react-loop`, `plan-and-execute`, `chain-of-thought`, `custom`. Used for catalog filtering. |
| `description.llmDependent` | bool | — | Default: `true`. Set `false` for rule-based agents that do not use an LLM. Affects which `inputs[]` are required (no API key needed for rule-based). |

### 5.4 `spec.install` Block

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `install.method` | enum | ✓ | `generic-wrapper` — use ACE's built-in chart, agent is a Docker image + env vars. `helm` — use a custom Helm chart in `catalog/agents/<name>/chart/`. `external-helm` — reference an external Helm chart. |
| `install.image` | string | ✓ (generic-wrapper) | Docker image for the agent. Goes through the image resolver. e.g., `myorg/flash-agent:1.0.0`. |
| `install.command` | string[] | — | Override container entrypoint. Defaults to the image's `CMD`. |
| `install.args` | string[] | — | Arguments passed to the container command. |
| `install.folder` | string | ✓ (helm) | Directory name matching `catalog/agents/<name>/chart/`. Passed as `--folder` to `install-agent`. |
| `install.chartRef` | object | ✓ (external-helm) | `repo`, `chart`, `version` — same structure as app spec. Version must be pinned. |
| `install.installImage` | string | — | The `install-agent` binary image. Default: `agentcert/agentcert-install-agent:latest`. Only override if using a custom install binary. |
| `install.namespace` | string | — | Default: `"{{.AppNamespace}}"` — the agent runs in the same namespace as the app. Override if the agent must run in a different namespace (e.g., `litmus`). |
| `install.timeout` | string | — | Default: `"20m"`. |
| `install.resources` | object | — | K8s resource requests and limits. Default: `requests: {memory: 512Mi, cpu: 200m}`. Override for heavy models. |
| `install.replicas` | int | — | Default: `1`. Almost always 1 — multiple replicas of a stateful agent cause duplicate or conflicting actions on the same environment. |

### 5.5 `spec.inputs[]` Block

These are the configurable parameters shown in the Chaos Studio agent configuration form. The user fills these in when building an experiment.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `key` | string | ✓ | Unique stable identifier for this input. Used as form field name. |
| `displayName` | string | ✓ | Label shown in the Chaos Studio form. |
| `description` | string | — | Inline help text. Shown as tooltip or beneath the field. |
| `type` | enum | ✓ | `secret`, `string`, `integer`, `boolean`, `enum`. `secret` inputs are handled distinctly — see §13. |
| `required` | bool | — | Default: `false`. If `true`, experiment cannot be saved without this value. **At least one `type: secret` input is required for LLM-dependent agents.** |
| `default` | string | — | Pre-filled default value. Not applicable for `type: secret`. |
| `placeholder` | string | — | Greyed-out hint text. Used for `type: secret` to show the expected format (e.g., `"sk-..."`). |
| `helmPath` | string | ✓ | The Helm `--set` path this input maps to. For generic-wrapper agents, the path must be under `agent.config.*` or `agent.secret.*`. |
| `values` | string[] | ✓ (enum) | Valid values for enum type. |
| `min` | int | — | Minimum (integer type). |
| `max` | int | — | Maximum (integer type). |
| `unit` | string | — | Unit label (e.g., `"seconds"`, `"tokens"`). |
| `advanced` | bool | — | Default: `false`. If `true`, hidden under "Advanced" toggle. |
| `validation` | object | — | Optional validation: `pattern` (regex), `message` (error shown on mismatch). Only for `type: string`. |
| `group` | string | — | Groups related inputs under a sub-header in the form. e.g., `"LLM Configuration"`, `"Behavior"`. |

### 5.6 `spec.contextInjection[]` Block

Runtime values that ACE injects at experiment submission time. These are NOT user-configurable — they are provided by the workflow runtime.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `helmPath` | string | ✓ | `--set` path in the install-agent call. |
| `source` | string | ✓ | Argo expression evaluated at submit time. Must be one of the supported sources listed below. |
| `required` | bool | — | Default: `true`. If a required context injection source is unavailable, the experiment fails to submit. |
| `description` | string | — | Documentation for what this value does. |

**Supported `source` values:**

| Source Expression | Value Injected | Purpose |
|------------------|---------------|---------|
| `{{workflow.name}}` | Argo workflow name (e.g., `sock-shop-exp-abc123`) | `notifyId` — agent tags events with this to tie back to the run |
| `{{workflow.uid}}` | Argo workflow UID (UUID) | Correlate certifier events to this specific run |
| `{{workflow.parameters.litellmUpstream}}` | LiteLLM proxy URL from project settings | Agent routes LLM calls through the ACE proxy for tracing |
| `{{workflow.parameters.appNamespace}}` | The app's install namespace | Agent watches the correct namespace |
| `{{workflow.parameters.adminModeNamespace}}` | Always `litmus` | Agent can query chaos state if needed |

**Mandatory context injections (every agent must include all three):**

```yaml
contextInjection:
  - helmPath: "agent.notifyId"
    source: "{{workflow.name}}"
    description: "Workflow name — agent uses this as the experiment correlation ID"
    required: true

  - helmPath: "agent.workflowUid"
    source: "{{workflow.uid}}"
    description: "Workflow UID — certifier uses this to match agent events to runs"
    required: true

  - helmPath: "sidecar.upstream"
    source: "{{workflow.parameters.litellmUpstream}}"
    description: "LiteLLM proxy — routes LLM API calls through ACE for tracing and cost tracking"
    required: true
```

### 5.7 `spec.capabilities[]`

The list of capability keys this agent has. Must use values from the capabilities vocabulary (see §10). The list is order-independent.

**Validation rule:** Every capability key listed must exist in the central `capabilities.yaml` vocabulary file. Unknown keys cause schema validation failure.

**Minimum capabilities for any agent:**
- At least one observe capability from the agent's domain vocabulary (e.g., `prometheus-query` for cloud-native, `snmp-query` for telecom, `fhir-read` for health IT)
- At least one act capability if the agent claims to remediate (e.g., `kubernetes-patch`, `netconf-edit-config`, `fhir-write`)

### 5.8 `spec.requiredTools[]`

The MCP tool names the certifier expects to see called during a successful experiment run.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | ✓ | Exact tool name as it appears in the agent's MCP server manifest. Case-sensitive. |
| `purpose` | string | — | Why the agent calls this tool — used in certifier report annotations. |
| `critical` | bool | — | Default: `true`. Critical tools must be called for `tool_call_efficiency` scoring to pass. Non-critical tools are expected but their absence is not a hard deduction. |
| `minCallCount` | int | — | Default: `1`. Expected minimum number of times this tool is called per fault scenario. Used to detect under-utilization. |
| `maxCallCount` | int | — | Default: unlimited. If the agent calls a tool more than this many times, it is flagged as inefficient in the certifier report. |

### 5.9 `spec.evaluationMetrics[]`

Which certifier scoring dimensions apply to this agent.

| Metric Key | Description | Required data |
|-----------|-------------|--------------|
| `time_to_detect` | Time from fault injection start to agent's first detection event (seconds) | Agent must emit a detection notification via `notifyId` |
| `time_to_mitigate` | Time from detection to confirmed recovery (alert resolved) | Agent must remediate AND alert must clear |
| `tool_call_efficiency` | Ratio of useful tool calls to total tool calls during the run | MCP call log, `requiredTools[]` definition |
| `root_cause_accuracy` | Semantic similarity between agent-identified root cause and `groundTruth.expectedRootCause` | Agent must output a root cause statement; LLM judge compares it |
| `remediation_correctness` | Whether the agent's remediation action matched `groundTruth.expectedRemediation` | Agent must take an action; action type is compared to ground truth |
| `false_positive_rate` | How many times the agent fired on non-fault-related signals | Requires baseline run (no faults) — Iter 2 |
| `blast_radius` | Whether the agent's remediation affected components beyond the faulted one (e.g., cascaded config changes, unintended restarts, collateral network changes) | Environment resource change audit — Iter 2 |

### 5.10 `spec.compatibility` Block

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `compatibility.supportedApps` | string[] | — | Catalog app names this agent is known to work with. Shown in the app catalog as "Compatible agents: flash-agent, k8s-agent". If empty, agent is shown as compatible with all apps (no declared incompatibilities). |
| `compatibility.unsupportedApps` | string[] | — | Apps this agent explicitly cannot work with. e.g., `["bookinfo"]` for an agent without `service-mesh-aware` capability. Chaos Studio warns the user when they combine this agent with an incompatible app. |
| `compatibility.minimumFaultCount` | int | — | Default: `1`. Minimum number of fault nodes needed in an experiment for meaningful evaluation. |
| `compatibility.maximumFaultCount` | int | — | Default: `10`. Upper bound to prevent unreasonably complex experiments that are hard to analyze. |

### 5.11 `spec.llmConfig` Block

Declares the agent's LLM model requirements. Replaces the former pattern of putting the LLM API key in `inputs[]` — API keys for the LLM are now managed through the Model Library and never appear in `agent.yaml`.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `llmConfig.configRef` | string | — | Alias of a saved Model Library entry (e.g., `my-openai-gpt4o`). When set, the agent always uses this configuration. Required for `official` and `community` tier agents — they reference the user's own configured model at registration time. |
| `llmConfig.provider` | enum | — | Inline provider declaration (used when `configRef` is absent). `openai` \| `anthropic` \| `google` \| `azure` \| `ollama` \| `custom`. For community-tier agents, this declares what provider the agent expects; the user's Model Library entry must match. |
| `llmConfig.model` | string | — | Inline model name declaration. Used to validate that the user's saved config uses a compatible model. |
| `llmConfig.allowUserChoice` | bool | — | Default: `false`. If `true`, the experiment run dialog shows a model picker and the user can choose from `allowedModels` at run time. |
| `llmConfig.allowedModels` | string[] | — | Required when `allowUserChoice: true`. The models the user may choose from. Must all be from the same provider declared in `provider`. |
| `llmConfig.defaultModel` | string | — | The model pre-selected in the run dialog when `allowUserChoice: true`. Must be in `allowedModels`. |
| `llmConfig.llmDependent` | bool | — | Default: `true`. Set `false` for rule-based agents that make no LLM calls. When `false`, no model configuration is required or shown in the wizard. |

**Complete example — fixed model (most agents):**

```yaml
spec:
  llmConfig:
    configRef: my-openai-gpt4o      # Set by user at registration; not in catalog YAML
    provider: openai                # Community agents declare expected provider
    model: gpt-4o                   # Community agents declare expected model
    allowUserChoice: false
    llmDependent: true
```

**Complete example — user chooses model at run time:**

```yaml
spec:
  llmConfig:
    provider: openai
    allowUserChoice: true
    allowedModels: [gpt-4o, gpt-4o-mini, gpt-4-turbo]
    defaultModel: gpt-4o
    llmDependent: true
```

**Complete example — rule-based agent:**

```yaml
spec:
  llmConfig:
    llmDependent: false
```

**How `configRef` is resolved at run time:**

1. ACE looks up the Model Library entry with the alias stored in `llmConfig.configRef` (for this project)
2. Retrieves the LiteLLM deployment ID ACE created when the user saved the model config
3. Injects the LiteLLM upstream URL into the sidecar via `sidecar.upstream` context injection
4. The sidecar routes all LLM calls to that deployment — agent code calls the sidecar, not LiteLLM directly

The user never sees the LiteLLM deployment ID. The `configRef` alias is the only user-facing identifier.

---

## 6. Registration Methods

### 6.1 Quick Register — Generic Wrapper

**Use when:** The agent is a Docker container that reads configuration from environment variables. No custom K8s resources needed beyond a standard Deployment + Secret.

**Effort:** 5–10 minutes in the Chaos Studio wizard.

**What ACE provides:**
- A generic Helm chart that deploys the agent as a single-pod Deployment
- Secret mounting from the K8s Secret ACE manages
- Standard RBAC: read-only access to pods, events, and configmaps cluster-wide; limited patch access for auto-remediation
- ConfigMap for non-secret config values

**What the user provides:**
- Docker image URL
- The env var names for API key, model, and other config
- A description and capabilities declaration

### 6.2 Advanced Register — Custom Helm Chart

**Use when:** The agent requires any of:
- A sidecar container (e.g., an LLM proxy sidecar, a log forwarder)
- Custom RBAC beyond what the generic wrapper provides
- Init containers for pre-warming or model download
- Persistent storage
- Custom ServiceAccount with specific cluster permissions
- Multiple pods (e.g., a controller + worker architecture)

**Effort:** 30–60 minutes plus chart authoring time.

**What the user provides:**
- A complete Helm chart (in the catalog repo or via external reference)
- The chart must accept the standard context injection paths (see §14)
- The chart must accept `agent.secretRef` to mount the ACE-managed secret

---

## 7. User Journey — Quick Register (Generic Wrapper)

### 7.1 Entry Point

In Chaos Studio, user clicks **"Register Agent"** (in the sidebar or from the "Install Agent" node picker when no matching agent exists).

### 7.2 Method Selection Screen

```
┌─────────────────────────────────────────────────────────────────────┐
│  Register New Agent                                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  🚀 Quick Register                                           │   │
│  │  My agent is a Docker image that reads config from env vars. │   │
│  │  ACE will deploy it using its built-in chart.               │   │
│  │  Ready in ~5 minutes.                                        │   │
│  │  [Start Quick Register]                                      │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  ⚙ Advanced Register                                        │   │
│  │  My agent has custom Kubernetes deployment requirements.     │   │
│  │  I'll provide a Helm chart.                                  │   │
│  │  [Start Advanced Register]                                   │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  Not sure? [Read the difference →]                                  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 8. User Journey — Advanced Register (Custom Helm Chart)

### 8.1 Chart Validation Tool

Before the wizard starts, the user can upload or point to their chart for pre-validation:

```
┌──────────────────────────────────────────────────────────────┐
│  Validate Your Helm Chart                                    │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Upload chart:  [Choose File .tgz]                          │
│  OR                                                          │
│  Chart repo:    [https://...] Chart: [name] Version: [x.y.z]│
│                                                              │
│  [Validate Chart →]                                         │
│                                                              │
│  Validation checks:                                          │
│  ✅ helm lint passes                                        │
│  ✅ accepts --set agent.secretRef=<name>                    │
│  ✅ accepts --set agent.notifyId=<value>                    │
│  ✅ accepts --set agent.workflowUid=<value>                 │
│  ✅ accepts --set sidecar.upstream=<value>                  │
│  ⚠  agent.config.MODEL_ALIAS not found in values.yaml       │
│     (optional but recommended)                              │
│  ❌ chart does not create a ServiceAccount                   │
│     The chart should create its own SA or use the default   │
│     'default' SA in the agent's namespace.                  │
└──────────────────────────────────────────────────────────────┘
```

Validation runs `helm template <chart> --set agent.secretRef=test` and checks for:
- Required `--set` paths in the rendered output (agent.notifyId, agent.workflowUid, sidecar.upstream, agent.secretRef)
- No hardcoded secrets in values.yaml
- No `hostNetwork: true` or `privileged: true` (rejected for security)
- No `ClusterRoleBinding` for cluster-admin (rejected for security)

---

## 9. Registration Form — Every Field

The Quick Register wizard collects the following fields across 6 steps. Advanced Register has an additional step for chart specification.

### Step 1: Identity

| Field | Type | Required | Validation | Notes |
|-------|------|----------|------------|-------|
| Agent Name | string | ✓ | `^[a-z0-9][a-z0-9-]*[a-z0-9]$`, max 63 chars | Stable key. Cannot change. Uniqueness checked against live catalog. |
| Display Name | string | ✓ | 1–80 chars | Shown in Chaos Studio agent picker. |
| Short Description | string | ✓ | 10–120 chars | Shown on agent card. |
| Full Description | markdown | ✓ | 50–5000 chars | What the agent does, its reasoning approach, what it does NOT handle. AI engine prompt will include this. |
| Reasoning Approach | enum | — | `react-loop`, `plan-and-execute`, `chain-of-thought`, `rule-based`, `custom` | For catalog filtering. |
| Owner Name | string | ✓ | 1–80 chars | |
| Owner Email | string | ✓ | valid email | |
| Organization | string | — | | |
| Repository URL | string | — | valid URL | Link to agent source code. |
| Tags | string[] | — | lowercase, hyphen-separated | Free-form. Used in catalog search. |

### Step 2: Docker Image (Quick Register only)

| Field | Type | Required | Validation | Notes |
|-------|------|----------|------------|-------|
| Docker Image | string | ✓ | Non-empty. No `latest` tag recommended (warning shown, not blocked). | e.g., `myorg/flash-agent:1.0.0`. Goes through image resolver. |
| Command Override | string[] | — | — | Override container `CMD`. Leave empty to use image default. |
| Command Args | string[] | — | — | Arguments passed to the command. |
| CPU Request | string | — | K8s quantity format | Default: `200m`. |
| Memory Request | string | — | K8s quantity format | Default: `512Mi`. |
| CPU Limit | string | — | K8s quantity format | Default: `1000m`. |
| Memory Limit | string | — | K8s quantity format | Default: `1Gi`. |

**Image tag warning:** If the image tag is `latest`, a yellow warning is shown:
> "⚠ Using `:latest` means different versions of your agent may run at different times. We recommend pinning to a specific version for reproducible certification results."

### Step 3: LLM Configuration

This step replaces the former practice of putting an LLM API key in `inputs[]`. ACE manages LLM credentials through the Model Library — users configure a model once and reference it by alias across all their agents.

This step is **skipped entirely** if `description.llmDependent: false` (rule-based agents).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Step 3 of 6: LLM Configuration                                             │
│                                                                             │
│  Your agent calls an LLM to reason. Configure the model here.              │
│  All calls are routed through ACE's secure gateway — your key stays        │
│  in your cluster.                                                           │
│                                                                             │
│  ── Use a saved model ────────────────────────────────────────────────────  │
│  [my-openai-gpt4o  ▼]                          [+ Save new model config]   │
│                                                                             │
│  — or configure inline ─────────────────────────────────────────────────── │
│                                                                             │
│  Provider    [OpenAI          ▼]                                            │
│  Model       [gpt-4o          ▼]  ○ Custom model name: [______________]    │
│  API Key     [sk-••••••••••••••••••••••••••••••••]  👁                      │
│  Base URL    [https://api.openai.com/v1]  (leave blank for default)        │
│                                                                             │
│  [Test Connection]  ──→  ✓ gpt-4o responded in 342ms                       │
│                                                                             │
│  ☐ Save as  [my-openai-gpt4o      ]  so other agents can reuse this        │
│                                                                             │
│  ─── Model flexibility at run time ──────────────────────────────────────── │
│  ● Fixed — agent always uses the model above                               │
│  ○ User chooses at run time                                                 │
│      Allowed: [☑ gpt-4o] [☑ gpt-4o-mini] [☑ claude-3-5-sonnet] [☐ o4]   │
│      Default: [gpt-4o ▼]                                                   │
│                                                                             │
│                                      [← Back]          [Next: Config Inputs →]│
└─────────────────────────────────────────────────────────────────────────────┘
```

**"Test Connection" behavior:**
1. ACE makes a minimal test completion through LiteLLM using the provided credentials
2. On success: LiteLLM model entry is created (or updated) and an internal deployment ID is stored
3. On failure: shows the raw error message from LiteLLM (e.g., "Invalid API key", "Model not found")
4. The user sees only the provider/model name and the test result — never the LiteLLM deployment ID

**"Save as" behavior:**
- Creates a named entry in the project's Model Library
- The entry stores: provider, model, API key (as K8s Secret in `litmus` namespace), and the LiteLLM deployment ID
- The alias becomes the `configRef` stored in `agent.yaml`
- Subsequent agents in the same project can select this alias from the "Use a saved model" dropdown

**Supported providers in the inline form:**

| Provider | Notes |
|---|---|
| OpenAI | Base URL defaults to `https://api.openai.com/v1` |
| Anthropic | LiteLLM proxies to Anthropic's native API; agent calls OpenAI-spec sidecar |
| Google | Gemini models via `google/gemini-*` routing in LiteLLM |
| Azure OpenAI | Requires Base URL (e.g., `https://<resource>.openai.azure.com/`) + deployment name as Model |
| Ollama | Base URL required (e.g., `http://ollama.svc.cluster.local:11434`) |
| Custom | Any OpenAI-compatible endpoint; Base URL required |

**Note for community catalog contributors:** Community agents in `catalog/agents/` do not include a `configRef` (since they don't know which key the user has). They declare `provider` and `model` to signal what kind of model they expect. When a user registers a community agent, this step creates a new Model Library entry for them.

### Step 4: Configuration Inputs

The user defines what parameters their agent needs. For each input:

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| Parameter Name | string | ✓ | Becomes the env var name in the container. All-caps with underscores (e.g., `OPENAI_API_KEY`). |
| Display Name | string | ✓ | Label shown in the experiment form. |
| Type | enum | ✓ | `secret`, `string`, `integer`, `boolean`, `enum`. |
| Required | bool | — | Default: false. |
| Default Value | string | — | Not applicable for secret. |
| Description | string | — | Help text. |
| Group | string | — | Groups related params under a sub-header. |
| Advanced | bool | — | Default: false. If true, hidden under "Advanced" toggle. |

**Note:** LLM API keys are configured in Step 3 (LLM Configuration) and managed through the Model Library. They do not appear as `type: secret` inputs here. This step is for other secrets the agent needs — a PagerDuty token, a JIRA API key, a monitoring system credential.

**Env var naming convention for generic wrapper:**
- Secret inputs → injected via `envFrom.secretRef` (all keys from the Secret become env vars)
- Non-secret inputs → injected via `envFrom.configMapRef` (all keys from the ConfigMap become env vars)
- The generic wrapper chart creates a ConfigMap with all non-secret input values

### Step 5: Capabilities & Tools

#### Capabilities

A multi-select from the capabilities vocabulary (see §10):

```
┌──────────────────────────────────────────────────────────────────┐
│  What can your agent do?                                         │
│  Select all that apply:                                          │
│                                                                  │
│  Observe                                                         │
│  [ ☑ prometheus-query       ] Query Prometheus/PromQL           │
│  [ ☑ kubernetes-get-pods    ] List and describe pods            │
│  [ ☑ kubernetes-get-events  ] List Kubernetes events            │
│  [ ☑ kubernetes-describe    ] Describe any K8s resource         │
│  [ ☑ log-query              ] Query container/app logs          │
│  [ ☐ http-probe             ] Issue HTTP requests to endpoints  │
│  [ ☐ service-mesh-aware     ] Istio/Envoy metrics & policies    │
│  [ ☐ finops-query           ] OpenCost / cloud cost APIs        │
│                                                                  │
│  Act                                                             │
│  [ ☑ kubernetes-patch       ] Patch K8s resources              │
│  [ ☑ kubernetes-delete      ] Delete K8s resources             │
│  [ ☐ kubernetes-restart     ] Rollout restart workloads         │
│  [ ☐ kubernetes-resource-quota ] Manage ResourceQuotas          │
│  [ ☐ kubernetes-scale       ] Scale deployments                 │
│                                                                  │
│  ⓘ Capabilities are used by the AI experiment generation engine │
│    to suggest relevant fault scenarios for your agent.          │
└──────────────────────────────────────────────────────────────────┘
```

#### Required Tools (MCP Tool Names)

```
┌──────────────────────────────────────────────────────────────────┐
│  Which tools does your agent call?                               │
│  Enter the exact tool names from your MCP server manifest.      │
│                                                                  │
│  [Import from MCP server URL: [http://...] [Import]]            │
│                                                                  │
│  ┌────────────────────────────────────┬──────────┬───────────┐   │
│  │ Tool Name                          │ Critical │ Max Calls │   │
│  ├────────────────────────────────────┼──────────┼───────────┤   │
│  │ Execute PromQL Query               │ ☑ Yes   │ —     [✕] │   │
│  │ Events: List                       │ ☑ Yes   │ —     [✕] │   │
│  │ Pods: List in Namespace            │ ☑ Yes   │ —     [✕] │   │
│  │ Resources: Get                     │ ☐ No    │ 10    [✕] │   │
│  └────────────────────────────────────┴──────────┴───────────┘   │
│                                                                  │
│  [+ Add Tool]                                                    │
│                                                                  │
│  ⓘ Tool names are case-sensitive. They must exactly match what  │
│    your MCP server returns in its tool manifest.                │
│    The certifier will flag missing tools in the final report.   │
└──────────────────────────────────────────────────────────────────┘
```

**MCP Import behavior:**
1. User enters their MCP server URL
2. ACE GraphQL server calls `GET <url>/tools` (standard MCP tools listing endpoint)
3. Response is parsed into tool names
4. All tools are pre-filled in the table as non-critical with no max call limit
5. User reviews and marks which ones are critical

#### Evaluation Metrics

```
┌──────────────────────────────────────────────────────────────────┐
│  Which evaluation metrics apply to your agent?                   │
│                                                                  │
│  [ ☑ time_to_detect          ] How fast it detects faults       │
│  [ ☑ time_to_mitigate        ] How fast it resolves faults      │
│  [ ☑ tool_call_efficiency    ] Quality of tool usage            │
│  [ ☑ root_cause_accuracy     ] Accuracy of diagnosis            │
│  [ ☐ remediation_correctness ] Correctness of fix applied       │
│  [ ☐ false_positive_rate     ] Noise during no-fault periods    │
│                                                                  │
│  ⓘ ACE will only score metrics you select here.                 │
│    Selecting too few means a less complete certification.        │
│    Selecting metrics your agent cannot satisfy means a lower    │
│    score. When in doubt, select what your agent claims to do.   │
└──────────────────────────────────────────────────────────────────┘
```

### Step 6: App Compatibility

```
┌──────────────────────────────────────────────────────────────────┐
│  Which catalog apps is your agent compatible with?               │
│                                                                  │
│  ○ Compatible with all catalog apps (default)                    │
│                                                                  │
│  ○ Specify compatibility                                         │
│    Compatible with:                                              │
│    [ ☑ sock-shop     ] [ ☑ otel-demo    ] [ ☐ bookinfo    ]     │
│                                                                  │
│    Mark as incompatible with:                                    │
│    [ ☑ bookinfo      ] (requires service-mesh-aware capability)  │
│                                                                  │
│  ⓘ Marking an app as incompatible prevents experiments that     │
│    would give meaningless results. Chaos Studio will warn users  │
│    who try to combine your agent with an incompatible app.      │
└──────────────────────────────────────────────────────────────────┘
```

### Step 7: Review & Register

```
┌────────────────────────────────────────────────────────────────────┐
│  Review & Register                                                 │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Agent:        flash-agent v1.0.0                                  │
│  Image:        myorg/flash-agent:1.0.0                             │
│  Capabilities: 7 capabilities declared                             │
│  Tools:        4 required tools                                    │
│  Metrics:      4 evaluation metrics                                │
│  Inputs:       5 parameters (1 secret, 4 config)                  │
│                                                                    │
│  Registration mode:                                                │
│  ○ Private (only visible to your project)                          │
│  ○ Contribute to community catalog (opens PR)                      │
│                                                                    │
│  For private registration: agent is immediately available          │
│  in Chaos Studio for your project.                                 │
│                                                                    │
│  For community contribution: generates agent.yaml + PR template.  │
│  Agent is available privately while PR is under review.           │
│                                                                    │
│  [← Back]                         [Register Agent]                │
└────────────────────────────────────────────────────────────────────┘
```

**Private registration:**
- `agent.yaml` is stored in the ACE database (not in git)
- Agent is immediately available in `listAgents()` for that project
- Not visible to other projects

**Community contribution:**
- Generates `catalog/agents/community/<name>/agent.yaml`
- Generates PR template with description and review checklist
- Agent is ALSO registered privately in the current project (available immediately, no PR wait)

---

## 10. Capabilities System

### 10.1 Architecture — Domain-Grouped Vocabulary

Capabilities are **domain-grouped**. Each domain has its own vocabulary file under `catalog/capabilities/`. An agent declares capabilities only from the domains relevant to its function. Chaos Studio shows only the capabilities matching the selected app's declared `capabilityDomains`.

```
catalog/capabilities/
├── common.yaml          # cross-domain: http-probe, generic-api-query, webhook-notify
├── cloud-native.yaml    # prometheus-query, kubernetes-*, log-query, service-mesh-aware
├── telecom.yaml         # snmp-query, netconf-get, alarm-query, topology-traverse, syslog-query
├── health-it.yaml       # fhir-read, hl7-parse, patient-monitor-query, clinical-alert-query
├── finops.yaml          # cost-api-query, budget-alert-query, rightsizing-recommendation
└── itops.yaml           # cmdb-query, monitoring-alert-query, ticket-create, runbook-execute
```

Each app in the catalog declares `capabilityDomains: [cloud-native, common]` (see App Onboarding spec). When a user selects that app in Chaos Studio, the capabilities panel shows only capabilities from those domains. A telecom agent's capabilities are never mixed into a cloud-native agent's picker — they belong to different domains.

### 10.2 Vocabulary — `common.yaml` (cross-domain)

```yaml
domain: common
displayName: Common
description: "Capabilities applicable across all domains"

capabilities:
  observe:
    - key: http-probe
      displayName: HTTP Probe
      description: "Issue HTTP requests to check endpoint health and response content"
      relatedFaults: [pod-network-loss, pod-network-latency, link-down-simulation]

    - key: generic-api-query
      displayName: Generic API Query
      description: "Query any REST or GraphQL API to retrieve observability data"
      relatedFaults: []

  act:
    - key: webhook-notify
      displayName: Webhook Notify
      description: "Send structured notifications via webhook (Slack, PagerDuty, Teams, etc.)"
      relatedFaults: []

    - key: email-notify
      displayName: Email Notify
      description: "Send email notifications to on-call or operations teams"
      relatedFaults: []
```

### 10.3 Vocabulary — `cloud-native.yaml`

```yaml
domain: cloud-native
displayName: Cloud Native
description: "Capabilities for Kubernetes-hosted microservices environments"

capabilities:
  observe:
    - key: prometheus-query
      displayName: Prometheus Query
      description: "Issue PromQL queries to Prometheus or any compatible metrics backend"
      relatedFaults: [pod-delete, pod-cpu-hog, pod-memory-hog, pod-network-loss, pod-network-latency, k8s-config-mutation]

    - key: kubernetes-get-pods
      displayName: Kubernetes Get Pods
      description: "List and describe pods in a namespace"
      relatedFaults: [pod-delete, pod-cpu-hog, pod-memory-hog]

    - key: kubernetes-get-events
      displayName: Kubernetes Get Events
      description: "List Kubernetes events to identify recent failures and state changes"
      relatedFaults: [pod-delete, pod-cpu-hog, k8s-config-mutation]

    - key: kubernetes-describe
      displayName: Kubernetes Describe
      description: "Describe any Kubernetes resource (Deployment, Service, ConfigMap, etc.)"
      relatedFaults: [pod-delete, pod-cpu-hog, k8s-config-mutation, pod-network-loss]

    - key: log-query
      displayName: Log Query
      description: "Query container or application logs (Loki, kubectl logs, Elasticsearch, etc.)"
      relatedFaults: [pod-delete, pod-cpu-hog, pod-memory-hog]

    - key: service-mesh-aware
      displayName: Service Mesh Aware
      description: "Query Istio/Envoy metrics and inspect VirtualService routing policies"
      relatedFaults: [pod-network-loss, pod-network-latency]

  act:
    - key: kubernetes-patch
      displayName: Kubernetes Patch
      description: "Patch Kubernetes resources (deployments, configmaps, resource quotas)"
      relatedFaults: [pod-cpu-hog, k8s-config-mutation]

    - key: kubernetes-delete
      displayName: Kubernetes Delete
      description: "Delete Kubernetes resources (pods, services, network policies)"
      relatedFaults: [pod-delete, pod-network-loss]

    - key: kubernetes-restart
      displayName: Kubernetes Restart
      description: "Perform rollout restarts of deployments or statefulsets"
      relatedFaults: [pod-delete, pod-cpu-hog, pod-memory-hog]

    - key: kubernetes-resource-quota
      displayName: Kubernetes Resource Quota
      description: "Manage ResourceQuota objects — diagnose violations and adjust limits"
      relatedFaults: [k8s-config-mutation]

    - key: kubernetes-scale
      displayName: Kubernetes Scale
      description: "Scale Deployment or StatefulSet replica counts"
      relatedFaults: [pod-delete]
```

### 10.4 Vocabulary — `telecom.yaml`

```yaml
domain: telecom
displayName: Telecom
description: "Capabilities for telecom network environments (5G core, IMS, NFV, etc.)"

capabilities:
  observe:
    - key: snmp-query
      displayName: SNMP Query
      description: "Query network device OIDs via SNMP v2c/v3"
      relatedFaults: [link-down-simulation, interface-error-injection, packet-loss-injection]

    - key: netconf-get
      displayName: NETCONF Get
      description: "Fetch device configuration and operational state via NETCONF/YANG"
      relatedFaults: [config-mutation, link-down-simulation]

    - key: alarm-query
      displayName: Alarm Query
      description: "Query the network alarm management system for active and cleared alarms"
      relatedFaults: [link-down-simulation, interface-error-injection, node-failure-simulation]

    - key: topology-traverse
      displayName: Topology Traversal
      description: "Navigate network topology graph to identify affected segments and downstream impact"
      relatedFaults: [link-down-simulation, node-failure-simulation]

    - key: syslog-query
      displayName: Syslog Query
      description: "Query syslog servers for device error and warning messages"
      relatedFaults: [link-down-simulation, interface-error-injection]

    - key: pm-counter-query
      displayName: Performance Counter Query
      description: "Query 3GPP PM counters (e.g., call drop rate, handover success rate)"
      relatedFaults: [packet-loss-injection, node-failure-simulation]

  act:
    - key: netconf-edit-config
      displayName: NETCONF Edit Config
      description: "Push configuration changes to network devices via NETCONF"
      relatedFaults: [config-mutation, link-down-simulation]

    - key: config-rollback
      displayName: Config Rollback
      description: "Rollback device or network function configuration to a previous checkpoint"
      relatedFaults: [config-mutation]

    - key: interface-admin-state
      displayName: Interface Admin State
      description: "Administratively enable or disable a network interface"
      relatedFaults: [link-down-simulation]

    - key: route-policy-update
      displayName: Route Policy Update
      description: "Update routing policies (BGP, OSPF, SR-MPLS) on network devices"
      relatedFaults: [link-down-simulation, config-mutation]

    - key: nf-restart
      displayName: Network Function Restart
      description: "Trigger a restart of a containerized network function (AMF, SMF, UPF, etc.)"
      relatedFaults: [node-failure-simulation]
```

### 10.5 Vocabulary — `health-it.yaml`

```yaml
domain: health-it
displayName: Health IT
description: "Capabilities for healthcare IT environments (FHIR, HL7, clinical systems)"

capabilities:
  observe:
    - key: fhir-read
      displayName: FHIR Read
      description: "Read FHIR R4 resources (Patient, Observation, DiagnosticReport, etc.) from a FHIR server"
      relatedFaults: [service-unavailability, data-corruption-simulation, latency-injection]

    - key: hl7-parse
      displayName: HL7 Parse
      description: "Parse and interpret HL7 v2.x messages from a message queue or interface engine"
      relatedFaults: [message-queue-fault, service-unavailability]

    - key: patient-monitor-query
      displayName: Patient Monitor Query
      description: "Query patient monitoring systems for vital sign anomalies and alert states"
      relatedFaults: [service-unavailability, latency-injection]

    - key: clinical-alert-query
      displayName: Clinical Alert Query
      description: "Query clinical decision support alert queue for active and suppressed alerts"
      relatedFaults: [service-unavailability, data-corruption-simulation]

    - key: audit-log-query
      displayName: Audit Log Query
      description: "Query HIPAA audit logs for access anomalies"
      relatedFaults: [data-corruption-simulation]

  act:
    - key: fhir-write
      displayName: FHIR Write
      description: "Create or update FHIR resources on a FHIR server"
      relatedFaults: [data-corruption-simulation]

    - key: adt-trigger
      displayName: ADT Trigger
      description: "Trigger Admit/Discharge/Transfer workflow in the HIS"
      relatedFaults: [service-unavailability]

    - key: alert-acknowledge
      displayName: Alert Acknowledge
      description: "Acknowledge or escalate a clinical or system alert"
      relatedFaults: [service-unavailability, latency-injection]
```

### 10.6 Vocabulary — `finops.yaml`

```yaml
domain: finops
displayName: FinOps
description: "Capabilities for cloud cost observability and optimization agents"

capabilities:
  observe:
    - key: cost-api-query
      displayName: Cost API Query
      description: "Query cloud provider cost APIs (AWS Cost Explorer, GCP Billing, Azure Cost Mgmt) or OpenCost"
      relatedFaults: [k8s-config-mutation, resource-quota-violation]

    - key: budget-alert-query
      displayName: Budget Alert Query
      description: "Query budget thresholds, forecasts, and current spend against limits"
      relatedFaults: [resource-quota-violation]

    - key: resource-inventory-query
      displayName: Resource Inventory Query
      description: "Enumerate cloud resources (VMs, storage, databases) for rightsizing analysis"
      relatedFaults: [resource-quota-violation, k8s-config-mutation]

    - key: tag-compliance-check
      displayName: Tag Compliance Check
      description: "Identify untagged or mis-tagged cloud resources that break cost allocation"
      relatedFaults: [k8s-config-mutation]

  act:
    - key: rightsizing-apply
      displayName: Apply Rightsizing
      description: "Apply resource rightsizing recommendations (resize VM, adjust K8s resource limits)"
      relatedFaults: [k8s-config-mutation]

    - key: resource-tag-update
      displayName: Resource Tag Update
      description: "Update cost allocation tags on cloud resources"
      relatedFaults: [k8s-config-mutation]

    - key: idle-resource-stop
      displayName: Stop Idle Resource
      description: "Stop or terminate idle cloud resources to reduce spend"
      relatedFaults: [resource-quota-violation]
```

### 10.7 Vocabulary — `itops.yaml`

```yaml
domain: itops
displayName: IT Operations
description: "Capabilities for IT operations agents (monitoring, ITSM, CMDB)"

capabilities:
  observe:
    - key: cmdb-query
      displayName: CMDB Query
      description: "Query a CMDB for asset records, configuration items, and relationships"
      relatedFaults: [service-unavailability, config-mutation]

    - key: monitoring-alert-query
      displayName: Monitoring Alert Query
      description: "Query a monitoring system (Zabbix, Nagios, Datadog, Dynatrace) for active alerts"
      relatedFaults: [service-unavailability, latency-injection]

    - key: log-aggregator-query
      displayName: Log Aggregator Query
      description: "Query centralized log systems (Splunk, ELK, Graylog) for error patterns"
      relatedFaults: [service-unavailability, config-mutation]

    - key: change-calendar-query
      displayName: Change Calendar Query
      description: "Query the change management calendar to correlate incidents with change windows"
      relatedFaults: [config-mutation]

  act:
    - key: ticket-create
      displayName: Create Ticket
      description: "Create an incident or problem ticket in an ITSM system (ServiceNow, Jira, Remedy)"
      relatedFaults: [service-unavailability, config-mutation]

    - key: ticket-update
      displayName: Update Ticket
      description: "Update an existing incident ticket with diagnosis and resolution steps"
      relatedFaults: [service-unavailability]

    - key: runbook-execute
      displayName: Execute Runbook
      description: "Trigger an automated runbook via an orchestration platform (Ansible, Rundeck)"
      relatedFaults: [service-unavailability, config-mutation]

    - key: cmdb-update
      displayName: CMDB Update
      description: "Update configuration item attributes in the CMDB after remediation"
      relatedFaults: [config-mutation]
```

### 10.8 How Capabilities Map to Fault Suggestions

The AI experiment generation engine (Iter 2) uses `relatedFaults` in each capability definition to build a candidate fault list. For a given agent the engine:

1. Collects all capabilities the agent declares
2. Filters to capabilities from domains matching the selected app's `capabilityDomains`
3. Unions the `relatedFaults` lists across matched capabilities
4. Ranks faults by how many of the agent's capabilities they exercise
5. Picks the top-N faults (configurable, default 5)
6. Matches each fault to a suitable target within the selected app

### 10.9 Adding New Capabilities

New capability keys require a PR to the appropriate domain file in `catalog/capabilities/`. The PR must include:

| Field | Required | Notes |
|-------|----------|-------|
| `key` | ✓ | Kebab-case. `<domain-prefix>-<action>` convention e.g., `netconf-get`, `fhir-read` |
| `displayName` | ✓ | Title-case human label |
| `description` | ✓ | One sentence. Start with a verb. What the agent does, not what it is. |
| `relatedFaults[]` | ✓ | Fault names from the relevant domain's fault catalog. Can be empty `[]` for act capabilities with no corresponding fault type yet. |

If the capability belongs to a domain that does not yet have a vocabulary file, create the new `catalog/capabilities/<domain>.yaml` file and declare the domain in `catalog/domains.yaml` in the same PR.

---

## 11. Required Tools — MCP Integration

### 11.1 Tool Name Matching

Tool names in `requiredTools[].name` are matched against the tool calls recorded in the MCP call log by the certifier. Matching is **exact and case-sensitive**. The tool name must be the same string that appears in:
- The agent's MCP server `tools/list` response
- The `tool_call` entries in the Langfuse trace

**Common naming pitfalls:**
- `"execute-promql-query"` ≠ `"Execute PromQL Query"` (wrong case, wrong separators)
- `"Pods:List"` ≠ `"Pods: List in Namespace"` (missing space and qualifier)

### 11.2 MCP Import

When the user provides an MCP server URL during registration:
1. ACE GraphQL server makes a `GET <url>/tools` request (MCP 2024-11-05 spec)
2. Parses the JSON response: `{"tools": [{"name": "...", "description": "..."}, ...]}`
3. Presents the list in the required tools table with all tools pre-selected as critical
4. User unchecks tools that the agent calls only occasionally (not critical)

If the MCP server is not reachable at registration time, the user enters tool names manually. The validation that tool names match is done at certifier score time, not at registration time.

### 11.3 Tool Call Efficiency Scoring

The certifier counts per fault scenario:
- `total_calls`: total MCP tool calls made
- `required_calls_made`: required tools that were called at least `minCallCount` times
- `redundant_calls`: calls to tools not in `requiredTools[]`
- `over_calls`: tools called more than `maxCallCount` times

```
tool_call_efficiency = required_calls_made / (total_calls × 1.0)
```

A score of 1.0 means the agent called exactly the right tools and nothing else. Lower scores indicate over-calling (trying many tools randomly) or under-calling (ignoring important signals).

---

## 12. Evaluation Metrics

### 12.1 `time_to_detect`

**Definition:** Time in seconds from the moment the fault is injected (ChaosEngine `status.experimentStatus.phase = Running`) to the moment the agent emits its first detection event tagged with the correct `notifyId`.

**Measurement:** The certifier compares the ChaosEngine start timestamp (from K8s events) with the agent's first notification timestamp (from Langfuse trace events tagged with `experiment_id = notifyId`).

**Scoring:** Compared against `groundTruth.faultAlertMappings[].maxDetectionTimeSecs`. Score scales linearly from 1.0 (detected within threshold) to 0.0 (never detected or detected after 3× threshold).

**Requires:** Agent must emit a structured log or metric entry containing the `notifyId` value when it decides a fault is present. The exact mechanism is agent-implementation-specific but must produce a Langfuse span with `experiment_id` tag.

### 12.2 `time_to_mitigate`

**Definition:** Time from the agent's detection event to the moment the app's Prometheus alert clears (transitions from `firing` to `resolved`).

**Measurement:** Certifier queries Prometheus for the alert timeline and finds the `resolved` timestamp. Compares with detection timestamp.

**Scoring:** Compared against `groundTruth.faultAlertMappings[].maxMitigationTimeSecs`.

**Note:** This metric requires the agent to actually mitigate the fault (not just detect it). Agents that detect but do not remediate will score 0.0 on this metric if they declare it.

### 12.3 `tool_call_efficiency`

See §11.3.

### 12.4 `root_cause_accuracy`

**Definition:** How accurately the agent identified the root cause of the fault.

**Measurement:** The certifier extracts the agent's root cause statement from the Langfuse trace (a structured output tagged `root_cause`). It submits this statement and the ground truth statement to an LLM judge that scores semantic similarity on a 0.0–1.0 scale.

**Requires:** Agent must produce a structured root cause output. The exact format is flexible but must be capturable from the trace. Recommended: a Langfuse `generation` output with `{"root_cause": "Pod carts-xxxx was OOMKilled due to memory limit of 64Mi"}`.

### 12.5 `remediation_correctness`

**Definition:** Whether the agent's remediation action matched the expected action in the ground truth.

**Measurement:** The certifier identifies the K8s resources that changed during the experiment window (using K8s audit log or diff) and classifies the action type (patch, delete, scale, etc.). Compares against `groundTruth.faultAlertMappings[].expectedRemediation`.

---

## 13. Secret Handling

### 13.1 Why Secrets Are Separate

Argo Workflow YAML is stored in etcd and visible in the Argo Server UI. Any value passed as a workflow parameter or container arg appears in plaintext. API keys must never appear there.

ACE uses a K8s Secret in the `litmus` namespace as the intermediary:

```
User fills form (HTTPS)
    │
    ▼ saveChaosExperiment mutation (GraphQL, TLS)
K8s Secret: ace-agent-secret-<experimentID>
  namespace: litmus
  data:
    OPENAI_API_KEY: <base64-encoded>
    (any other secret type inputs)
    │
    ▼ install-agent Argo step
  --set agent.secretRef=ace-agent-secret-<experimentID>
    │
    ▼ Helm chart renders deployment.yaml
  envFrom:
    - secretRef:
        name: ace-agent-secret-<experimentID>
    │
    ▼ Agent container
  env: OPENAI_API_KEY=sk-...  (only inside the container)
```

### 13.2 Secret Lifecycle

| Event | Action |
|-------|--------|
| First save of experiment | Secret created: `kubectl apply -f` with server-side apply (idempotent) |
| Re-save (user changes config) | Secret updated: server-side apply merges new values |
| User updates API key, re-saves | Secret updated: new key replaces old key |
| Experiment run starts | Secret exists; install-agent passes `--set agent.secretRef=<name>` |
| Experiment run completes | Secret NOT deleted — persists for next run |
| Experiment deleted (user deletes the experiment) | Secret deleted: `kubectl delete secret ace-agent-secret-<experimentID> -n litmus` |
| Key rotation | User re-saves experiment with new key → server-side apply updates Secret |

### 13.3 Secret Naming

`ace-agent-secret-<experimentID>`

Where `<experimentID>` is the stable UUID assigned to the experiment at creation time. It is NOT the run ID — it is the same across all runs of the same experiment. This means:
- The Secret is created once and reused
- The user does not have to re-enter the API key on every run
- The Secret is bound to the experiment, not the agent — different experiments using the same agent have separate Secrets

### 13.4 Multi-Secret Agents

If an agent has multiple `type: secret` inputs (e.g., `OPENAI_API_KEY` and a `PAGERDUTY_TOKEN`), all secret values are stored in the same K8s Secret object as separate keys. The agent container receives all of them as env vars via the single `envFrom.secretRef`.

### 13.5 Secret Security Properties

- Secrets are namespace-scoped to `litmus`
- The `argo-chaos` SA has `get` permission on Secrets in `litmus` (required for `--set agent.secretRef`)
- The agent SA in the app namespace has `get` permission only on the specific Secret by name
- Secrets are not printed in Argo logs (Kubernetes Secret env var injection does not log values)
- Secrets are base64-encoded in etcd (K8s default); encryption at rest is the cluster admin's responsibility

---

## 14. Context Injection

Context injection is how ACE passes runtime values to the agent's Helm chart at the moment the Argo Workflow is submitted. These values are not known at registration time — they are known only when the workflow starts.

### 14.1 Injection Mechanism

The hydration pipeline generates the install-agent Argo step with all context injection values as `--set` args:

```yaml
- name: install-agent
  container:
    image: agentcert/agentcert-install-agent:latest
    args:
      - --folder=flash-agent
      - --namespace={{workflow.parameters.appNamespace}}
      - --set=agent.secretRef=ace-agent-secret-<experimentID>
      - --set=agent.notifyId={{workflow.name}}        # ← context injection
      - --set=agent.workflowUid={{workflow.uid}}      # ← context injection
      - --set=sidecar.upstream={{workflow.parameters.litellmUpstream}}  # ← context injection
      - --set=agent.config.appNamespace={{workflow.parameters.appNamespace}}  # ← context injection
      [user-provided inputs as --set args...]
```

The `{{workflow.name}}` and `{{workflow.uid}}` are Argo template variable references — Argo resolves them before the step container starts. The container receives the final resolved value, not the template string.

### 14.2 Context Injection vs. User Inputs

| Property | Context Injection | User Input |
|----------|------------------|------------|
| When the value is known | At workflow submit time | At experiment save time |
| Who provides it | ACE runtime | The user |
| Appears in the form | No | Yes |
| Goes into Argo YAML | As `{{workflow.xxx}}` reference | As literal value (except secrets) |
| Can be overridden by user | No | Yes |

### 14.3 Generic Wrapper Chart — Required Value Paths

For agents using the generic wrapper, the chart is pre-wired to accept these exact paths:

| Path | What it contains |
|------|-----------------|
| `agent.notifyId` | Argo workflow name |
| `agent.workflowUid` | Argo workflow UID |
| `agent.secretRef` | K8s Secret name for API keys |
| `sidecar.upstream` | LiteLLM proxy URL |
| `agent.config.*` | Any non-secret config values (free-form sub-keys) |

### 14.4 Custom Chart — Required Value Paths

Custom charts must accept the same four mandatory paths. They may name their internal template variables differently as long as the `--set` paths work. Validation tool (§8.1) verifies this.

---

## 15. Generic Agent Wrapper Chart

### 15.1 Architecture

The generic wrapper chart deploys the agent as a single-container Deployment plus:
- A ConfigMap for non-secret environment variables
- A reference to the ACE-managed Secret for secrets
- A ServiceAccount with namespace-scoped RBAC
- Optional: a sidecar container if `sidecar.enabled: true`

### 15.2 Default RBAC

> **Note:** The generic wrapper's RBAC defaults are for agents running in a **cloud-native Kubernetes environment**. Agents in other domains (telecom, health IT, FinOps) typically need no Kubernetes RBAC at all — they talk to external systems (SNMP targets, FHIR servers, cost APIs) via network, not the K8s API. For those agents, set `rbac.enabled: false` in the generic wrapper values to skip Role creation entirely.

The generic wrapper creates a ClusterRole (read-only) + namespace-scoped Role (limited write) for cloud-native domain agents:

```yaml
# ClusterRole — read-only across cluster
rules:
  - apiGroups: [""]
    resources: [pods, events, namespaces, services, endpoints, configmaps]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, replicasets, statefulsets, daemonsets]
    verbs: [get, list, watch]
  - apiGroups: [metrics.k8s.io]
    resources: [pods, nodes]
    verbs: [get, list]

# Role in app namespace — limited write for remediation
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [delete]
  - apiGroups: [apps]
    resources: [deployments, statefulsets]
    verbs: [patch]
    resourceNames: []    # unrestricted within namespace
```

Agents that need more permissions must use a custom Helm chart that explicitly declares those permissions.

### 15.3 Sidecar Support

The generic wrapper supports an optional LLM proxy sidecar (e.g., for Langfuse tracing):

```yaml
sidecar:
  enabled: true
  image: agentcert/ace-sidecar:latest
  upstream: "{{workflow.parameters.litellmUpstream}}"
  port: 4000
```

When `sidecar.enabled: true`, the agent container's `OPENAI_BASE_URL` is automatically set to `http://localhost:4000/v1` (the sidecar's local port). The sidecar forwards to the configured `upstream` and records all LLM calls in Langfuse.

---

## 16. Custom Helm Chart Requirements

For Advanced Register agents, the chart must satisfy these requirements:

### 16.1 Mandatory

1. **Accept `agent.secretRef`** — The chart must create a pod that uses this value as an `envFrom.secretRef.name`:
   ```yaml
   envFrom:
     - secretRef:
         name: {{ .Values.agent.secretRef }}
   ```

2. **Accept `agent.notifyId` and `agent.workflowUid`** — Must pass these as environment variables to the agent container:
   ```yaml
   env:
     - name: ACE_NOTIFY_ID
       value: {{ .Values.agent.notifyId | quote }}
     - name: ACE_WORKFLOW_UID
       value: {{ .Values.agent.workflowUid | quote }}
   ```

3. **Accept `sidecar.upstream`** — If the chart includes a proxy sidecar, must use this value as the upstream URL.

4. **Graceful termination** — The agent pod must terminate within `terminationGracePeriodSeconds: 30`. If the agent needs longer cleanup, use a `preStop` lifecycle hook.

### 16.2 Prohibited

- `hostNetwork: true`
- `hostPID: true`
- `privileged: true` in any container
- `ClusterRoleBinding` to `cluster-admin` or equivalent
- `nodeSelector` on specific node names (prevents scheduling flexibility)
- Hardcoded secrets in `values.yaml`

### 16.3 Recommended

- `resources.requests` and `resources.limits` defined for all containers
- `livenessProbe` and `readinessProbe` for the agent container
- `podAntiAffinity` if replicas > 1
- Image pull policy `IfNotPresent` for pinned tags, `Always` for mutable tags

---

## 17. Agent Install Mechanics

### 17.1 What `install-agent` Does

The `install-agent` binary runs as an Argo Workflow step container. It receives arguments and executes Helm operations.

```
install-agent \
  --folder=<installFolder | chart ref>
  --namespace=<targetNamespace>
  --set=agent.secretRef=ace-agent-secret-<experimentID>
  --set=agent.notifyId=<workflow.name>
  --set=agent.workflowUid=<workflow.uid>
  --set=sidecar.upstream=<litellmUpstream>
  [--set=<helmPath>=<value> ... for each user input]
  --wait
  --timeout=<timeout>
```

### 17.2 Install Sequence

```
1. Validate the secret exists:
   kubectl get secret ace-agent-secret-<experimentID> -n litmus
   └─ If not found: install-agent exits with error
      "Agent secret ace-agent-secret-<experimentID> not found in litmus namespace.
       Save the experiment again to recreate the secret."

2. Helm install
   helm install <agentName>-<runID-short> ./chart \
     --namespace <targetNamespace> \
     --timeout <timeout> \
     --wait \
     [--set args...]

3. Wait for agent readiness
   kubectl wait pod -n <targetNamespace> \
     -l app.kubernetes.io/name=<agentName> \
     --for=condition=Ready \
     --timeout=<timeout>

4. Annotate agent pod with ACE metadata
   kubectl annotate pod <podName> -n <targetNamespace> \
     ace.io/agent=<agentName> \
     ace.io/workflow-uid=<uid> \
     ace.io/experiment-id=<experimentID>
```

### 17.3 Uninstall Sequence

```
helm uninstall <agentName>-<runID-short> -n <targetNamespace>
```

The Helm uninstall runs in the Argo `onExit` handler — guaranteed to run even if the workflow fails.

---

## 18. Agent Lifecycle in an Experiment

```
T+0:00  install-app completes → app is running and healthy
T+0:01  install-agent step begins
          → secret exists check passes
          → helm install flash-agent-<uid8>
          → agent pod comes up Running
          → agent begins scanning (Prometheus, K8s events)
T+0:30  [agent idle scan loop running]
T+0:31  First fault injected (pod-delete on carts)
T+0:32  Prometheus alert fires: KubePodNotReady{namespace=sock-shop,pod=carts-...}
T+0:35  Flash agent detects the alert via PromQL scan
T+0:35  Flash agent emits detection event:
          Langfuse span: {experiment_id: <notifyId>, event: "fault_detected", service: "carts"}
          ← certifier records time_to_detect = 35 - 31 = 4 seconds
T+0:40  Flash agent identifies root cause via K8s events + describe
          Output: {"root_cause": "Pod carts-xxxx deleted, OOMKilled prior to deletion"}
          ← certifier records root_cause_accuracy via LLM judge
T+0:42  Flash agent applies remediation: patch deployment to increase memory limit
          ← certifier records remediation_correctness
T+0:55  carts pod comes back Running; alert clears
          ← certifier records time_to_mitigate = 55 - 35 = 20 seconds
T+1:00  Fault duration expires; ChaosEngine completes
T+1:01  [next fault begins if experiment has more faults]
T+2:00  All faults complete
T+2:01  uninstall-agent runs: helm uninstall flash-agent-<uid8>
T+2:05  uninstall-app runs: helm uninstall sock-shop
T+2:10  Workflow completes
T+2:11  Certifier generates report for this run
```

---

## 19. Multi-Agent Experiments

Iter 1 supports one agent per experiment. This section defines the design for Iter 2.

### 19.1 Use Cases

- **Agent comparison**: Run two agents simultaneously under the same fault conditions to compare their performance
- **Agent collaboration**: One agent detects, another remediates (specialized roles)
- **Agent ensemble**: Multiple agents observe and an orchestrator decides which action to take

### 19.2 Schema Extension (Iter 2)

```yaml
# In the experiment node graph (Iter 2)
agentNodes:
  - agentName: flash-agent
    role: primary      # primary | secondary | observer
    inputs: { ... }

  - agentName: k8s-agent
    role: secondary
    inputs: { ... }
```

### 19.3 Conflict Prevention

Multiple agent pods in the same namespace may both attempt remediation for the same fault. Iter 2 will define a conflict prevention protocol:
- `primary` agent has exclusive write access during its action window
- `secondary` agent acts only if `primary` does not act within `primaryTimeoutSecs`
- `observer` agent never takes actions — observe and report only

---

## 20. Agent Versioning

### 20.1 Version Pinning in Experiments

When an experiment is saved, the agent version is stored in `SavedExperimentMetadata.AgentVersion`. At run time:

- `AgentVersion == current version` → run normally
- `AgentVersion < current version` → warning in Chaos Studio: "This experiment was built with Flash Agent v1.0 but v1.1 is available. Re-save to use the latest version."

### 20.2 Image Tag Stability

The agent image in `spec.install.image` is part of the agent spec and is versioned with the spec. If the user pushes a new image to the same tag (e.g., updates `myorg/flash-agent:1.0.0` in place), the spec version should be bumped to signal that certification results may differ.

### 20.3 Breaking vs. Non-Breaking Changes

| Change type | Version bump required | Certified experiments affected |
|------------|----------------------|-------------------------------|
| New capability added | Minor bump | No |
| Capability removed | Major bump | Warning — experiments relying on removed capability |
| `requiredTools[]` changed | Minor bump | Warning — certifier will re-score tools |
| Image updated (same tag) | Patch bump | Results may differ — recommend re-run |
| `inputs[]` field added (optional) | Minor bump | No |
| `inputs[]` field removed | Major bump | Experiments using removed field fail validation |
| `contextInjection[]` path changed | Major bump | Existing experiments break |

---

## 21. GraphQL API

### 21.1 Queries

```graphql
query ListAgents($projectID: ID!) {
  listAgents(projectID: $projectID): [AgentSpec!]!
}

query GetAgent($projectID: ID!, $agentName: String!) {
  getAgent(projectID: $projectID, agentName: $agentName): AgentSpec
}

# Model Library queries
query ListModelConfigs($projectID: ID!): [ModelConfig!]!
query GetModelConfig($projectID: ID!, $alias: String!): ModelConfig
```

### 21.2 Mutations

```graphql
# Register a new private agent
mutation RegisterAgent($projectID: ID!, $input: RegisterAgentInput!) {
  registerAgent(projectID: $projectID, input: $input): AgentRegistrationResult!
}

# Update an existing registered agent
mutation UpdateAgent($projectID: ID!, $agentName: String!, $input: UpdateAgentInput!) {
  updateAgent(projectID: $projectID, agentName: $agentName, input: $input): AgentSpec!
}

# Import required tools from an MCP server
mutation ImportMCPTools($serverURL: String!): MCPImportResult!

# Model Library mutations
mutation CreateModelConfig($projectID: ID!, $input: ModelConfigInput!): ModelConfigResult!
mutation UpdateModelConfig($projectID: ID!, $alias: String!, $input: ModelConfigInput!): ModelConfig!
mutation DeleteModelConfig($projectID: ID!, $alias: String!): Boolean!
mutation TestModelConfig($input: ModelConfigInput!): ModelConfigTestResult!
```

### 21.3 Type Definitions

```graphql
type AgentSpec {
  name:               String!
  displayName:        String!
  version:            String!
  tier:               String!        # "official" | "community" | "private"
  description:        AgentDescription!
  install:            AgentInstallSpec!
  inputs:             [AgentInput!]!
  contextInjection:   [ContextInjection!]!
  capabilities:       [String!]!
  requiredTools:      [RequiredTool!]!
  evaluationMetrics:  [String!]!
  compatibility:      AgentCompatibility!
  schemaVersion:      String!
}

type AgentDescription {
  short:     String!
  long:      String!
  approach:  String
  llmDependent: Boolean!
}

type AgentInstallSpec {
  method:       String!
  image:        String
  folder:       String
  namespace:    String!
  timeout:      String!
  resources:    ResourceSpec!
}

type AgentInput {
  key:          String!
  displayName:  String!
  description:  String
  type:         String!       # "secret" | "string" | "integer" | "boolean" | "enum"
  required:     Boolean!
  default:      String
  placeholder:  String
  helmPath:     String!
  values:       [String!]
  min:          Int
  max:          Int
  unit:         String
  advanced:     Boolean!
  group:        String
}

type ContextInjection {
  helmPath:     String!
  source:       String!
  required:     Boolean!
  description:  String
}

type RequiredTool {
  name:          String!
  purpose:       String
  critical:      Boolean!
  minCallCount:  Int!
  maxCallCount:  Int
}

type AgentCompatibility {
  supportedApps:    [String!]!
  unsupportedApps:  [String!]!
  minimumFaultCount: Int!
  maximumFaultCount: Int!
}

type AgentRegistrationResult {
  agent:   AgentSpec!
  message: String!
  prURL:   String    # populated if community contribution PR was opened
}

type MCPImportResult {
  tools:   [String!]!   # tool names discovered
  errors:  [String!]!   # any parsing errors
}

type ModelConfig {
  alias:           String!        # User-chosen alias, e.g. "my-openai-gpt4o"
  provider:        String!        # "openai" | "anthropic" | "google" | "azure" | "ollama" | "custom"
  model:           String!        # Model name, e.g. "gpt-4o"
  baseURL:         String         # Custom base URL (for Azure, Ollama, custom endpoints)
  secretRef:       String!        # K8s Secret name in litmus namespace holding the API key
  litellmDeployId: String!        # Internal — LiteLLM deployment ID; never exposed in UI
  agentsUsing:     [String!]!     # Agent names referencing this config
  status:          String!        # "active" | "error" | "untested"
  lastTested:      String         # ISO timestamp of last successful test
}

input ModelConfigInput {
  alias:    String!
  provider: String!
  model:    String!
  baseURL:  String
  apiKey:   String!               # Write-only; stored in K8s Secret, never returned
}

type ModelConfigResult {
  config:   ModelConfig!
  message:  String!
}

type ModelConfigTestResult {
  success:          Boolean!
  latencyMs:        Int
  errorMessage:     String         # populated on failure
}
```

### 21.4 Resolver Notes

- `listAgents`: Returns catalog agents (from `catalog/agents/**/*.yaml`) plus project-private agents (from database). Private agents are filtered by `projectID`.
- `registerAgent`: Creates private agent record in database. Optionally triggers community catalog PR generation.
- `importMCPTools`: Makes an outbound HTTP call to the provided URL. Timeout: 10 seconds. The GraphQL server must have network egress to the MCP server URL (not always guaranteed in cluster-internal deployments — document this).

---

## 22. K8s Resources Created Per Run

For a single experiment run using flash-agent:

| Resource | Namespace | Created by | Deleted by |
|----------|-----------|-----------|-----------|
| Secret `ace-agent-secret-<expID>` | `litmus` | `saveChaosExperiment` mutation | `deleteExperiment` mutation |
| Helm release `flash-agent-<uid8>` | app namespace | `install-agent` step | `uninstall-agent` onExit |
| Deployment `flash-agent` | app namespace | `install-agent` (via Helm) | `uninstall-agent` (via Helm) |
| ServiceAccount `flash-agent` | app namespace | `install-agent` (via Helm) | `uninstall-agent` (via Helm) |
| ClusterRole `flash-agent-reader` | cluster | `install-agent` (via Helm) | `uninstall-agent` (via Helm) |
| ClusterRoleBinding | cluster | `install-agent` (via Helm) | `uninstall-agent` (via Helm) |
| ConfigMap `flash-agent-config` | app namespace | `install-agent` (via Helm) | `uninstall-agent` (via Helm) |

The Secret in `litmus` persists across runs — it is NOT created/deleted per run.

---

## 23. Error States & Handling

| Error | When | User-Facing Message | Recovery |
|-------|------|--------------------|---------||
| Secret not found at install time | install-agent step | "Agent secret `ace-agent-secret-<expID>` not found. Save the experiment again." | User re-saves; secret is recreated |
| Agent pod crash loop | After helm install, during wait | "Agent pod `flash-agent-xxxx` is in CrashLoopBackOff. Check image and environment config." + kubectl describe output | User checks image, fixes config, re-saves |
| Image pull failure | Helm install wait | "Image `myorg/flash-agent:1.0.0` could not be pulled. Check the image name and registry access." | User verifies image exists, updates if needed |
| notifyId missing from agent output | At certifier score time | "time_to_detect could not be measured: no detection event with notifyId found in traces." | Agent developer fixes notification emission |
| Required tool not called | At certifier score time | "tool_call_efficiency: tool `Execute PromQL Query` (critical) was not called during this run." | Agent developer fixes tool usage |
| Context injection path missing in chart | At chart validation | "Chart does not accept `--set agent.notifyId`. Required path missing in values.yaml." | Chart developer adds missing value path |
| Agent takes too long to start | install-agent timeout | "Agent did not reach Ready state within 20m." | User increases `installTimeout` in agent spec |
| MCP server unreachable for import | importMCPTools mutation | "Could not reach MCP server at `<url>`. Tools must be entered manually." | User enters tool names manually |
| Duplicate agent name | registerAgent mutation | "An agent named `flash-agent` is already registered for this project." | User picks a different name or updates the existing registration |

---

## 24. Security Considerations

- **API keys never in Argo YAML.** Enforced by architecture — secret inputs are always stored in K8s Secrets and referenced by name, never as workflow parameters.
- **Agent RBAC is namespace-scoped.** Generic wrapper creates a ClusterRole for reads but only a namespace-scoped Role for write operations. Agents cannot write to other namespaces.
- **No cluster-admin.** Agents that require cluster-admin RBAC are rejected at chart validation time.
- **Image provenance.** For public catalog agents (official/community), the container image must be from a verified registry. Community agents list their image in the spec; ACE does not sign or verify images beyond that.
- **Private agents.** Private agent registrations (not in the public catalog) are scoped to a single ACE project. The agent spec (including image name, capabilities declaration) is not visible to other projects.
- **Secret rotation.** Users can update their API key by re-saving the experiment. The old key in the K8s Secret is overwritten immediately via server-side apply.
- **LLM call routing.** All LLM calls from agents using the generic wrapper's sidecar go through the LiteLLM proxy, which enforces rate limits and records traces in Langfuse. Direct calls to OpenAI/Anthropic are not blocked for custom chart agents but will not be traced.

---

## 25. Forward Compatibility

| Feature | Schema readiness in Iter 1 |
|---------|---------------------------|
| AI experiment generation | `spec.capabilities[]` + `spec.description.long` + `spec.requiredTools[].purpose` are the exact inputs the AI engine uses. All populated in Iter 1. |
| Multi-agent experiments | `spec.compatibility.maximumFaultCount` exists; multi-agent schema extension reserved under `agentNodes[]` |
| False positive scoring | `evaluationMetrics: [false_positive_rate]` can be declared; certifier ignores it in Iter 1 |
| Blast radius scoring | `evaluationMetrics: [blast_radius]` can be declared; certifier ignores it in Iter 1 |
| Agent version locking | `metadata.version` + `SavedExperimentMetadata.AgentVersion` in Iter 1 |
| Private catalog for enterprise | `metadata.tier: private` + project-scoped storage in Iter 1 |
| Agent marketplace (community sharing) | `metadata.repository` + community tier registration in Iter 1; discovery/search UI in Iter 2 |
| Multi-provider LLM | `llmConfig.provider` + `allowedModels[]` schema in Iter 1; Anthropic/Google proxy ports in sidecar in Iter 2 |
| Cross-project model sharing | Model Library is project-scoped in Iter 1; org-level sharing in Iter 2 |

---

## 26. Model Library

The Model Library is the ACE screen where users manage their LLM model configurations. It is the single source of truth for which provider, model, and API key an agent uses — decoupling that concern from both the agent spec and the experiment definition.

### 26.1 Screen Layout

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  ACE  >  Settings  >  Model Library                     [+ Add Model]       │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  ALIAS               PROVIDER   MODEL              AGENTS   STATUS   │  │
│  │  ────────────────────────────────────────────────────────────────    │  │
│  │  my-openai-gpt4o     OpenAI     gpt-4o             3        ✓ Active │  │
│  │  my-anthropic        Anthropic  claude-3-5-sonnet  1        ✓ Active │  │
│  │  azure-gpt4          Azure      gpt-4              0        ✓ Active │  │
│  │  team-ollama         Custom     llama3.1:70b        2        ✓ Active │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  API keys are stored as K8s Secrets in the litmus namespace.               │
│  ACE never stores keys in plain text or returns them via API.              │
│                                                                             │
│  Need advanced routing, fallback chains, or spend limits?                  │
│  [Open LiteLLM Dashboard ↗]  (opens LiteLLM UI in new tab)                │
└─────────────────────────────────────────────────────────────────────────────┘
```

Clicking a row expands to show:
- Provider + model
- Last tested timestamp + latency
- Agents currently using this config
- [Test Connection] button
- [Rotate Key] button (prompts for new key, updates Secret in place)
- [Delete] button (disabled if agents are using it)

### 26.2 Add Model Dialog

Reuses the same form as Step 3 of the agent registration wizard:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Add Model Configuration                                                    │
│                                                                             │
│  Alias       [my-openai-gpt4o                  ]  (your reference name)    │
│  Provider    [OpenAI          ▼]                                            │
│  Model       [gpt-4o          ▼]   ○ Custom: [______________]              │
│  API Key     [sk-••••••••••••••••••••••••••••••••]  👁                      │
│  Base URL    [https://api.openai.com/v1]  (leave blank for default)        │
│                                                                             │
│  [Test Connection]  ──→  ✓ gpt-4o responded in 342ms                       │
│                                                                             │
│  [Cancel]                                              [Save]              │
└─────────────────────────────────────────────────────────────────────────────┘
```

Test Connection is required before Save is enabled.

### 26.3 Key Rotation

Users can update the API key for an existing Model Configuration without re-registering all agents that reference it:

1. User clicks [Rotate Key] on a Model Library entry
2. ACE prompts for the new key
3. ACE updates the K8s Secret in-place (`kubectl patch secret`)
4. All agents using this config automatically use the new key on their next run
5. No changes required to `agent.yaml` or any experiment definition

### 26.4 Storage Architecture

Each Model Library entry maps to:

| Resource | Description |
|---|---|
| DB record | Stores alias, provider, model, baseURL, `litellmDeployId`, `secretRef` |
| K8s Secret `ace-model-<alias>-<projectID>` in `litmus` namespace | Stores the API key as `API_KEY` data field |
| LiteLLM model entry | Registered via LiteLLM's `/config/add_model` API; deployment ID stored in DB |

The `litellmDeployId` is internal — it is the deployment name that the sidecar's `upstream` points to. It is never shown in the UI or returned via GraphQL.

### 26.5 Difference Between Model Library Secrets and Experiment Secrets

| | Model Library Secret | Experiment Secret |
|---|---|---|
| Name | `ace-model-<alias>-<projectID>` | `ace-agent-secret-<experimentID>` |
| Contains | LLM API key | Other agent secrets (PagerDuty, JIRA, etc.) |
| Scoped to | Project | Experiment |
| Created when | User saves Model Config | User saves Experiment |
| Deleted when | User deletes Model Config | User deletes Experiment |
| Referenced by | LiteLLM sidecar upstream | `envFrom.secretRef` in agent container |

### 26.6 Certifier Observability

When an agent runs through the LiteLLM-routed sidecar, LiteLLM tags all Langfuse traces with:
- `ace_run_id`: the experiment run ID
- `model`: the resolved model name
- `provider`: the provider

This allows the certifier to include model metadata in the certification report — useful for comparing the same agent across different models (gpt-4o vs claude-3-5-sonnet scoring comparison).
