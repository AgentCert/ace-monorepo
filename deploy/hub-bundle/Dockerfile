FROM alpine:3.20

ARG BUNDLE_CONTENT_SHA=unknown
LABEL org.opencontainers.image.title="ACE local hub bundle" \
      org.opencontainers.image.description="Immutable app, agent, and chaos hub content for offline ACE runs" \
      io.agentcert.hub-bundle.content-sha="${BUNDLE_CONTENT_SHA}"

COPY app-charts/charts/ /bundle/app-charts/charts/
COPY agent-charts/charts/ /bundle/agent-charts/charts/
COPY ["chaos-charts/faults/", "/bundle/chaos-hubs/Litmus ChaosHub/faults/"]
COPY ["chaos-charts/experiments/", "/bundle/chaos-hubs/Litmus ChaosHub/experiments/"]

# GraphQL reads the copied tree as uid 65534, not the owner. COPY keeps the
# builder's file modes, so a checkout made under umask 0077 would otherwise
# produce 0600 files GraphQL cannot read (empty hubs, missing catalogs).
RUN test -f /bundle/app-charts/charts/applications.chartserviceversion.yaml \
 && test -f /bundle/agent-charts/charts/agents.chartserviceversion.yaml \
 && test -f "/bundle/chaos-hubs/Litmus ChaosHub/faults/fault-capabilities.yaml" \
 && addgroup -S bundle \
 && adduser -S -G bundle -u 65532 bundle \
 && chown -R bundle:bundle /bundle \
 && chmod -R a+rX /bundle

USER 65532:65532
ENTRYPOINT ["/bin/sh", "-ec"]
CMD ["test -d /bundle/app-charts/charts && test -d /bundle/agent-charts/charts && test -d '/bundle/chaos-hubs/Litmus ChaosHub/faults'"]
