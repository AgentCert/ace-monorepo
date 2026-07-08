# Test Scenarios Per Stage

**Date:** 2026-07-07

This document lists unit, integration, and manual test scenarios for each stage.
Run the "Must Pass" scenarios before marking a stage complete in PROGRESS.md.

---

## Stage 01: Fault Catalog Directory Structure & Seed Faults

### Unit Tests
None (Stage 01 creates YAML files; testing is via the validate script).

### Integration Tests

**01-INT-01: Validate all seed fault.yamls with `catalog/validate.sh fault`**
```bash
for f in $(find /srv/projects/ace-monorepo/catalog -name "fault.yaml"); do
  bash /srv/projects/ace-monorepo/catalog/validate.sh fault "$f" || exit 1
done
echo "All fault.yamls passed validation"
```
Expected: each file prints "OK: ... is valid".

**01-INT-02: YAML syntax check all seed fault.yamls**
```bash
python3 -c "
import yaml, glob, sys
for f in glob.glob('/srv/projects/ace-monorepo/catalog/**/fault.yaml', recursive=True):
    try:
        yaml.safe_load(open(f))
        print(f'OK: {f}')
    except yaml.YAMLError as e:
        print(f'FAIL: {f}: {e}')
        sys.exit(1)
"
```
Expected: "OK" for all 5 files.

### Manual Tests

**01-MAN-01: Correct scope assignment**
- Open `catalog/faults/general/pod-delete/fault.yaml` — confirm `scope: general` and `domain: null`.
- Open `catalog/faults/domains/telecom/snmp-trap-flood/fault.yaml` — confirm `scope: domain` and `domain: telecom`.
- Open `catalog/apps/official/sock-shop/faults/carts-db-corrupt/fault.yaml` — confirm `scope: app-specific` and `targetApp: sock-shop`.

---

## Stage 02: FaultCatalogEntry Go Types + YAML Loader

### Unit Tests

**02-UNIT-01: Loader builds in-memory index**
```go
// In pkg/fault_catalog/loader_test.go
func TestLoadCatalog_BuildsIndex(t *testing.T) {
    err := LoadCatalog("../../testdata/catalog")
    require.NoError(t, err)

    svc := NewService(nil)
    all := svc.ListFaults("", "", "")
    assert.GreaterOrEqual(t, len(all), 2, "expected at least 2 faults from testdata")
}
```

**02-UNIT-02: Duplicate fault name is skipped with warning**
```go
func TestLoadCatalog_SkipsDuplicate(t *testing.T) {
    // testdata should have two fault.yamls with the same name
    // Only one should end up in the index
    err := LoadCatalog("../../testdata/catalog-with-duplicate")
    require.NoError(t, err)
    svc := NewService(nil)
    all := svc.ListFaults("", "", "")
    names := make(map[string]bool)
    for _, f := range all {
        assert.False(t, names[f.Metadata.Name], "duplicate name found: %s", f.Metadata.Name)
        names[f.Metadata.Name] = true
    }
}
```

**02-UNIT-03: GetFault returns ErrFaultNotFound for unknown name**
```go
func TestGetFault_NotFound(t *testing.T) {
    _ = LoadCatalog("../../testdata/catalog")
    svc := NewService(nil)
    _, err := svc.GetFault("does-not-exist")
    var notFound ErrFaultNotFound
    assert.ErrorAs(t, err, &notFound)
}
```

**02-UNIT-04: FaultsForApp returns correct union**
```go
func TestFaultsForApp_ReturnsCorrectSet(t *testing.T) {
    _ = LoadCatalog("../../testdata/catalog")
    svc := NewService(nil) // no apps_registry; uses only index
    faults := svc.FaultsForApp(context.Background(), "test-app")
    // testdata should have at least 1 general + 1 app-specific fault
    assert.GreaterOrEqual(t, len(faults), 1)
}
```

### Integration Tests

**02-INT-01: Server starts with catalog loaded**
```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server
ACE_CATALOG_ROOT=/srv/projects/ace-monorepo/catalog go run . 2>&1 | \
  grep "fault_catalog: loaded" | head -1
# Expected: "fault_catalog: loaded 5 faults..."
```

---

## Stage 03: Fault Catalog GraphQL Schema + Resolvers

### Unit Tests

**03-UNIT-01: gqlgen generate exits 0**
```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server
go run github.com/99designs/gqlgen generate 2>&1
echo "Exit: $?"
# Expected: 0
```

**03-UNIT-02: Go build succeeds**
```bash
go build ./... 2>&1 | grep -v "^#"
echo "Exit: $?"
# Expected: 0
```

### Integration Tests

**03-INT-01: listFaults returns all faults**
```bash
curl -sf -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "{ listFaults { name scope } }"}' | \
  jq '.data.listFaults | length'
# Expected: >= 5
```

**03-INT-02: getFault returns correct struct**
```bash
curl -sf -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "{ getFault(name: \"pod-delete\") { name scope groundTruth { detectWithinSecs } } }"}' | \
  jq '.data.getFault'
# Expected: { name: "pod-delete", scope: "GENERAL", groundTruth: { detectWithinSecs: 60 } }
```

**03-INT-03: getFault on unknown name returns null**
```bash
curl -sf -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "{ getFault(name: \"does-not-exist\") { name } }"}' | \
  jq '.data.getFault'
# Expected: null
```

**03-INT-04: Unauthenticated request returns permission denied**
```bash
curl -sf -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "{ listFaults { name } }"}' | \
  jq '.errors[0].message'
# Expected: "permission denied" or "unauthorized"
```

---

## Stage 04: ExperimentDefinition Go Types + MongoDB Collection

### Unit Tests

**04-UNIT-01: validateFaultRefs rejects unknown faultRef**
```go
func TestValidateFaultRefs_Rejects(t *testing.T) {
    svc := experimentService{faultCatalog: mockFaultCatalog{}}
    doc := &ExperimentDefinitionDoc{
        Steps: []ExperimentStep{
            {Type: StepTypeFault, FaultRef: "nonexistent-fault"},
        },
    }
    err := svc.validateFaultRefs(doc)
    require.Error(t, err)
    assert.Contains(t, err.Error(), "nonexistent-fault")
}
```

**04-UNIT-02: validateFaultRefs accepts known faultRef**
```go
func TestValidateFaultRefs_Accepts(t *testing.T) {
    svc := experimentService{faultCatalog: mockFaultCatalog{knownFaults: []string{"pod-delete"}}}
    doc := &ExperimentDefinitionDoc{
        Steps: []ExperimentStep{
            {Type: StepTypeFault, FaultRef: "pod-delete"},
        },
    }
    err := svc.validateFaultRefs(doc)
    require.NoError(t, err)
}
```

### Integration Tests

**04-INT-01: MongoDB unique index prevents duplicate (name, projectID)**
```bash
mongosh litmus --eval "
  db.experiment_definitions.insertOne({name: 'test', projectID: 'p1'});
  try {
    db.experiment_definitions.insertOne({name: 'test', projectID: 'p1'});
    print('FAIL: expected duplicate key error');
  } catch(e) {
    print('OK: duplicate rejected: ' + e.message);
  }
  db.experiment_definitions.deleteOne({name: 'test', projectID: 'p1'});
"
```

---

## Stage 05: Experiment Definition GraphQL Schema + CRUD

### Integration Tests

**05-INT-01: createExperiment → getExperiment roundtrip**
```bash
# Create
curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query":"mutation{createExperiment(projectID:\"p1\",input:{name:\"test-05\",targetApp:{name:\"sock-shop\",version:\">=1.0.0\"},modelSelection:{mode:AGENT_DEFAULT},steps:[{name:\"b\",type:OBSERVE,duration:\"30s\"}]}){name version status}}"}' | \
  jq .data.createExperiment

# Get
curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query":"query{getExperiment(projectID:\"p1\",name:\"test-05\"){name status steps{name type}}}"}' | \
  jq .data.getExperiment
```

**05-INT-02: updateExperiment increments version**
```bash
# Get initial version
V1=$(curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query":"query{getExperiment(projectID:\"p1\",name:\"test-05\"){version}}"}' | \
  jq -r .data.getExperiment.version)

# Update
curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query":"mutation{updateExperiment(projectID:\"p1\",name:\"test-05\",input:{name:\"test-05\",targetApp:{name:\"sock-shop\",version:\">=1.0.0\"},modelSelection:{mode:AGENT_DEFAULT},steps:[{name:\"b\",type:OBSERVE,duration:\"60s\"}]}){version}}"}' | \
  jq .data.updateExperiment.version
# Expected: "1.0.1" (version bumped from 1.0.0)
```

---

## Stage 06: App–Fault Compatibility Resolver

### Integration Tests

**06-INT-01: faultsForApp returns correct scoped faults**
```bash
FAULTS=$(curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query":"query{faultsForApp(appName:\"sock-shop\"){name scope}}"}' | \
  jq '.data.faultsForApp')

echo "$FAULTS" | jq 'map(select(.scope == "GENERAL")) | length'
# Expected: >= 2

echo "$FAULTS" | jq 'map(select(.scope == "DOMAIN")) | length'
# Expected: >= 1

echo "$FAULTS" | jq 'map(select(.scope == "APP_SPECIFIC")) | length'
# Expected: >= 1

echo "$FAULTS" | jq 'map(select(.name == "snmp-trap-flood")) | length'
# Expected: 0 (telecom fault not shown for cloud-native app)
```

---

## Stage 07: Argo Workflow Hydrator

### Unit Tests

**07-UNIT-01: Hydrate returns valid YAML**
```go
func TestHydrate_ReturnsValidYAML(t *testing.T) {
    def := sampleExperimentDef()
    agent := &AgentSpec{Name: "flash-agent", Version: "1.0.0"}
    params := sampleHydrationParams()

    yaml, err := Hydrate(def, agent, params)
    require.NoError(t, err)
    require.NotEmpty(t, yaml)

    // Unmarshal to verify syntactic validity
    var check map[string]interface{}
    err = goyaml.Unmarshal([]byte(yaml), &check)
    require.NoError(t, err)
}
```

**07-UNIT-02: Observe step produces observe-tmpl task**
```go
func TestHydrate_ObserveStep(t *testing.T) {
    def := defWithSteps([]expdef.ExperimentStep{
        {Name: "baseline", Type: expdef.StepTypeObserve, Duration: "30s"},
    })
    yaml, err := Hydrate(def, sampleAgent(), sampleParams())
    require.NoError(t, err)
    assert.Contains(t, yaml, "observe-tmpl")
    assert.Contains(t, yaml, "30s")
}
```

**07-UNIT-03: Parallel-fault step produces fan-out tasks**
```go
func TestHydrate_ParallelFault_FanOut(t *testing.T) {
    def := defWithSteps([]expdef.ExperimentStep{
        {
            Name: "cascade",
            Type: expdef.StepTypeParallelFault,
            Faults: []expdef.ParallelFaultEntry{
                {FaultRef: "pod-delete", Target: expdef.StepTarget{Microservice: "carts"}},
                {FaultRef: "cpu-hog",    Target: expdef.StepTarget{Microservice: "catalogue"}},
            },
        },
    })
    yaml, err := Hydrate(def, sampleAgent(), sampleParamsWithMicroservices("carts", "catalogue"))
    require.NoError(t, err)
    // Both fault tasks should appear
    assert.Contains(t, yaml, "step-cascade-fault-0")
    assert.Contains(t, yaml, "step-cascade-fault-1")
}
```

**07-UNIT-04: Nil definition returns error**
```go
func TestHydrate_NilDef_Error(t *testing.T) {
    _, err := Hydrate(nil, sampleAgent(), sampleParams())
    require.Error(t, err)
    assert.Contains(t, err.Error(), "nil experiment definition")
}
```

---

## Stage 08: Extended ExperimentRun Tracking

### Unit Tests

**08-UNIT-01: IsTerminal returns correct values**
```go
func TestIsTerminal(t *testing.T) {
    for status, expected := range map[RunStatus]bool{
        RunStatusQueued:    false,
        RunStatusRunning:   false,
        RunStatusCompleted: true,
        RunStatusFailed:    true,
        RunStatusAborted:   true,
    } {
        doc := &AceExperimentRunDoc{Status: status}
        assert.Equal(t, expected, doc.IsTerminal(), "status: %s", status)
    }
}
```

### Integration Tests

**08-INT-01: MongoDB indexes created**
```bash
mongosh litmus --eval "db.experiment_runs_ext.getIndexes()" | \
  python3 -c "
import sys, json
indexes = json.load(sys.stdin)
names = [i.get('name','') for i in indexes]
assert 'runID_unique' in names, 'Missing runID_unique index'
assert 'definitionName_status' in names, 'Missing definitionName_status index'
print('OK: all expected indexes present')
"
```

---

## Stage 09: submitRun + abortRun Mutations

### Integration Tests (Kind cluster required)

**09-INT-01: submitRun creates MongoDB run record**
```bash
RUN_ID=$(curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query":"mutation{submitRun(projectID:\"p1\",experimentName:\"test-05\",agentName:\"flash-agent\"){runID}}"}' | \
  jq -r .data.submitRun.runID)
echo "Run ID: $RUN_ID"
mongosh litmus --eval "db.experiment_runs_ext.findOne({runID: '$RUN_ID'}, {status:1,agentName:1,modelUsed:1})"
# Expected: document with status=QUEUED, agentName=flash-agent, modelUsed!=null
```

**09-INT-02: submitRun creates Argo Workflow**
```bash
kubectl get workflows -n litmus | grep "$RUN_ID"
# Expected: a workflow matching the run ID
```

**09-INT-03: abortRun updates status to ABORTED**
```bash
curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"query\":\"mutation{abortRun(projectID:\\\"p1\\\",runID:\\\"$RUN_ID\\\"){status}}\"}" | \
  jq .data.abortRun.status
# Expected: "ABORTED"
```

---

## Stage 10: Chaos Studio Screens 1 & 2

### Manual Tests

**10-MAN-01: Screen 1 renders app grid**
- Navigate to `http://localhost:3000/chaos-studio/new`
- Confirm app cards render with name, domain, tier badge, and fault count.
- Confirm domain filter reduces visible cards.
- Confirm search filters by name substring.

**10-MAN-02: Screen 1 → Screen 2 transition**
- Click "Select" on the Sock Shop card.
- Confirm Screen 2 renders with "App: Sock Shop (cloud-native)" in the context bar.
- Confirm agent cards show.

**10-MAN-03: Screen 2 agent filtering**
- Confirm only cloud-native-compatible agents appear (not telecom-only agents).
- Confirm clicking an agent advances to Screen 3 placeholder.

---

## Stage 11: Chaos Studio Screen 3 (Canvas)

### Manual Tests

**11-MAN-01: Drag fault to canvas**
- Drag "pod-delete" from the GENERAL section of the fault library.
- Drop it on the canvas.
- Confirm a node labeled "pod-delete: ?" appears.

**11-MAN-02: Parameter panel opens on node click**
- Click the pod-delete node.
- Confirm the FaultParameterPanel slides in on the right.
- Confirm "Target Microservice" selector shows microservice options.
- Confirm "CHAOS_DURATION" integer field shows with default value "30".

**11-MAN-03: All step types can be added**
- From the step types section, drag "observe" → drops as an observe node.
- Drag "verify" → drops as a verify node with probe URL field.
- Drag "wait" → drops as a wait node with duration field.

**11-MAN-04: Delete node**
- Click the "×" button on a node.
- Confirm the node is removed from the canvas.

---

## Stage 12: Chaos Studio Screen 4 (Configure & Run)

### Manual Tests

**12-MAN-01: Save as Draft**
- Complete wizard steps 1–3 with at least one observe step.
- On Screen 4: enter experiment name, click "Save as Draft".
- Confirm no error. Check MongoDB:
  ```bash
  mongosh litmus --eval "db.experiment_definitions.findOne({name: '<your-name>'})"
  ```

**12-MAN-02: Save & Run (agent-default model)**
- Agent's `allowUserChoice` is false.
- Click "Save & Run".
- Confirm redirect to `/chaos-studio/runs/<runID>`.
- Confirm Argo Workflow appears in `kubectl get workflows -n litmus`.

**12-MAN-03: Save & Run with user model choice**
- Agent's `allowUserChoice` is true.
- Set model mode to "User chooses at run time".
- Click "Save & Run" → RunDialog appears.
- Select a model from the picker → click "Start Run".
- Check run record: `modelUsed` matches the selected model.

**12-MAN-04: Run status page polls**
- After submit, run status page shows "QUEUED".
- After Argo starts, status changes to "RUNNING".
- After completion, status changes to "COMPLETED" and polling stops.
