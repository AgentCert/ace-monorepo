# Stage 5: Registration Wizard Frontend (7 Steps)

**Phase:** 3 — Registration Wizard  
**Dependencies:** Stage 4 complete (ModelConfigDialog must be importable)  
**Risk Level:** Medium — complex multi-step form with state management

---

## Objectives

1. Replace/extend `views/AgentOnboarding/AgentOnboarding.tsx` with a 7-step registration wizard
2. The existing Helm-deploy path becomes the "Advanced Register" path (Step 2 variant)
3. Implement all 7 steps from spec §9
4. Wire to `registerAgent` mutation on final step

---

## Current State Analysis

### What We Have
- `views/AgentOnboarding/AgentOnboarding.tsx` — existing Helm-deploy agent management page
  - Shows agent list + "Deploy Agent" Helm form
  - Must be **preserved** as the Advanced Register path

### What We Need
- Entry point: "Register Agent" button → Method Selection Screen (Quick vs Advanced)
- Quick Register: 7-step wizard → calls `registerAgent` mutation
- Advanced Register: existing Helm form (already works via `DeployAgentWithHelm`)
- After registration: agent appears in the agent list

---

## Pre-Stage Verification

```bash
# Confirm existing page renders
cd AgentCert/chaoscenter/web && yarn tsc --noEmit

# Check what strings are registered (for i18n compliance)
grep -r "registerAgent\|agentOnboarding" \
  AgentCert/chaoscenter/web/src/strings/ | head -10
```

---

## Implementation Tasks

### Task 1: Create Wizard Directory Structure

**Files to Create:**

```
web/src/views/AgentOnboarding/
├── AgentOnboarding.tsx          (MODIFY — add "Register Agent" button → method selection)
├── wizard/
│   ├── AgentRegistrationWizard.tsx    (wizard shell: progress bar + step routing)
│   ├── MethodSelectionScreen.tsx      (Quick vs Advanced choice)
│   ├── Step1Identity.tsx
│   ├── Step2DockerImage.tsx           (Quick Register)
│   ├── Step2HelmChart.tsx             (Advanced Register — wires existing Helm form)
│   ├── Step3LLMConfig.tsx             (uses ModelConfigDialog)
│   ├── Step4ConfigInputs.tsx
│   ├── Step5CapabilitiesTools.tsx
│   ├── Step6AppCompatibility.tsx
│   ├── Step7Review.tsx
│   ├── types.ts                       (shared wizard form state types)
│   └── index.ts
```

---

### Task 2: Wizard Shell — `AgentRegistrationWizard.tsx`

**Objective:** Multi-step shell with progress indicator, Back/Next navigation, and shared form state.

**State shape:**

```typescript
interface WizardState {
  // Step 1
  agentName: string;
  displayName: string;
  shortDescription: string;
  fullDescription: string;
  approach: string;            // react-loop | plan-and-execute | chain-of-thought | rule-based | custom
  ownerName: string;
  ownerEmail: string;
  ownerOrg: string;
  repositoryURL: string;
  tags: string[];

  // Step 2 (Quick Register)
  dockerImage: string;
  commandOverride: string[];
  commandArgs: string[];
  cpuRequest: string;
  memoryRequest: string;
  cpuLimit: string;
  memoryLimit: string;

  // Step 3
  llmDependent: boolean;        // if false, skip Step 3
  selectedModelAlias: string;   // from Model Library
  inlineLLMProvider: string;    // if inline config
  inlineLLMModel: string;
  inlineLLMApiKey: string;
  inlineLLMBaseURL: string;
  saveAsAlias: string;
  allowUserChoice: boolean;
  allowedModels: string[];
  defaultModel: string;

  // Step 4
  inputs: AgentInputDefinition[];

  // Step 5
  capabilities: string[];
  requiredTools: RequiredToolInput[];
  evaluationMetrics: string[];

  // Step 6
  compatibilityMode: 'all' | 'specify';
  supportedApps: string[];
  unsupportedApps: string[];

  // Step 7 (review only, no additional data)
  registrationMode: 'private' | 'community';
}
```

The shell renders a stepper and the active step component. Back/Next buttons are always in the shell footer, not in individual step components.

---

### Task 3: Step 1 — Identity (`Step1Identity.tsx`)

Fields from spec §9, Step 1:

| Field | Validation |
|-------|------------|
| Agent Name | `^[a-z0-9][a-z0-9-]*[a-z0-9]$`, max 63 chars; uniqueness check on blur (call `listAgents` and check) |
| Display Name | 1–80 chars |
| Short Description | 10–120 chars |
| Full Description | Markdown textarea, 50–5000 chars |
| Reasoning Approach | Select dropdown |
| Owner Name | required |
| Owner Email | valid email |
| Organization | optional |
| Repository URL | optional, URL validation |
| Tags | Tag input (comma-separated or Enter-to-add) |

---

### Task 4: Step 2 — Docker Image (`Step2DockerImage.tsx`)

Fields from spec §9, Step 2:

| Field | Notes |
|-------|-------|
| Docker Image | non-empty; `:latest` warning (yellow, non-blocking) |
| Command Override | Optional, array of strings |
| Command Args | Optional, array of strings |
| CPU/Memory Request/Limit | K8s quantity format; defaults shown |

**`:latest` warning banner:**
> "⚠ Using `:latest` means different versions of your agent may run at different times. We recommend pinning to a specific version for reproducible certification results."

---

### Task 5: Step 3 — LLM Configuration (`Step3LLMConfig.tsx`)

**If `llmDependent: false`:** Skip this step entirely (do not render it in the stepper).

**Two-panel layout:**

**Panel A — Use a saved model:**
- Dropdown of existing Model Library configs for this project (from `listModelConfigs`)
- `[+ Save new model config]` button → opens `ModelConfigDialog` inline/modal

**Panel B — Configure inline:**
- Provider dropdown → triggers model list in Model field
- Model dropdown + "Custom model name" text input
- API Key (password field with show/hide)
- Base URL (shown conditionally)
- `[Test Connection]` button
- `[Save as _____ ]` checkbox + alias text input

**Model flexibility section:**
- Radio: `● Fixed` / `○ User chooses at run time`
- If "User chooses": multi-select checklist of `allowedModels` + default model select

Reuses `ModelConfigDialog` component from Stage 4.

---

### Task 6: Step 4 — Configuration Inputs (`Step4ConfigInputs.tsx`)

Dynamic table where each row is an `AgentInputDefinition`. Users click `[+ Add Parameter]` to add rows.

Per row:
- Parameter Name (env var format `ALL_CAPS_UNDERSCORES`, auto-uppercased from key)
- Display Name
- Type: `secret | string | integer | boolean | enum`
- Required toggle
- Default Value (disabled for `type: secret`)
- Description
- Group (optional)
- Advanced toggle

Note banner: "LLM API keys are configured in Step 3. This step is for other secrets your agent needs — PagerDuty tokens, JIRA API keys, monitoring credentials."

---

### Task 7: Step 5 — Capabilities & Tools (`Step5CapabilitiesTools.tsx`)

**Panel A: Capabilities** (spec §9 Step 5, capability picker):

- Load capabilities from `getAgentCapabilitiesTaxonomy`
- Group by domain then Observe/Act
- Checkbox list with description as inline help text

**Panel B: Required Tools (MCP)**

Table of tools with columns: Tool Name | Critical | Max Calls | (delete)

`[Import from MCP server URL]` → text input + `[Import]` button → calls `importMCPTools` mutation → pre-fills table.

`[+ Add Tool]` button for manual entry.

**Panel C: Evaluation Metrics**

Checkbox list of the 7 metrics from spec §9 Step 5:
- `time_to_detect`, `time_to_mitigate`, `tool_call_efficiency`, `root_cause_accuracy`, `remediation_correctness`, `false_positive_rate`, `blast_radius`

With one-line descriptions from the spec.

---

### Task 8: Step 6 — App Compatibility (`Step6AppCompatibility.tsx`)

Radio group:
- `○ Compatible with all catalog apps (default)`
- `○ Specify compatibility`

If "Specify":
- "Compatible with" multi-checkbox (apps from `listApps` or static list from catalog)
- "Mark as incompatible with" multi-checkbox with note about service-mesh capability

---

### Task 9: Step 7 — Review & Register (`Step7Review.tsx`)

Summary panel showing:
- Agent name + version + image
- Capabilities count, tools count, metrics count, inputs count

Radio: `○ Private` / `○ Contribute to community catalog`

`[Register Agent]` button → calls `registerAgent` mutation with full wizard state.

On success: navigate to agent detail page or back to agent list with success toast.

---

### Task 10: Update `AgentOnboarding.tsx`

Add `[Register Agent]` button at top of the existing list page.
Clicking it opens the `MethodSelectionScreen` modal/page.

The method selection screen (spec §7.2):
- Quick Register card → navigates to 7-step wizard
- Advanced Register card → shows existing Helm form (or navigates to existing deploy flow)

The agent list below the button is unchanged.

---

## Files to Create (Summary)

```
web/src/views/AgentOnboarding/wizard/
├── AgentRegistrationWizard.tsx
├── MethodSelectionScreen.tsx
├── Step1Identity.tsx
├── Step2DockerImage.tsx
├── Step2HelmChart.tsx
├── Step3LLMConfig.tsx
├── Step4ConfigInputs.tsx
├── Step5CapabilitiesTools.tsx
├── Step6AppCompatibility.tsx
├── Step7Review.tsx
├── types.ts
└── index.ts
```

## Files to Modify

- `web/src/views/AgentOnboarding/AgentOnboarding.tsx` — add Register Agent button + modal

---

## Verification Criteria

### Must Pass
- [ ] `yarn tsc --noEmit` passes
- [ ] 7-step stepper renders; Back/Next navigation works
- [ ] Step 3 skipped when `llmDependent: false`
- [ ] `registerAgent` mutation called with correct input on Step 7 submit
- [ ] Success toast and redirect to agent list on registration

### Should Pass
- [ ] Agent Name uniqueness check on blur in Step 1
- [ ] `:latest` warning shown in Step 2
- [ ] Capabilities loaded from `getAgentCapabilitiesTaxonomy` in Step 5
- [ ] MCP Import fills the tools table in Step 5

---

## Testing Commands

```bash
cd AgentCert/chaoscenter/web
yarn tsc --noEmit
# Start dev server, navigate to Agents, click Register Agent
# Walk through all 7 steps with test data
```

---

## Success Criteria

Stage 5 is complete when:
1. Full 7-step wizard is navigable
2. `registerAgent` mutation is called with the spec-aligned input on final step
3. Registered agent appears in the agent list

## Next Stage

Proceed to: **Stage 6: ImportMCPTools + agent.yaml Generation**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
