# Stage 09: Contribution Wizard Steps 1–3

**Phase:** 3 — Frontend Contribution Wizard  
**Dependencies:** Stage 08  
**Risk Level:** Medium

---

## Objectives

1. Replace `AppsOnboarding.tsx` with the 6-step Contribution Wizard (User Journey B, spec §7–8)
2. Implement Step 1: App Identity
3. Implement Step 2: Installation Method (Quick Contribute / Full Contribute decision gate)
4. Implement Step 3: Service Discovery & Fault Targeting (table with include/exclude, auto-exclusion logic)
5. Connect to the backend `validate-name` and `discover-services` REST endpoints (Stage 11 provides these — stubs used until then)

---

## Current State Analysis

### What We Have
- `views/AppsOnboarding/AppsOnboarding.tsx` — skeleton with 2 radio options, mock data table, no real wizard
- `views/AgentOnboarding/AgentOnboarding.tsx` — **reference pattern** for multi-step wizard UI
- Route `/apps-onboarding` → `AppsOnboarding` view

### What We Need
- Multi-step wizard using `ContributionFormData` state
- Step 1: Identity fields + name uniqueness check (async, calls backend)
- Step 2: Decision gate → Quick or Full Contribute → install method fields
- Step 3: Service discovery table — includes discovered services, auto-exclusion toggles

### Pattern to Follow: `AgentOnboarding`
Before implementing, read `views/AgentOnboarding/AgentOnboarding.tsx` to understand:
- How step state is managed (local component state vs. context)
- How step validation is done
- How "Next" and "Back" navigation work

---

## Pre-Stage Verification

```bash
# Read the AgentOnboarding wizard for reference
cat /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/AgentOnboarding/AgentOnboarding.tsx | head -80

# Check DOMAINS list available (same list used in Catalog Browser)
grep -n "DOMAINS\|domain" /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/AppsHub/AppsHub.tsx | head -10
```

---

## Implementation Tasks

### Task 1: Define `ContributionFormData` type

**File to Create:** `AgentCert/chaoscenter/web/src/views/AppsOnboarding/types.ts`

```typescript
export type ContributeMethod = 'quick' | 'full' | 'private';
export type InstallMethod = 'external-helm' | 'helm' | 'manifests';
export type LoadTestMethod = 'built-in' | 'standard' | 'custom-job' | 'skip';

export interface DiscoveredService {
  name: string;
  label: string;
  kind: 'deployment' | 'statefulset' | 'daemonset';
  included: boolean;
  criticality: 'high' | 'medium' | 'low';
  autoExcluded: boolean;
  autoExclusionReason?: string;
}

export interface ContributionFormData {
  // Step 1 — Identity
  name: string;
  displayName: string;
  domain: string;
  shortDescription: string;
  longDescription: string;
  maintainerName: string;
  maintainerEmail: string;
  tags: string[];

  // Step 2 — Installation
  contributeMethod: ContributeMethod;
  installMethod: InstallMethod;
  // Quick path (external-helm)
  chartRepoURL: string;
  chartName: string;
  chartVersion: string;
  // Full path
  gitURL: string;
  defaultNamespace: string;
  installTimeout: string;

  // Step 3 — Services
  discoveredServices: DiscoveredService[];

  // Step 4 — Health Probe
  healthProbeURL: string;
  healthProbeStatus: string;
  initialDelaySeconds: number;
  periodSeconds: number;
  failureThreshold: number;

  // Step 5 — Load Test
  loadTestMethod: LoadTestMethod;
  customJobYAML: string;

  // Step 6 — Generated output
  generatedAppYAML: string;
  generatedReadmeMD: string;
}

export const EMPTY_FORM_DATA: ContributionFormData = {
  name: '',
  displayName: '',
  domain: '',
  shortDescription: '',
  longDescription: '',
  maintainerName: '',
  maintainerEmail: '',
  tags: [],
  contributeMethod: 'quick',
  installMethod: 'external-helm',
  chartRepoURL: '',
  chartName: '',
  chartVersion: '',
  gitURL: '',
  defaultNamespace: '',
  installTimeout: '30m',
  discoveredServices: [],
  healthProbeURL: 'http://{{.AppNamespace}}.svc.cluster.local:80/health',
  healthProbeStatus: '200',
  initialDelaySeconds: 30,
  periodSeconds: 10,
  failureThreshold: 6,
  loadTestMethod: 'standard',
  customJobYAML: '',
  generatedAppYAML: '',
  generatedReadmeMD: '',
};

export const DOMAINS = [
  { id: 'cloud-native', displayName: 'Cloud Native' },
  { id: 'service-mesh', displayName: 'Service Mesh' },
  { id: 'telecom', displayName: 'Telecom' },
  { id: 'health-it', displayName: 'Health IT' },
  { id: 'itops', displayName: 'IT Operations' },
  { id: 'finops', displayName: 'FinOps / Financial' },
];

// Services with these names are auto-excluded (observability stack should not be faulted)
export const AUTO_EXCLUDE_NAMES = ['prometheus', 'grafana', 'alertmanager', 'loki', 'jaeger', 'tempo'];
// Services matching these patterns get criticality:high
export const HIGH_CRITICALITY_PATTERNS = [/-db$/, /-database$/, /-postgres$/, /-mysql$/, /-mongo$/];
```

### Task 2: Implement Step 1 — Identity

**File to Create:** `AgentCert/chaoscenter/web/src/views/AppsOnboarding/steps/Step1Identity.tsx`

```typescript
import React from 'react';
import { Color, FontVariation } from '@harnessio/design-system';
import { Button, ButtonVariation, Container, FormInput, Layout, Select, Text } from '@harnessio/uicore';
import { Formik, Form } from 'formik';
import * as Yup from 'yup';
import type { ContributionFormData } from '../types';
import { DOMAINS } from '../types';
import css from '../AppsOnboarding.module.scss';

interface Step1Props {
  data: ContributionFormData;
  onNext: (patch: Partial<ContributionFormData>) => void;
}

const schema = Yup.object({
  name: Yup.string()
    .matches(/^[a-z0-9][a-z0-9-]*[a-z0-9]$/, 'Kebab-case only (a-z, 0-9, hyphens). Must not start/end with hyphen.')
    .max(63, 'Max 63 characters')
    .required('Required'),
  displayName: Yup.string().min(1).max(80).required('Required'),
  domain: Yup.string().required('Select a domain'),
  shortDescription: Yup.string().min(10, 'Min 10 characters').max(120, 'Max 120 characters').required('Required'),
  longDescription: Yup.string().required('Required'),
  maintainerName: Yup.string().required('Required'),
  maintainerEmail: Yup.string().email('Invalid email').required('Required'),
});

export default function Step1Identity({ data, onNext }: Step1Props): React.ReactElement {
  return (
    <Container className={css.stepContainer}>
      <Text font={{ variation: FontVariation.H4 }} color={Color.GREY_800} className={css.stepTitle}>
        Step 1 of 6 — App Identity
      </Text>

      <Formik
        initialValues={{
          name: data.name,
          displayName: data.displayName,
          domain: data.domain,
          shortDescription: data.shortDescription,
          longDescription: data.longDescription,
          maintainerName: data.maintainerName,
          maintainerEmail: data.maintainerEmail,
        }}
        validationSchema={schema}
        onSubmit={values => onNext(values)}
      >
        {({ values, errors, touched, handleChange, handleBlur, setFieldValue }) => (
          <Form>
            <Layout.Vertical spacing="large">
              <Layout.Vertical spacing="xsmall">
                <FormInput.Text
                  name="name"
                  label="App Name (kebab-case) *"
                  placeholder="my-app-name"
                />
                <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_400}>
                  This becomes the stable ID. Cannot change after any experiment references this app.
                </Text>
              </Layout.Vertical>

              <FormInput.Text name="displayName" label="Display Name *" placeholder="My App Name" />

              <Layout.Vertical spacing="xsmall">
                <Text font={{ variation: FontVariation.FORM_LABEL }} color={Color.GREY_700}>Domain *</Text>
                <Select
                  items={DOMAINS.map(d => ({ label: d.displayName, value: d.id }))}
                  value={values.domain ? { label: DOMAINS.find(d => d.id === values.domain)?.displayName ?? values.domain, value: values.domain } : undefined}
                  onChange={item => setFieldValue('domain', item.value)}
                />
                {touched.domain && errors.domain && (
                  <Text font={{ variation: FontVariation.SMALL }} color={Color.RED_600}>{errors.domain}</Text>
                )}
              </Layout.Vertical>

              <Layout.Vertical spacing="xsmall">
                <FormInput.Text
                  name="shortDescription"
                  label="Short Description * (≤120 chars)"
                  placeholder="A one-line description for the catalog card"
                />
                <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_400}>
                  {values.shortDescription.length}/120
                </Text>
              </Layout.Vertical>

              <FormInput.TextArea
                name="longDescription"
                label="Full Description * (Markdown supported)"
                placeholder="Describe your application's architecture, purpose, and why agents should test against it..."
              />

              <Layout.Horizontal spacing="medium">
                <Layout.Vertical className={css.halfWidth}>
                  <FormInput.Text name="maintainerName" label="Maintainer Name *" />
                </Layout.Vertical>
                <Layout.Vertical className={css.halfWidth}>
                  <FormInput.Text name="maintainerEmail" label="Maintainer Email *" placeholder="you@example.com" />
                </Layout.Vertical>
              </Layout.Horizontal>

              <Layout.Horizontal flex={{ justifyContent: 'flex-end' }}>
                <Button variation={ButtonVariation.PRIMARY} type="submit" text="Next: Installation →" />
              </Layout.Horizontal>
            </Layout.Vertical>
          </Form>
        )}
      </Formik>
    </Container>
  );
}
```

### Task 3: Implement Step 2 — Installation Method

**File to Create:** `AgentCert/chaoscenter/web/src/views/AppsOnboarding/steps/Step2Installation.tsx`

```typescript
import React from 'react';
import { Color, FontVariation } from '@harnessio/design-system';
import { Button, ButtonVariation, Container, Layout, Text } from '@harnessio/uicore';
import type { ContributionFormData } from '../types';
import css from '../AppsOnboarding.module.scss';

interface Step2Props {
  data: ContributionFormData;
  onNext: (patch: Partial<ContributionFormData>) => void;
  onBack: () => void;
  onDiscover: (patch: Partial<ContributionFormData>) => Promise<void>;
}

export default function Step2Installation({ data, onNext, onBack, onDiscover }: Step2Props): React.ReactElement {
  const [method, setMethod] = React.useState(data.contributeMethod);
  const [chartRepo, setChartRepo] = React.useState(data.chartRepoURL);
  const [chartName, setChartName] = React.useState(data.chartName);
  const [chartVersion, setChartVersion] = React.useState(data.chartVersion);
  const [namespace, setNamespace] = React.useState(data.defaultNamespace);
  const [timeout, setTimeout] = React.useState(data.installTimeout);
  const [discovering, setDiscovering] = React.useState(false);

  const handleDiscover = async (): Promise<void> => {
    setDiscovering(true);
    try {
      await onDiscover({
        contributeMethod: method,
        installMethod: method === 'quick' ? 'external-helm' : 'helm',
        chartRepoURL: chartRepo,
        chartName,
        chartVersion,
        defaultNamespace: namespace,
        installTimeout: timeout,
      });
    } finally {
      setDiscovering(false);
    }
  };

  return (
    <Container className={css.stepContainer}>
      <Text font={{ variation: FontVariation.H4 }} color={Color.GREY_800} className={css.stepTitle}>
        Step 2 of 6 — Installation
      </Text>

      <Layout.Vertical spacing="large">
        {/* Decision gate: Quick vs Full */}
        <Layout.Vertical spacing="medium">
          {(['quick', 'full'] as const).map(m => (
            <div
              key={m}
              className={`${css.methodCard} ${method === m ? css.methodCardSelected : ''}`}
              onClick={() => setMethod(m)}
            >
              <Layout.Vertical spacing="xsmall">
                <Text font={{ variation: FontVariation.H5 }} color={Color.GREY_800}>
                  {m === 'quick' ? '🚀 Quick Contribute' : '📦 Full Contribute'}
                </Text>
                <Text font={{ variation: FontVariation.BODY }} color={Color.GREY_600}>
                  {m === 'quick'
                    ? 'My app already has a public Helm chart. I\'ll point ACE to it.'
                    : 'I\'ll provide K8s manifests or a custom Helm chart.'}
                </Text>
              </Layout.Vertical>
            </div>
          ))}
        </Layout.Vertical>

        {/* Quick Contribute fields */}
        {method === 'quick' && (
          <Layout.Vertical spacing="medium">
            <div className={css.field}>
              <label className={css.fieldLabel}>Helm Repository URL *</label>
              <input className={css.input} value={chartRepo} onChange={e => setChartRepo(e.target.value)} placeholder="https://charts.example.com" />
            </div>
            <div className={css.field}>
              <label className={css.fieldLabel}>Chart Name *</label>
              <input className={css.input} value={chartName} onChange={e => setChartName(e.target.value)} placeholder="my-chart" />
            </div>
            <div className={css.field}>
              <label className={css.fieldLabel}>Chart Version * (pin a specific version)</label>
              <input className={css.input} value={chartVersion} onChange={e => setChartVersion(e.target.value)} placeholder="1.2.3" />
              <Text font={{ variation: FontVariation.SMALL }} color={Color.ORANGE_700}>
                ⚠ Floating versions (latest, *) are not accepted.
              </Text>
            </div>
          </Layout.Vertical>
        )}

        {/* Full Contribute fields */}
        {method === 'full' && (
          <Layout.Vertical spacing="medium">
            <Text font={{ variation: FontVariation.BODY }} color={Color.GREY_600}>
              Provide your chart as a Git repository URL or zip upload.
            </Text>
            <div className={css.field}>
              <label className={css.fieldLabel}>Git Repository URL</label>
              <input className={css.input} value={data.gitURL} placeholder="https://github.com/your/chart-repo" readOnly />
            </div>
          </Layout.Vertical>
        )}

        {/* Common fields */}
        <div className={css.field}>
          <label className={css.fieldLabel}>Default Namespace *</label>
          <input className={css.input} value={namespace} onChange={e => setNamespace(e.target.value)} placeholder="my-app" />
        </div>
        <div className={css.field}>
          <label className={css.fieldLabel}>Install Timeout</label>
          <input className={css.input} value={timeout} onChange={e => setTimeout(e.target.value)} placeholder="30m" />
        </div>

        <Layout.Horizontal flex={{ justifyContent: 'space-between' }}>
          <Button variation={ButtonVariation.TERTIARY} text="← Back" onClick={onBack} />
          <Button
            variation={ButtonVariation.PRIMARY}
            text={discovering ? 'Discovering...' : 'Discover Services →'}
            disabled={discovering || (method === 'quick' && (!chartRepo || !chartName || !chartVersion))}
            onClick={handleDiscover}
          />
        </Layout.Horizontal>
      </Layout.Vertical>
    </Container>
  );
}
```

### Task 4: Implement Step 3 — Service Discovery & Fault Targeting

**File to Create:** `AgentCert/chaoscenter/web/src/views/AppsOnboarding/steps/Step3Services.tsx`

```typescript
import React from 'react';
import { Color, FontVariation } from '@harnessio/design-system';
import { Button, ButtonVariation, Container, Layout, Text } from '@harnessio/uicore';
import type { ContributionFormData, DiscoveredService } from '../types';
import css from '../AppsOnboarding.module.scss';

interface Step3Props {
  data: ContributionFormData;
  onNext: (patch: Partial<ContributionFormData>) => void;
  onBack: () => void;
}

export default function Step3Services({ data, onNext, onBack }: Step3Props): React.ReactElement {
  const [services, setServices] = React.useState<DiscoveredService[]>(data.discoveredServices);

  const toggleIncluded = (name: string): void => {
    setServices(prev =>
      prev.map(s => s.name === name ? { ...s, included: !s.included } : s)
    );
  };

  const setCriticality = (name: string, criticality: DiscoveredService['criticality']): void => {
    setServices(prev =>
      prev.map(s => s.name === name ? { ...s, criticality } : s)
    );
  };

  return (
    <Container className={css.stepContainer}>
      <Text font={{ variation: FontVariation.H4 }} color={Color.GREY_800} className={css.stepTitle}>
        Step 3 of 6 — Services & Fault Targets
      </Text>

      <Layout.Vertical spacing="large">
        <Text font={{ variation: FontVariation.BODY }} color={Color.GREY_600}>
          We discovered {services.length} services in your chart. Review and confirm which ones
          should be available as fault targets.
        </Text>

        {services.length === 0 ? (
          <Text font={{ variation: FontVariation.BODY }} color={Color.ORANGE_500}>
            No services discovered. Go back and check your chart reference.
          </Text>
        ) : (
          <div className={css.serviceTable}>
            <div className={`${css.serviceRow} ${css.serviceHeader}`}>
              <span>Service Name</span>
              <span>K8s Label</span>
              <span>Kind</span>
              <span>Criticality</span>
              <span>Include?</span>
            </div>
            {services.map(svc => (
              <div key={svc.name} className={`${css.serviceRow} ${svc.autoExcluded ? css.autoExcludedRow : ''}`}>
                <span>
                  {svc.name}
                  {svc.autoExcluded && (
                    <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_400}>
                      {' '}(auto-excluded: {svc.autoExclusionReason})
                    </Text>
                  )}
                </span>
                <span><code>{svc.label}</code></span>
                <span>{svc.kind}</span>
                <span>
                  <select
                    value={svc.criticality}
                    onChange={e => setCriticality(svc.name, e.target.value as DiscoveredService['criticality'])}
                    disabled={!svc.included}
                    className={css.criticalitySelect}
                  >
                    <option value="high">high</option>
                    <option value="medium">medium</option>
                    <option value="low">low</option>
                  </select>
                </span>
                <span>
                  <input
                    type="checkbox"
                    checked={svc.included}
                    onChange={() => toggleIncluded(svc.name)}
                  />
                </span>
              </div>
            ))}
          </div>
        )}

        {services.some(s => s.autoExcluded) && (
          <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_500} className={css.autoExcludeNote}>
            ⓘ Prometheus and Grafana are excluded by default — faulting observability tools breaks the
            experiment. You can include them manually if your agent specifically handles observability stack recovery.
          </Text>
        )}

        <Layout.Horizontal flex={{ justifyContent: 'space-between' }}>
          <Button variation={ButtonVariation.TERTIARY} text="← Back" onClick={onBack} />
          <Button
            variation={ButtonVariation.PRIMARY}
            text="Next: Health Probe →"
            disabled={services.filter(s => s.included).length === 0}
            onClick={() => onNext({ discoveredServices: services })}
          />
        </Layout.Horizontal>
      </Layout.Vertical>
    </Container>
  );
}
```

### Task 5: Wire Steps into `AppsOnboarding.tsx` (Main Wizard Shell)

**File to Replace:** `AgentCert/chaoscenter/web/src/views/AppsOnboarding/AppsOnboarding.tsx`

```typescript
import React, { useState } from 'react';
import DefaultLayoutTemplate from '@components/DefaultLayout';
import { useRouteWithBaseUrl } from '@hooks';
import { getScope } from '@utils';
import type { ContributionFormData, DiscoveredService } from './types';
import { EMPTY_FORM_DATA, AUTO_EXCLUDE_NAMES, HIGH_CRITICALITY_PATTERNS } from './types';
import Step1Identity from './steps/Step1Identity';
import Step2Installation from './steps/Step2Installation';
import Step3Services from './steps/Step3Services';
// Step4, Step5, Step6 imported in Stage 10
import css from './AppsOnboarding.module.scss';

export default function AppsOnboardingView(): React.ReactElement {
  const paths = useRouteWithBaseUrl();
  const scope = getScope();
  const [step, setStep] = useState(1);
  const [formData, setFormData] = useState<ContributionFormData>(EMPTY_FORM_DATA);

  const patch = (data: Partial<ContributionFormData>): void => {
    setFormData(prev => ({ ...prev, ...data }));
  };

  const next = (data: Partial<ContributionFormData>): void => {
    patch(data);
    setStep(s => s + 1);
  };

  const back = (): void => setStep(s => s - 1);

  // Calls the Stage 11 discovery endpoint. Stubs mock data until Stage 11 is complete.
  const handleDiscover = async (data: Partial<ContributionFormData>): Promise<void> => {
    patch(data);

    // TODO Stage 11: Replace stub with real API call
    // POST /api/catalog/discover-services { repoURL, chartName, version }
    const stubServices: DiscoveredService[] = [
      { name: 'app-service', label: 'app=app-service', kind: 'deployment', included: true, criticality: 'medium', autoExcluded: false },
      { name: 'app-db', label: 'app=app-db', kind: 'statefulset', included: true, criticality: 'high', autoExcluded: false },
      { name: 'prometheus', label: 'app=prometheus', kind: 'deployment', included: false, criticality: 'low', autoExcluded: true, autoExclusionReason: 'observability tool' },
    ];

    // Apply auto-exclusion logic
    const processed = stubServices.map(svc => {
      let autoExcluded = svc.autoExcluded;
      let autoExclusionReason = svc.autoExclusionReason;
      let criticality = svc.criticality;
      let included = svc.included;

      if (AUTO_EXCLUDE_NAMES.includes(svc.name)) {
        autoExcluded = true;
        included = false;
        autoExclusionReason = 'observability tool';
      }

      if (HIGH_CRITICALITY_PATTERNS.some(p => p.test(svc.name))) {
        criticality = 'high';
      }

      return { ...svc, autoExcluded, autoExclusionReason, criticality, included };
    });

    patch({ discoveredServices: processed });
    setStep(3);
  };

  const breadcrumbs = [
    { label: 'App Catalog', url: paths.toAppsHub() },
    { label: 'Contribute an App', url: paths.toAppsOnboarding() },
  ];

  const renderStep = (): React.ReactElement => {
    switch (step) {
      case 1: return <Step1Identity data={formData} onNext={next} />;
      case 2: return <Step2Installation data={formData} onNext={next} onBack={back} onDiscover={handleDiscover} />;
      case 3: return <Step3Services data={formData} onNext={next} onBack={back} />;
      // Steps 4-6 added in Stage 10
      default: return <div>Step {step} — coming in Stage 10</div>;
    }
  };

  return (
    <DefaultLayoutTemplate
      title="Contribute an App"
      breadcrumbs={breadcrumbs}
      subTitle="Add a new application to the ACE catalog"
    >
      {/* Step indicator */}
      <div className={css.stepIndicator}>
        {[1, 2, 3, 4, 5, 6].map(n => (
          <div key={n} className={`${css.stepDot} ${step >= n ? css.stepDotActive : ''}`}>
            {n}
          </div>
        ))}
      </div>
      {renderStep()}
    </DefaultLayoutTemplate>
  );
}
```

---

## Files to Create (Summary)

```
AgentCert/chaoscenter/web/src/views/AppsOnboarding/
├── types.ts                      (new)
└── steps/
    ├── Step1Identity.tsx          (new)
    ├── Step2Installation.tsx      (new)
    └── Step3Services.tsx          (new)
```

**Files to Modify:**
- `AppsOnboarding.tsx` — full rewrite (wizard shell)
- `AppsOnboarding.module.scss` — update styles for wizard

---

## Verification Criteria

### Must Pass
- [ ] TypeScript compilation passes
- [ ] Navigating to `/apps-onboarding` shows Step 1 (Identity form)
- [ ] Step 1 "Next" button validates name pattern, short description length, email format
- [ ] Step 2 "Discover Services →" triggers the discovery flow and moves to Step 3
- [ ] Step 3 shows the discovered services table with include/exclude checkboxes
- [ ] Auto-excluded services (prometheus) are unchecked with reason shown
- [ ] DB services auto-have `criticality: high`
- [ ] Step indicator shows current step highlighted

---

## Success Criteria

Stage 09 is complete when:
1. 3-step wizard renders and navigates correctly
2. Step 1 form validates correctly
3. Step 3 shows service table with auto-exclusion logic applied
4. TypeScript compiles cleanly

## Next Stage

Proceed to **Stage 10: Contribution Wizard Steps 4–6**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
