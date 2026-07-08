#!/usr/bin/env bash
# ACE Catalog Validation Script
# Implements spec §20.1 automated CI checks
# Usage:
#   ./validate.sh              Validate all app.yaml files (legacy mode)
#   ./validate.sh app          Validate all app.yaml files
#   ./validate.sh fault <path> Validate a single fault.yaml
set -euo pipefail

CATALOG_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="$CATALOG_DIR/app-spec-schema.json"
DOMAINS_FILE="$CATALOG_DIR/domains.yaml"
EXIT_CODE=0

CMD="${1:-app}"
TARGET="${2:-}"

# Extract valid domain IDs from domains.yaml
VALID_DOMAINS=$(python3 -c "
import yaml, sys
domains = yaml.safe_load(open('$DOMAINS_FILE'))
print(' '.join(d['id'] for d in domains['domains']))
")

validate_app() {
  local app_yaml="$1"
  local app_dir
  app_dir="$(dirname "$app_yaml")"
  local app_name
  app_name=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['metadata']['name'])")
  local tier
  tier=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['metadata']['tier'])")
  local method
  method=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['spec']['install']['method'])")
  local domain
  domain=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['metadata']['domain'])")

  echo "--- Validating: $app_yaml ---"

  # Check 1: Schema validation
  if python3 -m jsonschema -i "$app_yaml" "$SCHEMA" 2>&1; then
    echo "PASS [schema]"
  else
    echo "FAIL [schema]: $app_yaml"
    EXIT_CODE=1
  fi

  # Check 2: Template variables — healthProbe.url must use {{.AppNamespace}}
  local probe_url
  probe_url=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['spec']['healthProbe']['url'])")
  if echo "$probe_url" | grep -q "{{.AppNamespace}}"; then
    echo "PASS [healthProbe.url template variable]"
  else
    echo "FAIL [healthProbe.url]: must use {{.AppNamespace}}, got: $probe_url"
    EXIT_CODE=1
  fi

  # Check 3: Alert rule exprs must use {{.AppNamespace}}
  python3 -c "
import yaml, sys
d = yaml.safe_load(open('$app_yaml'))
alerts = d.get('spec', {}).get('observability', {}).get('prometheus', {}).get('alertRules', [])
for a in alerts:
    if '{{.AppNamespace}}' not in a.get('expr', ''):
        print(f'FAIL [alert {a[\"name\"]}]: expr must use {{{{.AppNamespace}}}}')
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
    local chart_version
    chart_version=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['spec']['install']['chartRef']['version'])")
    if echo "$chart_version" | grep -Eq "^[0-9]+\.[0-9]+\.[0-9]+"; then
      echo "PASS [version pin: $chart_version]"
    else
      echo "FAIL [version pin]: chartRef.version must be pinned SemVer, got: $chart_version"
      EXIT_CODE=1
    fi
  fi

  # Check 6: Maintainer email format (basic check)
  local email
  email=$(python3 -c "import yaml; d=yaml.safe_load(open('$app_yaml')); print(d['metadata']['maintainers'][0]['email'])")
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

validate_fault() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "ERROR: File not found: $file" >&2
    exit 1
  fi

  echo "Validating fault: $file"

  # Check required top-level keys
  for key in apiVersion kind metadata spec; do
    if ! grep -q "^${key}:" "$file"; then
      echo "ERROR: Missing required top-level key: $key" >&2
      exit 1
    fi
  done

  # Check apiVersion
  if ! grep -q "^apiVersion: ace.io/v1" "$file"; then
    echo "ERROR: apiVersion must be 'ace.io/v1'" >&2
    exit 1
  fi

  # Check kind
  if ! grep -q "^kind: FaultCatalogEntry" "$file"; then
    echo "ERROR: kind must be 'FaultCatalogEntry'" >&2
    exit 1
  fi

  # Check metadata fields
  for field in name displayName version tier scope; do
    if ! grep -q "  ${field}:" "$file"; then
      echo "ERROR: Missing metadata field: $field" >&2
      exit 1
    fi
  done

  # Check valid scope
  scope=$(grep "  scope:" "$file" | awk '{print $2}')
  if [[ "$scope" != "general" && "$scope" != "domain" && "$scope" != "app-specific" ]]; then
    echo "ERROR: Invalid scope '$scope'. Must be: general, domain, app-specific" >&2
    exit 1
  fi

  # For domain scope, domain must be non-null
  if [[ "$scope" == "domain" ]]; then
    domain=$(grep "  domain:" "$file" | awk '{print $2}')
    if [[ "$domain" == "null" ]]; then
      echo "ERROR: scope=domain requires a non-null domain value" >&2
      exit 1
    fi
  fi

  # For app-specific scope, targetApp must be non-null
  if [[ "$scope" == "app-specific" ]]; then
    target=$(grep "  targetApp:" "$file" | awk '{print $2}')
    if [[ "$target" == "null" ]]; then
      echo "ERROR: scope=app-specific requires a non-null targetApp value" >&2
      exit 1
    fi
  fi

  # Check spec sections
  for section in description implementation parameters compatibility groundTruth; do
    if ! grep -q "  ${section}:" "$file"; then
      echo "ERROR: Missing spec section: $section" >&2
      exit 1
    fi
  done

  echo "OK: $file is valid"
}

case "$CMD" in
  fault)
    validate_fault "$TARGET"
    ;;
  app|"")
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
    ;;
  help|--help|-h)
    echo "Usage:"
    echo "  $0                        Validate all app.yaml files"
    echo "  $0 app                    Validate all app.yaml files"
    echo "  $0 fault <path-to-fault>  Validate a fault.yaml"
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    exit 1
    ;;
esac
