# Stage 10: Contribution Wizard Steps 4–6 (Health Probe, Load Test, Review & Generate)

**Phase:** 3 — Frontend Contribution Wizard  
**Dependencies:** Stage 09  
**Risk Level:** Medium

---

## Objectives

1. Implement Step 4: Health Probe (URL with `{{.AppNamespace}}` hint, timeout calc, test button)
2. Implement Step 5: Load Test (4 options: built-in / standard deployer / custom job / skip)
3. Implement Step 6: Review & Generate (YAML preview, download zip, PR button placeholder)
4. Connect Steps 4–6 to the wizard shell in `AppsOnboarding.tsx`
5. Implement client-side `app.yaml` generation from `ContributionFormData`

---

## Current State Analysis

### What We Have (from Stage 09)
- Steps 1–3 wired in `AppsOnboarding.tsx`
- `ContributionFormData` interface with fields for Steps 4–6
- Wizard shell renders placeholder for steps > 3

### What We Need
- Step 4 component with probe URL validation (must contain `{{.AppNamespace}}`)
- Step 5 component with 4 radio options
- Step 6 component: summary view + `generateAppYAML()` client-side function + download

---

## Pre-Stage Verification

```bash
# Stage 09 complete
grep "Step3Services" /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/AppsOnboarding/AppsOnboarding.tsx
ls /srv/projects/ace-monorepo/AgentCert/chaoscenter/web/src/views/AppsOnboarding/steps/
```

---

## Implementation Tasks

### Task 1: Implement Step 4 — Health Probe

**File to Create:** `AgentCert/chaoscenter/web/src/views/AppsOnboarding/steps/Step4HealthProbe.tsx`

```typescript
import React, { useState } from 'react';
import { Color, FontVariation } from '@harnessio/design-system';
import { Button, ButtonVariation, Container, Layout, Text } from '@harnessio/uicore';
import type { ContributionFormData } from '../types';
import css from '../AppsOnboarding.module.scss';

interface Step4Props {
  data: ContributionFormData;
  onNext: (patch: Partial<ContributionFormData>) => void;
  onBack: () => void;
}

export default function Step4HealthProbe({ data, onNext, onBack }: Step4Props): React.ReactElement {
  const [url, setUrl] = useState(data.healthProbeURL);
  const [status, setStatus] = useState(data.healthProbeStatus);
  const [delay, setDelay] = useState(data.initialDelaySeconds);
  const [period, setPeriod] = useState(data.periodSeconds);
  const [threshold, setThreshold] = useState(data.failureThreshold);
  const [urlError, setUrlError] = useState('');

  const totalTimeout = delay + period * threshold;

  const validate = (): boolean => {
    if (!url.includes('{{.AppNamespace}}')) {
      setUrlError('URL must use {{.AppNamespace}} instead of a hardcoded namespace');
      return false;
    }
    setUrlError('');
    return true;
  };

  const handleNext = (): void => {
    if (validate()) {
      onNext({
        healthProbeURL: url,
        healthProbeStatus: status,
        initialDelaySeconds: delay,
        periodSeconds: period,
        failureThreshold: threshold,
      });
    }
  };

  return (
    <Container className={css.stepContainer}>
      <Text font={{ variation: FontVariation.H4 }} color={Color.GREY_800} className={css.stepTitle}>
        Step 4 of 6 — Health Probe
      </Text>

      <Layout.Vertical spacing="large">
        <Text font={{ variation: FontVariation.BODY }} color={Color.GREY_600}>
          ACE will probe this URL after install to confirm the app is ready before running any faults.
        </Text>

        <div className={css.field}>
          <label className={css.fieldLabel}>Health Probe URL *</label>
          <input
            className={`${css.input} ${urlError ? css.inputError : ''}`}
            value={url}
            onChange={e => { setUrl(e.target.value); setUrlError(''); }}
            placeholder="http://my-service.{{.AppNamespace}}.svc.cluster.local:80/health"
          />
          {urlError ? (
            <Text font={{ variation: FontVariation.SMALL }} color={Color.RED_600}>{urlError}</Text>
          ) : (
            <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_400}>
              ⓘ Use {'{{.AppNamespace}}'} instead of the literal namespace.
            </Text>
          )}
        </div>

        <div className={css.field}>
          <label className={css.fieldLabel}>Expected HTTP Status *</label>
          <input className={css.input} value={status} onChange={e => setStatus(e.target.value)} placeholder="200" style={{ maxWidth: 100 }} />
        </div>

        <Layout.Horizontal spacing="large">
          <div className={css.field}>
            <label className={css.fieldLabel}>Initial Delay (seconds)</label>
            <input type="number" className={css.input} value={delay} onChange={e => setDelay(Number(e.target.value))} style={{ maxWidth: 100 }} />
          </div>
          <div className={css.field}>
            <label className={css.fieldLabel}>Retry Interval (seconds)</label>
            <input type="number" className={css.input} value={period} onChange={e => setPeriod(Number(e.target.value))} style={{ maxWidth: 100 }} />
          </div>
          <div className={css.field}>
            <label className={css.fieldLabel}>Max Retries</label>
            <input type="number" className={css.input} value={threshold} onChange={e => setThreshold(Number(e.target.value))} style={{ maxWidth: 100 }} />
          </div>
        </Layout.Horizontal>

        <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_500}>
          Total timeout: {delay} + ({period} × {threshold}) = {totalTimeout} seconds
        </Text>

        <Layout.Horizontal flex={{ justifyContent: 'space-between' }}>
          <Button variation={ButtonVariation.TERTIARY} text="← Back" onClick={onBack} />
          <Button variation={ButtonVariation.PRIMARY} text="Next: Load Test →" onClick={handleNext} />
        </Layout.Horizontal>
      </Layout.Vertical>
    </Container>
  );
}
```

### Task 2: Implement Step 5 — Load Test

**File to Create:** `AgentCert/chaoscenter/web/src/views/AppsOnboarding/steps/Step5LoadTest.tsx`

```typescript
import React, { useState } from 'react';
import { Color, FontVariation } from '@harnessio/design-system';
import { Button, ButtonVariation, Container, Layout, Text } from '@harnessio/uicore';
import type { ContributionFormData, LoadTestMethod } from '../types';
import css from '../AppsOnboarding.module.scss';

interface Step5Props {
  data: ContributionFormData;
  onNext: (patch: Partial<ContributionFormData>) => void;
  onBack: () => void;
}

const OPTIONS: { value: LoadTestMethod; title: string; description: string }[] = [
  {
    value: 'built-in',
    title: 'My app has a built-in traffic generator',
    description: '(OTel Demo, apps with otelgen, Fortio)',
  },
  {
    value: 'standard',
    title: 'Use ACE\'s standard load generator',
    description: 'Image: litmuschaos/litmus-app-deployer:latest',
  },
  {
    value: 'custom-job',
    title: 'I\'ll provide a custom K8s Job for load generation',
    description: 'Paste your Job YAML below',
  },
  {
    value: 'skip',
    title: 'Skip load test (not recommended)',
    description: '⚠ Without traffic, most faults produce no observable signal. Certifier scoring will be lower quality.',
  },
];

export default function Step5LoadTest({ data, onNext, onBack }: Step5Props): React.ReactElement {
  const [method, setMethod] = useState<LoadTestMethod>(data.loadTestMethod);
  const [jobYAML, setJobYAML] = useState(data.customJobYAML);

  return (
    <Container className={css.stepContainer}>
      <Text font={{ variation: FontVariation.H4 }} color={Color.GREY_800} className={css.stepTitle}>
        Step 5 of 6 — Load Test
      </Text>

      <Layout.Vertical spacing="large">
        <Text font={{ variation: FontVariation.BODY }} color={Color.GREY_600}>
          For meaningful chaos results, traffic must be flowing during fault injection.
        </Text>

        <Layout.Vertical spacing="small">
          {OPTIONS.map(opt => (
            <label key={opt.value} className={`${css.radioCard} ${method === opt.value ? css.radioCardSelected : ''}`}>
              <input
                type="radio"
                name="loadTestMethod"
                value={opt.value}
                checked={method === opt.value}
                onChange={() => setMethod(opt.value)}
                className={css.radioInput}
              />
              <Layout.Vertical spacing="xsmall">
                <Text font={{ variation: FontVariation.BODY1 }} color={Color.GREY_800}>{opt.title}</Text>
                <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_500}>{opt.description}</Text>
              </Layout.Vertical>
            </label>
          ))}
        </Layout.Vertical>

        {method === 'custom-job' && (
          <div className={css.field}>
            <label className={css.fieldLabel}>K8s Job YAML</label>
            <textarea
              className={css.yamlEditor}
              value={jobYAML}
              onChange={e => setJobYAML(e.target.value)}
              placeholder="apiVersion: batch/v1&#10;kind: Job&#10;..."
              rows={10}
            />
          </div>
        )}

        <Layout.Horizontal flex={{ justifyContent: 'space-between' }}>
          <Button variation={ButtonVariation.TERTIARY} text="← Back" onClick={onBack} />
          <Button
            variation={ButtonVariation.PRIMARY}
            text="Next: Review →"
            onClick={() => onNext({ loadTestMethod: method, customJobYAML: jobYAML })}
          />
        </Layout.Horizontal>
      </Layout.Vertical>
    </Container>
  );
}
```

### Task 3: Implement the YAML Generator

**File to Create:** `AgentCert/chaoscenter/web/src/views/AppsOnboarding/generator.ts`

This function generates the `app.yaml` content from `ContributionFormData`. It is pure string rendering — no exec.

```typescript
import type { ContributionFormData, DiscoveredService } from './types';

export function generateAppYAML(data: ContributionFormData): string {
  const selectedServices = data.discoveredServices.filter(s => s.included);

  const microservicesYAML = selectedServices.map(svc => `    - name: ${svc.name}
      displayName: ${svc.name}
      k8s:
        label: "${svc.label}"
        kind: ${svc.kind}
        namespace: "{{.AppNamespace}}"
      criticality: ${svc.criticality}
      relevantFaults: [pod-delete, pod-cpu-hog]
      dependsOn: []`).join('\n');

  const installSection = data.installMethod === 'external-helm'
    ? `  install:
    method: external-helm
    chartRef:
      repo: "${data.chartRepoURL}"
      chart: "${data.chartName}"
      version: "${data.chartVersion}"
    namespace:
      default: ${data.defaultNamespace || 'my-app'}
      configurable: false
    timeout: ${data.installTimeout}
    wait: true`
    : `  install:
    method: helm
    folder: ${data.name}
    namespace:
      default: ${data.defaultNamespace || 'my-app'}
      configurable: false
    timeout: ${data.installTimeout}
    wait: true`;

  const loadTestSection = (() => {
    switch (data.loadTestMethod) {
      case 'built-in': return `  loadTest:
    enabled: false
    method: external`;
      case 'standard': return `  loadTest:
    enabled: true
    method: deployer
    image: litmuschaos/litmus-app-deployer:latest
    args: ["-namespace=loadtest", "-app=loadtest"]`;
      case 'custom-job': return `  loadTest:
    enabled: true
    method: job
    jobSpec: {}  # Paste your Job YAML inline`;
      case 'skip': return `  loadTest:
    enabled: false`;
    }
  })();

  return `apiVersion: ace.io/v1
kind: AppCatalogEntry
metadata:
  name: ${data.name}
  displayName: "${data.displayName}"
  version: "1.0.0"
  tier: community
  domain: ${data.domain}
  capabilityDomains: [${data.domain}, common]
  tags: []
  maintainers:
    - name: ${data.maintainerName}
      email: ${data.maintainerEmail}

spec:
  description:
    short: "${data.shortDescription}"
    long: |
      ${data.longDescription.split('\n').join('\n      ')}
    suitableFor: []
    notSuitableFor: []

${installSection}

  healthProbe:
    url: "${data.healthProbeURL}"
    expectedStatus: "${data.healthProbeStatus}"
    initialDelaySeconds: ${data.initialDelaySeconds}
    periodSeconds: ${data.periodSeconds}
    failureThreshold: ${data.failureThreshold}

${loadTestSection}

  microservices:
${microservicesYAML}

  faultCompatibility:
    - faultName: pod-delete
      compatible: true
      notes: "Adjust based on your app's actual fault behavior"
      recommendedTargets: [${selectedServices.slice(0, 2).map(s => s.name).join(', ')}]

  rbac:
    chaosRunnerPermissions:
      - apiGroups: [""]
        resources: [pods, events, "pods/exec", "pods/log"]
        verbs: [get, list, watch, delete, create]
      - apiGroups: [apps]
        resources: [deployments, replicasets, statefulsets]
        verbs: [get, list, watch, patch]
      - apiGroups: [litmuschaos.io]
        resources: [chaosengines, chaosexperiments, chaosresults]
        verbs: [get, list, create, update, patch, delete, watch]
      - apiGroups: ["batch"]
        resources: [jobs]
        verbs: [get, list, create, delete, watch]
`;
}

export function generateReadmeMD(data: ContributionFormData): string {
  const selectedServices = data.discoveredServices.filter(s => s.included);
  return `# ${data.displayName}

**Domain:** ${data.domain}  
**Version:** 1.0.0  
**Tier:** Community  
**Maintainer:** ${data.maintainerName}

## Overview

${data.longDescription}

## Microservices

| Service | K8s Label | Kind | Criticality |
|---------|----------|------|-------------|
${selectedServices.map(s => `| ${s.name} | ${s.label} | ${s.kind} | ${s.criticality} |`).join('\n')}

## Install

\`\`\`bash
helm install ${data.name} catalog/apps/community/${data.name}/chart \\
  --namespace ${data.defaultNamespace} --create-namespace --timeout ${data.installTimeout} --wait
\`\`\`

Health probe: \`${data.healthProbeURL}\` → expects HTTP ${data.healthProbeStatus}.
`;
}

export function downloadFilesAsZip(appYAML: string, readmeMD: string, appName: string): void {
  // Simple download without a zip lib: download each file separately
  downloadFile(`${appName}-app.yaml`, appYAML);
  setTimeout(() => downloadFile(`${appName}-README.md`, readmeMD), 300);
}

function downloadFile(filename: string, content: string): void {
  const blob = new Blob([content], { type: 'text/plain' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}
```

### Task 4: Implement Step 6 — Review & Generate

**File to Create:** `AgentCert/chaoscenter/web/src/views/AppsOnboarding/steps/Step6Review.tsx`

```typescript
import React, { useEffect, useState } from 'react';
import { Color, FontVariation } from '@harnessio/design-system';
import { Button, ButtonVariation, Container, Layout, Text } from '@harnessio/uicore';
import type { ContributionFormData } from '../types';
import { generateAppYAML, generateReadmeMD, downloadFilesAsZip } from '../generator';
import css from '../AppsOnboarding.module.scss';

interface Step6Props {
  data: ContributionFormData;
  onBack: () => void;
}

export default function Step6Review({ data, onBack }: Step6Props): React.ReactElement {
  const [appYAML, setAppYAML] = useState('');
  const [readmeMD, setReadmeMD] = useState('');
  const [showPreview, setShowPreview] = useState(false);

  useEffect(() => {
    setAppYAML(generateAppYAML(data));
    setReadmeMD(generateReadmeMD(data));
  }, [data]);

  const selectedServices = data.discoveredServices.filter(s => s.included);
  const compatibleFaults = 1; // pod-delete always added in generator

  return (
    <Container className={css.stepContainer}>
      <Text font={{ variation: FontVariation.H4 }} color={Color.GREY_800} className={css.stepTitle}>
        Step 6 of 6 — Review & Generate
      </Text>

      <Layout.Vertical spacing="large">
        <Text font={{ variation: FontVariation.H5 }} color={Color.GREY_700}>Your app spec summary:</Text>

        <div className={css.summaryGrid}>
          <div className={css.summaryRow}><span>Name:</span><strong>{data.name}</strong></div>
          <div className={css.summaryRow}><span>Domain:</span><strong>{data.domain}</strong></div>
          <div className={css.summaryRow}><span>Tier:</span><strong>Community (pending review)</strong></div>
          <div className={css.summaryRow}><span>Services:</span><strong>{selectedServices.length} services for fault targeting</strong></div>
          <div className={css.summaryRow}><span>Faults:</span><strong>Compatible with pod-delete + {compatibleFaults} fault(s)</strong></div>
          <div className={css.summaryRow}><span>Load Test:</span><strong>{data.loadTestMethod}</strong></div>
        </div>

        <Layout.Vertical spacing="small">
          <Text font={{ variation: FontVariation.H6 }} color={Color.GREY_700}>ACE will generate these files:</Text>
          <div className={css.fileList}>
            <div className={css.fileItem}>✅ catalog/apps/community/{data.name}/app.yaml</div>
            <div className={css.fileItem}>✅ catalog/apps/community/{data.name}/docs/README.md</div>
            <div className={`${css.fileItem} ${css.fileItemOptional}`}>
              ⬜ catalog/apps/community/{data.name}/ground-truth/
              <Text font={{ variation: FontVariation.SMALL }} color={Color.GREY_400}>
                (optional — add fault→alert ground truth for certifier)
              </Text>
            </div>
          </div>
        </Layout.Vertical>

        {showPreview && (
          <Layout.Vertical spacing="small">
            <Text font={{ variation: FontVariation.H6 }} color={Color.GREY_600}>app.yaml preview:</Text>
            <pre className={css.yamlPreview}>{appYAML}</pre>
          </Layout.Vertical>
        )}

        <Button
          variation={ButtonVariation.LINK}
          text={showPreview ? 'Hide preview' : 'Preview app.yaml'}
          onClick={() => setShowPreview(v => !v)}
        />

        <Layout.Vertical spacing="small">
          <Text font={{ variation: FontVariation.H6 }} color={Color.GREY_700}>What happens next:</Text>
          <ol className={css.nextSteps}>
            <li>Download the generated files</li>
            <li>Open a PR to the ACE monorepo</li>
            <li>CI runs schema validation + helm lint</li>
            <li>Community review (typically 2–3 business days)</li>
            <li>Merge → app live in catalog</li>
          </ol>
        </Layout.Vertical>

        <Layout.Horizontal spacing="medium" flex={{ justifyContent: 'space-between', alignItems: 'center' }}>
          <Button variation={ButtonVariation.TERTIARY} text="← Back" onClick={onBack} />
          <Layout.Horizontal spacing="medium">
            <Button
              variation={ButtonVariation.PRIMARY}
              text="Download Files"
              icon="download"
              onClick={() => downloadFilesAsZip(appYAML, readmeMD, data.name)}
            />
          </Layout.Horizontal>
        </Layout.Horizontal>
      </Layout.Vertical>
    </Container>
  );
}
```

### Task 5: Wire Steps 4–6 into the Wizard Shell

**File to Modify:** `AgentCert/chaoscenter/web/src/views/AppsOnboarding/AppsOnboarding.tsx`

```typescript
// Add imports
import Step4HealthProbe from './steps/Step4HealthProbe';
import Step5LoadTest from './steps/Step5LoadTest';
import Step6Review from './steps/Step6Review';

// Replace the switch default:
case 4: return <Step4HealthProbe data={formData} onNext={next} onBack={back} />;
case 5: return <Step5LoadTest data={formData} onNext={next} onBack={back} />;
case 6: return <Step6Review data={formData} onBack={back} />;
```

---

## Files to Create (Summary)

```
AgentCert/chaoscenter/web/src/views/AppsOnboarding/
├── generator.ts                  (new)
└── steps/
    ├── Step4HealthProbe.tsx       (new)
    ├── Step5LoadTest.tsx          (new)
    └── Step6Review.tsx            (new)
```

**Files to Modify:**
- `AppsOnboarding.tsx` — add Steps 4–6 to the switch
- `AppsOnboarding.module.scss` — add styles for new step elements

---

## Verification Criteria

### Must Pass
- [ ] TypeScript compilation passes
- [ ] Step 4 rejects URLs without `{{.AppNamespace}}`
- [ ] Step 5 shows all 4 load test options; custom job shows YAML textarea
- [ ] Step 6 shows correct summary (name, domain, service count)
- [ ] "Preview app.yaml" shows generated YAML
- [ ] "Download Files" triggers browser download of `app.yaml` and `README.md`
- [ ] Generated `app.yaml` passes `catalog/validate.sh` schema check

### Should Pass
- [ ] Generated YAML contains the `{{.AppNamespace}}` template variable in healthProbe.url
- [ ] All 6 steps navigable forward and back

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo/AgentCert/chaoscenter/web

# Type check
yarn tsc --noEmit

# Dev server — fill out all 6 wizard steps, download files, validate
yarn start

# After download: validate the generated app.yaml
cd /srv/projects/ace-monorepo
python3 -m jsonschema -i /path/to/downloaded-app.yaml catalog/app-spec-schema.json
```

---

## Success Criteria

Stage 10 is complete when:
1. All 6 wizard steps render and navigate
2. Generated `app.yaml` contains correct `{{.AppNamespace}}` in health probe URL
3. Browser downloads both files when "Download Files" is clicked
4. TypeScript compiles cleanly

## Next Stage

Proceed to **Stage 11: Backend Contribution Endpoints**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
