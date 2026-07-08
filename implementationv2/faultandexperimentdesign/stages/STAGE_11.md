# Stage 11: Chaos Studio — Screen 3 (Canvas / Fault Sequence Builder)

**Phase:** 3 — Chaos Studio  
**Status:** Not Started  
**Estimated Effort:** 2 days  
**Date Added:** 2026-07-07  
**Depends On:** Stage 10 (Screens 1 and 2 complete, wizard state flowing)

---

## Objectives

1. Create `ExperimentCanvas.tsx` — the main canvas that renders the step sequence as a vertical
   node flow and supports drag-and-drop from the fault library.
2. Create `FaultLibraryPanel.tsx` — left panel showing faults grouped by scope
   (GENERAL / CLOUD-NATIVE / APP-SPECIFIC), using `faultsForApp` results.
3. Create `FaultParameterPanel.tsx` — right-side slide-in panel that renders a form for all
   configurable parameters of a selected fault step.
4. Support adding steps of all five types: observe, fault, verify, wait, parallel-fault.
5. Canvas state (the step list) flows into Screen 4 (Stage 12) for saving.

---

## Current State Analysis

### What Exists
- `web/src/views/ExperimentVisualBuilder/` — existing canvas for the Argo-manifest experiment
  builder. This is a different concept (YAML-first), but the visual rendering patterns (SVG nodes,
  arrows) can be referenced.
- `web/src/views/AddFaultsModal/` — existing modal for adding faults in the classic builder.
  Reference the fault card rendering here.
- The frontend uses React; check for drag-and-drop library:
  ```bash
  grep "dnd\|drag\|@dnd-kit\|react-beautiful-dnd\|react-dnd" \
    /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/package.json
  ```

### What Is Needed
- `web/src/views/ChaosStudio/ExperimentCanvas.tsx`
- `web/src/views/ChaosStudio/FaultLibraryPanel.tsx`
- `web/src/views/ChaosStudio/FaultParameterPanel.tsx`
- A shared step state type (`ExperimentStepDraft`) managed in `index.tsx`
- Drag-and-drop support (either use existing DnD library or implement with HTML5 drag events)

---

## Pre-Stage Verification

```bash
# 1. Stage 10 complete — Screens 1 & 2 render
ls /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/SelectApp.tsx
ls /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/SelectAgent.tsx

# 2. Check for drag-and-drop library
grep "dnd\|drag" /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/package.json

# 3. Check existing visual builder for patterns
ls /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ExperimentVisualBuilder/

# 4. faultsForApp returns data with parameters
curl -s -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ faultsForApp(appName: \"sock-shop\") { name parameters { key displayName type default required } } }"}' | jq '.data.faultsForApp[0]'
```

---

## Implementation Tasks

### Task 1: Define Shared Step Draft Type in `index.tsx`

Extend `ChaosStudioWizardState` in `index.tsx` to hold the canvas step list:

```typescript
// Add to ChaosStudioWizardState in index.tsx:
export interface ExperimentStepDraft {
  id: string;          // client-side UUID for React keys
  name: string;        // user-editable step name
  type: 'observe' | 'fault' | 'verify' | 'wait' | 'parallel-fault';
  duration?: string;   // for observe/wait
  faultRef?: string;   // for fault steps
  targetMicroservice?: string;
  params?: Record<string, string>;
  dependsOn?: string;  // step name (not ID)
  probe?: { url: string; expectedStatus: number };
  parallelFaults?: Array<{
    faultRef: string;
    targetMicroservice: string;
    params?: Record<string, string>;
  }>;
}

// In ChaosStudioWizardState:
steps: ExperimentStepDraft[];
hypothesis: string;
```

Initialize `steps: []` in the wizard state.

### Task 2: Create `web/src/views/ChaosStudio/FaultLibraryPanel.tsx`

```tsx
import React, { useState } from 'react';
import { useQuery } from '@apollo/client';
import { FAULTS_FOR_APP_QUERY } from '../../api/faultCatalog';

interface FaultLibraryPanelProps {
  appName: string;
  onDragStart: (faultName: string) => void;
}

// Fault item in the library — draggable
const FaultLibraryItem: React.FC<{
  fault: { name: string; displayName: string; scope: string };
  onDragStart: () => void;
}> = ({ fault, onDragStart }) => (
  <div
    className="fault-library-item"
    draggable
    onDragStart={onDragStart}
    title={fault.name}
  >
    <span className="fault-dot">○</span>
    <span className="fault-display-name">{fault.displayName ?? fault.name}</span>
  </div>
);

const FaultLibraryPanel: React.FC<FaultLibraryPanelProps> = ({ appName, onDragStart }) => {
  const { data, loading } = useQuery(FAULTS_FOR_APP_QUERY, {
    variables: { appName },
    skip: !appName,
  });

  const faults = data?.faultsForApp ?? [];

  const general = faults.filter((f: any) => f.scope === 'GENERAL');
  const domain = faults.filter((f: any) => f.scope === 'DOMAIN');
  const appSpecific = faults.filter((f: any) => f.scope === 'APP_SPECIFIC');

  if (loading) return <div className="library-panel">Loading faults...</div>;

  return (
    <div className="library-panel">
      <h3>Fault Library</h3>
      <p className="library-hint">Drag a fault to the canvas</p>

      {general.length > 0 && (
        <div className="library-group">
          <div className="library-group-label">GENERAL</div>
          {general.map((f: any) => (
            <FaultLibraryItem
              key={f.name}
              fault={f}
              onDragStart={() => onDragStart(f.name)}
            />
          ))}
        </div>
      )}

      {domain.length > 0 && (
        <div className="library-group">
          <div className="library-group-label">
            {domain[0]?.domain?.toUpperCase() ?? 'DOMAIN'}
          </div>
          {domain.map((f: any) => (
            <FaultLibraryItem
              key={f.name}
              fault={f}
              onDragStart={() => onDragStart(f.name)}
            />
          ))}
        </div>
      )}

      {appSpecific.length > 0 && (
        <div className="library-group">
          <div className="library-group-label">{appName.toUpperCase()} SPECIFIC</div>
          {appSpecific.map((f: any) => (
            <FaultLibraryItem
              key={f.name}
              fault={f}
              onDragStart={() => onDragStart(f.name)}
            />
          ))}
        </div>
      )}

      {/* Non-fault step types */}
      <div className="library-group">
        <div className="library-group-label">STEP TYPES</div>
        {['observe', 'wait', 'verify', 'parallel-fault'].map(type => (
          <FaultLibraryItem
            key={type}
            fault={{ name: type, displayName: type.charAt(0).toUpperCase() + type.slice(1), scope: 'GENERAL' }}
            onDragStart={() => onDragStart(`__type:${type}`)}
          />
        ))}
      </div>
    </div>
  );
};

export default FaultLibraryPanel;
```

### Task 3: Create `web/src/views/ChaosStudio/ExperimentCanvas.tsx`

```tsx
import React, { useRef, useState } from 'react';
import { ExperimentStepDraft } from './index';

interface ExperimentCanvasProps {
  steps: ExperimentStepDraft[];
  selectedStepId: string | null;
  onSelectStep: (id: string | null) => void;
  onAddStep: (step: ExperimentStepDraft) => void;
  onRemoveStep: (id: string) => void;
  onReorderStep: (fromIdx: number, toIdx: number) => void;
  draggedFaultName: string | null;
}

// Returns the label shown on a canvas node.
function stepLabel(step: ExperimentStepDraft): string {
  switch (step.type) {
    case 'observe': return `observe ${step.duration ?? '30s'}`;
    case 'wait':    return `wait ${step.duration ?? '30s'}`;
    case 'fault':   return `${step.faultRef ?? '?'}: ${step.targetMicroservice ?? '?'}`;
    case 'verify':  return `verify: ${step.probe?.url ?? '?'}`;
    case 'parallel-fault': return `parallel (${step.parallelFaults?.length ?? 0} faults)`;
    default: return step.name;
  }
}

function stepColor(type: string): string {
  switch (type) {
    case 'observe': return '#4a90e2';
    case 'fault':   return '#e74c3c';
    case 'verify':  return '#27ae60';
    case 'wait':    return '#f39c12';
    case 'parallel-fault': return '#8e44ad';
    default: return '#95a5a6';
  }
}

const CanvasNode: React.FC<{
  step: ExperimentStepDraft;
  selected: boolean;
  onClick: () => void;
  onDelete: () => void;
}> = ({ step, selected, onClick, onDelete }) => (
  <div
    className={`canvas-node ${selected ? 'selected' : ''}`}
    style={{ borderLeft: `4px solid ${stepColor(step.type)}` }}
    onClick={onClick}
  >
    <span className="node-label">{stepLabel(step)}</span>
    <button
      className="node-delete"
      onClick={e => { e.stopPropagation(); onDelete(); }}
      aria-label="Remove step"
    >
      ×
    </button>
  </div>
);

const ArrowConnector: React.FC = () => (
  <div className="canvas-arrow">↓</div>
);

const ExperimentCanvas: React.FC<ExperimentCanvasProps> = ({
  steps,
  selectedStepId,
  onSelectStep,
  onAddStep,
  onRemoveStep,
  onReorderStep,
  draggedFaultName,
}) => {
  const canvasRef = useRef<HTMLDivElement>(null);
  const [dropTarget, setDropTarget] = useState<number | null>(null);

  const handleDrop = (e: React.DragEvent, insertAtIndex: number) => {
    e.preventDefault();
    setDropTarget(null);

    if (!draggedFaultName) return;

    // Determine step type from dragged item
    let newStep: ExperimentStepDraft;
    const id = `step-${Date.now()}`;

    if (draggedFaultName.startsWith('__type:')) {
      const type = draggedFaultName.replace('__type:', '') as ExperimentStepDraft['type'];
      newStep = {
        id,
        name: `${type}-${steps.length + 1}`,
        type,
        duration: type === 'observe' || type === 'wait' ? '30s' : undefined,
      };
    } else {
      newStep = {
        id,
        name: `inject-${draggedFaultName}-${steps.length + 1}`,
        type: 'fault',
        faultRef: draggedFaultName,
        targetMicroservice: '',
        params: {},
      };
    }

    onAddStep(newStep);
  };

  return (
    <div
      ref={canvasRef}
      className="experiment-canvas"
      onDragOver={e => e.preventDefault()}
    >
      {steps.length === 0 && (
        <div
          className="canvas-empty-drop-zone"
          onDrop={e => handleDrop(e, 0)}
          onDragOver={e => { e.preventDefault(); setDropTarget(0); }}
          onDragLeave={() => setDropTarget(null)}
        >
          Drag a fault from the library to add it here
        </div>
      )}

      {steps.map((step, idx) => (
        <React.Fragment key={step.id}>
          <CanvasNode
            step={step}
            selected={selectedStepId === step.id}
            onClick={() => onSelectStep(step.id)}
            onDelete={() => onRemoveStep(step.id)}
          />
          {idx < steps.length - 1 && <ArrowConnector />}
        </React.Fragment>
      ))}

      {steps.length > 0 && (
        <div
          className="canvas-drop-zone"
          onDrop={e => handleDrop(e, steps.length)}
          onDragOver={e => { e.preventDefault(); setDropTarget(steps.length); }}
          onDragLeave={() => setDropTarget(null)}
          style={{ opacity: dropTarget === steps.length ? 1 : 0.3 }}
        >
          + Drop here to add a step
        </div>
      )}
    </div>
  );
};

export default ExperimentCanvas;
```

### Task 4: Create `web/src/views/ChaosStudio/FaultParameterPanel.tsx`

```tsx
import React from 'react';
import { useQuery } from '@apollo/client';
import { GET_FAULT_QUERY } from '../../api/faultCatalog';
import { ExperimentStepDraft } from './index';

interface FaultParameterPanelProps {
  step: ExperimentStepDraft | null;
  allMicroservices: string[]; // from app.yaml microservices[].name
  onChange: (stepId: string, patch: Partial<ExperimentStepDraft>) => void;
}

const FaultParameterPanel: React.FC<FaultParameterPanelProps> = ({
  step,
  allMicroservices,
  onChange,
}) => {
  const { data } = useQuery(GET_FAULT_QUERY, {
    variables: { name: step?.faultRef },
    skip: !step?.faultRef,
  });

  if (!step) return null;

  const fault = data?.getFault;
  const parameters = fault?.parameters ?? [];

  const updateParam = (key: string, value: string) => {
    onChange(step.id, {
      params: { ...(step.params ?? {}), [key]: value },
    });
  };

  return (
    <div className="parameter-panel">
      <h3>{fault?.displayName ?? step.name}</h3>
      {fault && <p className="fault-description">{fault.description?.short}</p>}

      {/* Target microservice selector (for fault steps) */}
      {step.type === 'fault' && (
        <div className="param-field">
          <label>Target Microservice</label>
          <select
            value={step.targetMicroservice ?? ''}
            onChange={e => onChange(step.id, { targetMicroservice: e.target.value })}
          >
            <option value="">Select a microservice</option>
            {allMicroservices.map(ms => (
              <option key={ms} value={ms}>{ms}</option>
            ))}
          </select>
        </div>
      )}

      {/* Duration field for observe/wait steps */}
      {(step.type === 'observe' || step.type === 'wait') && (
        <div className="param-field">
          <label>Duration</label>
          <input
            type="text"
            value={step.duration ?? '30s'}
            onChange={e => onChange(step.id, { duration: e.target.value })}
            placeholder="e.g. 30s, 2m"
          />
        </div>
      )}

      {/* Probe URL for verify steps */}
      {step.type === 'verify' && (
        <>
          <div className="param-field">
            <label>Probe URL</label>
            <input
              type="text"
              value={step.probe?.url ?? ''}
              onChange={e => onChange(step.id, {
                probe: { ...(step.probe ?? { expectedStatus: 200 }), url: e.target.value },
              })}
              placeholder="http://front-end.sock-shop.svc.cluster.local:80"
            />
          </div>
          <div className="param-field">
            <label>Expected HTTP Status</label>
            <input
              type="number"
              value={step.probe?.expectedStatus ?? 200}
              onChange={e => onChange(step.id, {
                probe: { ...(step.probe ?? { url: '' }), expectedStatus: parseInt(e.target.value) },
              })}
            />
          </div>
        </>
      )}

      {/* Fault parameters from fault.yaml */}
      {parameters.map((param: any) => (
        <div className="param-field" key={param.key}>
          <label>
            {param.displayName}
            {param.required && <span className="required">*</span>}
          </label>
          {param.type === 'boolean' ? (
            <input
              type="checkbox"
              checked={(step.params?.[param.key] ?? param.default) === 'true'}
              onChange={e => updateParam(param.key, e.target.checked ? 'true' : 'false')}
            />
          ) : param.type === 'enum' && param.allowedValues ? (
            <select
              value={step.params?.[param.key] ?? param.default}
              onChange={e => updateParam(param.key, e.target.value)}
            >
              {param.allowedValues.map((v: string) => (
                <option key={v} value={v}>{v}</option>
              ))}
            </select>
          ) : (
            <input
              type={param.type === 'integer' || param.type === 'percent' ? 'number' : 'text'}
              value={step.params?.[param.key] ?? param.default}
              min={param.min}
              max={param.max}
              onChange={e => updateParam(param.key, e.target.value)}
            />
          )}
          <small className="param-description">{param.description}</small>
        </div>
      ))}

      {/* Step name editor */}
      <div className="param-field">
        <label>Step Name</label>
        <input
          type="text"
          value={step.name}
          onChange={e => onChange(step.id, { name: e.target.value })}
        />
      </div>
    </div>
  );
};

export default FaultParameterPanel;
```

Add `GET_FAULT_QUERY` to `web/src/api/faultCatalog.ts`:

```typescript
export const GET_FAULT_QUERY = gql`
  query GetFault($name: String!) {
    getFault(name: $name) {
      name
      displayName
      description { short }
      parameters {
        key
        displayName
        type
        default
        min
        max
        required
        description
        allowedValues
      }
    }
  }
`;
```

### Task 5: Wire Screen 3 into `index.tsx`

Replace the Screen 3 placeholder in `index.tsx` with:

```tsx
case 3:
  return (
    <div className="screen-3">
      <h2>Step 3 of 4: Build Experiment</h2>
      <div className="context-bar">
        App: <strong>{state.selectedAppName}</strong> |
        Agent: <strong>{state.selectedAgentName}</strong>
      </div>
      <div className="canvas-layout">
        <FaultLibraryPanel
          appName={state.selectedAppName ?? ''}
          onDragStart={setDraggedFault}
        />
        <div className="canvas-center">
          <ExperimentCanvas
            steps={state.steps ?? []}
            selectedStepId={selectedStepId}
            onSelectStep={setSelectedStepId}
            onAddStep={step => updateState({ steps: [...(state.steps ?? []), step] })}
            onRemoveStep={id => updateState({
              steps: (state.steps ?? []).filter(s => s.id !== id)
            })}
            onReorderStep={(from, to) => {/* reorder logic */}}
            draggedFaultName={draggedFault}
          />
        </div>
        <FaultParameterPanel
          step={(state.steps ?? []).find(s => s.id === selectedStepId) ?? null}
          allMicroservices={appMicroservices}
          onChange={(id, patch) => updateState({
            steps: (state.steps ?? []).map(s => s.id === id ? { ...s, ...patch } : s)
          })}
        />
      </div>
      <div className="wizard-footer">
        <button onClick={() => goToScreen(2)}>← Back</button>
        <button onClick={() => goToScreen(4)} disabled={(state.steps ?? []).length === 0}>
          Next →
        </button>
      </div>
    </div>
  );
```

---

## Verification Criteria

### Must Pass

1. TypeScript compiles without errors.

2. Dragging `pod-delete` from the library and dropping on the canvas adds a fault node.

3. Clicking a fault node on the canvas opens the parameter panel with the correct fields.

4. Changing a parameter value in the panel updates the step in state.

5. "Next" button is disabled when the step list is empty.

6. Removing a node from the canvas removes it from state.

### Should Pass

7. Fault nodes are color-coded by type (red for fault, blue for observe, etc.).

8. The fault library shows faults grouped by GENERAL / DOMAIN / APP-SPECIFIC.

9. The parameter panel shows the `short` description from the fault catalog.

10. The canvas renders correctly with 10 steps (performance sanity check).

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/web

# TypeScript check
yarn tsc --noEmit

# Unit tests
yarn test --testPathPattern="ChaosStudio/Experiment" --watchAll=false

# Visual test in browser
yarn start
# Navigate to http://localhost:3000/chaos-studio/new
# Select sock-shop → flash-agent → drag pod-delete to canvas → click it
```

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Drag events don't fire | `draggable` attribute missing or browser default prevented | Ensure `draggable={true}` and `onDragStart` calls `e.dataTransfer.setData("text", faultName)` |
| Canvas drop zone doesn't receive drops | Missing `onDragOver={e => e.preventDefault()}` | Without `preventDefault()` on dragOver, the drop event never fires |
| `getFault` query fires on every render | `useQuery` in `FaultParameterPanel` with no skip | Add `skip: !step?.faultRef` to avoid the query when no fault step is selected |
| Parameter panel fields not showing | `fault.parameters` is empty | Check that the `getFault` query includes the `parameters` selection set; gqlgen must return the nested array |
| Microservices list empty | `allMicroservices` prop not populated | `index.tsx` must fetch the app's microservice list from `apps_registry` query when app is selected |

---

## Rollback Procedure

```bash
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/ExperimentCanvas.tsx
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/FaultLibraryPanel.tsx
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/FaultParameterPanel.tsx
# Revert wizard screen 3 in index.tsx
git checkout /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/index.tsx
```

---

## Success Criteria

Stage 11 is complete when:
- Dragging a fault from the library adds it to the canvas as a node
- Clicking a node opens the parameter panel with correct fields
- Editing parameters updates the wizard state
- All five step types can be added to the canvas
- TypeScript compiles without errors

**Next Stage:** Stage 12 — Chaos Studio Screen 4 (Configure & Run)
