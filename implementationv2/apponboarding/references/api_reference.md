# API Reference

## GraphQL Queries (New — added in Stage 05)

### listApplications

Returns all applications in the catalog, sorted official-first, then alphabetically.

```graphql
query listApplications($projectID: ID!) {
  listApplications(projectID: $projectID) {
    name
    tier
    domain
    description {
      short
      long
    }
    install {
      method
      chartRef {
        repoURL
        chartName
        chartVersion
      }
    }
    healthProbe {
      url
      intervalSeconds
      timeoutSeconds
      successThreshold
    }
    loadTest {
      tool
      durationSeconds
      targetRPS
    }
    microservices {
      name
      label
      criticality
    }
    suitableFor
    faultCompatibility {
      faultName
      expectation
    }
    inputs {
      name
      description
      type
      defaultValue
      required
    }
  }
}
```

### getApplication

Returns a single application by name.

```graphql
query getApplication($projectID: ID!, $appName: String!) {
  getApplication(projectID: $projectID, appName: $appName) {
    name
    tier
    domain
    description {
      short
      long
    }
    version
    maintainer
    install {
      method
      chartRef {
        repoURL
        chartName
        chartVersion
      }
      namespaceSpec {
        name
        create
        labels
      }
      timeoutSeconds
      additionalManifests
    }
    healthProbe {
      url
      intervalSeconds
      timeoutSeconds
      successThreshold
    }
    loadTest {
      tool
      durationSeconds
      targetRPS
      script
    }
    microservices {
      name
      label
      kind
      port
      criticality
    }
    observability {
      hasPrometheus
      hasGrafana
      hasJaeger
    }
    suitableFor
    faultCompatibility {
      faultName
      expectation
    }
    groundTruth {
      faultName
      expectedDegradation
      recoveryTimeSeconds
    }
    inputs {
      name
      description
      type
      defaultValue
      required
    }
  }
}
```

---

## REST Endpoints (New — added in Stage 11)

### POST /api/catalog/validate-name

Checks if an app name is valid and available in the catalog.

**Request:**
```json
{
  "name": "my-new-app"
}
```

**Response (available):**
```json
{
  "available": true
}
```

**Response (unavailable — already exists):**
```json
{
  "available": false,
  "error": "An app named \"my-new-app\" already exists in the catalog"
}
```

**Response (invalid format):**
```json
{
  "available": false,
  "error": "Name must be kebab-case (a-z, 0-9, hyphens), max 63 chars, no leading/trailing hyphen"
}
```

---

### POST /api/catalog/discover-services

Runs `helm show all` against the specified chart and returns discovered Deployments/StatefulSets.

**Request:**
```json
{
  "repoURL": "https://charts.bitnami.com/bitnami",
  "chartName": "nginx",
  "chartVersion": "18.1.7"
}
```

**Response:**
```json
{
  "services": [
    {
      "name": "nginx",
      "label": "app.kubernetes.io/name=nginx",
      "kind": "deployment",
      "autoExcluded": false,
      "criticality": "medium"
    }
  ]
}
```

**Response (with auto-excluded):**
```json
{
  "services": [
    {
      "name": "front-end",
      "label": "name=front-end",
      "kind": "deployment",
      "autoExcluded": false,
      "criticality": "medium"
    },
    {
      "name": "grafana",
      "label": "app=grafana",
      "kind": "deployment",
      "autoExcluded": true,
      "autoExclusionReason": "observability tool",
      "criticality": "medium"
    }
  ]
}
```

**Error response:**
```json
{
  "services": null,
  "error": "helm show all failed: exit status 1"
}
```

---

## Existing GraphQL Queries (unchanged — do NOT remove)

### listAppHubCategories

```graphql
query listAppHubCategories($projectID: ID!) {
  listAppHubCategories(projectID: $projectID) {
    id
    name
    apps {
      id
      name
      description
      tags
      status {
        isDeployed
        namespace
      }
    }
  }
}
```

### getAppHubStatus

```graphql
query getAppHubStatus($projectID: ID!, $appID: String!) {
  getAppHubStatus(projectID: $projectID, appID: $appID) {
    isDeployed
    namespace
    deployedAt
  }
}
```

---

## Frontend Hooks

### `useListApplications`

```typescript
import { useListApplications } from 'api/core/catalog'

const { data, loading, error } = useListApplications({
  variables: { projectID },
  fetchPolicy: 'cache-and-network',
})
// data.listApplications: ApplicationSpec[]
```

### `useGetApplication`

```typescript
import { useGetApplication } from 'api/core/catalog'

const { data, loading, error } = useGetApplication({
  variables: { projectID, appName: 'sock-shop' },
})
// data.getApplication: ApplicationSpec | null
```
