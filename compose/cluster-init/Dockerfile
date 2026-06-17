# =============================================================================
# cluster-init — one-shot Kubernetes provisioner for the root docker-compose.
#
# Runs on the host network with the docker socket mounted so it can:
#   * probe the mounted ~/.kube/config (cloud / local reuse)
#   * create a local `kind` cluster when none is present (fresh / auto)
#
# It exits 0 once a working kube context exists; every app service that needs
# Kubernetes `depends_on` it with condition: service_completed_successfully.
# =============================================================================
FROM alpine:3.20

ARG KIND_VERSION=v0.31.0
ARG KUBECTL_VERSION=v1.29.0
ARG KUBELOGIN_VERSION=v0.2.8
ARG AWS_IAM_AUTH_VERSION=0.6.27
ARG TARGETARCH=amd64

RUN apk add --no-cache bash curl docker-cli jq unzip python3 py3-pip \
    && curl -fsSL -o /usr/local/bin/kind \
        "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${TARGETARCH}" \
    && chmod +x /usr/local/bin/kind \
    && curl -fsSL -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    \
    # kubelogin — Azure AKS exec-auth (az aks get-credentials without --admin)
    && curl -fsSL \
        "https://github.com/Azure/kubelogin/releases/download/${KUBELOGIN_VERSION}/kubelogin-linux-${TARGETARCH}.zip" \
        -o /tmp/kubelogin.zip \
    && unzip /tmp/kubelogin.zip -d /tmp/kubelogin \
    && mv "/tmp/kubelogin/bin/linux_${TARGETARCH}/kubelogin" /usr/local/bin/kubelogin \
    && chmod +x /usr/local/bin/kubelogin \
    && rm -rf /tmp/kubelogin* \
    \
    # aws-iam-authenticator — AWS EKS legacy exec-auth
    && curl -fsSL \
        "https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/download/v${AWS_IAM_AUTH_VERSION}/aws-iam-authenticator_${AWS_IAM_AUTH_VERSION}_linux_${TARGETARCH}" \
        -o /usr/local/bin/aws-iam-authenticator \
    && chmod +x /usr/local/bin/aws-iam-authenticator \
    \
    # aws CLI v1 — AWS EKS modern exec-auth (command: aws eks get-token)
    && pip3 install --quiet awscli --break-system-packages

# GCP: gke-gcloud-auth-plugin ships as part of the full gcloud SDK (~300 MB)
# and cannot be installed cleanly in Alpine. For GKE clusters, use a
# service-account-key kubeconfig (no exec plugin needed), or mount the host
# gke-gcloud-auth-plugin binary via a docker-compose.override.yml volume.
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
