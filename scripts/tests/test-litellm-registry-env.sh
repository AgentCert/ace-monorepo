#!/usr/bin/env bash
# =============================================================================
# test-litellm-registry-env.sh — regression tests for the LLM Models registry
# settings: the .env keys setup.sh writes (scripts/lib/model_registry.sh) and
# how the Helm chart and docker-compose.yml turn LiteLLM's database on from
# them.
# =============================================================================
# Offline: no cluster, no containers. The Helm checks need helm, the compose
# wrapper check python3 with PyYAML; each section is skipped without them.
#
# Usage: ./scripts/tests/test-litellm-registry-env.sh
# Exit status: number of failed checks (0 = all passed).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
skip() { echo "  SKIP  $*"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "${name}"; else fail "${name}"; fi; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
section() { echo; echo "== $*"; }
extract_fn() { awk -v n="$1()" 'index($0, n)==1 {p=1} p {print} p && /^}/ {exit}' "$2"; }

SETUP=scripts/setup.sh
CHART=deploy/helm/ace
DERIVED_URL="postgresql://postgres:pw1@postgres:5432/litellm"

section "syntax"
check "bash -n model_registry.sh" bash -n scripts/lib/model_registry.sh
check "bash -n setup.sh" bash -n "${SETUP}"

section ".env keys (model_registry_env)"
# shellcheck source=../lib/model_registry.sh
source scripts/lib/model_registry.sh
ENV_FILE="${WORK}/env"
SETUP_PYTHON=python3
eval "$(extract_fn cur "${SETUP}")"
eval "$(extract_fn set_env "${SETUP}")"
printf 'POSTGRES_USER=postgres\nPOSTGRES_PASSWORD=pw1\nLITELLM_MODE=local\nLITELLM_DATABASE_URL=\nLITELLM_SALT_KEY=\n' > "${ENV_FILE}"

model_registry_env cur set_env model_registry_new_salt
salt="$(cur LITELLM_SALT_KEY)"
check "a salt key is generated (64 hex characters)" grep -qE '^[0-9a-f]{64}$' <<<"${salt}"
eq "the database URL is derived from the Postgres credentials" "$(cur LITELLM_DATABASE_URL)" "${DERIVED_URL}"

model_registry_env cur set_env model_registry_new_salt
eq "a second run keeps the salt key" "$(cur LITELLM_SALT_KEY)" "${salt}"
eq "a second run keeps the URL" "$(cur LITELLM_DATABASE_URL)" "${DERIVED_URL}"

set_env POSTGRES_PASSWORD pw2
model_registry_env cur set_env model_registry_new_salt
eq "the derived URL follows a password change" "$(cur LITELLM_DATABASE_URL)" "postgresql://postgres:pw2@postgres:5432/litellm"

set_env LITELLM_DATABASE_URL "postgresql://u:p@db.example.com:5432/registry"
model_registry_env cur set_env model_registry_new_salt
eq "a URL naming another server is kept" "$(cur LITELLM_DATABASE_URL)" "postgresql://u:p@db.example.com:5432/registry"

set_env LITELLM_DATABASE_URL ""
set_env LITELLM_MODE external
model_registry_env cur set_env model_registry_new_salt
eq "LITELLM_MODE=external leaves the URL empty" "$(cur LITELLM_DATABASE_URL)" ""
eq "LITELLM_MODE=external still keeps the salt key" "$(cur LITELLM_SALT_KEY)" "${salt}"
check "DATABASE_URL is never written to .env" bash -c "! grep -q '^DATABASE_URL=' '${ENV_FILE}'"

section "setup.sh wiring"
check "setup.sh sources model_registry.sh" grep -q 'source "${SCRIPT_DIR}/lib/model_registry.sh"' "${SETUP}"
check "k8s_env_patch writes the registry keys" bash -c "$(declare -f extract_fn); extract_fn k8s_env_patch '${SETUP}' | grep -q 'model_registry_env cur set_env model_registry_new_salt'"

section "Helm chart"
if command -v helm >/dev/null 2>&1; then
    # The LiteLLM Deployment's pod spec, rendered with the given --set flags.
    litellm_deployment() {
        helm template ace "${CHART}" "$@" 2>/dev/null > "${WORK}/render.yaml"
        python3 - "${WORK}/render.yaml" <<'PY'
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "Deployment" and doc["metadata"]["name"] == "litellm":
        print(yaml.safe_dump(doc["spec"]["template"]["spec"]))
PY
    }
    on="$(litellm_deployment --set env.LITELLM_DATABASE_URL="${DERIVED_URL}" --set env.LITELLM_SALT_KEY=s)"
    off="$(litellm_deployment)"
    no_salt="$(litellm_deployment --set env.LITELLM_DATABASE_URL="${DERIVED_URL}" --set env.LITELLM_SALT_KEY=)"
    check "registry on: DATABASE_URL comes from the LITELLM_DATABASE_URL secret key" \
        python3 -c "import sys,yaml; env=yaml.safe_load(sys.argv[1])['containers'][0]['env']; assert any(e['name']=='DATABASE_URL' and e['valueFrom']['secretKeyRef']['key']=='LITELLM_DATABASE_URL' for e in env)" "${on}"
    check "registry on: STORE_MODEL_IN_DB=True" grep -q "value: 'True'" <<<"${on}"
    check "registry on: LiteLLM waits for Postgres" grep -q "name: wait-for-db" <<<"${on}"
    check "registry off: no DATABASE_URL" bash -c "! grep -q DATABASE_URL <<<'${off}'"
    check "a URL without a salt key leaves the registry off" bash -c "! grep -q 'name: DATABASE_URL' <<<'${no_salt}'"
    check "no --detailed_debug (it logs every API key)" bash -c "! grep -q detailed_debug <<<'${on}${off}'"
    check "the ace-env Secret never carries DATABASE_URL" bash -c "! helm template ace '${CHART}' --set env.LITELLM_DATABASE_URL=x --set env.LITELLM_SALT_KEY=s 2>/dev/null | grep -q '^  DATABASE_URL:'"
else
    skip "helm not installed"
fi

section "docker-compose.yml LiteLLM wrapper"
if python3 -c 'import yaml' 2>/dev/null; then
    python3 - docker-compose.yml > "${WORK}/wrapper.sh" <<'PY'
import sys, yaml
service = yaml.safe_load(open(sys.argv[1]))["services"]["litellm"]
assert service["entrypoint"][:2] == ["/bin/sh", "-c"], service["entrypoint"]
print(service["entrypoint"][2].replace("$$", "$"))  # Compose's own unescaping
PY
    command_line="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["services"]["litellm"]["command"])' docker-compose.yml)"
    check "no --detailed_debug in the command" bash -c "! grep -q detailed_debug <<<'${command_line}'"
    # Run the wrapper against a stand-in for the image's entrypoint.
    mkdir -p "${WORK}/app/docker"
    printf '#!/bin/sh\necho "DATABASE_URL=${DATABASE_URL-<unset>} STORE_MODEL_IN_DB=${STORE_MODEL_IN_DB-<unset>} ARGS=$*"\n' > "${WORK}/app/docker/prod_entrypoint.sh"
    chmod +x "${WORK}/app/docker/prod_entrypoint.sh"
    wrap() { (cd "${WORK}/app" && env -i PATH="${PATH}" "$@" /bin/sh -c "$(cat "${WORK}/wrapper.sh")" -- --config /app/config.yaml --port 4000); }
    eq "both set: the registry is on and the args pass through" \
        "$(wrap LITELLM_DATABASE_URL="${DERIVED_URL}" LITELLM_SALT_KEY=s)" \
        "DATABASE_URL=${DERIVED_URL} STORE_MODEL_IN_DB=True ARGS=--config /app/config.yaml --port 4000"
    eq "no salt key: off" "$(wrap LITELLM_DATABASE_URL="${DERIVED_URL}" LITELLM_SALT_KEY=)" \
        "DATABASE_URL=<unset> STORE_MODEL_IN_DB=<unset> ARGS=--config /app/config.yaml --port 4000"
    eq "empty URL: off, DATABASE_URL never set empty" "$(wrap LITELLM_DATABASE_URL= LITELLM_SALT_KEY=s)" \
        "DATABASE_URL=<unset> STORE_MODEL_IN_DB=<unset> ARGS=--config /app/config.yaml --port 4000"
    check "graphql reaches the admin API by service name" \
        python3 -c "import sys,yaml; e=yaml.safe_load(open(sys.argv[1]))['services']['graphql']['environment']; assert e['LITELLM_ADMIN_URL']=='\${LITELLM_ADMIN_URL_COMPOSE:-http://litellm:4000}'" docker-compose.yml
else
    skip "python3 without PyYAML"
fi

echo
echo "${PASS} passed, ${FAIL} failed"
exit "${FAIL}"
