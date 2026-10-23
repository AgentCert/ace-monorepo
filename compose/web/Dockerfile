# agentcert-web: builds the React UI from AgentCert/chaoscenter/web (the repo
# ships no dist/) and serves it with nginx. Build context: AgentCert/chaoscenter/web.
# Kept outside the AgentCert submodule; used by docker-compose.yml (web),
# scripts/setup.sh and scripts/build-and-push.sh.
# Base images: upstream names by default (plain `docker build` works anywhere).
# scripts/build-and-push.sh, setup.sh and prepare-images.sh pass the copy from
# IMAGE_REGISTRY / the frozen agentcert/ Docker Hub copies (scripts/lib/registry.sh).
#
# nginx.conf is supplied by the deployment, not baked in: every ACE deployment
# mounts its own over /etc/nginx/nginx.conf, listening on 2001 and proxying
# /auth/ and /api/ to that deployment's service names — compose/web-nginx.conf
# (docker-compose.yml) and the web-nginx-conf ConfigMap (deploy/helm/ace and
# deploy/k8s web.yaml). The upstream ChaosCenter nginx/nginx.conf (port 8185,
# litmusportal-*-service upstreams) matches none of them: it was always
# replaced, and without a mount nginx could not even start (those upstream
# hosts do not resolve). Hence EXPOSE 2001, the port all three deployments use.
ARG NODE_IMAGE=node:20
ARG UBI_MINIMAL_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10
FROM ${NODE_IMAGE} AS builder
WORKDIR /web
COPY . .
RUN npm install --legacy-peer-deps
RUN npm run build
FROM ${UBI_MINIMAL_IMAGE}
RUN microdnf update --nodocs \
    && microdnf module enable nginx:1.20 \
    && microdnf install --nodocs nginx \
    && microdnf clean all
COPY --from=builder /web/dist /opt/chaos
RUN chown 65534:0 -R /opt/chaos /var/log/nginx /etc/nginx
USER 65534
EXPOSE 2001
ENTRYPOINT ["sh", "-c", "nginx -c /etc/nginx/nginx.conf -g 'daemon off;'"]
