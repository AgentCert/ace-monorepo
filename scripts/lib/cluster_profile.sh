# shellcheck shell=bash
# =============================================================================
# cluster_profile.sh — what kind of Kubernetes cluster setup.sh deploys to.
# =============================================================================
# CLUSTER_MODE says who provides the cluster: setup creates KinD (auto/fresh),
# or an existing one from the kubeconfig is reused (local/cloud). Several deploy
# decisions depend instead on what the cluster is:
#   * can images built on this machine be loaded straight into its nodes?
#   * which annotation makes a LoadBalancer internal?
# This file answers that once. Sourced by scripts/setup.sh; it only defines
# functions. CLUSTER_PROVIDER in .env overrides the detection.
# =============================================================================

# cluster_provider_classify PROVIDER_ID NODE_LABELS
# Pure mapping (no kubectl) from a node's spec.providerID and its labels (the
# JSON map kubectl prints) to: kind | k3s | minikube | aks | eks | gke | generic
cluster_provider_classify() {
    local provider_id="$1" labels="$2"
    case "${provider_id}" in
        kind://*)  echo kind; return ;;
        k3s://*)   echo k3s; return ;;
        azure://*) echo aks; return ;;
        aws://*)   echo eks; return ;;
        gce://*)   echo gke; return ;;
    esac
    case "${labels}" in
        *'"kubernetes.azure.com/'*)                  echo aks ;;
        *'"eks.amazonaws.com/'*)                     echo eks ;;
        *'"cloud.google.com/gke-'*)                  echo gke ;;
        *'"minikube.k8s.io/'*)                       echo minikube ;;
        *'"node.kubernetes.io/instance-type":"k3s"'*) echo k3s ;;
        *)                                           echo generic ;;
    esac
}

# detect_cluster_provider — classify the cluster behind the current kube
# context; "unreachable" when kubectl gets no answer.
detect_cluster_provider() {
    local out
    out="$(kubectl get nodes --request-timeout=15s \
        -o jsonpath='{.items[0].spec.providerID}{"\t"}{.items[0].metadata.labels}' 2>/dev/null)" || out=""
    if [[ -z "${out}" ]]; then
        echo unreachable
        return
    fi
    cluster_provider_classify "${out%%$'\t'*}" "${out#*$'\t'}"
}

# cluster_provider_is_cloud PROVIDER — a managed cloud cluster.
cluster_provider_is_cloud() {
    case "$1" in aks|eks|gke) return 0 ;; *) return 1 ;; esac
}

# cluster_provider_can_sideload PROVIDER — images built on this machine can be
# loaded into its nodes by scripts/prepare-images.sh (kind load / k3s import).
# Everything else must pull every image from a registry.
cluster_provider_can_sideload() {
    case "$1" in kind|k3s) return 0 ;; *) return 1 ;; esac
}

cluster_provider_label() {
    case "$1" in
        aks)         echo "Azure AKS" ;;
        eks)         echo "Amazon EKS" ;;
        gke)         echo "Google GKE" ;;
        kind)        echo "KinD" ;;
        k3s)         echo "k3s" ;;
        minikube)    echo "minikube" ;;
        generic)     echo "Kubernetes (provider not recognised)" ;;
        unreachable) echo "no reachable cluster" ;;
        *)           echo "$1" ;;
    esac
}
