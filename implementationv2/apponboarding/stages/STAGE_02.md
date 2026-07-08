# Stage 02: Sock Shop AppCatalogEntry (app.yaml + ground truth)

**Phase:** 0 — Full Spec Creation  
**Dependencies:** Stage 01  
**Risk Level:** Low

---

## Objectives

1. Write the complete `catalog/apps/official/sock-shop/app.yaml` as the reference `AppCatalogEntry`
2. Write `catalog/apps/official/sock-shop/ground-truth/ground_truth_v1.yaml`
3. Write `catalog/apps/official/sock-shop/docs/README.md`
4. Symlink (or reference) the existing Helm chart from `app-charts/charts/sock-shop/`

---

## Current State Analysis

### What We Have
- `app-charts/charts/sock-shop/` — full Helm chart with all templates and values
- `app-charts/charts/applications.chartserviceversion.yaml` — lists Sock Shop with 13 microservices
- Existing knowledge of which labels the Sock Shop deployments use (from chart templates)

### What We Need
- Full `AppCatalogEntry` spec conforming to spec §5
- 13 microservices with correct K8s labels (from the actual Helm templates)
- Fault compatibility matrix for 5 faults
- Ground truth mappings for at least 3 fault scenarios (Official tier requirement)
- RBAC rules for `argo-chaos` ServiceAccount
- Sample inputs (replicaScale, resourceProfile)

---

## Pre-Stage Verification

```bash
# Confirm Stage 01 complete
ls /srv/projects/ace-monorepo/catalog/domains.yaml

# Check actual Sock Shop K8s label selectors from the chart
grep -r "applabel\|app:\|name:" /srv/projects/ace-monorepo/app-charts/charts/sock-shop/templates/sock-shop/*-deployment.yaml | head -30
```

---

## Implementation Tasks

### Task 1: Extract Sock Shop Service Labels

Before writing the app.yaml, verify the real label selectors used in the chart templates. The K8s labels must match what the Helm templates actually set.

```bash
# Extract actual deployment labels from Sock Shop chart
grep -A5 "selector:" /srv/projects/ace-monorepo/app-charts/charts/sock-shop/templates/sock-shop/*-deployment.yaml
```

Expected labels (based on Weaveworks Sock Shop):
- `front-end`: `name=front-end`
- `carts`: `name=carts`
- `carts-db`: `name=carts-db`
- `catalogue`: `name=catalogue`
- `catalogue-db`: `name=catalogue-db`
- `orders`: `name=orders`
- `orders-db`: `name=orders-db`
- `payment`: `name=payment`
- `queue-master`: `name=queue-master`
- `rabbitmq`: `name=rabbitmq`
- `shipping`: `name=shipping`
- `user`: `name=user`
- `user-db`: `name=user-db`

### Task 2: Write catalog/apps/official/sock-shop/app.yaml

**File:** `catalog/apps/official/sock-shop/app.yaml`

```yaml
apiVersion: ace.io/v1
kind: AppCatalogEntry
metadata:
  name: sock-shop
  displayName: Sock Shop
  version: "1.0.0"
  tier: official
  domain: cloud-native
  capabilityDomains:
    - cloud-native
    - common
  tags:
    - microservices
    - mongodb
    - rabbitmq
    - e-commerce
    - weaveworks
  maintainers:
    - name: ACE Core Team
      email: ace@infosys.com
  license: Apache-2.0
  repository: https://github.com/microservices-demo/microservices-demo
  createdAt: "2026-07-07"
  updatedAt: "2026-07-07"

spec:
  description:
    short: >-
      A cloud-native microservices e-commerce demo with 13 services
      covering the full request path from frontend to database.
    long: |
      Sock Shop is a canonical cloud-native microservices demo originally
      created by Weaveworks. It implements an e-commerce site with 13
      independent services: a React frontend, six domain services
      (carts, catalogue, orders, payment, shipping, user), three databases
      (MongoDB, MySQL), a message queue (RabbitMQ), and a queue consumer.

      The services communicate over HTTP and are independently deployable.
      All services emit Prometheus metrics. The frontend is externally
      reachable on port 80 and serves as the health probe endpoint.

      Sock Shop is the reference application for ACE cloud-native experiments.
      It is well-understood, has a complete fault compatibility matrix, and
      has verified ground truth for all five supported faults.
    suitableFor:
      - "Agents that observe Kubernetes pod health and restart behavior"
      - "Agents with Prometheus query capability (PromQL)"
      - "Agents that detect service degradation via HTTP error rates"
      - "Agents that investigate database connectivity failures"
      - "Agents that handle network partition scenarios"
    notSuitableFor:
      - "Agents requiring service mesh instrumentation (Istio not installed)"
      - "Agents that test gRPC-native services"
      - "Agents designed for stateful workloads with persistent storage"

  install:
    method: helm
    folder: sock-shop
    namespace:
      default: sock-shop
      configurable: false
    timeout: 30m
    wait: true
    additionalManifests: []

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
    args:
      - "-namespace=loadtest"
      - "-app=loadtest"
    installNamespace: loadtest

  microservices:
    - name: front-end
      displayName: Front End
      description: "React-based web frontend. External entry point for all user traffic."
      k8s:
        label: "name=front-end"
        kind: deployment
        namespace: "{{.AppNamespace}}"
      criticality: high
      relevantFaults: [pod-delete, pod-cpu-hog, pod-memory-hog, pod-network-loss]
      dependsOn: [carts, catalogue, orders, user, payment, shipping]
      sla:
        errorRateThreshold: 0.05

    - name: carts
      displayName: Carts
      description: "Shopping cart service. Stores cart items in carts-db."
      k8s:
        label: "name=carts"
        kind: deployment
        namespace: "{{.AppNamespace}}"
      criticality: high
      relevantFaults: [pod-delete, pod-cpu-hog, pod-memory-hog, pod-network-loss]
      dependsOn: [carts-db]
      sla:
        errorRateThreshold: 0.05

    - name: carts-db
      displayName: Carts DB
      description: "MongoDB database for the carts service."
      k8s:
        label: "name=carts-db"
        kind: deployment
        namespace: "{{.AppNamespace}}"
      criticality: high
      relevantFaults: [pod-delete, pod-cpu-hog]
      dependsOn: []
      sla:
        errorRateThreshold: 0.01

    - name: catalogue
      displayName: Catalogue
      description: "Product catalogue service. Queries catalogue-db."
      k8s:
        label: "name=catalogue"
        kind: deployment
        namespace: "{{.AppNamespace}}"
      criticality: high
      relevantFaults: [pod-delete, pod-cpu-hog, pod-memory-hog, pod-network-loss]
      dependsOn: [catalogue-db]
      sla:
        errorRateThreshold: 0.05

    - name: catalogue-db
      displayName: Catalogue DB
      description: "MySQL database for the catalogue service."
      k8s:
        label: "name=catalogue-db"
        kind: deployment
        namespace: "{{.AppNamespace}}"
      criticality: high
      relevantFaults: [pod-delete, pod-cpu-hog]
      dependsOn: []
      sla:
        errorRateThreshold: 0.01

    - name: orders
      displayName: Orders
      description: "Order processing service. Reads carts, writes to orders-db, queues via rabbitmq."
      k8s:
        label: "name=orders"
        kind: deployment
        namespace: "{{.AppNamespace}}"
      criticality: high
      relevantFaults: [pod-delete, pod-cpu-hog, pod-memory-hog, pod-network-loss]
      dependsOn: [orders-db, rabbitmq]
      sla:
        errorRateThreshold: 0.05

    - name: orders-db
      displayName: Orders DB
      description: "MongoDB database for the orders service."
      k8s:
        label: "name=orders-db"
        kind: deployment
        namespace: "{{.AppNamespace}}"
      criticality: high
      relevantFaults: [pod-delete, pod-cpu-hog]
      dependsOn: []
      sla:
        errorRateThreshold: 0.01

    - name: payment
      displayName: Payment
      description: "Payment processing service. No external dependencies."
      k8s:
        label: "name=payment"
        kind: deployment
        namespace: "{{.AppNamespace}}"
      criticality: high
      relevantFaults: [pod-delete, pod-cpu-hog, pod-network-loss]
      dependsOn: []
      sla:
        errorRateThreshold: 0.05

    - name: queue-master
      displayName: Queue Master
      description: "RabbitMQ consumer that processes order fulfillment events."
      k8s:
        label: "name=queue-master"
        kind: deployment
        namespace: "{{.AppNamespace}}"
      criticality: medium
      relevantFaults: [pod-delete, pod-cpu-hog]
      dependsOn: [rabbitmq, orders-db]
      sla:
        errorRateThreshold: 0.1

    - name: rabbitmq
      displayName: RabbitMQ
      description: "Message broker connecting orders service to queue-master."
      k8s:
        label: "name=rabbitmq"
        kind: deployment
        namespace: "{{.AppNamespace}}"
      criticality: medium
      relevantFaults: [pod-delete, pod-cpu-hog]
      dependsOn: []
      sla:
        errorRateThreshold: 0.1

    - name: shipping
      displayName: Shipping
      description: "Shipping service. Consumes order events from queue."
      k8s:
        label: "name=shipping"
        kind: deployment
        namespace: "{{.AppNamespace}}"
      criticality: medium
      relevantFaults: [pod-delete, pod-cpu-hog]
      dependsOn: [rabbitmq]
      sla:
        errorRateThreshold: 0.1

    - name: user
      displayName: User
      description: "User account and authentication service. Uses user-db."
      k8s:
        label: "name=user"
        kind: deployment
        namespace: "{{.AppNamespace}}"
      criticality: high
      relevantFaults: [pod-delete, pod-cpu-hog, pod-memory-hog, pod-network-loss]
      dependsOn: [user-db]
      sla:
        errorRateThreshold: 0.05

    - name: user-db
      displayName: User DB
      description: "MongoDB database for the user service."
      k8s:
        label: "name=user-db"
        kind: deployment
        namespace: "{{.AppNamespace}}"
      criticality: high
      relevantFaults: [pod-delete, pod-cpu-hog]
      dependsOn: []
      sla:
        errorRateThreshold: 0.01

  observability:
    prometheus:
      serviceMonitor: true
      alertRules:
        - name: HighRequestErrorRate
          severity: critical
          expr: >-
            sum(rate(http_requests_total{namespace="{{.AppNamespace}}",
            status=~"5.."}[2m])) /
            sum(rate(http_requests_total{namespace="{{.AppNamespace}}"}[2m])) > 0.05
          for: "1m"
          annotations:
            summary: "High HTTP error rate in {{ .AppNamespace }}"
            description: "Error rate exceeded 5% for 1 minute"

        - name: KubePodNotReady
          severity: critical
          expr: >-
            kube_pod_status_ready{namespace="{{.AppNamespace}}",
            condition="true"} == 0
          for: "2m"
          annotations:
            summary: "Pod not ready in {{ .AppNamespace }}"
            description: "One or more pods have been not-ready for 2 minutes"

        - name: NoRequestsReceived
          severity: warning
          expr: >-
            sum(rate(http_requests_total{namespace="{{.AppNamespace}}"}[2m])) == 0
          for: "2m"
          annotations:
            summary: "No traffic in {{ .AppNamespace }}"
            description: "No HTTP requests received for 2 minutes — load test may have stopped"

  faultCompatibility:
    - faultName: pod-delete
      compatible: true
      notes: "Most impactful fault for Sock Shop — directly tests service redundancy and restart recovery."
      recommendedTargets: [carts, catalogue, payment, front-end]

    - faultName: pod-cpu-hog
      compatible: true
      notes: "Effective for testing agent response to CPU throttling in any service."
      recommendedTargets: [carts, orders, front-end]

    - faultName: pod-memory-hog
      compatible: true
      notes: "Tests OOM killer behavior. Most impactful on JVM services (carts, orders)."
      recommendedTargets: [carts, orders, user]

    - faultName: pod-network-loss
      compatible: true
      notes: "Tests inter-service communication failure. carts → carts-db dependency makes this observable."
      recommendedTargets: [carts, catalogue, payment]

    - faultName: k8s-config-mutation
      compatible: true
      notes: "Tests agent response to misconfigured resources (e.g., wrong image tag, bad env var)."
      recommendedTargets: [front-end, carts]

  groundTruth:
    version: "1"
    faultAlertMappings:
      - faultName: pod-delete
        targetService: carts
        expectedAlerts: [KubePodNotReady, HighRequestErrorRate]
        expectedRootCause: "carts pod deleted — cart operations failing with connection refused"
        expectedRemediation: "Verify pod restart succeeds; if CrashLoopBackOff, check carts-db connectivity"
        maxDetectionTimeSecs: 120
        maxMitigationTimeSecs: 300

      - faultName: pod-delete
        targetService: payment
        expectedAlerts: [KubePodNotReady, HighRequestErrorRate]
        expectedRootCause: "payment pod deleted — checkout flow returning 500"
        expectedRemediation: "Confirm pod restarted; check order submission error rate returns to baseline"
        maxDetectionTimeSecs: 120
        maxMitigationTimeSecs: 300

      - faultName: pod-network-loss
        targetService: carts
        expectedAlerts: [HighRequestErrorRate]
        expectedRootCause: "network partition between carts and carts-db causing cart read/write failures"
        expectedRemediation: "Identify network policy causing partition; remove or modify policy"
        maxDetectionTimeSecs: 90
        maxMitigationTimeSecs: 240

  rbac:
    chaosRunnerPermissions:
      - apiGroups: [""]
        resources: [pods, events, "pods/exec", "pods/log"]
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

  inputs:
    - key: replicaScale
      displayName: Scale Factor
      description: "Multiply all service replicas by this factor. 1 = default, 2 = HA testing."
      type: integer
      required: false
      default: "1"
      min: 1
      max: 5
      helmPath: "global.replicaScale"
      advanced: false
      unit: replicas

    - key: resourceProfile
      displayName: Resource Profile
      description: "'minimal' for resource-constrained dev clusters, 'performance' for load testing."
      type: enum
      values: [minimal, standard, performance]
      default: standard
      helmPath: "global.resourceProfile"
      advanced: false

    - key: enableTracing
      displayName: Enable Distributed Tracing
      description: "Enables Jaeger-compatible trace headers. Requires a tracing backend."
      type: boolean
      default: "false"
      helmPath: "global.tracingEnabled"
      advanced: true
```

### Task 3: Write ground_truth_v1.yaml

**File:** `catalog/apps/official/sock-shop/ground-truth/ground_truth_v1.yaml`

```yaml
# Ground truth for Sock Shop v1.0.0
# Each entry maps a fault+target combination to expected agent observations.
# The certifier uses this for automated scoring.
version: "1"
app: sock-shop
appVersion: "1.0.0"

# Embedded from spec.groundTruth in app.yaml — kept in sync
faultAlertMappings:
  - faultName: pod-delete
    targetService: carts
    expectedAlerts: [KubePodNotReady, HighRequestErrorRate]
    expectedRootCause: "carts pod deleted — cart operations failing with connection refused"
    expectedRemediation: "Verify pod restart succeeds; if CrashLoopBackOff, check carts-db connectivity"
    maxDetectionTimeSecs: 120
    maxMitigationTimeSecs: 300

  - faultName: pod-delete
    targetService: payment
    expectedAlerts: [KubePodNotReady, HighRequestErrorRate]
    expectedRootCause: "payment pod deleted — checkout flow returning 500"
    expectedRemediation: "Confirm pod restarted; check order submission error rate returns to baseline"
    maxDetectionTimeSecs: 120
    maxMitigationTimeSecs: 300

  - faultName: pod-network-loss
    targetService: carts
    expectedAlerts: [HighRequestErrorRate]
    expectedRootCause: "network partition between carts and carts-db causing cart read/write failures"
    expectedRemediation: "Identify network policy causing partition; remove or modify policy"
    maxDetectionTimeSecs: 90
    maxMitigationTimeSecs: 240
```

### Task 4: Write docs/README.md

**File:** `catalog/apps/official/sock-shop/docs/README.md`

```markdown
# Sock Shop

**Domain:** Cloud Native  
**Version:** 1.0.0  
**Tier:** Official  
**Maintainer:** ACE Core Team

## Overview

Sock Shop is a canonical cloud-native microservices demo originally created by Weaveworks.
It implements an e-commerce application with 13 independent services.

## Architecture

```
browser → front-end (React)
              ├── catalogue → catalogue-db (MySQL)
              ├── carts → carts-db (MongoDB)
              ├── orders → orders-db (MongoDB)
              │               └── rabbitmq → queue-master → shipping
              ├── user → user-db (MongoDB)
              └── payment
```

## Microservices

| Service | K8s Label | Kind | Criticality |
|---------|----------|------|-------------|
| front-end | name=front-end | Deployment | high |
| carts | name=carts | Deployment | high |
| carts-db | name=carts-db | Deployment | high |
| catalogue | name=catalogue | Deployment | high |
| catalogue-db | name=catalogue-db | Deployment | high |
| orders | name=orders | Deployment | high |
| orders-db | name=orders-db | Deployment | high |
| payment | name=payment | Deployment | high |
| queue-master | name=queue-master | Deployment | medium |
| rabbitmq | name=rabbitmq | Deployment | medium |
| shipping | name=shipping | Deployment | medium |
| user | name=user | Deployment | high |
| user-db | name=user-db | Deployment | high |

## Install

```bash
helm install sock-shop app-charts/charts/sock-shop \
  --namespace sock-shop --create-namespace --timeout 30m --wait
```

Health probe: `http://front-end.sock-shop.svc.cluster.local:80` → expects HTTP 200.

## Supported Faults

- `pod-delete` — tests restart recovery
- `pod-cpu-hog` — tests CPU throttling response
- `pod-memory-hog` — tests OOM behavior
- `pod-network-loss` — tests inter-service network partition
- `k8s-config-mutation` — tests misconfiguration detection
```

### Task 5: Create chart/ reference (NOT a symlink — a chart-ref.yaml pointer)

Since `app-charts/charts/sock-shop/` already has the Helm chart, create a reference file rather than duplicating it:

**File:** `catalog/apps/official/sock-shop/chart-ref.yaml`

```yaml
# Points to the Helm chart in app-charts/charts/sock-shop/
# The CatalogService and install-app binary resolve this path relative to monorepo root.
type: local
path: "app-charts/charts/sock-shop"
```

---

## Files to Create (Summary)

```
catalog/apps/official/sock-shop/
├── app.yaml                    (new — full AppCatalogEntry)
├── chart-ref.yaml              (new — pointer to app-charts/charts/sock-shop)
├── ground-truth/
│   └── ground_truth_v1.yaml   (new)
└── docs/
    └── README.md               (new)
```

---

## Verification Criteria

### Must Pass
- [ ] `catalog/apps/official/sock-shop/app.yaml` is valid YAML
- [ ] `app.yaml` contains all 13 microservices from the existing `chartserviceversion.yaml`
- [ ] `app.yaml` `healthProbe.url` uses `{{.AppNamespace}}` (not hardcoded `sock-shop`)
- [ ] `app.yaml` all alert rule `expr` fields use `{{.AppNamespace}}`
- [ ] `app.yaml` has at least 5 `faultCompatibility` entries
- [ ] `ground_truth_v1.yaml` has at least 3 fault mappings
- [ ] `app.yaml` `metadata.tier` is `official`

### Should Pass
- [ ] K8s labels in microservices match actual labels in `app-charts/charts/sock-shop/templates/`
- [ ] `docs/README.md` renders correctly

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo

# Validate YAML
python3 -c "import yaml; d=yaml.safe_load(open('catalog/apps/official/sock-shop/app.yaml')); print(f'OK: {len(d[\"spec\"][\"microservices\"])} microservices')"

# Cross-check: template labels vs app.yaml labels
grep -h "name:" app-charts/charts/sock-shop/templates/sock-shop/*-deployment.yaml | sort -u
grep "label:" catalog/apps/official/sock-shop/app.yaml | sort

# Check namespace template variable used (not hardcoded)
grep -c "sock-shop" catalog/apps/official/sock-shop/app.yaml
grep -c "AppNamespace" catalog/apps/official/sock-shop/app.yaml
```

---

## Success Criteria

Stage 02 is complete when:
1. `catalog/apps/official/sock-shop/app.yaml` exists and validates as correct YAML
2. All 13 microservices listed with verified K8s labels
3. `healthProbe.url` and all alert `expr` use `{{.AppNamespace}}`
4. Ground truth has ≥ 3 fault mappings
5. All verification criteria pass

## Next Stage

Proceed to **Stage 03: App Spec JSON Schema for CI Validation**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
