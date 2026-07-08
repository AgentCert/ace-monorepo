# Stage 07: Catalog Browser View (Domain Filters, Tier Separation)

**Phase:** 2 — Frontend Catalog Browser  
**Dependencies:** Stage 06  
**Risk Level:** Medium

---

## Objectives

1. Replace the existing `AppsHub` view with a spec-compliant Catalog Browser (User Journey A, spec §6)
2. Add domain filter sidebar (client-side filter on `ApplicationSpec.domain`)
3. Separate Official and Community tier display with distinct visual treatment
4. Add "Contribute an App" link that navigates to the Contribution Wizard (Stage 09)
5. Navigate to the upgraded `AppDetail` panel (Stage 08) on card click

---

## Current State Analysis

### What We Have
- `views/AppsHub/AppsHub.tsx` — shows category-grouped cards from `listAppHubCategories`
- `views/AppsHub/AppsHub.module.scss` — styling
- Router wires `/apps-hub` to a container that calls `listAppHubCategories` and passes data to `AppsHubView`
- `useRouteWithBaseUrl()` provides `paths.toAppsHub()`, `paths.toAppDetail({ appName })`

### What We Need
- Replace `AppsHub.tsx` to use `listApplications` instead of `listAppHubCategories`
- Domain filter sidebar (client-side — no extra API call)
- Official / Community section separation
- App card shows: displayName, domain badge, version, tier badge, microservice count, fault count
- "Contribute an App" banner/button
- "Don't see your domain?" link to `/apps-onboarding`

### What Changes
- The container that was calling `listAppHubCategories` now calls `listApplications`
- `AppsHub.tsx` view is rewritten (the module.scss is updated too)
- The container file (wherever the query was called) needs updating to use `listApplications`

---

## Pre-Stage Verification

```bash
# Find the container that calls listAppHubCategories
grep -rn "listAppHubCategories\|AppsHub" /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src --include="*.tsx" | grep -v ".module" | head -10

# Check existing module.scss
cat /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/AppsHub/AppsHub.module.scss
```

---

## Implementation Tasks

### Task 1: Find and Update the Container

First, locate the container/page component that renders `AppsHubView` and provides data:

```bash
grep -rn "AppsHub\|listAppHubCategories" \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/pages \
  /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/app \
  --include="*.tsx" | head -10
```

In the container, change from `listAppHubCategories` to `listApplications`:

```typescript
// Before:
import { listAppHubCategories } from '@api/core';
const { data, loading, refetch } = listAppHubCategories({ variables: { projectID } });

// After:
import { listApplications } from '@api/core';
const { data, loading, refetch } = listApplications({ variables: { projectID } });
```

Pass `data?.listApplications ?? []` to the view.

### Task 2: Rewrite `AppsHub.tsx`

**File to Replace:** `AgentCert/chaoscenter/web/src/views/AppsHub/AppsHub.tsx`

```typescript
import React, { useState, useMemo } from 'react';
import { Color, FontVariation } from '@harnessio/design-system';
import { Button, ButtonVariation, Card, Container, Layout, Text, TextInput } from '@harnessio/uicore';
import { Icon } from '@harnessio/icons';
import { useHistory } from 'react-router-dom';
import DefaultLayoutTemplate from '@components/DefaultLayout';
import type { ApplicationSpec } from '@api/entities';
import { useDocumentTitle, useRouteWithBaseUrl } from '@hooks';
import { useStrings } from '@strings';
import Loader from '@components/Loader';
import css from './AppsHub.module.scss';

// The domain list drives the filter sidebar.
// Sourced from catalog/domains.yaml — keep in sync if domains change.
const DOMAINS = [
  { id: 'all', displayName: 'All Domains' },
  { id: 'cloud-native', displayName: 'Cloud Native' },
  { id: 'service-mesh', displayName: 'Service Mesh' },
  { id: 'telecom', displayName: 'Telecom' },
  { id: 'health-it', displayName: 'Health IT' },
  { id: 'itops', displayName: 'IT Operations' },
  { id: 'finops', displayName: 'FinOps / Financial' },
];

interface AppCardProps {
  app: ApplicationSpec;
}

function TierBadge({ tier }: { tier: string }): React.ReactElement {
  const isOfficial = tier === 'official';
  return (
    <span className={isOfficial ? css.tierBadgeOfficial : css.tierBadgeCommunity}>
      {isOfficial ? 'Official' : 'Community'}
    </span>
  );
}

function DomainBadge({ domain }: { domain: string }): React.ReactElement {
  return <span className={css.domainBadge}>{domain}</span>;
}

function AppCard({ app }: AppCardProps): React.ReactElement {
  const history = useHistory();
  const paths = useRouteWithBaseUrl();
  const compatibleFaults = app.faultCompatibility.filter(f => f.compatible).length;

  return (
    <Card
      className={css.appCard}
      elevation={1}
      interactive
      onClick={() => history.push(paths.toAppDetail({ appName: app.name }))}
    >
      <Layout.Vertical spacing="medium" padding="medium">
        <Layout.Horizontal flex={{ justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <Layout.Horizontal spacing="small" flex={{ alignItems: 'center' }}>
            <Icon name="nav-settings" size={24} color={Color.PRIMARY_7} />
            <Text font={{ variation: FontVariation.H5 }} color={Color.GREY_800}>
              {app.displayName}
            </Text>
          </Layout.Horizontal>
          <Layout.Horizontal spacing="xsmall">
            <TierBadge tier={app.tier} />
          </Layout.Horizontal>
        </Layout.Horizontal>

        <Layout.Horizontal spacing="xsmall" flex={{ alignItems: 'center' }}>
          <DomainBadge domain={app.domain} />
          <Text font={{ variation: FontVariation.SMALL_BOLD }} color={Color.GREY_400}>v{app.version}</Text>
        </Layout.Horizontal>

        <Text font={{ variation: FontVariation.BODY }} color={Color.GREY_600} lineClamp={2}>
          {app.description.short}
        </Text>

        <Layout.Horizontal spacing="medium">
          <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_500}>
            {app.microservices.length} microservices
          </Text>
          <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_500}>
            {compatibleFaults} faults
          </Text>
        </Layout.Horizontal>
      </Layout.Vertical>
    </Card>
  );
}

interface AppsHubViewProps {
  apps: ApplicationSpec[];
  loading: boolean;
}

export default function AppsHubView({ apps, loading }: AppsHubViewProps): React.ReactElement {
  const { getString } = useStrings();
  const history = useHistory();
  const paths = useRouteWithBaseUrl();
  const [selectedDomain, setSelectedDomain] = useState<string>('all');
  const [searchTerm, setSearchTerm] = useState<string>('');

  useDocumentTitle('App Catalog');

  const filteredApps = useMemo(() => {
    return apps.filter(app => {
      const domainMatch = selectedDomain === 'all' || app.domain === selectedDomain;
      const searchMatch =
        searchTerm === '' ||
        app.displayName.toLowerCase().includes(searchTerm.toLowerCase()) ||
        app.description.short.toLowerCase().includes(searchTerm.toLowerCase()) ||
        app.tags.some(t => t.toLowerCase().includes(searchTerm.toLowerCase()));
      return domainMatch && searchMatch;
    });
  }, [apps, selectedDomain, searchTerm]);

  const officialApps = filteredApps.filter(a => a.tier === 'official');
  const communityApps = filteredApps.filter(a => a.tier === 'community');

  return (
    <DefaultLayoutTemplate
      title="App Catalog"
      breadcrumbs={[]}
      subTitle="Choose an application environment for your experiment"
    >
      <Container padding="xlarge">
        <Loader loading={loading}>
          <Layout.Horizontal spacing="large" className={css.catalogLayout}>
            {/* Sidebar: domain filter */}
            <Layout.Vertical spacing="small" className={css.sidebar}>
              <Text font={{ variation: FontVariation.H6 }} color={Color.GREY_700}>Filter by Domain</Text>
              {DOMAINS.map(d => (
                <div
                  key={d.id}
                  className={`${css.domainFilter} ${selectedDomain === d.id ? css.domainFilterActive : ''}`}
                  onClick={() => setSelectedDomain(d.id)}
                >
                  <Text
                    font={{ variation: FontVariation.BODY }}
                    color={selectedDomain === d.id ? Color.PRIMARY_7 : Color.GREY_700}
                  >
                    {d.displayName}
                  </Text>
                </div>
              ))}
            </Layout.Vertical>

            {/* Main content */}
            <Layout.Vertical spacing="large" className={css.mainContent}>
              {/* Search bar */}
              <TextInput
                leftIcon="search"
                placeholder="Search apps..."
                value={searchTerm}
                onChange={(e: React.ChangeEvent<HTMLInputElement>) => setSearchTerm(e.target.value)}
                className={css.searchBar}
              />

              {/* Official section */}
              {officialApps.length > 0 && (
                <Layout.Vertical spacing="medium">
                  <Text font={{ variation: FontVariation.H5 }} color={Color.GREY_800}>Official</Text>
                  <div className={css.appGrid}>
                    {officialApps.map(app => (
                      <AppCard key={app.name} app={app} />
                    ))}
                  </div>
                </Layout.Vertical>
              )}

              {/* Community section */}
              {communityApps.length > 0 && (
                <Layout.Vertical spacing="medium">
                  <Text font={{ variation: FontVariation.H5 }} color={Color.GREY_700}>Community</Text>
                  <div className={css.appGrid}>
                    {communityApps.map(app => (
                      <AppCard key={app.name} app={app} />
                    ))}
                  </div>
                </Layout.Vertical>
              )}

              {/* Empty state */}
              {filteredApps.length === 0 && (
                <Layout.Vertical flex={{ justifyContent: 'center', alignItems: 'center' }} height={300} spacing="medium">
                  <Icon name="nav-settings" size={48} color={Color.GREY_400} />
                  <Text font={{ variation: FontVariation.H5 }} color={Color.GREY_500}>
                    No apps found for this filter
                  </Text>
                </Layout.Vertical>
              )}

              {/* Contribute banner */}
              <Layout.Horizontal
                className={css.contributeBanner}
                flex={{ justifyContent: 'space-between', alignItems: 'center' }}
                padding="medium"
              >
                <Text font={{ variation: FontVariation.BODY }} color={Color.GREY_700}>
                  Don't see your domain? Contribute an app to the catalog.
                </Text>
                <Button
                  variation={ButtonVariation.SECONDARY}
                  text="Contribute an App"
                  icon="plus"
                  onClick={() => history.push(paths.toAppsOnboarding())}
                />
              </Layout.Horizontal>
            </Layout.Vertical>
          </Layout.Horizontal>
        </Loader>
      </Container>
    </DefaultLayoutTemplate>
  );
}
```

### Task 3: Update `AppsHub.module.scss`

**File to Modify:** `AgentCert/chaoscenter/web/src/views/AppsHub/AppsHub.module.scss`

Replace with:

```scss
.catalogLayout {
  align-items: flex-start;
}

.sidebar {
  width: 200px;
  min-width: 180px;
  flex-shrink: 0;
  background: var(--grey-50, #fafafa);
  border-radius: 4px;
  padding: 16px;
  border: 1px solid var(--grey-200, #e5e7eb);
}

.domainFilter {
  padding: 8px 12px;
  border-radius: 4px;
  cursor: pointer;
  transition: background 0.1s;

  &:hover {
    background: var(--blue-50, #eff6ff);
  }
}

.domainFilterActive {
  background: var(--blue-50, #eff6ff);
}

.mainContent {
  flex: 1;
  min-width: 0;
}

.searchBar {
  max-width: 400px;
}

.appGrid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 16px;
}

.appCard {
  width: 100%;
  min-height: 160px;
  cursor: pointer;
  transition: box-shadow 0.15s;

  &:hover {
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.12);
  }
}

.tierBadgeOfficial {
  font-size: 11px;
  font-weight: 600;
  padding: 2px 8px;
  border-radius: 10px;
  background: #dbeafe;
  color: #1d4ed8;
}

.tierBadgeCommunity {
  font-size: 11px;
  font-weight: 600;
  padding: 2px 8px;
  border-radius: 10px;
  background: #f3f4f6;
  color: #6b7280;
}

.domainBadge {
  font-size: 11px;
  font-weight: 500;
  padding: 2px 8px;
  border-radius: 10px;
  background: #f0fdf4;
  color: #166534;
  text-transform: capitalize;
}

.contributeBanner {
  border: 1px dashed var(--grey-300, #d1d5db);
  border-radius: 6px;
  margin-top: 16px;
}
```

---

## Files to Modify

- `web/src/views/AppsHub/AppsHub.tsx` — full rewrite
- `web/src/views/AppsHub/AppsHub.module.scss` — updated styles
- Container/page that renders `AppsHub` — change to `listApplications` query

---

## Verification Criteria

### Must Pass
- [ ] TypeScript compilation passes (`yarn tsc --noEmit`)
- [ ] Domain filter sidebar renders with 7 entries (All + 6 domains)
- [ ] Sock Shop card appears in "Official" section
- [ ] Selecting "Cloud Native" filter shows only cloud-native apps
- [ ] Searching "sock" filters to Sock Shop
- [ ] Clicking a card navigates to `/apps-hub/sock-shop`
- [ ] "Contribute an App" button navigates to `/apps-onboarding`
- [ ] Community section renders (empty if no community apps)

### Should Pass
- [ ] Existing navigation to `/apps-hub` still works
- [ ] Loading state shows spinner

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/web

# Type check
yarn tsc --noEmit

# Dev server (manual browser testing)
yarn start
# Navigate to /apps-hub in browser
# Verify: domain filter, tier separation, search, card click, contribute banner
```

---

## Success Criteria

Stage 07 is complete when:
1. Catalog Browser renders with domain filter sidebar and tier sections
2. Sock Shop appears in the Official section
3. Domain filter and search work client-side
4. "Contribute an App" navigates to contribution flow
5. TypeScript compiles cleanly

## Next Stage

Proceed to **Stage 08: App Detail Panel**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
