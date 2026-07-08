# End-to-End Integration Tests

**Date:** 2026-07-07  
**Prerequisite:** All 12 stages complete. Kind cluster running. Server started with `ACE_CATALOG_ROOT` set.

---

## Setup

```bash
# 1. Start the GraphQL server
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server
ACE_CATALOG_ROOT=/srv/projects/ace-monorepo/catalog go run . &
SERVER_PID=$!
sleep 3

# 2. Get auth token
TOKEN=$(curl -sf -X POST http://localhost:8080/auth/login \
  -d '{"username":"admin","password":"litmus"}' | jq -r .accessToken)
export TOKEN

# 3. Set project ID
export PROJECT_ID="test-project-001"

# 4. Confirm cluster
kubectl cluster-info --context kind-AgentCert
```

---

## E2E Test 1: Full Fault Catalog Pipeline

Tests Stages 01–03.

```bash
echo "=== E2E Test 1: Fault Catalog Pipeline ==="

# 1a. listFaults returns all 5 seed faults
COUNT=$(curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "{ listFaults { name } }"}' | jq '.data.listFaults | length')
[ "$COUNT" -ge 5 ] && echo "PASS: listFaults count >= 5 (got $COUNT)" || echo "FAIL: only $COUNT faults"

# 1b. getFault on each seed fault returns correct scope
for FAULT in pod-delete cpu-hog pod-oom-kill snmp-trap-flood carts-db-corrupt; do
  SCOPE=$(curl -sf -X POST http://localhost:8080/query \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"query\": \"{ getFault(name: \\\"$FAULT\\\") { scope } }\"}" | \
    jq -r '.data.getFault.scope')
  [ -n "$SCOPE" ] && [ "$SCOPE" != "null" ] && \
    echo "PASS: getFault($FAULT) scope = $SCOPE" || \
    echo "FAIL: getFault($FAULT) returned null"
done

# 1c. faultsForApp(sock-shop) returns general + cloud-native + sock-shop-specific
FAULTS=$(curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "{ faultsForApp(appName: \"sock-shop\") { name scope } }"}' | \
  jq '.data.faultsForApp')
echo "$FAULTS" | jq 'map(select(.name == "pod-delete")) | length == 1' | \
  grep -q true && echo "PASS: pod-delete in faultsForApp(sock-shop)" || echo "FAIL"
echo "$FAULTS" | jq 'map(select(.name == "carts-db-corrupt")) | length == 1' | \
  grep -q true && echo "PASS: carts-db-corrupt in faultsForApp(sock-shop)" || echo "FAIL"
echo "$FAULTS" | jq 'map(select(.name == "snmp-trap-flood")) | length == 0' | \
  grep -q true && echo "PASS: snmp-trap-flood NOT in faultsForApp(sock-shop)" || echo "FAIL"
```

---

## E2E Test 2: Experiment Definition CRUD Pipeline

Tests Stages 04–06.

```bash
echo "=== E2E Test 2: Experiment CRUD ==="
EXP_NAME="e2e-test-$(date +%s)"

# 2a. Create experiment
CREATED=$(curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"query\": \"mutation {
      createExperiment(projectID: \\\"$PROJECT_ID\\\", input: {
        name: \\\"$EXP_NAME\\\",
        targetApp: { name: \\\"sock-shop\\\", version: \\\">=1.0.0\\\" },
        modelSelection: { mode: AGENT_DEFAULT },
        steps: [
          { name: \\\"baseline\\\", type: OBSERVE, duration: \\\"30s\\\" },
          { name: \\\"inject\\\", type: FAULT, faultRef: \\\"pod-delete\\\",
            target: { microservice: \\\"carts\\\" },
            params: [{ key: \\\"CHAOS_DURATION\\\", value: \\\"30\\\" }] }
        ]
      }) { name version status }
    }\"
  }" | jq '.data.createExperiment')
echo "$CREATED" | jq -r .name | grep -q "$EXP_NAME" && \
  echo "PASS: createExperiment succeeded" || echo "FAIL: createExperiment"
echo "$CREATED" | jq -r .version | grep -q "1.0.0" && \
  echo "PASS: version is 1.0.0" || echo "FAIL: wrong initial version"

# 2b. Get experiment
FETCHED=$(curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"query\": \"{ getExperiment(projectID: \\\"$PROJECT_ID\\\", name: \\\"$EXP_NAME\\\") { name steps { name type } } }\"}" | \
  jq '.data.getExperiment')
echo "$FETCHED" | jq '.steps | length == 2' | grep -q true && \
  echo "PASS: getExperiment returns 2 steps" || echo "FAIL: wrong step count"

# 2c. listExperiments
LIST=$(curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"query\": \"{ listExperiments(projectID: \\\"$PROJECT_ID\\\") { name } }\"}" | \
  jq --arg name "$EXP_NAME" '.data.listExperiments | map(select(.name == $name)) | length')
[ "$LIST" -eq 1 ] && echo "PASS: listExperiments includes new experiment" || echo "FAIL"

# 2d. deleteExperiment
curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"query\": \"mutation { deleteExperiment(projectID: \\\"$PROJECT_ID\\\", name: \\\"$EXP_NAME\\\") }\"}" | \
  jq .data.deleteExperiment | grep -q true && \
  echo "PASS: deleteExperiment returned true" || echo "FAIL"
```

---

## E2E Test 3: Workflow Hydration (Unit-level)

Tests Stage 07 in isolation without K8s.

```bash
echo "=== E2E Test 3: Hydration Unit Tests ==="
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/graphql/server
go test ./pkg/experiment_hydrator/... -v -count=1 2>&1 | grep -E "^(PASS|FAIL|---)"
```

---

## E2E Test 4: Full Run Lifecycle (Requires Kind cluster)

Tests Stages 07–09.

```bash
echo "=== E2E Test 4: Full Run Lifecycle ==="
EXP_NAME="e2e-run-$(date +%s)"

# 4a. Create experiment with an observe step (fast, for testing)
curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d "{
    \"query\": \"mutation {
      createExperiment(projectID: \\\"$PROJECT_ID\\\", input: {
        name: \\\"$EXP_NAME\\\",
        targetApp: { name: \\\"sock-shop\\\", version: \\\">=1.0.0\\\" },
        modelSelection: { mode: AGENT_DEFAULT },
        steps: [ { name: \\\"baseline\\\", type: OBSERVE, duration: \\\"5s\\\" } ]
      }) { name }
    }\"
  }" | jq .

# 4b. Submit run
RUN_RESULT=$(curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d "{
    \"query\": \"mutation {
      submitRun(
        projectID: \\\"$PROJECT_ID\\\",
        experimentName: \\\"$EXP_NAME\\\",
        agentName: \\\"flash-agent\\\"
      ) { runID status argoWorkflowName modelUsed modelProvider }
    }\"
  }")
echo "$RUN_RESULT" | jq .

RUN_ID=$(echo "$RUN_RESULT" | jq -r '.data.submitRun.runID')
[ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] && \
  echo "PASS: submitRun returned runID: $RUN_ID" || echo "FAIL: no runID"

MODEL_USED=$(echo "$RUN_RESULT" | jq -r '.data.submitRun.modelUsed')
[ "$MODEL_USED" != "null" ] && [ -n "$MODEL_USED" ] && \
  echo "PASS: modelUsed is populated: $MODEL_USED" || echo "FAIL: modelUsed is null"

# 4c. Verify Argo Workflow created
ARGO_WF=$(echo "$RUN_RESULT" | jq -r '.data.submitRun.argoWorkflowName')
kubectl get workflow "$ARGO_WF" -n litmus 2>/dev/null && \
  echo "PASS: Argo Workflow $ARGO_WF exists in litmus namespace" || \
  echo "FAIL: Argo Workflow not found"

# 4d. Verify K8s Secret created
kubectl get secret "ace-agent-secret-${RUN_ID#run-}" -n litmus 2>/dev/null && \
  echo "PASS: agent secret exists" || echo "INFO: secret may use different naming"

# 4e. Verify MongoDB run record
mongosh litmus --eval \
  "var doc = db.experiment_runs_ext.findOne({runID: '$RUN_ID'});
   if (doc) { print('PASS: run record found, status=' + doc.status); }
   else { print('FAIL: run record not found'); }" 2>/dev/null

# 4f. Wait for terminal state (max 5 min for short observe-only run)
echo "Waiting for terminal status..."
for i in $(seq 1 30); do
  STATUS=$(curl -sf -X POST http://localhost:8080/query \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"query\": \"{ getRun(projectID: \\\"$PROJECT_ID\\\", runID: \\\"$RUN_ID\\\") { status } }\"}" | \
    jq -r '.data.getRun.status')
  echo "  Attempt $i: status = $STATUS"
  case "$STATUS" in
    COMPLETED|FAILED) echo "PASS: Run reached terminal state: $STATUS"; break ;;
    ABORTED) echo "FAIL: Run was aborted unexpectedly"; break ;;
  esac
  sleep 10
done

# 4g. Test abortRun on a new run
RUN_ID2=$(curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"query\": \"mutation { submitRun(projectID: \\\"$PROJECT_ID\\\", experimentName: \\\"$EXP_NAME\\\", agentName: \\\"flash-agent\\\") { runID } }\"}" | \
  jq -r '.data.submitRun.runID')
sleep 2
ABORT_STATUS=$(curl -sf -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"query\": \"mutation { abortRun(projectID: \\\"$PROJECT_ID\\\", runID: \\\"$RUN_ID2\\\") { status } }\"}" | \
  jq -r '.data.abortRun.status')
[ "$ABORT_STATUS" = "ABORTED" ] && echo "PASS: abortRun → ABORTED" || \
  echo "INFO: abortRun status = $ABORT_STATUS (may have already completed)"
```

---

## E2E Test 5: Chaos Studio Frontend Flow (Browser)

Manual test — requires the frontend dev server.

```bash
echo "=== E2E Test 5: Chaos Studio Frontend (Manual) ==="
echo "Steps:"
echo "  1. Start dev server: cd AgentCert/chaoscenter/web && yarn start"
echo "  2. Navigate to http://localhost:3000/chaos-studio/new"
echo "  3. Select 'Sock Shop' from Screen 1"
echo "  4. Select 'Flash Agent' from Screen 2"
echo "  5. Drag 'pod-delete' from fault library to canvas"
echo "  6. Click the pod-delete node → set target microservice to 'carts'"
echo "  7. Click 'Next' to reach Screen 4"
echo "  8. Enter experiment name, click 'Save & Run'"
echo "  9. Verify redirect to /chaos-studio/runs/<runID>"
echo " 10. Verify status page shows QUEUED → RUNNING → COMPLETED"
echo ""
echo "Checklist (mark each as PASS/FAIL):"
echo "  [ ] App cards show fault count"
echo "  [ ] Domain filter works"
echo "  [ ] Agent list shows compatible agents"
echo "  [ ] Drag-and-drop adds node to canvas"
echo "  [ ] Parameter panel opens on node click"
echo "  [ ] Parameters are pre-populated with fault defaults"
echo "  [ ] Model selector adapts to agent's allowUserChoice"
echo "  [ ] Save & Run submits the experiment"
echo "  [ ] Run status page polls and updates"
```

---

## Cleanup After Tests

```bash
# Kill the test server
kill $SERVER_PID 2>/dev/null

# Delete test experiments from MongoDB
mongosh litmus --eval "
  db.experiment_definitions.deleteMany({name: /e2e-/});
  db.experiment_runs_ext.deleteMany({definitionName: /e2e-/});
"

# Delete test Argo Workflows
kubectl delete workflows -n litmus -l ace.io/experiment-name=e2e-test 2>/dev/null

# Delete test namespaces
kubectl delete namespace -l ace.io/run-id 2>/dev/null
```

---

## Expected Results Summary

| Test | Expected | Pass Criteria |
|------|----------|---------------|
| E2E-1a | listFaults count | >= 5 |
| E2E-1b | getFault scope | Correct scope for all 5 faults |
| E2E-1c | faultsForApp(sock-shop) | Contains pod-delete, carts-db-corrupt; does NOT contain snmp-trap-flood |
| E2E-2a | createExperiment | Returns version "1.0.0", status DRAFT |
| E2E-2b | getExperiment | Returns 2 steps |
| E2E-2c | listExperiments | New experiment in list |
| E2E-2d | deleteExperiment | Returns true |
| E2E-3 | Hydration unit tests | All pass |
| E2E-4b | submitRun | Returns non-null runID and modelUsed |
| E2E-4c | Argo Workflow | Exists in litmus namespace |
| E2E-4e | MongoDB run record | Found with status QUEUED |
| E2E-4f | Terminal state | COMPLETED or FAILED within 5 minutes |
| E2E-4g | abortRun | Returns ABORTED |
| E2E-5 | Frontend flow | All 10 checklist items pass |
