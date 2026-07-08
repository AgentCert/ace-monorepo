# Stage 04: ExperimentDefinition Go Types + MongoDB Collection

**Phase:** 1 — Experiment Definition  
**Status:** Not Started  
**Estimated Effort:** 1 day  
**Date Added:** 2026-07-07  
**Depends On:** Stage 03 (fault catalog service available for faultRef validation)

---

## Objectives

1. Define `ExperimentDefinitionDoc` and all sub-structs for MongoDB persistence in
   `pkg/experiment_definition/model.go`.
2. Implement a MongoDB repository in `pkg/experiment_definition/repository.go` with CRUD
   operations on the `experiment_definitions` collection.
3. Implement service-layer business logic in `pkg/experiment_definition/service.go`, including
   faultRef validation against the fault catalog.
4. Create the `experiment_definitions` MongoDB index: `{name: 1, projectID: 1}` unique.
5. Unit tests for the service layer pass against a mock repository.

---

## Current State Analysis

### What Exists
- `pkg/chaos_experiment/model/` — MongoDB document structs for the existing (Argo-manifest-based)
  experiment. Pattern to follow: `ChaosExperimentRequest` struct with BSON tags.
- `pkg/chaos_experiment/types.go` — database collection name constants.
- MongoDB infrastructure in `pkg/database/mongodb/` (connection management, collection helpers).
- Existing collection names: `chaosExperiments`, `chaosExperimentRuns` — do not reuse.

### What Is Needed
- `pkg/experiment_definition/model.go` — new Go structs
- `pkg/experiment_definition/repository.go` — MongoDB CRUD
- `pkg/experiment_definition/service.go` — business logic
- Collection constant: `ExperimentDefinitionsCollection = "experiment_definitions"`

---

## Pre-Stage Verification

```bash
# 1. MongoDB reachable
mongosh --eval "db.adminCommand({ping: 1})" 2>/dev/null || \
  kubectl exec -n litmus deploy/mongo -- mongosh --eval "db.adminCommand({ping: 1})"

# 2. Existing collection names (confirm no conflict)
mongosh litmus --eval "db.getCollectionNames()" 2>/dev/null | grep -i experiment

# 3. Confirm package pattern
ls /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/chaos_experiment/model/

# 4. Confirm database package
ls /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/database/
```

---

## Implementation Tasks

### Task 1: Create `pkg/experiment_definition/model.go`

```go
package experiment_definition

import (
    "time"
    "go.mongodb.org/mongo-driver/bson/primitive"
)

// CollectionName is the MongoDB collection for experiment definitions.
const CollectionName = "experiment_definitions"

// ExperimentStepType is the type of a single step in the experiment sequence.
type ExperimentStepType string

const (
    StepTypeObserve      ExperimentStepType = "observe"
    StepTypeFault        ExperimentStepType = "fault"
    StepTypeVerify       ExperimentStepType = "verify"
    StepTypeWait         ExperimentStepType = "wait"
    StepTypeParallelFault ExperimentStepType = "parallel-fault"
)

// ModelSelectionMode controls which LLM model is used for a run.
type ModelSelectionMode string

const (
    ModelSelectionAgentDefault   ModelSelectionMode = "agent-default"
    ModelSelectionFixed          ModelSelectionMode = "fixed"
    ModelSelectionUserChoosesAtRun ModelSelectionMode = "user-chooses-at-run"
)

// StepTarget identifies the microservice within the app to target.
type StepTarget struct {
    Microservice string `bson:"microservice" json:"microservice"`
    // ExplicitPodName is set when targetSpec.resolutionMode = explicit-pod
    ExplicitPodName string `bson:"explicitPodName,omitempty" json:"explicitPodName,omitempty"`
}

// StepProbe is the health probe for a verify step.
type StepProbe struct {
    URL            string `bson:"url" json:"url"`
    ExpectedStatus int    `bson:"expectedStatus" json:"expectedStatus"`
    TimeoutSecs    int    `bson:"timeoutSecs,omitempty" json:"timeoutSecs,omitempty"`
    Retries        int    `bson:"retries,omitempty" json:"retries,omitempty"`
}

// GroundTruthOverride allows per-step override of the fault's default SLAs.
type GroundTruthOverride struct {
    DetectWithinSecs   *int `bson:"detectWithinSecs,omitempty" json:"detectWithinSecs,omitempty"`
    MitigateWithinSecs *int `bson:"mitigateWithinSecs,omitempty" json:"mitigateWithinSecs,omitempty"`
}

// ParallelFaultEntry is one fault within a parallel-fault step.
type ParallelFaultEntry struct {
    FaultRef   string            `bson:"faultRef" json:"faultRef"`
    Target     StepTarget        `bson:"target" json:"target"`
    Params     map[string]string `bson:"params,omitempty" json:"params,omitempty"`
}

// ExperimentStep is one step in the experiment step sequence.
type ExperimentStep struct {
    Name                string              `bson:"name" json:"name"`
    Type                ExperimentStepType  `bson:"type" json:"type"`
    Description         string              `bson:"description,omitempty" json:"description,omitempty"`

    // For observe and wait steps
    Duration string `bson:"duration,omitempty" json:"duration,omitempty"` // e.g. "30s"

    // For fault steps
    FaultRef           string             `bson:"faultRef,omitempty" json:"faultRef,omitempty"`
    Target             *StepTarget        `bson:"target,omitempty" json:"target,omitempty"`
    Params             map[string]string  `bson:"params,omitempty" json:"params,omitempty"`
    DependsOn          string             `bson:"dependsOn,omitempty" json:"dependsOn,omitempty"`
    GroundTruthOverride *GroundTruthOverride `bson:"groundTruthOverride,omitempty" json:"groundTruthOverride,omitempty"`

    // For verify steps
    Probe *StepProbe `bson:"probe,omitempty" json:"probe,omitempty"`

    // For parallel-fault steps
    Faults []ParallelFaultEntry `bson:"faults,omitempty" json:"faults,omitempty"`
}

// PerStepCriteria holds success criteria for a named fault step.
type PerStepCriteria struct {
    StepName           string `bson:"stepName" json:"stepName"`
    DetectWithinSecs   int    `bson:"detectWithinSecs" json:"detectWithinSecs"`
    MitigateWithinSecs int    `bson:"mitigateWithinSecs" json:"mitigateWithinSecs"`
}

// OverallCriteria holds experiment-level success thresholds.
type OverallCriteria struct {
    ToolCallEfficiencyMin float64 `bson:"toolCallEfficiencyMin" json:"toolCallEfficiencyMin"`
    FalsePositiveRateMax  float64 `bson:"falsePositiveRateMax" json:"falsePositiveRateMax"`
    RootCauseAccuracyMin  float64 `bson:"rootCauseAccuracyMin" json:"rootCauseAccuracyMin"`
}

// SuccessCriteria is the success criteria block.
type SuccessCriteria struct {
    PerStep []PerStepCriteria `bson:"perStep,omitempty" json:"perStep,omitempty"`
    Overall *OverallCriteria  `bson:"overall,omitempty" json:"overall,omitempty"`
}

// AgentConstraints declares which agents are compatible with this experiment.
type AgentConstraints struct {
    RequiredCapabilities []string `bson:"requiredCapabilities,omitempty" json:"requiredCapabilities,omitempty"`
    SupportedAgents      []string `bson:"supportedAgents,omitempty" json:"supportedAgents,omitempty"`
    BlockedAgents        []string `bson:"blockedAgents,omitempty" json:"blockedAgents,omitempty"`
}

// ModelSelection controls LLM model behavior for this experiment.
type ModelSelection struct {
    Mode       ModelSelectionMode `bson:"mode" json:"mode"`
    FixedModel string             `bson:"fixedModel,omitempty" json:"fixedModel,omitempty"`
}

// TargetAppSpec identifies the app this experiment runs against.
type TargetAppSpec struct {
    Name         string            `bson:"name" json:"name"`
    Version      string            `bson:"version" json:"version"` // SemVer range, e.g. ">=1.0.0"
    InstallParams map[string]string `bson:"installParams,omitempty" json:"installParams,omitempty"`
}

// ExperimentDefinitionDoc is the MongoDB document for an experiment definition.
type ExperimentDefinitionDoc struct {
    ID          primitive.ObjectID `bson:"_id,omitempty"`
    Name        string             `bson:"name"`
    ProjectID   string             `bson:"projectID"`
    DisplayName string             `bson:"displayName,omitempty"`
    Version     string             `bson:"version"`
    Hypothesis  string             `bson:"hypothesis,omitempty"`
    Tags        []string           `bson:"tags,omitempty"`
    Author      struct {
        Name  string `bson:"name"`
        Email string `bson:"email"`
    } `bson:"author,omitempty"`

    TargetApp        TargetAppSpec    `bson:"targetApp"`
    AgentConstraints AgentConstraints `bson:"agentConstraints,omitempty"`
    ModelSelection   ModelSelection   `bson:"modelSelection"`
    Steps            []ExperimentStep `bson:"steps"`
    SuccessCriteria  SuccessCriteria  `bson:"successCriteria,omitempty"`
    EvaluationMetrics []string        `bson:"evaluationMetrics,omitempty"`

    // Lifecycle
    Status    string    `bson:"status"` // DRAFT | READY
    CreatedAt time.Time `bson:"createdAt"`
    UpdatedAt time.Time `bson:"updatedAt"`
    CreatedBy string    `bson:"createdBy"`
}
```

### Task 2: Create `pkg/experiment_definition/repository.go`

```go
package experiment_definition

import (
    "context"
    "time"

    "go.mongodb.org/mongo-driver/bson"
    "go.mongodb.org/mongo-driver/bson/primitive"
    "go.mongodb.org/mongo-driver/mongo"
    "go.mongodb.org/mongo-driver/mongo/options"
)

// Repository defines CRUD operations for experiment definitions.
type Repository interface {
    Create(ctx context.Context, doc *ExperimentDefinitionDoc) error
    GetByName(ctx context.Context, projectID, name string) (*ExperimentDefinitionDoc, error)
    List(ctx context.Context, projectID string, filter ListFilter) ([]*ExperimentDefinitionDoc, error)
    Update(ctx context.Context, projectID, name string, update *ExperimentDefinitionDoc) error
    Delete(ctx context.Context, projectID, name string) error
}

// ListFilter allows filtering the List query.
type ListFilter struct {
    Tags      []string
    TargetApp string
    Status    string
}

type mongoRepository struct {
    collection *mongo.Collection
}

// NewRepository returns a new MongoDB-backed repository.
// Callers must pass the application's MongoDB database handle.
func NewRepository(db *mongo.Database) Repository {
    coll := db.Collection(CollectionName)

    // Ensure unique index on (name, projectID)
    _, _ = coll.Indexes().CreateOne(context.Background(), mongo.IndexModel{
        Keys: bson.D{
            {Key: "name", Value: 1},
            {Key: "projectID", Value: 1},
        },
        Options: options.Index().SetUnique(true).SetName("name_projectID_unique"),
    })

    return &mongoRepository{collection: coll}
}

func (r *mongoRepository) Create(ctx context.Context, doc *ExperimentDefinitionDoc) error {
    doc.ID = primitive.NewObjectID()
    doc.CreatedAt = time.Now()
    doc.UpdatedAt = time.Now()
    if doc.Version == "" {
        doc.Version = "1.0.0"
    }
    if doc.Status == "" {
        doc.Status = "DRAFT"
    }
    _, err := r.collection.InsertOne(ctx, doc)
    return err
}

func (r *mongoRepository) GetByName(ctx context.Context, projectID, name string) (*ExperimentDefinitionDoc, error) {
    var doc ExperimentDefinitionDoc
    err := r.collection.FindOne(ctx, bson.M{
        "name":      name,
        "projectID": projectID,
    }).Decode(&doc)
    if err == mongo.ErrNoDocuments {
        return nil, ErrExperimentNotFound{Name: name}
    }
    return &doc, err
}

func (r *mongoRepository) List(ctx context.Context, projectID string, f ListFilter) ([]*ExperimentDefinitionDoc, error) {
    filter := bson.M{"projectID": projectID}
    if f.TargetApp != "" {
        filter["targetApp.name"] = f.TargetApp
    }
    if f.Status != "" {
        filter["status"] = f.Status
    }

    cursor, err := r.collection.Find(ctx, filter,
        options.Find().SetSort(bson.D{{Key: "createdAt", Value: -1}}))
    if err != nil {
        return nil, err
    }
    defer cursor.Close(ctx)

    var docs []*ExperimentDefinitionDoc
    if err := cursor.All(ctx, &docs); err != nil {
        return nil, err
    }
    return docs, nil
}

func (r *mongoRepository) Update(ctx context.Context, projectID, name string, update *ExperimentDefinitionDoc) error {
    update.UpdatedAt = time.Now()
    _, err := r.collection.ReplaceOne(ctx,
        bson.M{"name": name, "projectID": projectID},
        update,
    )
    return err
}

func (r *mongoRepository) Delete(ctx context.Context, projectID, name string) error {
    _, err := r.collection.DeleteOne(ctx, bson.M{"name": name, "projectID": projectID})
    return err
}
```

### Task 3: Create `pkg/experiment_definition/service.go`

```go
package experiment_definition

import (
    "context"
    "fmt"
    "strings"

    "github.com/litmuschaos/litmus/chaoscenter/graphql/server/pkg/fault_catalog"
)

// Service defines experiment definition business logic.
type Service interface {
    Create(ctx context.Context, projectID string, doc *ExperimentDefinitionDoc) error
    GetByName(ctx context.Context, projectID, name string) (*ExperimentDefinitionDoc, error)
    List(ctx context.Context, projectID string, filter ListFilter) ([]*ExperimentDefinitionDoc, error)
    Update(ctx context.Context, projectID, name string, doc *ExperimentDefinitionDoc) error
    Delete(ctx context.Context, projectID, name string) error
}

type experimentService struct {
    repo         Repository
    faultCatalog fault_catalog.Service
}

// NewService returns a new experiment definition service.
func NewService(repo Repository, faultCatalog fault_catalog.Service) Service {
    return &experimentService{repo: repo, faultCatalog: faultCatalog}
}

func (s *experimentService) Create(ctx context.Context, projectID string, doc *ExperimentDefinitionDoc) error {
    doc.ProjectID = projectID
    if err := s.validateFaultRefs(doc); err != nil {
        return err
    }
    return s.repo.Create(ctx, doc)
}

func (s *experimentService) GetByName(ctx context.Context, projectID, name string) (*ExperimentDefinitionDoc, error) {
    return s.repo.GetByName(ctx, projectID, name)
}

func (s *experimentService) List(ctx context.Context, projectID string, filter ListFilter) ([]*ExperimentDefinitionDoc, error) {
    return s.repo.List(ctx, projectID, filter)
}

func (s *experimentService) Update(ctx context.Context, projectID, name string, doc *ExperimentDefinitionDoc) error {
    doc.ProjectID = projectID
    if err := s.validateFaultRefs(doc); err != nil {
        return err
    }
    return s.repo.Update(ctx, projectID, name, doc)
}

func (s *experimentService) Delete(ctx context.Context, projectID, name string) error {
    return s.repo.Delete(ctx, projectID, name)
}

// validateFaultRefs checks that every faultRef in the step list resolves in the fault catalog.
func (s *experimentService) validateFaultRefs(doc *ExperimentDefinitionDoc) error {
    var invalid []string
    for _, step := range doc.Steps {
        if step.Type == StepTypeFault && step.FaultRef != "" {
            if _, err := s.faultCatalog.GetFault(step.FaultRef); err != nil {
                invalid = append(invalid, step.FaultRef)
            }
        }
        if step.Type == StepTypeParallelFault {
            for _, pf := range step.Faults {
                if _, err := s.faultCatalog.GetFault(pf.FaultRef); err != nil {
                    invalid = append(invalid, pf.FaultRef)
                }
            }
        }
    }
    if len(invalid) > 0 {
        return fmt.Errorf("experiment definition references unknown fault(s): %s",
            strings.Join(invalid, ", "))
    }
    return nil
}
```

### Task 4: Create `pkg/experiment_definition/errors.go`

```go
package experiment_definition

import "fmt"

// ErrExperimentNotFound is returned when a definition name does not exist.
type ErrExperimentNotFound struct {
    Name string
}

func (e ErrExperimentNotFound) Error() string {
    return fmt.Sprintf("experiment definition not found: %q", e.Name)
}

// ErrDuplicateName is returned when creating a definition with a name that already exists.
type ErrDuplicateName struct {
    Name string
}

func (e ErrDuplicateName) Error() string {
    return fmt.Sprintf("experiment definition already exists: %q", e.Name)
}
```

---

## Verification Criteria

### Must Pass

1. Package compiles:
   ```bash
   go build ./pkg/experiment_definition/...
   ```

2. Unit tests pass (write tests for `validateFaultRefs` — should reject unknown faultRef):
   ```bash
   go test ./pkg/experiment_definition/... -v
   ```

3. MongoDB index created — verify with:
   ```bash
   mongosh litmus --eval "db.experiment_definitions.getIndexes()"
   # Expected: index on {name:1, projectID:1} with unique:true
   ```

4. Create + GetByName roundtrip succeeds in an integration test.

### Should Pass

5. Creating two definitions with the same name in the same project returns a duplicate key error.

6. `validateFaultRefs` returns an error when a step references `faultRef: "nonexistent-fault"`.

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server

# Unit tests
go test ./pkg/experiment_definition/... -v -count=1

# Race detector
go test -race ./pkg/experiment_definition/...

# Integration (requires MongoDB)
go test ./pkg/experiment_definition/... -tags=integration -v
```

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `mongo: no documents in result` | `GetByName` filter uses wrong field name | Check BSON tag: `bson:"name"` not `bson:"Name"` |
| Duplicate key error on every insert | Index exists from a prior test and docs weren't cleaned up | Use `db.experiment_definitions.drop()` in test cleanup |
| `fault_catalog import cycle` | `experiment_definition` imports `fault_catalog` which imports `experiment_definition` | Keep the dependency one-way: `experiment_definition` → `fault_catalog`; never the reverse |
| `time.Time` marshals incorrectly in BSON | Missing bson struct tag | Use `bson:"createdAt"` not `json` tags for MongoDB fields |

---

## Rollback Procedure

```bash
# Remove the new package
rm -rf /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/experiment_definition/

# Drop the MongoDB collection (if created)
mongosh litmus --eval "db.experiment_definitions.drop()"
```

---

## Success Criteria

Stage 04 is complete when:
- `go build ./pkg/experiment_definition/...` succeeds
- Unit tests pass including `validateFaultRefs` negative case
- MongoDB `experiment_definitions` collection has unique index on `(name, projectID)`

**Next Stage:** Stage 05 — Experiment Definition GraphQL Schema + CRUD
