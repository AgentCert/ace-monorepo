#!/usr/bin/env bash
# Starts (or confirms already-running) the port-forward the "kubernetes" MCP
# server needs for live/online SRE investigations against otel-demo.
#
# kubernetes-mcp-server is a ClusterIP-only service inside the otel-demo
# namespace (the same one flash-agent's live investigations already use), so
# it's only reachable from this host via a port-forward. prometheus-mcp-server
# is a NodePort (31085) and needs no forwarding -- see
# zero/zero-config/config.toml's [mcp_servers.kubernetes]/[mcp_servers.prometheus].
#
# Run this once before any zero invocation using a live/online prompt
# template (sre_react_online.md). Safe to re-run: skips if already forwarded.
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NAMESPACE="otel-demo"
SERVICE="kubernetes-mcp-server"
LOCAL_PORT="18081"
REMOTE_PORT="8081"

if curl -s -m 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${LOCAL_PORT}/mcp" 2>/dev/null | grep -qE "^[0-9]+$"; then
  echo "Port-forward to ${SERVICE} already active on :${LOCAL_PORT}"
  exit 0
fi

echo "Starting port-forward: ${SERVICE}.${NAMESPACE} ${LOCAL_PORT} -> ${REMOTE_PORT}"
nohup kubectl --kubeconfig "$KUBECONFIG" port-forward -n "$NAMESPACE" "svc/${SERVICE}" \
  "${LOCAL_PORT}:${REMOTE_PORT}" > /tmp/sre-agent-k8s-mcp-portforward.log 2>&1 < /dev/null &
disown

for _ in $(seq 1 15); do
  sleep 1
  if curl -s -m 2 -X POST "http://127.0.0.1:${LOCAL_PORT}/mcp" \
      -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"healthcheck","version":"1.0"}}}' \
      2>/dev/null | grep -q "serverInfo"; then
    echo "Port-forward ready on :${LOCAL_PORT}"
    exit 0
  fi
done

echo "ERROR: port-forward did not become ready within 15s -- check /tmp/sre-agent-k8s-mcp-portforward.log" >&2
exit 1
