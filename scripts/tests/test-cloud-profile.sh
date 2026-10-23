#!/usr/bin/env bash
# =============================================================================
# test-cloud-profile.sh — regression tests for running ACE on KinD and on a
# cloud cluster (AKS / EKS / GKE) from the same scripts.
# =============================================================================
# Offline: no cluster, no registry, no network (kubectl is stubbed). Covers
#   * scripts/lib/cluster_profile.sh   provider detection from node data
#   * scripts/lib/allowed_origins.py   the ALLOWED_ORIGINS builder
#   * the Helm chart's exposure (expose.*) and cloud-disk (storage.cloudDisks)
#     settings, and that KinD renders keep their NodePorts and nothing else
#   * setup.sh's generate_helm_values_platform: the generated values file
#     renders exactly what the --set flags it replaced rendered
#   * setup.sh's enforce_registry_images, apply_cluster_profile and
#     post_cloud_setup, run as they are in setup.sh against a scratch .env
#
# Usage: ./scripts/tests/test-cloud-profile.sh
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
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "${name}"; else fail "${name}"; fi; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
section() { echo; echo "== $*"; }
# Print one shell function's definition from a file (top-level `name() {` … `}`).
extract_fn() { awk -v n="$1()" 'index($0, n)==1 {p=1} p {print} p && /^}/ {exit}' "$2"; }

CHART=deploy/helm/ace
SETUP=scripts/setup.sh

section "syntax"
check "bash -n setup.sh" bash -n "${SETUP}"
check "bash -n cluster_profile.sh" bash -n scripts/lib/cluster_profile.sh
check "python compiles allowed_origins.py" python3 -m py_compile scripts/lib/allowed_origins.py

section "cluster provider detection"
# shellcheck source=../lib/cluster_profile.sh
source scripts/lib/cluster_profile.sh
eq "kind providerID"     "$(cluster_provider_classify 'kind://docker/agentcert-x/agentcert-x-control-plane' '{}')" kind
eq "AKS providerID"      "$(cluster_provider_classify 'azure:///subscriptions/s/resourceGroups/mc_rg/providers/Microsoft.Compute/virtualMachineScaleSets/aks-pool/virtualMachines/0' '{}')" aks
eq "EKS providerID"      "$(cluster_provider_classify 'aws:///us-east-1a/i-0123' '{}')" eks
eq "GKE providerID"      "$(cluster_provider_classify 'gce://proj/us-central1-a/gke-node' '{}')" gke
eq "k3s providerID"      "$(cluster_provider_classify 'k3s://node1' '{}')" k3s
eq "AKS by label"        "$(cluster_provider_classify '' '{"kubernetes.azure.com/agentpool":"ace110"}')" aks
eq "minikube by label"   "$(cluster_provider_classify '' '{"minikube.k8s.io/name":"minikube"}')" minikube
eq "k3s by label"        "$(cluster_provider_classify '' '{"node.kubernetes.io/instance-type":"k3s"}')" k3s
eq "unknown -> generic"  "$(cluster_provider_classify '' '{"kubernetes.io/os":"linux"}')" generic
check "aks is cloud"           cluster_provider_is_cloud aks
check "kind is not cloud"      bash -c '! { source scripts/lib/cluster_profile.sh; cluster_provider_is_cloud kind; }'
check "kind can side-load"     cluster_provider_can_sideload kind
check "aks cannot side-load"   bash -c '! { source scripts/lib/cluster_profile.sh; cluster_provider_can_sideload aks; }'
check "minikube cannot side-load (no loader in prepare-images.sh)" \
    bash -c '! { source scripts/lib/cluster_profile.sh; cluster_provider_can_sideload minikube; }'
kubectl() { echo "fail"; return 1; }
eq "unreachable cluster" "$(detect_cluster_provider)" unreachable
kubectl() { printf 'azure:///subscriptions/x\t{"kubernetes.azure.com/agentpool":"p"}'; }
eq "detect via kubectl" "$(detect_cluster_provider)" aks
unset -f kubectl

section "ALLOWED_ORIGINS builder"
if python3 - <<'PY'
import re, sys
sys.path.insert(0, "scripts/lib")
import allowed_origins as ao
rx = re.compile(ao.build(["172.26.0.1", "http://ace.example.com:2001/x, 100.78.201.16", ""]))
ok = ["localhost", "http://localhost:2001", "https://localhost", "graphql.ace.svc.cluster.local:8081",
      "host.docker.internal:4000", "10.244.1.10", "172.26.0.1:8081", "192.168.1.5:2001",
      "http://100.78.201.16:2001", "100.64.0.1", "100.127.255.255", "ace.example.com:2001"]
bad = ["8.8.8.8", "100.128.0.1", "100.63.0.1", "evil.com", "localhost.evil.com",
       "http://evil.com/?localhost", "aceXexample.com"]
errors = [o for o in ok if not rx.match(o)] + ["!" + o for o in bad if rx.match(o)]
# The earlier hand-written regex (setup.sh before the builder): everything it
# accepted must still be accepted.
old = re.compile(r"^(http://|https://|)((localhost|host\.docker\.internal|host\.minikube\.internal|[a-z0-9.-]+\.svc\.cluster\.local)"
                 r"|172\.[0-9]+\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.26\.0\.1)(:[0-9]+|)$")
errors += ["regressed:" + o for o in ok + bad if old.match(o) and not rx.match(o)]
assert ao.build([]) == ao.build(["", " , "]), "empty hosts change the regex"
assert ao.build(["a.b", "A.B", "http://a.b:1"]).count(r"a\.b") == 1, "duplicate host"
for unsupported in ("(?=", "(?!", "(?<", "\\1"):   # outside Go RE2
    assert unsupported not in ao.build(["x.y"]), unsupported
sys.exit(1 if errors else 0) if not errors else print(errors) or sys.exit(1)
PY
then pass "origins accepted/rejected as expected, superset of the old regex, RE2-safe"
else fail "ALLOWED_ORIGINS builder"
fi

section "Helm chart: exposure and cloud disks"
render() { helm template ace "${CHART}" -n ace "$@" 2>&1; }
# Print the Service document NAME from a rendered chart on stdin.
service_doc() { python3 -c '
import sys
name = sys.argv[1]
for d in sys.stdin.read().split("\n---\n"):
    if "\nkind: Service\n" in "\n" + d and "\n  name: %s\n" % name in "\n" + d:
        print(d)' "$1"; }
kind_out="$(render)"
for svc in web:32001 langfuse-web:32400 certifier:32080; do
    doc="$(service_doc "${svc%%:*}" <<<"${kind_out}")"
    check "KinD ${svc%%:*}: NodePort ${svc##*:}, no annotations" \
        bash -c "grep -q 'type: NodePort' <<<\"\$1\" && grep -q 'nodePort: ${svc##*:}' <<<\"\$1\" && ! grep -q annotations <<<\"\$1\"" _ "${doc}"
done
check "KinD: no cloud-disk settings" bash -c '! grep -qE "PGDATA|type: Recreate|fsGroup: 65532" <<<"$1"' _ "${kind_out}"

for p in aks:service.beta.kubernetes.io/azure-load-balancer-internal \
         eks:service.beta.kubernetes.io/aws-load-balancer-scheme \
         gke:networking.gke.io/load-balancer-type; do
    out="$(render --set expose.type=LoadBalancer --set "expose.provider=${p%%:*}")"
    doc="$(service_doc web <<<"${out}")"
    check "${p%%:*}: internal-LB annotation on web, no nodePort" \
        bash -c "grep -q '${p#*:}' <<<\"\$1\" && grep -q 'type: LoadBalancer' <<<\"\$1\" && ! grep -q nodePort <<<\"\$1\"" _ "${doc}"
    doc="$(service_doc langfuse-web <<<"${out}")"
    check "${p%%:*}: internal-LB annotation on langfuse-web" grep -q "${p#*:}" <<<"${doc}"
    doc="$(service_doc certifier <<<"${out}")"
    check "${p%%:*}: certifier stays NodePort unless enabled" \
        bash -c "grep -q 'nodePort: 32080' <<<\"\$1\" && ! grep -q annotations <<<\"\$1\"" _ "${doc}"
done
out="$(render --set expose.type=LoadBalancer --set expose.provider=aks --set expose.internal=false)"
check "internal=false: no provider annotation" bash -c '! grep -q azure-load-balancer-internal <<<"$1"' _ "${out}"
out="$(render --set expose.type=LoadBalancer --set expose.provider=aks \
    --set 'expose.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-internal=false' \
    --set 'expose.annotations.example\.com/team=ace')"
doc="$(service_doc web <<<"${out}")"
check "expose.annotations override and extend the provider's" \
    bash -c "grep -q 'azure-load-balancer-internal: \"false\"' <<<\"\$1\" && grep -q 'example.com/team: \"ace\"' <<<\"\$1\"" _ "${doc}"
out="$(render --set expose.type=LoadBalancer --set expose.provider=aks --set expose.web.loadBalancerIP=100.78.201.16 \
    --set expose.certifier.enabled=true --set expose.certifier.loadBalancerIP=100.78.201.14 \
    --set 'expose.loadBalancerSourceRanges={10.0.0.0/8,100.64.0.0/10}')"
check "web gets its pinned IP" grep -q 'loadBalancerIP: 100.78.201.16' <<<"$(service_doc web <<<"${out}")"
check "langfuse without a pinned IP has none" bash -c '! grep -q loadBalancerIP <<<"$1"' _ "$(service_doc langfuse-web <<<"${out}")"
doc="$(service_doc certifier <<<"${out}")"
check "certifier enabled: internal LB at its IP" \
    bash -c "grep -q 'loadBalancerIP: 100.78.201.14' <<<\"\$1\" && grep -q azure-load-balancer-internal <<<\"\$1\"" _ "${doc}"
check "source ranges rendered" grep -q -- '- 100.64.0.0/10' <<<"${doc}"
out="$(render --set expose.type=ClusterIP)"
doc="$(service_doc web <<<"${out}")"
check "ClusterIP: no nodePort, no annotations" \
    bash -c "grep -q 'type: ClusterIP' <<<\"\$1\" && ! grep -qE 'nodePort|annotations' <<<\"\$1\"" _ "${doc}"
out="$(render --set storage.cloudDisks=true)"
eq "cloudDisks: Recreate on the 6 PVC-backed Deployments" "$(grep -c 'type: Recreate' <<<"${out}")" 6
check "cloudDisks: Postgres data in a subdirectory" grep -q 'value: /var/lib/postgresql/data/pgdata' <<<"${out}"
check "cloudDisks: MinIO fsGroup" grep -q 'fsGroup: 65532' <<<"${out}"
check "cloud render is valid YAML" python3 -c 'import sys,yaml; list(yaml.safe_load_all(sys.stdin))' <<<"${out}"

section "setup.sh: values-platform.yaml"
ENV_FILE="${WORK}/env"
SETUP_PYTHON=python3
SCRIPT_DIR="${REPO_ROOT}/scripts"
# shellcheck source=../lib/registry.sh
source scripts/lib/registry.sh
eval "$(extract_fn cur "${SETUP}")"
eval "$(extract_fn set_env "${SETUP}")"
eval "$(extract_fn generate_helm_values_platform "${SETUP}")"
ok() { :; }; warn() { echo "WARN $*" >&2; }
BOLD=""; DIM=""; NC=""
metrics_api_served_elsewhere() { return 1; }
cat > "${ENV_FILE}" <<'EOF'
IMAGE_REGISTRY=
IMAGE_MIRROR_NAMESPACE=
ACE_IMAGE_TAG=
IMAGE_PULL_SECRET_NAME=registry-pull
PLATFORM_IMAGE_SOURCE=local
LITMUS_IMAGES_SOURCE=local
HUB_BUNDLE_IMAGE_SOURCE=local
HUB_BUNDLE_IMAGE=agentcert/ace-hub-bundle:local
EOF
CLUSTER_MODE=auto DO_LOCAL_BUILD=1 generate_helm_values_platform "${WORK}/vp.yaml"
# What setup.sh passed for this KinD case before values-platform.yaml existed.
old_flags=(--set-string chartsHub.bundleImage=agentcert/ace-hub-bundle:local --set chartsHub.bundleImagePullPolicy=Never
           --set-string imageRegistry= --set-string imageMirrorNamespace= --set-string aceImageTag=
           --set-string imagePullSecretName=registry-pull --set aceImagesLocal=true --set runtimeImagesLocal=true
           --set chartsHub.bundleLocal=true --set imagePullPolicy=IfNotPresent)
if [[ "$(render -f "${WORK}/vp.yaml")" == "$(render "${old_flags[@]}")" ]]; then
    pass "KinD: values file renders exactly what the old --set flags rendered"
else
    fail "KinD: values file and old --set flags render differently"
fi
cat > "${ENV_FILE}" <<'EOF'
IMAGE_REGISTRY=infyartifactory.jfrog.io/docker-local
IMAGE_MIRROR_NAMESPACE=
ACE_IMAGE_TAG=RELEASE-2
IMAGE_PULL_SECRET_NAME=registry-pull
PLATFORM_IMAGE_SOURCE=skip
LITMUS_IMAGES_SOURCE=registry
HUB_BUNDLE_IMAGE_SOURCE=registry
HUB_BUNDLE_IMAGE=agentcert/ace-hub-bundle:latest
ACE_WEB_LB_IP=100.78.201.16
ACE_LB_SOURCE_RANGES=10.0.0.0/8, 100.64.0.0/10
EOF
CLUSTER_MODE=cloud CLUSTER_PROVIDER=aks DO_LOCAL_BUILD=0 generate_helm_values_platform "${WORK}/vp-cloud.yaml"
out="$(render -f "${WORK}/vp-cloud.yaml")"
doc="$(service_doc web <<<"${out}")"
check "cloud: web is an internal LB at the pinned IP" \
    bash -c "grep -q azure-load-balancer-internal <<<\"\$1\" && grep -q 'loadBalancerIP: 100.78.201.16' <<<\"\$1\"" _ "${doc}"
check "cloud: images pulled from the registry under the release tag" \
    grep -q 'image: infyartifactory.jfrog.io/docker-local/agentcert/agentcert-graphql:RELEASE-2' <<<"${out}"
check "cloud: pull policy Always, cloud disks, no host export" \
    bash -c "grep -q 'imagePullPolicy: Always' <<<\"\$1\" && grep -q 'type: Recreate' <<<\"\$1\" && ! grep -q cert-export <<<\"\$1\"" _ "${out}"
echo "ACE_EXPOSE_TYPE=Ingress" >> "${ENV_FILE}"
check "cloud: an invalid ACE_EXPOSE_TYPE is refused" \
    bash -c '! { CLUSTER_MODE=cloud CLUSTER_PROVIDER=aks generate_helm_values_platform "$1" 2>/dev/null; }' _ "${WORK}/x.yaml"

section "setup.sh: cluster profile"
eval "$(extract_fn enforce_registry_images "${SETUP}")"
eval "$(extract_fn abort_setup "${SETUP}")"
eval "$(extract_fn refuse_publish_without_push "${SETUP}")"
eval "$(extract_fn apply_cluster_profile "${SETUP}")"
cat > "${ENV_FILE}" <<'EOF'
CLUSTER_MODE=local
IMAGE_REGISTRY=infyartifactory.jfrog.io/docker-local
PLATFORM_IMAGE_SOURCE=local
INSTALL_APP_IMAGE_SOURCE=local
INSTALL_AGENT_IMAGE_SOURCE=local
LITMUS_IMAGES_SOURCE=local
SRE_AGENTS_IMAGE_SOURCE=local
ITBENCH_EXPERIMENT_IMAGE_SOURCE=local
HUB_BUNDLE_IMAGE_SOURCE=local
HUB_BUNDLE_IMAGE=agentcert/ace-hub-bundle:local
INSTALL_APPLICATION_IMAGE_PULL_POLICY=Never
INSTALL_AGENT_IMAGE_PULL_POLICY=Never
OLLAMA_MODEL=
EOF
detect_cluster_provider() { echo aks; }
CLUSTER_MODE=local; BUILD_MODE=prompt; DO_LOCAL_BUILD=1; DO_BUILD=0; CLOUD_PUBLISH=0; CALLBACK_HOST=172.26.0.1
SELECTED_BUILD_IMAGES=(x)
apply_cluster_profile 2>/dev/null
eq "a local context that is AKS becomes cloud" "${CLUSTER_MODE}/$(cur CLUSTER_MODE)/${CALLBACK_HOST}" "cloud/cloud/"
eq "persisted local build dropped" "${DO_LOCAL_BUILD}/$(cur PLATFORM_IMAGE_SOURCE)" "0/skip"
srcs=""
for k in INSTALL_APP_IMAGE_SOURCE INSTALL_AGENT_IMAGE_SOURCE LITMUS_IMAGES_SOURCE SRE_AGENTS_IMAGE_SOURCE \
         ITBENCH_EXPERIMENT_IMAGE_SOURCE HUB_BUNDLE_IMAGE_SOURCE; do srcs+="$(cur "${k}") "; done
eq "every image source switched to registry" "${srcs}" "registry registry registry registry registry registry "
eq "Never pull policies become Always" "$(cur INSTALL_APPLICATION_IMAGE_PULL_POLICY)/$(cur INSTALL_AGENT_IMAGE_PULL_POLICY)" "Always/Always"
eq "hub bundle points at the published tag" "$(cur HUB_BUNDLE_IMAGE)" "agentcert/ace-hub-bundle:latest"
rc=0; bash -c "$(declare -f cur set_env enforce_registry_images abort_setup refuse_publish_without_push cluster_provider_label image_source_normalize); ENV_FILE='${ENV_FILE}'; CLUSTER_PROVIDER=aks; BUILD_MODE=prompt; DO_BUILD=1; PUSH_IMAGES=0; enforce_registry_images" >/dev/null 2>&1 || rc=$?
eq "cloud publishing without --push is rejected (exit 2)" "${rc}" 2
CLUSTER_MODE=cloud; DO_BUILD=1; CLOUD_PUBLISH=0; PUSH_IMAGES=1
apply_cluster_profile 2>/dev/null
eq "build and push on cloud publishes every ACE image" "${DO_BUILD}/${CLOUD_PUBLISH}" "0/1"
check "--local-build on cloud exits non-zero" \
    bash -c "! bash -c \"\$1\"" _ "$(declare -f cur set_env enforce_registry_images apply_cluster_profile detect_cluster_provider \
               cluster_provider_classify cluster_provider_is_cloud cluster_provider_can_sideload cluster_provider_label \
               image_source_normalize); ok() { :; }; warn() { :; }; ENV_FILE='${ENV_FILE}'; SETUP_PYTHON=python3;
               CLUSTER_MODE=cloud BUILD_MODE=local; apply_cluster_profile 2>/dev/null"
cat > "${ENV_FILE}" <<'EOF'
CLUSTER_MODE=auto
INSTALL_APP_IMAGE_SOURCE=local
HUB_BUNDLE_IMAGE=agentcert/ace-hub-bundle:local
EOF
CLUSTER_MODE=auto; DO_LOCAL_BUILD=1; BUILD_MODE=local; CLUSTER_PROVIDER=""
apply_cluster_profile 2>/dev/null
eq "KinD keeps local images untouched" "$(cur INSTALL_APP_IMAGE_SOURCE)/$(cur HUB_BUNDLE_IMAGE)/${DO_LOCAL_BUILD}" \
    "local/agentcert/ace-hub-bundle:local/1"
detect_cluster_provider() { echo unreachable; }
check "cloud with no reachable cluster exits non-zero" \
    bash -c "! bash -c \"\$1\"" _ "$(declare -f cur set_env enforce_registry_images apply_cluster_profile detect_cluster_provider \
               cluster_provider_classify cluster_provider_is_cloud cluster_provider_can_sideload cluster_provider_label \
               image_source_normalize); ok() { :; }; warn() { :; }; ENV_FILE='${ENV_FILE}'; SETUP_PYTHON=python3;
               set_env CLUSTER_PROVIDER ''; CLUSTER_MODE=cloud BUILD_MODE=prompt; apply_cluster_profile 2>/dev/null"

section "setup.sh: post_cloud_setup"
eval "$(extract_fn lb_address "${SETUP}")"
eval "$(extract_fn refresh_allowed_origins "${SETUP}")"
eval "$(extract_fn post_cloud_setup "${SETUP}")"
RESTARTS=0
apply_ace_env_secret() { :; }
sleep() { :; }
kubectl() {
    case "$*" in
        "get svc web "*)          echo 100.78.201.16 ;;
        "get svc langfuse-web "*) echo 100.78.201.15 ;;
        "rollout restart"*)       RESTARTS=$((RESTARTS + 1)) ;;
    esac
}
cat > "${ENV_FILE}" <<'EOF'
CLUSTER_MODE=cloud
ACE_EXTRA_ALLOWED_ORIGINS=ace.example.com
NEXTAUTH_URL=http://localhost:4000
EOF
CALLBACK_HOST=""
post_cloud_setup ace >/dev/null
eq "NEXTAUTH_URL follows the langfuse-web LB" "$(cur NEXTAUTH_URL)" "http://100.78.201.15:3000"
eq "CHAOS_CENTER_PUBLIC_ENDPOINT follows the web LB" "$(cur CHAOS_CENTER_PUBLIC_ENDPOINT)" "http://100.78.201.16:2001"
eq "LB addresses remembered" "$(cur ACE_PUBLIC_HOSTS)" "100.78.201.16,100.78.201.15"
check "ALLOWED_ORIGINS has the LB IPs and the extra host" \
    bash -c 'grep -qF "100\.78\.201\.16" <<<"$1" && grep -qF "ace\.example\.com" <<<"$1"' _ "$(cur ALLOWED_ORIGINS)"
eq "changed values restart graphql/auth/langfuse-web once" "${RESTARTS}" 1
post_cloud_setup ace >/dev/null
eq "a re-run with the same addresses restarts nothing" "${RESTARTS}" 1
kubectl() { :; }
before="$(cur NEXTAUTH_URL)"
post_cloud_setup ace >/dev/null 2>&1
eq "no LB address: settings left alone" "$(cur NEXTAUTH_URL)" "${before}"
unset -f kubectl sleep

echo
echo "Result: ${PASS} passed, ${FAIL} failed"
exit "${FAIL}"
