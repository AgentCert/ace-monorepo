#!/usr/bin/env bash
# =============================================================================
# test-registry-tooling.sh — regression tests for the image-registry tooling
# (docs/setup/registry-migration-plan.md, Phases 0-6).
# =============================================================================
# Offline by default: no cluster, no registry, no network. Covers
#   * syntax of every script involved, YAML of the sync manifest
#   * deploy/images.txt format
#   * the naming rule (scripts/lib/registry.sh) and its Python twin
#     (scripts/lib/resolve_image_env.py) — they must agree on every image
#   * resolve_image_env.py scenarios (local vs registry, legacy values, ...)
#   * setup.sh's .env migration block, values-env generator and ace-env
#     Secret builder, run exactly as they are in setup.sh (kubectl stubbed)
#
#   * the Helm "ace" chart (ace.image helper vs registry.sh on every image,
#     local flags, pull secrets), the agent charts, the installers' imageref copy
#
#   --online   also: check-registry-images.sh on both paths (needs registry
#              access + credentials in .env), mirror-images.sh --dry-run, the Go
#              test suites (graphql, install-app, install-agent) in golang:1.24
#              with a bash->Go naming parity fixture, and the app charts
#              (sock-shop, bookinfo, otel-demo) rendered through install-app's
#              post-renderer (needs Docker + network for the otel subchart)
#
# Usage: ./scripts/tests/test-registry-tooling.sh [--online]
# Exit status: number of failed checks (0 = all passed).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1
ONLINE=0; [[ "${1:-}" == "--online" ]] && ONLINE=1
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "${name}"; else fail "${name}"; fi; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
section() { echo; echo "== $*"; }

# Print one shell function's definition from a file (top-level `name() {` … `}`).
extract_fn() { awk -v n="$1()" 'index($0, n)==1 {p=1} p {print} p && /^}/ {exit}' "$2"; }

# shellcheck source=../lib/registry.sh
source scripts/lib/registry.sh
R="infyartifactory.jfrog.io/docker-local"

section "syntax"
for f in scripts/lib/registry.sh scripts/check-registry-images.sh scripts/mirror-images.sh \
         scripts/build-and-push.sh scripts/apply_cluster_prereqs.sh scripts/prepare-images.sh \
         scripts/setup.sh; do
    check "bash -n ${f}" bash -n "${f}"
done
check "python compiles resolve_image_env.py" python3 -m py_compile scripts/lib/resolve_image_env.py
if python3 -c 'import yaml' 2>/dev/null; then
    check "registry-secret-sync.yaml parses (5 documents)" python3 -c "
import yaml; d=list(yaml.safe_load_all(open('deploy/registry-secret-sync.yaml')))
assert [x['kind'] for x in d]==['ServiceAccount','ClusterRole','ClusterRoleBinding','ConfigMap','Deployment']
open('${WORK}/sync.sh','w').write(d[3]['data']['sync.sh'])"
    check "embedded sync.sh: bash -n" bash -n "${WORK}/sync.sh"
else
    echo "  SKIP  YAML checks (python3 yaml module not installed)"
fi

section "inventory (deploy/images.txt)"
cols="$(grep -vE '^\s*(#|$)' deploy/images.txt | awk -F'|' '{print NF}' | sort -u | tr '\n' ' ')"
eq "rows have 3 (mirror) or 6 (build/optional) columns" "${cols}" "3 6 "
dups="$(INCLUDE_OPTIONAL=1 inventory_rows deploy/images.txt all | while IFS='|' read -r _ _ i _; do image_canonical "$i"; echo; done | sort | uniq -d)"
eq "no duplicate images" "${dups}" ""
bad_build="$(inventory_rows deploy/images.txt build | while IFS='|' read -r _ _ i c r _; do
    [[ "${r}" == compose:* || "${r}" == hub-bundle || -f "${c}/${r}" ]] || echo "${i}"; done)"
eq "every build row's Dockerfile exists" "${bad_build}" ""
check "invalid-image fault images are not listed" bash -c "! grep -qE 'hello-bench-invalid|arm64v8/busybox' <(grep -v '^#' deploy/images.txt)"

section "naming rule (registry.sh)"
IMAGE_REGISTRY=""; IMAGE_MIRROR_NAMESPACE=agentcert
eq "empty: mongo:5 -> frozen copy"   "$(registry_ref mongo:5)" "agentcert/mongo:5"
eq "empty: untagged gets :latest"    "$(registry_ref gaiadocker/iproute2)" "agentcert/gaiadocker-iproute2:latest"
eq "empty: docker.io/ dropped"       "$(registry_ref docker.io/library/mongo)" "agentcert/mongo:latest"
eq "empty: quay host dropped, flat"  "$(registry_ref quay.io/containers/kubernetes_mcp_server:v0.0.67)" "agentcert/containers-kubernetes_mcp_server:v0.0.67"
eq "empty: flat name mapping"        "$(image_flat_ref localhost:5000/a/b:latest agentcert)" "agentcert/a-b:latest"
eq "empty: no frozen copy -> upstream" "$(registry_ref nginx:1.25)" "nginx:1.25"
eq "empty: unknown host:port -> upstream" "$(registry_ref localhost:5000/a/b)" "localhost:5000/a/b:latest"
eq "empty: ACE image unchanged"      "$(registry_ref agentcert/certifier:latest)" "agentcert/certifier:latest"
eq "empty: scarf go-runner alias"    "$(registry_ref litmuschaos.docker.scarf.sh/litmuschaos/go-runner:latest)" "agentcert/litmuschaos-go-runner:latest"
eq "empty: upstream_ref is the source" "$(upstream_ref quay.io/containers/x:v1)" "quay.io/containers/x:v1"
IMAGE_MIRROR_NAMESPACE=none
eq "namespace none: upstream name"   "$(registry_ref quay.io/containers/kubernetes_mcp_server:v0.0.67)" "quay.io/containers/kubernetes_mcp_server:v0.0.67"
IMAGE_MIRROR_NAMESPACE=agentcert
IMAGE_REGISTRY="${R}"
eq "set: mongo:5 under agentcert/"     "$(registry_ref mongo:5)" "${R}/agentcert/mongo:5"
eq "set: quay keeps host in path"    "$(registry_ref quay.io/containers/x:v1)" "${R}/agentcert/quay.io/containers/x:v1"
eq "set: cgr untagged"               "$(registry_ref cgr.dev/chainguard/minio)" "${R}/agentcert/cgr.dev/chainguard/minio:latest"
eq "set: ACE image not doubled"       "$(registry_ref agentcert/certifier:latest)" "${R}/agentcert/certifier:latest"
eq "set: idempotent"                  "$(registry_ref "${R}/agentcert/mongo:5")" "${R}/agentcert/mongo:5"
IMAGE_MIRROR_NAMESPACE=none
eq "set, namespace none: flat layout" "$(registry_ref mongo:5)" "${R}/mongo:5"
eq "set, namespace none: ACE image"   "$(registry_ref agentcert/certifier:latest)" "${R}/agentcert/certifier:latest"
IMAGE_MIRROR_NAMESPACE=agentcert
eq "host"                            "$(registry_host)" "infyartifactory.jfrog.io"
eq "normalize UI url"                "$(registry_normalize https://infyartifactory.jfrog.io/ui/native/docker-local/)" "${R}"
check "bare JFrog host rejected"     bash -c "source scripts/lib/registry.sh; IMAGE_REGISTRY=infyartifactory.jfrog.io; ! registry_load /dev/null"
eq "source normalize jfrog"          "$(image_source_normalize jfrog)" "registry"
eq "source normalize DockerHub"      "$(image_source_normalize DockerHub)" "registry"
eq "source normalize local"          "$(image_source_normalize local)" "local"
check "placeholder counts as unset"  value_is_unset dckr_pat_REPLACE_ME
# A registry already ending in the namespace folder resolves to the same place.
IMAGE_REGISTRY="${R}/agentcert"
eq "agentcert path: ACE image not doubled" "$(registry_ref agentcert/certifier:latest)" "${R}/agentcert/certifier:latest"
eq "agentcert path: third-party under it"  "$(registry_ref mongo:5)" "${R}/agentcert/mongo:5"
eq "agentcert path: quay keeps host"       "$(registry_ref quay.io/containers/x:v1)" "${R}/agentcert/quay.io/containers/x:v1"
eq "agentcert path: idempotent"            "$(registry_ref "${R}/agentcert/certifier:latest")" "${R}/agentcert/certifier:latest"
IMAGE_REGISTRY="${R}"
eq "docker-local: ACE image at the same place" "$(registry_ref agentcert/certifier:latest)" "${R}/agentcert/certifier:latest"
# ACE_IMAGE_TAG: release tag for ACE-built images only.
ACE_IMAGE_TAG=RELEASE-7
IMAGE_REGISTRY="${R}/agentcert"
eq "release tag: ACE image"                "$(registry_ref agentcert/agentcert-graphql:latest)" "${R}/agentcert/agentcert-graphql:RELEASE-7"
eq "release tag: pinned ACE tag replaced"  "$(registry_ref agentcert/litmusportal-subscriber:3.0.0)" "${R}/agentcert/litmusportal-subscriber:RELEASE-7"
eq "release tag: untagged ACE image"       "$(registry_ref agentcert/certifier)" "${R}/agentcert/certifier:RELEASE-7"
eq "release tag: third-party untouched"    "$(registry_ref mongo:5)" "${R}/agentcert/mongo:5"
eq "release tag: digest untouched"         "$(registry_ref agentcert/certifier@sha256:abc)" "${R}/agentcert/certifier@sha256:abc"
IMAGE_REGISTRY=""
eq "release tag: Docker Hub ACE image"     "$(registry_ref agentcert/certifier:latest)" "agentcert/certifier:RELEASE-7"
eq "release tag: frozen copy untouched"    "$(registry_ref python:3.11-slim)" "agentcert/python:3.11-slim"
eq "release tag: Docker Hub idempotent"    "$(registry_ref agentcert/certifier:RELEASE-7)" "agentcert/certifier:RELEASE-7"
check "release tag loaded from .env" bash -c "source scripts/lib/registry.sh; printf 'IMAGE_REGISTRY=${R}/agentcert\nACE_IMAGE_TAG=RELEASE-9\n' > '${WORK}/tag.env'; unset IMAGE_REGISTRY ACE_IMAGE_TAG; registry_load '${WORK}/tag.env'; [[ \$(registry_ref agentcert/certifier:latest) == '${R}/agentcert/certifier:RELEASE-9' ]]"
unset ACE_IMAGE_TAG
IMAGE_REGISTRY="${R}"

section "bash/Python naming parity (every inventory image, registry set and empty)"
mapfile -t imgs < <(INCLUDE_OPTIONAL=1 inventory_rows deploy/images.txt all | cut -d'|' -f3)
for reg in "" "${R}" "${R}/agentcert"; do
  for ns in agentcert none; do
   for tag in "" RELEASE-7; do
    IMAGE_REGISTRY="${reg}"; IMAGE_MIRROR_NAMESPACE="${ns}"; ACE_IMAGE_TAG="${tag}"
    bash_out="$(for i in "${imgs[@]}"; do registry_ref "$i"; echo; done)"
    py_out="$(python3 - "${reg}" "${ns}" "${tag}" "${imgs[@]}" <<'PY'
import sys; sys.path.insert(0, "scripts/lib"); import resolve_image_env as r
for i in sys.argv[4:]: print(r.registry_ref(i, sys.argv[1], sys.argv[2], sys.argv[3]))
PY
)"
    eq "parity (${#imgs[@]} images, IMAGE_REGISTRY='${reg}', namespace=${ns}, tag='${tag}')" "${bash_out}" "${py_out}"
   done
  done
done
IMAGE_MIRROR_NAMESPACE=agentcert; unset ACE_IMAGE_TAG
# Distinct upstream images must not collapse onto one Docker Hub copy.
IMAGE_REGISTRY=""
dupes="$(for i in "${imgs[@]}"; do printf '%s %s\n' "$(registry_ref "$i")" "$(upstream_ref "$i")"; done \
         | sort -u | awk '{print $1}' | uniq -d \
         | grep -v '^agentcert/litmuschaos-go-runner:latest$' || true)"
eq "no two upstream images share a flat name (go-runner scarf alias is the same image)" "${dupes}" ""

section "resolve_image_env.py"
python3 - "${R}" <<'PY'
import sys; sys.path.insert(0, "scripts/lib"); import resolve_image_env as r
R = sys.argv[1]; fails = 0
base = {"INSTALL_APPLICATION_IMAGE": "agentcert/agentcert-install-app:latest",
        "SUBSCRIBER_IMAGE": "agentcert/litmusportal-subscriber:3.0.0",
        "FLASH_AGENT_IMAGE": "agentcert/agentcert-flash-agent:latest"}
def case(name, env, want):
    global fails
    out, _ = r.resolve(env)
    bad = {k: (out.get(k), v) for k, v in want.items() if out.get(k) != v}
    print(("  PASS  " if not bad else "  FAIL  ") + name + (f" {bad}" if bad else "")); fails += bool(bad)
case("empty registry: nothing prefixed", {**base, "IMAGE_REGISTRY": "", "INSTALL_APP_IMAGE_SOURCE": "registry"},
     {"INSTALL_APPLICATION_IMAGE": None, "LITMUS_HELPER_IMAGES_REGISTRY_PREFIX": "docker.io"})
case("empty registry: third-party infra image -> frozen agentcert/ copy",
     {"IMAGE_REGISTRY": "", "LITMUS_IMAGES_SOURCE": "registry", "CHAOS_OPERATOR_IMAGE": "litmuschaos/chaos-operator:3.0.0",
      "KUBERNETES_MCP_SERVER_IMAGE": "quay.io/containers/kubernetes_mcp_server:v0.0.67"},
     {"CHAOS_OPERATOR_IMAGE": "agentcert/litmuschaos-chaos-operator:3.0.0",
      "KUBERNETES_MCP_SERVER_IMAGE": "agentcert/containers-kubernetes_mcp_server:v0.0.67"})
case("empty registry + IMAGE_MIRROR_NAMESPACE=none: upstream names",
     {"IMAGE_REGISTRY": "", "IMAGE_MIRROR_NAMESPACE": "none", "LITMUS_IMAGES_SOURCE": "registry",
      "CHAOS_OPERATOR_IMAGE": "litmuschaos/chaos-operator:3.0.0"}, {"CHAOS_OPERATOR_IMAGE": None})
case("local sources: nothing prefixed", {**base, "IMAGE_REGISTRY": R, "INSTALL_APP_IMAGE_SOURCE": "local",
     "LITMUS_IMAGES_SOURCE": "local"}, {"INSTALL_APPLICATION_IMAGE": None, "SUBSCRIBER_IMAGE": None,
     "LITMUS_HELPER_IMAGES_REGISTRY_PREFIX": "docker.io"})
case("registry sources: prefixed", {**base, "IMAGE_REGISTRY": R, "INSTALL_APP_IMAGE_SOURCE": "registry",
     "LITMUS_IMAGES_SOURCE": "registry", "SRE_AGENTS_IMAGE_SOURCE": "registry"},
     {"INSTALL_APPLICATION_IMAGE": f"{R}/agentcert/agentcert-install-app:latest",
      "SUBSCRIBER_IMAGE": f"{R}/agentcert/litmusportal-subscriber:3.0.0",
      "FLASH_AGENT_IMAGE": f"{R}/agentcert/agentcert-flash-agent:latest",
      "LITMUS_HELPER_IMAGES_REGISTRY_PREFIX": f"{R}/agentcert/"})
case("legacy jfrog/dockerhub = registry", {**base, "IMAGE_REGISTRY": R, "INSTALL_APP_IMAGE_SOURCE": "jfrog",
     "LITMUS_IMAGES_SOURCE": "dockerhub"}, {"INSTALL_APPLICATION_IMAGE": f"{R}/agentcert/agentcert-install-app:latest",
     "SUBSCRIBER_IMAGE": f"{R}/agentcert/litmusportal-subscriber:3.0.0"})
case("no double prefix", {"IMAGE_REGISTRY": R, "INSTALL_APP_IMAGE_SOURCE": "registry",
     "INSTALL_APPLICATION_IMAGE": f"{R}/agentcert/agentcert-install-app:latest"}, {"INSTALL_APPLICATION_IMAGE": None})
sys.exit(fails)
PY
rc=$?; FAIL=$((FAIL + rc)); PASS=$((PASS + 5 - rc))
check ".env.example resolves to public names only" bash -c "! python3 scripts/lib/resolve_image_env.py .env.example | grep -q jfrog"
check ".env.example has no legacy registry keys" bash -c "! grep -qE '^(JFROG_|DOCKERHUB_|LITMUS_HELPER_IMAGES_REGISTRY_PREFIX)' .env.example"

section "setup.sh .env migration (run as-is from setup.sh)"
sed -n '/^# Image registry settings now live in one place/,/^      _src_key _img_key _img_val _legacy_prefix$/p' scripts/setup.sh > "${WORK}/migrate.sh"
{ extract_fn cur scripts/setup.sh; extract_fn set_env scripts/setup.sh; } > "${WORK}/helpers.sh"
cat > "${WORK}/run-migrate.sh" <<EOF
set -euo pipefail
SETUP_PYTHON=python3; ENV_FILE="\$1"; ok() { :; }
source "${REPO_ROOT}/scripts/lib/registry.sh"; source "${WORK}/helpers.sh"; source "${WORK}/migrate.sh"
EOF
printf '%s\n' INSTALL_APP_IMAGE_SOURCE=jfrog LITMUS_IMAGES_SOURCE=local \
    "INSTALL_APPLICATION_IMAGE=${R}/agentcert/agentcert-install-app:latest" \
    JFROG_HOST=infyartifactory.jfrog.io JFROG_REGISTRY_PATH=docker-local JFROG_USER=alice JFROG_TOKEN=t1 \
    DOCKERHUB_USERNAME=YOUR_DOCKERHUB_EMAIL_OR_USERNAME > "${WORK}/legacy-jfrog.env"
bash "${WORK}/run-migrate.sh" "${WORK}/legacy-jfrog.env"
env_get() { env_file_value "$1" "${WORK}/$2"; }
eq "jfrog source -> registry"            "$(env_get INSTALL_APP_IMAGE_SOURCE legacy-jfrog.env)" "registry"
eq "IMAGE_REGISTRY from JFROG_*"         "$(env_get IMAGE_REGISTRY legacy-jfrog.env)" "${R}"
eq "REGISTRY_USERNAME from JFROG_USER"   "$(env_get REGISTRY_USERNAME legacy-jfrog.env)" "alice"
eq "image prefix stripped"               "$(env_get INSTALL_APPLICATION_IMAGE legacy-jfrog.env)" "agentcert/agentcert-install-app:latest"
eq "legacy key kept"                     "$(env_get JFROG_USER legacy-jfrog.env)" "alice"
cp "${WORK}/legacy-jfrog.env" "${WORK}/before-2nd.env"; bash "${WORK}/run-migrate.sh" "${WORK}/legacy-jfrog.env"
check "migration is idempotent" cmp -s "${WORK}/before-2nd.env" "${WORK}/legacy-jfrog.env"
printf '%s\n' INSTALL_APP_IMAGE_SOURCE=dockerhub DOCKERHUB_USERNAME=bob DOCKERHUB_TOKEN=dt > "${WORK}/legacy-dh.env"
bash "${WORK}/run-migrate.sh" "${WORK}/legacy-dh.env"
eq "dockerhub -> registry, registry stays empty" "$(env_get INSTALL_APP_IMAGE_SOURCE legacy-dh.env)|$(env_get IMAGE_REGISTRY legacy-dh.env)" "registry|"
eq "REGISTRY_USERNAME from DOCKERHUB_*"  "$(env_get REGISTRY_USERNAME legacy-dh.env)" "bob"
printf '%s\n' IMAGE_REGISTRY=infyartifactory.jfrog.io JFROG_REGISTRY_PATH=docker-local > "${WORK}/bare-host.env"
bash "${WORK}/run-migrate.sh" "${WORK}/bare-host.env"
eq "bare JFrog host gets repo path"      "$(env_get IMAGE_REGISTRY bare-host.env)" "${R}"

section "setup.sh deploy-time resolution (values-env.yaml and ace-env Secret)"
printf '%s\n' "IMAGE_REGISTRY=${R}" INSTALL_APP_IMAGE_SOURCE=registry INSTALL_AGENT_IMAGE_SOURCE=local \
    LITMUS_IMAGES_SOURCE=registry INSTALL_APPLICATION_IMAGE=agentcert/agentcert-install-app:latest \
    INSTALL_AGENT_IMAGE=agentcert/agentcert-install-agent:latest \
    SUBSCRIBER_IMAGE=agentcert/litmusportal-subscriber:3.0.0 > "${WORK}/deploy.env"
cp "${WORK}/deploy.env" "${WORK}/deploy.env.orig"
mkdir -p "${WORK}/root/deploy/helm/ace"
{ extract_fn dedup_env scripts/setup.sh; extract_fn generate_helm_values_env scripts/setup.sh
  extract_fn apply_ace_env_secret scripts/setup.sh; } > "${WORK}/deploy-fns.sh"
cat > "${WORK}/run-deploy.sh" <<EOF
set -euo pipefail
SETUP_PYTHON=python3; ENV_FILE="${WORK}/deploy.env"; REPO_ROOT="${WORK}/root"; SCRIPT_DIR="${REPO_ROOT}/scripts"
ok() { :; }
kubectl() { if [[ "\$1" == create ]]; then for a in "\$@"; do [[ "\$a" == --from-env-file=* ]] && cp "\${a#--from-env-file=}" "${WORK}/secret.env"; done; true; else cat >/dev/null; fi; }
source "${WORK}/deploy-fns.sh"
generate_helm_values_env
apply_ace_env_secret ace
EOF
check "generators run" bash "${WORK}/run-deploy.sh"
vals="${WORK}/root/deploy/helm/ace/values-env.yaml"
check "values-env: registry-sourced image prefixed" grep -q "INSTALL_APPLICATION_IMAGE: '${R}/agentcert/agentcert-install-app:latest'" "${vals}"
check "values-env: local-sourced image unchanged"   grep -q "INSTALL_AGENT_IMAGE: 'agentcert/agentcert-install-agent:latest'" "${vals}"
check "values-env: litmus prefix derived"           grep -q "LITMUS_HELPER_IMAGES_REGISTRY_PREFIX: '${R}/agentcert/'" "${vals}"
eq "Secret: registry-sourced image prefixed" "$(env_file_value INSTALL_APPLICATION_IMAGE "${WORK}/secret.env")" "${R}/agentcert/agentcert-install-app:latest"
eq "Secret: one entry per key" "$(grep -c '^INSTALL_APPLICATION_IMAGE=' "${WORK}/secret.env")" "1"
check ".env not modified by deploy generators" cmp -s "${WORK}/deploy.env" "${WORK}/deploy.env.orig"

section "Helm chart deploy/helm/ace (ace.image vs registry.sh)"
render_ace() { helm template ace deploy/helm/ace "$@" 2>&1; }
ace_images() { render_ace "$@" | sed -nE 's/^[[:space:]]+(- )?image:[[:space:]]*"?([^"[:space:]]+)"?.*/\2/p'; }
public_images="$(sed -n '/^images:/,/^[^[:space:]#]/p' deploy/helm/ace/values.yaml \
                 | sed -nE 's/^[[:space:]]+([a-zA-Z0-9]+):[[:space:]]*([^[:space:]#]+).*/\1 \2/p')"
check "chart renders (defaults)" render_ace
for cfg in "|agentcert|" "${R}|agentcert|registry-pull" "|none|"; do
    IFS='|' read -r creg cns csec <<<"${cfg}"
    want=""; bad=""
    while read -r _key img; do
        exp="$(IMAGE_REGISTRY="${creg}" IMAGE_MIRROR_NAMESPACE="${cns}" registry_ref "${img}")"
        want+="${exp}"$'\n'
    done <<<"${public_images}"
    got="$(ace_images --set-string imageRegistry="${creg}" --set-string imageMirrorNamespace="${cns}" \
                      --set-string imagePullSecretName="${csec}" --set chartsHub.bundleLocal=true | sort -u)"
    want="$(printf '%s' "${want}"; echo "agentcert/ace-hub-bundle:local")"
    eq "every chart image matches registry.sh (registry='${creg}', namespace=${cns})" \
       "${got}" "$(printf '%s\n' "${want}" | grep . | sort -u)"
done
loc_imgs="$(ace_images --set imageRegistry="${R}" --set aceImagesLocal=true --set runtimeImagesLocal=true --set chartsHub.bundleLocal=true \
            | grep -E 'agentcert-(graphql|auth|web)|agentcert/certifier|metrics-server|hub-bundle' | sort -u | tr '\n' ' ')"
eq "local flags keep side-loaded images' public names" "${loc_imgs}" \
   "agentcert/ace-hub-bundle:local agentcert/agentcert-auth:latest agentcert/agentcert-graphql:latest agentcert/agentcert-web:latest agentcert/certifier:latest registry.k8s.io/metrics-server/metrics-server:v0.7.2 "
pods="$(render_ace | grep -cE '^[[:space:]]+containers:')"
eq "pull secret on every pod spec when IMAGE_REGISTRY is set (${pods} pods)" \
   "$(render_ace --set imageRegistry="${R}" --set imagePullSecretName=registry-pull | grep -c 'imagePullSecrets:')" "${pods}"
eq "no pull secret on the public path" "$(render_ace --set imagePullSecretName=registry-pull | grep -c 'imagePullSecrets:')" "0"

section "Helm ace.image helper parity (every inventory image)"
mkdir -p "${WORK}/parity/templates"
printf 'apiVersion: v2\nname: parity\nversion: 0.1.0\n' > "${WORK}/parity/Chart.yaml"
cp deploy/helm/ace/templates/_helpers.tpl deploy/helm/ace/templates/_mirrored.tpl "${WORK}/parity/templates/"
printf '%s\n' '{{- range .Values.refs }}' '# {{ include "ace.image" (dict "root" $ "image" . "local" false) }}' '{{- end }}' \
    > "${WORK}/parity/templates/out.yaml"
refs_json="$(printf '%s\n' "${imgs[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
for reg in "" "${R}" "${R}/agentcert"; do
  for ns in agentcert none; do
   for tag in "" RELEASE-7; do
    helm_out="$(helm template p "${WORK}/parity" --set-json "refs=${refs_json}" --set-string imageRegistry="${reg}" \
                --set-string imageMirrorNamespace="${ns}" --set-string aceImageTag="${tag}" 2>&1 | grep -v '^---\|^# Source\|^$' | sed 's/^# //')"
    bash_out="$(for i in "${imgs[@]}"; do IMAGE_REGISTRY="${reg}" IMAGE_MIRROR_NAMESPACE="${ns}" ACE_IMAGE_TAG="${tag}" registry_ref "$i"; echo; done)"
    eq "Helm == bash (${#imgs[@]} images, registry='${reg}', namespace=${ns}, tag='${tag}')" "${helm_out}" "${bash_out}"
   done
  done
done

section "agent charts (registry guard, imagePullSecrets)"
for chart in agent-charts/charts/*/; do
    c="$(basename "${chart}")"
    out="$(helm template a "${chart}" --set agentId=x 2>&1)" || { fail "${c}: renders"; continue; }
    if grep -qE 'image: "/' <<<"${out}"; then fail "${c}: image starts with /"; else pass "${c}: renders, default images valid"; fi
    out="$(helm template a "${chart}" --set agentId=x --set agent.containerImage.registry= --set sidecar.image.registry= \
           --set 'imagePullSecrets[0].name=registry-pull' 2>&1)"
    if grep -qE 'image: "/' <<<"${out}"; then fail "${c}: empty registry renders a leading /";
    elif ! grep -q 'name: registry-pull' <<<"${out}"; then fail "${c}: imagePullSecrets value not rendered";
    else pass "${c}: empty registry guard + imagePullSecrets"; fi
done

section "installers share graphql's imageref code"
check "install-app/install-agent imageref.go copies are up to date" scripts/lib/sync-imageref.sh --check
check "install-app and install-agent registry.go are identical" cmp app-charts/install-app/registry.go agent-charts/install-agent/registry.go

section "Phase 6: Dockerfile base images"
inv_resolved() { INCLUDE_OPTIONAL=1 inventory_rows deploy/images.txt all | cut -d'|' -f3 | while read -r i; do registry_ref "$i"; echo; done | sort -u; }
dockerfiles="$(INCLUDE_OPTIONAL=1 inventory_rows deploy/images.txt build | while IFS='|' read -r _k _g _i c r _f; do
    [[ "${r}" == hub-bundle ]] && echo deploy/hub-bundle/Dockerfile || realpath -m --relative-to=. "${c}/${r}"; done | sort -u)"
literal_from="$(for f in ${dockerfiles}; do grep -HnE '^\s*FROM\s' "${f}" | grep -vE 'FROM\s+\$\{[A-Z0-9_]+_IMAGE\}' || true; done)"
eq "every FROM in the $(wc -w <<<"${dockerfiles}") built Dockerfiles uses a *_IMAGE build arg" "${literal_from}" ""
for reg in "" "${R}"; do
    IMAGE_REGISTRY="${reg}"
    known="$(inv_resolved)"
    unknown="$(for f in ${dockerfiles}; do dockerfile_base_image_args "${f}" | grep -v '^--build-arg$' | cut -d= -f2-; done \
               | sort -u | comm -23 - <(printf '%s\n' "${known}"))"
    eq "every resolved base image is in deploy/images.txt (registry='${reg}')" "${unknown}" ""
done
IMAGE_REGISTRY=""

section "Phase 6: docker compose"
compose_files="docker-compose.yml compose/langfuse/docker-compose.yml compose/langfuse.override.yml compose/litellm.override.yml"
raw_images="$(grep -hE '^\s+image:' ${compose_files} | grep -vE 'image:\s*\$\{(ACE_IMG_[A-Z0-9_]+|[A-Z0-9_]+_IMAGE):-[^}]+\}\s*$' || true)"
eq "every compose image is \${ACE_IMG_*:-...} or \${*_IMAGE:-...}" "${raw_images}" ""
for reg in "" "${R}"; do
    got="$( ( IMAGE_REGISTRY="${reg}"; printf 'IMAGE_REGISTRY=%s\nACE_INSTANCE_NAME=t\nLITELLM_PROXY_IMAGE=litellm/litellm:v1.82.0-stable\nCERTIFIER_IMAGE=agentcert/certifier:latest\n' "${reg}" > "${WORK}/c.env"
              compose_image_env "${WORK}/c.env" docker-compose.yml compose/langfuse/docker-compose.yml
              COMPOSE_PROFILES=mongo,litellm,ollama,langfuse docker compose --env-file "${WORK}/c.env" -f docker-compose.yml config 2>&1 ) \
           | sed -nE 's/^\s+image:\s*//p' | sort -u)"
    unknown="$(comm -23 <(printf '%s\n' "${got}") <(IMAGE_REGISTRY="${reg}"; inv_resolved))"
    eq "root compose (all profiles, registry='${reg}'): $(wc -l <<<"${got}") images, all in deploy/images.txt" "${unknown}" ""
done
eq "kind node image: open source keeps kind's default" "$(IMAGE_REGISTRY= KIND_NODE_IMAGE= kind_node_image /dev/null)" ""
check "kind node image: private registry pulls kindest/node from it" \
    bash -c "source scripts/lib/registry.sh; IMAGE_REGISTRY='${R}' KIND_NODE_IMAGE= kind_node_image /dev/null | grep -q '^${R}/agentcert/kindest/node:v'"

section "Phase 6: deploy/k8s manifests (resolve_image_env.py --rewrite-manifests)"
printf 'IMAGE_REGISTRY=%s\nIMAGE_PULL_SECRET_NAME=registry-pull\n' "${R}" > "${WORK}/k.env"
printf 'IMAGE_REGISTRY=\n' > "${WORK}/o.env"
for envf in "${WORK}/k.env" "${WORK}/o.env"; do
    reg="$(env_file_value IMAGE_REGISTRY "${envf}")"
    # As setup.sh's apply_manifest_resolved: a locally built hub bundle keeps its name.
    out="$(cat deploy/k8s/*.yaml | python3 scripts/lib/resolve_image_env.py --rewrite-manifests "${envf}" --keep agentcert/ace-hub-bundle:local)"
    got="$(sed -nE 's/^\s+(- )?image:\s*"?([^"[:space:]]+)"?.*/\2/p' <<<"${out}" | sort -u)"
    unknown="$(comm -23 <(printf '%s\n' "${got}") <(IMAGE_REGISTRY="${reg}"; { inv_resolved; echo "agentcert/ace-hub-bundle:local"; } | sort -u) | grep . || true)"
    eq "deploy/k8s (registry='${reg}'): every image resolved to a deploy/images.txt copy" "${unknown}" ""
    pods="$(grep -cE '^\s+containers:\s*$' <<<"${out}")"
    want=0; [[ -n "${reg}" ]] && want="${pods}"
    eq "deploy/k8s (registry='${reg}'): pull secret on ${want} of ${pods} pod specs" "$(grep -c '^\s*imagePullSecrets:' <<<"${out}")" "${want}"
    check "deploy/k8s (registry='${reg}'): valid YAML" python3 -c 'import sys,yaml; list(yaml.safe_load_all(sys.stdin))' <<<"${out}"
done
keep="$(python3 scripts/lib/resolve_image_env.py --rewrite-manifests "${WORK}/k.env" --keep-ace-images < deploy/k8s/graphql.yaml | sed -nE 's/^\s+image:\s*//p' | sort -u | tr '\n' ' ')"
eq "--keep-ace-images keeps side-loaded agentcert/* names" "${keep}" "agentcert/ace-hub-bundle:local agentcert/agentcert-graphql:latest "

if [[ "${ONLINE}" -eq 1 ]]; then
    section "online: registry contents"
    check "check-registry-images.sh (IMAGE_REGISTRY from .env): 0 MISSING" \
        bash -c "./scripts/check-registry-images.sh 2>&1 | grep -q ' 0 MISSING'"
    check "check-registry-images.sh (public, mirror rows): all OK" \
        bash -c "IMAGE_REGISTRY= ./scripts/check-registry-images.sh --kind mirror"
    check "mirror-images.sh --dry-run: nothing to copy" \
        bash -c "./scripts/mirror-images.sh --dry-run 2>&1 | grep -q ' 0 would copy, 0 failed'"
    section "online: Go test suites (golang:1.24) + bash->Go naming parity"
    GOCACHE_DIR="${ACE_GO_CACHE:-${REPO_ROOT}/.tmp/go-cache}"; mkdir -p "${GOCACHE_DIR}"
    : > "${WORK}/parity.tsv"
    for reg in "" "${R}" "${R}/agentcert"; do for ns in agentcert none; do for tag in "" RELEASE-7; do
        for i in "${imgs[@]}"; do
            printf '%s\t%s\t%s\t%s\t%s\n' "${reg}" "${ns}" "${tag}" "${i}" \
                "$(IMAGE_REGISTRY="${reg}" IMAGE_MIRROR_NAMESPACE="${ns}" ACE_IMAGE_TAG="${tag}" registry_ref "$i")"
        done >> "${WORK}/parity.tsv"
    done; done; done
    cp "${WORK}/parity.tsv" "${GOCACHE_DIR}/parity.tsv"
    gorun() { docker run --rm -e GOCACHE=/cache/build -e GOMODCACHE=/cache/mod -e IMAGEREF_PARITY_FIXTURE=/cache/parity.tsv \
              -v "${GOCACHE_DIR}:/cache" -v "${REPO_ROOT}:/ws" -w "/ws/$1" golang:1.24 sh -c "$2"; }
    check "graphql: go build ./..." gorun AgentCert/chaoscenter/graphql/server "go build ./..."
    check "graphql: imageref (incl. bash parity fixture), ops, infra, handler, agent_registry tests" \
        gorun AgentCert/chaoscenter/graphql/server "go test ./pkg/imageref/ ./pkg/chaos_experiment/ops/ ./pkg/chaos_infrastructure/ ./pkg/chaos_experiment_run/handler/ ./pkg/agent_registry/"
    check "install-app: vet + test" gorun app-charts/install-app "go vet . && go test ."
    check "install-agent: vet + test" gorun agent-charts/install-agent "go vet . && go test ."

    section "online: app charts through install-app's post-renderer"
    if gorun app-charts/install-app "CGO_ENABLED=0 go build -o /cache/install-app ." >/dev/null 2>&1; then
        cp -r app-charts/charts "${WORK}/appcharts"
        (cd "${WORK}/appcharts/otel-demo" && helm dependency build >/dev/null 2>&1)
        inventory_refs="$(INCLUDE_OPTIONAL=1 inventory_rows deploy/images.txt all | cut -d'|' -f3)"
        for chart in sock-shop bookinfo otel-demo; do
            plain="$(helm template t "${WORK}/appcharts/${chart}" 2>/dev/null)"
            for cfg in "${R}|registry-pull" "|"; do
                IFS='|' read -r creg csec <<<"${cfg}"
                out="$(ACE_HELM_POST_RENDER=1 ACE_IMAGE_REGISTRY="${creg}" ACE_IMAGE_MIRROR_NAMESPACE=agentcert ACE_IMAGE_PULL_SECRET="${csec}" \
                       helm template t "${WORK}/appcharts/${chart}" --post-renderer "${GOCACHE_DIR}/install-app" 2>&1)"
                want="$(grep -oE '^[[:space:]]+(- )?image:[[:space:]]*\S+' <<<"${plain}" | sed -E "s/.*image:[[:space:]]*//; s/[\"']//g" \
                        | while read -r i; do IMAGE_REGISTRY="${creg}" registry_ref "$i"; echo; done | sort -u)"
                got="$(grep -oE '^[[:space:]]+(- )?image:[[:space:]]*\S+' <<<"${out}" | sed -E "s/.*image:[[:space:]]*//; s/[\"']//g" | sort -u)"
                eq "${chart} (registry='${creg}'): every image resolved" "${got}" "${want}"
                mirrored="$(while read -r i; do IMAGE_REGISTRY="${creg}" registry_ref "$i"; echo; done <<<"${inventory_refs}" | sort -u)"
                missing="$(comm -23 <(printf '%s\n' "${got}") <(printf '%s\n' "${mirrored}"))"
                eq "${chart} (registry='${creg}'): every resolved image is in deploy/images.txt" "${missing}" ""
                pods="$(grep -cE '^[[:space:]]+containers:[[:space:]]*$' <<<"${out}")"
                if [[ -n "${csec}" ]]; then
                    eq "${chart}: pull secret on all ${pods} pod specs" "$(grep -c 'imagePullSecrets:' <<<"${out}")" "${pods}"
                fi
                check "${chart} (registry='${creg}'): output is valid YAML" python3 -c \
                    'import sys,yaml; list(yaml.safe_load_all(sys.stdin))' <<<"${out}"
            done
        done
    else
        fail "build install-app for the post-renderer test"
    fi
    section "online: Python manifest rewriter == Go post-renderer (byte for byte)"
    if [[ -x "${GOCACHE_DIR}/install-app" ]]; then
        for reg in "" "${R}"; do
            for f in deploy/k8s/*.yaml agent-charts/litellm/deployment.yaml; do
                py="$(printf 'IMAGE_REGISTRY=%s\nIMAGE_PULL_SECRET_NAME=registry-pull\n' "${reg}" > "${WORK}/p.env"
                      python3 scripts/lib/resolve_image_env.py --rewrite-manifests "${WORK}/p.env" < "${f}")"
                sec=""; [[ -n "${reg}" ]] && sec=registry-pull
                go="$(ACE_HELM_POST_RENDER=1 ACE_IMAGE_REGISTRY="${reg}" ACE_IMAGE_MIRROR_NAMESPACE=agentcert ACE_IMAGE_PULL_SECRET="${sec}" \
                      "${GOCACHE_DIR}/install-app" < "${f}")"
                [[ "${py}" == "${go}" ]] || { fail "rewriter parity: ${f} (registry='${reg}')"; continue 2; }
            done
            pass "Python == Go on deploy/k8s + litellm manifests (registry='${reg}')"
        done
    else
        fail "rewriter parity: install-app binary not built"
    fi
fi

echo
echo "Result: ${PASS} passed, ${FAIL} failed"
exit "${FAIL}"
