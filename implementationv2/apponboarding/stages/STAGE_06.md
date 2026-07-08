# Stage 06: Frontend API Queries (listApplications / getApplication)

**Phase:** 2 — Frontend Catalog Browser  
**Dependencies:** Stage 05  
**Risk Level:** Low

---

## Objectives

1. Add `listApplications` Apollo query hook in `api/core/catalog/`
2. Add `getApplication` Apollo query hook
3. Add TypeScript entity types for `ApplicationSpec` and its nested types
4. Export from the `api/core` index

---

## Current State Analysis

### What We Have
- `web/src/api/core/apphub/listAppHubCategories.ts` — reference pattern for Apollo query hooks
- `web/src/api/core/apphub/getAppHubStatus.ts` — reference pattern
- `web/src/api/entities/` — shared TypeScript entity types (e.g., `AppHubEntry`, `AppHubCategory`)
- `web/src/api/core/index.ts` — exports all API hooks

### What We Need
- New directory `web/src/api/core/catalog/`
- TypeScript types for `ApplicationSpec` hierarchy (matching the GraphQL schema from Stage 05)
- Apollo query hooks: `listApplications`, `getApplication`
- Entity types exported from `api/entities/`

---

## Pre-Stage Verification

```bash
# Stage 05 complete
grep "ApplicationSpec" /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/graph/model/models_gen.go | head -3

# Reference pattern for Apollo query hooks
cat /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/api/core/apphub/listAppHubCategories.ts
```

---

## Implementation Tasks

### Task 1: Create TypeScript entity types

**File to Create:** `AgentCert/chaoscenter/web/src/api/entities/catalog.ts`

```typescript
// TypeScript types matching the GraphQL ApplicationSpec type hierarchy
// See: graphql/definitions/shared/hubs.graphqls — ApplicationSpec section

export interface CatalogAppDescription {
  short: string;
  long: string;
  suitableFor: string[];
  notSuitableFor: string[];
}

export interface CatalogChartRef {
  repo: string;
  chart: string;
  version: string;
}

export interface CatalogNamespaceSpec {
  default: string;
  configurable: boolean;
}

export interface CatalogInstallSpec {
  method: string;
  folder?: string;
  chartRef?: CatalogChartRef;
  namespace: CatalogNamespaceSpec;
  timeout: string;
  wait: boolean;
}

export interface CatalogHealthProbeSpec {
  urlTemplate: string;
  expectedStatus: string;
  initialDelaySeconds: number;
  periodSeconds: number;
  failureThreshold: number;
}

export interface CatalogLoadTestSpec {
  enabled: boolean;
  method?: string;
  image?: string;
  args?: string[];
}

export interface CatalogMicroserviceSpec {
  name: string;
  displayName: string;
  description?: string;
  k8sLabel: string;
  k8sKind: string;
  k8sNamespace: string;
  criticality: string;
  relevantFaults: string[];
  dependsOn: string[];
}

export interface FaultCompatibilityEntry {
  faultName: string;
  compatible: boolean;
  notes?: string;
  recommendedTargets: string[];
}

export interface CatalogAppInput {
  key: string;
  displayName: string;
  description?: string;
  type: string;
  required: boolean;
  default?: string;
  helmPath: string;
  values?: string[];
  min?: number;
  max?: number;
  unit?: string;
  advanced: boolean;
}

export interface ApplicationSpec {
  name: string;
  displayName: string;
  version: string;
  tier: 'official' | 'community';
  domain: string;
  capabilityDomains: string[];
  tags: string[];
  description: CatalogAppDescription;
  install: CatalogInstallSpec;
  healthProbe: CatalogHealthProbeSpec;
  loadTest: CatalogLoadTestSpec;
  microservices: CatalogMicroserviceSpec[];
  faultCompatibility: FaultCompatibilityEntry[];
  inputs: CatalogAppInput[];
  schemaVersion: string;
}
```

### Task 2: Export from `api/entities/index.ts`

**File to Modify:** `AgentCert/chaoscenter/web/src/api/entities/index.ts`

```typescript
// Add to existing exports:
export * from './catalog';
```

### Task 3: Create `api/core/catalog/listApplications.ts`

Follow the exact pattern from `api/core/apphub/listAppHubCategories.ts`:

**File to Create:** `AgentCert/chaoscenter/web/src/api/core/catalog/listApplications.ts`

```typescript
import { gql, useQuery } from '@apollo/client';
import type { QueryHookOptions } from '@apollo/client';
import type { ApplicationSpec } from '@api/entities';

export const LIST_APPLICATIONS = gql`
  query listApplications($projectID: ID!) {
    listApplications(projectID: $projectID) {
      name
      displayName
      version
      tier
      domain
      capabilityDomains
      tags
      description {
        short
        long
        suitableFor
        notSuitableFor
      }
      install {
        method
        folder
        chartRef {
          repo
          chart
          version
        }
        namespace {
          default
          configurable
        }
        timeout
        wait
      }
      healthProbe {
        urlTemplate
        expectedStatus
        initialDelaySeconds
        periodSeconds
        failureThreshold
      }
      loadTest {
        enabled
        method
        image
        args
      }
      microservices {
        name
        displayName
        description
        k8sLabel
        k8sKind
        k8sNamespace
        criticality
        relevantFaults
        dependsOn
      }
      faultCompatibility {
        faultName
        compatible
        notes
        recommendedTargets
      }
      inputs {
        key
        displayName
        description
        type
        required
        default
        helmPath
        values
        min
        max
        unit
        advanced
      }
      schemaVersion
    }
  }
`;

export interface ListApplicationsRequest {
  projectID: string;
}

export interface ListApplicationsResponse {
  listApplications: ApplicationSpec[];
}

export const listApplications = (
  options?: QueryHookOptions<ListApplicationsResponse, ListApplicationsRequest>
) =>
  useQuery<ListApplicationsResponse, ListApplicationsRequest>(LIST_APPLICATIONS, {
    ...options
  });
```

### Task 4: Create `api/core/catalog/getApplication.ts`

**File to Create:** `AgentCert/chaoscenter/web/src/api/core/catalog/getApplication.ts`

```typescript
import { gql, useQuery } from '@apollo/client';
import type { QueryHookOptions } from '@apollo/client';
import type { ApplicationSpec } from '@api/entities';

export const GET_APPLICATION = gql`
  query getApplication($projectID: ID!, $appName: String!) {
    getApplication(projectID: $projectID, appName: $appName) {
      name
      displayName
      version
      tier
      domain
      capabilityDomains
      tags
      description {
        short
        long
        suitableFor
        notSuitableFor
      }
      install {
        method
        folder
        chartRef { repo chart version }
        namespace { default configurable }
        timeout
        wait
      }
      healthProbe {
        urlTemplate
        expectedStatus
        initialDelaySeconds
        periodSeconds
        failureThreshold
      }
      loadTest { enabled method image args }
      microservices {
        name
        displayName
        description
        k8sLabel
        k8sKind
        k8sNamespace
        criticality
        relevantFaults
        dependsOn
      }
      faultCompatibility { faultName compatible notes recommendedTargets }
      inputs {
        key displayName description type required default
        helmPath values min max unit advanced
      }
      schemaVersion
    }
  }
`;

export interface GetApplicationRequest {
  projectID: string;
  appName: string;
}

export interface GetApplicationResponse {
  getApplication: ApplicationSpec | null;
}

export const getApplication = (
  options?: QueryHookOptions<GetApplicationResponse, GetApplicationRequest>
) =>
  useQuery<GetApplicationResponse, GetApplicationRequest>(GET_APPLICATION, {
    ...options
  });
```

### Task 5: Create `api/core/catalog/index.ts`

**File to Create:** `AgentCert/chaoscenter/web/src/api/core/catalog/index.ts`

```typescript
export * from './listApplications';
export * from './getApplication';
```

### Task 6: Export from `api/core/index.ts`

**File to Modify:** `AgentCert/chaoscenter/web/src/api/core/index.ts`

```typescript
// Add to existing exports:
export * from './catalog';
```

---

## Files to Create (Summary)

```
AgentCert/chaoscenter/web/src/
├── api/entities/
│   └── catalog.ts                     (new)
└── api/core/
    └── catalog/
        ├── index.ts                   (new)
        ├── listApplications.ts        (new)
        └── getApplication.ts          (new)
```

**Files to Modify:**
- `api/entities/index.ts` — add `export * from './catalog'`
- `api/core/index.ts` — add `export * from './catalog'`

---

## Verification Criteria

### Must Pass
- [ ] TypeScript compilation: `yarn tsc --noEmit` passes with no new errors
- [ ] `ApplicationSpec` type is importable: `import { ApplicationSpec } from '@api/entities'` resolves
- [ ] `listApplications` hook is importable: `import { listApplications } from '@api/core'` resolves
- [ ] `getApplication` hook is importable

### Should Pass
- [ ] Running the frontend dev server: the `listApplications` query appears in Apollo DevTools (when connected to the backend)

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/web

# TypeScript type check
yarn tsc --noEmit

# Verify exports resolve
grep -r "from '@api/entities'" src/views/AppsHub/ | head -5
```

---

## Success Criteria

Stage 06 is complete when:
1. `ApplicationSpec` TypeScript type defined and exported
2. `listApplications` and `getApplication` Apollo hooks created
3. TypeScript compilation passes
4. Both hooks exportable from `@api/core`

## Next Stage

Proceed to **Stage 07: Catalog Browser View**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
