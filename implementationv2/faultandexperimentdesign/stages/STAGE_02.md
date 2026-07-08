# Stage 02: FaultCatalogEntry Go Types + YAML Loader

**Phase:** 0 — Fault Catalog  
**Status:** Not Started  
**Estimated Effort:** 1 day  
**Date Added:** 2026-07-07  
**Depends On:** Stage 01 (fault.yaml files must exist)

---

## Objectives

1. Create the `pkg/fault_catalog/` Go package in the GraphQL server.
2. Define `FaultCatalogEntry` and all sub-structs mirroring the `fault.yaml` schema.
3. Implement a startup YAML loader that walks `catalog/faults/` and `catalog/apps/*/faults/`
   and builds an in-memory index keyed by `(scope, domain, name)`.
4. Implement the service layer: `ListFaults`, `GetFault`, `FaultsForApp` (stub — full filter in Stage 06).
5. Wire the loader into the GraphQL server's `main.go` startup sequence.
6. Unit tests pass with a local test fixture.

---

## Current State Analysis

### What Exists
- Pattern to follow: `pkg/apphub/service.go` and `pkg/agenthub/` — both walk a local filesystem
  path and build in-memory state. The `apphub` service uses `filepath.Walk` and YAML unmarshaling.
- `pkg/database/` for MongoDB; fault catalog does NOT go to MongoDB — in-memory only.
- `main.go` at `AgentCert/chaoscenter/graphql/server/server.go` or similar — check with:
  ```bash
  find /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server -name "*.go" -maxdepth 1 | head
  ```

### What Is Needed
- New package directory: `AgentCert/chaoscenter/graphql/server/pkg/fault_catalog/`
- Files: `model.go`, `loader.go`, `service.go`, `errors.go`
- Unit test file: `loader_test.go` with a local `testdata/` fixture

---

## Pre-Stage Verification

```bash
# 1. Stage 01 complete — fault.yamls exist
find /srv/projects/ace-monorepo/catalog -name "fault.yaml" | wc -l
# Expected: >= 5

# 2. Confirm apphub pattern to model after
ls /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/apphub/

# 3. Confirm Go module path
head -5 /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/go.mod
# Note the module path, e.g. github.com/litmuschaos/litmus/chaoscenter/graphql/server

# 4. Confirm package compiles before changes
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server
go build ./... 2>&1 | head -20
```

---

## Implementation Tasks

### Task 1: Create `pkg/fault_catalog/model.go`

Package path: `AgentCert/chaoscenter/graphql/server/pkg/fault_catalog/model.go`

```go
package fault_catalog

// FaultScope represents the three-tier taxonomy.
type FaultScope string

const (
    ScopeGeneral     FaultScope = "general"
    ScopeDomain      FaultScope = "domain"
    ScopeAppSpecific FaultScope = "app-specific"
)

// FaultImplementationType is the execution mechanism.
type FaultImplementationType string

const (
    ImplLitmus   FaultImplementationType = "litmus"
    ImplHTTPFault FaultImplementationType = "http-fault"
    ImplScript   FaultImplementationType = "script"
    ImplExternal FaultImplementationType = "external"
)

// ParameterType is the type of a fault parameter.
type ParameterType string

const (
    ParamTypeInteger ParameterType = "integer"
    ParamTypeString  ParameterType = "string"
    ParamTypeBoolean ParameterType = "boolean"
    ParamTypeEnum    ParameterType = "enum"
    ParamTypePercent ParameterType = "percent"
)

// GroundTruthCategory maps to the certifier's scoring categories.
type GroundTruthCategory string

const (
    GTCatAvailability  GroundTruthCategory = "availability"
    GTCatPerformance   GroundTruthCategory = "performance"
    GTCatSecurity      GroundTruthCategory = "security"
    GTCatDataIntegrity GroundTruthCategory = "data-integrity"
    GTCatConfiguration GroundTruthCategory = "configuration"
)

// CatalogTier is official vs community.
type CatalogTier string

const (
    TierOfficial  CatalogTier = "official"
    TierCommunity CatalogTier = "community"
)

// FaultMaintainer is a contact for the fault.
type FaultMaintainer struct {
    Name  string `yaml:"name"`
    Email string `yaml:"email"`
}

// FaultMetadata mirrors the metadata block of fault.yaml.
type FaultMetadata struct {
    Name        string            `yaml:"name"`
    DisplayName string            `yaml:"displayName"`
    Version     string            `yaml:"version"`
    Tier        CatalogTier       `yaml:"tier"`
    Scope       FaultScope        `yaml:"scope"`
    Domain      *string           `yaml:"domain"`
    TargetApp   *string           `yaml:"targetApp"`
    Tags        []string          `yaml:"tags"`
    Maintainers []FaultMaintainer `yaml:"maintainers"`
}

// FaultDescription is the human-readable description block.
type FaultDescription struct {
    Short          string   `yaml:"short"`
    Long           string   `yaml:"long"`
    SuitableFor    []string `yaml:"suitableFor"`
    NotSuitableFor []string `yaml:"notSuitableFor"`
}

// FaultImplementation defines how the fault is executed.
type FaultImplementation struct {
    Type          FaultImplementationType `yaml:"type"`
    ChaosKind     string                  `yaml:"chaosKind,omitempty"`
    ExperimentRef string                  `yaml:"experimentRef,omitempty"`
    Namespace     string                  `yaml:"namespace,omitempty"`
    // For http-fault type
    Target *struct {
        Service string `yaml:"service"`
        Port    int    `yaml:"port"`
        Path    string `yaml:"path"`
    } `yaml:"target,omitempty"`
    // For script type
    Image   string   `yaml:"image,omitempty"`
    Command []string `yaml:"command,omitempty"`
    Args    []string `yaml:"args,omitempty"`
    // For external type
    Endpoint string `yaml:"endpoint,omitempty"`
    Method   string `yaml:"method,omitempty"`
}

// FaultParameter is one configurable parameter.
type FaultParameter struct {
    Key         string        `yaml:"key"`
    DisplayName string        `yaml:"displayName"`
    Type        ParameterType `yaml:"type"`
    Unit        string        `yaml:"unit,omitempty"`
    Default     string        `yaml:"default"`
    Min         *int          `yaml:"min,omitempty"`
    Max         *int          `yaml:"max,omitempty"`
    Required    bool          `yaml:"required"`
    Description string        `yaml:"description"`
    LitmusEnv   string        `yaml:"litmusEnv,omitempty"`
    AllowedValues []string    `yaml:"allowedValues,omitempty"` // for enum type
}

// FaultCompatibility declares where this fault can be used.
type FaultCompatibility struct {
    TargetDomains        []string `yaml:"targetDomains"`
    IncompatibleApps     []string `yaml:"incompatibleApps"`
    RequiredCapabilities []string `yaml:"requiredCapabilities"`
}

// FaultObservability describes expected symptoms and alerts.
type FaultObservability struct {
    ExpectedSymptoms    []string `yaml:"expectedSymptoms"`
    ExpectedAlerts      []string `yaml:"expectedAlerts"`
    DetectionWindowSecs int      `yaml:"detectionWindowSecs"`
}

// FaultGroundTruth is the machine-readable expected outcome.
type FaultGroundTruth struct {
    Category           GroundTruthCategory `yaml:"category"`
    Impact             string              `yaml:"impact"` // low|medium|high|critical
    DetectWithinSecs   int                 `yaml:"detectWithinSecs"`
    MitigateWithinSecs int                 `yaml:"mitigateWithinSecs"`
    DetectionHints     []string            `yaml:"detectionHints"`
    RemediationHints   []string            `yaml:"remediationHints"`
}

// FaultSpec is the spec block of fault.yaml.
type FaultSpec struct {
    Description   FaultDescription   `yaml:"description"`
    Implementation FaultImplementation `yaml:"implementation"`
    Parameters    []FaultParameter   `yaml:"parameters"`
    Compatibility FaultCompatibility `yaml:"compatibility"`
    Observability FaultObservability `yaml:"observability"`
    GroundTruth   FaultGroundTruth   `yaml:"groundTruth"`
}

// FaultCatalogEntry is the top-level struct for a fault.yaml file.
type FaultCatalogEntry struct {
    APIVersion string        `yaml:"apiVersion"`
    Kind       string        `yaml:"kind"`
    Metadata   FaultMetadata `yaml:"metadata"`
    Spec       FaultSpec     `yaml:"spec"`

    // FilePath is set by the loader — not part of the YAML schema.
    FilePath string `yaml:"-"`
}
```

### Task 2: Create `pkg/fault_catalog/errors.go`

```go
package fault_catalog

import "fmt"

// ErrFaultNotFound is returned when a fault name does not exist in the catalog.
type ErrFaultNotFound struct {
    Name string
}

func (e ErrFaultNotFound) Error() string {
    return fmt.Sprintf("fault catalog: fault not found: %q", e.Name)
}

// ErrInvalidScope is returned when a scope value is not one of the three valid values.
type ErrInvalidScope struct {
    Scope string
}

func (e ErrInvalidScope) Error() string {
    return fmt.Sprintf("fault catalog: invalid scope %q: must be general, domain, or app-specific", e.Scope)
}

// ErrInvalidFaultYAML is returned when a fault.yaml fails to parse.
type ErrInvalidFaultYAML struct {
    Path string
    Err  error
}

func (e ErrInvalidFaultYAML) Error() string {
    return fmt.Sprintf("fault catalog: failed to parse %s: %v", e.Path, e.Err)
}
```

### Task 3: Create `pkg/fault_catalog/loader.go`

```go
package fault_catalog

import (
    "os"
    "path/filepath"
    "sync"

    log "github.com/sirupsen/logrus"
    "gopkg.in/yaml.v3"
)

// CatalogIndex is the in-memory index of all loaded faults.
// Key: fault metadata name (unique across the full catalog).
type CatalogIndex struct {
    mu     sync.RWMutex
    byName map[string]*FaultCatalogEntry
    // Convenience slices for filtered queries
    general     []*FaultCatalogEntry
    byDomain    map[string][]*FaultCatalogEntry // domain -> entries
    byTargetApp map[string][]*FaultCatalogEntry // targetApp -> entries
}

var globalIndex = &CatalogIndex{
    byName:      make(map[string]*FaultCatalogEntry),
    byDomain:    make(map[string][]*FaultCatalogEntry),
    byTargetApp: make(map[string][]*FaultCatalogEntry),
}

// LoadCatalog reads all fault.yaml files from the catalog root and populates
// the global in-memory index. catalogRoot is typically the path to the
// catalog/ directory in the ACE monorepo, configurable via ACE_CATALOG_ROOT.
//
// It walks:
//   catalogRoot/faults/general/<fault-name>/fault.yaml
//   catalogRoot/faults/domains/<domain>/<fault-name>/fault.yaml
//   catalogRoot/apps/<tier>/<app-name>/faults/<fault-name>/fault.yaml
func LoadCatalog(catalogRoot string) error {
    entries, err := walkFaultYAMLs(catalogRoot)
    if err != nil {
        return err
    }

    globalIndex.mu.Lock()
    defer globalIndex.mu.Unlock()

    // Reset index
    globalIndex.byName = make(map[string]*FaultCatalogEntry)
    globalIndex.general = nil
    globalIndex.byDomain = make(map[string][]*FaultCatalogEntry)
    globalIndex.byTargetApp = make(map[string][]*FaultCatalogEntry)

    for i := range entries {
        e := &entries[i]
        name := e.Metadata.Name

        if _, exists := globalIndex.byName[name]; exists {
            log.Warnf("fault_catalog: duplicate fault name %q in %s — skipping", name, e.FilePath)
            continue
        }

        globalIndex.byName[name] = e

        switch e.Metadata.Scope {
        case ScopeGeneral:
            globalIndex.general = append(globalIndex.general, e)
        case ScopeDomain:
            if e.Metadata.Domain != nil {
                d := *e.Metadata.Domain
                globalIndex.byDomain[d] = append(globalIndex.byDomain[d], e)
            }
        case ScopeAppSpecific:
            if e.Metadata.TargetApp != nil {
                a := *e.Metadata.TargetApp
                globalIndex.byTargetApp[a] = append(globalIndex.byTargetApp[a], e)
            }
        }
    }

    log.Infof("fault_catalog: loaded %d faults (%d general, %d domain-specific, %d app-specific)",
        len(globalIndex.byName),
        len(globalIndex.general),
        totalDomainFaults(),
        totalAppFaults(),
    )
    return nil
}

// walkFaultYAMLs finds all fault.yaml files under catalogRoot and returns
// the parsed FaultCatalogEntry structs.
func walkFaultYAMLs(catalogRoot string) ([]FaultCatalogEntry, error) {
    var entries []FaultCatalogEntry

    err := filepath.Walk(catalogRoot, func(path string, info os.FileInfo, err error) error {
        if err != nil {
            return err
        }
        if info.IsDir() || filepath.Base(path) != "fault.yaml" {
            return nil
        }

        data, err := os.ReadFile(path)
        if err != nil {
            log.Warnf("fault_catalog: failed to read %s: %v", path, err)
            return nil // skip, don't abort entire load
        }

        var entry FaultCatalogEntry
        if err := yaml.Unmarshal(data, &entry); err != nil {
            log.Warnf("fault_catalog: failed to parse %s: %v — skipping", path, err)
            return nil
        }

        if entry.Kind != "FaultCatalogEntry" {
            return nil // skip non-fault YAML files (e.g., app.yaml)
        }

        entry.FilePath = path
        entries = append(entries, entry)
        log.Debugf("fault_catalog: loaded fault %q from %s", entry.Metadata.Name, path)
        return nil
    })

    return entries, err
}

func totalDomainFaults() int {
    n := 0
    for _, v := range globalIndex.byDomain {
        n += len(v)
    }
    return n
}

func totalAppFaults() int {
    n := 0
    for _, v := range globalIndex.byTargetApp {
        n += len(v)
    }
    return n
}
```

### Task 4: Create `pkg/fault_catalog/service.go`

```go
package fault_catalog

// Service is the interface for fault catalog queries.
type Service interface {
    // ListFaults returns faults filtered by optional scope, domain, or targetApp.
    // Pass empty strings to return all faults in a category.
    ListFaults(scope FaultScope, domain string, targetApp string) []*FaultCatalogEntry

    // GetFault returns the fault with the given name, or ErrFaultNotFound.
    GetFault(name string) (*FaultCatalogEntry, error)

    // FaultsForApp returns all faults applicable to the given app (general +
    // domain-matching + app-specific), minus any in incompatibleApps for that app.
    // appDomain is the app's declared domain (from app.yaml). appName is the app slug.
    FaultsForApp(appName string, appDomain string) []*FaultCatalogEntry
}

type catalogService struct {
    index *CatalogIndex
}

// NewService returns a new fault catalog Service backed by the global index.
// Call LoadCatalog() before creating a Service.
func NewService() Service {
    return &catalogService{index: globalIndex}
}

func (s *catalogService) ListFaults(scope FaultScope, domain string, targetApp string) []*FaultCatalogEntry {
    s.index.mu.RLock()
    defer s.index.mu.RUnlock()

    if scope == "" && domain == "" && targetApp == "" {
        // Return all faults
        all := make([]*FaultCatalogEntry, 0, len(s.index.byName))
        for _, e := range s.index.byName {
            all = append(all, e)
        }
        return all
    }

    var result []*FaultCatalogEntry
    for _, e := range s.index.byName {
        if scope != "" && e.Metadata.Scope != scope {
            continue
        }
        if domain != "" && (e.Metadata.Domain == nil || *e.Metadata.Domain != domain) {
            continue
        }
        if targetApp != "" && (e.Metadata.TargetApp == nil || *e.Metadata.TargetApp != targetApp) {
            continue
        }
        result = append(result, e)
    }
    return result
}

func (s *catalogService) GetFault(name string) (*FaultCatalogEntry, error) {
    s.index.mu.RLock()
    defer s.index.mu.RUnlock()

    e, ok := s.index.byName[name]
    if !ok {
        return nil, ErrFaultNotFound{Name: name}
    }
    return e, nil
}

// FaultsForApp merges general + domain + app-specific faults and applies
// incompatibility filtering. Stage 06 will extend this with full app.yaml lookup.
func (s *catalogService) FaultsForApp(appName string, appDomain string) []*FaultCatalogEntry {
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

    // 1. General faults
    for _, e := range s.index.general {
        add(e)
    }

    // 2. Domain faults matching appDomain
    if appDomain != "" {
        for _, e := range s.index.byDomain[appDomain] {
            add(e)
        }
    }

    // 3. App-specific faults for this app
    for _, e := range s.index.byTargetApp[appName] {
        add(e)
    }

    return result
}
```

### Task 5: Wire into Server Startup

In the GraphQL server's startup file (check actual path with `grep -r "func main" AgentCert/chaoscenter/graphql/server/`):

```go
// After existing service initializations, add:
catalogRoot := os.Getenv("ACE_CATALOG_ROOT")
if catalogRoot == "" {
    catalogRoot = "/catalog" // default for in-cluster; override for local dev
}
if err := fault_catalog.LoadCatalog(catalogRoot); err != nil {
    log.Warnf("fault catalog load failed (non-fatal): %v", err)
}
faultCatalogSvc := fault_catalog.NewService()
```

The `ACE_CATALOG_ROOT` env var must be added to:
- `AgentCert/chaoscenter/graphql/server/utils/config.go` (or equivalent config struct)
- `agent-charts/templates/graphql-server-deployment.yaml` — pass the catalog volume mount path

---

## Verification Criteria

### Must Pass

1. Package compiles without errors:
   ```bash
   cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server
   go build ./pkg/fault_catalog/...
   ```

2. Unit tests pass:
   ```bash
   go test ./pkg/fault_catalog/... -v
   ```

3. Server starts with fault catalog loaded:
   ```bash
   ACE_CATALOG_ROOT=/srv/projects/ace-monorepo/catalog \
   go run ./server.go 2>&1 | grep "fault_catalog:"
   # Expected: "fault_catalog: loaded N faults..."
   ```

4. `ListFaults(ScopeGeneral, "", "")` returns at least 2 entries (pod-delete, cpu-hog).

### Should Pass

5. `GetFault("pod-delete")` returns the correct entry with all fields populated.
6. `FaultsForApp("sock-shop", "cloud-native")` returns ≥ 4 faults (2 general + 1 domain + 1 app-specific).
7. Duplicate fault name in two different `fault.yaml` files emits a WARN log and keeps only the first.

---

## Testing Commands

```bash
# Full test with fixture
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server
go test ./pkg/fault_catalog/... -v -count=1

# Build verification
go vet ./pkg/fault_catalog/...

# Race detector
go test -race ./pkg/fault_catalog/...
```

Create `pkg/fault_catalog/testdata/` with two minimal fault.yaml files for the unit tests.

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `yaml.Unmarshal` silently ignores fields | Field name in Go struct doesn't match YAML key | Use struct tags exactly: `yaml:"displayName"` not `yaml:"display_name"` |
| Loader finds 0 faults | `ACE_CATALOG_ROOT` path is wrong | Check with `ls $ACE_CATALOG_ROOT/faults/general/` |
| Duplicate name warning for legitimate faults | Same fault name used in `general/` and `domains/` | Fault names must be globally unique across all scopes — rename the duplicate |
| Race condition in concurrent test | `CatalogIndex` not locked during read | Always use `s.index.mu.RLock()` in service methods |
| `gopkg.in/yaml.v3` not in go.mod | Missing dependency | `go get gopkg.in/yaml.v3` then `go mod tidy` |

---

## Rollback Procedure

```bash
# Remove the new package
rm -rf /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/fault_catalog/

# Remove any startup changes (revert the server.go edits)
git diff AgentCert/chaoscenter/graphql/server/server.go
git checkout AgentCert/chaoscenter/graphql/server/server.go
```

---

## Success Criteria

Stage 02 is complete when:
- `go build ./pkg/fault_catalog/...` exits 0
- `go test ./pkg/fault_catalog/...` exits 0
- Server startup log shows "fault_catalog: loaded N faults"
- `NewService().FaultsForApp("sock-shop", "cloud-native")` returns ≥ 4 entries

**Next Stage:** Stage 03 — Fault Catalog GraphQL Schema + Resolvers
