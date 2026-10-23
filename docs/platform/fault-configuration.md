---
title: "Fault configuration"
parent: "Control Plane"
grand_parent: "Deep Dive"
---

# Configure faults through Chaos Studio

Kubernetes and ITBench faults declare their editable environment variables in
`spec.configurations` in their own `<fault>.chartserviceversion.yaml`. Defaults
come from `spec.definition.env` in `fault.yaml`. The shared settings form displays
typed controls, bounds, dropdowns, help text, advanced settings and reset actions.

```yaml
spec:
  configurations:
    - key: BROKEN_TARGET_PORT
      label: Broken target port
      type: integer
      required: true
      min: 1
      max: 65535
      group: Injection
```

Supported types are `string`, `text`, `integer`, `number`, `boolean`, and `select`.
Each key must name a literal environment default already present in `fault.yaml`.
Environment variables remain strings when written into the ChaosEngine. Empty
optional numeric settings preserve the runner's existing default semantics.
Credentials and platform execution identity cannot be offered as editable fields.
Existing secret and ConfigMap references survive edits to other settings.

The API returns resolved fields and a hash of the fault definition and metadata.
The builder records the hub, category, fault name and hash on the ChaosEngine as
`agentcert.io/fault-source`. On save and manual/cron dispatch, the server loads
the authorized project's hub and validates the effective settings against its
current declarations. It does not trust field definitions supplied by a client.
Parsed definitions use a bounded content cache, so hub syncs and mounted file
edits take effect without restarting the server. Changed definitions require
removing and re-adding the fault, avoiding a silent change to saved experiments.

## Add a fault or setting

1. Implement the fault and publish its runner image if it introduces new behavior.
   ITBench's dispatcher must recognize the new experiment name.
2. Add the normal fault bundle and category index entry in the ChaosHub.
3. Declare defaults in `fault.yaml` and editable fields in the fault's CSV.
4. Sync the hub. The builder fetches the new fields without frontend changes.

An older hub without `spec.configurations` retains the existing tuning form.
Use `configurations: []` to explicitly offer no settings. Known built-in faults
in older workflows also receive validation; whole workflow parameter references
are checked against their resolved values.

## When edits apply

Settings are persisted in the experiment revision and materialized into each
submitted workflow. Changes apply to newly submitted runs. Existing workflow
pods retain their configuration. Configured ON_DEMAND faults keep their chosen
duration; the old 30-second normalization remains for legacy workflows.
For an existing schedule, save the revision and submit it with **Run** to update
its future ticks. CronWorkflow submission updates an existing schedule instead
of ignoring it as an already-created resource. The subscriber preserves live
controller status, ownership and finalizers and retries resource-version
conflicts. Saving a draft does not start it.
Active faults do not support hot reload. That requires a runner-specific update
channel, acknowledgement and revert behavior, rather than replacing pod env vars.

Resource targets such as Services retain their real kind in the saved manifest.
At dispatch, the shared target adapter encodes the resolved target into the SDK's
`TARGETS` environment variable and clears legacy `appinfo`. This accommodates the
installed operator's workload-only `appkind` schema without modifying its CRD.
Manual and scheduled runs use the same adapter. It runs after target parameters
are resolved and configuration validation succeeds; clients cannot edit `TARGETS`
through fault settings. Ambiguous target sources and reserved target delimiters
are rejected. Workload targets keep the existing operator path.
The target picker supports the catalog's Service and HorizontalPodAutoscaler
kinds and resolves compatibility using the canonical experiment name, rather
than a canvas node's instance suffix.

## Validation

Backend tests cover all 60 catalog faults and 455 fields, metadata reloads,
defaults, invalid ranges, duplicate variables, hidden references, stale revisions,
directory traversal, project-scoped resolution, legacy parameters and duration
handling. UI tests cover typed controls and save/reopen for Workflow and
CronWorkflow, including preserved secret references.

## Runtime check

Deploy the GraphQL update before the web update, and ensure the deployed hub
contains these metadata files. Use a separate application namespace for smoke
tests on `kind-agentcert-sachin-mourya`.

1. Add Kubernetes `pod-cpu-hog`. Set duration to 15 seconds, CPU cores to 1,
   and CPU load to 25%. Verify CPU load above 100% is rejected. Save and reopen;
   the settings should remain selected.
2. Run against the test application. Inspect the experiment pod's environment
   and confirm `TOTAL_CHAOS_DURATION=15`, `CPU_CORES=1`, and `CPU_LOAD=25`.
3. Add ITBench `modified-target-port-kubernetes-service`. Set a broken port
   such as 9998 that is unused by the test application, with a 15-second duration.
   Save, reopen, run, and verify the Service changes to 9998 and is restored.
4. Edit settings while that workflow runs. Confirm the existing workflow stays
   unchanged and a newly submitted run receives the new settings.
5. Repeat with a scheduled workflow. Sync a changed definition and verify the
   stale-definition message appears before saving or dispatching an old revision.

These smoke tests exercise configuration delivery and restoration. They do not
certify the behavior of every fault in the catalog.

### Verified on the current Kind cluster — 14 October 2026

The updated backend, web bundle and fault metadata are deployed in `ace` on
`kind-agentcert-sachin-mourya`. Test resources are isolated in
`ace-fault-config-smoke`; the target Deployment has a 200m CPU and 64Mi memory
limit. The application remains ready and its Service target port is `8080`.

| Check | Result |
| --- | --- |
| Backend configuration, chart settings, save validation, dispatch and ChaosHub tests | Passed |
| Six focused frontend suites | 38 tests passed |
| Subscriber cron submission regression | Passed; creation, revision update, concurrent conflict retry, permission error propagation and preservation of existing one-off workflows |
| Production frontend build | Passed; asset size and Sass deprecation warnings |
| Kubernetes `pod-cpu-hog` through the real operator | Pass; experiment env and helper command used duration 15, cores 1, load 25 |
| ITBench `modified-target-port-kubernetes-service` using the Go target adapter | Pass; port 9998 observed during injection, port 8080 verified after restoration; experiment env used duration 15 |
| Deployed GraphQL schema and web availability | Passed |
| Authenticated deployed metadata API | All 455 settings returned |
| Invalid settings and stale definition | CPU load 101, Service port 65536 and an obsolete definition revision rejected; invalid cron range also rejected |
| Browser CPU fault configuration | Numeric controls rendered; load 101 blocked with a range error; load 35 saved and reopened in a fresh browser session |
| Browser new ITBench fault selection | Service kind and isolated target selected; port 65536 blocked; port 9994 and duration 11 saved and reopened; backend independently confirmed the canonical source revision and target were preserved |
| Authenticated ACE save/reopen and manual dispatch | Both fault configurations persisted; CPU and ITBench workflow verdicts passed |
| Edit while running | Current CPU run retained load 25 and duration 15; the next run received load 40 and duration 12; both passed |
| Updated scheduled dispatch | Existing cron received port 9995 and duration 12; one scheduled workflow passed and restored port 8080; further ticks suspended |
| Full frontend TypeScript check | Blocked by existing dependency/compiler and repository type errors; touched code was also checked with ESLint |
| Full subscriber package test suite | Existing tests fail to compile because they reference the removed `InfraScope` variable; the new regression was run against all production package files and the production binary built successfully |

The early injector checks submitted ChaosEngines directly. Follow-up checks used
the authenticated ACE save/run APIs, the live UI, and the real scheduled
controller. Local fixture manifests, verdict reports, browser screenshots and
original deployment images are recorded under the ignored
`.tmp/fault-config-runtime/` directory. The isolated namespace and tagged test
experiments are retained for inspection. The unused schedule from the first
failed update test was removed; the verified schedule remains suspended.

To run the focused subscriber regression while its older tests are broken, from
`AgentCert/chaoscenter/subscriber`:

```sh
find pkg/k8s -maxdepth 1 -name '*.go' ! -name '*_test.go' -print0 |
  xargs -0 go test pkg/k8s/cron_test.go
go build .
```

Test images: GraphQL `agentcert/agentcert-graphql:fault-config-20261014-r2`,
web `agentcert/agentcert-web:fault-config-20261014-r2`, hub bundle
`agentcert/ace-hub-bundle:fault-config-20261014`, and subscriber
`agentcert/litmusportal-subscriber:fault-config-20261014`. These local image updates are
temporary deployment overrides, separate from Helm's normal image settings.
