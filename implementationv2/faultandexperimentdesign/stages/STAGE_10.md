# Stage 10: Chaos Studio — Screen 1 (Select App) + Screen 2 (Select Agent)

**Phase:** 3 — Chaos Studio  
**Status:** Not Started  
**Estimated Effort:** 1.5 days  
**Date Added:** 2026-07-07  
**Depends On:** Stage 06 (faultsForApp query working)

---

## Objectives

1. Create the four-screen Chaos Studio wizard shell at `web/src/views/ChaosStudio/index.tsx`.
2. Implement Screen 1 — Select App: grid of app cards with domain filter, search, and fault count
   per app (from `faultsForApp` query).
3. Implement Screen 2 — Select Agent: list of agents filtered to those compatible with the selected
   app's domain.
4. Wire the route `/chaos-studio/new` to render the wizard.
5. State flows forward from Screen 1 to Screen 2: selected app is passed as context.

---

## Current State Analysis

### What Exists
- `web/src/views/ChaosStudio/` — directory exists, likely with FaultStudio content.
  Check what's there before adding new files:
  ```bash
  ls /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/
  ```
- `web/src/views/AppsHub/` — pattern for displaying app cards, querying app list.
- `web/src/views/AgentHub/` — pattern for displaying agents.
- `web/src/views/AgentOnboarding/` — wizard pattern (multi-step with state).
- Existing GraphQL queries for apps and agents — check `web/src/api/` or `web/src/gql/`.
- Frontend uses React + TypeScript. Check the bundler/CSS framework:
  ```bash
  head -20 /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/package.json
  ```

### What Is Needed
- `web/src/views/ChaosStudio/index.tsx` — wizard shell
- `web/src/views/ChaosStudio/SelectApp.tsx` — Screen 1
- `web/src/views/ChaosStudio/SelectAgent.tsx` — Screen 2
- GraphQL query hooks for `listApps`, `faultsForApp`, `listAgents`
- Route entry in the router config

---

## Pre-Stage Verification

```bash
# 1. Stage 06 faultsForApp query returns data
curl -s -X POST http://localhost:8080/query \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ faultsForApp(appName: \"sock-shop\") { name } }"}' | jq '.data.faultsForApp | length'
# Expected: >= 4

# 2. Check existing ChaosStudio directory contents
ls /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/

# 3. Check existing app hub component for card pattern
ls /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/AppsHub/

# 4. Check router configuration
grep -rn "ChaosStudio\|chaos-studio" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/ | grep -v ".test." | head -10

# 5. Frontend package.json for UI library
grep "\"@harness\|\"@blueprintjs\|\"antd\|\"chakra" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/package.json | head -5
```

---

## Implementation Tasks

### Task 1: Create `web/src/views/ChaosStudio/index.tsx` (Wizard Shell)

```tsx
import React, { useState } from 'react';
import SelectApp from './SelectApp';
import SelectAgent from './SelectAgent';

// Wizard state shared across screens
export interface ChaosStudioWizardState {
  selectedAppName: string;
  selectedAppDomain: string;
  selectedAgentName: string;
  selectedAgentVersion: string;
}

type WizardScreen = 1 | 2 | 3 | 4;

const ChaosStudioWizard: React.FC = () => {
  const [screen, setScreen] = useState<WizardScreen>(1);
  const [state, setState] = useState<Partial<ChaosStudioWizardState>>({});

  const goToScreen = (n: WizardScreen) => setScreen(n);

  const updateState = (patch: Partial<ChaosStudioWizardState>) =>
    setState(prev => ({ ...prev, ...patch }));

  const renderStep = () => {
    switch (screen) {
      case 1:
        return (
          <SelectApp
            onSelect={(appName, appDomain) => {
              updateState({ selectedAppName: appName, selectedAppDomain: appDomain });
              goToScreen(2);
            }}
          />
        );
      case 2:
        return (
          <SelectAgent
            appName={state.selectedAppName ?? ''}
            appDomain={state.selectedAppDomain ?? ''}
            onBack={() => goToScreen(1)}
            onSelect={(agentName, agentVersion) => {
              updateState({ selectedAgentName: agentName, selectedAgentVersion: agentVersion });
              goToScreen(3);
            }}
          />
        );
      case 3:
        // Stage 11: ExperimentCanvas
        return <div>Screen 3 — Canvas (Stage 11)</div>;
      case 4:
        // Stage 12: ConfigureAndRun
        return <div>Screen 4 — Configure & Run (Stage 12)</div>;
      default:
        return null;
    }
  };

  return (
    <div className="chaos-studio-wizard">
      <div className="wizard-progress">
        <span className={screen >= 1 ? 'active' : ''}>1. Select App</span>
        <span className={screen >= 2 ? 'active' : ''}>2. Select Agent</span>
        <span className={screen >= 3 ? 'active' : ''}>3. Build Experiment</span>
        <span className={screen >= 4 ? 'active' : ''}>4. Configure & Run</span>
      </div>
      <div className="wizard-body">{renderStep()}</div>
    </div>
  );
};

export default ChaosStudioWizard;
```

### Task 2: Create `web/src/views/ChaosStudio/SelectApp.tsx`

```tsx
import React, { useState } from 'react';
import { useQuery } from '@apollo/client';
import { LIST_APPS_QUERY } from '../../api/apps';
import { FAULTS_FOR_APP_QUERY } from '../../api/faultCatalog';

interface AppCardProps {
  appName: string;
  domain: string;
  tier: string;
  onSelect: () => void;
}

// FaultCountBadge fetches fault count for one app card.
const FaultCountBadge: React.FC<{ appName: string }> = ({ appName }) => {
  const { data } = useQuery(FAULTS_FOR_APP_QUERY, {
    variables: { appName },
    fetchPolicy: 'cache-first',
  });
  const count = data?.faultsForApp?.length ?? 0;
  return <span className="fault-count">{count} faults available</span>;
};

const AppCard: React.FC<AppCardProps> = ({ appName, domain, tier, onSelect }) => (
  <div className="app-card" onClick={onSelect}>
    <div className="app-card-header">
      <span className="app-name">{appName}</span>
      {tier === 'official' && <span className="badge-official">★ Official</span>}
    </div>
    <div className="app-domain">{domain}</div>
    <FaultCountBadge appName={appName} />
    <button className="btn-select" onClick={onSelect}>Select</button>
  </div>
);

interface SelectAppProps {
  onSelect: (appName: string, appDomain: string) => void;
}

const SelectApp: React.FC<SelectAppProps> = ({ onSelect }) => {
  const [domainFilter, setDomainFilter] = useState('');
  const [searchTerm, setSearchTerm] = useState('');

  const { data, loading, error } = useQuery(LIST_APPS_QUERY);

  if (loading) return <div>Loading apps...</div>;
  if (error) return <div>Error loading apps: {error.message}</div>;

  const apps = (data?.listApps ?? []).filter((app: any) => {
    if (domainFilter && app.domain !== domainFilter) return false;
    if (searchTerm && !app.name.toLowerCase().includes(searchTerm.toLowerCase())) return false;
    return true;
  });

  const domains = [...new Set((data?.listApps ?? []).map((a: any) => a.domain))];

  return (
    <div className="select-app-screen">
      <h2>Step 1 of 4: Select Application</h2>

      <div className="filters">
        <select
          value={domainFilter}
          onChange={e => setDomainFilter(e.target.value)}
          aria-label="Filter by domain"
        >
          <option value="">All Domains</option>
          {(domains as string[]).map(d => (
            <option key={d} value={d}>{d}</option>
          ))}
        </select>

        <input
          type="text"
          placeholder="Search apps..."
          value={searchTerm}
          onChange={e => setSearchTerm(e.target.value)}
          aria-label="Search applications"
        />
      </div>

      <div className="app-grid">
        {apps.map((app: any) => (
          <AppCard
            key={app.name}
            appName={app.name}
            domain={app.domain}
            tier={app.tier}
            onSelect={() => onSelect(app.name, app.domain)}
          />
        ))}
        {apps.length === 0 && (
          <div className="empty-state">No apps match the current filter.</div>
        )}
      </div>
    </div>
  );
};

export default SelectApp;
```

### Task 3: Create `web/src/views/ChaosStudio/SelectAgent.tsx`

```tsx
import React from 'react';
import { useQuery } from '@apollo/client';
import { LIST_AGENTS_QUERY } from '../../api/agentRegistry';

interface SelectAgentProps {
  appName: string;
  appDomain: string;
  onBack: () => void;
  onSelect: (agentName: string, agentVersion: string) => void;
}

const SelectAgent: React.FC<SelectAgentProps> = ({
  appName,
  appDomain,
  onBack,
  onSelect,
}) => {
  const { data, loading, error } = useQuery(LIST_AGENTS_QUERY);

  if (loading) return <div>Loading agents...</div>;
  if (error) return <div>Error loading agents: {error.message}</div>;

  // Filter agents compatible with the selected app's domain.
  // An agent is compatible if it has no domain restriction, or if its
  // supportedDomains includes appDomain.
  const agents = (data?.listAgents ?? []).filter((agent: any) => {
    if (!agent.supportedDomains || agent.supportedDomains.length === 0) return true;
    return agent.supportedDomains.includes(appDomain);
  });

  return (
    <div className="select-agent-screen">
      <h2>Step 2 of 4: Select Agent</h2>
      <div className="context-info">
        App: <strong>{appName}</strong> ({appDomain})
        — Showing agents compatible with this app&apos;s domain
      </div>

      <div className="agent-list">
        {agents.map((agent: any) => (
          <div key={agent.name} className="agent-row">
            <div className="agent-info">
              <span className="agent-name">{agent.displayName ?? agent.name}</span>
              <span className="agent-version"> v{agent.version}</span>
              <span className="agent-capabilities">
                capabilities: {agent.capabilities?.length ?? 0}
              </span>
              <div className="agent-meta">
                {agent.agentType} · {agent.llmDependent ? 'llm-dependent' : 'rule-based'}
                <span className="compatible-badge"> ✓ Compatible</span>
              </div>
            </div>
            <button
              className="btn-select"
              onClick={() => onSelect(agent.name, agent.version)}
            >
              Select
            </button>
          </div>
        ))}
        {agents.length === 0 && (
          <div className="empty-state">
            No agents are registered for the {appDomain} domain.
            <a href="/agent-onboarding">Register a new agent</a>
          </div>
        )}
      </div>

      <div className="wizard-footer">
        <button onClick={onBack}>← Back</button>
      </div>
    </div>
  );
};

export default SelectAgent;
```

### Task 4: Create GraphQL Query Hooks

Create `web/src/api/faultCatalog.ts`:

```typescript
import { gql } from '@apollo/client';

export const FAULTS_FOR_APP_QUERY = gql`
  query FaultsForApp($appName: String!) {
    faultsForApp(appName: $appName) {
      name
      displayName
      scope
      domain
      targetApp
      tags
      description {
        short
      }
      groundTruth {
        category
        impact
      }
      parameters {
        key
        displayName
        type
        default
        required
      }
    }
  }
`;

export const LIST_FAULTS_QUERY = gql`
  query ListFaults($scope: FaultScope, $domain: String) {
    listFaults(scope: $scope, domain: $domain) {
      name
      displayName
      scope
      domain
      tags
    }
  }
`;
```

### Task 5: Register the Route

Find the router configuration (likely at `web/src/RouteDefinitions.tsx` or similar):

```bash
grep -rn "chaos-studio\|ChaosStudio\|Route\|createBrowserRouter" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/ | grep -v ".test." | head -20
```

Add the new route:
```tsx
{
  path: '/chaos-studio/new',
  element: <ChaosStudioWizard />,
}
```

Add a navigation link from the sidebar or dashboard to `/chaos-studio/new`.

---

## Verification Criteria

### Must Pass

1. Frontend compiles without TypeScript errors:
   ```bash
   cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/web
   yarn tsc --noEmit 2>&1 | tail -20
   ```

2. `/chaos-studio/new` route renders Screen 1 (Select App) in the browser.

3. Screen 1 shows app cards with fault counts from `faultsForApp` query.

4. Clicking an app card advances to Screen 2 (Select Agent).

5. Screen 2 shows agents filtered by the selected app's domain.

6. Clicking an agent in Screen 2 advances to Screen 3 (placeholder div for now).

### Should Pass

7. Domain filter in Screen 1 hides apps from other domains.

8. Search in Screen 1 filters cards by name substring.

9. "Back" button in Screen 2 returns to Screen 1 with the domain filter still applied.

10. Wizard progress indicator highlights the current step.

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/web

# TypeScript check
yarn tsc --noEmit

# Unit tests
yarn test --testPathPattern="ChaosStudio" --watchAll=false

# Start dev server
yarn start
# Navigate to http://localhost:3000/chaos-studio/new
```

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `LIST_APPS_QUERY` import missing | The query doesn't exist yet in `api/apps.ts` | Check `web/src/api/` for existing app list query used by `AppsHub`; reuse or duplicate it |
| `LIST_AGENTS_QUERY` import missing | Agent list query not yet in `api/agentRegistry.ts` | Check `web/src/api/` for existing agent list query used by `AgentHub`; reuse or duplicate |
| Apollo `useQuery` type errors | `data` shape unknown in TypeScript | Generate GraphQL types: `yarn codegen` or add explicit type annotations |
| Route not found | Router config uses a different pattern | Match the existing pattern — may use React Router v5 (`<Switch><Route>`) or v6 (`createBrowserRouter`) |
| `FaultCountBadge` causes N+1 GraphQL queries | One request per app card | Accept this for Stage 10 (small catalog); Stage 11 can batch via `listFaults` with app filter |

---

## Rollback Procedure

```bash
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/index.tsx
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/SelectApp.tsx
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/ChaosStudio/SelectAgent.tsx
rm -f /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/api/faultCatalog.ts
# Revert route changes in router config
git checkout \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/RouteDefinitions.tsx
```

---

## Success Criteria

Stage 10 is complete when:
- Screens 1 and 2 render correctly in the browser without console errors
- App selection advances to Screen 2 with domain context preserved
- Agent selection advances to Screen 3 (placeholder)
- TypeScript compiles without errors

**Next Stage:** Stage 11 — Chaos Studio Screen 3 (Canvas / Fault Sequence Builder)
