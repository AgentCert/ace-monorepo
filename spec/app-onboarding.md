# ACE — App Onboarding Specification

**Version:** 1.0  
**Status:** Draft  
**Scope:** Defines the complete flow for how applications enter the ACE catalog — both consuming an existing catalog app and contributing a new one.

---

## Table of Contents

1. [Purpose & Scope](#1-purpose--scope)
2. [Terminology](#2-terminology)
3. [User Personas](#3-user-personas)
4. [Catalog Architecture](#4-catalog-architecture)
5. [App Spec Schema — Complete Field Reference](#5-app-spec-schema--complete-field-reference)
6. [User Journey A — Pick From Catalog](#6-user-journey-a--pick-from-catalog)
7. [User Journey B — Contribute a New App](#7-user-journey-b--contribute-a-new-app)
8. [Contribution Wizard — Screen by Screen](#8-contribution-wizard--screen-by-screen)
9. [App Install Mechanics](#9-app-install-mechanics)
10. [Fresh Install Guarantee](#10-fresh-install-guarantee)
11. [Microservice Fault Targeting](#11-microservice-fault-targeting)
12. [Observability Requirements](#12-observability-requirements)
13. [Fault Compatibility Matrix](#13-fault-compatibility-matrix)
14. [RBAC Requirements](#14-rbac-requirements)
15. [Image Registry Handling](#15-image-registry-handling)
16. [Configurable Install Parameters](#16-configurable-install-parameters)
17. [GraphQL API](#17-graphql-api)
18. [K8s Resources Created Per Run](#18-k8s-resources-created-per-run)
19. [Error States & Handling](#19-error-states--handling)
20. [Catalog Review & Publication Process](#20-catalog-review--publication-process)
21. [Versioning & Compatibility](#21-versioning--compatibility)
22. [Security Considerations](#22-security-considerations)
23. [Forward Compatibility](#23-forward-compatibility)

---

## 1. Purpose & Scope

ACE is a certification platform for AI agents of any type. To certify an agent, it must be tested inside a realistic application environment — an environment it did not bring itself. ACE provides a **catalog of standard application environments** that represent real-world domains: cloud-native, telecom, health IT, ITOps, FinOps, and others. The agent's domain determines which catalog apps are relevant — a telecom NOC agent tests against a telecom environment, a cloud-native agent against Sock Shop or OTel Demo, and so on.

This specification defines:

- How a user picks an existing app from the catalog to use in an experiment
- How a user contributes a new app to the catalog when their domain is not yet represented
- Every field, validation rule, UI screen, backend mechanic, and error case involved in both flows

**What this spec does NOT cover:**
- Experiment creation (Phase 3 spec)
- Agent onboarding (Agent Onboarding spec)
- The certifier scoring pipeline

---

## 2. Terminology

| Term | Definition |
|------|-----------|
| **Catalog** | The registry of all available app environments in ACE |
| **App** | A complete, installable application environment in the catalog (e.g., Sock Shop, OTel Demo) |
| **App Spec** | The `app.yaml` file that describes an app to ACE — the machine-readable contract |
| **Microservice** | A fault-targetable unit within an app (a Deployment or StatefulSet with a known K8s label) |
| **Official Tier** | Apps curated, tested, and maintained by the ACE core team |
| **Community Tier** | Apps contributed by users; functional but not deeply curated |
| **Domain** | A classification grouping (e.g., `cloud-native`, `telecom`, `health-it`) |
| **Fresh Install** | The guarantee that every experiment run starts with a clean installation of the app — no shared state between runs |
| **Fault Compatibility** | A declaration of which chaos faults are meaningful for this app |
| **Ground Truth** | The expected alert → root cause mapping used by the certifier |
| **Contribution Wizard** | The UI flow that guides a user through adding a new app to the catalog |
| **Helm Wrapper** | The ACE-generated Helm chart scaffold when a contributor provides raw manifests |
| **install-app** | The ACE binary that installs/uninstalls an app using its Helm chart |

---

## 3. User Personas

### 3.1 The Certifier (primary user)

A user who has built an AI agent of any type and wants to certify it. They did NOT build the app. They pick an app from the catalog that represents their agent's target domain — a cloud-native agent picks Sock Shop or OTel Demo, a telecom agent picks a 5G core simulation, a health IT agent picks a FHIR services stack — and runs their agent against it.

**What they need from app onboarding:** A catalog with enough domain coverage that they can find a suitable environment. A simple picker in Chaos Studio. No understanding of Helm or K8s chaos engineering required.

### 3.2 The Domain Contributor

A user (or team) whose domain is not yet in the catalog. They have expertise in their domain (e.g., telecom infrastructure) and want to contribute a representative environment so their team — and the broader community — can certify agents against it.

**What they need from app onboarding:** A clear, guided contribution path. They may understand their app's architecture deeply but not necessarily Helm chart authoring or Litmus internals. The contribution wizard should handle the complexity.

### 3.3 The ACE Administrator

A user who manages an ACE deployment for their organization. They may want to add internal proprietary apps to a private catalog without contributing them publicly.

**What they need:** The ability to add apps to a local/private catalog without going through the public PR review process.

---

## 4. Catalog Architecture

### 4.1 Overview

The catalog is a directory tree inside the ACE monorepo. The GraphQL server reads from it at startup and on reload. There is no database — the catalog is code.

```
catalog/
├── CATALOG.md                        # human-readable index of all apps
├── apps/
│   ├── official/                     # ACE core team curated
│   │   ├── sock-shop/
│   │   │   ├── app.yaml              # the spec (machine-readable)
│   │   │   ├── chart/                # Helm chart
│   │   │   │   ├── Chart.yaml
│   │   │   │   ├── values.yaml
│   │   │   │   └── templates/
│   │   │   ├── ground-truth/
│   │   │   │   └── ground_truth_v1.yaml
│   │   │   ├── docs/
│   │   │   │   └── README.md
│   │   │   └── .validate.yaml        # CI validation config
│   │   └── otel-demo/
│   │       └── ...
│   └── community/                    # user-contributed
│       └── telecom-5g-core/
│           ├── app.yaml
│           ├── chart/                # OR chart-ref.yaml pointing to external chart
│           ├── ground-truth/         # optional for community tier
│           └── docs/
│               └── README.md
└── domains.yaml                      # domain taxonomy definition
```

### 4.2 Catalog Loading

The GraphQL server's `CatalogService` loads all `app.yaml` files from `catalog/apps/**/*.yaml` at startup. It builds an in-memory index keyed by `metadata.name`. The index is rebuilt on SIGHUP (for zero-downtime updates without restart).

### 4.3 Tier System

| Property | Official | Community |
|----------|----------|-----------|
| Who maintains | ACE core team | Contributor |
| Review process | Full review, CI gate, load test verified | Basic CI gate (schema valid, chart lints) |
| Fault compatibility | Complete matrix required | Partial acceptable |
| Ground truth | Required for certifier | Optional |
| Load test | Defined and verified | Optional |
| SLA | ACE maintains compatibility | Contributor maintains |
| Shown in Chaos Studio | Prominently, with domain badge | Listed, marked as Community |

### 4.4 Domain Taxonomy

Defined in `catalog/domains.yaml`:

```yaml
domains:
  - id: cloud-native
    displayName: Cloud Native
    description: "Kubernetes-native microservices applications"
    icon: cloud
    exampleApps: [sock-shop, otel-demo]

  - id: service-mesh
    displayName: Service Mesh
    description: "Applications with Istio/Envoy mesh instrumentation"
    icon: mesh
    exampleApps: [bookinfo]

  - id: telecom
    displayName: Telecom
    description: "5G core, IMS, NFV workloads"
    icon: signal
    exampleApps: []   # none yet — invite contributors

  - id: health-it
    displayName: Health IT
    description: "FHIR, HL7 services, clinical workflows"
    icon: health
    exampleApps: []

  - id: itops
    displayName: IT Operations
    description: "Monitoring stacks, CMDB, ticketing systems"
    icon: ops
    exampleApps: []

  - id: finops
    displayName: FinOps / Financial
    description: "Cost management, financial transaction services"
    icon: finance
    exampleApps: []
```

### 4.5 Versioning

Each app has a semantic version in `metadata.version`. Experiments saved against an app lock the version at save time. If the catalog app is upgraded (e.g., sock-shop goes from `1.0.0` to `1.1.0`), existing experiments show a "Schema updated — re-save to use latest" warning but continue to work against their locked version.

Version bump policy:
- **Patch** (1.0.x): bug fixes to chart, no schema changes
- **Minor** (1.x.0): new microservices added, new optional fields in spec
- **Major** (x.0.0): breaking — namespace changes, microservice renames, incompatible values changes

---

## 5. App Spec Schema — Complete Field Reference

The `app.yaml` file is the machine-readable contract. The GraphQL server, hydration pipeline, and Chaos Studio all read from this file. No other source of truth for app metadata exists.

### 5.1 Top-Level Structure

```yaml
apiVersion: ace.io/v1
kind: AppCatalogEntry
metadata: { ... }           # identity & provenance
spec:
  description: { ... }      # human-facing descriptions and domain tags
  install: { ... }          # how to install the app
  healthProbe: { ... }      # how to verify the app is ready
  loadTest: { ... }         # traffic generation
  microservices: [ ... ]    # fault-targetable units
  observability: { ... }    # Prometheus alert rules and ServiceMonitor
  faultCompatibility: [ ... ] # which faults are valid for this app
  groundTruth: { ... }      # certifier fault→alert mapping
  rbac: { ... }             # required RBAC for chaos operations
  inputs: [ ... ]           # configurable parameters at experiment build time
```

### 5.2 `metadata` Block

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `metadata.name` | string | ✓ | Kebab-case. Stable primary key. **Cannot be changed after any experiment references this app.** Used in saved experiment metadata, certifier reports, and certification badges. |
| `metadata.displayName` | string | ✓ | Human-readable name shown in Chaos Studio. May include spaces and mixed case. |
| `metadata.version` | string | ✓ | SemVer string (e.g., `"1.0.0"`). Bumped by maintainer on any change. |
| `metadata.tier` | enum | ✓ | `official` or `community`. Set by the catalog review process, not by the contributor. Community contributions always start as `community`. |
| `metadata.domain` | string | ✓ | Primary domain from `domains.yaml`. Must match an `id` in that file. |
| `metadata.capabilityDomains` | string[] | ✓ | Which capability vocabulary files apply to agents testing against this app. e.g., `["cloud-native", "common"]` for Sock Shop; `["telecom", "common"]` for a 5G core sim. Chaos Studio uses this to filter which agent capabilities are shown when this app is selected. Must be valid domain IDs from `catalog/capabilities/`. |
| `metadata.tags` | string[] | — | Additional searchable tags. Free-form, lowercase. e.g., `["microservices", "mongodb", "rabbitmq"]` |
| `metadata.maintainers` | object[] | ✓ | At least one maintainer with `name` and `email`. |
| `metadata.license` | string | — | SPDX license identifier (e.g., `"Apache-2.0"`). Required for Official tier. |
| `metadata.repository` | string | — | URL to the upstream source repo (not the ACE catalog fork). |
| `metadata.createdAt` | string | auto | ISO-8601 date. Set by CI on first merge. Do not set manually. |
| `metadata.updatedAt` | string | auto | ISO-8601 date. Set by CI on each merge. |

### 5.3 `spec.description` Block

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description.short` | string | ✓ | ≤ 120 characters. Shown in catalog card. |
| `description.long` | string | ✓ | Full description. Markdown supported. Shown in app detail page. |
| `description.suitableFor` | string[] | ✓ | Plain-language statements of which agent types benefit from this app. e.g., `"Agents that observe Kubernetes pod health"`, `"Agents with SNMP or NETCONF capabilities"`, `"Agents that query FHIR endpoints"`. Used as catalog search hints and shown on the app detail card. |
| `description.notSuitableFor` | string[] | — | Plain-language statements of what this app does NOT support. Prevents misconfigured experiments. e.g., `"Agents requiring service mesh (Istio not installed)"` |

### 5.4 `spec.install` Block

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `install.method` | enum | ✓ | `helm` — uses chart in `chart/` subdirectory. `external-helm` — references a chart in a Helm repo. `manifests` — raw K8s YAML applied via kubectl. |
| `install.folder` | string | ✓ (helm) | Directory name passed as `--folder` to `install-app`. Must match the `chart/` subdirectory name exactly. |
| `install.chartRef.repo` | string | ✓ (external-helm) | Helm repository URL. e.g., `https://charts.bitnami.com/bitnami` |
| `install.chartRef.chart` | string | ✓ (external-helm) | Chart name within the repo. |
| `install.chartRef.version` | string | ✓ (external-helm) | Pinned chart version. Must be pinned — floating versions are rejected by CI. |
| `install.namespace.default` | string | ✓ | Default Kubernetes namespace for the app. |
| `install.namespace.configurable` | bool | — | Default: `false`. If `true`, user can override the namespace in the experiment form. (Iter 2: required `true` for dynamic namespace support) |
| `install.timeout` | string | ✓ | Duration string (e.g., `"30m"`). Passed to `helm install --timeout`. |
| `install.wait` | bool | — | Default: `true`. If `true`, `install-app` blocks until all pods are Ready. Do not set `false` unless the app has an alternative readiness signal. |
| `install.additionalManifests` | string[] | — | Paths to additional YAML files applied after Helm install (e.g., NetworkPolicy, additional RBAC). Relative to the app's catalog directory. |

### 5.5 `spec.healthProbe` Block

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `healthProbe.url` | string | ✓ | URL template. **Must use `{{.AppNamespace}}` instead of hardcoded namespace.** e.g., `http://front-end.{{.AppNamespace}}.svc.cluster.local:80` |
| `healthProbe.expectedStatus` | string | ✓ | HTTP status code string (e.g., `"200"`). The health check fails if the response status does not match exactly. |
| `healthProbe.initialDelaySeconds` | int | — | Default: `30`. Seconds to wait after `install-app` completes before first probe attempt. |
| `healthProbe.periodSeconds` | int | — | Default: `10`. Interval between probe attempts. |
| `healthProbe.failureThreshold` | int | — | Default: `6`. Number of consecutive failures before the install step fails. Total probe time = `initialDelaySeconds + (periodSeconds × failureThreshold)`. |
| `healthProbe.headers` | map | — | HTTP headers to include in the probe request. Useful for apps that require a Host header or auth token for the health endpoint. |
| `healthProbe.insecureSkipTLS` | bool | — | Default: `false`. Set `true` only for apps with self-signed certs in dev environments. |

### 5.6 `spec.loadTest` Block

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `loadTest.enabled` | bool | ✓ | If `false`, the load test Argo step is omitted from generated experiments entirely. Set `false` for apps that ship a built-in traffic generator (e.g., OTel Demo). |
| `loadTest.method` | enum | ✓ (if enabled) | `deployer` — uses `litmus-app-deployer` container. `job` — custom K8s Job spec. `external` — app has its own generator, no install needed. |
| `loadTest.image` | string | ✓ (deployer) | Docker image for the load generator. Goes through image resolver — use unqualified name, registry is applied at generation time. |
| `loadTest.args` | string[] | ✓ (deployer) | Args passed to the load test container. |
| `loadTest.installNamespace` | string | — | Namespace to install the load generator into. Default: `loadtest`. |
| `loadTest.jobSpec` | object | ✓ (job) | Full K8s Job spec (inline YAML object). The `namespace` field is templated with `{{.AppNamespace}}`. |

### 5.7 `spec.microservices[]` Block

One entry per fault-targetable unit. A "microservice" in this context means any Kubernetes Deployment, StatefulSet, or DaemonSet that can be independently targeted for fault injection.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | ✓ | Kebab-case. Stable key. Used in experiment node labels and certifier reports. Cannot change after any experiment references it. |
| `displayName` | string | — | Human-readable. Shown in fault targeting dropdowns. Defaults to `name` if absent. |
| `description` | string | — | What this service does. Shown as tooltip in Chaos Studio. |
| `k8s.label` | string | ✓ | Kubernetes label selector (e.g., `"name=carts"`). Must match exactly one Deployment/StatefulSet in the app namespace. **This is the `applabel` used in ChaosEngine specs.** |
| `k8s.kind` | string | ✓ | Resource kind: `deployment`, `statefulset`, or `daemonset`. Lowercase. Used as `appkind` in ChaosEngine. |
| `k8s.namespace` | string | — | Override namespace for this specific service. Default: `{{.AppNamespace}}`. Only needed for apps where some services run in a different namespace. |
| `k8s.containerName` | string | — | Target container name within the pod. Required for faults that target a specific container (e.g., pod-cpu-hog with multiple containers). If omitted, the first container is targeted. |
| `relevantFaults` | string[] | — | Fault names from `faultCompatibility` that make meaningful chaos for this service. Used by Chaos Studio to suggest fault options when this service is targeted. If omitted, all compatible faults are offered. |
| `criticality` | enum | — | `high`, `medium`, or `low`. Affects certifier scoring weight. A `high` criticality service failure that the agent does not detect scores worse than a `low` criticality failure. Default: `medium`. |
| `dependsOn` | string[] | — | Names of other microservices in this app that this service depends on. Used to build the dependency graph shown in Chaos Studio and to warn users when targeting a dependency. e.g., `carts` depends on `carts-db`. |
| `sla` | object | — | SLA thresholds for this service. `errorRateThreshold: 0.05` (5% error rate = SLA breach). Used by certifier to determine if the fault produced a measurable degradation. |

### 5.8 `spec.observability` Block

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `observability.prometheus.serviceMonitor` | bool | — | Default: `true`. If `true`, the app chart must include a ServiceMonitor CRD for Prometheus scraping. |
| `observability.prometheus.alertRules[]` | object[] | ✓ (Official) | Alert rule definitions. See below. |
| `observability.prometheus.alertRules[].name` | string | ✓ | Alert name. Must match exactly the alert name in `ground-truth/ground_truth_v1.yaml`. |
| `observability.prometheus.alertRules[].severity` | string | ✓ | `critical`, `warning`, or `info`. |
| `observability.prometheus.alertRules[].expr` | string | ✓ | PromQL expression. **Must use `{{.AppNamespace}}` template variable** — not a hardcoded namespace. |
| `observability.prometheus.alertRules[].for` | string | — | Default: `"1m"`. Duration before alert fires. |
| `observability.prometheus.alertRules[].annotations` | map | — | Standard Prometheus annotations (`summary`, `description`, `runbook_url`). |

### 5.9 `spec.faultCompatibility[]` Block

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `faultName` | string | ✓ | Must match a fault `name` in `kubernetes.chartserviceversion.yaml`. |
| `compatible` | bool | ✓ | Whether this fault is meaningful for this app. |
| `notes` | string | — | Why this fault is or is not compatible. Shown as tooltip in Chaos Studio fault library. |
| `recommendedTargets` | string[] | — | Which microservice names make the best targets for this fault on this app. Shown as default suggestions in the fault configuration panel. |

### 5.10 `spec.groundTruth` Block

Used by the ACE Certifier to score agent performance. For each fault+target combination, defines what alert the agent should observe and what root cause it should identify.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `groundTruth.version` | string | ✓ | Version of the ground truth schema. Current: `"1"`. |
| `groundTruth.faultAlertMappings[].faultName` | string | ✓ | Fault name. |
| `groundTruth.faultAlertMappings[].targetService` | string | ✓ | Microservice name being faulted. |
| `groundTruth.faultAlertMappings[].expectedAlerts` | string[] | ✓ | Alert names (from `observability.prometheus.alertRules`) that should fire during this fault. |
| `groundTruth.faultAlertMappings[].expectedRootCause` | string | ✓ | Human-readable root cause string. The certifier compares agent-identified root cause against this using semantic similarity (LLM judge). |
| `groundTruth.faultAlertMappings[].expectedRemediation` | string | — | Expected remediation action. Used for `remediation_correctness` scoring. |
| `groundTruth.faultAlertMappings[].maxDetectionTimeSecs` | int | — | SLA: agent should detect the fault within this many seconds. Used for `time_to_detect` scoring. |
| `groundTruth.faultAlertMappings[].maxMitigationTimeSecs` | int | — | SLA: agent should mitigate within this many seconds. Used for `time_to_mitigate` scoring. |

### 5.11 `spec.rbac` Block

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `rbac.chaosRunnerPermissions[]` | RBAC rule objects | ✓ | K8s RBAC rules that the `argo-chaos` ServiceAccount needs in the app's namespace to execute faults. The ACE Helm chart generates a Role+RoleBinding from this spec at install time. |

### 5.12 `spec.inputs[]` Block

Configurable parameters surfaced in the Chaos Studio "Install App" node configuration panel.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `key` | string | ✓ | Unique identifier for this input. Used as the query key in form state. |
| `displayName` | string | ✓ | Label shown in the Chaos Studio form. |
| `description` | string | — | Inline help text beneath the field. |
| `type` | enum | ✓ | `string`, `integer`, `boolean`, `enum`. No `secret` type for apps (app configs are not sensitive). |
| `required` | bool | — | Default: `false`. If `true`, the experiment cannot be saved without this value. |
| `default` | string | — | Default value shown pre-filled in the form. |
| `helmPath` | string | ✓ | The Helm `--set` path this input maps to. e.g., `global.replicaScale`. The install-app step uses this to pass the value. |
| `values` | string[] | ✓ (enum) | List of valid values for enum type. |
| `min` | int | — | Minimum value (integer type only). |
| `max` | int | — | Maximum value (integer type only). |
| `unit` | string | — | Unit label shown next to the input (e.g., `"replicas"`, `"seconds"`). |
| `advanced` | bool | — | Default: `false`. If `true`, the input is hidden behind an "Advanced" toggle in Chaos Studio. Prevents overwhelming first-time users. |

---

## 6. User Journey A — Pick From Catalog

This is the primary path. The user already has an agent and wants to find a suitable environment to test it against.

### 6.1 Entry Point

The user opens Chaos Studio and clicks **"New Experiment"**. The first screen is the Catalog Browser — not a blank canvas.

### 6.2 Catalog Browser Screen

```
┌─────────────────────────────────────────────────────────────────────────┐
│  New Experiment — Choose an Application Environment                     │
├───────────────────────────────────┬─────────────────────────────────────┤
│  [🔍 Search...]                   │  Filter by Domain:                  │
│                                   │  [All] [Cloud Native] [Telecom]     │
│  Official                         │  [Health IT] [ITOps] [FinOps]       │
│  ┌─────────────────────────────┐  │                                     │
│  │ 🛍 Sock Shop          v1.0  │  │  Filter by Agent Domain:            │
│  │ Cloud Native                │  │  [Cloud Native] [Telecom]           │
│  │ 13 microservices · 5 faults │  │  [Health IT] [FinOps] [ITOps]       │
│  │ [Select]                    │  │                                     │
│  └─────────────────────────────┘  │                                     │
│  ┌─────────────────────────────┐  │                                     │
│  │ 📊 OTel Demo          v1.0  │  │                                     │
│  │ Cloud Native                │  │                                     │
│  │ 20+ microservices · 6 faults│  │                                     │
│  │ [Select]                    │  │                                     │
│  └─────────────────────────────┘  │                                     │
│                                   │                                     │
│  Community                        │                                     │
│  ┌─────────────────────────────┐  │                                     │
│  │ 📡 5G Core Sim  (community) │  │                                     │
│  │ Telecom                     │  │                                     │
│  │ 8 microservices · 3 faults  │  │                                     │
│  │ [Select]                    │  │                                     │
│  └─────────────────────────────┘  │                                     │
│                                   │                                     │
│  [+ Don't see your domain? Contribute an app]                           │
└─────────────────────────────────────────────────────────────────────────┘
```

Clicking a card opens the App Detail panel (right side):

```
┌──────────────────────────────────────────────────────────────┐
│  Sock Shop  v1.0  ·  Official  ·  Cloud Native               │
│                                                              │
│  A cloud-native microservices e-commerce demo. 13 services   │
│  covering the full request path from frontend to database.   │
│                                                              │
│  ✅ Suitable for agents that observe Kubernetes pod health   │
│  ✅ Suitable for agents with Prometheus query capability     │
│  ❌ Not suitable for service mesh scenarios (no Istio)       │
│                                                              │
│  Microservices (13):                                         │
│  carts · catalogue · orders · payment · shipping · user      │
│  front-end · queue-master · rabbitmq · session-db            │
│  carts-db · catalogue-db · user-db                          │
│                                                              │
│  Available Faults:                                           │
│  pod-delete · pod-cpu-hog · pod-memory-hog                  │
│  pod-network-loss · k8s-config-mutation                     │
│                                                              │
│  Install time: ~5 min · Namespace: sock-shop                 │
│                                                              │
│  [View Documentation]        [Select This App →]            │
└──────────────────────────────────────────────────────────────┘
```

### 6.3 Configure Install Parameters

After selecting the app, the user sees the install configuration panel:

```
┌──────────────────────────────────────────────────────────────┐
│  Configure: Sock Shop                                        │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Namespace          [sock-shop              ]                │
│  Install Timeout    [30m                    ]                │
│                                                              │
│  ▶ Advanced                                                  │
│    Scale Factor     [1                      ] replicas       │
│    Resource Profile [▼ standard             ]                │
│                     minimal / standard / performance         │
│                                                              │
│  [← Back to Catalog]              [Continue to Agent →]     │
└──────────────────────────────────────────────────────────────┘
```

Only inputs with `advanced: false` appear by default. Advanced inputs are hidden under the `▶ Advanced` toggle.

---

## 7. User Journey B — Contribute a New App

Triggered by the **"Don't see your domain? Contribute an app"** link in the catalog browser.

### 7.1 Decision Gate

Before the wizard starts, a screen explains what contribution means and asks a qualifying question:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Contribute an App to the ACE Catalog                                │
│                                                                      │
│  An ACE catalog app is a realistic, installable environment that     │
│  other community members can use to test and certify their agents.   │
│                                                                      │
│  Contributions become part of the shared catalog after review.       │
│                                                                      │
│  Before you start:                                                   │
│  • Your app should represent a real domain scenario, not a toy       │
│  • It must be installable via Helm or Kubernetes manifests           │
│  • At least one service must be faultable                            │
│                                                                      │
│  How would you like to contribute?                                   │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  🚀 Quick Contribute                                         │    │
│  │  My app already has a public Helm chart.                     │    │
│  │  I'll point ACE to it.                                       │    │
│  │  [Start Quick Contribute]                                    │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  📦 Full Contribute                                          │    │
│  │  I'll provide K8s manifests or a custom Helm chart.          │    │
│  │  [Start Full Contribute]                                     │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  🏢 Private App (Admin only)                                 │    │
│  │  Add to my organization's private catalog without a PR.      │    │
│  │  [Private Add]                                               │    │
│  └──────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

### 7.2 Quick Contribute vs. Full Contribute

**Quick Contribute** (method: `external-helm`):
- User provides a public Helm chart URL, chart name, and pinned version
- ACE resolves the chart metadata, auto-discovers deployments, and pre-fills the spec
- User confirms/adjusts the auto-discovered services
- System generates the `app.yaml` spec and PR template
- The chart itself is NOT copied into the ACE repo — only the reference is

**Full Contribute** (method: `helm` or `manifests`):
- User provides a zip/git URL of their Helm chart or raw K8s manifests
- ACE parses the templates to auto-discover service labels and namespace
- User fills in the full spec through the wizard
- The chart IS included in the ACE repo (`catalog/apps/community/<name>/chart/`)
- Required when the chart is internal, proprietary, or needs ACE-specific modifications

---

## 8. Contribution Wizard — Screen by Screen

### Step 1: Identity

```
┌──────────────────────────────────────────────────────────────┐
│  Step 1 of 6 — App Identity                                  │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  App Name (kebab-case)   *                                   │
│  [telecom-5g-core                                   ]        │
│  ⓘ This becomes the stable ID. Cannot change after          │
│    any experiment references this app.                       │
│                                                              │
│  Display Name            *                                   │
│  [5G Core Network Simulation                        ]        │
│                                                              │
│  Domain                  *                                   │
│  [▼ Telecom                                         ]        │
│                                                              │
│  Short Description       *  (≤120 chars)                     │
│  [Simulates a 5G core network with AMF, SMF, and UPF...]     │
│  42/120                                                      │
│                                                              │
│  Full Description        *                                   │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ Markdown supported...                                │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  Maintainer Name         *   Maintainer Email           *    │
│  [Acme Telecom Team      ]   [ace-contrib@acme.com     ]     │
│                                                              │
│                              [Next: Installation →]          │
└──────────────────────────────────────────────────────────────┘
```

**Validation:**
- `name`: pattern `^[a-z0-9][a-z0-9-]*[a-z0-9]$`, max 63 chars
- `name` uniqueness: checked against live catalog; error if duplicate
- `displayName`: 1–80 chars
- `description.short`: 10–120 chars
- `domain`: must be a valid domain id from `domains.yaml`
- `maintainers[0].email`: valid email format

### Step 2: Installation Method

#### Quick Contribute Path

```
┌──────────────────────────────────────────────────────────────┐
│  Step 2 of 6 — Installation                                  │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Helm Repository URL     *                                   │
│  [https://charts.example.com/telecom               ]         │
│                                                              │
│  Chart Name              *                                   │
│  [5g-core                                          ]         │
│                                                              │
│  Chart Version           *  (pin a specific version)         │
│  [2.1.0                                            ]         │
│  ⚠ Floating versions (latest, *) are not accepted.          │
│                                                              │
│  Default Namespace       *                                   │
│  [5g-core                                          ]         │
│                                                              │
│  Install Timeout                                             │
│  [30m                                              ]         │
│                                                              │
│  [← Back]                [Discover Services →]              │
└──────────────────────────────────────────────────────────────┘
```

When "Discover Services" is clicked:
- System runs `helm show templates <repo>/<chart>@<version>`
- Parses all `kind: Deployment` and `kind: StatefulSet` templates
- Extracts `.metadata.labels` and `.spec.selector.matchLabels` from each
- Presents discovered services on the next screen

#### Full Contribute Path

```
┌──────────────────────────────────────────────────────────────┐
│  Step 2 of 6 — Installation                                  │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  How will your app be installed?                             │
│                                                              │
│  ○ Upload Helm chart (zip)   [Choose File]                   │
│  ○ Git repository URL        [https://github.com/...]        │
│  ○ Upload K8s manifests      [Choose Files]                  │
│                                                              │
│  Default Namespace           *                               │
│  [5g-core                                         ]          │
│                                                              │
│  Install Timeout                                             │
│  [30m                                             ]          │
│                                                              │
│  [← Back]                   [Upload & Discover →]           │
└──────────────────────────────────────────────────────────────┘
```

### Step 3: Service Discovery & Fault Targeting

This step is the most important — it defines what the chaos engine can target.

```
┌────────────────────────────────────────────────────────────────────┐
│  Step 3 of 6 — Services & Fault Targets                            │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  We discovered 8 services in your chart. Review and confirm        │
│  which ones should be available as fault targets.                  │
│                                                                    │
│  ┌──────────────────┬────────────────────┬───────────┬──────────┐  │
│  │ Service Name     │ K8s Label          │ Kind      │ Include? │  │
│  ├──────────────────┼────────────────────┼───────────┼──────────┤  │
│  │ amf              │ app=amf            │ deployment│ ☑       │  │
│  │ smf              │ app=smf            │ deployment│ ☑       │  │
│  │ upf              │ app=upf            │ deployment│ ☑       │  │
│  │ nrf              │ app=nrf            │ deployment│ ☑       │  │
│  │ ausf             │ app=ausf           │ deployment│ ☑       │  │
│  │ prometheus       │ app=prometheus     │ deployment│ ☐       │  │
│  │ grafana          │ app=grafana        │ deployment│ ☐       │  │
│  │ postgres         │ app=postgres       │ statefulset│ ☑      │  │
│  └──────────────────┴────────────────────┴───────────┴──────────┘  │
│                                                                    │
│  ⓘ Prometheus and Grafana are excluded by default —               │
│    faulting observability tools breaks the experiment.             │
│    You can include them manually if your agent specifically        │
│    handles observability stack recovery.                           │
│                                                                    │
│  [← Back]   [Add Custom Service]   [Next: Health Probe →]         │
└────────────────────────────────────────────────────────────────────┘
```

**Auto-exclusion logic:**
- Services named `prometheus`, `grafana`, `alertmanager`, `loki`, `jaeger`, `tempo` are auto-unchecked with a note
- Services named `*-db`, `*-database`, `*-postgres`, `*-mysql`, `*-mongo` are auto-checked with criticality `high`
- Everything else auto-checked with criticality `medium`

**"Add Custom Service" modal** (for services not in the chart, e.g., an external dependency):
```
Service Name:  [redis-cache     ]
K8s Label:     [app=redis       ]
Kind:          [▼ deployment    ]
Criticality:   [▼ medium        ]
```

### Step 4: Health Probe

```
┌──────────────────────────────────────────────────────────────┐
│  Step 4 of 6 — Health Probe                                  │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ACE will probe this URL after install to confirm the app    │
│  is ready before running any faults.                         │
│                                                              │
│  Health Probe URL        *                                   │
│  [http://amf.{{.AppNamespace}}.svc.cluster.local:80/health]  │
│  ⓘ Use {{.AppNamespace}} instead of the literal namespace.  │
│                                                              │
│  Expected HTTP Status    *                                   │
│  [200                                              ]         │
│                                                              │
│  Initial Delay           [30        ] seconds                │
│  Retry Interval          [10        ] seconds                │
│  Max Retries             [6         ]                        │
│  Total timeout:  30 + (10 × 6) = 90 seconds                 │
│                                                              │
│  [Test this probe against the live cluster]                  │
│  ⓘ Only available if you are connected to a cluster.        │
│                                                              │
│  [← Back]                            [Next: Load Test →]    │
└──────────────────────────────────────────────────────────────┘
```

**"Test this probe" behavior:**
- Sends a GET request from the GraphQL server's service account to the URL
- Replaces `{{.AppNamespace}}` with the app's default namespace
- Shows: `HTTP 200 OK — probe ready ✅` or `Connection refused — check URL ❌`

### Step 5: Load Test

```
┌──────────────────────────────────────────────────────────────┐
│  Step 5 of 6 — Load Test                                     │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  For meaningful chaos results, traffic must be flowing       │
│  during fault injection.                                     │
│                                                              │
│  ○ My app has a built-in traffic generator                   │
│    (OTel Demo, apps with otelgen, Fortio)                    │
│                                                              │
│  ○ Use ACE's standard load generator                         │
│    Image: litmuschaos/litmus-app-deployer:latest             │
│    Args:  [-namespace=loadtest -app=loadtest]                │
│    (customizable)                                            │
│                                                              │
│  ○ I'll provide a custom K8s Job for load generation         │
│    [Paste Job YAML...]                                       │
│                                                              │
│  ○ Skip load test (not recommended)                          │
│    ⚠ Without traffic, most faults produce no observable     │
│      signal. Certifier scoring will be lower quality.       │
│                                                              │
│  [← Back]                            [Next: Review →]       │
└──────────────────────────────────────────────────────────────┘
```

### Step 6: Review & Generate

```
┌────────────────────────────────────────────────────────────────────┐
│  Step 6 of 6 — Review & Generate                                   │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Your app spec summary:                                            │
│                                                                    │
│  Name:         telecom-5g-core                                     │
│  Domain:       Telecom                                             │
│  Tier:         Community (pending review)                          │
│  Services:     6 services for fault targeting                      │
│  Faults:       Compatible with pod-delete, pod-cpu-hog, ...        │
│  Load Test:    Built-in generator                                  │
│                                                                    │
│  ACE will generate these files for you:                            │
│  ✅  catalog/apps/community/telecom-5g-core/app.yaml              │
│  ✅  catalog/apps/community/telecom-5g-core/docs/README.md        │
│  ⬜  catalog/apps/community/telecom-5g-core/ground-truth/         │
│      (optional — add fault→alert ground truth for certifier)      │
│                                                                    │
│  [Preview app.yaml]                                                │
│                                                                    │
│  What happens next:                                                │
│  1. Download the generated files                                   │
│  2. Open a PR to the ACE monorepo                                  │
│  3. CI runs schema validation + helm lint                          │
│  4. Community review (typically 2–3 business days)                │
│  5. Merge → app live in catalog                                    │
│                                                                    │
│  [← Back]   [Download Files]   [Open PR on GitHub (if connected)] │
└────────────────────────────────────────────────────────────────────┘
```

---

## 9. App Install Mechanics

### 9.1 What `install-app` Does

The `install-app` binary is an Argo Workflow step container. It receives arguments and executes Helm operations against the cluster.

```
install-app \
  --folder=<installFolder>        # required: chart path
  --namespace=<namespace>         # required: target namespace
  --create-namespace              # always passed
  --timeout=<timeout>             # from app spec
  --wait                          # always passed (if spec.install.wait = true)
  [--set=<key>=<value> ...]       # from user's input[] overrides
  [--registry=<registry>]         # if project has custom image registry
```

### 9.2 Step-by-Step Install Sequence

```
1. Create namespace (kubectl create ns <namespace> --dry-run=client -o yaml | kubectl apply -f -)
   └─ Idempotent: uses dry-run apply, not create

2. Apply RBAC (from spec.rbac.chaosRunnerPermissions)
   └─ Generates Role + RoleBinding for argo-chaos SA in the app namespace

3. Helm install
   └─ helm install <name> ./chart \
        --namespace <namespace> \
        --timeout <timeout> \
        --wait \
        [--set ...user inputs]

4. Apply additionalManifests (if any)
   └─ kubectl apply -f <file> -n <namespace>

5. Health probe loop
   └─ Wait initialDelaySeconds
   └─ Loop up to failureThreshold times:
        GET healthProbe.url → check status == expectedStatus
        If match: exit 0 (install step complete)
        If not: sleep periodSeconds, retry
   └─ If all retries exhausted: exit 1 (install step fails, workflow fails)

6. Annotate namespace with ACE metadata
   kubectl annotate ns <namespace> \
     ace.io/app=<appName> \
     ace.io/app-version=<version> \
     ace.io/workflow-uid=<uid>
   └─ Used by cleanup step to find and remove the correct namespace
```

### 9.3 Install Failure Handling

If `helm install` fails (timeout, pod crash loop, resource limit):

1. `install-app` exits with non-zero code
2. Argo marks the step as Failed
3. Argo's `onExit` handler fires (regardless of failure):
   - `uninstall-app` step runs: `helm uninstall <name> -n <namespace>`
   - Namespace is deleted: `kubectl delete ns <namespace>`
4. Workflow is marked as Failed
5. Error message surfaced in Chaos Studio with the `helm install` stderr output

---

## 10. Fresh Install Guarantee

Every experiment run installs the app from scratch and uninstalls it at the end. This is not optional — it is the architectural guarantee that makes ACE certification meaningful.

**Why this matters:**
- Agent A's failed remediation in run #1 does not affect Agent B's score in run #2
- Accumulated state (partial writes, leaked connections, misconfigured resources) does not carry over
- The fault injection scenario is always identical regardless of how many times it has been run

**How it is enforced:**

1. `install-app` does NOT check if the app is already running — it always runs `helm install`
2. If a namespace already exists from a prior run (e.g., workflow was killed mid-run), the cleanup step detects it via the `ace.io/workflow-uid` annotation and deletes it before installing
3. The `uninstall-app` step is in the Argo `onExit` handler — it runs even if the workflow fails or is cancelled
4. The namespace name is deterministic per app (e.g., `sock-shop`) in Iter 1. In Iter 2, it becomes `exp-<runID>-sock-shop` for parallel run isolation

**Stale namespace detection:**

```bash
# At install time, check for leftover namespace from a previous run
EXISTING_UID=$(kubectl get ns <namespace> \
  -o jsonpath='{.metadata.annotations.ace\.io/workflow-uid}' 2>/dev/null || echo "")

if [ -n "$EXISTING_UID" ] && [ "$EXISTING_UID" != "{{workflow.uid}}" ]; then
  echo "Stale namespace from workflow $EXISTING_UID — cleaning up..."
  helm uninstall <app> -n <namespace> --ignore-not-found
  kubectl delete ns <namespace>
fi
```

---

## 11. Microservice Fault Targeting

### 11.1 Label Requirements

Every microservice in `spec.microservices[]` must have a `k8s.label` that:
- Selects exactly **one** Deployment or StatefulSet (not multiple)
- Is a valid Kubernetes label selector format: `key=value`
- Is stable across pod restarts — pod labels are inherited from the pod template spec

**Correct:** `name=carts` — selects the Deployment with `metadata.labels.name=carts`  
**Wrong:** `pod-template-hash=abc123` — pod-specific, changes on rollout  
**Wrong:** `app.kubernetes.io/instance=release-name` — selects all pods in the release  

### 11.2 What Happens at Fault Step Generation

When a user picks "Pod Delete → carts", the hydration pipeline:

1. Looks up `app.microservices[name=carts].k8s.label` → `"name=carts"`
2. Looks up `app.microservices[name=carts].k8s.kind` → `"deployment"`
3. Looks up `app.microservices[name=carts].k8s.namespace` → `"{{.AppNamespace}}"` (resolves to `sock-shop`)
4. Generates ChaosEngine with:
   ```yaml
   appinfo:
     appns: "sock-shop"
     applabel: "name=carts"
     appkind: "deployment"
   ```

If `k8s.label` is misconfigured (matches 0 pods), the ChaosEngine runs but reports `Fail` — the `litmus-checker` step surfaces this as an error in Chaos Studio.

### 11.3 Dependency Graph Display

If `dependsOn` is populated, Chaos Studio shows a dependency warning:

> "⚠ You are targeting `carts`. This service depends on `carts-db`. If `carts-db` is also faulted in this experiment, the `carts` fault results may be confounded."

---

## 12. Observability Requirements

### 12.1 Alert Rules

Alert rules in `spec.observability.prometheus.alertRules[]` are rendered into a PrometheusRule CRD and applied in the app's namespace at install time. The `expr` field uses `{{.AppNamespace}}` which is substituted at install time.

**Minimum required alerts (Official tier):**
- One `critical` alert that fires when the app is degraded (e.g., `HighRequestErrorRate`)
- One alert that fires when pods are not ready (e.g., `KubePodNotReady`)
- One alert that fires when there is no traffic (e.g., `NoRequestsReceived`)

Without these alerts, the certifier cannot measure `time_to_detect` — the most important scoring metric.

### 12.2 ServiceMonitor

If `observability.prometheus.serviceMonitor: true`, the app chart must include a ServiceMonitor CRD in `templates/monitoring/servicemonitor.yaml`. The CI gate verifies this file exists and is valid YAML.

---

## 13. Fault Compatibility Matrix

`spec.faultCompatibility[]` is shown in Chaos Studio as a filter on the fault library. When a user has selected Sock Shop as their app, only faults with `compatible: true` appear in the fault picker.

**Compatibility is determined by the app spec author, not by ACE.** The author should mark a fault as compatible only if:
- The fault produces a measurable degradation signal in this app
- The app has a service that makes a sensible target for the fault
- The certifier can meaningfully score agent response to this fault

Marking all faults as compatible is wrong — it creates noisy, unscoreable experiments. A well-defined compatibility matrix is the difference between a useful community contribution and a placeholder.

---

## 14. RBAC Requirements

The `spec.rbac.chaosRunnerPermissions[]` block defines the K8s RBAC rules needed in the app's namespace for the `argo-chaos` ServiceAccount to execute chaos operations.

`install-app` generates and applies a Role and RoleBinding at install time:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ace-chaos-runner
  namespace: <appNamespace>
rules:
  <spec.rbac.chaosRunnerPermissions>
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ace-chaos-runner-binding
  namespace: <appNamespace>
subjects:
  - kind: ServiceAccount
    name: argo-chaos
    namespace: litmus
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ace-chaos-runner
```

These are created in the app namespace, not `litmus`. They are deleted when the namespace is deleted at experiment end.

**Minimum rules for Litmus-based faults:**
```yaml
- apiGroups: [""]
  resources: [pods, events, pods/exec, pods/log]
  verbs: [get, list, watch, delete, create]
- apiGroups: [apps]
  resources: [deployments, replicasets, statefulsets]
  verbs: [get, list, watch, patch]
- apiGroups: [litmuschaos.io]
  resources: [chaosengines, chaosexperiments, chaosresults]
  verbs: [get, list, create, update, patch, delete, watch]
- apiGroups: ["batch"]
  resources: [jobs]
  verbs: [get, list, create, delete, watch]
```

---

## 15. Image Registry Handling

All container images referenced in the app chart are handled at install time via the `--registry` flag passed to `install-app`.

If the project has a custom registry configured (e.g., `myregistry.io/ace`), `install-app` passes `--set global.imageRegistry=myregistry.io/ace` to Helm. The chart's `values.yaml` must honor `global.imageRegistry` as an image prefix for all images it pulls.

**App chart convention for image registry support:**

```yaml
# values.yaml
global:
  imageRegistry: ""   # empty = use default (docker.io, etc.)

carts:
  image:
    registry: "{{ .Values.global.imageRegistry }}"
    repository: weaveworksdemos/carts
    tag: "0.4.8"
```

If `global.imageRegistry` is empty, images are pulled from their default registries. If set, all images are pulled from the custom registry with the original `org/image:tag` appended.

---

## 16. Configurable Install Parameters

These appear in the Chaos Studio "Install App" configuration form. They translate directly to Helm `--set` args.

### Standard Parameters (every app)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `namespace` | from spec | Override install namespace |
| `installTimeout` | from spec | Override install timeout |

### App-Specific Parameters

Defined in `spec.inputs[]`. Examples:

```yaml
inputs:
  - key: replicaScale
    displayName: Scale Factor
    description: "Multiply all service replicas by this factor. 1 = default. 2 = HA testing."
    type: integer
    required: false
    default: "1"
    min: 1
    max: 5
    helmPath: "global.replicaScale"
    advanced: false

  - key: resourceProfile
    displayName: Resource Profile
    type: enum
    values: [minimal, standard, performance]
    default: standard
    description: "'minimal' for resource-constrained dev clusters, 'performance' for load testing"
    helmPath: "global.resourceProfile"
    advanced: false

  - key: enableTracing
    displayName: Enable Distributed Tracing
    type: boolean
    default: "true"
    helmPath: "global.tracingEnabled"
    advanced: true     # hidden behind Advanced toggle
```

---

## 17. GraphQL API

### 17.1 Queries

```graphql
# List all available apps in the catalog
# Returns both official and community tier apps
query ListApplications($projectID: ID!) {
  listApplications(projectID: $projectID): [ApplicationSpec!]!
}

# Get full detail for a single app
query GetApplication($projectID: ID!, $appName: String!) {
  getApplication(projectID: $projectID, appName: $appName): ApplicationSpec
}
```

### 17.2 Type Definitions

```graphql
type ApplicationSpec {
  name:              String!
  displayName:       String!
  version:           String!
  tier:              String!     # "official" | "community"
  domain:            String!
  capabilityDomains: [String!]!  # e.g. ["cloud-native", "common"] — drives agent capabilities filter
  tags:              [String!]!
  description:       AppDescription!
  install:           InstallSpec!
  healthProbe:       HealthProbeSpec!
  loadTest:          LoadTestSpec!
  microservices:     [MicroserviceSpec!]!
  faultCompatibility:[FaultCompatibilityEntry!]!
  inputs:            [AppInput!]!
  schemaVersion:     String!
}

type AppDescription {
  short:             String!
  long:              String!
  suitableFor:       [String!]!
  notSuitableFor:    [String!]!
}

type InstallSpec {
  method:            String!      # "helm" | "external-helm" | "manifests"
  folder:            String
  chartRef:          ChartRef
  namespace:         NamespaceSpec!
  timeout:           String!
  wait:              Boolean!
}

type ChartRef {
  repo:     String!
  chart:    String!
  version:  String!
}

type NamespaceSpec {
  default:       String!
  configurable:  Boolean!
}

type HealthProbeSpec {
  urlTemplate:          String!
  expectedStatus:       String!
  initialDelaySeconds:  Int!
  periodSeconds:        Int!
  failureThreshold:     Int!
}

type LoadTestSpec {
  enabled: Boolean!
  method:  String
  image:   String
  args:    [String!]
}

type MicroserviceSpec {
  name:          String!
  displayName:   String!
  description:   String
  k8sLabel:      String!
  k8sKind:       String!
  k8sNamespace:  String!
  criticality:   String!
  relevantFaults:[String!]!
  dependsOn:     [String!]!
}

type FaultCompatibilityEntry {
  faultName:          String!
  compatible:         Boolean!
  notes:              String
  recommendedTargets: [String!]!
}

type AppInput {
  key:         String!
  displayName: String!
  description: String
  type:        String!
  required:    Boolean!
  default:     String
  helmPath:    String!
  values:      [String!]
  min:         Int
  max:         Int
  unit:        String
  advanced:    Boolean!
}
```

### 17.3 Resolver Implementation Notes

- `listApplications`: reads all `app.yaml` files from `catalog/apps/**/*.yaml`, parses, and returns sorted (Official first, then Community; alphabetical within each tier)
- Results are cached in-memory; cache is invalidated on SIGHUP or on deploy (process restart)
- `projectID` is passed for authorization context but the catalog is global — all projects see the same catalog
- If `app.yaml` fails schema validation, it is logged as an error and excluded from results (does not crash the server)

---

## 18. K8s Resources Created Per Run

For a single experiment run against Sock Shop:

| Resource | Namespace | Created by | Deleted by |
|----------|-----------|-----------|-----------|
| Namespace `sock-shop` | cluster | `install-app` | `uninstall-app` onExit |
| Helm release `sock-shop` | `sock-shop` | `install-app` | `uninstall-app` onExit |
| Role `ace-chaos-runner` | `sock-shop` | `install-app` | namespace deletion |
| RoleBinding `ace-chaos-runner-binding` | `sock-shop` | `install-app` | namespace deletion |
| PrometheusRule `sock-shop-alerts` | `sock-shop` | `install-app` | namespace deletion |
| ServiceMonitor `sock-shop` | `sock-shop` | `install-app` | namespace deletion |
| Namespace `loadtest` | cluster | `load-test-install` | `load-test-delete` |
| ChaosEngine `<name>-<uid8>-chaos` | `litmus` | fault step | `cleanup-chaos-resources` |
| ChaosExperiment CRDs | `litmus` | fault install step | `cleanup-chaos-resources` |

All resources are tagged with `ace.io/workflow-uid=<uid>` for traceability and cleanup.

---

## 19. Error States & Handling

### 19.1 Install Failures

| Error | Cause | Handling |
|-------|-------|---------|
| `helm install` timeout | Pods not reaching Ready within timeout | onExit fires: uninstall + namespace delete. Error shown in Chaos Studio with pod status at time of failure. |
| Health probe timeout | App started but not serving traffic | Same as above. Error message includes last probe response (body truncated to 500 chars). |
| RBAC permission denied | argo-chaos SA missing permissions | install-app exits with error. Message includes the specific RBAC error. User prompted to check `spec.rbac.chaosRunnerPermissions`. |
| Stale namespace conflict | Previous run left namespace | install-app detects via `ace.io/workflow-uid` annotation, auto-cleans, re-installs. A warning is logged but install proceeds. |
| Image pull failure | Wrong registry, missing credentials | helm install times out waiting for pods. Error message includes `kubectl describe pod` output showing `ImagePullBackOff`. |
| Custom registry image missing | Image not mirrored to custom registry | Same as image pull failure. |

### 19.2 Spec Validation Errors

| Error | When caught | Message shown |
|-------|-------------|--------------|
| `k8s.label` selects 0 pods | At fault step runtime | "Fault target `name=carts` matched 0 pods in namespace `sock-shop`. Check the microservice label in the app spec." |
| `healthProbe.url` hardcodes namespace | At catalog CI validation | CI rejects PR: "healthProbe.url must use `{{.AppNamespace}}` template variable, not a hardcoded namespace." |
| `schemaVersion` missing | At catalog load | App excluded from results with log warning: "Skipping `app.yaml`: missing required field `metadata.version`." |
| Duplicate app `name` | At contribution wizard Step 1 | Inline error: "An app with this name already exists in the catalog." |

---

## 20. Catalog Review & Publication Process

### 20.1 Automated CI Checks (gate on all PRs)

1. **Schema validation** — `app.yaml` must pass JSON Schema validation against the AppCatalogEntry schema
2. **Helm lint** — `helm lint catalog/apps/<tier>/<name>/chart/` must exit 0
3. **Unique name** — `metadata.name` must not conflict with any existing catalog entry
4. **Template variables** — `healthProbe.url` and all alert rule `expr` fields must use `{{.AppNamespace}}`, not a hardcoded namespace string
5. **Version pin** (external-helm only) — `chartRef.version` must be a valid SemVer, no `latest` or `*`
6. **Maintainer field** — at least one maintainer with valid email
7. **Domain validity** — `metadata.domain` must exist in `domains.yaml`
8. **Ground truth consistency** (Official only) — alert names in `groundTruth.faultAlertMappings[].expectedAlerts` must exist in `observability.prometheus.alertRules[].name`

### 20.2 Community Tier Review

Human review checklist:
- Does the app represent a real-world domain scenario?
- Is the description accurate and useful?
- Are the microservice labels correct and documented?
- Is there at least one valid fault compatibility entry?
- Does the README explain the app's architecture?

Review target: 2–3 business days.

### 20.3 Official Tier Promotion

Community apps can be promoted to Official tier by the ACE core team after:
- Ground truth is defined for at least 3 fault scenarios
- Load test is verified working
- Alert rules have been tested against actual fault injections
- The chart has been running in the ACE dev cluster for at least one release cycle

---

## 21. Versioning & Compatibility

### 21.1 Experiment Version Locking

When an experiment is saved, the catalog app version is stored in `SavedExperimentMetadata.AppVersion`. At run time, the runner checks:

- If `AppVersion == catalog[appName].version` → run normally
- If `AppVersion < catalog[appName].version` → show warning in Chaos Studio: "This experiment was built with Sock Shop v1.0 but the catalog has v1.1. Re-save to pick up changes."
- The experiment still runs against the version it was saved with (no forced upgrade)

### 21.2 Microservice Name Stability

`microservice.name` is used as a stable key in saved experiment nodes. If a microservice is renamed in a catalog update, saved experiments that reference the old name will fail at hydration time with:

> "Microservice `cart` not found in Sock Shop v1.1. This experiment was built with v1.0. Please re-save."

This is why microservice names must never be changed in a minor version bump — they require a major version bump and a migration note.

---

## 22. Security Considerations

- App catalog entries are read-only at runtime — no user can modify a catalog entry through the API
- All install operations run under the `argo-chaos` ServiceAccount, not a cluster-admin SA
- App namespace RBAC is scoped to the app namespace only — no cluster-level permissions
- `install-app` does not exec into existing pods — only creates new resources
- Helm chart values provided by the user (from `inputs[]`) are sanitized before passing to `helm --set` (no injection via special characters in values)
- Images in official tier apps must be from verified public registries (docker.io, ghcr.io, quay.io). Community apps list their images in README for manual review.

---

## 23. Forward Compatibility

These items are NOT implemented in Iter 1 but the schema is designed to accommodate them:

| Feature | Schema readiness |
|---------|-----------------|
| Dynamic namespace per run (parallel experiments) | `install.namespace.configurable: true` + `{{.AppNamespace}}` template already in healthProbe and alert rules |
| Prerequisites (Istio, OpenCost) | `spec.prerequisites[]` block placeholder — ignored in Iter 1, consumed in Iter 2 for Istio/BookInfo |
| App versioned experiments (lock to specific catalog version) | `metadata.version` exists; experiment metadata stores `AppVersion` from Iter 1 |
| AI experiment generation | `spec.faultCompatibility[].recommendedTargets` + `microservices[].criticality` are the data the AI engine uses to rank fault suggestions |
| Private catalog for enterprise | `tier: private` value reserved but not implemented; `CatalogService` loading logic is designed to accept additional catalog roots via config |
