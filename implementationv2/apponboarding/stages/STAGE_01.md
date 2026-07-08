# Stage 01: Catalog Directory Skeleton + domains.yaml

**Phase:** 0 — Full Spec Creation  
**Dependencies:** None  
**Risk Level:** Low

---

## Objectives

1. Create the `catalog/` directory tree at monorepo root
2. Write `catalog/domains.yaml` with the full domain taxonomy from the spec
3. Write `catalog/CATALOG.md` as the human-readable index
4. Create stub `catalog/apps/official/` and `catalog/apps/community/` directories

---

## Current State Analysis

### What We Have
- `app-charts/` repo with Helm charts (Sock Shop)
- `app-charts/charts/applications.chartserviceversion.yaml` — existing flat catalog format (read by `apphub` service)
- No `catalog/` directory at monorepo root

### What We Need
- `catalog/` directory matching spec §4.1 structure
- `catalog/domains.yaml` matching spec §4.4 taxonomy
- Placeholder `.gitkeep` files so community/ is tracked by git

---

## Pre-Stage Verification

```bash
# Confirm catalog/ does not exist yet
ls /srv/projects/ace-monorepo/catalog 2>/dev/null && echo "ALREADY EXISTS" || echo "OK - not present"

# Confirm monorepo root location
ls /srv/projects/ace-monorepo
```

---

## Implementation Tasks

### Task 1: Create Directory Structure

**Files to Create:**
```
catalog/
├── CATALOG.md
├── domains.yaml
└── apps/
    ├── official/.gitkeep
    └── community/.gitkeep
```

Run:
```bash
cd /srv/projects/ace-monorepo
mkdir -p catalog/apps/official catalog/apps/community
touch catalog/apps/official/.gitkeep catalog/apps/community/.gitkeep
```

### Task 2: Write `catalog/domains.yaml`

**File:** `catalog/domains.yaml`

```yaml
# ACE Domain Taxonomy
# This file is the authoritative list of domains used in app.yaml metadata.domain fields.
# Every app.yaml must reference a domain.id from this list.
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
    exampleApps: []

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

### Task 3: Write `catalog/CATALOG.md`

**File:** `catalog/CATALOG.md`

```markdown
# ACE Application Catalog

Human-readable index of all apps available for chaos engineering experiments.
The machine-readable source of truth is each app's `app.yaml`.

## Official Apps

| App | Domain | Version | Microservices | Faults |
|-----|--------|---------|---------------|--------|
| [Sock Shop](apps/official/sock-shop/app.yaml) | Cloud Native | 1.0.0 | 13 | 5 |

## Community Apps

_None yet. [Contribute an app →](../spec/app-onboarding.md#7-user-journey-b--contribute-a-new-app)_

---

Last updated by CI. Do not edit manually.
```

---

## Files to Create (Summary)

```
catalog/
├── CATALOG.md              (new)
├── domains.yaml            (new)
└── apps/
    ├── official/
    │   └── .gitkeep        (new)
    └── community/
        └── .gitkeep        (new)
```

---

## Verification Criteria

### Must Pass
- [ ] `catalog/domains.yaml` is valid YAML (`python3 -c "import yaml; yaml.safe_load(open('catalog/domains.yaml'))"`)
- [ ] `catalog/domains.yaml` contains exactly 6 domain entries
- [ ] All domain `id` values are lowercase kebab-case
- [ ] `catalog/apps/official/` and `catalog/apps/community/` directories exist

### Should Pass
- [ ] `catalog/CATALOG.md` renders correctly in a markdown viewer

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo

# Validate YAML syntax
python3 -c "import yaml; d=yaml.safe_load(open('catalog/domains.yaml')); print(f'OK: {len(d[\"domains\"])} domains')"

# Check directory structure
find catalog/ -type f | sort
```

---

## Success Criteria

Stage 01 is complete when:
1. `catalog/domains.yaml` exists and is valid YAML with 6 domain entries
2. `catalog/apps/official/` and `catalog/apps/community/` directories exist
3. `catalog/CATALOG.md` exists with placeholder Official/Community sections
4. All verification criteria pass

## Next Stage

Proceed to **Stage 02: Sock Shop AppCatalogEntry**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
