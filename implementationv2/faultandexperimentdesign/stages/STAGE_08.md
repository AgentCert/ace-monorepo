# Stage 08: Extended ExperimentRun Tracking

**Phase:** 2 — Experiment Execution  
**Status:** Not Started  
**Estimated Effort:** 1 day  
**Date Added:** 2026-07-07  
**Depends On:** Stage 04 (ExperimentDefinitionDoc types)

---

## Objectives

1. Define the `AceExperimentRun` MongoDB document struct in a new file
   `pkg/experiment_definition/run_model.go`.
2. Create `graphql/definitions/shared/experiment_run_ext.graphqls` with the `AceExperimentRun`
   type and the `submitRun`, `abortRun`, `getRun`, `listRuns` operations (stubs for Stage 09).
3. Create MongoDB `experiment_runs_ext` collection with appropriate indexes.
4. Implement a minimal `RunRepository` with `Create`, `GetByID`, `UpdateStatus`, `List` methods.
5. Do NOT modify `chaos_experiment_run.graphqls` or any existing run-related code.

---

## Current State Analysis

### What Exists
- `graphql/definitions/shared/chaos_experiment_run.graphqls` — existing `ExperimentRun` type.
  Do NOT touch. New type is `AceExperimentRun`.
- `pkg/chaos_experiment_run/` — existing run tracking for the Argo-manifest-based runs.
  Do NOT modify. New collection `experiment_runs_ext` is completely separate.

### Key Constraint

The run record is **immutable after reaching a terminal state**. Status transitions are written
by the `submitRun` resolver (Stage 09) and by a background status-polling goroutine that watches
the Argo Workflow status. The `UpdateStatus` method appends to a `statusHistory[]` array.

---

## Pre-Stage Verification

```bash
# 1. Existing run collection name (confirm no conflict)
mongosh litmus --eval "db.getCollectionNames()" 2>/dev/null | grep -i run

# 2. chaos_experiment_run.graphqls — check existing ExperimentRun type
grep -n "^type ExperimentRun\|^type AceExperimentRun" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/definitions/shared/*.graphqls

# 3. Stage 04 builds
go build ./pkg/experiment_definition/...
```

---

## Implementation Tasks

### Task 1: Create `pkg/experiment_definition/run_model.go`

```go
package experiment_definition

import (
    "time"
    "go.mongodb.org/mongo-driver/bson/primitive"
)

// RunCollectionName is the MongoDB collection for ACE experiment runs.
const RunCollectionName = "experiment_runs_ext"

// RunStatus represents the lifecycle state of an experiment run.
type RunStatus string

const (
    RunStatusQueued    RunStatus = "QUEUED"
    RunStatusRunning   RunStatus = "RUNNING"
    RunStatusCompleted RunStatus = "COMPLETED"
    RunStatusFailed    RunStatus = "FAILED"
    RunStatusAborted   RunStatus = "ABORTED"
)

// StatusEvent records a single status transition.
type StatusEvent struct {
    Status    RunStatus `bson:"status"`
    Timestamp time.Time `bson:"timestamp"`
    Reason    string    `bson:"reason,omitempty"`
}

// AceExperimentRunDoc is the MongoDB document for an experiment run.
// Documents are immutable after reaching a terminal status (COMPLETED, FAILED, ABORTED).
type AceExperimentRunDoc struct {
    ID       primitive.ObjectID `bson:"_id,omitempty"`
    RunID    string             `bson:"runID"`    // UUID, e.g. "run-abc123"
    ProjectID string            `bson:"projectID"`

    // Definition reference
    DefinitionName    string `bson:"definitionName"`
    DefinitionVersion string `bson:"definitionVersion"`

    // Agent reference
    AgentName    string `bson:"agentName"`
    AgentVersion string `bson:"agentVersion"`

    // Model used (always populated — resolved at run submit time)
    ModelUsed     string `bson:"modelUsed"`     // e.g. "gpt-4o"
    ModelProvider string `bson:"modelProvider"` // e.g. "openai"

    // Execution references
    ArgoWorkflowName string `bson:"argoWorkflowName"`
    LangfuseTraceID  string `bson:"langfuseTraceId,omitempty"`
    CertifierReportID string `bson:"certifierReportId,omitempty"`

    // Status
    Status        RunStatus     `bson:"status"`
    StatusHistory []StatusEvent `bson:"statusHistory"`

    // Timing
    StartedAt   *time.Time `bson:"startedAt,omitempty"`
    CompletedAt *time.Time `bson:"completedAt,omitempty"`
    CreatedAt   time.Time  `bson:"createdAt"`
    CreatedBy   string     `bson:"createdBy"`
}

// IsTerminal returns true if the run has reached a terminal state.
func (r *AceExperimentRunDoc) IsTerminal() bool {
    switch r.Status {
    case RunStatusCompleted, RunStatusFailed, RunStatusAborted:
        return true
    }
    return false
}
```

### Task 2: Create `pkg/experiment_definition/run_repository.go`

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

// RunRepository defines CRUD for experiment run records.
type RunRepository interface {
    Create(ctx context.Context, doc *AceExperimentRunDoc) error
    GetByID(ctx context.Context, runID string) (*AceExperimentRunDoc, error)
    UpdateStatus(ctx context.Context, runID string, status RunStatus, reason string) error
    UpdateCertifierFields(ctx context.Context, runID string, langfuseTraceID, certifierReportID string) error
    List(ctx context.Context, filter RunListFilter) ([]*AceExperimentRunDoc, error)
}

// RunListFilter filters the List query.
type RunListFilter struct {
    ProjectID      string
    DefinitionName string
    AgentName      string
    Status         RunStatus
}

type mongoRunRepository struct {
    collection *mongo.Collection
}

// NewRunRepository returns a MongoDB-backed RunRepository.
func NewRunRepository(db *mongo.Database) RunRepository {
    coll := db.Collection(RunCollectionName)

    // Unique index on runID
    _, _ = coll.Indexes().CreateMany(context.Background(), []mongo.IndexModel{
        {
            Keys:    bson.D{{Key: "runID", Value: 1}},
            Options: options.Index().SetUnique(true).SetName("runID_unique"),
        },
        {
            Keys: bson.D{
                {Key: "definitionName", Value: 1},
                {Key: "status", Value: 1},
            },
            Options: options.Index().SetName("definitionName_status"),
        },
        {
            Keys:    bson.D{{Key: "agentName", Value: 1}},
            Options: options.Index().SetName("agentName"),
        },
    })

    return &mongoRunRepository{collection: coll}
}

func (r *mongoRunRepository) Create(ctx context.Context, doc *AceExperimentRunDoc) error {
    doc.ID = primitive.NewObjectID()
    doc.CreatedAt = time.Now()
    if doc.Status == "" {
        doc.Status = RunStatusQueued
    }
    doc.StatusHistory = append(doc.StatusHistory, StatusEvent{
        Status:    doc.Status,
        Timestamp: doc.CreatedAt,
    })
    _, err := r.collection.InsertOne(ctx, doc)
    return err
}

func (r *mongoRunRepository) GetByID(ctx context.Context, runID string) (*AceExperimentRunDoc, error) {
    var doc AceExperimentRunDoc
    err := r.collection.FindOne(ctx, bson.M{"runID": runID}).Decode(&doc)
    if err == mongo.ErrNoDocuments {
        return nil, ErrRunNotFound{RunID: runID}
    }
    return &doc, err
}

func (r *mongoRunRepository) UpdateStatus(ctx context.Context, runID string, status RunStatus, reason string) error {
    now := time.Now()
    update := bson.M{
        "$set": bson.M{"status": status},
        "$push": bson.M{
            "statusHistory": StatusEvent{
                Status:    status,
                Timestamp: now,
                Reason:    reason,
            },
        },
    }
    // Set timing fields
    switch status {
    case RunStatusRunning:
        update["$set"].(bson.M)["startedAt"] = now
    case RunStatusCompleted, RunStatusFailed, RunStatusAborted:
        update["$set"].(bson.M)["completedAt"] = now
    }
    _, err := r.collection.UpdateOne(ctx, bson.M{"runID": runID}, update)
    return err
}

func (r *mongoRunRepository) UpdateCertifierFields(ctx context.Context, runID, langfuseTraceID, certifierReportID string) error {
    _, err := r.collection.UpdateOne(ctx,
        bson.M{"runID": runID},
        bson.M{"$set": bson.M{
            "langfuseTraceId":   langfuseTraceID,
            "certifierReportId": certifierReportID,
        }},
    )
    return err
}

func (r *mongoRunRepository) List(ctx context.Context, f RunListFilter) ([]*AceExperimentRunDoc, error) {
    filter := bson.M{}
    if f.ProjectID != "" {
        filter["projectID"] = f.ProjectID
    }
    if f.DefinitionName != "" {
        filter["definitionName"] = f.DefinitionName
    }
    if f.AgentName != "" {
        filter["agentName"] = f.AgentName
    }
    if f.Status != "" {
        filter["status"] = f.Status
    }

    cursor, err := r.collection.Find(ctx, filter,
        options.Find().SetSort(bson.D{{Key: "createdAt", Value: -1}}).SetLimit(100))
    if err != nil {
        return nil, err
    }
    defer cursor.Close(ctx)

    var docs []*AceExperimentRunDoc
    return docs, cursor.All(ctx, &docs)
}
```

### Task 3: Add `ErrRunNotFound` to errors.go

```go
// ErrRunNotFound is returned when a run ID does not exist.
type ErrRunNotFound struct {
    RunID string
}

func (e ErrRunNotFound) Error() string {
    return fmt.Sprintf("experiment run not found: %q", e.RunID)
}
```

### Task 4: Create `graphql/definitions/shared/experiment_run_ext.graphqls`

```graphql
"""
Lifecycle status of an ACE experiment run.
"""
enum AceRunStatus {
  """Submitted to Argo; waiting for cluster capacity."""
  QUEUED
  """Argo Workflow is actively executing."""
  RUNNING
  """All steps completed; certifier received Langfuse trace."""
  COMPLETED
  """A step failed (app probe, fault injection, or verify step)."""
  FAILED
  """User called abortRun or 90-minute timeout was reached."""
  ABORTED
}

"""
A single status transition event in the run lifecycle.
"""
type RunStatusEvent {
  status: AceRunStatus!
  timestamp: String!
  reason: String
}

"""
One execution instance of an AceExperimentDefinition.
A run record is immutable after reaching COMPLETED, FAILED, or ABORTED.
"""
type AceExperimentRun {
  runID: String!
  projectID: String!

  """Name and version of the experiment definition this run was created from."""
  definitionName: String!
  definitionVersion: String!

  """Agent that executed this run."""
  agentName: String!
  agentVersion: String!

  """
  LLM model used in this run — always populated (resolved at submit time).
  e.g. "gpt-4o", "claude-3-5-sonnet-20241022"
  """
  modelUsed: String!

  """
  LLM provider for the model used. e.g. "openai", "anthropic"
  """
  modelProvider: String!

  """Name of the Argo Workflow created for this run."""
  argoWorkflowName: String!

  """Langfuse trace ID — populated when agent begins executing."""
  langfuseTraceId: String

  """Certifier report ID — populated when certification completes."""
  certifierReportId: String

  status: AceRunStatus!
  statusHistory: [RunStatusEvent!]!

  startedAt: String
  completedAt: String
  createdAt: String!
  createdBy: String!
}

"""
Input for a secret key/value pair used by the agent.
"""
input AceSecretInput {
  key: String!
  value: String!
}

"""
Input for overriding a parameter value at run time.
"""
input AceParamInput {
  stepName: String!
  key: String!
  value: String!
}

extend type Mutation {
  """
  Submit a new run of an experiment definition.
  Validates the definition, hydrates an Argo Workflow, submits it, and returns the run record.
  """
  submitRun(
    projectID: ID!
    experimentName: String!
    agentName: String!
    """
    Override the model for this run. Only valid when the agent's
    llmConfig.allowUserChoice is true. Ignored otherwise.
    """
    modelOverride: String
    """
    Agent secret key/value pairs. These are stored in a K8s Secret
    named ace-agent-secret-<runID> in the litmus namespace.
    """
    secretOverrides: [AceSecretInput!]
    """
    Per-step parameter overrides applied at hydration time.
    """
    paramOverrides: [AceParamInput!]
  ): AceExperimentRun! @authorized

  """
  Abort a running experiment. Stops the Argo Workflow and marks the run as ABORTED.
  Has no effect if the run is already in a terminal state.
  """
  abortRun(projectID: ID!, runID: String!): AceExperimentRun! @authorized
}

extend type Query {
  """
  Retrieve a single run record by run ID.
  """
  getRun(projectID: ID!, runID: String!): AceExperimentRun @authorized

  """
  List runs, optionally filtered by experiment name, agent name, or status.
  Returns up to 100 records ordered by creation time descending.
  """
  listRuns(
    projectID: ID!
    experimentName: String
    agentName: String
    status: AceRunStatus
  ): [AceExperimentRun!]! @authorized
}
```

---

## Verification Criteria

### Must Pass

1. Package compiles:
   ```bash
   go build ./pkg/experiment_definition/...
   ```

2. `gqlgen generate` after adding `experiment_run_ext.graphqls` exits 0:
   ```bash
   go run github.com/99designs/gqlgen generate
   go build ./...
   ```

3. MongoDB indexes are created on `experiment_runs_ext`:
   ```bash
   mongosh litmus --eval "db.experiment_runs_ext.getIndexes()"
   # Expected: 3 indexes (runID unique, definitionName+status, agentName)
   ```

4. `AceRunStatus` enum values do not collide with existing `ExperimentRunStatus` in `chaos_experiment.graphqls`.

### Should Pass

5. `AceExperimentRunDoc.IsTerminal()` returns true for COMPLETED, FAILED, ABORTED and false for QUEUED, RUNNING.

6. `UpdateStatus` with RUNNING sets `startedAt`; with COMPLETED sets `completedAt`.

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server

# Compile check
go build ./...

# Unit tests
go test ./pkg/experiment_definition/... -run TestRun -v

# MongoDB index verification
mongosh litmus --eval "db.experiment_runs_ext.getIndexes()"
```

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `AceRunStatus` collides with `ExperimentRunStatus` | Both enums have `RUNNING`, `COMPLETED` etc. | They are different GraphQL enum types; gqlgen generates separate Go types — no collision |
| `submitRun` / `abortRun` resolver stubs generated but not implemented | Stage 08 only creates the schema; resolvers are implemented in Stage 09 | Leave the stubs returning `nil, fmt.Errorf("not implemented")` for now |
| `UpdateStatus` fails with no documents matched | runID not found | Check `Create` succeeded and runID is a string UUID, not an ObjectID |

---

## Rollback Procedure

```bash
rm /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/definitions/shared/experiment_run_ext.graphqls
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/experiment_definition/run_model.go
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server/pkg/experiment_definition/run_repository.go
mongosh litmus --eval "db.experiment_runs_ext.drop()"
go run github.com/99designs/gqlgen generate
```

---

## Success Criteria

Stage 08 is complete when:
- `go build ./...` succeeds
- `AceExperimentRunDoc` struct is usable in unit tests
- `experiment_runs_ext` collection indexes are created
- `experiment_run_ext.graphqls` adds the four new operations without breaking existing schema

**Next Stage:** Stage 09 — `submitRun` + `abortRun` Mutations
