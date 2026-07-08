# Fault YAML Validation Guide

**Date:** 2026-07-07

This guide explains how to validate `fault.yaml` files using the `ace fault validate` CLI stub
and the Go-level validation in the fault catalog loader.

---

## Validation Layers

ACE validates fault.yaml files at three layers:

| Layer | When | Tool |
|-------|------|------|
| Schema validation | Before committing a new fault | `catalog/validate.sh fault <path>` |
| YAML syntax | Continuous | `python3 -c "import yaml; yaml.safe_load(open(...))"` |
| Runtime loader validation | Server startup | Go `fault_catalog.LoadCatalog()` — logs WARNs for parse errors |

---

## Using `catalog/validate.sh fault`

The `fault validate` subcommand of `catalog/validate.sh` (added in Stage 01) checks:
1. Required top-level keys: `apiVersion`, `kind`, `metadata`, `spec`
2. `apiVersion` must be `ace.io/v1`
3. `kind` must be `FaultCatalogEntry`
4. Required `metadata` fields: `name`, `displayName`, `version`, `tier`, `scope`
5. `scope` must be `general`, `domain`, or `app-specific`
6. If `scope=domain`: `domain` must be non-null
7. If `scope=app-specific`: `targetApp` must be non-null
8. Required `spec` sections: `description`, `implementation`, `parameters`, `compatibility`, `groundTruth`

### Usage

```bash
# Validate a single fault.yaml
bash /srv/projects/ace-monorepo/catalog/validate.sh fault \
  /srv/projects/ace-monorepo/catalog/faults/general/pod-delete/fault.yaml

# Expected output on success:
# Validating fault: /srv/projects/ace-monorepo/catalog/faults/general/pod-delete/fault.yaml
# OK: /srv/projects/ace-monorepo/catalog/faults/general/pod-delete/fault.yaml is valid

# Validate all fault.yamls in the catalog
for f in $(find /srv/projects/ace-monorepo/catalog -name "fault.yaml"); do
  bash /srv/projects/ace-monorepo/catalog/validate.sh fault "$f" || exit 1
done
echo "All fault.yamls valid"
```

---

## Using `ace fault validate` (Future CLI)

The `ace` CLI stub described in the spec runs validation via:

```bash
ace fault validate catalog/faults/general/pod-delete/fault.yaml
```

Until the `ace` CLI is implemented, the `catalog/validate.sh fault` subcommand is the equivalent.
The `ace` CLI will eventually be a thin wrapper around the same validation logic.

---

## Common Validation Errors and Fixes

### Error: "Missing required top-level key: metadata"

**Cause:** The YAML file uses tabs instead of spaces, causing `grep` to miss the key.

**Fix:**
```bash
# Check for tabs
cat -A /path/to/fault.yaml | grep "^I"
# Replace tabs with 2-space indentation
sed -i 's/\t/  /g' /path/to/fault.yaml
```

---

### Error: "Invalid scope 'null'" or "scope is empty"

**Cause:** The `scope` field has a trailing space or is written as `scope:` with no value.

**Fix:**
```bash
# Check the scope line
grep -n "  scope:" /path/to/fault.yaml
# Correct format:
#   scope: general
```

---

### Error: "scope=domain requires a non-null domain value"

**Cause:** A domain fault is missing the `domain` field or has `domain: null`.

**Fix:**
```yaml
# Wrong:
metadata:
  scope: domain
  domain: null

# Correct:
metadata:
  scope: domain
  domain: cloud-native
```

---

### Error: "scope=app-specific requires a non-null targetApp value"

**Cause:** An app-specific fault is missing `targetApp` or has `targetApp: null`.

**Fix:**
```yaml
# Correct:
metadata:
  scope: app-specific
  domain: null
  targetApp: sock-shop
```

---

### Error: Python YAML parse error — `yaml.YAMLError`

**Cause:** The YAML file has a syntax error — unescaped special characters, wrong indentation,
or missing quotes.

**Fix:**
```bash
python3 -c "import yaml; yaml.safe_load(open('/path/to/fault.yaml'))" 2>&1
```
The error message includes the line number and character position. Common culprits:
- Bare `*` in a list: use `["*"]` not `[*]`
- Colon in a string without quoting: use `"key: value"` not `key: value` in string context
- Inconsistent indentation (2-space vs 4-space mixing)

---

### Error: "Missing spec section: groundTruth"

**Cause:** The `groundTruth` section is missing or misspelled.

**Fix:** Ensure the `groundTruth` key is exactly two spaces indented under `spec:`:
```yaml
spec:
  groundTruth:
    category: availability
    impact: high
    detectWithinSecs: 60
    mitigateWithinSecs: 120
    detectionHints: []
    remediationHints: []
```

---

## Go Loader Validation (Runtime)

The `fault_catalog.LoadCatalog()` function performs additional Go-level validation at server startup:

- **YAML parse failure**: Logs `WARN: fault_catalog: failed to parse <path>: ... — skipping`.
  The fault is excluded from the catalog but the server continues.
- **Wrong `kind`**: Files with `kind` other than `FaultCatalogEntry` are silently skipped.
  This prevents `app.yaml` or other YAML files in the same directories from being misloaded.
- **Duplicate name**: Logs `WARN: fault_catalog: duplicate fault name "<name>" in <path> — skipping`.
  The first-loaded entry wins.
- **Empty `name`**: A fault with an empty `metadata.name` is skipped with a WARN.

### Checking Loader Logs

After starting the server:
```bash
go run . 2>&1 | grep "fault_catalog" | head -20
```

Expected on clean startup:
```
INFO: fault_catalog: loaded 5 faults (2 general, 2 domain-specific, 1 app-specific)
```

Expected warnings to investigate:
```
WARN: fault_catalog: failed to parse catalog/faults/domains/telecom/snmp-trap-flood/fault.yaml: yaml: line 15: ...
WARN: fault_catalog: duplicate fault name "pod-delete" in catalog/faults/domains/cloud-native/pod-delete/fault.yaml — skipping
```

---

## CI Pipeline Checks (Added in Stage 01)

The ACE CI pipeline (GitHub Actions) runs the following checks on any PR that modifies a file
matching `catalog/faults/**/*.yaml` or `catalog/apps/**/faults/*.yaml`:

```yaml
# .github/workflows/fault-catalog-ci.yml (added as part of Stage 01)
name: Fault Catalog Validation

on:
  pull_request:
    paths:
      - 'catalog/faults/**/*.yaml'
      - 'catalog/apps/**/faults/*.yaml'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Validate YAML syntax
        run: |
          pip install pyyaml
          for f in $(find catalog -name "fault.yaml"); do
            python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "OK: $f"
          done

      - name: Validate fault schema
        run: |
          for f in $(find catalog -name "fault.yaml"); do
            bash catalog/validate.sh fault "$f"
          done

      - name: Check for duplicate fault names
        run: |
          NAMES=$(grep -rh "^  name:" catalog --include="fault.yaml" | awk '{print $2}' | sort)
          UNIQUE=$(echo "$NAMES" | sort -u)
          if [ "$(echo "$NAMES" | wc -l)" -ne "$(echo "$UNIQUE" | wc -l)" ]; then
            echo "FAIL: duplicate fault names detected:"
            comm -23 <(echo "$UNIQUE") <(echo "$NAMES" | sort -u)
            exit 1
          fi
          echo "OK: no duplicate fault names"
```

---

## Adding a New Fault — Checklist

Before submitting a PR with a new `fault.yaml`:

- [ ] File is in the correct path for its scope:
  - General: `catalog/faults/general/<name>/fault.yaml`
  - Domain: `catalog/faults/domains/<domain>/<name>/fault.yaml`
  - App-specific: `catalog/apps/<tier>/<app>/faults/<name>/fault.yaml`
- [ ] `bash catalog/validate.sh fault <path>` prints "OK"
- [ ] `python3 -c "import yaml; yaml.safe_load(open('<path>'))"` exits 0
- [ ] `metadata.name` is kebab-case and globally unique (check existing names with `grep -rh "^  name:" catalog --include="fault.yaml"`)
- [ ] `metadata.scope` + `domain` + `targetApp` combination is correct
- [ ] `spec.implementation.type` is set and all required implementation fields are present
- [ ] At least one parameter has `required: true`
- [ ] `spec.groundTruth.detectWithinSecs` and `mitigateWithinSecs` are positive integers
- [ ] If `type: litmus`: `experimentRef` matches a real ChaosExperiment in LitmusChaos Hub or is bundled in the same directory
- [ ] If `type: script`: Docker image is available in a registry accessible from the kind cluster
