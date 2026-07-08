# Stage 04: CatalogService Go Package

**Phase:** 1 — Backend CatalogService  
**Dependencies:** Stage 03  
**Risk Level:** Medium

---

## Objectives

1. Create the `catalog` Go package at `AgentCert/chaoscenter/graphql/server/pkg/catalog/`
2. Implement `CatalogService` that reads `catalog/apps/**/*.yaml` from the monorepo filesystem
3. Build in-memory index with SIGHUP reload capability
4. Validate each entry against the required fields; skip invalid entries with a log warning

---

## Current State Analysis

### What We Have
- `pkg/apphub/service.go` — reads `chartserviceversion.yaml` from a cloned Git repo. **This is the direct pattern to follow.**
- `pkg/apphub/handler.go` — reads CSV YAML → `AppEntry` → `AppHubEntry` model. Same parsing pattern.
- `graph/resolver.go` — wires services together; `appHubService` registered there.
- `graph/hubs.resolvers.go` — existing resolvers for `listAppHubCategories` / `getAppHubStatus`

### What We Need
- New `pkg/catalog/` package with:
  - `model.go` — Go structs for `AppCatalogEntry` YAML parsing (internal, not GraphQL models)
  - `loader.go` — reads all `app.yaml` files, parses, validates, returns `[]ParsedApp`
  - `service.go` — `CatalogService` interface, in-memory index, `ListApplications`/`GetApplication`
- Config env vars: `CATALOG_DIR` (path to `catalog/` directory)
- SIGHUP handler to reload the index

### Key Reuse Notes
- Copy the `gopkg.in/yaml.v2` parsing pattern from `pkg/apphub/handler.go`
- Copy the env var config pattern from `pkg/apphub/service.go` (`utils.Config.*`)
- The in-memory map pattern replaces the filesystem-per-request read in `apphub`

---

## Pre-Stage Verification

```bash
# Confirm Stage 03 complete
bash /srv/projects/ace-monorepo/catalog/validate.sh

# Check existing apphub service as reference
cat /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/apphub/service.go | head -50
cat /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/apphub/handler.go | head -50

# Check what config fields exist
grep -n "AppHub\|Catalog" /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/utils/variables.go
```

---

## Implementation Tasks

### Task 1: Add `CATALOG_DIR` config variable

**File to Modify:** `AgentCert/chaoscenter/graphql/server/utils/variables.go`

Add the `CatalogDir` field to the existing `config` struct alongside `DefaultAppHubPath`:

```go
// Find the existing struct in variables.go and add:
CatalogDir string `split_words:"true" default:"/catalog"`
```

The default `/catalog` assumes the monorepo's `catalog/` directory is mounted at `/catalog` in the container (or set via env var `CATALOG_DIR=/srv/projects/ace-monorepo/catalog` for local dev).

### Task 2: Create `pkg/catalog/model.go`

**File to Create:** `AgentCert/chaoscenter/graphql/server/pkg/catalog/model.go`

Internal Go structs for parsing `app.yaml` — these are NOT the GraphQL model types.

```go
package catalog

// AppCatalogEntry is the internal Go representation of an app.yaml file.
type AppCatalogEntry struct {
	APIVersion string          `yaml:"apiVersion"`
	Kind       string          `yaml:"kind"`
	Metadata   AppMetadata     `yaml:"metadata"`
	Spec       AppSpec         `yaml:"spec"`
}

type AppMetadata struct {
	Name              string        `yaml:"name"`
	DisplayName       string        `yaml:"displayName"`
	Version           string        `yaml:"version"`
	Tier              string        `yaml:"tier"`
	Domain            string        `yaml:"domain"`
	CapabilityDomains []string      `yaml:"capabilityDomains"`
	Tags              []string      `yaml:"tags"`
	Maintainers       []Maintainer  `yaml:"maintainers"`
	License           string        `yaml:"license"`
	Repository        string        `yaml:"repository"`
	CreatedAt         string        `yaml:"createdAt"`
	UpdatedAt         string        `yaml:"updatedAt"`
}

type Maintainer struct {
	Name  string `yaml:"name"`
	Email string `yaml:"email"`
}

type AppSpec struct {
	Description       AppDescription       `yaml:"description"`
	Install           InstallSpec          `yaml:"install"`
	HealthProbe       HealthProbeSpec      `yaml:"healthProbe"`
	LoadTest          LoadTestSpec         `yaml:"loadTest"`
	Microservices     []MicroserviceSpec   `yaml:"microservices"`
	Observability     ObservabilitySpec    `yaml:"observability"`
	FaultCompatibility []FaultCompatEntry  `yaml:"faultCompatibility"`
	GroundTruth       GroundTruthSpec      `yaml:"groundTruth"`
	RBAC              RBACSpec             `yaml:"rbac"`
	Inputs            []AppInput           `yaml:"inputs"`
}

type AppDescription struct {
	Short         string   `yaml:"short"`
	Long          string   `yaml:"long"`
	SuitableFor   []string `yaml:"suitableFor"`
	NotSuitableFor []string `yaml:"notSuitableFor"`
}

type InstallSpec struct {
	Method              string        `yaml:"method"`
	Folder              string        `yaml:"folder"`
	ChartRef            *ChartRef     `yaml:"chartRef,omitempty"`
	Namespace           NamespaceSpec `yaml:"namespace"`
	Timeout             string        `yaml:"timeout"`
	Wait                bool          `yaml:"wait"`
	AdditionalManifests []string      `yaml:"additionalManifests"`
}

type ChartRef struct {
	Repo    string `yaml:"repo"`
	Chart   string `yaml:"chart"`
	Version string `yaml:"version"`
}

type NamespaceSpec struct {
	Default      string `yaml:"default"`
	Configurable bool   `yaml:"configurable"`
}

type HealthProbeSpec struct {
	URL                  string            `yaml:"url"`
	ExpectedStatus       string            `yaml:"expectedStatus"`
	InitialDelaySeconds  int               `yaml:"initialDelaySeconds"`
	PeriodSeconds        int               `yaml:"periodSeconds"`
	FailureThreshold     int               `yaml:"failureThreshold"`
	Headers              map[string]string `yaml:"headers"`
	InsecureSkipTLS      bool              `yaml:"insecureSkipTLS"`
}

type LoadTestSpec struct {
	Enabled          bool     `yaml:"enabled"`
	Method           string   `yaml:"method"`
	Image            string   `yaml:"image"`
	Args             []string `yaml:"args"`
	InstallNamespace string   `yaml:"installNamespace"`
}

type MicroserviceSpec struct {
	Name           string          `yaml:"name"`
	DisplayName    string          `yaml:"displayName"`
	Description    string          `yaml:"description"`
	K8s            K8sSpec         `yaml:"k8s"`
	RelevantFaults []string        `yaml:"relevantFaults"`
	Criticality    string          `yaml:"criticality"`
	DependsOn      []string        `yaml:"dependsOn"`
	SLA            *SLASpec        `yaml:"sla,omitempty"`
}

type K8sSpec struct {
	Label         string `yaml:"label"`
	Kind          string `yaml:"kind"`
	Namespace     string `yaml:"namespace"`
	ContainerName string `yaml:"containerName"`
}

type SLASpec struct {
	ErrorRateThreshold float64 `yaml:"errorRateThreshold"`
}

type ObservabilitySpec struct {
	Prometheus PrometheusSpec `yaml:"prometheus"`
}

type PrometheusSpec struct {
	ServiceMonitor bool        `yaml:"serviceMonitor"`
	AlertRules     []AlertRule `yaml:"alertRules"`
}

type AlertRule struct {
	Name        string            `yaml:"name"`
	Severity    string            `yaml:"severity"`
	Expr        string            `yaml:"expr"`
	For         string            `yaml:"for"`
	Annotations map[string]string `yaml:"annotations"`
}

type FaultCompatEntry struct {
	FaultName          string   `yaml:"faultName"`
	Compatible         bool     `yaml:"compatible"`
	Notes              string   `yaml:"notes"`
	RecommendedTargets []string `yaml:"recommendedTargets"`
}

type GroundTruthSpec struct {
	Version            string              `yaml:"version"`
	FaultAlertMappings []FaultAlertMapping `yaml:"faultAlertMappings"`
}

type FaultAlertMapping struct {
	FaultName            string   `yaml:"faultName"`
	TargetService        string   `yaml:"targetService"`
	ExpectedAlerts       []string `yaml:"expectedAlerts"`
	ExpectedRootCause    string   `yaml:"expectedRootCause"`
	ExpectedRemediation  string   `yaml:"expectedRemediation"`
	MaxDetectionTimeSecs int      `yaml:"maxDetectionTimeSecs"`
	MaxMitigationTimeSecs int     `yaml:"maxMitigationTimeSecs"`
}

type RBACSpec struct {
	ChaosRunnerPermissions []interface{} `yaml:"chaosRunnerPermissions"`
}

type AppInput struct {
	Key         string   `yaml:"key"`
	DisplayName string   `yaml:"displayName"`
	Description string   `yaml:"description"`
	Type        string   `yaml:"type"`
	Required    bool     `yaml:"required"`
	Default     string   `yaml:"default"`
	HelmPath    string   `yaml:"helmPath"`
	Values      []string `yaml:"values"`
	Min         *int     `yaml:"min,omitempty"`
	Max         *int     `yaml:"max,omitempty"`
	Unit        string   `yaml:"unit"`
	Advanced    bool     `yaml:"advanced"`
}
```

### Task 3: Create `pkg/catalog/loader.go`

**File to Create:** `AgentCert/chaoscenter/graphql/server/pkg/catalog/loader.go`

```go
package catalog

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	log "github.com/sirupsen/logrus"
	"gopkg.in/yaml.v2"
)

// LoadAll reads all app.yaml files from the given catalog root directory.
// Invalid entries are logged and skipped (never cause a panic or crash).
// Returns entries sorted: official first (alphabetical), then community (alphabetical).
func LoadAll(catalogDir string) ([]*AppCatalogEntry, error) {
	appsDir := filepath.Join(catalogDir, "apps")
	
	if _, err := os.Stat(appsDir); os.IsNotExist(err) {
		return nil, fmt.Errorf("catalog apps directory not found: %s", appsDir)
	}

	var official, community []*AppCatalogEntry

	for _, tier := range []string{"official", "community"} {
		tierDir := filepath.Join(appsDir, tier)
		if _, err := os.Stat(tierDir); os.IsNotExist(err) {
			continue
		}

		entries, err := os.ReadDir(tierDir)
		if err != nil {
			log.WithError(err).Errorf("failed to read catalog tier directory: %s", tierDir)
			continue
		}

		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			appYAML := filepath.Join(tierDir, entry.Name(), "app.yaml")
			if _, err := os.Stat(appYAML); os.IsNotExist(err) {
				continue
			}

			app, err := loadAppYAML(appYAML)
			if err != nil {
				log.WithFields(log.Fields{
					"file":  appYAML,
					"error": err,
				}).Warn("skipping invalid app.yaml")
				continue
			}

			if err := validateEntry(app, appYAML); err != nil {
				log.WithFields(log.Fields{
					"app":   app.Metadata.Name,
					"error": err,
				}).Warn("skipping app.yaml that failed validation")
				continue
			}

			switch tier {
			case "official":
				official = append(official, app)
			case "community":
				community = append(community, app)
			}
		}
	}

	return append(official, community...), nil
}

func loadAppYAML(path string) (*AppCatalogEntry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read error: %w", err)
	}

	var entry AppCatalogEntry
	if err := yaml.Unmarshal(data, &entry); err != nil {
		return nil, fmt.Errorf("parse error: %w", err)
	}

	return &entry, nil
}

// validateEntry checks required fields and the {{.AppNamespace}} template variable rule.
func validateEntry(app *AppCatalogEntry, filePath string) error {
	if app.APIVersion != "ace.io/v1" {
		return fmt.Errorf("apiVersion must be ace.io/v1, got %q", app.APIVersion)
	}
	if app.Kind != "AppCatalogEntry" {
		return fmt.Errorf("kind must be AppCatalogEntry, got %q", app.Kind)
	}
	if app.Metadata.Name == "" {
		return fmt.Errorf("metadata.name is required")
	}
	if app.Metadata.Version == "" {
		return fmt.Errorf("metadata.version is required (app: %s)", app.Metadata.Name)
	}
	if app.Metadata.Tier != "official" && app.Metadata.Tier != "community" {
		return fmt.Errorf("metadata.tier must be 'official' or 'community', got %q (app: %s)", app.Metadata.Tier, app.Metadata.Name)
	}
	if len(app.Metadata.Maintainers) == 0 {
		return fmt.Errorf("metadata.maintainers must have at least one entry (app: %s)", app.Metadata.Name)
	}
	
	// healthProbe.url must use {{.AppNamespace}}
	if !strings.Contains(app.Spec.HealthProbe.URL, "{{.AppNamespace}}") {
		return fmt.Errorf("healthProbe.url must contain {{.AppNamespace}}, got %q (app: %s)", app.Spec.HealthProbe.URL, app.Metadata.Name)
	}

	return nil
}
```

### Task 4: Create `pkg/catalog/service.go`

**File to Create:** `AgentCert/chaoscenter/graphql/server/pkg/catalog/service.go`

```go
package catalog

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"sync"
	"syscall"

	"github.com/litmuschaos/litmus/chaoscenter/graphql/server/graph/model"
	"github.com/litmuschaos/litmus/chaoscenter/graphql/server/utils"
	log "github.com/sirupsen/logrus"
)

// Service provides access to the app catalog.
type Service interface {
	ListApplications(ctx context.Context, projectID string) ([]*model.ApplicationSpec, error)
	GetApplication(ctx context.Context, projectID, appName string) (*model.ApplicationSpec, error)
}

type catalogService struct {
	mu       sync.RWMutex
	index    map[string]*model.ApplicationSpec // keyed by metadata.name
	ordered  []*model.ApplicationSpec          // official first, then community
}

// NewService creates a new CatalogService, loads the catalog immediately,
// and starts a SIGHUP listener for zero-downtime reloads.
func NewService() (Service, error) {
	svc := &catalogService{}
	if err := svc.reload(); err != nil {
		return nil, fmt.Errorf("initial catalog load failed: %w", err)
	}
	go svc.listenForReload()
	return svc, nil
}

func (s *catalogService) reload() error {
	catalogDir := utils.Config.CatalogDir
	if catalogDir == "" {
		catalogDir = "/catalog"
	}

	entries, err := LoadAll(catalogDir)
	if err != nil {
		return err
	}

	index := make(map[string]*model.ApplicationSpec, len(entries))
	ordered := make([]*model.ApplicationSpec, 0, len(entries))
	for _, e := range entries {
		spec := toGraphQLModel(e)
		index[e.Metadata.Name] = spec
		ordered = append(ordered, spec)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.index = index
	s.ordered = ordered

	log.WithField("count", len(entries)).Info("catalog loaded")
	return nil
}

func (s *catalogService) listenForReload() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGHUP)
	for range ch {
		log.Info("SIGHUP received — reloading catalog")
		if err := s.reload(); err != nil {
			log.WithError(err).Error("catalog reload failed")
		}
	}
}

func (s *catalogService) ListApplications(ctx context.Context, projectID string) ([]*model.ApplicationSpec, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]*model.ApplicationSpec, len(s.ordered))
	copy(result, s.ordered)
	return result, nil
}

func (s *catalogService) GetApplication(ctx context.Context, projectID, appName string) (*model.ApplicationSpec, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if spec, ok := s.index[appName]; ok {
		return spec, nil
	}
	return nil, nil
}

// toGraphQLModel converts an internal AppCatalogEntry to the GraphQL model.ApplicationSpec.
// This function is defined in mapper.go (to be created in Stage 05 alongside the GraphQL types).
func toGraphQLModel(e *AppCatalogEntry) *model.ApplicationSpec {
	// Implemented in Stage 05 after model.ApplicationSpec is generated
	// Placeholder — fill in Stage 05
	_ = e
	return nil
}
```

**Note:** `toGraphQLModel` is a placeholder until Stage 05 adds `model.ApplicationSpec` to the generated GraphQL models. The package will compile with the placeholder — it just returns nil. Stage 05 fills it in.

---

## Files to Create (Summary)

```
AgentCert/chaoscenter/graphql/server/pkg/catalog/
├── model.go      (new — internal YAML structs)
├── loader.go     (new — filesystem reader + validator)
└── service.go    (new — in-memory index + SIGHUP reload)
```

**Files to Modify:**
- `AgentCert/chaoscenter/graphql/server/utils/variables.go` — add `CatalogDir` field

---

## Verification Criteria

### Must Pass
- [ ] `go build ./pkg/catalog/...` succeeds from `graphql/server/`
- [ ] `go vet ./pkg/catalog/...` passes without errors
- [ ] `CatalogService` successfully loads `catalog/apps/official/sock-shop/app.yaml` when `CATALOG_DIR` is set correctly
- [ ] Invalid app.yaml (wrong apiVersion) causes a warning log and is skipped, not a crash
- [ ] `ListApplications` returns Sock Shop when the real catalog dir is pointed to

### Should Pass
- [ ] SIGHUP causes reload without restart (test manually: `kill -HUP <pid>`)

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server

# Build check
go build ./pkg/catalog/...

# Vet check
go vet ./pkg/catalog/...

# Manual integration test (run after Stage 05 adds the GraphQL model)
CATALOG_DIR=/srv/projects/ace-monorepo/catalog go test ./pkg/catalog/... -v
```

---

## Common Issues and Solutions

### Issue: gopkg.in/yaml.v2 not imported in new package
**Symptom:** `cannot find package "gopkg.in/yaml.v2"`  
**Solution:** It's already in `go.mod` (used by `apphub`). No new `go get` needed.

### Issue: utils.Config.CatalogDir is empty at startup
**Symptom:** catalog loads from wrong path or not at all  
**Solution:** Set `CATALOG_DIR=/srv/projects/ace-monorepo/catalog` in `.env` or the local dev docker-compose override.

---

## Success Criteria

Stage 04 is complete when:
1. `pkg/catalog/` package compiles without errors
2. `CATALOG_DIR` config field added to `variables.go`
3. `LoadAll()` correctly reads and skips entries
4. `CatalogService` builds in-memory index on startup
5. SIGHUP handler registered (even if reload is no-op until catalog has multiple entries)

## Next Stage

Proceed to **Stage 05: GraphQL Schema Extension + Resolvers**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
