# Fault Catalog Schema Reference

**Source:** Spec §5, §6, §7, §8  
**Date:** 2026-07-07

This document is the authoritative field reference for `fault.yaml` files in the ACE catalog.
It mirrors spec §5 and adds implementation notes for each field.

---

## Top-Level Structure

```yaml
apiVersion: ace.io/v1           # Required. Must be exactly "ace.io/v1".
kind: FaultCatalogEntry         # Required. Must be exactly "FaultCatalogEntry".
metadata: { ... }               # Required. See Metadata Fields.
spec: { ... }                   # Required. See Spec Fields.
```

---

## Metadata Fields

| Field | Type | Required | Description | Implementation Notes |
|-------|------|----------|-------------|---------------------|
| `metadata.name` | string | Yes | Unique slug, kebab-case, e.g. `pod-delete` | Used as the lookup key in the in-memory catalog index. Must be globally unique across all scopes. |
| `metadata.displayName` | string | Yes | Human-readable name shown in the UI | Displayed in FaultLibraryPanel and parameter panel header. |
| `metadata.version` | string | Yes | SemVer string, e.g. `"1.0.0"` | Stored in `ExperimentDefinitionDoc.steps[].faultVersion` to pin the fault version at definition-creation time. |
| `metadata.tier` | enum | Yes | `official` or `community` | Determines the badge shown on the fault card. Official faults are maintained by the ACE team. |
| `metadata.scope` | enum | Yes | `general`, `domain`, or `app-specific` | Determines which catalog subdirectory the fault lives in and which apps can use it. |
| `metadata.domain` | string or null | Conditional | Required when `scope=domain`. Null for general. | Values: `cloud-native`, `telecom`, `health-it`, `finops`, `itops`. The loader uses this field to build the `byDomain` index. |
| `metadata.targetApp` | string or null | Conditional | Required when `scope=app-specific`. Null otherwise. | Must exactly match the `metadata.name` in the app's `app.yaml`. |
| `metadata.tags` | []string | No | Freeform tags for searching/filtering | Surfaced in the UI as filter chips. |
| `metadata.maintainers` | []Maintainer | No | List of `{name, email}` contacts | Displayed in fault detail view. |

---

## Spec Fields

### `spec.description`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `spec.description.short` | string | Yes | One-sentence summary. Shown in fault cards. |
| `spec.description.long` | string | Yes | Multi-paragraph description. Shown in detail panel. |
| `spec.description.suitableFor` | []string | No | Bulleted list of good use cases. |
| `spec.description.notSuitableFor` | []string | No | Bulleted list of cases where this fault should not be used. |

---

### `spec.implementation`

| Field | Type | Required | Description | Implementation Notes |
|-------|------|----------|-------------|---------------------|
| `spec.implementation.type` | enum | Yes | `litmus`, `http-fault`, `script`, or `external` | Determines the hydrator rendering path. |
| `spec.implementation.chaosKind` | string | Conditional | Required for `type: litmus`. Always `ChaosEngine`. | |
| `spec.implementation.experimentRef` | string | Conditional | Required for `type: litmus`. Name of the ChaosExperiment CR in the `litmus` namespace. | E.g., `pod-delete`, `pod-cpu-hog`. |
| `spec.implementation.namespace` | string | Conditional | Required for `type: litmus`. Always `litmus`. | ChaosEngine is created here. |
| `spec.implementation.image` | string | Conditional | Required for `type: script`. Docker image that runs the fault script. | Image must be pushed to a registry accessible from the kind cluster. |
| `spec.implementation.command` | []string | No | Command entrypoint for `type: script`. | |
| `spec.implementation.args` | []string | No | Arguments to the script command. | |
| `spec.implementation.endpoint` | string | Conditional | Required for `type: external`. HTTP endpoint to POST to. | Template variables: `{{.AppNamespace}}`, `{{.params.KEY}}`. |
| `spec.implementation.method` | string | No | HTTP method for `type: external`. Defaults to POST. | |

---

### `spec.targetSpec`

| Field | Type | Required | Description | Implementation Notes |
|-------|------|----------|-------------|---------------------|
| `spec.targetSpec.required` | bool | Yes | Whether a target microservice must be specified. | If false, the fault targets the whole namespace (use sparingly). |
| `spec.targetSpec.resolutionMode` | enum | Yes | `microservice-label`, `explicit-pod`, `node`, or `all-pods` | `microservice-label` is the standard mode: looks up `app.yaml microservices[name=...].k8s.label` to get the label selector. |

---

### `spec.parameters[]`

Each entry in the `parameters` array:

| Field | Type | Required | Description | Implementation Notes |
|-------|------|----------|-------------|---------------------|
| `key` | string | Yes | Machine-readable key, SCREAMING_SNAKE_CASE. | Used as the `name` in ChaosEngine env vars (via `litmusEnv`). |
| `displayName` | string | Yes | Human-readable label shown in the parameter form. | |
| `type` | enum | Yes | `integer`, `string`, `boolean`, `enum`, or `percent`. | Determines the form field type rendered in FaultParameterPanel. |
| `unit` | string | No | Unit for display: `seconds`, `percent`, `cores`, `megabytes`. | Appended to the input label. |
| `default` | string | Yes | Default value as a string. | Used when the user doesn't override this parameter. |
| `min` | int | No | Minimum value (for `integer` and `percent` types). | Enforced at hydration time. |
| `max` | int | No | Maximum value (for `integer` and `percent` types). | Enforced at hydration time. |
| `required` | bool | Yes | Whether the parameter must be set before the experiment can be submitted. | Required parameters with no value cause a validation error in `submitRun`. |
| `description` | string | Yes | Tooltip/help text shown below the form field. | |
| `litmusEnv` | string | Conditional | Required for `type: litmus` implementation. Maps to the LitmusChaos ENV var name in the ChaosEngine. | |
| `allowedValues` | []string | No | For `type: enum`. The allowed values. | Rendered as a `<select>` in the UI. |

---

### `spec.compatibility`

| Field | Type | Required | Description | Implementation Notes |
|-------|------|----------|-------------|---------------------|
| `spec.compatibility.targetDomains` | []string | Yes | Domains this fault applies to. `["*"]` means any domain. | Used by the catalog loader to populate `byDomain` index. |
| `spec.compatibility.incompatibleApps` | []string | No | App names this fault must NOT appear for in Chaos Studio. | Checked in `FaultsForApp()` after the three-tier merge. |
| `spec.compatibility.requiredCapabilities` | []string | No | Agent capabilities needed. Advisory only — shown in agent compatibility hints, not enforced. | E.g., `[snmp-trap-receiver]`. |

---

### `spec.observability`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `spec.observability.expectedSymptoms` | []string | Yes | List of observable symptoms when this fault is active. Shown in the fault detail view. |
| `spec.observability.expectedAlerts` | []string | No | Prometheus alert rule names expected to fire. |
| `spec.observability.detectionWindowSecs` | int | Yes | Expected time (seconds) for symptoms to become observable after fault injection starts. |

---

### `spec.groundTruth`

| Field | Type | Required | Description | Implementation Notes |
|-------|------|----------|-------------|---------------------|
| `spec.groundTruth.category` | enum | Yes | `availability`, `performance`, `security`, `data-integrity`, or `configuration` | Maps to the certifier scoring dimension. |
| `spec.groundTruth.impact` | enum | Yes | `low`, `medium`, `high`, or `critical` | Used in certifier reports to weight the fault's significance. |
| `spec.groundTruth.detectWithinSecs` | int | Yes | Default detection SLA in seconds. | Can be overridden per step in `experiment.yaml` via `groundTruthOverride`. |
| `spec.groundTruth.mitigateWithinSecs` | int | Yes | Default mitigation SLA in seconds. | Can be overridden per step in `experiment.yaml` via `groundTruthOverride`. |
| `spec.groundTruth.detectionHints` | []string | Yes | Human-readable hints for how to detect this fault. | Surfaced in the certifier report as context for detection scoring. |
| `spec.groundTruth.remediationHints` | []string | Yes | Human-readable hints for how to mitigate this fault. | Surfaced in the certifier report as context for mitigation scoring. |

---

## Valid Scope + Domain Combinations

| `scope` | `domain` | `targetApp` | Lives At |
|---------|----------|-------------|----------|
| `general` | `null` | `null` | `catalog/faults/general/<name>/fault.yaml` |
| `domain` | non-null string | `null` | `catalog/faults/domains/<domain>/<name>/fault.yaml` |
| `app-specific` | `null` | non-null string | `catalog/apps/<tier>/<app>/faults/<name>/fault.yaml` |

---

## Validation Rules (enforced by `catalog/validate.sh fault` subcommand)

1. `apiVersion` must be exactly `ace.io/v1`
2. `kind` must be exactly `FaultCatalogEntry`
3. `metadata.name` must be non-empty, kebab-case, globally unique in the catalog
4. `metadata.scope` must be one of: `general`, `domain`, `app-specific`
5. If `scope=domain`: `metadata.domain` must be non-null
6. If `scope=app-specific`: `metadata.targetApp` must be non-null
7. `spec.description.short` must be non-empty
8. `spec.implementation.type` must be one of: `litmus`, `http-fault`, `script`, `external`
9. If `type=litmus`: `spec.implementation.experimentRef` and `namespace` must be non-empty
10. If `type=script`: `spec.implementation.image` must be non-empty
11. At least one entry in `spec.parameters[]` must have `required: true` (strongly recommended)
12. `spec.groundTruth.detectWithinSecs` and `mitigateWithinSecs` must be > 0

---

## Full Example: `pod-delete` Fault

See `catalog/faults/general/pod-delete/fault.yaml` (created in Stage 01).

---

## Full Example: `snmp-trap-flood` Fault

See `catalog/faults/domains/telecom/snmp-trap-flood/fault.yaml` (created in Stage 01).
