# Stage 08: App Detail Panel (suitableFor, faultCompatibility, inputs)

**Phase:** 2 — Frontend Catalog Browser  
**Dependencies:** Stage 07  
**Risk Level:** Low

---

## Objectives

1. Replace `AppDetail.tsx` to show the full spec (spec §6.2 detail panel)
2. Display `suitableFor` / `notSuitableFor` with ✅/❌ icons
3. Display fault compatibility table
4. Display microservices list with K8s label and criticality
5. Display configurable install inputs form (standard + Advanced toggle) per spec §6.3

---

## Current State Analysis

### What We Have
- `views/AppDetail/AppDetail.tsx` — uses `AppHubEntry` categories from `listAppHubCategories`
- `views/AppDetail/AppDetail.module.scss` — basic styling
- `views/AppDetail/index.ts` — exports the view
- The container that provides data to `AppDetail` — needs to switch to `getApplication`

### What We Need
- `AppDetail` rewritten to use `ApplicationSpec` from `getApplication` query
- `suitableFor[]` shown as green ✅ bullets
- `notSuitableFor[]` shown as red ❌ bullets
- `microservices[]` table with name, K8s label, kind, criticality
- `faultCompatibility[]` table with compatible/incompatible indicator
- `inputs[]` form: standard inputs visible, advanced inputs under collapsible toggle
- "Select This App →" button that proceeds to experiment creation
- "View Documentation" button (links to docs/README.md if available)

---

## Pre-Stage Verification

```bash
# Current AppDetail container
grep -rn "AppDetail\|getApplication\|appName" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/pages \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/app \
  --include="*.tsx" | head -10

# Check existing AppDetail module
cat /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/AppDetail/AppDetail.tsx | head -30
```

---

## Implementation Tasks

### Task 1: Update the AppDetail Container

Find the container that renders `AppDetail` and update it to use `getApplication`:

```typescript
// Before (gets all categories, finds app by name):
// const { data, loading } = listAppHubCategories({ variables: { projectID } });
// passes categories to AppDetailView

// After (gets the specific app):
import { getApplication } from '@api/core';
const { appName } = useParams<{ appName: string }>();
const { data, loading } = getApplication({
  variables: { projectID, appName },
  fetchPolicy: 'cache-and-network',
});
// passes data?.getApplication to AppDetailView
```

### Task 2: Rewrite `AppDetail.tsx`

**File to Replace:** `AgentCert/chaoscenter/web/src/views/AppDetail/AppDetail.tsx`

```typescript
import React, { useState } from 'react';
import { Color, FontVariation } from '@harnessio/design-system';
import { Button, ButtonVariation, Card, Container, Layout, Tag, Text } from '@harnessio/uicore';
import { Icon } from '@harnessio/icons';
import { useHistory } from 'react-router-dom';
import DefaultLayoutTemplate from '@components/DefaultLayout';
import type { ApplicationSpec, CatalogAppInput } from '@api/entities';
import { useDocumentTitle, useRouteWithBaseUrl } from '@hooks';
import { useStrings } from '@strings';
import css from './AppDetail.module.scss';

interface AppDetailViewProps {
  app: ApplicationSpec | null | undefined;
  loading: boolean;
}

function SuitabilityList({ items, suitable }: { items: string[]; suitable: boolean }): React.ReactElement {
  return (
    <Layout.Vertical spacing="xsmall">
      {items.map((item, idx) => (
        <Layout.Horizontal key={idx} spacing="xsmall" flex={{ alignItems: 'flex-start' }}>
          <Text color={suitable ? Color.GREEN_600 : Color.RED_600} font={{ variation: FontVariation.BODY }}>
            {suitable ? '✅' : '❌'}
          </Text>
          <Text font={{ variation: FontVariation.BODY }} color={Color.GREY_700}>{item}</Text>
        </Layout.Horizontal>
      ))}
    </Layout.Vertical>
  );
}

function InputField({ input }: { input: CatalogAppInput }): React.ReactElement {
  return (
    <Layout.Vertical spacing="xsmall" className={css.inputField}>
      <Layout.Horizontal spacing="xsmall" flex={{ alignItems: 'center' }}>
        <Text font={{ variation: FontVariation.FORM_LABEL }} color={Color.GREY_700}>
          {input.displayName}
        </Text>
        {input.required && (
          <Text font={{ variation: FontVariation.SMALL }} color={Color.RED_600}>*</Text>
        )}
      </Layout.Horizontal>
      {input.description && (
        <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_500}>{input.description}</Text>
      )}
      <div className={css.inputPlaceholder}>
        <Text font={{ variation: FontVariation.BODY }} color={Color.GREY_500}>
          {input.default ?? (input.type === 'enum' ? input.values?.[0] : '')}
          {input.unit ? ` ${input.unit}` : ''}
        </Text>
      </div>
    </Layout.Vertical>
  );
}

export default function AppDetailView({ app, loading }: AppDetailViewProps): React.ReactElement {
  const { getString } = useStrings();
  const history = useHistory();
  const paths = useRouteWithBaseUrl();
  const [showAdvanced, setShowAdvanced] = useState(false);

  useDocumentTitle(app?.displayName ?? 'App Detail');

  const breadcrumbs = [{ label: 'App Catalog', url: paths.toAppsHub() }];

  if (loading) {
    return (
      <DefaultLayoutTemplate title="App Catalog" breadcrumbs={breadcrumbs}>
        <Container padding="xlarge">
          <Text font={{ variation: FontVariation.BODY }} color={Color.GREY_500}>Loading...</Text>
        </Container>
      </DefaultLayoutTemplate>
    );
  }

  if (!app) {
    return (
      <DefaultLayoutTemplate title="App Catalog" breadcrumbs={breadcrumbs}>
        <Container padding="xlarge">
          <Layout.Vertical flex={{ justifyContent: 'center', alignItems: 'center' }} height={400} spacing="medium">
            <Icon name="nav-settings" size={48} color={Color.GREY_400} />
            <Text font={{ variation: FontVariation.H5 }} color={Color.GREY_500}>Application not found</Text>
          </Layout.Vertical>
        </Container>
      </DefaultLayoutTemplate>
    );
  }

  const standardInputs = app.inputs.filter(i => !i.advanced);
  const advancedInputs = app.inputs.filter(i => i.advanced);
  const compatibleFaults = app.faultCompatibility.filter(f => f.compatible);
  const incompatibleFaults = app.faultCompatibility.filter(f => !f.compatible);

  return (
    <DefaultLayoutTemplate title={app.displayName} breadcrumbs={breadcrumbs}>
      <Container padding="xlarge" className={css.container}>
        <Layout.Horizontal spacing="xlarge" flex={{ alignItems: 'flex-start' }}>

          {/* Left: App detail card */}
          <Card className={css.detailCard} elevation={1}>
            <Layout.Vertical spacing="large" padding="xlarge">
              {/* Header */}
              <Layout.Horizontal spacing="medium" flex={{ alignItems: 'center', justifyContent: 'space-between' }}>
                <Layout.Horizontal spacing="medium" flex={{ alignItems: 'center' }}>
                  <Icon name="nav-settings" size={36} color={Color.PRIMARY_7} />
                  <Layout.Vertical spacing="xsmall">
                    <Text font={{ variation: FontVariation.H3 }} color={Color.GREY_800}>{app.displayName}</Text>
                    <Layout.Horizontal spacing="small">
                      <Tag>{app.tier === 'official' ? 'Official' : 'Community'}</Tag>
                      <Tag>{app.domain}</Tag>
                      <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_500}>v{app.version}</Text>
                    </Layout.Horizontal>
                  </Layout.Vertical>
                </Layout.Horizontal>
              </Layout.Horizontal>

              {/* Description */}
              <Text font={{ variation: FontVariation.BODY }} color={Color.GREY_700}>
                {app.description.long}
              </Text>

              {/* Suitability */}
              {app.description.suitableFor.length > 0 && (
                <Layout.Vertical spacing="small">
                  <SuitabilityList items={app.description.suitableFor} suitable={true} />
                  {app.description.notSuitableFor.length > 0 && (
                    <SuitabilityList items={app.description.notSuitableFor} suitable={false} />
                  )}
                </Layout.Vertical>
              )}

              {/* Microservices */}
              <Layout.Vertical spacing="small">
                <Text font={{ variation: FontVariation.H6 }} color={Color.GREY_600}>
                  Microservices ({app.microservices.length})
                </Text>
                <div className={css.tagCloud}>
                  {app.microservices.map(ms => (
                    <Tag key={ms.name} className={css[`criticality_${ms.criticality}`]}>{ms.name}</Tag>
                  ))}
                </div>
              </Layout.Vertical>

              {/* Compatible faults */}
              <Layout.Vertical spacing="small">
                <Text font={{ variation: FontVariation.H6 }} color={Color.GREY_600}>Available Faults</Text>
                <div className={css.tagCloud}>
                  {compatibleFaults.map(f => <Tag key={f.faultName}>{f.faultName}</Tag>)}
                </div>
                {incompatibleFaults.length > 0 && (
                  <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_400}>
                    + {incompatibleFaults.length} incompatible faults (hidden)
                  </Text>
                )}
              </Layout.Vertical>

              {/* Install info */}
              <Layout.Horizontal spacing="xlarge">
                <Layout.Vertical spacing="xsmall">
                  <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_500}>Namespace</Text>
                  <Text font={{ variation: FontVariation.BODY }} color={Color.GREY_800}>{app.install.namespace.default}</Text>
                </Layout.Vertical>
                <Layout.Vertical spacing="xsmall">
                  <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_500}>Install timeout</Text>
                  <Text font={{ variation: FontVariation.BODY }} color={Color.GREY_800}>{app.install.timeout}</Text>
                </Layout.Vertical>
              </Layout.Horizontal>

              {/* Action buttons */}
              <Layout.Horizontal spacing="medium">
                <Button variation={ButtonVariation.TERTIARY} text="View Documentation" icon="link" />
                <Button
                  variation={ButtonVariation.PRIMARY}
                  text="Select This App →"
                  onClick={() => {
                    // TODO: navigate to experiment creation with this app pre-selected
                    // history.push(paths.toNewExperiment({ appName: app.name }));
                  }}
                />
              </Layout.Horizontal>
            </Layout.Vertical>
          </Card>

          {/* Right: Configure Install Parameters */}
          <Card className={css.configCard} elevation={1}>
            <Layout.Vertical spacing="medium" padding="large">
              <Text font={{ variation: FontVariation.H5 }} color={Color.GREY_800}>
                Configure: {app.displayName}
              </Text>

              {/* Standard inputs */}
              {standardInputs.length > 0 && (
                <Layout.Vertical spacing="medium">
                  {standardInputs.map(input => <InputField key={input.key} input={input} />)}
                </Layout.Vertical>
              )}

              {/* Advanced inputs toggle */}
              {advancedInputs.length > 0 && (
                <Layout.Vertical spacing="medium">
                  <div
                    className={css.advancedToggle}
                    onClick={() => setShowAdvanced(v => !v)}
                  >
                    <Icon name={showAdvanced ? 'chevron-down' : 'chevron-right'} size={12} />
                    <Text font={{ variation: FontVariation.SMALL_BOLD }} color={Color.GREY_600}>
                      Advanced
                    </Text>
                  </div>
                  {showAdvanced && (
                    <Layout.Vertical spacing="medium" className={css.advancedSection}>
                      {advancedInputs.map(input => <InputField key={input.key} input={input} />)}
                    </Layout.Vertical>
                  )}
                </Layout.Vertical>
              )}
            </Layout.Vertical>
          </Card>

        </Layout.Horizontal>
      </Container>
    </DefaultLayoutTemplate>
  );
}
```

### Task 3: Update `AppDetail.module.scss`

**File to Modify:** `AgentCert/chaoscenter/web/src/views/AppDetail/AppDetail.module.scss`

```scss
.container {
  max-width: 1200px;
}

.detailCard {
  flex: 1;
  min-width: 0;
}

.configCard {
  width: 320px;
  min-width: 280px;
  flex-shrink: 0;
  align-self: flex-start;
  position: sticky;
  top: 16px;
}

.tagCloud {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.microserviceHeader,
.microserviceRow {
  padding: 8px 12px;
  border-bottom: 1px solid var(--grey-100, #f3f4f6);
}

.microserviceHeader {
  background: var(--grey-50, #fafafa);
  font-weight: 600;
}

.microserviceList {
  border: 1px solid var(--grey-200, #e5e7eb);
  border-radius: 4px;
  overflow: hidden;
}

.criticality_high {
  background: #fee2e2;
  color: #991b1b;
}

.criticality_medium {
  background: #fef3c7;
  color: #92400e;
}

.criticality_low {
  background: #f0fdf4;
  color: #166534;
}

.inputField {
  padding: 8px 0;
  border-bottom: 1px solid var(--grey-100, #f3f4f6);

  &:last-child {
    border-bottom: none;
  }
}

.inputPlaceholder {
  padding: 6px 10px;
  background: var(--grey-50, #fafafa);
  border: 1px solid var(--grey-200, #e5e7eb);
  border-radius: 4px;
  min-height: 32px;
}

.advancedToggle {
  display: flex;
  align-items: center;
  gap: 6px;
  cursor: pointer;
  user-select: none;

  &:hover {
    opacity: 0.8;
  }
}

.advancedSection {
  padding: 8px 0 0 16px;
  border-left: 2px solid var(--grey-200, #e5e7eb);
}
```

---

## Files to Modify

- `web/src/views/AppDetail/AppDetail.tsx` — full rewrite
- `web/src/views/AppDetail/AppDetail.module.scss` — updated styles
- Container that renders `AppDetail` — switch from `listAppHubCategories` to `getApplication`

---

## Verification Criteria

### Must Pass
- [ ] TypeScript compilation passes
- [ ] Navigating to `/apps-hub/sock-shop` shows the full detail view
- [ ] `suitableFor` items shown with ✅ green
- [ ] `notSuitableFor` items shown with ❌ red
- [ ] Microservice list shows all 13 Sock Shop services
- [ ] Compatible faults shown as tags
- [ ] Standard inputs (replicaScale, resourceProfile) shown in the config panel
- [ ] "Advanced" toggle expands to show `enableTracing` input
- [ ] "← Back to Catalog" breadcrumb navigates to `/apps-hub`

### Should Pass
- [ ] Config panel is sticky on scroll
- [ ] Criticality badges are color-coded (high=red, medium=amber, low=green)

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/web

# Type check
yarn tsc --noEmit

# Dev server — navigate to /apps-hub, click Sock Shop card
yarn start
```

---

## Success Criteria

Stage 08 is complete when:
1. `/apps-hub/sock-shop` shows full app detail with all spec sections
2. `suitableFor`/`notSuitableFor` rendered with correct icons
3. Config panel with standard + Advanced toggle works
4. TypeScript compiles cleanly

## Next Stage

Proceed to **Stage 09: Contribution Wizard Steps 1–3**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
