# Stage 03: App Spec JSON Schema for CI Validation

**Phase:** 0 — Full Spec Creation  
**Dependencies:** Stage 02  
**Risk Level:** Low

---

## Objectives

1. Write `catalog/app-spec-schema.json` — JSON Schema for validating any `app.yaml` file
2. Write a simple validation script `catalog/validate.sh` that runs CI checks from spec §20.1
3. Verify the Sock Shop `app.yaml` (Stage 02) passes all schema checks

---

## Current State Analysis

### What We Have
- Completed `catalog/apps/official/sock-shop/app.yaml` from Stage 02
- Spec §20.1 defines 8 automated CI checks

### What We Need
- JSON Schema that encodes the `AppCatalogEntry` structure
- Validation script that implements the checks not covered by JSON Schema (e.g., `{{.AppNamespace}}` template variable check)
- This schema is what the `CatalogService` (Stage 04) uses to validate entries at load time

---

## Pre-Stage Verification

```bash
# Stage 02 complete
ls /srv/projects/ace-monorepo/catalog/apps/official/sock-shop/app.yaml

# Check jsonschema tool availability
python3 -m jsonschema --version 2>/dev/null || pip install jsonschema
```

---

## Implementation Tasks

### Task 1: Write `catalog/app-spec-schema.json`

**File:** `catalog/app-spec-schema.json`

The schema enforces the required fields from spec §5. Key rules:
- `metadata.name` must match `^[a-z0-9][a-z0-9-]*[a-z0-9]$` (max 63 chars)
- `metadata.tier` must be `official` or `community`
- `description.short` must be ≤ 120 chars
- `install.method` must be `helm`, `external-helm`, or `manifests`
- At least one maintainer required
- `faultCompatibility` array must have at least one entry

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "ACE AppCatalogEntry",
  "description": "Schema for ACE catalog app.yaml files (spec §5)",
  "type": "object",
  "required": ["apiVersion", "kind", "metadata", "spec"],
  "properties": {
    "apiVersion": {
      "type": "string",
      "const": "ace.io/v1"
    },
    "kind": {
      "type": "string",
      "const": "AppCatalogEntry"
    },
    "metadata": {
      "type": "object",
      "required": ["name", "displayName", "version", "tier", "domain", "capabilityDomains", "maintainers"],
      "properties": {
        "name": {
          "type": "string",
          "pattern": "^[a-z0-9][a-z0-9-]*[a-z0-9]$",
          "maxLength": 63,
          "description": "Stable primary key. Kebab-case. Cannot change after experiments reference it."
        },
        "displayName": {
          "type": "string",
          "minLength": 1,
          "maxLength": 80
        },
        "version": {
          "type": "string",
          "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+$",
          "description": "SemVer string"
        },
        "tier": {
          "type": "string",
          "enum": ["official", "community"]
        },
        "domain": {
          "type": "string",
          "description": "Must match an id in catalog/domains.yaml"
        },
        "capabilityDomains": {
          "type": "array",
          "items": { "type": "string" },
          "minItems": 1
        },
        "tags": {
          "type": "array",
          "items": { "type": "string" }
        },
        "maintainers": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "object",
            "required": ["name", "email"],
            "properties": {
              "name": { "type": "string" },
              "email": {
                "type": "string",
                "format": "email"
              }
            }
          }
        },
        "license": { "type": "string" },
        "repository": { "type": "string", "format": "uri" }
      }
    },
    "spec": {
      "type": "object",
      "required": ["description", "install", "healthProbe", "microservices", "faultCompatibility"],
      "properties": {
        "description": {
          "type": "object",
          "required": ["short", "long", "suitableFor"],
          "properties": {
            "short": {
              "type": "string",
              "minLength": 10,
              "maxLength": 120
            },
            "long": { "type": "string" },
            "suitableFor": {
              "type": "array",
              "minItems": 1,
              "items": { "type": "string" }
            },
            "notSuitableFor": {
              "type": "array",
              "items": { "type": "string" }
            }
          }
        },
        "install": {
          "type": "object",
          "required": ["method", "namespace", "timeout"],
          "properties": {
            "method": {
              "type": "string",
              "enum": ["helm", "external-helm", "manifests"]
            },
            "folder": { "type": "string" },
            "chartRef": {
              "type": "object",
              "required": ["repo", "chart", "version"],
              "properties": {
                "repo": { "type": "string" },
                "chart": { "type": "string" },
                "version": {
                  "type": "string",
                  "pattern": "^[0-9]+\\.[0-9]+\\.[0-9]+",
                  "description": "Must be pinned SemVer, no 'latest' or '*'"
                }
              }
            },
            "namespace": {
              "type": "object",
              "required": ["default"],
              "properties": {
                "default": { "type": "string" },
                "configurable": { "type": "boolean" }
              }
            },
            "timeout": {
              "type": "string",
              "pattern": "^[0-9]+(m|h|s)$"
            },
            "wait": { "type": "boolean" }
          }
        },
        "healthProbe": {
          "type": "object",
          "required": ["url", "expectedStatus"],
          "properties": {
            "url": {
              "type": "string",
              "description": "Must contain {{.AppNamespace}}, not a hardcoded namespace"
            },
            "expectedStatus": {
              "type": "string",
              "pattern": "^[0-9]{3}$"
            },
            "initialDelaySeconds": { "type": "integer", "minimum": 0 },
            "periodSeconds": { "type": "integer", "minimum": 1 },
            "failureThreshold": { "type": "integer", "minimum": 1 }
          }
        },
        "loadTest": {
          "type": "object",
          "required": ["enabled"],
          "properties": {
            "enabled": { "type": "boolean" },
            "method": {
              "type": "string",
              "enum": ["deployer", "job", "external"]
            },
            "image": { "type": "string" },
            "args": {
              "type": "array",
              "items": { "type": "string" }
            }
          }
        },
        "microservices": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "object",
            "required": ["name", "k8s"],
            "properties": {
              "name": {
                "type": "string",
                "pattern": "^[a-z0-9][a-z0-9-]*$"
              },
              "displayName": { "type": "string" },
              "description": { "type": "string" },
              "k8s": {
                "type": "object",
                "required": ["label", "kind"],
                "properties": {
                  "label": {
                    "type": "string",
                    "pattern": "^[a-zA-Z0-9._/-]+=.+$",
                    "description": "Must be key=value format"
                  },
                  "kind": {
                    "type": "string",
                    "enum": ["deployment", "statefulset", "daemonset"]
                  },
                  "namespace": { "type": "string" },
                  "containerName": { "type": "string" }
                }
              },
              "relevantFaults": {
                "type": "array",
                "items": { "type": "string" }
              },
              "criticality": {
                "type": "string",
                "enum": ["high", "medium", "low"]
              },
              "dependsOn": {
                "type": "array",
                "items": { "type": "string" }
              }
            }
          }
        },
        "faultCompatibility": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "object",
            "required": ["faultName", "compatible"],
            "properties": {
              "faultName": { "type": "string" },
              "compatible": { "type": "boolean" },
              "notes": { "type": "string" },
              "recommendedTargets": {
                "type": "array",
                "items": { "type": "string" }
              }
            }
          }
        },
        "rbac": {
          "type": "object",
          "properties": {
            "chaosRunnerPermissions": {
              "type": "array",
              "items": { "type": "object" }
            }
          }
        },
        "inputs": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["key", "displayName", "type", "helmPath"],
            "properties": {
              "key": { "type": "string" },
              "displayName": { "type": "string" },
              "description": { "type": "string" },
              "type": {
                "type": "string",
                "enum": ["string", "integer", "boolean", "enum"]
              },
              "required": { "type": "boolean" },
              "default": { "type": "string" },
              "helmPath": { "type": "string" },
              "values": {
                "type": "array",
                "items": { "type": "string" }
              },
              "min": { "type": "integer" },
              "max": { "type": "integer" },
              "unit": { "type": "string" },
              "advanced": { "type": "boolean" }
            }
          }
        }
      }
    }
  }
}
```

### Task 2: Write `catalog/validate.sh`

**File:** `catalog/validate.sh`

This script implements the CI checks from spec §20.1 that are not covered by JSON Schema alone:

```bash
#!/usr/bin/env bash
# ACE Catalog Validation Script
# Implements spec §20.1 automated CI checks
set -euo pipefail

CATALOG_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="$CATALOG_DIR/app-spec-schema.json"
DOMAINS_FILE="$CATALOG_DIR/domains.yaml"
EXIT_CODE=0

# Extract valid domain IDs from domains.yaml
VALID_DOMAINS=$(python3 -c "
import yaml, sys
domains = yaml.safe_load(open('$DOMAINS_FILE'))
print(' '.join(d['id'] for d in domains['domains']))
")

validate_app() {
  local app_yaml="$1"
  local app_dir="$(dirname "$app_yaml")"
  local app_name=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['metadata']['name'])")
  local tier=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['metadata']['tier'])")
  local method=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['spec']['install']['method'])")
  local domain=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['metadata']['domain'])")

  echo "--- Validating: $app_yaml ---"

  # Check 1: Schema validation
  if ! python3 -m jsonschema -i "$app_yaml" "$SCHEMA" 2>&1; then
    echo "FAIL [schema]: $app_yaml"
    EXIT_CODE=1
  else
    echo "PASS [schema]"
  fi

  # Check 2: Template variables — healthProbe.url must use {{.AppNamespace}}
  local probe_url=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['spec']['healthProbe']['url'])")
  if echo "$probe_url" | grep -q "{{.AppNamespace}}"; then
    echo "PASS [healthProbe.url template variable]"
  else
    echo "FAIL [healthProbe.url]: must use {{.AppNamespace}}, got: $probe_url"
    EXIT_CODE=1
  fi

  # Check 3: Alert rule exprs must use {{.AppNamespace}}
  local alert_fail=0
  python3 -c "
import yaml, sys
d = yaml.safe_load(open('$app_yaml'))
alerts = d.get('spec', {}).get('observability', {}).get('prometheus', {}).get('alertRules', [])
for a in alerts:
    if '{{.AppNamespace}}' not in a.get('expr', ''):
        print(f'FAIL [alert {a[\"name\"]}]: expr must use {{{{.AppNamespace}}}}: {a[\"expr\"][:80]}')
        sys.exit(1)
print(f'PASS [alert exprs]: {len(alerts)} rules checked')
" || EXIT_CODE=1

  # Check 4: Domain validity
  if echo "$VALID_DOMAINS" | tr ' ' '\n' | grep -qx "$domain"; then
    echo "PASS [domain: $domain]"
  else
    echo "FAIL [domain]: '$domain' not in domains.yaml. Valid: $VALID_DOMAINS"
    EXIT_CODE=1
  fi

  # Check 5: Version pin for external-helm
  if [ "$method" = "external-helm" ]; then
    local chart_version=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['spec']['install']['chartRef']['version'])")
    if echo "$chart_version" | grep -Eq "^[0-9]+\.[0-9]+\.[0-9]+"; then
      echo "PASS [version pin: $chart_version]"
    else
      echo "FAIL [version pin]: chartRef.version must be pinned SemVer, got: $chart_version"
      EXIT_CODE=1
    fi
  fi

  # Check 6: Maintainer email format (basic check)
  local email=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['metadata']['maintainers'][0]['email'])")
  if echo "$email" | grep -Eq "^[^@]+@[^@]+\.[^@]+$"; then
    echo "PASS [maintainer email: $email]"
  else
    echo "FAIL [maintainer email]: invalid format: $email"
    EXIT_CODE=1
  fi

  # Check 7: Official tier — ground truth must exist
  if [ "$tier" = "official" ]; then
    if [ -d "$app_dir/ground-truth" ]; then
      echo "PASS [ground-truth directory exists]"
    else
      echo "WARN [official tier]: ground-truth/ directory missing"
    fi
  fi

  echo ""
}

# Find all app.yaml files
find "$CATALOG_DIR/apps" -name "app.yaml" | sort | while read -r app_yaml; do
  validate_app "$app_yaml"
done

if [ $EXIT_CODE -eq 0 ]; then
  echo "=== All catalog entries validated successfully ==="
else
  echo "=== Validation FAILED ==="
  exit 1
fi
```

Make it executable:
```bash
chmod +x /srv/projects/ace-monorepo/catalog/validate.sh
```

---

## Files to Create (Summary)

```
catalog/
├── app-spec-schema.json    (new)
└── validate.sh             (new, chmod +x)
```

---

## Verification Criteria

### Must Pass
- [ ] `catalog/validate.sh` runs without error against `catalog/apps/official/sock-shop/app.yaml`
- [ ] JSON schema validates Sock Shop app.yaml
- [ ] `healthProbe.url` template variable check passes
- [ ] Alert rule expr template variable check passes
- [ ] Domain validity check passes (`cloud-native` in domains.yaml)

### Should Pass
- [ ] Deliberately broken app.yaml (wrong tier value, missing required field) is rejected by schema

---

## Testing Commands

```bash
cd /srv/projects/ace-monorepo

# Install jsonschema if needed
pip install jsonschema

# Run full validation
bash catalog/validate.sh

# Test schema directly against Sock Shop app.yaml
python3 -m jsonschema -i catalog/apps/official/sock-shop/app.yaml catalog/app-spec-schema.json && echo "SCHEMA OK"

# Negative test — validate that a broken app.yaml fails
python3 -c "
import json, yaml, jsonschema
schema = json.load(open('catalog/app-spec-schema.json'))
broken = {'apiVersion':'ace.io/v1','kind':'AppCatalogEntry','metadata':{'name':'bad app name!'},'spec':{}}
try:
    jsonschema.validate(broken, schema)
    print('ERROR: should have failed')
except jsonschema.ValidationError as e:
    print(f'OK: rejected as expected: {e.message[:60]}')
"
```

---

## Success Criteria

Stage 03 is complete when:
1. `catalog/app-spec-schema.json` exists and validates the Sock Shop `app.yaml` cleanly
2. `catalog/validate.sh` passes all checks on Sock Shop
3. Negative test confirms the schema rejects malformed entries
4. All verification criteria pass

## Next Stage

Proceed to **Stage 04: CatalogService Go Package**

---

**Stage Status:** Not Started  
**Last Updated:** 2026-07-07
