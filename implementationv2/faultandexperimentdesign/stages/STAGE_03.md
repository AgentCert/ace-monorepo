# Stage 03: Fault Catalog GraphQL Schema + Resolvers

**Phase:** 0 — Fault Catalog  
**Status:** Not Started  
**Estimated Effort:** 1 day  
**Date Added:** 2026-07-07  
**Depends On:** Stage 02 (fault catalog service must be implemented)

---

## Objectives

1. Create `graphql/definitions/shared/fault_catalog.graphqls` with all enums, types, and queries
   for the fault catalog.
2. Run `gqlgen generate` to produce resolver stubs.
3. Implement the three resolvers: `listFaults`, `getFault`, `faultsForApp` (stub — full filter in Stage 06).
4. Wire the `fault_catalog.Service` into the resolver via the existing resolver dependency pattern.
5. Integration test: live GraphQL query returns correct faults from the catalog.

---

## Current State Analysis

### What Exists
- `graphql/definitions/shared/fault_studio.graphqls` — do NOT touch; different concept.
- `graphql/definitions/shared/agent_registry.graphqls` — pattern to follow for new query additions.
- gqlgen is already configured at `AgentCert/chaoscenter/graphql/server/graph/` with
  `gqlgen.yml` controlling code generation.
- The resolver file pattern uses one `.resolvers.go` file per schema domain (e.g.,
  `chaos_experiment.resolvers.go`).

### What Is Needed
- `graphql/definitions/shared/fault_catalog.graphqls` — new schema file
- `graph/fault_catalog.resolvers.go` — new resolver file (generated skeleton + manual implementation)
- Update `graph/resolver.go` to add `FaultCatalogService fault_catalog.Service`

---

## Pre-Stage Verification

```bash
# 1. Stage 02 complete — fault catalog service builds
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server
go build ./pkg/fault_catalog/...

# 2. gqlgen version and config
cat gqlgen.yml | head -30

# 3. Confirm schema directory
ls graphql/definitions/shared/*.graphqls

# 4. Confirm resolver pattern
head -30 graph/agent_registry.resolvers.go 2>/dev/null || \
  head -30 graph/chaos_experiment.resolvers.go
```

---

## Implementation Tasks

### Task 1: Create `graphql/definitions/shared/fault_catalog.graphqls`

File path: `AgentCert/chaoscenter/graphql/definitions/shared/fault_catalog.graphqls`

```graphql
"""
Scope of a fault in the three-tier ACE taxonomy.
"""
enum FaultScope {
  GENERAL
  DOMAIN
  APP_SPECIFIC
}

"""
How a fault is implemented and executed at workflow runtime.
"""
enum FaultImplementationType {
  LITMUS
  HTTP_FAULT
  SCRIPT
  EXTERNAL
}

"""
Category of the ground truth impact — drives certifier scoring dimensions.
"""
enum GroundTruthCategory {
  AVAILABILITY
  PERFORMANCE
  SECURITY
  DATA_INTEGRITY
  CONFIGURATION
}

"""
Whether a fault entry is official (maintained by ACE team) or community.
"""
enum CatalogTier {
  OFFICIAL
  COMMUNITY
}

"""
Type of a fault parameter value.
"""
enum FaultParameterType {
  INTEGER
  STRING
  BOOLEAN
  ENUM
  PERCENT
}

"""
Human-readable description of a fault.
"""
type FaultDescription {
  short: String!
  long: String!
  suitableFor: [String!]!
  notSuitableFor: [String!]!
}

"""
How the fault is executed at runtime (implementation details).
"""
type FaultImplementation {
  type: FaultImplementationType!
  chaosKind: String
  experimentRef: String
  namespace: String
  image: String
  endpoint: String
}

"""
A single configurable parameter of a fault.
"""
type FaultParameter {
  key: String!
  displayName: String!
  type: FaultParameterType!
  unit: String
  default: String!
  min: Int
  max: Int
  required: Boolean!
  description: String!
  litmusEnv: String
  allowedValues: [String!]
}

"""
Compatibility constraints for a fault.
"""
type FaultCompatibility {
  targetDomains: [String!]!
  incompatibleApps: [String!]!
  requiredCapabilities: [String!]!
}

"""
Expected observable symptoms when this fault is active.
"""
type FaultObservability {
  expectedSymptoms: [String!]!
  expectedAlerts: [String!]!
  detectionWindowSecs: Int!
}

"""
Machine-readable ground truth used by the certifier for scoring.
"""
type FaultGroundTruth {
  category: GroundTruthCategory!
  impact: String!
  detectWithinSecs: Int!
  mitigateWithinSecs: Int!
  detectionHints: [String!]!
  remediationHints: [String!]!
}

"""
A single fault from the ACE fault catalog.
"""
type FaultSpec {
  name: String!
  displayName: String!
  version: String!
  tier: CatalogTier!
  scope: FaultScope!
  domain: String
  targetApp: String
  tags: [String!]!
  filePath: String!
  description: FaultDescription!
  implementation: FaultImplementation!
  parameters: [FaultParameter!]!
  compatibility: FaultCompatibility!
  observability: FaultObservability!
  groundTruth: FaultGroundTruth!
}

extend type Query {
  """
  List all faults, optionally filtered by scope, domain, or targetApp.
  Pass no arguments to list all faults across all scopes.
  """
  listFaults(
    scope: FaultScope
    domain: String
    targetApp: String
  ): [FaultSpec!]! @authorized

  """
  Retrieve a single fault by its catalog name slug (e.g. "pod-delete").
  Returns null if the fault does not exist.
  """
  getFault(name: String!): FaultSpec @authorized

  """
  Returns all faults applicable to the named app:
  general + domain-matching + app-specific, minus incompatible ones.
  This is the primary query used by the Chaos Studio fault library panel.
  """
  faultsForApp(appName: String!): [FaultSpec!]! @authorized
}
```

### Task 2: Run `gqlgen generate`

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server
go run github.com/99designs/gqlgen generate
```

This should create or update `graph/fault_catalog.resolvers.go` with stub implementations.
If it does not automatically create the file, check `gqlgen.yml` for the `resolver` stubs config
and run with `--verbose`.

Verify the stubs compile:
```bash
go build ./graph/...
```

### Task 3: Update `graph/resolver.go`

Add the fault catalog service to the `Resolver` struct:

```go
// In graph/resolver.go, add to the Resolver struct:
type Resolver struct {
    // ... existing fields ...
    FaultCatalogService fault_catalog.Service
}
```

In the server startup (where the `Resolver` is constructed), add:
```go
resolver := &graph.Resolver{
    // ... existing fields ...
    FaultCatalogService: faultCatalogSvc, // from Stage 02 startup wiring
}
```

### Task 4: Implement `graph/fault_catalog.resolvers.go`

Replace the generated stubs with implementations that call the service:

```go
package graph

// ListFaults is the resolver for the listFaults field.
func (r *queryResolver) ListFaults(
    ctx context.Context,
    scope *model.FaultScope,
    domain *string,
    targetApp *string,
) ([]*model.FaultSpec, error) {
    // Convert GraphQL enums to catalog package types
    var svc_scope fault_catalog.FaultScope
    if scope != nil {
        svc_scope = graphqlScopeToService(*scope)
    }
    var domainStr, targetAppStr string
    if domain != nil {
        domainStr = *domain
    }
    if targetApp != nil {
        targetAppStr = *targetApp
    }

    entries := r.FaultCatalogService.ListFaults(svc_scope, domainStr, targetAppStr)
    return faultEntriesToGraphQL(entries), nil
}

// GetFault is the resolver for the getFault field.
func (r *queryResolver) GetFault(ctx context.Context, name string) (*model.FaultSpec, error) {
    entry, err := r.FaultCatalogService.GetFault(name)
    if err != nil {
        // Return nil, nil for not-found (GraphQL nullable return)
        if _, ok := err.(fault_catalog.ErrFaultNotFound); ok {
            return nil, nil
        }
        return nil, err
    }
    result := faultEntryToGraphQL(entry)
    return result, nil
}

// FaultsForApp is the resolver for the faultsForApp field.
// Full compatibility filter (domain lookup from app.yaml) is in Stage 06.
// This stub returns general + app-specific, with domain hardcoded as empty
// until Stage 06 wires the app registry lookup.
func (r *queryResolver) FaultsForApp(ctx context.Context, appName string) ([]*model.FaultSpec, error) {
    // Stage 06 will look up appDomain from apps_registry.
    // For now, call with empty domain so only general + app-specific are returned.
    entries := r.FaultCatalogService.FaultsForApp(appName, "")
    return faultEntriesToGraphQL(entries), nil
}
```

Create a conversion helper file `graph/fault_catalog_converters.go` with:
- `faultEntryToGraphQL(e *fault_catalog.FaultCatalogEntry) *model.FaultSpec`
- `faultEntriesToGraphQL(entries []*fault_catalog.FaultCatalogEntry) []*model.FaultSpec`
- `graphqlScopeToService(scope model.FaultScope) fault_catalog.FaultScope`

---

## Verification Criteria

### Must Pass

1. `gqlgen generate` runs without errors after adding `fault_catalog.graphqls`.

2. Server compiles:
   ```bash
   go build ./...
   ```

3. `listFaults` query returns results:
   ```bash
   curl -s -X POST http://localhost:8080/query \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer $TOKEN" \
     -d '{"query": "{ listFaults { name scope domain tags } }"}' | jq '.data.listFaults | length'
   # Expected: >= 5
   ```

4. `getFault` by name returns correct data:
   ```bash
   curl -s -X POST http://localhost:8080/query \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer $TOKEN" \
     -d '{"query": "{ getFault(name: \"pod-delete\") { name scope groundTruth { detectWithinSecs } } }"}' | jq .
   # Expected: detectWithinSecs: 60
   ```

5. `getFault` on unknown name returns `null` (not an error):
   ```bash
   curl -s -X POST http://localhost:8080/query \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer $TOKEN" \
     -d '{"query": "{ getFault(name: \"does-not-exist\") { name } }"}' | jq '.data.getFault'
   # Expected: null
   ```

### Should Pass

6. `faultsForApp("sock-shop")` returns at least the app-specific fault `carts-db-corrupt`
   (domain filter will be wired in Stage 06).

7. `listFaults(scope: DOMAIN, domain: "telecom")` returns `snmp-trap-flood`.

8. Unauthorized request returns a 401 / permission denied error (verifying `@authorized` works).

---

## Testing Commands

```bash
# Start server with catalog loaded
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server
ACE_CATALOG_ROOT=/srv/projects/ace-monorepo/catalog go run . &
SERVER_PID=$!

# Get auth token (use existing auth mechanism)
TOKEN=$(curl -s -X POST http://localhost:8080/auth/login \
  -d '{"username":"admin","password":"litmus"}' | jq -r .accessToken)

# Run queries
curl -s -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "{ listFaults { name scope } }"}' | jq .

kill $SERVER_PID
```

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `gqlgen generate` fails with "type already defined" | New GraphQL type name collides with an existing type in another `.graphqls` file | Prefix the conflicting type name with `Fault` (e.g., `FaultImplementationType` instead of `ImplementationType`) |
| Resolver method not found in stubs | `gqlgen.yml` resolvers binding config is per-file and new file not in the list | Check `gqlgen.yml` `resolver` section; ensure it picks up all `*.graphqls` in the shared dir |
| `@authorized` directive not recognized | The directive is defined elsewhere but not imported | Look at how other files use `@authorized` — it may be defined in `common.graphqls` as a schema directive |
| Conversion from catalog scope to GraphQL enum fails | Enum values differ (e.g., `app-specific` vs `APP_SPECIFIC`) | The converter function must map explicitly: `"app-specific" → model.FaultScopeAppSpecific` |

---

## Rollback Procedure

```bash
# Remove the new schema file
rm /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/definitions/shared/fault_catalog.graphqls

# Remove the generated and manual resolver files
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/graph/fault_catalog.resolvers.go
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/graph/fault_catalog_converters.go

# Re-run gqlgen to regenerate without the fault_catalog schema
go run github.com/99designs/gqlgen generate

# Revert resolver.go changes
git checkout graph/resolver.go
```

---

## Success Criteria

Stage 03 is complete when:
- `go build ./...` succeeds
- `listFaults` returns ≥ 5 faults via a live curl query
- `getFault("pod-delete")` returns the correct struct
- `getFault("nonexistent")` returns GraphQL `null`
- Unauthenticated requests are rejected

**Next Stage:** Stage 04 — ExperimentDefinition Go Types + MongoDB Collection
