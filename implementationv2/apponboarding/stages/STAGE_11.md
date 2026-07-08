# Stage 11: Backend Contribution Endpoints

**Phase:** 4 — Backend Contribution  
**Dependencies:** Stage 10  
**Risk Level:** Medium

---

## Objectives

1. Add `POST /api/catalog/validate-name` — checks name uniqueness against live catalog
2. Add `POST /api/catalog/discover-services` — runs `helm show all` to parse chart templates
3. Add `POST /api/catalog/generate` — generates app.yaml + README.md content server-side (optional, as client-side generation in Stage 10 already covers this)
4. Replace the stub in `AppsOnboarding.tsx`'s `handleDiscover` with real API calls
5. Wire the endpoints into the existing GraphQL server's Gin router

---

## Current State Analysis

### What We Have
- `pkg/apps_registry/handler.go` — existing REST handler pattern for apps (Gin, JSON, MongoDB)
- `graph/resolver.go` or `api/` directory sets up the Gin router (check exact location)
- The frontend wizard uses stub data for service discovery (Stage 09 task `handleDiscover`)
- `helm` CLI available in the GraphQL server container (confirmed by reference in `ops/service.go`)

### What We Need
- New `pkg/catalog/contribution_handler.go` with 3 endpoint handlers
- Routes wired in the server's Gin router
- Frontend `handleDiscover` updated to call the real endpoint

---

## Pre-Stage Verification

```bash
# Find where Gin routes are registered in the GraphQL server
grep -rn "gin.Default\|gin.New\|router.POST\|router.GET" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/api/ \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/ \
  --include="*.go" | grep -v generated | head -15

# Confirm helm CLI is available in the server container
grep -n "helm\|Helm" /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/chaos_experiment/ops/service.go | head -5

# Check existing apps_registry handler as reference
ls /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/apps_registry/
```

---

## Implementation Tasks

### Task 1: Create `pkg/catalog/contribution_handler.go`

**File to Create:** `AgentCert/chaoscenter/graphql/server/pkg/catalog/contribution_handler.go`

```go
package catalog

import (
	"fmt"
	"net/http"
	"os/exec"
	"regexp"
	"strings"
	"unicode"

	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"
	"gopkg.in/yaml.v2"
)

// ContributionHandler handles REST endpoints for the Contribution Wizard.
type ContributionHandler struct {
	catalogService Service
}

// NewContributionHandler creates a handler backed by the given CatalogService.
func NewContributionHandler(svc Service) *ContributionHandler {
	return &ContributionHandler{catalogService: svc}
}

// RegisterRoutes wires the contribution endpoints into the given Gin router group.
func (h *ContributionHandler) RegisterRoutes(rg *gin.RouterGroup) {
	rg.POST("/catalog/validate-name", h.ValidateName())
	rg.POST("/catalog/discover-services", h.DiscoverServices())
}

// ─── Validate Name ───────────────────────────────────────────────────────────

// ValidateNameRequest is the request body for name validation.
type ValidateNameRequest struct {
	Name string `json:"name"`
}

// ValidateNameResponse is the response for name validation.
type ValidateNameResponse struct {
	Available bool   `json:"available"`
	Error     string `json:"error,omitempty"`
}

// ValidateName checks:
//  1. Name matches kebab-case pattern
//  2. Name does not already exist in the catalog
func (h *ContributionHandler) ValidateName() gin.HandlerFunc {
	namePattern := regexp.MustCompile(`^[a-z0-9][a-z0-9-]*[a-z0-9]$`)

	return func(c *gin.Context) {
		var req ValidateNameRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, ValidateNameResponse{Error: "invalid request body"})
			return
		}

		if !namePattern.MatchString(req.Name) || len(req.Name) > 63 {
			c.JSON(http.StatusOK, ValidateNameResponse{
				Available: false,
				Error:     "Name must be kebab-case (a-z, 0-9, hyphens), max 63 chars, no leading/trailing hyphen",
			})
			return
		}

		if h.catalogService != nil {
			existing, err := h.catalogService.GetApplication(c.Request.Context(), "", req.Name)
			if err == nil && existing != nil {
				c.JSON(http.StatusOK, ValidateNameResponse{
					Available: false,
					Error:     fmt.Sprintf("An app named %q already exists in the catalog", req.Name),
				})
				return
			}
		}

		c.JSON(http.StatusOK, ValidateNameResponse{Available: true})
	}
}

// ─── Discover Services ───────────────────────────────────────────────────────

// DiscoverRequest is the request body for service discovery.
type DiscoverRequest struct {
	RepoURL     string `json:"repoURL"`
	ChartName   string `json:"chartName"`
	ChartVersion string `json:"chartVersion"`
}

// DiscoveredServiceInfo is one discovered service from chart templates.
type DiscoveredServiceInfo struct {
	Name          string `json:"name"`
	Label         string `json:"label"`
	Kind          string `json:"kind"`
	AutoExcluded  bool   `json:"autoExcluded"`
	AutoExclusionReason string `json:"autoExclusionReason,omitempty"`
	Criticality   string `json:"criticality"`
}

// DiscoverResponse is the response for service discovery.
type DiscoverResponse struct {
	Services []DiscoveredServiceInfo `json:"services"`
	Error    string                  `json:"error,omitempty"`
}

var autoExcludeNames = map[string]string{
	"prometheus":   "observability tool",
	"grafana":      "observability tool",
	"alertmanager": "observability tool",
	"loki":         "observability tool",
	"jaeger":       "observability tool",
	"tempo":        "observability tool",
}

var highCriticalitySuffixes = []string{"-db", "-database", "-postgres", "-mysql", "-mongo"}

// DiscoverServices runs `helm show all <repo>/<chart>@<version>`,
// parses Deployment/StatefulSet templates, and returns discovered services.
func (h *ContributionHandler) DiscoverServices() gin.HandlerFunc {
	return func(c *gin.Context) {
		var req DiscoverRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, DiscoverResponse{Error: "invalid request body"})
			return
		}

		if req.RepoURL == "" || req.ChartName == "" || req.ChartVersion == "" {
			c.JSON(http.StatusBadRequest, DiscoverResponse{Error: "repoURL, chartName, and chartVersion are required"})
			return
		}

		// Add the helm repo temporarily
		repoAlias := sanitizeRepoAlias(req.RepoURL)
		addCmd := exec.Command("helm", "repo", "add", repoAlias, req.RepoURL)
		if out, err := addCmd.CombinedOutput(); err != nil {
			log.WithError(err).WithField("output", string(out)).Warn("helm repo add failed")
			// Continue — repo may already be added
		}

		// Pull and show templates
		showCmd := exec.Command("helm", "show", "all",
			fmt.Sprintf("%s/%s", repoAlias, req.ChartName),
			"--version", req.ChartVersion)
		out, err := showCmd.Output()
		if err != nil {
			log.WithError(err).Error("helm show all failed")
			c.JSON(http.StatusInternalServerError, DiscoverResponse{
				Error: fmt.Sprintf("helm show all failed: %v", err),
			})
			return
		}

		services, parseErr := parseHelmTemplates(string(out))
		if parseErr != nil {
			c.JSON(http.StatusInternalServerError, DiscoverResponse{
				Error: fmt.Sprintf("failed to parse chart templates: %v", parseErr),
			})
			return
		}

		c.JSON(http.StatusOK, DiscoverResponse{Services: services})
	}
}

// parseHelmTemplates parses YAML output from helm show all and extracts Deployment/StatefulSet entries.
func parseHelmTemplates(helmOutput string) ([]DiscoveredServiceInfo, error) {
	var services []DiscoveredServiceInfo

	// Split multi-document YAML
	docs := strings.Split(helmOutput, "\n---")
	for _, doc := range docs {
		doc = strings.TrimSpace(doc)
		if doc == "" {
			continue
		}

		var obj map[interface{}]interface{}
		if err := yaml.Unmarshal([]byte(doc), &obj); err != nil {
			continue
		}

		kind, ok := obj["kind"].(string)
		if !ok {
			continue
		}
		lowerKind := strings.ToLower(kind)
		if lowerKind != "deployment" && lowerKind != "statefulset" && lowerKind != "daemonset" {
			continue
		}

		metadata, _ := obj["metadata"].(map[interface{}]interface{})
		if metadata == nil {
			continue
		}
		name, _ := metadata["name"].(string)
		if name == "" {
			continue
		}

		// Extract first label from spec.selector.matchLabels
		label := extractLabel(obj, name)
		info := DiscoveredServiceInfo{
			Name:        name,
			Label:       label,
			Kind:        lowerKind,
			Criticality: "medium",
		}

		// Auto-exclude logic
		if reason, excluded := autoExcludeNames[name]; excluded {
			info.AutoExcluded = true
			info.AutoExclusionReason = reason
		}
		// High criticality for *-db patterns
		for _, suffix := range highCriticalitySuffixes {
			if strings.HasSuffix(name, suffix) {
				info.Criticality = "high"
				break
			}
		}

		services = append(services, info)
	}

	return services, nil
}

func extractLabel(obj map[interface{}]interface{}, fallbackName string) string {
	spec, _ := obj["spec"].(map[interface{}]interface{})
	if spec == nil {
		return fmt.Sprintf("name=%s", fallbackName)
	}
	selector, _ := spec["selector"].(map[interface{}]interface{})
	if selector == nil {
		return fmt.Sprintf("name=%s", fallbackName)
	}
	matchLabels, _ := selector["matchLabels"].(map[interface{}]interface{})
	for k, v := range matchLabels {
		return fmt.Sprintf("%v=%v", k, v)
	}
	return fmt.Sprintf("name=%s", fallbackName)
}

func sanitizeRepoAlias(repoURL string) string {
	var result strings.Builder
	for _, ch := range repoURL {
		if unicode.IsLetter(ch) || unicode.IsDigit(ch) {
			result.WriteRune(ch)
		} else {
			result.WriteRune('-')
		}
	}
	s := result.String()
	if len(s) > 30 {
		s = s[:30]
	}
	return s
}
```

### Task 2: Wire Routes into Server's Gin Router

Find the existing Gin router setup (e.g., in `api/` or `main.go`) and add the contribution handler:

```go
// In the function that builds the Gin router:
import "github.com/litmuschaos/litmus/chaoscenter/graphql/server/pkg/catalog"

// After creating the catalogService:
catalogSvc, _ := catalog.NewService()
contributionHandler := catalog.NewContributionHandler(catalogSvc)
contributionHandler.RegisterRoutes(apiGroup)  // where apiGroup is the Gin group for /api/*
```

**Find the exact location:**
```bash
grep -rn "router.Group\|r.Group\|gin.New" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/api/ \
  --include="*.go" | head -10
```

### Task 3: Update Frontend `handleDiscover` to Call Real Backend

**File to Modify:** `AgentCert/chaoscenter/web/src/views/AppsOnboarding/AppsOnboarding.tsx`

Replace the stub in `handleDiscover`:

```typescript
// Replace the stub comment with:
const response = await fetch('/api/catalog/discover-services', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${token}` },
  body: JSON.stringify({
    repoURL: data.chartRepoURL,
    chartName: data.chartName,
    chartVersion: data.chartVersion,
  }),
});
const result = await response.json();
if (!response.ok) {
  showError(result.error || 'Service discovery failed');
  return;
}
const processedServices = result.services.map((svc: any) => ({
  name: svc.name,
  label: svc.label,
  kind: svc.kind,
  included: !svc.autoExcluded,
  criticality: svc.criticality as DiscoveredService['criticality'],
  autoExcluded: svc.autoExcluded,
  autoExclusionReason: svc.autoExclusionReason,
}));
patch({ discoveredServices: processedServices });
setStep(3);
```

Also update Step 1 to call `validate-name` on blur of the name field:

```typescript
// In Step1Identity.tsx, add after name field changes:
const checkNameAvailability = async (name: string): Promise<void> => {
  if (!namePattern.test(name)) return;
  const response = await fetch('/api/catalog/validate-name', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name }),
  });
  const result = await response.json();
  if (!result.available) {
    setFieldError('name', result.error);
  }
};
```

---

## Files to Create

```
AgentCert/chaoscenter/graphql/server/pkg/catalog/
└── contribution_handler.go    (new)
```

**Files to Modify:**
- Server Gin router setup file (location TBD from `grep`) — add `contributionHandler.RegisterRoutes`
- `web/src/views/AppsOnboarding/AppsOnboarding.tsx` — replace stub with real fetch
- `web/src/views/AppsOnboarding/steps/Step1Identity.tsx` — add name availability check

---

## Verification Criteria

### Must Pass
- [ ] `go build ./pkg/catalog/...` succeeds
- [ ] `POST /api/catalog/validate-name` with `{"name":"sock-shop"}` returns `{"available":false,"error":"...already exists..."}`
- [ ] `POST /api/catalog/validate-name` with `{"name":"new-app-name"}` returns `{"available":true}`
- [ ] `POST /api/catalog/validate-name` with `{"name":"Bad Name!"}` returns validation error
- [ ] `POST /api/catalog/discover-services` with a valid public chart returns services list
- [ ] Frontend wizard: Step 2 "Discover Services" calls real endpoint and populates Step 3 table

### Should Pass
- [ ] Discovery gracefully handles network timeout to chart repo
- [ ] Step 1 name field shows availability error inline (no form submit needed)

---

## Testing Commands

```bash
# Build
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server
go build ./...

# Test validate-name endpoint (requires server running)
curl -s -X POST http://localhost:8080/api/catalog/validate-name \
  -H "Content-Type: application/json" \
  -d '{"name":"sock-shop"}' | python3 -m json.tool

# Test validate-name with bad name
curl -s -X POST http://localhost:8080/api/catalog/validate-name \
  -H "Content-Type: application/json" \
  -d '{"name":"Bad Name!"}' | python3 -m json.tool

# Test discover (uses a real public chart)
curl -s -X POST http://localhost:8080/api/catalog/discover-services \
  -H "Content-Type: application/json" \
  -d '{"repoURL":"https://charts.bitnami.com/bitnami","chartName":"nginx","chartVersion":"18.1.7"}' | python3 -m json.tool
```

---

## Common Issues and Solutions

### Issue: `helm` not in PATH inside the container
**Symptom:** `exec: "helm": executable file not found in $PATH`  
**Solution:** The GraphQL server Dockerfile must include helm. Check the existing Dockerfile:
```bash
grep -n "helm" /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/Dockerfile 2>/dev/null | head -5
```
If helm is not in the Dockerfile, add it. Alternatively, fall back gracefully: if helm is not available, return a response telling the user to add services manually.

### Issue: Gin router group not found
**Symptom:** Build error on `contributionHandler.RegisterRoutes(apiGroup)`  
**Solution:** Find the correct variable name for the API router group from the existing routes file.

---

## Success Criteria

Stage 11 is complete when:
1. Both contribution endpoints return correct responses
2. Frontend wizard Step 2 calls real endpoint and populates Step 3
3. Step 1 name field checks availability against live catalog
4. `go build` passes

## Next Stage

Proceed to **Stage 12: Install Mechanics**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
