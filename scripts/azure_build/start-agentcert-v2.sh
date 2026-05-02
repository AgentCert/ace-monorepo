#!/bin/bash
# ============================================================================
# AgentCert Unified Startup Script v2 — Remote / Azure VM edition
# ============================================================================
# Merges good behavior from the legacy AgentCert/start-agentcert.sh
# (local-custom override hook) with the azure_build pattern (--env-file +
# --paths-file + LiteLLM K8s sync) and adds bug fixes:
#   1. Port-conflict check uses `ss -tlnp` so it catches root-owned listeners
#      (e.g. docker-proxy from a kind cluster squatting on 8080).
#   2. GraphQL readiness check verifies the process is alive after the bind,
#      catching the case where ss sees a foreign listener and we falsely
#      report "ready".
#   3. Auto-strips CRLF from chaoscenter/web/scripts/generate-certificate.sh
#      before running yarn generate-certificate.
#
# Usage:
#   bash start-agentcert-v2.sh \
#       --env-file   /path/to/.env \
#       --paths-file /path/to/build-paths.env
#
# Options:
#   --env-file   PATH   Path to .env             (required)
#   --paths-file PATH   Path to build-paths.env  (required — provides AGENTCERT_ROOT)
#   --skip-mongo        Skip MongoDB startup check
#   --skip-frontend     Skip Frontend startup
#   --skip-litellm      Skip LiteLLM K8s sync (useful when no kubectl/cluster)
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE=""
PATHS_FILE="${SCRIPT_DIR}/build-paths.env"
SKIP_MONGO=false
SKIP_FRONTEND=false
SKIP_LITELLM=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)      ENV_FILE="${2:-}";   shift 2 ;;
        --paths-file)    PATHS_FILE="${2:-}"; shift 2 ;;
        --skip-mongo)    SKIP_MONGO=true;     shift ;;
        --skip-frontend) SKIP_FRONTEND=true;  shift ;;
        --skip-litellm)  SKIP_LITELLM=true;   shift ;;
        *) echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${ENV_FILE}"  ]]; then echo "[ERROR] --env-file is required" >&2; exit 1; fi
if [[ ! -f "${ENV_FILE}"  ]]; then echo "[ERROR] .env file not found: ${ENV_FILE}" >&2; exit 1; fi
if [[ ! -f "${PATHS_FILE}" ]]; then echo "[ERROR] --paths-file not found: ${PATHS_FILE}" >&2; exit 1; fi

# shellcheck source=/dev/null
source "${PATHS_FILE}"

if [[ -z "${AGENTCERT_ROOT:-}" || ! -d "${AGENTCERT_ROOT}" ]]; then
    echo "[ERROR] AGENTCERT_ROOT not set or not found: ${AGENTCERT_ROOT:-<unset>}" >&2
    exit 1
fi

PID_DIR="${AGENTCERT_ROOT}"

# Read a value from the .env (handles unquoted JSON like INFRA_DEPLOYMENTS=[...])
env_val() {
    local key="$1" default="${2:-}" val
    val=$(grep -E "^${key}=" "${ENV_FILE}" | tail -1 | cut -d'=' -f2- | tr -d '\r\n' | sed 's/^["'"'"']//;s/["'"'"']$//')
    echo "${val:-${default}}"
}

status()  { echo -e "\033[36m[STATUS]\033[0m $1"; }
ok()      { echo -e "\033[32m[  OK  ]\033[0m $1"; }
fail()    { echo -e "\033[31m[FAILED]\033[0m $1"; }
wait_msg(){ echo -e "\033[33m[WAIT  ]\033[0m $1"; }

echo ""
echo -e "\033[35m============================================\033[0m"
echo -e "\033[35m   AgentCert Startup Script v2 (Remote/Azure)\033[0m"
echo -e "\033[35m============================================\033[0m"
echo -e "  AGENTCERT_ROOT: ${AGENTCERT_ROOT}"
echo -e "  env-file:       ${ENV_FILE}"
echo -e "  paths-file:     ${PATHS_FILE}"
echo ""

AUTH_DIR="${AGENTCERT_ROOT}/chaoscenter/authentication/api"
GQL_DIR="${AGENTCERT_ROOT}/chaoscenter/graphql/server"
WEB_DIR="${AGENTCERT_ROOT}/chaoscenter/web"

for d in "$AUTH_DIR" "$GQL_DIR" "$WEB_DIR"; do
    if [[ ! -d "$d" ]]; then
        echo "[ERROR] Directory not found: $d" >&2; exit 1
    fi
done

# ============================================================================
# Step 1: Port-conflict check (uses ss -tlnp to catch root-owned listeners)
# Asks user before killing host PIDs OR stopping docker containers that
# publish a conflicting port (e.g. kind's control-plane on 8080).
# Ports are read from .env so changing GQL_REST_PORT/GQL_GRPC_PORT/AUTH_*
# updates the conflict list, the GraphQL launch, and the summary.
# ============================================================================
# Read port values from .env up-front so the conflict list matches what we
# will actually try to bind below.
GQL_REST_PORT_PRE="$(env_val GQL_REST_PORT 8080)"
GQL_GRPC_PORT_PRE="$(env_val GQL_GRPC_PORT 8082)"
AUTH_REST_PORT_PRE="$(env_val AUTH_REST_PORT 3000)"
AUTH_GRPC_PORT_PRE="$(env_val AUTH_GRPC_PORT 3030)"
FRONTEND_PORT_PRE="$(env_val FRONTEND_PORT 2001)"

CHECK_PORTS=("$AUTH_GRPC_PORT_PRE" "$AUTH_REST_PORT_PRE" "$GQL_REST_PORT_PRE" "$GQL_GRPC_PORT_PRE" "$FRONTEND_PORT_PRE")

status "Checking for port conflicts on: ${CHECK_PORTS[*]}"
conflict=false
declare -a own_pids=()             # entries: "PID:port"
declare -a foreign_containers=()   # entries: "container:port"
declare -a foreign_unknown=()      # entries: "port"

for port in "${CHECK_PORTS[@]}"; do
    line=$(ss -tlnpH "( sport = :$port )" 2>/dev/null | head -1)
    [[ -z "$line" ]] && continue
    pid=$(echo "$line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
    pname=$(echo "$line" | grep -oE 'users:\(\("[^"]+' | head -1 | cut -d'"' -f2)
    if [[ -n "$pid" ]]; then
        fail "Port $port in use by ${pname:-unknown} (PID: $pid)"
        own_pids+=("$pid:$port")
    else
        # Listener owned by another user (typically root). Try to map it to a docker container.
        container=$(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | awk -F'|' -v p=":$port->" '$2 ~ p {print $1; exit}')
        if [[ -n "$container" ]]; then
            fail "Port $port held by docker container '$container'"
            foreign_containers+=("$container:$port")
        else
            fail "Port $port held by another user (no docker match; needs sudo to inspect)"
            foreign_unknown+=("$port")
        fi
    fi
    conflict=true
done

if [[ "$conflict" == true ]]; then
    echo ""
    if [[ ${#own_pids[@]} -gt 0 ]]; then
        echo "  Will kill (host PIDs): ${own_pids[*]}"
    fi
    if [[ ${#foreign_containers[@]} -gt 0 ]]; then
        echo "  Will 'docker stop'   : ${foreign_containers[*]}"
        echo "  (kind/control-plane stop will make in-cluster LiteLLM unreachable until restarted)"
    fi
    if [[ ${#foreign_unknown[@]} -gt 0 ]]; then
        echo "  Cannot free (manual): port(s) ${foreign_unknown[*]} — non-docker root-owned listener"
    fi
    read -rp "Free these ports? (Y/n) " response
    if [[ -z "$response" || "$response" =~ ^[Yy] ]]; then
        for entry in "${own_pids[@]}"; do
            pid="${entry%%:*}"; p="${entry##*:}"
            kill -9 "$pid" 2>/dev/null && ok "Killed PID $pid on port $p" || fail "Could not kill PID $pid"
        done
        if [[ ${#foreign_containers[@]} -gt 0 ]]; then
            declare -A _seen=()
            for entry in "${foreign_containers[@]}"; do
                c="${entry%%:*}"; p="${entry##*:}"
                [[ -n "${_seen[$c]:-}" ]] && continue
                _seen[$c]=1
                if docker stop "$c" >/dev/null 2>&1; then
                    ok "Stopped docker container '$c' (held port $p)"
                    [[ "$c" == *control-plane* || "$c" == *kind* ]] && SKIP_LITELLM=true && \
                        wait_msg "Auto-enabling --skip-litellm (cluster '$c' is stopped)"
                else
                    fail "Could not stop docker container '$c'"
                fi
            done
        fi
        if [[ ${#foreign_unknown[@]} -gt 0 ]]; then
            fail "Cannot free port(s) ${foreign_unknown[*]} from this user. Run: sudo ss -tlnp '( sport = :${foreign_unknown[0]} )'"
            exit 1
        fi
        sleep 2
    else
        fail "Cannot continue with ports in use. Exiting."; exit 1
    fi
else
    ok "No port conflicts detected"
fi

# ============================================================================
# Step 2: MongoDB
# ============================================================================
if [[ "$SKIP_MONGO" == false ]]; then
    status "Checking MongoDB..."
    mongo_running=false
    mongo_container=""
    if docker ps --filter "publish=27017" --format "{{.Names}}" 2>/dev/null | grep -q .; then
        mongo_container=$(docker ps --filter "publish=27017" --format "{{.Names}}" | head -1)
        ok "MongoDB running in container: $mongo_container"
        mongo_running=true
    fi
    if [[ "$mongo_running" == false ]]; then
        wait_msg "Starting MongoDB container..."
        if docker ps -a --format "{{.Names}}" | grep -qx "m3"; then
            mongo_container="m3"; docker start "$mongo_container" >/dev/null
        elif docker ps -a --format "{{.Names}}" | grep -qx "agentcert-mongo"; then
            mongo_container="agentcert-mongo"; docker start "$mongo_container" >/dev/null
        else
            mongo_container="agentcert-mongo"
            docker run -d --name "$mongo_container" -p 27017:27017 mongo:4.2 >/dev/null
        fi
        ok "Started MongoDB container '$mongo_container'"
    fi
    wait_msg "Waiting for MongoDB..."
    retries=0
    while [[ $retries -lt 10 ]]; do
        if docker exec "$mongo_container" mongosh --quiet --eval "db.adminCommand({ ping: 1 })" >/dev/null 2>&1 || \
           docker exec "$mongo_container" mongo --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
            ok "MongoDB is ready"; break
        fi
        retries=$((retries + 1)); sleep 1
    done
    [[ $retries -eq 10 ]] && { fail "MongoDB did not become ready in time"; exit 1; }
fi

# ============================================================================
# Step 3: Environment variables
# ============================================================================
status "Setting environment variables from ${ENV_FILE}..."

export VERSION="3.0.0"
export DB_SERVER="$(env_val DB_SERVER mongodb://localhost:27017)"
export JWT_SECRET="$(env_val JWT_SECRET litmus-portal@123)"
export DB_USER="$(env_val MONGODB_USERNAME admin)"
export DB_PASSWORD="$(env_val MONGODB_PASSWORD 1234)"
export SELF_AGENT="false"
export INFRA_COMPATIBLE_VERSIONS='["3.0.0"]'
# Origins that may open a WS to /query. Matches against the Host header.
# Allows: localhost / docker / minikube hostnames, tailscale 100.78.* and 100.104.*,
# kind/docker bridges 172.*, pod IPs 10.*, LAN 192.168.*.
export ALLOWED_ORIGINS='^(http://|https://|)((localhost|host\.docker\.internal|host\.minikube\.internal)|100\.78\.[0-9]+\.[0-9]+|100\.104\.[0-9]+\.[0-9]+|172\.[0-9]+\.[0-9]+\.[0-9]+|10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+)(:[0-9]+|)$'
export SKIP_SSL_VERIFY="true"
export ENABLE_GQL_INTROSPECTION="true"
export INFRA_SCOPE="cluster"
export ENABLE_INTERNAL_TLS="false"
export LITMUS_AUTH_GRPC_ENDPOINT="localhost"
export LITMUS_AUTH_GRPC_PORT="$(env_val LITMUS_AUTH_GRPC_PORT 3030)"
export ADMIN_USERNAME="$(env_val ADMIN_USERNAME admin)"
export ADMIN_PASSWORD="$(env_val ADMIN_PASSWORD litmus)"
export REST_PORT="$(env_val AUTH_REST_PORT 3000)"
export GRPC_PORT="$(env_val AUTH_GRPC_PORT 3030)"
export GQL_REST_PORT="$(env_val GQL_REST_PORT 8080)"
export GQL_GRPC_PORT="$(env_val GQL_GRPC_PORT 8082)"
# Frontend webpack.dev.js reads these to build the proxy target
# (default: graphql 8080, auth 3000). Must match GQL_REST_PORT / REST_PORT.
export GQL_PROXY_PORT="$(env_val GQL_PROXY_PORT "$GQL_REST_PORT")"
export AUTH_PROXY_PORT="$(env_val AUTH_PROXY_PORT "$REST_PORT")"
export TARGET_LOCALHOST="$(env_val TARGET_LOCALHOST true)"

export DEFAULT_HUB_GIT_URL="${CHAOS_CHARTS_GIT_URL:-https://github.com/agentcert/chaos-charts}"
export DEFAULT_HUB_BRANCH_NAME="master"

export SUBSCRIBER_IMAGE="$(env_val SUBSCRIBER_IMAGE agentcert/litmusportal-subscriber:3.0.0)"
export EVENT_TRACKER_IMAGE="$(env_val EVENT_TRACKER_IMAGE litmuschaos/litmusportal-event-tracker:3.0.0)"
export ARGO_WORKFLOW_CONTROLLER_IMAGE="$(env_val ARGO_WORKFLOW_CONTROLLER_IMAGE litmuschaos/workflow-controller:v3.3.1)"
export ARGO_WORKFLOW_EXECUTOR_IMAGE="$(env_val ARGO_WORKFLOW_EXECUTOR_IMAGE litmuschaos/argoexec:v3.3.1)"
export LITMUS_CHAOS_OPERATOR_IMAGE="$(env_val CHAOS_OPERATOR_IMAGE litmuschaos/chaos-operator:3.0.0)"
export LITMUS_CHAOS_RUNNER_IMAGE="$(env_val CHAOS_RUNNER_IMAGE litmuschaos/chaos-runner:3.0.0)"
export LITMUS_CHAOS_EXPORTER_IMAGE="$(env_val CHAOS_EXPORTER_IMAGE litmuschaos/chaos-exporter:3.0.0)"
export CONTAINER_RUNTIME_EXECUTOR="k8sapi"
export WORKFLOW_HELPER_IMAGE_VERSION="$(env_val WORKFLOW_HELPER_IMAGE_VERSION 3.0.0)"

export INSTALL_AGENT_IMAGE="$(env_val INSTALL_AGENT_IMAGE agentcert/agentcert-install-agent:latest)"
export INSTALL_AGENT_IMAGE_PULL_POLICY="$(env_val INSTALL_AGENT_IMAGE_PULL_POLICY Always)"
export INSTALL_APPLICATION_IMAGE="$(env_val INSTALL_APPLICATION_IMAGE agentcert/agentcert-install-app:latest)"
export INSTALL_APPLICATION_IMAGE_PULL_POLICY="$(env_val INSTALL_APPLICATION_IMAGE_PULL_POLICY Always)"
export FLASH_AGENT_IMAGE="$(env_val FLASH_AGENT_IMAGE agentcert/agentcert-flash-agent:latest)"
export AGENT_SIDECAR_IMAGE="$(env_val AGENT_SIDECAR_IMAGE agentcert/agent-sidecar:latest)"

export KUBERNETES_MCP_SERVER_IMAGE="quay.io/containers/kubernetes_mcp_server:latest"
export PROMETHEUS_MCP_SERVER_IMAGE="agentcert/prometheus-mcp-server:latest"
export PROMETHEUS_MCP_URL="http://prometheus.monitoring.svc.cluster.local:9090"
export INFRA_DEPLOYMENTS='["app=chaos-exporter", "name=chaos-operator", "app=event-tracker","app=workflow-controller","app=kubernetes-mcp-server","app=prometheus-mcp-server"]'

export DEFAULT_AGENT_HUB_GIT_URL="${AGENT_CHARTS_GIT_URL:-https://github.com/agentcert/agent-charts}"
export DEFAULT_AGENT_HUB_BRANCH_NAME="main"
export DEFAULT_AGENT_HUB_PATH="${AGENT_CHARTS_ROOT:-/tmp/default}"
export DEFAULT_APP_HUB_GIT_URL="${APP_CHARTS_GIT_URL:-https://github.com/agentcert/app-charts}"
export DEFAULT_APP_HUB_BRANCH_NAME="main"
export DEFAULT_APP_HUB_PATH="${APP_CHARTS_ROOT:-/tmp/default}"

export AZURE_OPENAI_KEY="$(env_val AZURE_OPENAI_KEY)"
export AZURE_OPENAI_ENDPOINT="$(env_val AZURE_OPENAI_ENDPOINT)"
export AZURE_OPENAI_DEPLOYMENT="$(env_val AZURE_OPENAI_DEPLOYMENT gpt-4)"
export AZURE_OPENAI_API_VERSION="$(env_val AZURE_OPENAI_API_VERSION 2024-12-01-preview)"
export AZURE_OPENAI_EMBEDDING_DEPLOYMENT="$(env_val AZURE_OPENAI_EMBEDDING_DEPLOYMENT text-embedding-3-small)"

export LITELLM_MASTER_KEY="$(env_val LITELLM_MASTER_KEY sk-litellm-local-dev)"
export LITELLM_PROXY_IMAGE="$(env_val LITELLM_PROXY_IMAGE agentcert/agentcert-litellm-proxy:dev)"
export LITELLM_PROFILE="$(env_val LITELLM_PROFILE azure)"
export OPENAI_BASE_URL="$(env_val OPENAI_BASE_URL http://litellm-proxy.litellm.svc.cluster.local:4000/v1)"
export OPENAI_API_KEY="${LITELLM_MASTER_KEY}"
export MODEL_ALIAS="$(env_val AZURE_OPENAI_DEPLOYMENT gpt-4)"

export LANGFUSE_HOST="$(env_val LANGFUSE_HOST)"
export LANGFUSE_PUBLIC_KEY="$(env_val LANGFUSE_PUBLIC_KEY)"
export LANGFUSE_SECRET_KEY="$(env_val LANGFUSE_SECRET_KEY)"
export LANGFUSE_ORG_ID="$(env_val LANGFUSE_ORG_ID)"
export LANGFUSE_PROJECT_ID="$(env_val LANGFUSE_PROJECT_ID)"
export OTEL_EXPORTER_OTLP_ENDPOINT="$(env_val AGENT_OTEL_EXPORTER_OTLP_ENDPOINT)"
export OTEL_EXPORTER_OTLP_HEADERS="$(env_val AGENT_OTEL_EXPORTER_OTLP_HEADERS)"

export PRE_CLEANUP_WAIT_SECONDS="$(env_val PRE_CLEANUP_WAIT_SECONDS 0)"
export BLIND_TRACES="$(env_val BLIND_TRACES yes)"

# Local per-VM overrides (legacy hook from old start-agentcert.sh)
DOTENV_OVERRIDE="${AGENTCERT_ROOT}/local-custom/config/.env"
if [[ -f "$DOTENV_OVERRIDE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$DOTENV_OVERRIDE"
    set +a
    ok "Loaded local overrides from $DOTENV_OVERRIDE"
fi

# Default for subscriber callbacks; overridden by local-custom/config/.env if set
export CHAOS_CENTER_UI_ENDPOINT="${CHAOS_CENTER_UI_ENDPOINT:-http://localhost:${GQL_REST_PORT}}"

ok "Environment variables set"

# ============================================================================
# Step 3b: LiteLLM K8s ConfigMap + Secret + rollout
# ============================================================================
LITELLM_NS="litellm"
LITELLM_DEPLOY="litellm-proxy"
LITELLM_DIR="${AGENT_CHARTS_ROOT:-}/litellm"
SERVER_NS="litmus-chaos"
SERVER_DEPLOY="litmusportal-server"

if [[ "$SKIP_LITELLM" == true ]]; then
    status "Skipping LiteLLM K8s sync (--skip-litellm)"
elif ! command -v kubectl >/dev/null 2>&1; then
    fail "kubectl not found; skipping LiteLLM K8s sync"
elif [[ ! -d "${LITELLM_DIR}" ]]; then
    fail "LiteLLM manifest dir not found: ${LITELLM_DIR} — skipping K8s sync"
else
    status "Applying LiteLLM namespace and configmap..."
    kubectl apply -f "${LITELLM_DIR}/namespace.yaml"
    sed "s/model_name: LITELLM_MODEL_NAME/model_name: ${AZURE_OPENAI_DEPLOYMENT}/g" \
        "${LITELLM_DIR}/configmap.yaml" | kubectl apply -f -

    status "Applying LiteLLM secret with keys from .env..."
    AZURE_API_KEY="$(env_val AZURE_OPENAI_KEY)"
    [[ -z "${AZURE_API_KEY}" ]] && AZURE_API_KEY="$(env_val AZURE_OPENAI_API_KEY)"
    AZURE_MODEL="azure/${AZURE_OPENAI_DEPLOYMENT}"
    kubectl -n "${LITELLM_NS}" create secret generic litellm-secrets \
        --from-literal=AZURE_API_KEY="${AZURE_API_KEY}" \
        --from-literal=AZURE_API_BASE="${AZURE_OPENAI_ENDPOINT}" \
        --from-literal=AZURE_MODEL="${AZURE_MODEL}" \
        --from-literal=AZURE_API_VERSION="${AZURE_OPENAI_API_VERSION}" \
        --from-literal=OPENAI_API_KEY="${LITELLM_MASTER_KEY}" \
        --from-literal=LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY}" \
        --from-literal=LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY}" \
        --from-literal=LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY}" \
        --from-literal=LANGFUSE_HOST="${LANGFUSE_HOST}" \
        --dry-run=client -o yaml | kubectl apply -f -

    status "Applying LiteLLM deployment and restarting pod..."
    kubectl apply -f "${LITELLM_DIR}/deployment.yaml"
    kubectl -n "${LITELLM_NS}" set image deployment/"${LITELLM_DEPLOY}" \
        litellm="${LITELLM_PROXY_IMAGE}" >/dev/null
    kubectl -n "${LITELLM_NS}" rollout restart deployment/"${LITELLM_DEPLOY}"
    kubectl -n "${LITELLM_NS}" rollout status deployment/"${LITELLM_DEPLOY}" --timeout=180s
    ok "LiteLLM restarted with fresh config and secrets"

    if kubectl get deployment "${SERVER_DEPLOY}" -n "${SERVER_NS}" >/dev/null 2>&1; then
        OPENAI_BASE_URL="$(env_val OPENAI_BASE_URL http://litellm-proxy.litellm.svc.cluster.local:4000/v1)"
        kubectl set env deployment/"${SERVER_DEPLOY}" -n "${SERVER_NS}" \
            LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY}" \
            OPENAI_API_KEY="${LITELLM_MASTER_KEY}" \
            OPENAI_BASE_URL="${OPENAI_BASE_URL}" \
            MODEL_ALIAS="${AZURE_OPENAI_DEPLOYMENT}" >/dev/null
        ok "litmusportal-server env synced"
    fi
fi

# ============================================================================
# Step 4: Auth Service
# ============================================================================
status "Starting Authentication Service..."
(cd "$AUTH_DIR" && go run main.go > "$PID_DIR/.auth.log" 2>&1) &
AUTH_PID=$!
echo "$AUTH_PID" > "$PID_DIR/.agentcert-auth.pid"

wait_msg "Waiting for Auth Service on port 3030..."
retries=0
while [[ $retries -lt 30 ]]; do
    if ss -tlnp 2>/dev/null | grep -q ":3030 " || netstat -tlnp 2>/dev/null | grep -q ":3030 "; then
        ok "Authentication Service ready (PID: $AUTH_PID)"; break
    fi
    retries=$((retries + 1)); sleep 1
done
[[ $retries -eq 30 ]] && { fail "Authentication Service did not start. Check $PID_DIR/.auth.log"; exit 1; }

# ============================================================================
# Step 5: GraphQL Server
# ============================================================================
status "Starting GraphQL Server..."
status "Tidying GraphQL dependencies..."
(cd "$GQL_DIR" && go mod tidy)
ok "GraphQL dependencies ready"

GQL_APP_NAME="agentcert-graph"
GQL_BINARY="$GQL_DIR/$GQL_APP_NAME"
status "Building GraphQL binary..."
# -buildvcs=false avoids 'error obtaining VCS status' on shared/ownership-protected repos
(cd "$GQL_DIR" && go build -buildvcs=false -o "$GQL_APP_NAME" .)
ok "GraphQL binary built"

pkill -f "$GQL_APP_NAME" 2>/dev/null || true
sleep 1

(cd "$GQL_DIR" && nohup env \
  REST_PORT="$GQL_REST_PORT" \
  GRPC_PORT="$GQL_GRPC_PORT" \
  OTEL_EXPORTER_OTLP_ENDPOINT="$OTEL_EXPORTER_OTLP_ENDPOINT" \
  OTEL_EXPORTER_OTLP_HEADERS="$OTEL_EXPORTER_OTLP_HEADERS" \
  "$GQL_BINARY" >> "$PID_DIR/.graphql.log" 2>&1) &
GQL_PID=$!
echo "$GQL_PID" > "$PID_DIR/.agentcert-graphql.pid"

wait_msg "Waiting for GraphQL Server on port ${GQL_REST_PORT}..."
retries=0
gql_ok=false
while [[ $retries -lt 30 ]]; do
    # Check the listener belongs to OUR PID (catches kind/docker-proxy false positives)
    listener_pid=$(ss -tlnpH "( sport = :${GQL_REST_PORT} )" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
    if [[ -n "$listener_pid" ]] && kill -0 "$GQL_PID" 2>/dev/null; then
        gql_ok=true; ok "GraphQL Server ready (PID: $GQL_PID, listener PID: $listener_pid)"; break
    fi
    if ! kill -0 "$GQL_PID" 2>/dev/null; then
        fail "GraphQL Server process died. Check $PID_DIR/.graphql.log"
        tail -20 "$PID_DIR/.graphql.log" >&2 || true
        kill "$AUTH_PID" 2>/dev/null || true; exit 1
    fi
    retries=$((retries + 1)); sleep 1
done
if [[ "$gql_ok" != true ]]; then
    fail "GraphQL Server did not bind port ${GQL_REST_PORT} in time. Check $PID_DIR/.graphql.log"
    kill "$GQL_PID" "$AUTH_PID" 2>/dev/null || true; exit 1
fi

# ============================================================================
# Step 6: Frontend (optional)
# ============================================================================
if [[ "$SKIP_FRONTEND" == false ]]; then
    status "Starting Frontend..."
    if [[ ! -f "$WEB_DIR/package.json" ]]; then
        fail "package.json not found in $WEB_DIR"
    else
        if ! command -v yarn >/dev/null 2>&1; then
            fail "yarn not installed. Run: npm install -g yarn"
            kill "$GQL_PID" "$AUTH_PID" 2>/dev/null || true; exit 1
        fi

        needs_install=false
        [[ ! -d "$WEB_DIR/node_modules" || ! -x "$WEB_DIR/node_modules/.bin/webpack" ]] && needs_install=true
        if [[ "$needs_install" == true ]]; then
            wait_msg "Installing frontend dependencies..."
            if ! (cd "$WEB_DIR" && yarn install --frozen-lockfile); then
                (cd "$WEB_DIR" && yarn install)
            fi
            ok "Frontend dependencies installed"
        else
            ok "Frontend dependencies already present"
        fi

        # Strip CRLF from cert script (common after Windows-side edits)
        CERT_SCRIPT="$WEB_DIR/scripts/generate-certificate.sh"
        if [[ -f "$CERT_SCRIPT" ]] && grep -q $'\r' "$CERT_SCRIPT"; then
            sed -i 's/\r$//' "$CERT_SCRIPT"
            ok "Stripped CRLF from $(basename "$CERT_SCRIPT")"
        fi
        # Remove any stray 'certificates\r' dir created by past CRLF runs
        find "$WEB_DIR" -maxdepth 1 -type d -name $'certificates\r' -exec rm -rf {} + 2>/dev/null || true

        cert_count=$(find "$WEB_DIR" -maxdepth 3 -type f \( -name "*.crt" -o -name "*.key" -o -name "*.pem" \) | wc -l | tr -d ' ')
        if (cd "$WEB_DIR" && yarn run 2>/dev/null | grep -q "generate-certificate") && [[ "$cert_count" == "0" ]]; then
            wait_msg "Generating frontend certificates..."
            (cd "$WEB_DIR" && yarn generate-certificate)
            ok "Frontend certificates generated"
        fi

        (cd "$WEB_DIR" && yarn dev > "$PID_DIR/.frontend.log" 2>&1) &
        FE_PID=$!
        echo "$FE_PID" > "$PID_DIR/.agentcert-frontend.pid"

        wait_msg "Waiting for Frontend on port 2001..."
        retries=0
        while [[ $retries -lt 60 ]]; do
            if ss -tlnp 2>/dev/null | grep -q ":2001 " || netstat -tlnp 2>/dev/null | grep -q ":2001 "; then
                ok "Frontend ready (PID: $FE_PID)"; break
            fi
            retries=$((retries + 1)); sleep 1
        done
        [[ $retries -eq 60 ]] && echo -e "\033[33m[WAIT  ]\033[0m Frontend still building. Check $PID_DIR/.frontend.log"
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo -e "\033[32m============================================\033[0m"
echo -e "\033[32m     AgentCert Started Successfully!       \033[0m"
echo -e "\033[32m============================================\033[0m"
echo ""
echo "Services:"
echo "  - MongoDB:        $(env_val MONGODB_HOST localhost):$(env_val MONGODB_PORT 27017)"
echo "  - Auth Service:   localhost:${GRPC_PORT} (gRPC) / localhost:${REST_PORT} (REST)"
echo "  - GraphQL Server: http://localhost:${GQL_REST_PORT}"
[[ "$SKIP_FRONTEND" == false ]] && echo "  - Frontend:       https://localhost:2001"
echo ""
echo "Login: $(env_val ADMIN_USERNAME admin) / $(env_val ADMIN_PASSWORD litmus)"
echo ""
echo "Logs:"
echo "  - Auth:     $PID_DIR/.auth.log"
echo "  - GraphQL:  $PID_DIR/.graphql.log"
[[ "$SKIP_FRONTEND" == false ]] && echo "  - Frontend: $PID_DIR/.frontend.log"
echo ""
echo -e "\033[33mTo stop: bash ${AGENTCERT_ROOT}/stop-agentcert.sh\033[0m"
echo ""
