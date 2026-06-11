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
ARG TARGETARCH=amd64

RUN apk add --no-cache bash curl docker-cli jq \
    && curl -fsSL -o /usr/local/bin/kind \
        "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${TARGETARCH}" \
    && chmod +x /usr/local/bin/kind \
    && curl -fsSL -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && chmod +x /usr/local/bin/kubectl

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
