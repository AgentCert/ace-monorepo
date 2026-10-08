# ACE images in docker.io/agentcert (frozen open-source copies)

Generated 2026-10-07 11:59 UTC by `scripts/check-registry-images.sh --markdown` from `deploy/images.txt`.
Re-run that command to refresh this file.

**Summary:** 103 OK, 2 OLD, 0 MISSING

- **OK**: present at the expected name (ACE images: built from the current source).
- **OLD**: ACE image whose moving tag (`:latest`) is an older build; the current build is linked as *new build*.
- **MISSING**: not in the registry.
- **build** = built from this repo by `scripts/build-and-push.sh`; **mirror** = third-party copy made by `scripts/mirror-images.sh`.

| Status | Kind | Group | Image | Registry location |
|---|---|---|---|---|
| OLD | build | platform | `agentcert/agentcert-graphql:latest` | `agentcert/agentcert-graphql:latest` |
| OLD | build | platform | `agentcert/agentcert-auth:latest` | `agentcert/agentcert-auth:latest` |
| OK | build | platform | `agentcert/agentcert-web:latest` | `agentcert/agentcert-web:latest` |
| OK | build | platform | `agentcert/certifier:latest` | `agentcert/certifier:latest` |
| OK | build | platform | `agentcert/ace-hub-bundle:latest` | `agentcert/ace-hub-bundle:latest` |
| OK | build | platform | `agentcert/cluster-init:latest` | `agentcert/cluster-init:latest` |
| OK | build | infra | `agentcert/litmusportal-subscriber:3.0.0` | `agentcert/litmusportal-subscriber:3.0.0` |
| OK | build | workflow | `agentcert/agentcert-install-app:latest` | `agentcert/agentcert-install-app:latest` |
| OK | build | workflow | `agentcert/agentcert-install-agent:latest` | `agentcert/agentcert-install-agent:latest` |
| OK | build | workflow | `agentcert/itbench-experiment:dev` | `agentcert/itbench-experiment:dev` |
| OK | build | agents | `agentcert/agentcert-flash-agent:latest` | `agentcert/agentcert-flash-agent:latest` |
| OK | build | agents | `agentcert/sre-agent-comprehensive:latest` | `agentcert/sre-agent-comprehensive:latest` |
| OK | build | agents | `agentcert/sre-agent-crewai:latest` | `agentcert/sre-agent-crewai:latest` |
| OK | build | agents | `agentcert/agent-sidecar:latest` | `agentcert/agent-sidecar:latest` |
| OK | mirror | platform | `litellm/litellm:v1.82.0-stable` | `agentcert/litellm-litellm:v1.82.0-stable` |
| OK | mirror | platform | `mongo:5` | `agentcert/mongo:5` |
| OK | mirror | platform | `postgres:17` | `agentcert/postgres:17` |
| OK | mirror | platform | `redis:7` | `agentcert/redis:7` |
| OK | mirror | platform | `clickhouse/clickhouse-server:26.8` | `agentcert/clickhouse-clickhouse-server:26.8` |
| OK | mirror | platform | `cgr.dev/chainguard/minio:latest` | `agentcert/chainguard-minio:latest` |
| OK | mirror | platform | `langfuse/langfuse:3` | `agentcert/langfuse-langfuse:3` |
| OK | mirror | platform | `langfuse/langfuse-worker:3` | `agentcert/langfuse-langfuse-worker:3` |
| OK | mirror | platform | `busybox:1.36` | `agentcert/busybox:1.36` |
| OK | mirror | platform | `registry.k8s.io/metrics-server/metrics-server:v0.7.2` | `agentcert/metrics-server-metrics-server:v0.7.2` |
| OK | mirror | platform | `python:3.11-slim` | `agentcert/python:3.11-slim` |
| OK | mirror | infra | `litmuschaos/litmusportal-event-tracker:3.0.0` | `agentcert/litmuschaos-litmusportal-event-tracker:3.0.0` |
| OK | mirror | infra | `litmuschaos/workflow-controller:v3.3.1` | `agentcert/litmuschaos-workflow-controller:v3.3.1` |
| OK | mirror | infra | `litmuschaos/argoexec:v3.3.1` | `agentcert/litmuschaos-argoexec:v3.3.1` |
| OK | mirror | infra | `litmuschaos/chaos-operator:3.0.0` | `agentcert/litmuschaos-chaos-operator:3.0.0` |
| OK | mirror | infra | `litmuschaos/chaos-runner:3.0.0` | `agentcert/litmuschaos-chaos-runner:3.0.0` |
| OK | mirror | infra | `litmuschaos/chaos-exporter:3.0.0` | `agentcert/litmuschaos-chaos-exporter:3.0.0` |
| OK | mirror | infra | `quay.io/containers/kubernetes_mcp_server:v0.0.67` | `agentcert/containers-kubernetes_mcp_server:v0.0.67` |
| OK | mirror | infra | `ghcr.io/pab1it0/prometheus-mcp-server:latest` | `agentcert/pab1it0-prometheus-mcp-server:latest` |
| OK | mirror | workflow | `litmuschaos/k8s:latest` | `agentcert/litmuschaos-k8s:latest` |
| OK | mirror | workflow | `litmuschaos.docker.scarf.sh/litmuschaos/go-runner:latest` | `agentcert/litmuschaos-go-runner:latest` |
| OK | mirror | workflow | `litmuschaos/go-runner:latest` | `agentcert/litmuschaos-go-runner:latest` |
| OK | mirror | workflow | `litmuschaos/litmus-checker:latest` | `agentcert/litmuschaos-litmus-checker:latest` |
| OK | mirror | workflow | `litmuschaos/litmus-app-deployer:latest` | `agentcert/litmuschaos-litmus-app-deployer:latest` |
| OK | mirror | workflow | `alpine/k8s:1.29.2` | `agentcert/alpine-k8s:1.29.2` |
| OK | mirror | workflow | `alpine/k8s:1.18.2` | `agentcert/alpine-k8s:1.18.2` |
| OK | mirror | workflow | `alpine:3.19` | `agentcert/alpine:3.19` |
| OK | mirror | workflow | `alexeiled/stress-ng:latest-ubuntu` | `agentcert/alexeiled-stress-ng:latest-ubuntu` |
| OK | mirror | workflow | `gaiadocker/iproute2:latest` | `agentcert/gaiadocker-iproute2:latest` |
| OK | mirror | workflow | `ubuntu:16.04` | `agentcert/ubuntu:16.04` |
| OK | mirror | workflow | `curlimages/curl:8.10.1` | `agentcert/curlimages-curl:8.10.1` |
| OK | mirror | workflow | `registry.k8s.io/pause:3.9` | `agentcert/pause:3.9` |
| OK | mirror | workflow | `registry.access.redhat.com/ubi10-minimal:10.2-1782798957` | `agentcert/ubi10-minimal:10.2-1782798957` |
| OK | mirror | apps | `weaveworksdemos/front-end:0.3.12` | `agentcert/weaveworksdemos-front-end:0.3.12` |
| OK | mirror | apps | `weaveworksdemos/catalogue:0.3.5` | `agentcert/weaveworksdemos-catalogue:0.3.5` |
| OK | mirror | apps | `weaveworksdemos/catalogue-db:0.3.0` | `agentcert/weaveworksdemos-catalogue-db:0.3.0` |
| OK | mirror | apps | `weaveworksdemos/carts:0.4.8` | `agentcert/weaveworksdemos-carts:0.4.8` |
| OK | mirror | apps | `weaveworksdemos/orders:0.4.7` | `agentcert/weaveworksdemos-orders:0.4.7` |
| OK | mirror | apps | `weaveworksdemos/payment:0.4.3` | `agentcert/weaveworksdemos-payment:0.4.3` |
| OK | mirror | apps | `weaveworksdemos/shipping:0.4.8` | `agentcert/weaveworksdemos-shipping:0.4.8` |
| OK | mirror | apps | `weaveworksdemos/user:0.4.7` | `agentcert/weaveworksdemos-user:0.4.7` |
| OK | mirror | apps | `weaveworksdemos/user-db:0.4.0` | `agentcert/weaveworksdemos-user-db:0.4.0` |
| OK | mirror | apps | `weaveworksdemos/queue-master:0.3.1` | `agentcert/weaveworksdemos-queue-master:0.3.1` |
| OK | mirror | apps | `mongo:latest` | `agentcert/mongo:latest` |
| OK | mirror | apps | `rabbitmq:3.6.8` | `agentcert/rabbitmq:3.6.8` |
| OK | mirror | apps | `litmuschaos/chaos-exporter:1.13.3` | `agentcert/litmuschaos-chaos-exporter:1.13.3` |
| OK | mirror | apps | `prom/prometheus:v2.25.0` | `agentcert/prom-prometheus:v2.25.0` |
| OK | mirror | apps | `grafana/grafana:latest` | `agentcert/grafana-grafana:latest` |
| OK | mirror | apps | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0` | `agentcert/kube-state-metrics-kube-state-metrics:v2.13.0` |
| OK | mirror | apps | `registry.istio.io/release/examples-bookinfo-details-v1:1.20.3` | `agentcert/release-examples-bookinfo-details-v1:1.20.3` |
| OK | mirror | apps | `registry.istio.io/release/examples-bookinfo-ratings-v1:1.20.3` | `agentcert/release-examples-bookinfo-ratings-v1:1.20.3` |
| OK | mirror | apps | `registry.istio.io/release/examples-bookinfo-reviews-v1:1.20.3` | `agentcert/release-examples-bookinfo-reviews-v1:1.20.3` |
| OK | mirror | apps | `registry.istio.io/release/examples-bookinfo-reviews-v2:1.20.3` | `agentcert/release-examples-bookinfo-reviews-v2:1.20.3` |
| OK | mirror | apps | `registry.istio.io/release/examples-bookinfo-reviews-v3:1.20.3` | `agentcert/release-examples-bookinfo-reviews-v3:1.20.3` |
| OK | mirror | apps | `registry.istio.io/release/examples-bookinfo-productpage-v1:1.20.3` | `agentcert/release-examples-bookinfo-productpage-v1:1.20.3` |
| OK | mirror | apps | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | `agentcert/ubi9-ubi-minimal:latest` |
| OK | mirror | apps | `busybox:latest` | `agentcert/busybox:latest` |
| OK | mirror | apps | `ghcr.io/open-feature/flagd:v0.12.9` | `agentcert/open-feature-flagd:v0.12.9` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-accounting` | `agentcert/open-telemetry-demo:2.2.0-accounting` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-ad` | `agentcert/open-telemetry-demo:2.2.0-ad` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-cart` | `agentcert/open-telemetry-demo:2.2.0-cart` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-checkout` | `agentcert/open-telemetry-demo:2.2.0-checkout` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-currency` | `agentcert/open-telemetry-demo:2.2.0-currency` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-email` | `agentcert/open-telemetry-demo:2.2.0-email` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-flagd-ui` | `agentcert/open-telemetry-demo:2.2.0-flagd-ui` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-fraud-detection` | `agentcert/open-telemetry-demo:2.2.0-fraud-detection` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-frontend` | `agentcert/open-telemetry-demo:2.2.0-frontend` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-frontend-proxy` | `agentcert/open-telemetry-demo:2.2.0-frontend-proxy` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-image-provider` | `agentcert/open-telemetry-demo:2.2.0-image-provider` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-kafka` | `agentcert/open-telemetry-demo:2.2.0-kafka` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-llm` | `agentcert/open-telemetry-demo:2.2.0-llm` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-load-generator` | `agentcert/open-telemetry-demo:2.2.0-load-generator` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-payment` | `agentcert/open-telemetry-demo:2.2.0-payment` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-product-catalog` | `agentcert/open-telemetry-demo:2.2.0-product-catalog` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-product-reviews` | `agentcert/open-telemetry-demo:2.2.0-product-reviews` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-quote` | `agentcert/open-telemetry-demo:2.2.0-quote` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-recommendation` | `agentcert/open-telemetry-demo:2.2.0-recommendation` |
| OK | mirror | apps | `ghcr.io/open-telemetry/demo:2.2.0-shipping` | `agentcert/open-telemetry-demo:2.2.0-shipping` |
| OK | mirror | apps | `otel/opentelemetry-collector-contrib:0.151.0` | `agentcert/otel-opentelemetry-collector-contrib:0.151.0` |
| OK | mirror | apps | `postgres:17.6` | `agentcert/postgres:17.6` |
| OK | mirror | apps | `valkey/valkey:9.0.1-alpine3.23` | `agentcert/valkey-valkey:9.0.1-alpine3.23` |
| OK | mirror | build-base | `python:3.12-slim` | `agentcert/python:3.12-slim` |
| OK | mirror | build-base | `golang:1.21-alpine` | `agentcert/golang:1.21-alpine` |
| OK | mirror | build-base | `golang:1.21-alpine3.19` | `agentcert/golang:1.21-alpine3.19` |
| OK | mirror | build-base | `golang:1.22` | `agentcert/golang:1.22` |
| OK | mirror | build-base | `golang:1.24` | `agentcert/golang:1.24` |
| OK | mirror | build-base | `alpine:3.20` | `agentcert/alpine:3.20` |
| OK | mirror | build-base | `node:20` | `agentcert/node:20` |
| OK | mirror | build-base | `registry.access.redhat.com/ubi9/ubi-minimal:9.6` | `agentcert/ubi9-ubi-minimal:9.6` |
| OK | mirror | build-base | `registry.access.redhat.com/ubi8/ubi-minimal:8.10` | `agentcert/ubi8-ubi-minimal:8.10` |
| OK | mirror | build-base | `gcr.io/distroless/static-debian12:nonroot` | `agentcert/distroless-static-debian12:nonroot` |
