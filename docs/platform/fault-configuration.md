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
`min`/`max` apply only to `integer` and `number`, `options` only to `select`, and
`pattern` (an RE2 regular expression) only to `string` and `text`.
Each key must name a literal environment default already present in `fault.yaml`,
and that default must itself be valid. Environment variables remain strings when
written into the ChaosEngine. Empty optional numeric settings preserve the
runner's existing default semantics. A `pattern` is also checked against an
empty value, so an optional patterned setting wraps its pattern as `^(...)?$`.
Credentials and platform execution identity cannot be offered as editable fields.
Existing secret and ConfigMap references survive edits to other settings.

Offer a variable only if the fault's runner (litmus-go) reads it. A variable left
out of `spec.configurations` is not editable in the form.

## Ranges and random choices

Some litmus-go runners accept a range, written `low-high`, for a numeric setting
and use a random whole number in it (`common.ValidateRange`). These settings are
declared as `string` with an anchored pattern that keeps the old bounds, for
example `^(100|[1-9]?[0-9])(-(100|[1-9]?[0-9]))?$` for a 0-100 percentage. Put
the lower bound first: a reversed range such as `100-50` makes the runner fail.

| Faults | Settings that accept a range |
| --- | --- |
| `pod-cpu-hog`, `pod-memory-hog`, `pod-io-stress` | `CPU_CORES`, `CPU_LOAD`, `MEMORY_CONSUMPTION`, `NUMBER_OF_WORKERS`, `FILESYSTEM_UTILIZATION_PERCENTAGE`, `FILESYSTEM_UTILIZATION_BYTES`, `PODS_AFFECTED_PERC` |
| `node-cpu-hog`, `node-memory-hog`, `node-io-stress` | `NODE_CPU_CORE`, `CPU_LOAD`, `CPU`, `MEMORY_CONSUMPTION_PERCENTAGE`, `MEMORY_CONSUMPTION_MEBIBYTES`, `NUMBER_OF_WORKERS`, `VM_WORKERS`, `FILESYSTEM_UTILIZATION_*`, `NODES_AFFECTED_PERC` |
| `disk-fill` | `FILL_PERCENTAGE` (1-100), `EPHEMERAL_STORAGE_MEBIBYTES`, `PODS_AFFECTED_PERC` |
| `pod-delete`, `container-kill`, `pod-http-*`, `pod-network-*` (except partition) | `PODS_AFFECTED_PERC` |

The same faults offer `random` for `SEQUENCE`, which picks `serial` or `parallel`
at run time. The `*-exec` and `pod-dns-*` faults support neither. The netem
percentages of `pod-network-loss`, `-corruption` and `-duplication` accept a
decimal such as `0.5` but not a range, because the runner builds the `tc netem`
command before it would resolve one.

## How settings are validated

The API returns resolved fields and a hash (revision) of the fault definition and
metadata. For a fault that has a `configurations` block, the builder records the
hub directory, category, fault name and revision on the ChaosEngine as
`agentcert.io/fault-source`. The engine's experiment name must equal
`metadata.name` in `fault.yaml`, which can differ from the directory name (three
ITBench faults do). On save and manual/cron dispatch, the server loads the
authorized project's hub and validates against its current declarations. It does
not trust field definitions supplied by a client.

- **Strict:** an annotated engine whose revision equals the current definition's.
  Declared settings are validated, and undeclared or hidden variables must equal
  their `fault.yaml` defaults.
- **Lenient:** an engine from an older revision, or a legacy unannotated engine
  (looked up by experiment name). Only declared settings that hold a literal value
  are checked against the current schema. `valueFrom` references and values
  containing `{{` (for example ConfigMap-backed workflow parameters) are skipped,
  and undeclared or hidden variables are accepted. Whole workflow parameter
  references in imported hub workflows are checked by their resolved values.

A hub update therefore never stops saved experiments or schedules. The builder
shows "definition changed" as non-blocking information. Parsed definitions use
a bounded content cache, so hub syncs and mounted file edits take effect without
restarting the server.

A fault without `spec.configurations` keeps the existing tuning form and is not
validated: a missing CSV or `fault.yaml`, a non-`ChaosExperiment` kind or a
repeated variable is an error only when a schema is present. Use
`configurations: []` to explicitly offer no settings.

## Add a fault or setting

1. Implement the fault and publish its runner image if it introduces new behavior.
   ITBench's dispatcher must recognize the new experiment name.
2. Add the normal fault bundle and category index entry in the ChaosHub.
3. Declare defaults in `fault.yaml` and editable fields in the fault's CSV.
   Check in litmus-go that the runner reads each variable, and whether it
   accepts ranges or `random` for that fault.
4. Sync the hub. The builder fetches the new fields without frontend changes.

## When edits apply

Settings are persisted in the experiment revision and materialized into each
submitted workflow. Changes apply to newly submitted runs. Existing workflow
pods retain their configuration. The source annotation is stamped only on faults
with a `configurations` block. Those keep their chosen ON_DEMAND duration;
schema-less faults keep the legacy 30-second normalization.
For an existing schedule, save the revision and submit it with **Run** to update
its future ticks. CronWorkflow submission updates an existing schedule instead
of ignoring it as an already-created resource. The subscriber preserves live
controller status, ownership and finalizers and retries resource-version
conflicts. Saving a draft does not start it.
Active faults do not support hot reload. That requires a runner-specific update
channel, acknowledgement and revert behavior, rather than replacing pod env vars.

## Targets

Resource targets such as Services retain their real kind in the saved manifest.
At dispatch, the shared target adapter runs after target parameters are resolved
and configuration validation succeeds:

- Workload kinds keep the existing operator `appinfo` path. `appkind: pod` also
  stays in `appinfo`, because cluster detection rewrites it.
- A non-workload kind with a selector is encoded into the SDK's `TARGETS`
  variable and `appinfo` is cleared. This accommodates the installed operator's
  workload-only `appkind` schema without modifying its CRD.
- A non-workload kind with an empty selector (for example the ConfigMap-based
  feature-flag fault) has `appinfo` cleared and gets no `TARGETS`.

Clients cannot edit `TARGETS` through fault settings. Ambiguous target sources
and reserved target delimiters are rejected. Manual and scheduled runs use the
same adapter. The target picker supports the catalog's Service and
HorizontalPodAutoscaler kinds and resolves compatibility using the canonical
experiment name, rather than a canvas node's instance suffix.

## Automated checks

From `AgentCert/chaoscenter/graphql/server`:

```sh
go test -count=1 ./pkg/chartconfig/... ./pkg/faultconfig/... ./pkg/chaoshub/...
```

`TestAllCatalogSettingsReachEngineEnvironment` parses every catalog fault and
logs `validated 60 faults and 446 configurable fields` for the current hub.
`TestHubExperimentsValidate` runs `ValidateWorkflow` over every
`chaos-charts/experiments/*/experiment*.yaml`. Other tests cover metadata reloads,
defaults, invalid ranges, duplicate variables, hidden references, strict and
lenient revisions, directory traversal, project-scoped resolution, legacy
parameters and duration handling. UI tests cover typed controls and save/reopen
for Workflow and CronWorkflow, including preserved secret references.

If the subscriber package's older tests do not compile, run the cron regression
against its production files only, from `AgentCert/chaoscenter/subscriber`:

```sh
find pkg/k8s -maxdepth 1 -name '*.go' ! -name '*_test.go' -print0 |
  xargs -0 go test pkg/k8s/cron_test.go
go build .
```

## Runtime check

Deploy the GraphQL update before the web update, and make sure the deployed hub
contains the updated metadata files. Run smoke tests against a dedicated
application namespace, never a shared one, on the cluster context you intend to
test.

1. Add Kubernetes `pod-cpu-hog`. Set duration to 15 seconds, CPU cores to 1 and
   CPU load to 25. Verify that CPU load 101 is rejected and that a range such as
   `25-50` is accepted. Save and reopen; the settings should remain selected.
2. Run it. Inspect the experiment pod's environment and confirm
   `TOTAL_CHAOS_DURATION=15`, `CPU_CORES=1` and `CPU_LOAD=25`; check that the
   helper's stress command uses the same values.
3. Add ITBench `modified-target-port-kubernetes-service`. Set a broken port that
   the test application does not use, such as 9998, with a 15-second duration.
   Verify port 65536 is rejected. Save, reopen and run; verify the Service changes
   to the broken port during injection and is restored afterwards.
4. Edit settings while that workflow runs. Confirm the existing workflow stays
   unchanged and a newly submitted run receives the new settings.
5. Repeat with a scheduled workflow and confirm the next tick uses the new
   settings. Then sync a changed definition: the builder shows "definition
   changed", the old revision still saves and dispatches, and a declared value
   that the new schema rejects is refused.
6. Confirm through the authenticated metadata API that every catalog setting is
   returned (446 for the current hub).

Remove or suspend test schedules and delete the smoke namespace afterwards. If
you deployed temporary images, restore Helm's normal image settings.

These smoke tests exercise configuration delivery and restoration. They do not
certify the behavior of every fault in the catalog.
