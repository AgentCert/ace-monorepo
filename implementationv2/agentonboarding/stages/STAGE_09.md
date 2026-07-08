# Stage 9: install-agent Integration & End-to-End Smoke Test

**Phase:** 4 — Experiment Wiring  
**Dependencies:** Stage 8 complete  
**Risk Level:** Medium — requires a running kind cluster

---

## Objectives

1. Verify `install-agent` binary correctly processes all `--set` args from Stage 8
2. Run a full end-to-end smoke test: register agent → save experiment → run experiment → verify agent pod starts
3. Verify `agent.notifyId`, `agent.workflowUid`, `sidecar.upstream` reach the agent container as env vars
4. Verify `uninstall-agent` cleans up cleanly

---

## Current State Analysis

### What We Have
- `agent-charts/install-agent/main.go` — Go binary that runs Helm install
- Kind cluster with ACE deployed (see `deploy/kind/` docs)
- `flash-agent` as the reference agent image (already works with the old install path)

### What We Need
- Confirmation that `install-agent` passes the 3 mandatory context injections to the agent container
- Confirmation that `agent.secretRef` is wired to `envFrom.secretRef` in the Helm chart
- Confirmation that uninstall runs in `onExit` handler

---

## Pre-Stage Verification

```bash
# Confirm install-agent binary exists and has --set support
./agent-charts/install-agent/main.go --help 2>/dev/null || \
  cd agent-charts/install-agent && go build -o install-agent . && ./install-agent --help

# Confirm kind cluster is up
kubectl cluster-info --context kind-agentcert

# Confirm ACE is deployed
kubectl get pods -n litmus | grep -E "graphql|frontend"
```

---

## Implementation Tasks

### Task 1: Review `install-agent/main.go` for Context Injection Support

**File to Read:** `agent-charts/install-agent/main.go`

Verify it:
- Accepts `--set` in the form `--set=<path>=<value>`
- Passes these as `helm install --set <path>=<value>` args
- Does NOT log `--set` values that contain secrets

If the binary does not yet forward `--set` args, add the forwarding:

```go
// In install-agent main.go — ensure --set args are passed through to helm
for _, setArg := range sets {
    helmArgs = append(helmArgs, "--set", setArg)
}
```

**Security check:** Grep for any logging of `--set` args:

```bash
grep -n "set\|Set\|args" agent-charts/install-agent/main.go | grep -i "log\|print\|fmt\."
```

If secret values could appear in set args (they shouldn't — secrets go via secretRef), add filtering:
log set arg names only, not values for paths ending in `.apiKey`, `.secret`, `.key`.

---

### Task 2: Generic Wrapper Chart — Verify Required Paths

**File to Read:** `agent-charts/charts/` (the generic wrapper chart, if it exists)

Verify `values.yaml` has these paths (from spec §14.3):

```yaml
agent:
  notifyId: ""        # filled by --set
  workflowUid: ""     # filled by --set
  secretRef: ""       # filled by --set (K8s Secret name)
  config: {}          # free-form non-secret config

sidecar:
  enabled: true
  upstream: ""        # filled by --set
  port: 4000
```

Verify `deployment.yaml` template uses them:

```yaml
envFrom:
  - secretRef:
      name: {{ .Values.agent.secretRef }}
env:
  - name: ACE_NOTIFY_ID
    value: {{ .Values.agent.notifyId | quote }}
  - name: ACE_WORKFLOW_UID
    value: {{ .Values.agent.workflowUid | quote }}
  - name: OPENAI_BASE_URL
    value: "http://localhost:{{ .Values.sidecar.port }}/v1"
```

If these paths are missing, add them. This is the key contract between ACE and any generic-wrapper agent.

---

### Task 3: End-to-End Smoke Test

**Objective:** Register a test agent, save an experiment, run it, verify the agent pod has the correct env vars.

**Step 1: Register a test agent via GraphQL**

```graphql
mutation {
  registerAgent(input: {
    projectID: "<your-project-id>"
    name: "smoke-test-agent"
    displayName: "Smoke Test Agent"
    version: "1.0.0"
    vendor: "ace-test"
    capabilities: ["prometheus-query"]
    install: { method: "generic-wrapper", image: "busybox:1.36", namespace: "litmus" }
    description: { short: "Smoke test agent", long: "Used for E2E testing of onboarding flow.",
                   llmDependent: false }
    owner: { name: "Test", email: "test@ace.io" }
    inputs: []
    evaluationMetrics: ["time_to_detect"]
  }) {
    agent { agentID name }
  }
}
```

**Step 2: Save a chaos experiment with this agent (use existing saveChaosExperiment mutation)**

**Step 3: Run the experiment and watch the install-agent step**

```bash
# Watch the Argo workflow
argo watch <workflow-name> -n litmus

# Check the install-agent step logs
argo logs <workflow-name> -n litmus -c install-agent
```

**Step 4: Verify agent pod env vars**

```bash
# Find the agent pod
kubectl get pods -n litmus -l app.kubernetes.io/name=smoke-test-agent

# Check env vars
kubectl exec -n litmus <pod-name> -- env | grep -E "ACE_NOTIFY_ID|ACE_WORKFLOW_UID|OPENAI_BASE_URL"
```

Expected output:
```
ACE_NOTIFY_ID=<workflow-name>
ACE_WORKFLOW_UID=<workflow-uid>
OPENAI_BASE_URL=http://localhost:4000/v1   (if sidecar enabled)
```

**Step 5: Verify cleanup**

After the workflow completes:

```bash
kubectl get pods -n litmus -l app.kubernetes.io/name=smoke-test-agent
# Should return No resources found — pod is cleaned up by uninstall-agent
```

---

### Task 4: Test Secret Injection (with a real secret input)

Register an agent with a `type: secret` input. Save an experiment, providing a dummy API key.
Verify:

```bash
# Secret exists
kubectl get secret ace-agent-secret-<expID> -n litmus

# Secret has the right key
kubectl get secret ace-agent-secret-<expID> -n litmus -o jsonpath='{.data}' | python3 -c \
  "import json,base64,sys; d=json.load(sys.stdin); print({k: base64.b64decode(v).decode() for k,v in d.items()})"
# Should print the key names and values (in test/dev only; never do this in prod)

# Agent container received the secret as env var
kubectl exec -n litmus <pod-name> -- env | grep OPENAI_API_KEY
```

---

## Files to Modify (if needed)

- `agent-charts/install-agent/main.go` — add --set forwarding if missing; remove secret value logging
- `agent-charts/charts/<generic-wrapper>/values.yaml` — add required path defaults
- `agent-charts/charts/<generic-wrapper>/templates/deployment.yaml` — wire required env vars

---

## Verification Criteria

### Must Pass
- [ ] `install-agent` passes `--set` args to `helm install`
- [ ] Agent pod starts with `ACE_NOTIFY_ID` and `ACE_WORKFLOW_UID` env vars set
- [ ] `uninstall-agent` removes the agent pod and Helm release
- [ ] `ace-agent-secret-<expID>` is injected into the agent container via `envFrom.secretRef`
- [ ] No secret values appear in `install-agent` logs

### Should Pass
- [ ] `sidecar.upstream` is set to the correct LiteLLM URL in the agent pod
- [ ] Agent pod annotations include `ace.io/agent`, `ace.io/workflow-uid`, `ace.io/experiment-id`

---

## Testing Commands

```bash
# Full smoke test
kubectl get pods -n litmus
argo list -n litmus
argo watch <workflow-name> -n litmus

# Agent env var check
kubectl exec -n litmus <agent-pod> -- env | sort

# Cleanup verification
kubectl get pods -n litmus -l app.kubernetes.io/name=smoke-test-agent
kubectl get secret -n litmus | grep ace-agent-secret
```

---

## Rollback Procedure

If the smoke test reveals install-agent regressions:
1. Check `argo logs <wf> -n litmus` for the install-agent step
2. Verify `--set` args are correct (log the non-secret ones at DEBUG level)
3. Check `helm history <release-name> -n litmus` for failed releases

---

## Success Criteria

Stage 9 is complete when:
1. Smoke test agent pod starts and has correct env vars
2. Agent pod is cleaned up after workflow completion
3. Secret is injected without appearing in logs or workflow YAML
4. All 9 stages verified complete in `PROGRESS.md`

**The implementation plan is complete.**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
