#!/usr/bin/env bash
# =============================================================================
# Renders deploy/kind/kind-agentcert.yaml (the checked-in template) into a
# per-checkout kind config with an instance-scoped cluster name and
# instance-scoped host ports substituted in from named env vars.
#
# Why this exists: kind cluster names and kind's extraPortMappings hostPorts
# are BOTH host-wide unique resources (Docker/kernel-level, not scoped to a
# checkout or user). Two engineers who each check out this monorepo onto the
# same shared host and run `kind create cluster --config
# deploy/kind/kind-agentcert.yaml` unmodified will collide on the cluster
# name AND on every single one of its 16 hostPort bindings. See CLAUDE.md
# section 0 for the incident this class of bug caused with Docker Compose;
# this is the same problem for the kind/Kubernetes path.
#
# Usage:
#   deploy/kind/render-kind-config.sh [output-path]
#   deploy/kind/render-kind-config.sh --personal-workspace
#
#   [output-path]         Render to this path (default:
#                          <repo-root>/.tmp/kind-agentcert.rendered.yaml).
#                          Always overwritten -- this output is disposable,
#                          regenerated from current env vars every call.
#   --personal-workspace  Render to <repo-root>/local-personal-workspace/
#                          kind-agentcert.yaml -- the file the compose-driven
#                          `cluster-init` service (docker-compose.yml /
#                          compose/cluster-init/entrypoint.sh) reads by
#                          default. Written ONLY if that file doesn't already
#                          exist, since docs already tell users to hand-edit
#                          it directly (see docs/setup/configuration.md) --
#                          this must never clobber a manual edit.
#
# Reads (all optional; fall back to this template's own checked-in values):
#   KIND_CLUSTER_NAME, KIND_HOSTPORT_INGRESS, KIND_HOSTPORT_WEB,
#   KIND_HOSTPORT_AUTH_REST, KIND_HOSTPORT_AUTH_GRPC,
#   KIND_HOSTPORT_GRAPHQL_REST, KIND_HOSTPORT_GRAPHQL_GRPC,
#   KIND_HOSTPORT_CERTIFIER, KIND_HOSTPORT_LITELLM, KIND_HOSTPORT_LANGFUSE,
#   KIND_HOSTPORT_MONGO, KIND_HOSTPORT_MINIO, KIND_HOSTPORT_OTEL_PROM_MCP,
#   KIND_HOSTPORT_OTEL_K8S_MCP, KIND_HOSTPORT_PROMETHEUS,
#   KIND_HOSTPORT_GRAFANA, KIND_HOSTPORT_DEX
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE="${SCRIPT_DIR}/kind-agentcert.yaml"

if [[ "${1:-}" == "--personal-workspace" ]]; then
    OUT="${REPO_ROOT}/local-personal-workspace/kind-agentcert.yaml"
    if [[ -f "${OUT}" ]]; then
        echo "[render-kind-config] ${OUT} already exists — leaving it untouched (hand-edit it directly for further changes)."
        exit 0
    fi
else
    OUT="${1:-${REPO_ROOT}/.tmp/kind-agentcert.rendered.yaml}"
fi

mkdir -p "$(dirname "${OUT}")"

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-agentcert}" \
KIND_HOSTPORT_INGRESS="${KIND_HOSTPORT_INGRESS:-8088}" \
KIND_HOSTPORT_WEB="${KIND_HOSTPORT_WEB:-2001}" \
KIND_HOSTPORT_AUTH_REST="${KIND_HOSTPORT_AUTH_REST:-3005}" \
KIND_HOSTPORT_AUTH_GRPC="${KIND_HOSTPORT_AUTH_GRPC:-3030}" \
KIND_HOSTPORT_GRAPHQL_REST="${KIND_HOSTPORT_GRAPHQL_REST:-8081}" \
KIND_HOSTPORT_GRAPHQL_GRPC="${KIND_HOSTPORT_GRAPHQL_GRPC:-8082}" \
KIND_HOSTPORT_CERTIFIER="${KIND_HOSTPORT_CERTIFIER:-18000}" \
KIND_HOSTPORT_LITELLM="${KIND_HOSTPORT_LITELLM:-14000}" \
KIND_HOSTPORT_LANGFUSE="${KIND_HOSTPORT_LANGFUSE:-4002}" \
KIND_HOSTPORT_MONGO="${KIND_HOSTPORT_MONGO:-27017}" \
KIND_HOSTPORT_MINIO="${KIND_HOSTPORT_MINIO:-19090}" \
KIND_HOSTPORT_OTEL_PROM_MCP="${KIND_HOSTPORT_OTEL_PROM_MCP:-31085}" \
KIND_HOSTPORT_OTEL_K8S_MCP="${KIND_HOSTPORT_OTEL_K8S_MCP:-31086}" \
KIND_HOSTPORT_PROMETHEUS="${KIND_HOSTPORT_PROMETHEUS:-31090}" \
KIND_HOSTPORT_GRAFANA="${KIND_HOSTPORT_GRAFANA:-31687}" \
KIND_HOSTPORT_DEX="${KIND_HOSTPORT_DEX:-32000}" \
python3 - "${TEMPLATE}" "${OUT}" <<'PY'
import os, re, sys

template_path, out_path = sys.argv[1], sys.argv[2]
text = open(template_path).read()

# containerPort -> env var name. Keyed on containerPort (the NodePort side),
# since that's the stable, unique identifier for each mapping -- hostPort is
# exactly the value we're replacing, so it can't double as the lookup key.
PORT_VARS = {
    80:    "KIND_HOSTPORT_INGRESS",
    32001: "KIND_HOSTPORT_WEB",
    32003: "KIND_HOSTPORT_AUTH_REST",
    32030: "KIND_HOSTPORT_AUTH_GRPC",
    32081: "KIND_HOSTPORT_GRAPHQL_REST",
    32082: "KIND_HOSTPORT_GRAPHQL_GRPC",
    32080: "KIND_HOSTPORT_CERTIFIER",
    31400: "KIND_HOSTPORT_LITELLM",
    32400: "KIND_HOSTPORT_LANGFUSE",
    32017: "KIND_HOSTPORT_MONGO",
    32090: "KIND_HOSTPORT_MINIO",
    31085: "KIND_HOSTPORT_OTEL_PROM_MCP",
    31086: "KIND_HOSTPORT_OTEL_K8S_MCP",
    31090: "KIND_HOSTPORT_PROMETHEUS",
    31687: "KIND_HOSTPORT_GRAFANA",
    32000: "KIND_HOSTPORT_DEX",
}

text = re.sub(r'^name: .*$', f'name: {os.environ["KIND_CLUSTER_NAME"]}',
              text, count=1, flags=re.MULTILINE)

def replace_hostport(match):
    var = PORT_VARS.get(int(match.group("cport")))
    if var is None:
        return match.group(0)
    return f'{match.group("cline")}{match.group("pre")}{os.environ[var]}{match.group("post")}'

pattern = re.compile(
    r'(?P<cline>^[ \t]*- containerPort: (?P<cport>\d+)\n)(?P<pre>[ \t]*hostPort: )\d+(?P<post>.*)$',
    re.MULTILINE,
)
text = pattern.sub(replace_hostport, text)

with open(out_path, "w") as f:
    f.write(text)

print(f"[render-kind-config] wrote {out_path} (cluster: {os.environ['KIND_CLUSTER_NAME']})")
PY
