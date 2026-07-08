# App Onboarding — Technical Architecture

## Executive Summary

The App Onboarding feature adds a structured catalog of installable application environments to ACE. The catalog lives in the monorepo as YAML files, served via a new `CatalogService` in the GraphQL backend, and browsed/contributed via an upgraded frontend. The architecture deliberately reuses every existing pattern: the `apphub` service pattern (catalog as filesystem), the `AgentOnboarding` wizard pattern (multi-step form), and the `AppHubEntry`/`Microservice` GraphQL types (extended, not replaced).

---

## Core Architectural Principles

### 1. Catalog Is Code
The catalog is a directory tree in the monorepo (`catalog/`). There is no database table for catalog entries. The `CatalogService` reads YAML files at startup and on SIGHUP. This mirrors how the existing `apphub` service reads `chartserviceversion.yaml` files cloned from a Git repo — but simpler, because the catalog is already in the repo.

**Why:** Zero ops burden — catalog changes go through PRs, have CI validation, and are version-controlled. The existing CI/CD pipeline already handles monorepo changes.

### 2. Additive GraphQL Schema
The new `listApplications` and `getApplication` queries and the full `ApplicationSpec` type are **added** to the existing `hubs.graphqls` schema. The existing `listAppHubCategories` / `AppHubEntry` / `AppHubCategory` types are not removed or changed — they serve the existing `AppsHub` view during the transition.

**Why:** Non-breaking. The existing frontend still compiles and works while the new catalog browser is built in parallel.

### 3. Wizard Follows AgentOnboarding Pattern
The Contribution Wizard reuses the same Harness UI `MultiStepWizard` / `StepWizard` component pattern used in `AgentOnboarding`. Steps are individual React components, wizard state is a single `ContributionFormData` object passed through context.

**Why:** Consistency with the existing UI codebase. No new patterns to learn.

### 4. Service Discovery is Backend-Initiated
The "Discover Services" step in the wizard sends the chart reference to the backend, which runs `helm show all` and parses the template YAML. The browser never runs helm. This keeps the frontend thin and avoids browser security restrictions on running external tools.

**Why:** Only the GraphQL server pod has `helm` CLI available. Keeps the frontend stateless.

---

## High-Level Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│  Browser (React/TypeScript)                                      │
│                                                                  │
│  ┌─────────────────┐  ┌────────────────────────────────────┐   │
│  │  CatalogBrowser │  │  ContributionWizard                │   │
│  │  (User Journey A)│  │  (User Journey B)                 │   │
│  │  - Domain filter │  │  Step1: Identity                  │   │
│  │  - Tier badges   │  │  Step2: Install method            │   │
│  │  - App cards     │  │  Step3: Service discovery         │   │
│  └────────┬────────┘  │  Step4: Health probe               │   │
│           │           │  Step5: Load test                  │   │
│  ┌────────▼────────┐  │  Step6: Review & Download          │   │
│  │  AppDetailPanel  │  └────────────────┬───────────────┘   │   │
│  │  - suitableFor   │                   │                    │   │
│  │  - faultCompat   │                   │                    │   │
│  │  - inputs form   │                   │                    │   │
│  └─────────────────┘                   │                    │   │
└──────────────────────────┬─────────────┴────────────────────────┘
                           │  Apollo GraphQL + REST
┌──────────────────────────▼─────────────────────────────────────┐
│  GraphQL Server (Go)                                            │
│                                                                  │
│  ┌────────────────────┐   ┌───────────────────────────────────┐ │
│  │  CatalogService    │   │  ContributionHandler (REST)       │ │
│  │  ─────────────     │   │  POST /api/catalog/validate-name  │ │
│  │  listApplications  │   │  POST /api/catalog/discover       │ │
│  │  getApplication    │   │  POST /api/catalog/generate       │ │
│  │  (SIGHUP reload)   │   └───────────────────────────────────┘ │
│  └──────────┬─────────┘                                         │
│             │ reads filesystem                                   │
└─────────────┼───────────────────────────────────────────────────┘
              │
┌─────────────▼───────────────────────────────────────────────────┐
│  Monorepo Filesystem                                             │
│                                                                  │
│  catalog/                                                        │
│  ├── domains.yaml                                                │
│  └── apps/                                                       │
│      ├── official/sock-shop/app.yaml  ←── Stage 02              │
│      └── community/                  ←── contributions go here  │
│                                                                  │
│  app-charts/charts/sock-shop/        ←── existing Helm chart    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Data Flow — User Journey A (Pick From Catalog)

```
User clicks "New Experiment"
  ↓
CatalogBrowser mounts → Apollo: listApplications(projectID)
  ↓
CatalogService.ListApplications() → reads catalog/apps/**/*.yaml
  → parses AppCatalogEntry YAMLs → builds []ApplicationSpec
  → returns sorted: Official first, then Community; alphabetical within tier
  ↓
Browser renders category groups with domain filter sidebar
  ↓
User filters by domain "Cloud Native" → client-side filter on ApplicationSpec.domain
  ↓
User clicks Sock Shop card → Apollo: getApplication(projectID, "sock-shop")
  ↓
AppDetailPanel renders:
  - description.suitableFor / notSuitableFor
  - microservices[] list
  - faultCompatibility[] table
  - inputs[] form (standard + Advanced toggle)
  ↓
User clicks "Select This App →" → experiment creation flow continues
```

---

## Data Flow — User Journey B (Contribute)

```
User clicks "Contribute an App"
  ↓
ContributionWizard mounts with empty ContributionFormData
  ↓
Step 1: Identity → validates name uniqueness
  POST /api/catalog/validate-name { name: "telecom-5g-core" }
  → 200 OK or 409 Conflict
  ↓
Step 2: Installation method selection
  Quick Contribute → external-helm fields
  Full Contribute → file upload or git URL
  ↓
Step 3: Service Discovery → backend discovers services
  Quick: POST /api/catalog/discover { repoURL, chartName, version }
     → server runs: helm show all <repo>/<chart>@<version>
     → parses Deployment/StatefulSet templates → []DiscoveredService
  Full: server parses uploaded templates or clones git URL
  User reviews table: includes/excludes services
  Auto-exclusion: prometheus, grafana → unchecked; *-db → criticality:high
  ↓
Step 4: Health Probe → validates URL contains {{.AppNamespace}}
  "Test Probe" button → POST /api/catalog/test-probe (live cluster only)
  ↓
Step 5: Load Test → select built-in / standard deployer / custom job / skip
  ↓
Step 6: Review & Generate
  Client renders full app.yaml preview
  "Download Files" → generates zip: app.yaml + docs/README.md
  POST /api/catalog/generate → returns generated file content
```

---

## CatalogService — Go Package Structure

```
graphql/server/pkg/catalog/
├── service.go      # Service interface + ListApplications + GetApplication
├── loader.go       # YAML parsing: reads app.yaml → ApplicationSpec
└── model.go        # Go structs matching the app.yaml schema (for YAML parsing)
```

Key design decisions:
- `service.go` builds an in-memory map `map[string]*model.ApplicationSpec` at startup
- Reload is triggered via `os.Signal` SIGHUP listener (same as apphub uses timer-based sync)
- Schema validation errors in individual `app.yaml` files log a warning and skip that entry — no crash
- Sort order: `official` entries before `community`, alphabetical within tier

---

## GraphQL Schema Extension

New types added to `hubs.graphqls` (additive, no removals):

```graphql
# --- New types for spec-compliant catalog ---
type ApplicationSpec { ... }     # full app spec (§17.2)
type AppDescription { ... }
type InstallSpec { ... }
type ChartRef { ... }
type NamespaceSpec { ... }
type HealthProbeSpec { ... }
type LoadTestSpec { ... }
type MicroserviceSpec { ... }    # richer than existing Microservice type
type FaultCompatibilityEntry { ... }
type AppInput { ... }

# --- New queries (additive) ---
extend type Query {
  listApplications(projectID: ID!): [ApplicationSpec!]! @authorized
  getApplication(projectID: ID!, appName: String!): ApplicationSpec @authorized
}
```

The existing `Microservice`, `AppHubEntry`, `AppHubCategory`, `AppHubStatus` types and their queries remain unchanged.

---

## Catalog YAML Format (app.yaml)

```yaml
apiVersion: ace.io/v1
kind: AppCatalogEntry
metadata:
  name: sock-shop          # stable primary key (kebab-case)
  displayName: Sock Shop
  version: "1.0.0"
  tier: official           # official | community
  domain: cloud-native     # from domains.yaml
  capabilityDomains: [cloud-native, common]
  tags: [microservices, mongodb, rabbitmq]
  maintainers:
    - name: ACE Core Team
      email: ace@infosys.com
  license: Apache-2.0
  repository: https://github.com/microservices-demo/microservices-demo
spec:
  description:
    short: "..."
    long: "..."
    suitableFor: [...]
    notSuitableFor: [...]
  install:
    method: helm
    folder: sock-shop
    namespace:
      default: sock-shop
      configurable: false
    timeout: 30m
    wait: true
  healthProbe:
    url: "http://front-end.{{.AppNamespace}}.svc.cluster.local:80"
    expectedStatus: "200"
    initialDelaySeconds: 30
    periodSeconds: 10
    failureThreshold: 6
  loadTest:
    enabled: true
    method: deployer
    image: litmuschaos/litmus-app-deployer:latest
    args: ["-namespace=loadtest", "-app=loadtest"]
  microservices: [...]
  observability: { ... }
  faultCompatibility: [...]
  groundTruth: { ... }
  rbac: { ... }
  inputs: [...]
```

---

## Contribution Wizard State

```typescript
interface ContributionFormData {
  // Step 1
  name: string;
  displayName: string;
  domain: string;
  shortDescription: string;
  longDescription: string;
  maintainerName: string;
  maintainerEmail: string;
  tags: string[];

  // Step 2
  contributeMethod: 'quick' | 'full' | 'private';
  installMethod: 'helm' | 'external-helm' | 'manifests';
  // Quick path
  chartRepoURL?: string;
  chartName?: string;
  chartVersion?: string;
  // Full path
  uploadedChartFile?: File;
  gitURL?: string;
  defaultNamespace: string;
  installTimeout: string;

  // Step 3
  discoveredServices: DiscoveredService[];
  selectedServices: DiscoveredServiceWithConfig[];

  // Step 4
  healthProbeURL: string;
  healthProbeExpectedStatus: string;
  initialDelaySeconds: number;
  periodSeconds: number;
  failureThreshold: number;

  // Step 5
  loadTestMethod: 'built-in' | 'standard' | 'custom-job' | 'skip';
  customJobYAML?: string;

  // Step 6 (generated, not user input)
  generatedAppYAML?: string;
  generatedReadmeMD?: string;
}
```

---

## Security Considerations

- Catalog entries are read-only from the GraphQL API — no write path through GraphQL
- Contribution wizard submits to a REST endpoint that writes to a temporary staging area (never directly to `catalog/`)
- Service discovery runs `helm show all` — no `helm install`, no cluster mutation
- File generation is pure string rendering — no exec, no filesystem writes in the handler
- All contribution REST endpoints require the same JWT auth as GraphQL

---

## Technology Stack

| Component | Technology |
|-----------|-----------|
| Catalog format | YAML (`app.yaml`) with JSON Schema validation |
| Backend catalog reader | Go (`gopkg.in/yaml.v2`, same as `apphub`) |
| GraphQL code gen | `gqlgen` — run `go generate ./...` after schema changes |
| Frontend queries | Apollo Client (same pattern as `listAppHubCategories`) |
| Contribution wizard | Harness UI `MultiStepWizard` (same as `AgentOnboarding`) |
| File download | Browser `Blob` + `URL.createObjectURL` |
| Service discovery | `helm show all` via `os/exec` in the Go handler |

---

**Version:** 1.0  
**Last Updated:** 2026-07-07
