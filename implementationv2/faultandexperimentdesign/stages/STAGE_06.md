# Stage 06: App–Fault Compatibility Resolver

**Phase:** 1 — Experiment Definition  
**Status:** Not Started  
**Estimated Effort:** 0.5 day  
**Date Added:** 2026-07-07  
**Depends On:** Stages 03 + 05 (fault catalog service and experiment definition schema both complete)

---

## Objectives

1. Extend `fault_catalog.Service.FaultsForApp()` to look up the app's domain and `capabilityDomains`
   from the `apps_registry` service, rather than accepting domain as a caller parameter.
2. Apply the full three-tier merge: general + domain-matching + app-specific, minus `incompatibleApps`.
3. Wire the extended `FaultsForApp` to the `faultsForApp(appName)` GraphQL resolver so it returns
   the correct filtered set when called from Chaos Studio.
4. Verify with a manual query that selecting Sock Shop returns general + cloud-native + sock-shop
   faults, and does NOT return telecom faults.

---

## Current State Analysis

### What Exists (from Stage 03 stub)
- `FaultsForApp(appName string, appDomain string)` in `pkg/fault_catalog/service.go` — currently
  the caller must pass `appDomain` manually; Stage 03 resolver stub passes an empty string.
- `pkg/apps_registry/` — existing app registry service that can look up an app by name and return
  its `app.yaml` fields including `domain` and `capabilityDomains`.

### What Is Needed
- Update `fault_catalog.Service` interface: `FaultsForApp(ctx, appName)` — no longer requires
  caller to pass domain; the service looks it up internally via `apps_registry`.
- Update the interface, implementation, and the GraphQL resolver accordingly.

---

## Pre-Stage Verification

```bash
# 1. apps_registry service can look up an app by name
grep -n "GetApp\|FindApp\|GetByName" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/apps_registry/*.go

# 2. Stage 03 faultsForApp resolver compiles
go build ./graph/...

# 3. sock-shop app.yaml has a domain field
grep "domain:" /srv/projects/ace-monorepo/catalog/apps/official/sock-shop/app.yaml

# 4. Fault catalog has cloud-native domain faults loaded
curl -s -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ listFaults(scope: DOMAIN, domain: \"cloud-native\") { name } }"}' | jq .
```

---

## Implementation Tasks

### Task 1: Determine `apps_registry` App Lookup Method

Check the actual `apps_registry` service interface:

```bash
cat /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/apps_registry/*.go | \
  grep -A 5 "type.*Service\|type.*Interface\|func.*Get"
```

The service likely has a method like:
```go
GetApp(ctx context.Context, appName string) (*model.App, error)
```
or
```go
FindAppByName(name string) (*AppRegistryEntry, error)
```

Identify the exact method signature and the struct fields that expose `domain` and
`capabilityDomains`.

### Task 2: Update `fault_catalog.Service` Interface and Implementation

Change the interface signature in `pkg/fault_catalog/service.go`:

```go
// Service is the interface for fault catalog queries.
type Service interface {
    ListFaults(scope FaultScope, domain string, targetApp string) []*FaultCatalogEntry
    GetFault(name string) (*FaultCatalogEntry, error)

    // FaultsForApp returns all faults applicable to the given app.
    // It looks up the app's domain from the apps_registry internally.
    // context.Context is needed to call the apps_registry service.
    FaultsForApp(ctx context.Context, appName string) ([]*FaultCatalogEntry, error)
}
```

Update the implementation:

```go
type catalogService struct {
    index        *CatalogIndex
    appsRegistry apps_registry.Service // injected in NewService
}

// NewService returns a new fault catalog Service.
func NewService(appsRegistry apps_registry.Service) Service {
    return &catalogService{
        index:        globalIndex,
        appsRegistry: appsRegistry,
    }
}

// FaultsForApp returns all faults applicable to the given app name.
func (s *catalogService) FaultsForApp(ctx context.Context, appName string) ([]*FaultCatalogEntry, error) {
    // Look up app domain and capabilityDomains from apps_registry
    app, err := s.appsRegistry.GetApp(ctx, appName)
    if err != nil {
        // If app not found, fall back to general + app-specific only
        // (do not fail — the app may not be onboarded yet)
        return s.faultsForAppInternal(appName, "", nil), nil
    }

    domain := app.Domain
    capabilityDomains := app.CapabilityDomains

    return s.faultsForAppInternal(appName, domain, capabilityDomains), nil
}

// faultsForAppInternal does the actual merge and filtering.
func (s *catalogService) faultsForAppInternal(
    appName string,
    primaryDomain string,
    capabilityDomains []string,
) []*FaultCatalogEntry {
    s.index.mu.RLock()
    defer s.index.mu.RUnlock()

    seen := make(map[string]bool)
    var result []*FaultCatalogEntry

    add := func(e *FaultCatalogEntry) {
        if seen[e.Metadata.Name] {
            return
        }
        // Exclude incompatible apps
        for _, incompatible := range e.Spec.Compatibility.IncompatibleApps {
            if incompatible == appName {
                return
            }
        }
        seen[e.Metadata.Name] = true
        result = append(result, e)
    }

    // Step 1: All general faults
    for _, e := range s.index.general {
        add(e)
    }

    // Step 2: Domain faults for primaryDomain
    if primaryDomain != "" {
        for _, e := range s.index.byDomain[primaryDomain] {
            add(e)
        }
    }

    // Step 3: Domain faults for each capabilityDomain (union, no duplicates)
    for _, cd := range capabilityDomains {
        if cd == primaryDomain {
            continue // already added
        }
        for _, e := range s.index.byDomain[cd] {
            add(e)
        }
    }

    // Step 4: App-specific faults for this app
    for _, e := range s.index.byTargetApp[appName] {
        add(e)
    }

    return result
}
```

### Task 3: Update the GraphQL Resolver

In `graph/fault_catalog.resolvers.go`, update the `FaultsForApp` resolver to call the new
context-aware signature:

```go
// FaultsForApp is the resolver for the faultsForApp field.
func (r *queryResolver) FaultsForApp(ctx context.Context, appName string) ([]*model.FaultSpec, error) {
    entries, err := r.FaultCatalogService.FaultsForApp(ctx, appName)
    if err != nil {
        return nil, err
    }
    return faultEntriesToGraphQL(entries), nil
}
```

### Task 4: Update Server Startup Wiring

Where `fault_catalog.NewService()` is called in `server.go`, pass the `apps_registry` service:

```go
// Before:
faultCatalogSvc := fault_catalog.NewService()

// After:
faultCatalogSvc := fault_catalog.NewService(appsRegistrySvc)
```

Ensure `appsRegistrySvc` is already initialized before this line.

---

## Verification Criteria

### Must Pass

1. `go build ./...` succeeds after the interface change.

2. `faultsForApp("sock-shop")` returns general + cloud-native + carts-db-corrupt:
   ```bash
   curl -s -X POST http://localhost:8080/query \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"query": "{ faultsForApp(appName: \"sock-shop\") { name scope domain } }"}' | jq '.data.faultsForApp'
   ```
   Expected:
   - `pod-delete` scope=GENERAL
   - `cpu-hog` scope=GENERAL
   - `pod-oom-kill` scope=DOMAIN domain=cloud-native
   - `carts-db-corrupt` scope=APP_SPECIFIC

3. `faultsForApp("sock-shop")` does NOT return `snmp-trap-flood`:
   ```bash
   curl ... | jq '.data.faultsForApp[].name' | grep snmp-trap-flood
   # Expected: no output
   ```

### Should Pass

4. If `appName` does not exist in the app registry, the query still returns general faults (graceful fallback).

5. An app that declares `capabilityDomains: ["cloud-native", "telecom"]` (hypothetically) would
   receive both cloud-native and telecom domain faults.

6. A fault in `incompatibleApps: ["sock-shop"]` does not appear in `faultsForApp("sock-shop")`.

---

## Testing Commands

```bash
# Manual curl test
export TOKEN=$(curl -s -X POST http://localhost:8080/auth/login \
  -d '{"username":"admin","password":"litmus"}' | jq -r .accessToken)

curl -s -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ faultsForApp(appName: \"sock-shop\") { name scope } }"}' | \
  jq '.data.faultsForApp | group_by(.scope) | map({scope: .[0].scope, count: length})'

# Unit test the faultsForAppInternal function
go test ./pkg/fault_catalog/... -run TestFaultsForApp -v
```

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `apps_registry.GetApp` method not found | Different method name in actual codebase | Grep the actual interface: `grep -n "func.*Get\|func.*Find" pkg/apps_registry/*.go` |
| Import cycle: `fault_catalog` imports `apps_registry` which imports `fault_catalog` | Circular dependency | Introduce an `AppInfo` struct in `fault_catalog` as the minimal interface; have the resolver pass `AppInfo` to `FaultsForApp` instead of having `fault_catalog` directly import `apps_registry` |
| `capabilityDomains` field not in app registry model | Field not yet added during App Onboarding plan | Fall back to using `primaryDomain` only; note this as a dependency on the App Onboarding plan |

---

## Rollback Procedure

The changes in Stage 06 are extensions to existing files, not new files. To roll back:

```bash
git diff AgentCert/chaoscenter/graphql/server/pkg/fault_catalog/service.go
git checkout AgentCert/chaoscenter/graphql/server/pkg/fault_catalog/service.go
git checkout AgentCert/chaoscenter/graphql/server/graph/fault_catalog.resolvers.go
```

---

## Success Criteria

Stage 06 is complete when:
- `faultsForApp("sock-shop")` returns ≥ 4 faults (2 general + 1 domain + 1 app-specific)
- `faultsForApp("sock-shop")` does not return `snmp-trap-flood`
- No import cycles introduced
- Unit test for the merge logic passes

**Next Stage:** Stage 07 — Argo Workflow Hydrator
