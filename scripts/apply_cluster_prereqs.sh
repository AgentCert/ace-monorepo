#!/usr/bin/env bash
# =============================================================================
# apply_cluster_prereqs.sh — give the cluster the private-registry login.
# =============================================================================
# Only needed when IMAGE_REGISTRY is set (e.g. infyartifactory.jfrog.io/docker-local
# inside the Infosys network). With IMAGE_REGISTRY empty (public registries,
# the open-source path) it does nothing. scripts/setup.sh runs it automatically
# before deploying; it is also safe to run by hand at any time (idempotent).
#
# It does not pull images — Kubernetes pulls them when pods start. It makes
# sure those pulls are authenticated:
#   1. creates the IMAGE_PULL_SECRET_NAME docker-registry Secret (from
#      REGISTRY_USERNAME / REGISTRY_PASSWORD) in kube-system (the master copy),
#      the ACE namespace and the chaos-infrastructure namespace, plus any
#      experiment namespace that already exists;
#   2. adds it to every ServiceAccount in those namespaces, so pods use it
#      without each manifest having to name it (namespaces labelled
#      ace.registry-sync=disabled are left alone);
#   3. installs deploy/registry-secret-sync.yaml, which copies the secret into
#      every namespace created later (experiments create them at run time).
#
# The corporate CA bundle is not handled here: setup.sh's create_ca_configmap
# already creates the ace-ca-certs ConfigMap that graphql mounts.
#
# Reads .env (scripts/lib/registry.sh) and never writes it.
#
# Usage:
#   ./scripts/apply_cluster_prereqs.sh [--env-file PATH] [--no-sync]
#   ./scripts/apply_cluster_prereqs.sh --uninstall   # remove the sync Deployment
#
#   --no-sync    skip installing registry-secret-sync
#   --uninstall  remove registry-secret-sync (used when switching back to
#                public registries); existing pull secrets are left in place
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/registry.sh
source "${SCRIPT_DIR}/lib/registry.sh"

ENV_FILE="${REPO_ROOT}/.env"
SYNC_MANIFEST="${REPO_ROOT}/deploy/registry-secret-sync.yaml"
INSTALL_SYNC=1
UNINSTALL=0

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)  ENV_FILE="$2"; shift 2 ;;
        --no-sync)   INSTALL_SYNC=0; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help)   sed -n '2,33p' "$0"; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

registry_load "${ENV_FILE}" || exit 1

ACE_NS="${ACE_NAMESPACE:-ace}"
INFRA_NS="$(env_file_value ACE_INFRA_NAMESPACE "${ENV_FILE}")"; INFRA_NS="${INFRA_NS:-litmus}"
# Experiment namespaces that may already exist. Not created here — their Helm
# releases own them; registry-secret-sync covers them when they appear.
EXPERIMENT_NAMESPACES=(sock-shop book-info otel-demo itbench litellm)

remove_sync() {
    kubectl delete deployment,configmap,serviceaccount registry-secret-sync \
        -n kube-system --ignore-not-found >/dev/null
    kubectl delete clusterrolebinding,clusterrole registry-secret-sync --ignore-not-found >/dev/null
}

if [[ "${UNINSTALL}" -eq 1 ]]; then
    remove_sync
    ok "registry-secret-sync removed (pull secrets already in namespaces are left in place)."
    exit 0
fi

echo -e "${BOLD}Cluster registry prerequisites${NC}"
if [[ -z "${IMAGE_REGISTRY}" ]]; then
    ok "IMAGE_REGISTRY is empty — images come from public registries; no pull secret needed."
    exit 0
fi
echo -e "${DIM}  registry: ${IMAGE_REGISTRY}   secret: ${IMAGE_PULL_SECRET_NAME}${NC}"

# Credentials come from .env. When run by hand without them, ask (not saved).
if ! registry_has_credentials; then
    if [[ -t 0 ]]; then
        read -rp "  Registry username for $(registry_host): " REGISTRY_USERNAME
        read -rsp "  Registry password / access token: " REGISTRY_PASSWORD; echo
        export REGISTRY_USERNAME REGISTRY_PASSWORD
    fi
    registry_has_credentials \
        || fail "REGISTRY_USERNAME / REGISTRY_PASSWORD are not set in ${ENV_FILE}"
fi

kubectl cluster-info >/dev/null 2>&1 || fail "kubectl cannot reach a cluster (context: $(kubectl config current-context 2>/dev/null || echo none))"

# Secret + every ServiceAccount in one namespace. A brand-new namespace gets its
# default ServiceAccount a moment after creation, so wait briefly for it.
prepare_namespace() {
    local ns="$1" sa n=0 attached=0
    registry_secret_apply "${ns}" || fail "could not create ${IMAGE_PULL_SECRET_NAME} in ${ns}"
    while ! kubectl get serviceaccount default -n "${ns}" >/dev/null 2>&1 && (( n < 20 )); do
        sleep 0.5; n=$((n + 1))
    done
    for sa in $(kubectl get serviceaccounts -n "${ns}" -o jsonpath='{.items[*].metadata.name}'); do
        registry_sa_attach "${ns}" "${sa}" && attached=$((attached + 1))
    done
    ok "${ns}: ${IMAGE_PULL_SECRET_NAME} applied, attached to ${attached} ServiceAccount(s)"
}

# 1) Master copy in kube-system (the sync reads it from here).
registry_secret_apply kube-system || fail "could not create ${IMAGE_PULL_SECRET_NAME} in kube-system"
ok "kube-system: master ${IMAGE_PULL_SECRET_NAME} applied"

# 2) Namespaces setup owns: create if needed.
for ns in "${ACE_NS}" "${INFRA_NS}"; do
    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    prepare_namespace "${ns}"
done

# 3) Experiment namespaces that already exist.
for ns in "${EXPERIMENT_NAMESPACES[@]}"; do
    kubectl get namespace "${ns}" >/dev/null 2>&1 || continue
    if registry_ns_opted_out "${ns}"; then
        ok "${ns}: skipped (labelled ace.registry-sync=disabled)"
    else
        prepare_namespace "${ns}"
    fi
done

# 4) Keep every future namespace covered.
if [[ "${INSTALL_SYNC}" -eq 1 ]]; then
    [[ -f "${SYNC_MANIFEST}" ]] || fail "missing ${SYNC_MANIFEST}"
    sync_image="$(registry_ref alpine/k8s:1.29.2)"
    rendered="$(sed -e "s|__IMAGE_PULL_SECRET_NAME__|${IMAGE_PULL_SECRET_NAME}|g" \
                    -e "s|__SYNC_IMAGE__|${sync_image}|g" "${SYNC_MANIFEST}")"
    # The checksum annotation makes apply roll the pod only when the manifest,
    # secret name or image changed (no restart on an unchanged re-run).
    checksum="$(printf '%s' "${rendered}" | sha256sum | cut -c1-16)"
    printf '%s\n' "${rendered//__CONFIG_CHECKSUM__/${checksum}}" | kubectl apply -f - >/dev/null
    if kubectl rollout status deployment/registry-secret-sync -n kube-system --timeout=120s >/dev/null 2>&1; then
        ok "registry-secret-sync running (copies ${IMAGE_PULL_SECRET_NAME} into new namespaces within seconds)"
    else
        warn "registry-secret-sync not ready yet — check: kubectl -n kube-system logs deploy/registry-secret-sync"
    fi
    # Older installs used a CronJob/Deployment named jfrog-secret-sync.
    kubectl delete deployment,cronjob jfrog-secret-sync -n kube-system --ignore-not-found >/dev/null 2>&1 || true
fi

ok "Cluster registry prerequisites complete."
