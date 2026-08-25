#!/usr/bin/env bash
# Generates/updates the personal (gitignored) .vscode/settings.json with
# remote.portsAttributes for every ACE service port belonging to THIS
# checkout, plus a generated User-settings snippet for the Remote-SSH static
# forwards that create tunnels on reconnect.
#
# Ownership, not guessing: this host is shared, and other checkouts' ACE
# stacks (possibly on ACE's own unparameterized default ports, e.g. 2001)
# can be reachable on localhost too. An earlier version of this script
# TCP-probed candidate port *numbers* and trusted any that answered — which
# is exactly the shared-host collision CLAUDE.md §0 warns about: it forwarded
# another user's KinD deployment on port 2001 and labelled it "ACE Web UI".
# This version never trusts a bare port number. It only trusts ports read
# directly off containers it can prove belong to this checkout:
#   - the KinD node named "${KIND_CLUSTER_NAME}-control-plane", where
#     KIND_CLUSTER_NAME comes from this checkout's own .env
#   - any container whose name contains this checkout's own ACE_INSTANCE_NAME
#     (docker-compose.yml suffixes every container_name with it; Compose's
#     auto-generated names for the vendored langfuse/minio services embed the
#     ACE_INSTANCE_NAME-scoped project name too — see docker-compose.yml and
#     scripts/start-local-services.sh's langfuse_project variable)
#
# Safe to re-run any time (after setup.sh reassigns ports, after switching
# between compose and KinD, after a restart). It only touches the
# remote.autoForwardPorts / remote.portsAttributes keys and leaves any other
# personal VS Code settings in the file untouched.
#
# Stale-entry cleanup is tracked, not blind: each run records exactly which
# portsAttributes/defaultForwardedPorts entries it wrote into a gitignored
# state file (.vscode/.gen-vscode-ports.state.json). On the next run, an
# entry from that state file is deleted from settings.json only if it's
# still byte-for-byte what THIS script last wrote there — if the user
# hand-edited or added their own unrelated entries in between, those are
# left alone rather than being wiped by a full overwrite.
#
# Important limitation: a shell script running on the remote host cannot
# directly delete/recreate rows in the already-open local VS Code Ports panel.
# The live forwarded-port list is client-side Remote-SSH state. This script
# can only write the settings VS Code reads when a remote connection starts,
# and stop stale restored forwards from being resurrected on the next connect.
#
# Why both remote.portsAttributes AND remote.SSH.defaultForwardedPorts are
# generated (not just the former): VS Code's own source
# (src/vs/workbench/contrib/remote/common/remote.contribution.ts) documents
# "process" auto-forward mode as "ports will be automatically forwarded when
# discovered by watching for processes that are STARTED and include a port"
# — i.e. it is edge-triggered on a process-start event, not a periodic scan
# of already-listening sockets. ACE's containers are long-running background
# daemons that were already listening long before VS Code connects, so
# "process" mode structurally can never discover them — no amount of
# reloading the window changes this, since there is no start event to catch.
# remote.portsAttributes alone therefore only ever supplies labels for ports
# some *other* mechanism causes to be forwarded (e.g. ports the user forwards
# manually, or leftover forwards VS Code persisted from a prior session via
# remote.restoreForwardedPorts) — it was never actually auto-forwarding these
# ports itself. remote.SSH.defaultForwardedPorts is the Remote-SSH-extension
# setting built for exactly this case: a static list forwarded unconditionally
# on every connect, independent of any discovery heuristic. In practice,
# Remote-SSH may ignore that setting from workspace scope, so this script also
# writes .vscode/ace-vscode-ports.user-settings.json as the exact snippet to
# merge into VS Code User settings on the client side.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
SETTINGS_FILE="$REPO_ROOT/.vscode/settings.json"
STATE_FILE="$REPO_ROOT/.vscode/.gen-vscode-ports.state.json"
USER_SETTINGS_SNIPPET_FILE="$REPO_ROOT/.vscode/ace-vscode-ports.user-settings.json"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "No .env found at $ENV_FILE — run ./scripts/setup.sh first." >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "jq is required (apt install jq / brew install jq)." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker is required." >&2; exit 1; }

# .env is dotenv-style, not valid bash (e.g. ALLOWED_ORIGINS is an unquoted
# regex) — so pull individual values by line instead of `source`-ing it.
get_env() {
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | sed -E "s/^$1=//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//"
}

# container port (numeric) -> label, for the KinD node's published NodePorts.
kind_label_for() {
  case "$1" in
    32000) echo "Dex OIDC" ;;
    32001) echo "ACE Web UI" ;;
    32003) echo "Auth REST" ;;
    32017) echo "MongoDB" ;;
    32030) echo "Auth gRPC" ;;
    32080) echo "Certifier API" ;;
    32081) echo "GraphQL REST" ;;
    32082) echo "GraphQL gRPC" ;;
    32090) echo "MinIO S3" ;;
    32400) echo "Langfuse" ;;
    31400) echo "LiteLLM Proxy" ;;
    31090) echo "Prometheus" ;;
    31687) echo "Grafana" ;;
    31085) echo "Prometheus MCP (otel-demo)" ;;
    31086) echo "K8s MCP (otel-demo)" ;;
    80)    echo "Ingress" ;;
    *)     echo "" ;;
  esac
}

# container name + container port -> label, for compose/raw-run containers.
# These are only ever consulted for containers already proven to be ours
# (name contains ACE_INSTANCE_NAME), so the match just needs to pick the
# right label, not prove ownership again.
compose_label_for() {
  local name="$1" cport="$2"
  case "$name" in
    *mongo-init*|*mongo-keyfile*|*cluster-init*|*workspace-init*) return ;;
    *certifier*) echo "Certifier API" ;;
    *mongo*)     echo "MongoDB" ;;
    *auth*)      echo "Auth REST" ;;
    *graphql*)   echo "GraphQL REST" ;;
    *litellm*)   echo "LiteLLM Proxy" ;;
    *ollama*)    echo "Ollama API" ;;
    *minio*)
      case "$cport" in
        9001) echo "MinIO Console" ;;
        *)    echo "MinIO S3" ;;
      esac
      ;;
    *postgres*|*redis*|*clickhouse*) return ;;  # internal to Langfuse, no UI
    *langfuse*) echo "Langfuse" ;;
    *web*)      echo "ACE Web UI" ;;
    *)          echo "$name" ;;
  esac
}

declare -A forwarded=()

emit_ports() {
  # reads container's published ports as "<container_port>\t<host_port>" pairs
  local container="$1"
  docker inspect "$container" --format '{{json .NetworkSettings.Ports}}' 2>/dev/null \
    | jq -r 'select(. != null) | to_entries[] | select(.value != null) | .key as $k | .value[] | [($k | split("/")[0]), .HostPort] | @tsv'
}

# --- KinD path: only the control-plane container named from OUR OWN .env ---
kind_cluster="$(get_env KIND_CLUSTER_NAME)"
kind_found=0
if [[ -n "$kind_cluster" ]]; then
  cp_name="${kind_cluster}-control-plane"
  if docker inspect "$cp_name" >/dev/null 2>&1; then
    kind_found=1
    while IFS=$'\t' read -r cport hport; do
      [[ -z "${hport:-}" ]] && continue
      label="$(kind_label_for "$cport")"
      [[ -z "$label" ]] && continue
      forwarded["$hport"]="$label"
    done < <(emit_ports "$cp_name")
  fi
fi

# --- Compose / raw-run path: only containers whose name contains OUR OWN ACE_INSTANCE_NAME ---
instance="$(get_env ACE_INSTANCE_NAME)"
compose_found=0
if [[ -n "$instance" ]]; then
  while IFS= read -r cname; do
    [[ -z "$cname" ]] && continue
    compose_found=1
    while IFS=$'\t' read -r cport hport; do
      [[ -z "${hport:-}" ]] && continue
      label="$(compose_label_for "$cname" "$cport")"
      [[ -z "$label" ]] && continue
      forwarded["$hport"]="$label"
    done < <(emit_ports "$cname")
  done < <(docker ps --format '{{.Names}}' | grep -F -- "$instance" || true)
fi

if [[ $kind_found -eq 0 && $compose_found -eq 0 ]]; then
  echo "No containers found for KIND_CLUSTER_NAME='${kind_cluster}' or ACE_INSTANCE_NAME='${instance}'." >&2
  echo "Is the stack up? (start-local-services.sh / setup.sh --restart)" >&2
  exit 1
fi

if [[ ${#forwarded[@]} -eq 0 ]]; then
  echo "Found this checkout's containers but none had a recognized published port." >&2
  exit 1
fi

mkdir -p "$REPO_ROOT/.vscode"
[[ -f "$SETTINGS_FILE" ]] || echo '{}' > "$SETTINGS_FILE"
[[ -f "$STATE_FILE" ]] || echo '{"portsAttributes":{},"defaultForwardedPorts":[]}' > "$STATE_FILE"

new_attrs_json="{}"
new_dfp_json="[]"
for port in "${!forwarded[@]}"; do
  label="${forwarded[$port]}"
  new_attrs_json=$(jq --arg p "$port" --arg label "$label" \
    '. + {($p): {"label": $label, "onAutoForward": "silent"}}' <<<"$new_attrs_json")
  new_dfp_json=$(jq --arg p "$port" --arg label "$label" \
    '. + [{"name": $label, "remotePort": ($p | tonumber), "localPort": ($p | tonumber)}]' <<<"$new_dfp_json")
done

# Prune only entries this script itself wrote on a previous run (recorded in
# STATE_FILE) AND that still match byte-for-byte — i.e. nothing else touched
# them since. Anything the user added/edited by hand is left in place instead
# of being silently overwritten.
prev_state_json="$(cat "$STATE_FILE")"
prev_attrs_json="$(jq '.portsAttributes // {}' <<<"$prev_state_json")"
prev_dfp_json="$(jq '.defaultForwardedPorts // []' <<<"$prev_state_json")"

existing_attrs_json="$(jq '.["remote.portsAttributes"] // {}' "$SETTINGS_FILE")"
pruned_attrs_json="$(jq -n \
  --argjson existing "$existing_attrs_json" \
  --argjson prev "$prev_attrs_json" \
  '$existing | with_entries(select(($prev[.key] // null) != .value))')"

# Keep only entries that are NOT byte-identical to something this script
# wrote last run (i.e. user-owned entries). Anything script-owned is dropped
# here unconditionally: if it's still relevant, new_dfp_json below re-adds
# the fresh version; if it's stale, it should disappear entirely — either
# way it has no business surviving from pruned_dfp_json itself.
existing_dfp_json="$(jq '.["remote.SSH.defaultForwardedPorts"] // []' "$SETTINGS_FILE")"
pruned_dfp_json="$(jq -n \
  --argjson existing "$existing_dfp_json" \
  --argjson prev "$prev_dfp_json" \
  '$existing | map(select(. as $item | ($prev | any(. == $item)) | not))')"

# autoForwardPortsSource must be "process" (socket/process scan) rather than
# the default "output" (parses text printed to a VS Code terminal), since
# these ports never get printed to one — but see the top-of-file comment:
# neither mode can discover a port on a process that was already running
# before VS Code connected, which is why defaultForwardedPorts (below) is
# the mechanism actually doing the forwarding, not autoForwardPortsSource.
jq --argjson pruned "$pruned_attrs_json" --argjson new "$new_attrs_json" \
   --argjson pruned_dfp "$pruned_dfp_json" --argjson new_dfp "$new_dfp_json" \
  '.["remote.autoForwardPorts"] = true
   | .["remote.autoForwardPortsSource"] = "process"
   | .["remote.restoreForwardedPorts"] = false
   | .["remote.portsAttributes"] = ($pruned + $new)
   | .["remote.SSH.defaultForwardedPorts"] = ($pruned_dfp + $new_dfp)' \
  "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"

jq -n --argjson attrs "$new_attrs_json" --argjson dfp "$new_dfp_json" \
  '{
    "remote.autoForwardPorts": true,
    "remote.autoForwardPortsSource": "process",
    "remote.restoreForwardedPorts": false,
    "remote.portsAttributes": $attrs,
    "remote.SSH.defaultForwardedPorts": $dfp
  }' > "$USER_SETTINGS_SNIPPET_FILE.tmp" && mv "$USER_SETTINGS_SNIPPET_FILE.tmp" "$USER_SETTINGS_SNIPPET_FILE"

jq -n --argjson attrs "$new_attrs_json" --argjson dfp "$new_dfp_json" \
  '{"portsAttributes": $attrs, "defaultForwardedPorts": $dfp}' > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

echo "Wrote ${#forwarded[@]} port definition(s) belonging to this checkout (KIND_CLUSTER_NAME=${kind_cluster:-<unset>}, ACE_INSTANCE_NAME=${instance:-<unset>}):"
echo "  .vscode/settings.json: workspace labels/metadata, stale restore disabled"
echo "  .vscode/ace-vscode-ports.user-settings.json: User settings snippet for Remote-SSH static forwards"
for port in "${!forwarded[@]}"; do
  echo "  $port -> ${forwarded[$port]}"
done

# Ports actually dropped this run (were script-owned last run, no longer part
# of this checkout's stack).
dropped_json="$(jq -n --argjson existing "$existing_attrs_json" --argjson prev "$prev_attrs_json" --argjson new "$new_attrs_json" \
  '(($existing | with_entries(select(($prev[.key] // null) == .value))) | keys) - ($new | keys)')"
if [[ "$(jq 'length' <<<"$dropped_json")" -gt 0 ]]; then
  echo ""
  echo "Dropped $(jq 'length' <<<"$dropped_json") stale port(s) (no longer part of this checkout's stack):"
  jq -r '.[]' <<<"$dropped_json" | while read -r p; do echo "  $p"; done
fi

echo ""
echo "NOTE: this script cannot mutate the currently-open VS Code Ports panel from the remote shell."
echo "To force stale rows to disappear and new static forwards to appear, merge .vscode/ace-vscode-ports.user-settings.json into VS Code User settings on the client side, then reload/reconnect the Remote-SSH window."
