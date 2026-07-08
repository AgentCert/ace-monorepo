# Stage 4: Model Library Frontend

**Phase:** 2 — Model Library  
**Dependencies:** Stage 3 complete  
**Risk Level:** Low

---

## Objectives

1. Create the **Settings > Model Library** screen (spec §26)
2. Create the **Add Model / Edit Model dialog** (reused in Step 3 of the wizard)
3. Implement **Test Connection** button flow
4. Implement **Rotate Key** flow
5. Export the Model Library form as a reusable component for the registration wizard's Step 3

---

## Current State Analysis

### What We Have
- `web/src/views/AccountSettings/` — settings layout already exists
- `web/src/api/core/agents/` — agent GraphQL query hooks
- No model library API hooks, no model library views

### What We Need
- `web/src/api/core/modelLibrary/` — GraphQL hooks for Model Library mutations/queries
- `web/src/views/ModelLibrary/` — the Settings screen
- `web/src/components/ModelConfigDialog/` — reusable Add/Edit dialog (also used in wizard Step 3)
- Route: `Settings > Model Library`

---

## Pre-Stage Verification

```bash
# Frontend builds cleanly before we start
cd AgentCert/chaoscenter/web && yarn tsc --noEmit
```

---

## Implementation Tasks

### Task 1: Create GraphQL API Hooks

**Files to Create:**
- `web/src/api/core/modelLibrary/listModelConfigs.ts`
- `web/src/api/core/modelLibrary/getModelConfig.ts`
- `web/src/api/core/modelLibrary/createModelConfig.ts`
- `web/src/api/core/modelLibrary/updateModelConfig.ts`
- `web/src/api/core/modelLibrary/deleteModelConfig.ts`
- `web/src/api/core/modelLibrary/testModelConfig.ts`
- `web/src/api/core/modelLibrary/rotateModelConfigKey.ts`
- `web/src/api/core/modelLibrary/index.ts`

Follow the pattern in `web/src/api/core/agents/listAgents.ts` — define the GQL document and
export a typed hook using the project's Apollo wrapper (`useQuery`/`useMutation`).

**Key types (mirror the backend GraphQL types):**

```typescript
export interface ModelConfig {
  alias: string;
  provider: string;
  model: string;
  baseURL?: string;
  secretRef: string;
  agentsUsing: string[];
  status: string;
  lastTested?: string;
}

export interface ModelConfigInput {
  alias: string;
  provider: string;
  model: string;
  baseURL?: string;
  apiKey: string;   // write-only, never returned
}

export interface ModelConfigTestResult {
  success: boolean;
  latencyMs?: number;
  errorMessage?: string;
}
```

---

### Task 2: Create `ModelLibrary` Settings Screen

**Files to Create:**
- `web/src/views/ModelLibrary/ModelLibrary.tsx`
- `web/src/views/ModelLibrary/ModelLibrary.module.scss`
- `web/src/views/ModelLibrary/index.ts`

**Screen layout (from spec §26.1):**

```
ACE > Settings > Model Library               [+ Add Model]

┌─────────────────────────────────────────────────────┐
│  ALIAS        PROVIDER  MODEL           AGENTS  STATUS │
│  ──────────────────────────────────────────────────── │
│  my-openai… OpenAI    gpt-4o           3       ✓     │
│  my-anthro… Anthropic claude-3-5-son. 1       ✓     │
└─────────────────────────────────────────────────────┘

ℹ API keys are stored as K8s Secrets in the litmus namespace.
  ACE never stores keys in plain text or returns them via API.
```

Clicking a row expands an inline details panel with:
- Provider + model, last tested timestamp + latency
- Agents using this config (as chips)
- `[Test Connection]` button
- `[Rotate Key]` button → inline prompt for new key
- `[Delete]` button (disabled + tooltip if `agentsUsing.length > 0`)

Use `TableV2` from `@harnessio/uicore` matching the pattern in `AgentOnboarding.tsx`.

---

### Task 3: Create `ModelConfigDialog` Reusable Component

**Files to Create:**
- `web/src/components/ModelConfigDialog/ModelConfigDialog.tsx`
- `web/src/components/ModelConfigDialog/ModelConfigDialog.module.scss`
- `web/src/components/ModelConfigDialog/index.ts`

**Props:**

```typescript
interface ModelConfigDialogProps {
  isOpen: boolean;
  onClose: () => void;
  onSaved: (config: ModelConfig) => void;
  initialValues?: Partial<ModelConfigInput>;  // for Edit mode
  mode: 'add' | 'edit';
}
```

**Form fields (from spec §26.2 / Step 3):**

| Field | Component |
|-------|-----------|
| Alias | `TextInput` — required, disabled in edit mode |
| Provider | `Select` — OpenAI, Anthropic, Google, Azure, Ollama, Custom |
| Model | `Select` (provider-specific models) + "Custom" text input option |
| API Key | `TextInput` type=password with show/hide toggle |
| Base URL | `TextInput` — shown when provider ≠ OpenAI/Anthropic/Google; shown always for Azure/Ollama/Custom |

**Test Connection button:**
1. Calls `testModelConfig` mutation with current form values (before saving)
2. Shows spinner during call
3. On success: shows `✓ <model> responded in <latencyMs>ms` in green
4. On failure: shows error message in red
5. Save button is disabled until Test Connection passes at least once

**Save button:** Calls `createModelConfig` or `updateModelConfig`.

**Provider-specific model lists:**

```typescript
const PROVIDER_MODELS: Record<string, string[]> = {
  openai:    ['gpt-4o', 'gpt-4o-mini', 'gpt-4-turbo', 'o1', 'o1-mini'],
  anthropic: ['claude-3-5-sonnet-20241022', 'claude-3-5-haiku-20241022', 'claude-opus-4-8'],
  google:    ['gemini-1.5-pro', 'gemini-1.5-flash', 'gemini-2.0-flash'],
  azure:     [],  // free text — user enters deployment name
  ollama:    [],  // free text
  custom:    [],  // free text
};
```

---

### Task 4: Add Model Library Route

**File to Modify:** `web/src/routes/` (or wherever AccountSettings routes are defined)

Add `ModelLibrary` as a sub-route under Settings:

```
/account/<accountID>/settings/model-library
```

Add a link in the AccountSettings sidebar/nav.

---

### Task 5: Rotate Key Dialog

Within the expanded row (or as a separate `RotateKeyDialog` component):

```
Rotate API Key for "my-openai-gpt4o"

New API Key  [sk-•••••••••••••••••]  👁

[Test new key before saving]  → ✓ gpt-4o responded in 312ms

[Cancel]                              [Rotate Key]
```

Calls `rotateModelConfigKey(projectID, alias, newApiKey)` mutation.
Test Connection is required before Rotate Key is enabled (same UX as Add Model).

---

## Files to Create (Summary)

```
web/src/api/core/modelLibrary/
├── listModelConfigs.ts
├── getModelConfig.ts
├── createModelConfig.ts
├── updateModelConfig.ts
├── deleteModelConfig.ts
├── testModelConfig.ts
├── rotateModelConfigKey.ts
└── index.ts

web/src/views/ModelLibrary/
├── ModelLibrary.tsx
├── ModelLibrary.module.scss
└── index.ts

web/src/components/ModelConfigDialog/
├── ModelConfigDialog.tsx
├── ModelConfigDialog.module.scss
└── index.ts
```

## Files to Modify

- `web/src/routes/` — add Model Library route
- AccountSettings sidebar — add "Model Library" link

---

## Verification Criteria

### Must Pass
- [ ] `yarn tsc --noEmit` passes
- [ ] Model Library screen renders at the route URL
- [ ] Add Model dialog opens, validates required fields, and shows Test Connection button
- [ ] Test Connection calls `testModelConfig` mutation and shows latency on success
- [ ] Saved model appears in the table
- [ ] Delete is disabled when `agentsUsing` is non-empty

### Should Pass
- [ ] Rotate Key dialog updates the Secret without changing the alias
- [ ] `[Open LiteLLM Dashboard ↗]` link navigates to LiteLLM UI

---

## Testing Commands

```bash
cd AgentCert/chaoscenter/web
yarn tsc --noEmit
# Start dev server and navigate to Settings > Model Library
```

---

## Success Criteria

Stage 4 is complete when:
1. Model Library screen is accessible from Settings
2. Full CRUD works in the UI (add, test, rotate key, delete)
3. `ModelConfigDialog` is exported and ready to import in the wizard Step 3

## Next Stage

Proceed to: **Stage 5: Registration Wizard Frontend**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
