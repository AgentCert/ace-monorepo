# Stage 12: Chaos Studio — Screen 4 (Configure & Run)

**Phase:** 3 — Chaos Studio  
**Status:** Not Started  
**Estimated Effort:** 1.5 days  
**Date Added:** 2026-07-07  
**Depends On:** Stages 09 + 11 (submitRun mutation + canvas both complete)

---

## Objectives

1. Create `ConfigureAndRun.tsx` — Screen 4 with: experiment name, model selection (adaptive to
   `llmConfig.allowUserChoice`), agent secrets form, success criteria table, evaluation metrics
   checkboxes, and "Save & Run" / "Save as Draft" buttons.
2. Create `RunDialog.tsx` — modal shown when clicking Run on an already-saved experiment,
   with a model picker if `user-chooses-at-run`.
3. Wire the `createExperiment` mutation on "Save as Draft".
4. Wire the `submitRun` mutation on "Save & Run".
5. After submit, redirect to a run status page and poll `getRun` until the run reaches a terminal state.

---

## Current State Analysis

### What Exists
- `submitRun` and `createExperiment` GraphQL mutations are wired in Stages 05 + 09.
- `web/src/views/ExperimentDashboardV2/` — existing run status display pattern. Reference it
  for the post-submit polling UI.
- `web/src/views/ModelLibrary/` — existing model library UI. Reference it for the model picker
  component pattern.

---

## Pre-Stage Verification

```bash
# 1. submitRun mutation works
curl -s -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { submitRun(projectID: \"proj1\", experimentName: \"test\", agentName: \"flash-agent\") { runID status } }"}' | jq .

# 2. createExperiment mutation works
curl -s -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation { createExperiment(projectID: \"proj1\", input: {name: \"test2\", targetApp: {name: \"sock-shop\", version: \">=1.0.0\"}, modelSelection: {mode: AGENT_DEFAULT}, steps: []}) { name status } }"}' | jq .

# 3. Stage 11 canvas state flows through to wizard state
ls /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/ExperimentCanvas.tsx
```

---

## Implementation Tasks

### Task 1: Create `web/src/views/ChaosStudio/ConfigureAndRun.tsx`

```tsx
import React, { useState } from 'react';
import { useMutation, useQuery } from '@apollo/client';
import { CREATE_EXPERIMENT_MUTATION, SUBMIT_RUN_MUTATION } from '../../api/experiments';
import { GET_AGENT_QUERY } from '../../api/agentRegistry';
import { ChaosStudioWizardState, ExperimentStepDraft } from './index';
import RunDialog from './RunDialog';

interface ConfigureAndRunProps {
  wizardState: Partial<ChaosStudioWizardState>;
  steps: ExperimentStepDraft[];
  onBack: () => void;
  projectID: string;
}

interface PerStepCriteria {
  stepName: string;
  detectWithinSecs: number;
  mitigateWithinSecs: number;
}

const DEFAULT_METRICS = [
  'time_to_detect',
  'time_to_mitigate',
  'tool_call_efficiency',
  'root_cause_accuracy',
  'false_positive_rate',
];

const ConfigureAndRun: React.FC<ConfigureAndRunProps> = ({
  wizardState,
  steps,
  onBack,
  projectID,
}) => {
  const [experimentName, setExperimentName] = useState(
    `${wizardState.selectedAppName ?? 'experiment'}-${Date.now()}`
  );
  const [modelMode, setModelMode] = useState<'agent-default' | 'fixed' | 'user-chooses-at-run'>('agent-default');
  const [fixedModel, setFixedModel] = useState('');
  const [agentSecrets, setAgentSecrets] = useState<Record<string, string>>({});
  const [perStepCriteria, setPerStepCriteria] = useState<PerStepCriteria[]>(
    steps
      .filter(s => s.type === 'fault')
      .map(s => ({
        stepName: s.name,
        detectWithinSecs: 60,
        mitigateWithinSecs: 120,
      }))
  );
  const [selectedMetrics, setSelectedMetrics] = useState<Set<string>>(
    new Set(DEFAULT_METRICS)
  );
  const [showRunDialog, setShowRunDialog] = useState(false);
  const [savedExperimentName, setSavedExperimentName] = useState<string | null>(null);

  // Fetch agent details to check allowUserChoice
  const { data: agentData } = useQuery(GET_AGENT_QUERY, {
    variables: { agentName: wizardState.selectedAgentName },
    skip: !wizardState.selectedAgentName,
  });
  const agent = agentData?.getAgent;
  const allowUserChoice = agent?.llmConfig?.allowUserChoice ?? false;

  const [createExperiment, { loading: creating }] = useMutation(CREATE_EXPERIMENT_MUTATION);
  const [submitRun, { loading: submitting }] = useMutation(SUBMIT_RUN_MUTATION);

  const buildExperimentInput = () => ({
    name: experimentName,
    targetApp: {
      name: wizardState.selectedAppName,
      version: '>=1.0.0',
    },
    agentConstraints: {
      supportedAgents: [wizardState.selectedAgentName],
    },
    modelSelection: {
      mode: modelMode.toUpperCase().replace(/-/g, '_'),
      fixedModel: modelMode === 'fixed' ? fixedModel : null,
    },
    steps: steps.map(s => ({
      name: s.name,
      type: s.type.toUpperCase().replace(/-/g, '_'),
      duration: s.duration,
      faultRef: s.faultRef,
      target: s.targetMicroservice ? { microservice: s.targetMicroservice } : undefined,
      params: s.params ? Object.entries(s.params).map(([k, v]) => ({ key: k, value: v })) : [],
      probe: s.probe,
    })),
    successCriteria: {
      perStep: perStepCriteria,
    },
    evaluationMetrics: Array.from(selectedMetrics),
  });

  const handleSaveDraft = async () => {
    await createExperiment({
      variables: {
        projectID,
        input: buildExperimentInput(),
      },
    });
    setSavedExperimentName(experimentName);
    alert(`Experiment "${experimentName}" saved as draft.`);
  };

  const handleSaveAndRun = async () => {
    // First save the experiment definition
    try {
      await createExperiment({
        variables: { projectID, input: buildExperimentInput() },
      });
      setSavedExperimentName(experimentName);
    } catch (e) {
      // May already exist — proceed to run
    }

    if (allowUserChoice && modelMode === 'user-chooses-at-run') {
      setShowRunDialog(true);
    } else {
      await doSubmitRun(fixedModel || undefined);
    }
  };

  const doSubmitRun = async (modelOverride?: string) => {
    const secrets = Object.entries(agentSecrets).map(([key, value]) => ({ key, value }));
    const { data } = await submitRun({
      variables: {
        projectID,
        experimentName,
        agentName: wizardState.selectedAgentName,
        modelOverride: modelOverride || undefined,
        secretOverrides: secrets,
      },
    });
    const runID = data?.submitRun?.runID;
    if (runID) {
      window.location.href = `/chaos-studio/runs/${runID}`;
    }
  };

  const toggleMetric = (m: string) => {
    const next = new Set(selectedMetrics);
    if (next.has(m)) next.delete(m);
    else next.add(m);
    setSelectedMetrics(next);
  };

  return (
    <div className="configure-and-run-screen">
      <h2>Step 4 of 4: Configure &amp; Run</h2>

      {/* Experiment Name */}
      <div className="config-field">
        <label>Experiment Name</label>
        <input
          type="text"
          value={experimentName}
          onChange={e => setExperimentName(e.target.value)}
          placeholder="e.g. sock-shop-pod-failure-cascade"
        />
      </div>

      {/* Model Selection */}
      <div className="config-section">
        <h4>LLM Model</h4>
        {!allowUserChoice ? (
          <p className="model-fixed-note">
            Model: <strong>{agent?.llmConfig?.defaultModel ?? '(fixed by agent)'}</strong>
            &nbsp;·&nbsp;{agent?.llmConfig?.configRef ?? 'agent default'}
            &nbsp;<a href="/model-library">(Change model config ↗)</a>
          </p>
        ) : (
          <div className="model-select-options">
            <label>
              <input
                type="radio"
                value="agent-default"
                checked={modelMode === 'agent-default'}
                onChange={() => setModelMode('agent-default')}
              />
              Use agent default model
            </label>
            <label>
              <input
                type="radio"
                value="fixed"
                checked={modelMode === 'fixed'}
                onChange={() => setModelMode('fixed')}
              />
              Fix for this experiment:
              <select
                value={fixedModel}
                onChange={e => setFixedModel(e.target.value)}
                disabled={modelMode !== 'fixed'}
              >
                <option value="">Select model</option>
                {(agent?.llmConfig?.allowedModels ?? []).map((m: string) => (
                  <option key={m} value={m}>{m}</option>
                ))}
              </select>
            </label>
            <label>
              <input
                type="radio"
                value="user-chooses-at-run"
                checked={modelMode === 'user-chooses-at-run'}
                onChange={() => setModelMode('user-chooses-at-run')}
              />
              User chooses at run time
            </label>
          </div>
        )}
      </div>

      {/* Agent Secrets */}
      <div className="config-section">
        <h4>Agent Secrets (for {wizardState.selectedAgentName})</h4>
        {(agent?.requiredSecrets ?? []).map((secretKey: string) => (
          <div className="secret-field" key={secretKey}>
            <label>{secretKey} <span className="required">(required)</span></label>
            <input
              type="password"
              value={agentSecrets[secretKey] ?? ''}
              onChange={e => setAgentSecrets(prev => ({ ...prev, [secretKey]: e.target.value }))}
              placeholder="••••••••••••••••"
            />
          </div>
        ))}
      </div>

      {/* Success Criteria */}
      <div className="config-section">
        <h4>Success Criteria</h4>
        <table className="criteria-table">
          <thead>
            <tr>
              <th>Step</th>
              <th>Detect within (s)</th>
              <th>Mitigate within (s)</th>
            </tr>
          </thead>
          <tbody>
            {perStepCriteria.map((c, i) => (
              <tr key={c.stepName}>
                <td>{c.stepName}</td>
                <td>
                  <input
                    type="number"
                    value={c.detectWithinSecs}
                    onChange={e => {
                      const next = [...perStepCriteria];
                      next[i] = { ...next[i], detectWithinSecs: parseInt(e.target.value) };
                      setPerStepCriteria(next);
                    }}
                  />
                </td>
                <td>
                  <input
                    type="number"
                    value={c.mitigateWithinSecs}
                    onChange={e => {
                      const next = [...perStepCriteria];
                      next[i] = { ...next[i], mitigateWithinSecs: parseInt(e.target.value) };
                      setPerStepCriteria(next);
                    }}
                  />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Evaluation Metrics */}
      <div className="config-section">
        <h4>Evaluation Metrics</h4>
        <div className="metrics-checkboxes">
          {DEFAULT_METRICS.map(m => (
            <label key={m} className="metric-checkbox">
              <input
                type="checkbox"
                checked={selectedMetrics.has(m)}
                onChange={() => toggleMetric(m)}
              />
              {m.replace(/_/g, ' ')}
            </label>
          ))}
        </div>
      </div>

      {/* Action Buttons */}
      <div className="wizard-footer">
        <button onClick={onBack}>← Back</button>
        <button
          onClick={handleSaveDraft}
          disabled={creating || !experimentName}
        >
          Save as Draft
        </button>
        <button
          className="btn-primary"
          onClick={handleSaveAndRun}
          disabled={creating || submitting || !experimentName || steps.length === 0}
        >
          {submitting ? 'Submitting...' : 'Save & Run →'}
        </button>
      </div>

      {/* Run Dialog (model picker for user-chooses-at-run) */}
      {showRunDialog && (
        <RunDialog
          experimentName={experimentName}
          agentName={wizardState.selectedAgentName ?? ''}
          appName={wizardState.selectedAppName ?? ''}
          allowedModels={agent?.llmConfig?.allowedModels ?? []}
          onRun={model => {
            setShowRunDialog(false);
            doSubmitRun(model);
          }}
          onCancel={() => setShowRunDialog(false)}
        />
      )}
    </div>
  );
};

export default ConfigureAndRun;
```

### Task 2: Create `web/src/views/ChaosStudio/RunDialog.tsx`

```tsx
import React, { useState } from 'react';

interface RunDialogProps {
  experimentName: string;
  agentName: string;
  appName: string;
  allowedModels: string[];
  onRun: (selectedModel: string) => void;
  onCancel: () => void;
}

const RunDialog: React.FC<RunDialogProps> = ({
  experimentName,
  agentName,
  appName,
  allowedModels,
  onRun,
  onCancel,
}) => {
  const [selectedModel, setSelectedModel] = useState(allowedModels[0] ?? '');

  return (
    <div className="run-dialog-overlay" role="dialog" aria-modal="true">
      <div className="run-dialog">
        <h3>Run Experiment</h3>
        <table className="run-summary">
          <tbody>
            <tr><td>Experiment</td><td><strong>{experimentName}</strong></td></tr>
            <tr><td>Agent</td><td>{agentName}</td></tr>
            <tr><td>App</td><td>{appName}</td></tr>
          </tbody>
        </table>

        <div className="run-model-picker">
          <label htmlFor="run-model-select">Model</label>
          <select
            id="run-model-select"
            value={selectedModel}
            onChange={e => setSelectedModel(e.target.value)}
          >
            {allowedModels.map(m => (
              <option key={m} value={m}>{m}</option>
            ))}
          </select>
        </div>

        <div className="run-dialog-footer">
          <button onClick={onCancel}>Cancel</button>
          <button
            className="btn-primary"
            onClick={() => onRun(selectedModel)}
            disabled={!selectedModel}
          >
            Start Run →
          </button>
        </div>
      </div>
    </div>
  );
};

export default RunDialog;
```

### Task 3: Add GraphQL Mutation Hooks

Create `web/src/api/experiments.ts`:

```typescript
import { gql } from '@apollo/client';

export const CREATE_EXPERIMENT_MUTATION = gql`
  mutation CreateExperiment($projectID: ID!, $input: AceExperimentInput!) {
    createExperiment(projectID: $projectID, input: $input) {
      name
      version
      status
    }
  }
`;

export const SUBMIT_RUN_MUTATION = gql`
  mutation SubmitRun(
    $projectID: ID!
    $experimentName: String!
    $agentName: String!
    $modelOverride: String
    $secretOverrides: [AceSecretInput!]
    $paramOverrides: [AceParamInput!]
  ) {
    submitRun(
      projectID: $projectID
      experimentName: $experimentName
      agentName: $agentName
      modelOverride: $modelOverride
      secretOverrides: $secretOverrides
      paramOverrides: $paramOverrides
    ) {
      runID
      status
      argoWorkflowName
    }
  }
`;

export const GET_RUN_QUERY = gql`
  query GetRun($projectID: ID!, $runID: String!) {
    getRun(projectID: $projectID, runID: $runID) {
      runID
      status
      definitionName
      agentName
      modelUsed
      modelProvider
      langfuseTraceId
      certifierReportId
      startedAt
      completedAt
      statusHistory {
        status
        timestamp
        reason
      }
    }
  }
`;
```

### Task 4: Wire Screen 4 into `index.tsx`

Replace the Screen 4 placeholder:

```tsx
case 4:
  return (
    <ConfigureAndRun
      wizardState={state}
      steps={state.steps ?? []}
      onBack={() => goToScreen(3)}
      projectID={currentProjectID} // from app context
    />
  );
```

### Task 5: Run Status Polling Page

Create a minimal `web/src/views/ChaosStudio/RunStatusPage.tsx` for the post-submit redirect:

```tsx
import React, { useEffect } from 'react';
import { useParams } from 'react-router-dom';
import { useQuery } from '@apollo/client';
import { GET_RUN_QUERY } from '../../api/experiments';

const TERMINAL_STATUSES = ['COMPLETED', 'FAILED', 'ABORTED'];

const RunStatusPage: React.FC<{ projectID: string }> = ({ projectID }) => {
  const { runID } = useParams<{ runID: string }>();

  const { data, startPolling, stopPolling } = useQuery(GET_RUN_QUERY, {
    variables: { projectID, runID },
    pollInterval: 5000, // poll every 5 seconds
  });

  const run = data?.getRun;
  const isTerminal = run && TERMINAL_STATUSES.includes(run.status);

  useEffect(() => {
    if (isTerminal) stopPolling();
    else startPolling(5000);
  }, [isTerminal]);

  if (!run) return <div>Loading run status...</div>;

  return (
    <div className="run-status-page">
      <h2>Run: {run.runID}</h2>
      <div className={`status-badge status-${run.status.toLowerCase()}`}>{run.status}</div>
      <table>
        <tbody>
          <tr><td>Experiment</td><td>{run.definitionName}</td></tr>
          <tr><td>Agent</td><td>{run.agentName}</td></tr>
          <tr><td>Model</td><td>{run.modelUsed} ({run.modelProvider})</td></tr>
          {run.langfuseTraceId && <tr><td>Langfuse Trace</td><td>{run.langfuseTraceId}</td></tr>}
          {run.certifierReportId && <tr><td>Certifier Report</td><td>{run.certifierReportId}</td></tr>}
        </tbody>
      </table>
      <h4>Status History</h4>
      <ul>
        {run.statusHistory?.map((e: any) => (
          <li key={e.timestamp}>
            [{new Date(e.timestamp).toLocaleTimeString()}] {e.status}
            {e.reason && ` — ${e.reason}`}
          </li>
        ))}
      </ul>
    </div>
  );
};

export default RunStatusPage;
```

Register the route: `/chaos-studio/runs/:runID`.

---

## Verification Criteria

### Must Pass

1. TypeScript compiles without errors.

2. "Save as Draft" calls `createExperiment` and succeeds.

3. "Save & Run" calls `createExperiment` then `submitRun` and redirects to `/chaos-studio/runs/<runID>`.

4. Run status page polls `getRun` every 5 seconds and stops polling when terminal.

5. `RunDialog` renders and sends the user-selected model in `submitRun`.

6. When `allowUserChoice: false`, no model picker is shown on Screen 4.

### Should Pass

7. Required agent secrets are validated before "Save & Run" is enabled (cannot submit with empty required secrets).

8. Success criteria table is pre-populated from the fault catalog's `groundTruth.detectWithinSecs` defaults.

9. "Save as Draft" button is disabled if experiment name is empty.

10. The run status page shows the Langfuse trace ID as a clickable link to the Langfuse UI.

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/web

# TypeScript check
yarn tsc --noEmit

# Unit tests
yarn test --testPathPattern="ChaosStudio" --watchAll=false

# E2E (manual) — full wizard flow
yarn start
# 1. Navigate to http://localhost:3000/chaos-studio/new
# 2. Select sock-shop
# 3. Select flash-agent
# 4. Drag pod-delete to canvas → set target microservice to "carts" → set CHAOS_DURATION to 30
# 5. Click Next → fill experiment name → click Save & Run
# 6. Verify redirect to /chaos-studio/runs/<runID>
# 7. Verify Argo Workflow appears: kubectl get workflows -n litmus
```

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `agent?.llmConfig?.allowUserChoice` is always undefined | Agent GraphQL query doesn't include `llmConfig` in the selection set | Add `llmConfig { allowUserChoice allowedModels defaultModel }` to `GET_AGENT_QUERY` |
| `submitRun` mutation returns "experiment not found" | `createExperiment` failed silently or returned a different name | Wrap both in a try/catch and display error; ensure `savedExperimentName` is set from the mutation response |
| Redirect after `submitRun` happens too fast | Window redirects before the run record is written to MongoDB | Use `navigate()` from React Router instead of `window.location.href`; navigate after the mutation promise resolves |
| RunDialog not shown for `user-chooses-at-run` | `modelMode` state not set correctly | Ensure the radio button's `onChange` sets `'user-chooses-at-run'` not `'USER_CHOOSES_AT_RUN'` |
| Required secrets form fields not rendered | `agent.requiredSecrets` not in the agent GraphQL type | Check the `agent_registry.graphqls` — the field may be named `requiredEnvVars` or `secretInputs` |

---

## Rollback Procedure

```bash
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/ConfigureAndRun.tsx
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/RunDialog.tsx
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/RunStatusPage.tsx
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/api/experiments.ts
git checkout /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/index.tsx
```

---

## Success Criteria

Stage 12 is complete when:
- "Save & Run" produces a Queued run in MongoDB and an Argo Workflow in `litmus` namespace
- Run status page polls and shows the terminal state
- `RunDialog` model picker works when `allowUserChoice: true`
- All four Chaos Studio screens form a coherent, end-to-end wizard flow
- TypeScript compiles without errors

**This is the final stage of the implementation plan. All 12 stages complete.**

---

## Post-Completion: Integration Smoke Test

After all 12 stages, run the full smoke test:

```bash
# 1. Start server
ACE_CATALOG_ROOT=/srv/projects/ace-monorepo/catalog \
  go run ./AgentCert/chaoscenter/graphql/server/ &

# 2. Verify fault catalog
curl -s http://localhost:8080/query -d '{"query":"{listFaults{name scope}}"}' | jq '.data.listFaults | length'
# Expected: >= 5

# 3. Create and submit an experiment
TOKEN=$(curl -s -X POST http://localhost:8080/auth/login \
  -d '{"username":"admin","password":"litmus"}' | jq -r .accessToken)

RUN_ID=$(curl -s -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query":"mutation{submitRun(projectID:\"p1\",experimentName:\"e2e-test\",agentName:\"flash-agent\"){runID}}"}' | \
  jq -r .data.submitRun.runID)
echo "Run ID: $RUN_ID"

# 4. Check Argo Workflow
kubectl get workflows -n litmus | grep "$RUN_ID"

# 5. Wait for terminal state
for i in $(seq 1 30); do
  STATUS=$(curl -s http://localhost:8080/query \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"query\":\"query{getRun(projectID:\\\"p1\\\",runID:\\\"$RUN_ID\\\"){status}}\"}" | \
    jq -r .data.getRun.status)
  echo "Status: $STATUS"
  [[ "$STATUS" == "COMPLETED" || "$STATUS" == "FAILED" ]] && break
  sleep 10
done
```
