# Stage 2: Capabilities Vocabulary

**Phase:** 1 — Spec-Aligned Backend Model  
**Dependencies:** Stage 1 complete  
**Risk Level:** Low

---

## Objectives

1. Create `catalog/capabilities/` with 6 domain YAML files from spec §10
2. Create `catalog/domains.yaml` listing all domains
3. Add a Go loader that reads these files at server startup into an in-memory capability map
4. Update the validator to check declared capabilities against the loaded vocabulary
5. Wire the `getAgentCapabilitiesTaxonomy` resolver to return capabilities from YAML

---

## Current State Analysis

### What We Have
- `pkg/agent_registry/validator.go` — `loadCapabilitiesTaxonomy()` function with a hardcoded capability map (chaos-fault names, not spec capabilities)
- `pkg/agent_registry/constants.go` — `AgentRegistryCollection`, regex constants
- `catalog/` — has `apps/`, `CATALOG.md`, `domains.yaml` (but `capabilities/` doesn't exist yet)

### What We Need
- `catalog/capabilities/common.yaml`, `cloud-native.yaml`, `telecom.yaml`, `health-it.yaml`, `finops.yaml`, `itops.yaml`
- `catalog/domains.yaml` updated to include capability domains
- Go code to parse and load these YAML files
- `GetAgentCapabilitiesTaxonomy` resolver returns domain-grouped capability list

---

## Pre-Stage Verification

```bash
# Confirm capabilities directory doesn't exist
ls catalog/capabilities/ 2>/dev/null || echo "Does not exist — correct"

# Check the current hardcoded taxonomy
grep -A 20 "loadCapabilitiesTaxonomy" \
  AgentCert/chaoscenter/graphql/server/pkg/agent_registry/validator.go
```

---

## Implementation Tasks

### Task 1: Create Capability YAML Files

**Objective:** Populate `catalog/capabilities/` with the exact vocabulary from spec §10.

**Files to Create:**
- `catalog/capabilities/common.yaml`
- `catalog/capabilities/cloud-native.yaml`
- `catalog/capabilities/telecom.yaml`
- `catalog/capabilities/health-it.yaml`
- `catalog/capabilities/finops.yaml`
- `catalog/capabilities/itops.yaml`

Use the YAML content **verbatim from spec §10.2–§10.7**. The structure is:

```yaml
domain: common
displayName: Common
description: "Capabilities applicable across all domains"

capabilities:
  observe:
    - key: http-probe
      displayName: HTTP Probe
      description: "Issue HTTP requests to check endpoint health and response content"
      relatedFaults: [pod-network-loss, pod-network-latency, link-down-simulation]
    # ... etc
  act:
    - key: webhook-notify
      displayName: Webhook Notify
      description: "Send structured notifications via webhook (Slack, PagerDuty, Teams, etc.)"
      relatedFaults: []
```

Create all 6 files using the capability lists from spec §10.2–§10.7 exactly as written.

**Verification:**
```bash
ls catalog/capabilities/
# Should list: common.yaml cloud-native.yaml telecom.yaml health-it.yaml finops.yaml itops.yaml
```

---

### Task 2: Update `catalog/domains.yaml`

**File to Modify:** `catalog/domains.yaml`

**Change:** Add `capabilityFile` pointer for each domain:

```yaml
domains:
  - id: cloud-native
    displayName: Cloud Native
    capabilityFile: capabilities/cloud-native.yaml

  - id: telecom
    displayName: Telecom
    capabilityFile: capabilities/telecom.yaml

  - id: health-it
    displayName: Health IT
    capabilityFile: capabilities/health-it.yaml

  - id: finops
    displayName: FinOps
    capabilityFile: capabilities/finops.yaml

  - id: itops
    displayName: IT Operations
    capabilityFile: capabilities/itops.yaml

  - id: common
    displayName: Common
    capabilityFile: capabilities/common.yaml
```

---

### Task 3: Go Capability Loader

**Objective:** Load YAML files at startup; expose as an in-memory vocabulary map.

**Files to Create:**
- `AgentCert/chaoscenter/graphql/server/pkg/agent_registry/capabilities_loader.go`

```go
package agent_registry

import (
    "fmt"
    "os"
    "path/filepath"

    "gopkg.in/yaml.v3"
)

// CapabilityVocab holds all known capabilities keyed by capability key.
type CapabilityVocab struct {
    byKey  map[string]CapabilityEntry
    byDomain map[string][]CapabilityEntry
}

type CapabilityEntry struct {
    Key          string
    DisplayName  string
    Description  string
    Domain       string
    Category     string   // "observe" | "act"
    RelatedFaults []string
}

type capabilityDomainFile struct {
    Domain      string `yaml:"domain"`
    DisplayName string `yaml:"displayName"`
    Capabilities struct {
        Observe []capabilityYAML `yaml:"observe"`
        Act     []capabilityYAML `yaml:"act"`
    } `yaml:"capabilities"`
}

type capabilityYAML struct {
    Key           string   `yaml:"key"`
    DisplayName   string   `yaml:"displayName"`
    Description   string   `yaml:"description"`
    RelatedFaults []string `yaml:"relatedFaults"`
}

// LoadCapabilitiesFromDir reads all *.yaml files in the given directory
// and builds a CapabilityVocab. Called once at server startup.
func LoadCapabilitiesFromDir(dir string) (*CapabilityVocab, error) {
    vocab := &CapabilityVocab{
        byKey:    make(map[string]CapabilityEntry),
        byDomain: make(map[string][]CapabilityEntry),
    }

    entries, err := os.ReadDir(dir)
    if err != nil {
        return nil, fmt.Errorf("reading capabilities dir %s: %w", dir, err)
    }

    for _, entry := range entries {
        if entry.IsDir() || filepath.Ext(entry.Name()) != ".yaml" {
            continue
        }
        data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
        if err != nil {
            return nil, fmt.Errorf("reading %s: %w", entry.Name(), err)
        }

        var df capabilityDomainFile
        if err := yaml.Unmarshal(data, &df); err != nil {
            return nil, fmt.Errorf("parsing %s: %w", entry.Name(), err)
        }

        for _, cap := range df.Capabilities.Observe {
            e := CapabilityEntry{Key: cap.Key, DisplayName: cap.DisplayName,
                Description: cap.Description, Domain: df.Domain,
                Category: "observe", RelatedFaults: cap.RelatedFaults}
            vocab.byKey[cap.Key] = e
            vocab.byDomain[df.Domain] = append(vocab.byDomain[df.Domain], e)
        }
        for _, cap := range df.Capabilities.Act {
            e := CapabilityEntry{Key: cap.Key, DisplayName: cap.DisplayName,
                Description: cap.Description, Domain: df.Domain,
                Category: "act", RelatedFaults: cap.RelatedFaults}
            vocab.byKey[cap.Key] = e
            vocab.byDomain[df.Domain] = append(vocab.byDomain[df.Domain], e)
        }
    }
    return vocab, nil
}

// IsValid returns true if the key exists in the loaded vocabulary.
func (v *CapabilityVocab) IsValid(key string) bool {
    _, ok := v.byKey[key]
    return ok
}

// AllEntries returns all capability entries for use in the taxonomy query.
func (v *CapabilityVocab) AllEntries() []CapabilityEntry {
    entries := make([]CapabilityEntry, 0, len(v.byKey))
    for _, e := range v.byKey {
        entries = append(entries, e)
    }
    return entries
}
```

**How to initialise:** In `server.go` (or wherever the service is constructed), load the vocab:

```go
// Find the catalog/capabilities dir relative to executable
capDir := os.Getenv("CATALOG_CAPABILITIES_DIR")
if capDir == "" {
    capDir = "../../../../catalog/capabilities"  // dev default
}
vocab, err := agent_registry.LoadCapabilitiesFromDir(capDir)
if err != nil {
    log.Fatalf("failed to load capabilities vocabulary: %v", err)
}
```

Pass `vocab` into the validator via a new constructor parameter or a setter.

---

### Task 4: Update Validator to Use Loaded Vocabulary

**File to Modify:** `pkg/agent_registry/validator.go`

**Change:** Replace the hardcoded `loadCapabilitiesTaxonomy()` with `vocab.IsValid(key)`:

```go
type validatorImpl struct {
    operator    Operator
    vocab       *CapabilityVocab   // replaces capabilitiesTaxonomy map[string]bool
    nameRegex   *regexp.Regexp
    semverRegex *regexp.Regexp
}

func NewValidator(operator Operator, vocab *CapabilityVocab) Validator {
    return &validatorImpl{
        operator:    operator,
        vocab:       vocab,
        nameRegex:   regexp.MustCompile(AgentNameRegex),
        semverRegex: regexp.MustCompile(SemverRegex),
    }
}
```

In `ValidateCapabilities`:

```go
func (v *validatorImpl) ValidateCapabilities(ctx context.Context, caps []string) error {
    for _, key := range caps {
        if !v.vocab.IsValid(key) {
            return NewValidationError("capabilities",
                fmt.Sprintf("unknown capability key '%s'", key))
        }
    }
    return nil
}
```

---

### Task 5: Wire `GetAgentCapabilitiesTaxonomy` Resolver

**File to Modify:** `graph/agent_registry.resolvers.go`

The existing resolver calls `r.agentRegistryService.GetAgentCapabilitiesTaxonomy(ctx)`.
Update the service implementation to return entries from `vocab.AllEntries()` instead of a hardcoded list.

In `service.go` `GetAgentCapabilitiesTaxonomy`:

```go
func (s *serviceImpl) GetAgentCapabilitiesTaxonomy(ctx context.Context) ([]*CapabilityDefinition, error) {
    entries := s.vocab.AllEntries()
    result := make([]*CapabilityDefinition, 0, len(entries))
    for _, e := range entries {
        result = append(result, &CapabilityDefinition{
            ID:          e.Key,
            Name:        e.DisplayName,
            Description: e.Description,
            Category:    e.Domain + "/" + e.Category,
        })
    }
    return result, nil
}
```

Also add `vocab *CapabilityVocab` to `serviceImpl` struct and pass it via `NewService`.

---

## Files to Create (Summary)

```
catalog/capabilities/
├── common.yaml
├── cloud-native.yaml
├── telecom.yaml
├── health-it.yaml
├── finops.yaml
└── itops.yaml

AgentCert/chaoscenter/graphql/server/pkg/agent_registry/
└── capabilities_loader.go
```

## Files to Modify

- `catalog/domains.yaml` — add `capabilityFile` to each domain
- `pkg/agent_registry/validator.go` — replace hardcoded taxonomy with vocab loader
- `pkg/agent_registry/service.go` — add `vocab` field, update `GetAgentCapabilitiesTaxonomy`
- `AgentCert/chaoscenter/graphql/server/server.go` — load vocab at startup, pass to service

---

## Verification Criteria

### Must Pass
- [ ] All 6 capability YAML files exist and are valid YAML (`python3 -c "import yaml; yaml.safe_load(open('catalog/capabilities/cloud-native.yaml'))"`)
- [ ] `go build ./...` compiles with vocabulary loader
- [ ] Registering an agent with `capabilities: ["prometheus-query"]` succeeds
- [ ] Registering an agent with `capabilities: ["made-up-key"]` fails with validation error
- [ ] `getAgentCapabilitiesTaxonomy` GraphQL query returns at least 30 capabilities

### Should Pass
- [ ] Taxonomy includes entries from all 6 domains
- [ ] Each entry has non-empty `description` and `category`

---

## Testing Commands

```bash
# Validate YAML files
for f in catalog/capabilities/*.yaml; do
  python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "$f: OK"
done

# Go tests
cd AgentCert/chaoscenter/graphql/server
go build ./...
go test ./pkg/agent_registry/...
```

---

## Success Criteria

Stage 2 is complete when:
1. All 6 capability YAML files exist and parse cleanly
2. Backend rejects unknown capability keys at registration time
3. `getAgentCapabilitiesTaxonomy` returns the full vocabulary

## Next Stage

Proceed to: **Stage 3: Model Library Backend**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
