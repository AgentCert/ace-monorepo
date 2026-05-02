#!/bin/bash
# ============================================================================
# AgentCert Unified Startup Script -- Remote / Azure VM edition
# ============================================================================
# Reads all config (image tags, secrets, paths) from --env-file and
# --paths-file. No hardcoded secrets or paths.
#
# Usage:
#   bash start-agentcert.sh --env-file /path/to/.env --paths-file /path/to/build-paths.env
#
# Options:
#   --env-file   PATH   Path to .env  (required)
#   --paths-file PATH   Path to build-paths.env  (required -- provides AGENTCERT_ROOT)
#   --skip-mongo        Skip MongoDB startup check
#   --skip-frontend     Skip Frontend startup
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE=""
PATHS_FILE="${SCRIPT_DIR}/build-paths.env"
SKIP_MONGO=false
SKIP_FRONTEND=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)   ENV_FILE="${2:-}";   shift 2 ;;
        --paths-file) PATHS_FILE="${2:-}"; shift 2 ;;
        --skip-mongo)    SKIP_MONGO=true;    shift ;;
        --skip-frontend) SKIP_FRONTEND=true; shift ;;
        *) echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${ENV_FILE}" ]]; then
    echo "[ERROR] --env-file is required" >&2; exit 1
fi
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "[ERROR] .env file not found: ${ENV_FILE}" >&2; exit 1
fi
if [[ ! -f "${PATHS_FILE}" ]]; then
    echo "[ERROR] --paths-file not found: ${PATHS_FILE}" >&2; exit 1
fi

# Load paths file (provides AGENTCERT_ROOT, APP_CHARTS_ROOT, etc.)
# shellcheck source=/dev/null
source "${PATHS_FILE}"

if [[ -z "${AGENTCERT_ROOT:-}" || ! -d "${AGENTCERT_ROOT}" ]]; then
    echo "[ERROR] AGENTCERT_ROOT not set or not found: ${AGENTCERT_ROOT:-<unset>}" >&2
    echo "[ERROR] Update ${PATHS_FILE} or run build-all.sh with --git first." >&2
    exit 1
fi

PID_DIR="${AGENTCERT_ROOT}"

# Helper: read a value from the .env file
env_val() {
    local key="$1"
    local default="${2:-}"
    local val
    val=$(grep -E "^${key}=" "${ENV_FILE}" | tail -1 | cut -d'=' -f2- | tr -d '\r\n' | sed 's/^["'"'"']//;s/["'"'"']$//')
    echo "${val:-${default}}"
}

status()  { echo -e "\033[36m[STATUS]\033[0m $1"; }
ok()      { echo -e "\033[32m[  OK  ]\033[0m $1"; }
fail()    { echo -e "\033[31m[FAILED]\033[0m $1"; }
wait_msg(){ echo -e "\033[33m[WAIT  ]\033[0m $1"; }

echo ""
echo -e "\033[35m============================================\033[0m"
echo -e "\033[35m   AgentCert Startup Script (Remote/Azure) \033[0m"
echo -e "\033[35m============================================\033[0m"
echo -e "  AGENTCERT_ROOT: ${AGENTCERT_ROOT}"
echo -e "  env-file:       ${ENV_FILE}"
echo ""

# Derive component directories from AGENTCERT_ROOT
AUTH_DIR="${AGENTCERT_ROOT}/chaoscenter/authentication/api"
GQL_DIR="${AGENTCERT_ROOT}/chaoscenter/graphql/server"
WEB_DIR="${AGENTCERT_ROOT}/chaoscenter/web"

for d in "$AUTH_DIR" "$GQL_DIR" "$WEB_DIR"; do
    if [[ ! -d "$d" ]]; then
        echo "[ERROR] Directory not found: $d" >&2
        echo "[ERROR] Run build-all.sh with --git first to clone the repo." >&2
        exit 1
    fi
done

# ============================================================================
# Step 1: Check for port conflicts
# ============================================================================
status "Checking for port conflicts..."
conflict=false
for port in 3030 3000 8080 8082 2001; do
    pid=$(lsof -ti :"$port" 2>/dev/null || true)
    if [ -n "$pid" ]; then
        pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        fail "Port $port in use by $pname (PID: $pid)"
        conflict=true
    fi
done
if [ "$conflict" = true ]; then
    echo ""
    read -rp "Kill conflicting processes? (Y/n) " response
    if [[ -z "$response" || "$response" =~ ^[Yy] ]]; then
        for port in 3030 3000 8080 8082 2001; do
            pid=$(lsof -ti :"$port" 2>/dev/null || true)
            [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true && ok "Killed process on port $port"
        done
        sleep 2
    else
        fail "Cannot continue with ports in use. Exiting."; exit 1
    fi
else
    ok "No port conflicts detected"
fi

# ============================================================================
# Step 2: Check MongoDB
# ============================================================================
if [ "$SKIP_MONGO" = false ]; then
    status "Checking MongoDB..."
    mongo_running=false
    mongo_container=""
    if docker ps --filter "publish=27017" --format "{{.Names}}" 2>/dev/null | grep -q .; then
        mongo_container=$(docker ps --filter "publish=27017" --format "{{.Names}}" 2>/dev/null | head -1)
        ok "MongoDB running in container: $mongo_container"
        mongo_running=true
    fi
    if [ "$mongo_running" = false ]; then
        wait_msg "Starting MongoDB container..."
        if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qx "m3"; then
            mongo_container="m3"; docker start "$mongo_container" > /dev/null
        elif docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qx "agentcert-mongo"; then
            mongo_container="agentcert-mongo"; docker start "$mongo_container" > /dev/null
        else
            mongo_container="agentcert-mongo"
            docker run -d --name "$mongo_container" -p 27017:27017 mongo:4.2 > /dev/null
        fi
        ok "Started MongoDB container '$mongo_container'"
        mongo_running=true
    fi
    wait_msg "Waiting for MongoDB..."
    retries=0
    while [ $retries -lt 10 ]; do
        if docker exec "$mongo_container" mongosh --quiet --eval "db.adminCommand({ ping: 1 })" > /dev/null 2>&1 || \
           docker exec "$mongo_container" mongo --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
            ok "MongoDB is ready"; break
        fi
        retries=$((retries + 1)); sleep 1
    done
    [ $retries -eq 10 ] && fail "MongoDB did not become ready in time" && exit 1
fi

# ============================================================================
# Step 3: Set environment variables (all from .env)
# ============================================================================
status "Setting environment variables from ${ENV_FILE}..."

export VERSION="3.0.0"
export DB_SERVER="$(env_val DB_SERVER mongodb://localhost:27017)"
export JWT_SECRET="$(env_val JWT_SECRET litmus-portal@123)"
export DB_USER="$(env_val MONGODB_USERNAME admin)"
export DB_PASSWORD="$(env_val MONGODB_PASSWORD 1234)"
export SELF_AGENT="false"
export INFRA_COMPATIBLE_VERSIONS='["3.0.0"]'
export ALLOWED_ORIGINS='^(http://|https://|)((localhost|host\.docker\.internal|host\.minikube\.internal)|100\.78\.[0-9]+\.[0-9]+)(:[0-9]+|)$'
export SKIP_SSL_VERIFY="true"
export ENABLE_GQL_INTROSPECTION="true"
export INFRA_SCOPE="cluster"
export ENABLE_INTERNAL_TLS="false"
export LITMUS_AUTH_GRPC_ENDPOINT="localhost"
export LITMUS_AUTH_GRPC_PORT="$(env_val LITMUS_AUTH_GRPC_PORT 3030)"
export ADMIN_USERNAME="$(env_val ADMIN_USERNAME admin)"
export ADMIN_PASSWORD="$(env_val ADMIN_PASSWORD litmus)"
# All ports read from .env; AUTH_REST_PORT/AUTH_GRPC_PORT exported as REST_PORT/GRPC_PORT
# because that is what the authentication binary reads via envconfig.
export REST_PORT="$(env_val AUTH_REST_PORT 3000)"
export GRPC_PORT="$(env_val AUTH_GRPC_PORT 3030)"
export GQL_REST_PORT="$(env_val GQL_REST_PORT 8080)"
export GQL_GRPC_PORT="$(env_val GQL_GRPC_PORT 8082)"

# Chaos Hub
export DEFAULT_HUB_GIT_URL="${CHAOS_CHARTS_GIT_URL:-https://github.com/agentcert/chaos-charts}"
export DEFAULT_HUB_BRANCH_NAME="master"

# Standard infra images
export SUBSCRIBER_IMAGE="$(env_val SUBSCRIBER_IMAGE agentcert/litmusportal-subscriber:3.0.0)"
export EVENT_TRACKER_IMAGE="$(env_val EVENT_TRACKER_IMAGE litmuschaos/litmusportal-event-tracker:3.0.0)"
export ARGO_WORKFLOW_CONTROLLER_IMAGE="$(env_val ARGO_WORKFLOW_CONTROLLER_IMAGE litmuschaos/workflow-controller:v3.3.1)"
export ARGO_WORKFLOW_EXECUTOR_IMAGE="$(env_val ARGO_WORKFLOW_EXECUTOR_IMAGE litmuschaos/argoexec:v3.3.1)"
export LITMUS_CHAOS_OPERATOR_IMAGE="$(env_val CHAOS_OPERATOR_IMAGE litmuschaos/chaos-operator:3.0.0)"
export LITMUS_CHAOS_RUNNER_IMAGE="$(env_val CHAOS_RUNNER_IMAGE litmuschaos/chaos-runner:3.0.0)"
export LITMUS_CHAOS_EXPORTER_IMAGE="$(env_val CHAOS_EXPORTER_IMAGE litmuschaos/chaos-exporter:3.0.0)"
export CONTAINER_RUNTIME_EXECUTOR="k8sapi"
export WORKFLOW_HELPER_IMAGE_VERSION="$(env_val WORKFLOW_HELPER_IMAGE_VERSION 3.0.0)"

# Custom images -- updated by azure_build scripts after each Docker Hub push
export INSTALL_AGENT_IMAGE="$(env_val INSTALL_AGENT_IMAGE agentcert/agentcert-install-agent:latest)"
export INSTALL_AGENT_IMAGE_PULL_POLICY="$(env_val INSTALL_AGENT_IMAGE_PULL_POLICY Always)"
export INSTALL_APPLICATION_IMAGE="$(env_val INSTALL_APPLICATION_IMAGE agentcert/agentcert-install-app:latest)"
export INSTALL_APPLICATION_IMAGE_PULL_POLICY="$(env_val INSTALL_APPLICATION_IMAGE_PULL_POLICY Always)"
export FLASH_AGENT_IMAGE="$(env_val FLASH_AGENT_IMAGE agentcert/agentcert-flash-agent:latest)"
export AGENT_SIDECAR_IMAGE="$(env_val AGENT_SIDECAR_IMAGE agentcert/agent-sidecar:latest)"

# MCP server images
export KUBERNETES_MCP_SERVER_IMAGE="quay.io/containers/kubernetes_mcp_server:latest"
export PROMETHEUS_MCP_SERVER_IMAGE="agentcert/prometheus-mcp-server:latest"
export PROMETHEUS_MCP_URL="http://prometheus.monitoring.svc.cluster.local:9090"
export INFRA_DEPLOYMENTS='["app=chaos-exporter", "name=chaos-operator", "app=event-tracker","app=workflow-controller","app=kubernetes-mcp-server","app=prometheus-mcp-server"]'

# Hub paths from build-paths.env
export DEFAULT_AGENT_HUB_GIT_URL="${AGENT_CHARTS_GIT_URL:-https://github.com/agentcert/agent-charts}"
export DEFAULT_AGENT_HUB_BRANCH_NAME="main"
export DEFAULT_AGENT_HUB_PATH="${AGENT_CHARTS_ROOT:-/tmp/default}"
export DEFAULT_APP_HUB_GIT_URL="${APP_CHARTS_GIT_URL:-https://github.com/agentcert/app-charts}"
export DEFAULT_APP_HUB_BRANCH_NAME="main"
export DEFAULT_APP_HUB_PATH="${APP_CHARTS_ROOT:-/tmp/default}"

# Azure OpenAI
export AZURE_OPENAI_KEY="$(env_val AZURE_OPENAI_KEY)"
export AZURE_OPENAI_ENDPOINT="$(env_val AZURE_OPENAI_ENDPOINT)"
export AZURE_OPENAI_DEPLOYMENT="$(env_val AZURE_OPENAI_DEPLOYMENT gpt-4)"
export AZURE_OPENAI_API_VERSION="$(env_val AZURE_OPENAI_API_VERSION 2024-12-01-preview)"
export AZURE_OPENAI_EMBEDDING_DEPLOYMENT="$(env_val AZURE_OPENAI_EMBEDDING_DEPLOYMENT text-embedding-3-small)"

# LiteLLM
export LITELLM_MASTER_KEY="$(env_val LITELLM_MASTER_KEY sk-litellm-local-dev)"
export LITELLM_PROXY_IMAGE="$(env_val LITELLM_PROXY_IMAGE agentcert/agentcert-litellm-proxy:dev)"
export LITELLM_PROFILE="$(env_val LITELLM_PROFILE azure)"
export OPENAI_BASE_URL="$(env_val OPENAI_BASE_URL http://litellm-proxy.litellm.svc.cluster.local:4000/v1)"
export OPENAI_API_KEY="${LITELLM_MASTER_KEY}"
export MODEL_ALIAS="$(env_val AZURE_OPENAI_DEPLOYMENT gpt-4)"

# Langfuse / OTEL
export LANGFUSE_HOST="$(env_val LANGFUSE_HOST)"
export LANGFUSE_PUBLIC_KEY="$(env_val LANGFUSE_PUBLIC_KEY)"
export LANGFUSE_SECRET_KEY="$(env_val LANGFUSE_SECRET_KEY)"
export LANGFUSE_ORG_ID="$(env_val LANGFUSE_ORG_ID)"
export LANGFUSE_PROJECT_ID="$(env_val LANGFUSE_PROJECT_ID)"
export OTEL_EXPORTER_OTLP_ENDPOINT="$(env_val AGENT_OTEL_EXPORTER_OTLP_ENDPOINT)"
export OTEL_EXPORTER_OTLP_HEADERS="$(env_val AGENT_OTEL_EXPORTER_OTLP_HEADERS)"

# Misc
export PRE_CLEANUP_WAIT_SECONDS="$(env_val PRE_CLEANUP_WAIT_SECONDS 0)"
export BLIND_TRACES="$(env_val BLIND_TRACES yes)"

# SLA contract (org-wide defaults; per-experiment override comes via Argo annotation in Phase 2)
export SLA_DETECT_SEC="$(env_val SLA_DETECT_SEC 60)"
export SLA_MITIGATE_SEC="$(env_val SLA_MITIGATE_SEC 300)"
export SLA_TOOL_CALL_SEC="$(env_val SLA_TOOL_CALL_SEC 30)"

ok "Environment variables set"

# ============================================================================
# Step 3b: Apply LiteLLM K8s ConfigMap + Secret + rollout restart
# ============================================================================
LITELLM_NS="litellm"
LITELLM_DEPLOY="litellm-proxy"
LITELLM_DIR="${AGENT_CHARTS_ROOT:-}/litellm"
SERVER_NS="litmus-chaos"
SERVER_DEPLOY="litmusportal-server"

if ! command -v kubectl >/dev/null 2>&1; then
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

    # Sync master key + model into litmusportal-server if it is running
    if kubectl get deployment "${SERVER_DEPLOY}" -n "${SERVER_NS}" >/dev/null 2>&1; then
        OPENAI_BASE_URL="$(env_val OPENAI_BASE_URL http://litellm-proxy.litellm.svc.cluster.local:4000/v1)"
        kubectl set env deployment/"${SERVER_DEPLOY}" -n "${SERVER_NS}" \
            LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY}" \
            OPENAI_API_KEY="${LITELLM_MASTER_KEY}" \
            OPENAI_BASE_URL="${OPENAI_BASE_URL}" \
            MODEL_ALIAS="${AZURE_OPENAI_DEPLOYMENT}" >/dev/null
        ok "litmusportal-server env synced: LITELLM_MASTER_KEY MODEL_ALIAS OPENAI_BASE_URL"
    fi
fi

# ============================================================================
# Step 4: Start Authentication Service
# ============================================================================
status "Starting Authentication Service..."
(cd "$AUTH_DIR" && go run main.go > "$PID_DIR/.auth.log" 2>&1) &
AUTH_PID=$!
echo "$AUTH_PID" > "$PID_DIR/.agentcert-auth.pid"

wait_msg "Waiting for Auth Service on port 3030..."
retries=0
while [ $retries -lt 30 ]; do
    if ss -tlnp 2>/dev/null | grep -q ":3030 " || netstat -tlnp 2>/dev/null | grep -q ":3030 "; then
        ok "Authentication Service ready (PID: $AUTH_PID)"; break
    fi
    retries=$((retries + 1)); sleep 1
done
if [ $retries -eq 30 ]; then
    fail "Authentication Service did not start. Check $PID_DIR/.auth.log"; exit 1
fi

# ============================================================================
# Step 5: Start GraphQL Server
# ============================================================================
status "Starting GraphQL Server..."
status "Tidying GraphQL dependencies..."
(cd "$GQL_DIR" && go mod tidy)
ok "GraphQL dependencies ready"

GQL_APP_NAME="agentcert-graph"
GQL_BINARY="$GQL_DIR/$GQL_APP_NAME"
status "Building GraphQL binary..."
(cd "$GQL_DIR" && go build -o "$GQL_APP_NAME" .)
ok "GraphQL binary built"

pkill -f "$GQL_APP_NAME" 2>/dev/null || true

(cd "$GQL_DIR" && nohup env \
  REST_PORT="$GQL_REST_PORT" \
  GRPC_PORT="$GQL_GRPC_PORT" \
  OTEL_EXPORTER_OTLP_ENDPOINT="$OTEL_EXPORTER_OTLP_ENDPOINT" \
  OTEL_EXPORTER_OTLP_HEADERS="$OTEL_EXPORTER_OTLP_HEADERS" \
  "$GQL_BINARY" >> "$PID_DIR/.graphql.log" 2>&1) &
GQL_PID=$!
echo "$GQL_PID" > "$PID_DIR/.agentcert-graphql.pid"

wait_msg "Waiting for GraphQL Server on port 8080..."
retries=0
while [ $retries -lt 30 ]; do
    if ss -tlnp 2>/dev/null | grep -q ":8080 " || netstat -tlnp 2>/dev/null | grep -q ":8080 "; then
        ok "GraphQL Server ready (PID: $GQL_PID)"; break
    fi
    retries=$((retries + 1)); sleep 1
done
if [ $retries -eq 30 ]; then
    fail "GraphQL Server did not start. Check $PID_DIR/.graphql.log"
    kill "$AUTH_PID" 2>/dev/null || true; exit 1
fi

# ============================================================================
# Step 6: Start Frontend (optional)
# ============================================================================
if [ "$SKIP_FRONTEND" = false ]; then
    status "Starting Frontend..."
    if [ ! -f "$WEB_DIR/package.json" ]; then
        fail "package.json not found in $WEB_DIR"
    else
        if ! command -v yarn >/dev/null 2>&1; then
            fail "yarn not installed. Run: npm install -g yarn"
            kill "$GQL_PID" 2>/dev/null || true
            kill "$AUTH_PID" 2>/dev/null || true
            exit 1
        fi

        needs_install=false
        [[ ! -d "$WEB_DIR/node_modules" || ! -x "$WEB_DIR/node_modules/.bin/webpack" ]] && needs_install=true

        if [ "$needs_install" = true ]; then
            wait_msg "Installing frontend dependencies..."
            if ! (cd "$WEB_DIR" && yarn install --frozen-lockfile); then
                (cd "$WEB_DIR" && yarn install)
            fi
            ok "Frontend dependencies installed"
        else
            ok "Frontend dependencies already present"
        fi

        cert_count=$(find "$WEB_DIR" -maxdepth 3 -type f \( -name "*.crt" -o -name "*.key" -o -name "*.pem" \) | wc -l | tr -d ' ')
        if (cd "$WEB_DIR" && yarn run 2>/dev/null | grep -q "generate-certificate") && [ "$cert_count" = "0" ]; then
            wait_msg "Generating frontend certificates..."
            (cd "$WEB_DIR" && yarn generate-certificate)
            ok "Frontend certificates generated"
        fi

        (cd "$WEB_DIR" && yarn dev > "$PID_DIR/.frontend.log" 2>&1) &
        FE_PID=$!
        echo "$FE_PID" > "$PID_DIR/.agentcert-frontend.pid"

        wait_msg "Waiting for Frontend on port 2001..."
        retries=0
        while [ $retries -lt 60 ]; do
            if ss -tlnp 2>/dev/null | grep -q ":2001 " || netstat -tlnp 2>/dev/null | grep -q ":2001 "; then
                ok "Frontend ready (PID: $FE_PID)"; break
            fi
            retries=$((retries + 1)); sleep 1
        done
        [ $retries -eq 60 ] && echo -e "\033[33m[WAIT  ]\033[0m Frontend still building. Check $PID_DIR/.frontend.log"
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
echo "  - Auth Service:   localhost:3030 (gRPC) / localhost:3000 (REST)"
echo "  - GraphQL Server: http://localhost:8080"
[ "$SKIP_FRONTEND" = false ] && echo "  - Frontend:       https://localhost:2001"
echo ""
echo "Login: $(env_val ADMIN_USERNAME admin) / $(env_val ADMIN_PASSWORD litmus)"
echo ""
echo "Logs:"
echo "  - Auth:     $PID_DIR/.auth.log"
echo "  - GraphQL:  $PID_DIR/.graphql.log"
[ "$SKIP_FRONTEND" = false ] && echo "  - Frontend: $PID_DIR/.frontend.log"
echo ""
echo -e "\033[33mTo stop: bash ${AGENTCERT_ROOT}/stop-agentcert.sh\033[0m"
echo ""
