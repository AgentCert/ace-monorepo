#!/bin/bash
# ============================================================================
# AgentCert Unified Startup Script (Linux / Azure VM)
# ============================================================================
# This script starts all AgentCert components in the correct order with
# health checks to ensure stability.
#
# Usage:
#   chmod +x start-agentcert.sh
#   ./start-agentcert.sh
#
# Options:
#   --skip-mongo    Skip MongoDB startup
#   --skip-frontend Skip Frontend startup
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_DIR="$SCRIPT_DIR"
SKIP_MONGO=false
SKIP_FRONTEND=false

for arg in "$@"; do
    case "$arg" in
        --skip-mongo)    SKIP_MONGO=true ;;
        --skip-frontend) SKIP_FRONTEND=true ;;
    esac
done

# Colors
status()  { echo -e "\033[36m[STATUS]\033[0m $1"; }
ok()      { echo -e "\033[32m[  OK  ]\033[0m $1"; }
fail()    { echo -e "\033[31m[FAILED]\033[0m $1"; }
wait_msg(){ echo -e "\033[33m[WAIT  ]\033[0m $1"; }

echo ""
echo -e "\033[35m============================================\033[0m"
echo -e "\033[35m       AgentCert Startup Script (Linux)    \033[0m"
echo -e "\033[35m============================================\033[0m"
echo ""

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
            if [ -n "$pid" ]; then
                kill -9 "$pid" 2>/dev/null || true
                ok "Killed process on port $port"
            fi
        done
        sleep 2
    else
        fail "Cannot continue with ports in use. Exiting."
        exit 1
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
        ok "MongoDB is running in container: $mongo_container"
        mongo_running=true
    fi

    if [ "$mongo_running" = false ]; then
        wait_msg "Starting MongoDB container..."
        if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qx "m3"; then
            mongo_container="m3"
            docker start "$mongo_container" > /dev/null
            ok "Started existing MongoDB container '$mongo_container'"
        elif docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qx "agentcert-mongo"; then
            mongo_container="agentcert-mongo"
            docker start "$mongo_container" > /dev/null
            ok "Started existing MongoDB container '$mongo_container'"
        else
            mongo_container="agentcert-mongo"
            docker run -d --name "$mongo_container" -p 27017:27017 mongo:4.2 > /dev/null
            ok "Started new MongoDB container '$mongo_container'"
        fi
        mongo_running=true
    fi

    if [ "$mongo_running" = true ]; then
        wait_msg "Waiting for MongoDB to accept connections..."
        retries=0
        while [ $retries -lt 10 ]; do
            if docker exec "$mongo_container" mongosh --quiet --eval "db.adminCommand({ ping: 1 })" > /dev/null 2>&1 || \
               docker exec "$mongo_container" mongo --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
                ok "MongoDB is ready"
                break
            fi
            retries=$((retries + 1))
            sleep 1
        done
        if [ $retries -eq 10 ]; then
            fail "MongoDB did not become ready in time"
            exit 1
        fi
    fi
fi

# ============================================================================
# Step 3: Set environment variables
# ============================================================================
status "Setting environment variables..."

# Common env vars
export VERSION="3.0.0"
# INFRA_DEPLOYMENTS is set below in the MCP server images section
export DB_SERVER="mongodb://localhost:27017"
export JWT_SECRET="litmus-portal@123"
export DB_USER="admin"
export DB_PASSWORD="1234"
export SELF_AGENT="false"
export INFRA_COMPATIBLE_VERSIONS='["3.0.0"]'
export ALLOWED_ORIGINS='^(http://|https://|)((localhost|host\.docker\.internal|host\.minikube\.internal)|100\.78\.[0-9]+\.[0-9]+)(:[0-9]+|)$'
export SKIP_SSL_VERIFY="true"
export ENABLE_GQL_INTROSPECTION="true"
export INFRA_SCOPE="cluster"
export ENABLE_INTERNAL_TLS="false"
export LITMUS_AUTH_GRPC_ENDPOINT="localhost"
export LITMUS_AUTH_GRPC_PORT="3030"
export ADMIN_USERNAME="admin"
export ADMIN_PASSWORD="litmus"
export REST_PORT="3000"
export GRPC_PORT="3030"
export GQL_REST_PORT="8080"
export GQL_GRPC_PORT="8082"

# Chaos Hub settings
export DEFAULT_HUB_GIT_URL="https://github.com/agentcert/chaos-charts"
export DEFAULT_HUB_BRANCH_NAME="master"

# Container images
export SUBSCRIBER_IMAGE="agentcert/litmusportal-subscriber:3.0.0"
export EVENT_TRACKER_IMAGE="litmuschaos/litmusportal-event-tracker:3.0.0"
export ARGO_WORKFLOW_CONTROLLER_IMAGE="litmuschaos/workflow-controller:v3.3.1"
export ARGO_WORKFLOW_EXECUTOR_IMAGE="litmuschaos/argoexec:v3.3.1"
export LITMUS_CHAOS_OPERATOR_IMAGE="litmuschaos/chaos-operator:3.0.0"
export LITMUS_CHAOS_RUNNER_IMAGE="litmuschaos/chaos-runner:3.0.0"
export LITMUS_CHAOS_EXPORTER_IMAGE="litmuschaos/chaos-exporter:3.0.0"
export CONTAINER_RUNTIME_EXECUTOR="k8sapi"
export WORKFLOW_HELPER_IMAGE_VERSION="3.0.0"

# Install-agent image (used by service.go applyInstallAgentTemplateOverrides)
export INSTALL_AGENT_IMAGE="agentcert/agentcert-install-agent:latest"
export INSTALL_AGENT_IMAGE_PULL_POLICY="Always"

# MCP server images (used by infra namespace manifests)
export KUBERNETES_MCP_SERVER_IMAGE="quay.io/containers/kubernetes_mcp_server:latest"
export PROMETHEUS_MCP_SERVER_IMAGE="agentcert/prometheus-mcp-server:latest"
export PROMETHEUS_MCP_URL="http://prometheus.monitoring.svc.cluster.local:9090"

# Infra deployment labels (used for readiness checks on subscriber connect)
export INFRA_DEPLOYMENTS='["app=chaos-exporter", "name=chaos-operator", "app=event-tracker","app=workflow-controller","app=kubernetes-mcp-server","app=prometheus-mcp-server"]'

# Agent/App Hub settings
export DEFAULT_AGENT_HUB_GIT_URL="https://github.com/agentcert/agent-charts"
export DEFAULT_AGENT_HUB_BRANCH_NAME="main"
export DEFAULT_AGENT_HUB_PATH="/tmp/default"
export DEFAULT_APP_HUB_GIT_URL="https://github.com/agentcert/app-charts"
export DEFAULT_APP_HUB_BRANCH_NAME="main"
export DEFAULT_APP_HUB_PATH="/tmp/default"

# OTEL / Langfuse tracing for GraphQL server
# The Go OTEL tracer in otel_tracer.go reads these at startup.
# If OTEL_EXPORTER_OTLP_ENDPOINT is empty, tracing is silently disabled.
export OTEL_EXPORTER_OTLP_ENDPOINT="https://us.cloud.langfuse.com/api/public/otel"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic cGstbGYtYmExMDgxYTktNzg0OS00MjdmLThhMWMtMmEyZWUwNjkwMGMxOnNrLWxmLTcyNjk0YmQ3LTRhNTktNDMwZC1iODcwLTAxODMxMTRjMDJmZQ=="
export LANGFUSE_HOST="https://us.cloud.langfuse.com"
export LANGFUSE_PUBLIC_KEY="pk-lf-ba1081a9-7849-427f-8a1c-2a2ee06900c1"
export LANGFUSE_SECRET_KEY="sk-lf-72694bd7-4a59-430d-b870-0183114c02fe"

# NOTE: CHAOS_CENTER_UI_ENDPOINT is intentionally NOT set here.
# The Go server auto-detects the machine's outbound IP address on the
# subscriber-pod-permanent-fix branch. This is the correct behavior for
# Azure VMs where the subscriber pod needs to reach back to the VM's IP.
# If auto-detect doesn't work for your setup, uncomment and set manually:
# export CHAOS_CENTER_UI_ENDPOINT="http://<YOUR_VM_PRIVATE_IP>:8080"

ok "Environment variables set"

# ============================================================================
# Step 4: Build Go binaries (if needed)
# ============================================================================
AUTH_DIR="$SCRIPT_DIR/chaoscenter/authentication/api"
GQL_DIR="$SCRIPT_DIR/chaoscenter/graphql/server"
WEB_DIR="$SCRIPT_DIR/chaoscenter/web"




# ============================================================================
# Step 5: Start Authentication Service
# ============================================================================
status "Starting Authentication Service..."

(cd "$AUTH_DIR" && go run main.go > "$PID_DIR/.auth.log" 2>&1) &
AUTH_PID=$!
echo "$AUTH_PID" > "$PID_DIR/.agentcert-auth.pid"

wait_msg "Waiting for Auth Service on port 3030..."
retries=0
while [ $retries -lt 30 ]; do
    if ss -tlnp 2>/dev/null | grep -q ":3030 " || netstat -tlnp 2>/dev/null | grep -q ":3030 "; then
        ok "Authentication Service is ready (PID: $AUTH_PID)"
        break
    fi
    retries=$((retries + 1))
    sleep 1
done
if [ $retries -eq 30 ]; then
    fail "Authentication Service did not start in time. Check $PID_DIR/.auth.log"
    exit 1
fi

# ============================================================================
# Step 6: Start GraphQL Server
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

# Stop any previously running daemon by process name.
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
        ok "GraphQL Server is ready (PID: $GQL_PID)"
        break
    fi
    retries=$((retries + 1))
    sleep 1
done
if [ $retries -eq 30 ]; then
    fail "GraphQL Server did not start in time. Check $PID_DIR/.graphql.log"
    kill "$AUTH_PID" 2>/dev/null || true
    exit 1
fi

# ============================================================================
# Step 7: Start Frontend (optional)
# ============================================================================
if [ "$SKIP_FRONTEND" = false ]; then
    status "Starting Frontend..."

    if [ ! -f "$WEB_DIR/package.json" ]; then
        fail "package.json not found in $WEB_DIR"
    else
        status "Preparing Frontend dependencies..."

        if ! command -v yarn >/dev/null 2>&1; then
            fail "yarn is not installed. Please install yarn and re-run."
            kill "$GQL_PID" 2>/dev/null || true
            kill "$AUTH_PID" 2>/dev/null || true
            exit 1
        fi

        needs_install=false
        if [ ! -d "$WEB_DIR/node_modules" ]; then
            needs_install=true
        elif [ ! -x "$WEB_DIR/node_modules/.bin/webpack" ]; then
            needs_install=true
        fi

        if [ "$needs_install" = true ]; then
            wait_msg "Installing frontend dependencies (fresh setup or missing webpack)..."
            if ! (cd "$WEB_DIR" && yarn install --frozen-lockfile); then
                wait_msg "Retrying dependency install without --frozen-lockfile..."
                (cd "$WEB_DIR" && yarn install)
            fi
            ok "Frontend dependencies installed"
        else
            ok "Frontend dependencies already present"
        fi

        has_generate_cert_script=false
        if (cd "$WEB_DIR" && yarn run 2>/dev/null | grep -q "generate-certificate"); then
            has_generate_cert_script=true
        fi

        cert_count=$(find "$WEB_DIR" -maxdepth 3 -type f \( -name "*.crt" -o -name "*.key" -o -name "*.pem" \) | wc -l | tr -d ' ')
        if [ "$has_generate_cert_script" = true ] && [ "$cert_count" = "0" ]; then
            wait_msg "No frontend cert files found; running yarn generate-certificate..."
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
                ok "Frontend is ready (PID: $FE_PID)"
                break
            fi
            retries=$((retries + 1))
            sleep 1
        done
        if [ $retries -eq 60 ]; then
            echo -e "\033[33m         Frontend may still be building. Check $PID_DIR/.frontend.log\033[0m"
        fi
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo -e "\033[32m============================================\033[0m"
echo -e "\033[32m       AgentCert Started Successfully!     \033[0m"
echo -e "\033[32m============================================\033[0m"
echo ""
echo "Services:"
echo "  - MongoDB:        localhost:27017"
echo "  - Auth Service:   localhost:3030 (gRPC) / localhost:3000 (REST)"
echo "  - GraphQL Server: http://localhost:8080"
if [ "$SKIP_FRONTEND" = false ]; then
echo "  - Frontend:       https://localhost:2001"
fi
echo ""
echo "Default Credentials:"
echo "  - Username: admin"
echo "  - Password: litmus"
echo ""
echo "Logs:"
echo "  - Auth:    $PID_DIR/.auth.log"
echo "  - GraphQL: $PID_DIR/.graphql.log"
if [ "$SKIP_FRONTEND" = false ]; then
echo "  - Frontend: $PID_DIR/.frontend.log"
fi
echo ""
echo -e "\033[33mTo stop all services, run: ./stop-agentcert.sh\033[0m"
echo ""