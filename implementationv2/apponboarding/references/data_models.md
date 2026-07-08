# Data Models Reference

## AppCatalogEntry (catalog YAML format)

Full schema of `catalog/apps/{official,community}/<name>/app.yaml`.

```yaml
apiVersion: ace.io/v1
kind: AppCatalogEntry

metadata:
  name: string                   # kebab-case, ≤63 chars, unique in catalog
  version: string                # SemVer (^[0-9]+\.[0-9]+\.[0-9]+$)
  tier: official | community
  domain: cloud-native | service-mesh | telecom | health-it | itops | finops
  maintainer: string             # email address
  tags: [string]                 # optional free-form tags

description:
  short: string                  # 10–120 chars, shown in card
  long: string                   # markdown, shown in detail panel

spec:
  install:
    method: external-helm | bundled-helm | cloud-managed
    chartRef:                    # required when method = external-helm
      repoURL: string            # https:// URL
      chartName: string
      chartVersion: string       # pinned version (x.y.z), NOT ranges
    gitRef:                      # required when method = bundled-helm
      url: string
      ref: string                # branch or tag
    namespaceSpec:
      name: string               # usually same as metadata.name
      create: bool               # default true
      labels: {string: string}
    timeoutSeconds: integer      # default 300
    additionalManifests: [string] # paths relative to this app.yaml dir

  healthProbe:
    url: string                  # MUST contain {{.AppNamespace}}
    intervalSeconds: integer     # default 10
    timeoutSeconds: integer      # default 300
    successThreshold: integer    # default 3 consecutive successes

  loadTest:
    tool: k6 | locust | custom-job | skip
    durationSeconds: integer
    targetRPS: integer
    script: string               # inline script for k6/locust
    jobRef:                      # for custom-job
      image: string
      args: [string]

  microservices:
    - name: string               # kebab-case
      label: string              # k8s selector, e.g. "name=carts"
      kind: Deployment | StatefulSet | DaemonSet
      port: integer
      criticality: high | medium | low

  observability:
    prometheus:
      alertRules:
        - alert: string
          expr: string           # MUST contain {{.AppNamespace}}
          for: string            # e.g. "1m"
          labels: {string: string}
          annotations: {string: string}
    grafana:
      enabled: bool
      dashboardURL: string
    jaeger:
      enabled: bool

  suitableFor: [string]          # free-text conditions, shown in detail panel

  faultCompatibility:
    - faultName: string          # maps to Litmus fault name
      expectation: string

  groundTruth:
    - faultName: string
      expectedDegradation: string
      recoveryTimeSeconds: integer

  rbac:
    chaosRunnerPermissions:
      - apiGroups: [string]
        resources: [string]
        verbs: [string]

  inputs:
    - name: string               # camelCase
      description: string
      type: string | integer | boolean
      defaultValue: string
      required: bool
```

---

## Internal Go Model (pkg/catalog/model.go)

```go
type AppCatalogEntry struct {
    APIVersion string      `yaml:"apiVersion"`
    Kind       string      `yaml:"kind"`
    Metadata   AppMetadata `yaml:"metadata"`
    Description struct {
        Short string `yaml:"short"`
        Long  string `yaml:"long"`
    } `yaml:"description"`
    Spec AppSpec `yaml:"spec"`
}

type AppMetadata struct {
    Name       string            `yaml:"name"`
    Version    string            `yaml:"version"`
    Tier       string            `yaml:"tier"`      // "official" | "community"
    Domain     string            `yaml:"domain"`
    Maintainer string            `yaml:"maintainer"`
    Tags       []string          `yaml:"tags"`
}

type AppSpec struct {
    Install           InstallSpec         `yaml:"install"`
    HealthProbe       HealthProbeSpec     `yaml:"healthProbe"`
    LoadTest          LoadTestSpec        `yaml:"loadTest"`
    Microservices     []MicroserviceSpec  `yaml:"microservices"`
    Observability     ObservabilitySpec   `yaml:"observability"`
    SuitableFor       []string            `yaml:"suitableFor"`
    FaultCompatibility []FaultCompatEntry `yaml:"faultCompatibility"`
    GroundTruth       []GroundTruthSpec   `yaml:"groundTruth"`
    RBAC              RBACSpec            `yaml:"rbac"`
    Inputs            []AppInput          `yaml:"inputs"`
}
```

---

## GraphQL Types (added in Stage 05)

```graphql
type ApplicationSpec {
  name: String!
  tier: String!
  domain: String!
  version: String!
  maintainer: String!
  tags: [String!]!
  description: CatalogAppDescription!
  install: CatalogInstallSpec!
  healthProbe: CatalogHealthProbeSpec!
  loadTest: CatalogLoadTestSpec!
  microservices: [CatalogMicroserviceSpec!]!
  suitableFor: [String!]!
  faultCompatibility: [FaultCompatibilityEntry!]!
  groundTruth: [CatalogGroundTruth!]!
  inputs: [CatalogAppInput!]!
}

type CatalogAppDescription {
  short: String!
  long: String!
}

type CatalogInstallSpec {
  method: String!
  chartRef: CatalogChartRef
  namespaceSpec: CatalogNamespaceSpec!
  timeoutSeconds: Int!
  additionalManifests: [String!]!
}

type CatalogChartRef {
  repoURL: String!
  chartName: String!
  chartVersion: String!
}

type CatalogNamespaceSpec {
  name: String!
  create: Boolean!
}

type CatalogHealthProbeSpec {
  url: String!
  intervalSeconds: Int!
  timeoutSeconds: Int!
  successThreshold: Int!
}

type CatalogLoadTestSpec {
  tool: String!
  durationSeconds: Int!
  targetRPS: Int!
  script: String
}

type CatalogMicroserviceSpec {
  name: String!
  label: String!
  kind: String!
  port: Int!
  criticality: String!
}

type FaultCompatibilityEntry {
  faultName: String!
  expectation: String!
}

type CatalogAppInput {
  name: String!
  description: String!
  type: String!
  defaultValue: String!
  required: Boolean!
}
```

---

## Frontend TypeScript Types (api/entities/catalog.ts)

```typescript
export interface ApplicationSpec {
  name: string;
  tier: 'official' | 'community';
  domain: string;
  version: string;
  maintainer: string;
  tags: string[];
  description: CatalogAppDescription;
  install: CatalogInstallSpec;
  healthProbe: CatalogHealthProbeSpec;
  loadTest: CatalogLoadTestSpec;
  microservices: CatalogMicroserviceSpec[];
  suitableFor: string[];
  faultCompatibility: FaultCompatibilityEntry[];
  groundTruth: CatalogGroundTruth[];
  inputs: CatalogAppInput[];
}

export interface ContributionFormData {
  name: string;
  domain: string;
  descriptionShort: string;
  descriptionLong: string;
  installMethod: 'external-helm' | 'bundled-helm' | 'cloud-managed';
  chartRepoURL: string;
  chartName: string;
  chartVersion: string;
  gitURL: string;
  gitRef: string;
  namespaceName: string;
  discoveredServices: DiscoveredService[];
  healthProbeURL: string;
  healthProbeIntervalSeconds: number;
  healthProbeTimeoutSeconds: number;
  healthProbeSuccessThreshold: number;
  loadTestMethod: 'built-in' | 'standard' | 'custom-job' | 'skip';
  loadTestDurationSeconds: number;
  loadTestTargetRPS: number;
  customLoadTestYAML: string;
  maintainer: string;
  version: string;
}

export interface DiscoveredService {
  name: string;
  label: string;
  kind: string;
  included: boolean;
  criticality: 'high' | 'medium' | 'low';
  autoExcluded: boolean;
  autoExclusionReason?: string;
}
```

---

## catalog/domains.yaml Format

```yaml
# ace.io/v1 DomainTaxonomy
domains:
  - id: cloud-native
    displayName: "Cloud Native"
    description: "Kubernetes-native applications with microservice architectures"
    examples: ["Sock Shop", "Hipster Shop", "Online Boutique"]
  - id: service-mesh
    displayName: "Service Mesh"
    description: "Applications designed for Istio or Linkerd"
    examples: ["Bookinfo", "httpbin"]
  - id: telecom
    displayName: "Telecom / 5G"
    description: "CNF/VNF workloads and telco-grade applications"
    examples: ["Open5GS", "Free5GC"]
  - id: health-it
    displayName: "Health IT"
    description: "Healthcare information systems (FHIR, HL7)"
    examples: ["OpenMRS", "HAPI FHIR"]
  - id: itops
    displayName: "IT Operations"
    description: "Operations tooling, monitoring stacks, ITSM"
    examples: ["Elastic Stack", "Prometheus Stack"]
  - id: finops
    displayName: "FinOps / Financial"
    description: "Financial services, trading, banking applications"
    examples: ["Open Bank Project"]
```
