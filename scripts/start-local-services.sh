#!/bin/bash
set -uo pipefail

# =============================================================================
# Start local supporting services: MongoDB, Langfuse, LiteLLM, Certifier
# =============================================================================
# Idempotent — each service is only started if it isn't already running.
# Pulls env vars from <repo-root>/.env via `docker compose --env-file`.
#
# Usage:
#   ./scripts/start-local-services.sh [options]
#
# Options:
#   --skip-mongo                  Skip MongoDB
#   --skip-langfuse               Skip Langfuse
#   --skip-litellm                Skip LiteLLM
#   --skip-certifier              Skip Certifier
#   --skip-ollama                 Skip Ollama
#   --only-mongo                  Run only MongoDB
#   --only-langfuse               Run only Langfuse
#   --only-litellm                Run only LiteLLM
#   --only-certifier              Run only Certifier
#   --only-ollama                 Run only Ollama
#   --pull-certifier              Pull the certifier image from a registry
#                                 instead of building from source. Default tag:
#                                 agentcert/certifier:latest. Override the tag
#                                 with CERTIFIER_IMAGE in your .env.
#   --env-file PATH               .env to feed services (default: <repo-root>/.env)
#   --langfuse-dir PATH           Langfuse compose dir (default: /opt/langfuse,
#                                 then ~/langfuse, then <repo-root>/.tmp/langfuse)
#   --restart                     Recreate services even if already running
#   -h, --help                    Show this help
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${REPO_ROOT}/.env"
LANGFUSE_DIR=""
RUN_MONGO=true
RUN_LANGFUSE=true
RUN_LITELLM=true
RUN_CERTIFIER=true
RUN_OLLAMA=true
RESTART=false
PULL_CERTIFIER=false
CERTIFIER_PULL_IMAGE_DEFAULT="agentcert/certifier:latest"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

usage() { awk '/^# ====/{c++; next} c>0 && c<3 {sub(/^# ?/,""); print}' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-mongo)     RUN_MONGO=false; shift ;;
        --skip-langfuse)  RUN_LANGFUSE=false; shift ;;
        --skip-litellm)   RUN_LITELLM=false; shift ;;
        --skip-certifier) RUN_CERTIFIER=false; shift ;;
        --skip-ollama)    RUN_OLLAMA=false; shift ;;
        --only-mongo)     RUN_MONGO=true;  RUN_LANGFUSE=false; RUN_LITELLM=false; RUN_CERTIFIER=false; RUN_OLLAMA=false; shift ;;
        --only-langfuse)  RUN_MONGO=false; RUN_LANGFUSE=true;  RUN_LITELLM=false; RUN_CERTIFIER=false; RUN_OLLAMA=false; shift ;;
        --only-litellm)   RUN_MONGO=false; RUN_LANGFUSE=false; RUN_LITELLM=true;  RUN_CERTIFIER=false; RUN_OLLAMA=false; shift ;;
        --only-certifier) RUN_MONGO=false; RUN_LANGFUSE=false; RUN_LITELLM=false; RUN_CERTIFIER=true;  RUN_OLLAMA=false; shift ;;
        --only-ollama)    RUN_MONGO=false; RUN_LANGFUSE=false; RUN_LITELLM=false; RUN_CERTIFIER=false; RUN_OLLAMA=true;  shift ;;
        --pull-certifier) PULL_CERTIFIER=true; shift ;;
        --env-file)       ENV_FILE="${2:-}"; shift 2 ;;
        --langfuse-dir)   LANGFUSE_DIR="${2:-}"; shift 2 ;;
        --restart)        RESTART=true; shift ;;
        -h|--help)        usage ;;
        *)                log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

command -v docker >/dev/null 2>&1 || { log_error "docker not found"; exit 1; }
docker compose version >/dev/null 2>&1 || { log_error "'docker compose' plugin not available"; exit 1; }

port_in_use() { ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${1}$"; }
container_running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }
container_exists()  { docker ps -a --format '{{.Names}}' | grep -qx "$1"; }

# Safety net on top of ACE_INSTANCE_NAME-scoped naming (belt-and-suspenders,
# not a substitute for it): before this script creates/recreates/adopts a
# container by name, refuse if a container by that name already exists AND
# was created from a DIFFERENT checkout's working directory. This is the
# guard that would have prevented the incident where a compose `up` with an
# unset COMPOSE_PROJECT_NAME matched another checkout's already-running
# litellm-proxy/certifier_app purely by (accidentally shared) project label
# and silently deleted it as a "stale" version of its own service. Every
# start_*() below must call this before docker run/docker compose up.
assert_not_foreign_container() {
    local name="$1"
    docker inspect "${name}" >/dev/null 2>&1 || return 0   # doesn't exist yet -- nothing to check
    local their_dir
    their_dir="$(docker inspect "${name}" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)"
    # Raw `docker run` containers (mongo) carry no compose working_dir label
    # at all -- ownership there is asserted purely by ACE_INSTANCE_NAME being
    # baked into the name itself, so an empty label is expected and fine.
    # These three are the only working directories THIS script ever invokes
    # `docker compose` from (litellm-setup submodule, certifier submodule,
    # and the disposable langfuse clone) -- keep in sync if a new service is
    # added below.
    if [[ -n "${their_dir}" \
        && "${their_dir}" != "${REPO_ROOT}" \
        && "${their_dir}" != "${CERTIFIER_DIR:-}" \
        && "${their_dir}" != "${REPO_ROOT}/agentcert-stack/litellm-setup" \
        && "${their_dir}" != "${REPO_ROOT}/.tmp/langfuse" ]]; then
        log_error "Container '${name}' already exists but belongs to a DIFFERENT checkout (working_dir: ${their_dir}, ours: ${REPO_ROOT}). Refusing to touch it -- this is exactly the collision that previously deleted another checkout's containers. Pick a different ACE_INSTANCE_NAME in .env if this is unexpected."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# MongoDB (replSet rs0 + keyFile + root auth admin/1234)
# AgentCert's DB_SERVER (.env) requires `?replicaSet=rs0&authSource=admin`,
# so the local mongo must be started as a single-node replica set with auth.
# ---------------------------------------------------------------------------
# Suffix distinguishing this checkout's containers from any other ACE
# checkout's on the same host — container names (unlike ports) are host-wide
# unique, so without this, container_running()/container_exists() below would
# match another checkout's already-running containers by name and silently
# adopt them instead of starting our own. Override via ACE_INSTANCE_NAME in
# .env; defaults to the current user login.
ACE_INSTANCE_NAME="$(grep -m1 '^ACE_INSTANCE_NAME=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)"
ACE_INSTANCE_NAME="${ACE_INSTANCE_NAME:-$(id -un | tr '[:upper:].' '[:lower:]-')}"

OLLAMA_IMAGE="ollama/ollama:latest"
OLLAMA_NAME="ollama-${ACE_INSTANCE_NAME}"
OLLAMA_MODELS_VOL="ollama-models-${ACE_INSTANCE_NAME}"
# Host port for this checkout's Ollama container. Must not collide with the
# system Ollama on :11434 or another checkout's Ollama. setup.sh auto-derives
# a UID-based value; the fallback 11435 is used only when .env is absent.
OLLAMA_PORT="$(grep -m1 '^OLLAMA_PORT=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)"
OLLAMA_PORT="${OLLAMA_PORT:-11435}"
OLLAMA_MODEL="$(grep -m1 '^OLLAMA_MODEL=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)"

MONGO_IMAGE="mongo:5"
MONGO_NAME="agentcert-mongo-${ACE_INSTANCE_NAME}"
MONGO_DATA_VOL="mongodb_data_${ACE_INSTANCE_NAME}"
MONGO_KEYFILE_VOL="mongo-keyfile-vol-${ACE_INSTANCE_NAME}"
MONGO_ROOT_USER="admin"
MONGO_ROOT_PASS="1234"
# Host port for this checkout's mongo. Parameterized (not just a default) so
# multiple independent checkouts on one host can each own a mongo without
# port_in_use() below mistaking someone else's mongo on :27017 for "ours".
MONGO_PORT="$(grep -m1 '^MONGO_PORT=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)"
MONGO_PORT="${MONGO_PORT:-27017}"

ensure_mongo_keyfile_vol() {
    if docker volume inspect "${MONGO_KEYFILE_VOL}" >/dev/null 2>&1; then
        return 0
    fi
    log_info "Creating mongo keyfile volume '${MONGO_KEYFILE_VOL}' ..."
    docker volume create "${MONGO_KEYFILE_VOL}" >/dev/null
    local tmp_key
    tmp_key="$(mktemp)"
    openssl rand -base64 756 > "${tmp_key}"
    docker run --rm \
        -v "${tmp_key}:/tmp/src-keyfile:ro" \
        -v "${MONGO_KEYFILE_VOL}:/keydata" \
        "${MONGO_IMAGE}" bash -c \
        'cp /tmp/src-keyfile /keydata/keyfile && chown 999:999 /keydata/keyfile && chmod 400 /keydata/keyfile' \
        >/dev/null
    rm -f "${tmp_key}"
}

mongo_rs_initialized() {
    docker exec "${MONGO_NAME}" mongosh --quiet \
        -u "${MONGO_ROOT_USER}" -p "${MONGO_ROOT_PASS}" --authenticationDatabase admin \
        --eval 'try { rs.status().ok } catch(e) { 0 }' 2>/dev/null | tail -1 | grep -qx '1'
}

start_mongo() {
    assert_not_foreign_container "${MONGO_NAME}" || return 1
    log_info "MongoDB: checking port ${MONGO_PORT} ..."
    if port_in_use "${MONGO_PORT}"; then
        local existing
        existing=$(docker ps --filter "publish=${MONGO_PORT}" --format "{{.Names}}" | head -1)
        if [[ "${RESTART}" == true && -n "${existing}" ]]; then
            log_warn "Restarting MongoDB container '${existing}' ..."
            docker restart "${existing}" >/dev/null
        elif [[ "${existing}" == "${MONGO_NAME}" ]] && ! mongo_rs_initialized; then
            # Container is ours and running, but a prior rs.initiate never
            # succeeded (e.g. an earlier failed attempt left it up but
            # unconfigured) -- fall through to the init logic below instead
            # of reporting a false "already up".
            log_warn "MongoDB container '${existing}' is up but replSet rs0 isn't initialized yet — finishing setup ..."
        else
            log_success "MongoDB already up (${existing:-external listener on :${MONGO_PORT}})"
            return 0
        fi
    fi

    ensure_mongo_keyfile_vol

    if container_exists "${MONGO_NAME}"; then
        log_info "Starting existing container '${MONGO_NAME}' ..."
        docker start "${MONGO_NAME}" >/dev/null
    else
        log_info "Creating new container '${MONGO_NAME}' (${MONGO_IMAGE}, replSet rs0, keyFile, auth) ..."
        docker run -d --name "${MONGO_NAME}" -p "${MONGO_PORT}:27017" \
            -e MONGO_INITDB_ROOT_USERNAME="${MONGO_ROOT_USER}" \
            -e MONGO_INITDB_ROOT_PASSWORD="${MONGO_ROOT_PASS}" \
            -v "${MONGO_DATA_VOL}:/data/db" \
            -v "${MONGO_KEYFILE_VOL}:/keydata:ro" \
            "${MONGO_IMAGE}" mongod --replSet rs0 --bind_ip_all --keyFile /keydata/keyfile \
            >/dev/null
    fi

    log_info "Waiting for mongod to accept auth ..."
    local retries=0
    while (( retries < 30 )); do
        if docker exec "${MONGO_NAME}" mongosh --quiet \
            -u "${MONGO_ROOT_USER}" -p "${MONGO_ROOT_PASS}" --authenticationDatabase admin \
            --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1; then
            break
        fi
        sleep 1; ((retries++))
    done
    if (( retries == 30 )); then
        log_error "MongoDB did not accept auth within 30s"
        return 1
    fi

    if mongo_rs_initialized; then
        log_success "MongoDB ready on :${MONGO_PORT} (replSet rs0 already initialized)"
        return 0
    fi

    log_info "Initializing replica set rs0 ..."
    # NOTE: this host string must stay "localhost:27017" (the container's own
    # internal port) regardless of MONGO_PORT -- rs.initiate()'s self-check
    # validates the given host against the socket the current connection came
    # in on, which from inside the container (docker exec) is always the
    # container-internal 27017, never the external MONGO_PORT mapping.
    # External/host-side clients must use directConnection=true (bypassing
    # replica-set topology discovery) rather than relying on this label.
    if ! docker exec "${MONGO_NAME}" mongosh --quiet \
        -u "${MONGO_ROOT_USER}" -p "${MONGO_ROOT_PASS}" --authenticationDatabase admin \
        --eval 'rs.initiate({_id:"rs0",members:[{_id:0,host:"localhost:27017"}]})' >/dev/null 2>&1; then
        log_error "rs.initiate failed"
        return 1
    fi
    retries=0
    while (( retries < 30 )); do
        if mongo_rs_initialized; then
            log_success "MongoDB ready on :${MONGO_PORT} (replSet rs0 initialized)"
            return 0
        fi
        sleep 1; ((retries++))
    done
    log_error "Replica set did not become healthy within 30s"
    return 1
}

# ---------------------------------------------------------------------------
# Langfuse
# ---------------------------------------------------------------------------
resolve_langfuse_dir() {
    if [[ -n "${LANGFUSE_DIR}" ]]; then
        [[ -f "${LANGFUSE_DIR}/docker-compose.yml" ]] && return 0
        log_error "No docker-compose.yml in --langfuse-dir: ${LANGFUSE_DIR}"
        return 1
    fi
    for cand in /opt/langfuse "${HOME}/langfuse" "${REPO_ROOT}/.tmp/langfuse"; do
        if [[ -f "${cand}/docker-compose.yml" ]]; then
            LANGFUSE_DIR="${cand}"; return 0
        fi
    done
    return 1
}

start_langfuse() {
    log_info "Langfuse: checking ..."
    local langfuse_port
    langfuse_port="$(grep -m1 '^LANGFUSE_PORT=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)"
    langfuse_port="${langfuse_port:-4000}"

    # See ACE_INSTANCE_NAME comment in the mongo section above: the upstream
    # langfuse repo's docker-compose.yml service name is "langfuse-web", so
    # compose's default project name (its checkout dir's basename, e.g.
    # "langfuse") produces "langfuse-langfuse-web-1" — identical across any
    # two checkouts that clone into a dir with that same basename. Force a
    # project name unique to this checkout so we never mistake another
    # checkout's Langfuse for our own (or vice versa). NOT exported globally
    # (that leaked into start_litellm's compose project in a prior version of
    # this script) -- only passed inline to the docker compose calls below.
    local langfuse_project="ace-langfuse-${ACE_INSTANCE_NAME}"
    local langfuse_web_container="${langfuse_project}-langfuse-web-1"
    assert_not_foreign_container "${langfuse_web_container}" || return 1

    if container_running "${langfuse_web_container}" && [[ "${RESTART}" == false ]]; then
        log_success "Langfuse already up (web: http://localhost:${langfuse_port})"
        return 0
    fi

    # Deliberately NOT using resolve_langfuse_dir()'s shared /opt/langfuse or
    # ~/langfuse lookup here: this checkout wants its own independent
    # Langfuse, and a shared checkout may be unpatched (hardcoded ports that
    # collide with whatever else is using it) or owned by another user.
    # Always use (and if needed clone into) our own .tmp/langfuse.
    LANGFUSE_DIR="${REPO_ROOT}/.tmp/langfuse"
    if [[ ! -f "${LANGFUSE_DIR}/docker-compose.yml" ]]; then
        log_warn "No Langfuse checkout found — cloning upstream into ${LANGFUSE_DIR} ..."
        mkdir -p "$(dirname "${LANGFUSE_DIR}")"
        if ! git clone --depth 1 https://github.com/langfuse/langfuse.git "${LANGFUSE_DIR}"; then
            log_error "git clone of langfuse failed"
            return 1
        fi
    fi

    log_info "Starting Langfuse compose stack from ${LANGFUSE_DIR} ..."
    # --env-file is required here (matching start_litellm/certifier below) --
    # without it, `docker compose up -d` only reads a .env from its own CWD
    # (${LANGFUSE_DIR}/.env, which doesn't exist), so LANGFUSE_INIT_ORG_ID /
    # LANGFUSE_INIT_PROJECT_PUBLIC_KEY / LANGFUSE_INIT_PROJECT_SECRET_KEY /
    # etc. from the repo-root .env silently never reach the container --
    # Langfuse still boots and seeds the admin USER, but auto-creates no
    # org/project, so the API keys configured elsewhere (LANGFUSE_PUBLIC_KEY/
    # LANGFUSE_SECRET_KEY, used by flash-agent and LiteLLM's langfuse
    # callback) don't correspond to anything and every trace write fails
    # with "Invalid credentials" -- silently, since it's a background
    # callback, not a request-blocking error.
    # -f compose/langfuse.override.yml: parameterizes the two hardcoded ports
    # in the pristine upstream clone (see that file's header for why this
    # can't just be a hand-edit to LANGFUSE_DIR).
    if [[ -f "${ENV_FILE}" ]]; then
        if ! (cd "${LANGFUSE_DIR}" && COMPOSE_PROJECT_NAME="${langfuse_project}" docker compose --env-file "${ENV_FILE}" -f docker-compose.yml -f "${REPO_ROOT}/compose/langfuse.override.yml" up -d); then
            log_error "Langfuse compose up failed"
            return 1
        fi
    else
        log_warn "No env file at ${ENV_FILE} -- starting Langfuse without LANGFUSE_INIT_* vars (no org/project will be auto-created)"
        if ! (cd "${LANGFUSE_DIR}" && COMPOSE_PROJECT_NAME="${langfuse_project}" docker compose -f docker-compose.yml -f "${REPO_ROOT}/compose/langfuse.override.yml" up -d); then
            log_error "Langfuse compose up failed"
            return 1
        fi
    fi
    log_success "Langfuse up. Web UI: http://localhost:${langfuse_port}"
}

# ---------------------------------------------------------------------------
# LiteLLM
# ---------------------------------------------------------------------------
start_litellm() {
    log_info "LiteLLM: checking ..."
    local compose_dir="${REPO_ROOT}/agentcert-stack/litellm-setup"
    local compose_file="${compose_dir}/docker-compose-litellm.yml"

    if [[ ! -f "${compose_file}" ]]; then
        log_error "Compose file not found: ${compose_file}"
        return 1
    fi
    if [[ ! -f "${ENV_FILE}" ]]; then
        log_error "LiteLLM needs an env file (got: ${ENV_FILE}) for AZURE_OPENAI_*, LANGFUSE_*, etc."
        return 1
    fi

    local litellm_port
    litellm_port="$(grep -m1 '^LITELLM_PORT=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)"
    litellm_port="${litellm_port:-14000}"

    # See ACE_INSTANCE_NAME comment above: container_name is host-wide unique,
    # so this must not collide with another checkout's litellm-proxy.
    export LITELLM_CONTAINER_NAME="litellm-proxy-${ACE_INSTANCE_NAME}"
    assert_not_foreign_container "${LITELLM_CONTAINER_NAME}" || return 1

    if container_running "${LITELLM_CONTAINER_NAME}" && [[ "${RESTART}" == false ]]; then
        log_success "LiteLLM already up (proxy: http://localhost:${litellm_port})"
        return 0
    fi

    log_info "Starting LiteLLM proxy with env-file ${ENV_FILE} ..."
    # -f compose/litellm.override.yml: parameterizes container_name/port that
    # the agentcert-stack submodule's own compose file hardcodes (see that
    # file's header for why this can't just be a hand-edit to the submodule).
    #
    # COMPOSE_PROJECT_NAME is NOT optional here. Without it, Compose derives
    # the project name from this directory's basename ("litellm-setup") --
    # and ANY other ACE checkout on this host has a submodule directory with
    # that exact same basename. Compose identifies "its" containers purely by
    # the com.docker.compose.project label, not by working directory, so two
    # checkouts sharing an implicit project name will each treat the other's
    # container as a stale instance of their own service and DELETE it on
    # `up` (this happened once already -- see git blame / incident notes).
    # Every docker compose invocation in this script must set this.
    if ! (cd "${compose_dir}" && COMPOSE_PROJECT_NAME="ace-litellm-${ACE_INSTANCE_NAME}" docker compose --env-file "${ENV_FILE}" -f docker-compose-litellm.yml -f "${REPO_ROOT}/compose/litellm.override.yml" up -d); then
        log_error "LiteLLM compose up failed"
        return 1
    fi
    log_success "LiteLLM up. Proxy: http://localhost:${litellm_port}"
}

# ---------------------------------------------------------------------------
# Certifier (FastAPI app on :${API_PORT:-8000})
#
# Talks to the shared monorepo MongoDB (admin:1234, replSet rs0) — we do NOT
# start the certifier compose's own `mongo` / `mongo-express` services, since
# the script's `start_mongo` already provides a single-source mongo for the
# whole monorepo.
# ---------------------------------------------------------------------------
CERTIFIER_DIR="${REPO_ROOT}/certifier"
CERTIFIER_APP_CONTAINER="certifier_app-${ACE_INSTANCE_NAME}"

# Resolve the certifier image tag in this priority order:
#   1. --pull-certifier flag → use CERTIFIER_PULL_IMAGE_DEFAULT (overridable via
#      CERTIFIER_IMAGE in .env)
#   2. CERTIFIER_IMAGE set in the .env / environment
#   3. Default local-build tag `certifier:latest`
_resolve_certifier_image() {
    local env_image
    env_image="$(grep -m1 '^CERTIFIER_IMAGE=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)"
    if [[ "${PULL_CERTIFIER}" == true ]]; then
        echo "${env_image:-${CERTIFIER_PULL_IMAGE_DEFAULT}}"
    elif [[ -n "${env_image}" ]]; then
        echo "${env_image}"
    else
        echo "certifier:latest"
    fi
}

start_certifier() {
    log_info "Certifier: checking ..."
    assert_not_foreign_container "${CERTIFIER_APP_CONTAINER}" || return 1

    if [[ ! -f "${CERTIFIER_DIR}/docker-compose.yml" ]]; then
        log_error "Compose file not found: ${CERTIFIER_DIR}/docker-compose.yml"
        return 1
    fi
    if [[ ! -f "${ENV_FILE}" ]]; then
        log_error "Certifier needs an env file (got: ${ENV_FILE}) for AZURE_OPENAI_*, LANGFUSE_*, etc."
        return 1
    fi

    # Implicit dependency: the certifier app crashes on boot if mongo isn't
    # reachable (FastAPI lifespan creates indices). Start the shared monorepo
    # mongo first if it isn't already up. This mirrors `depends_on` semantics
    # for compose stacks that live in different directories.
    if ! container_running "${MONGO_NAME}"; then
        log_info "Certifier requires MongoDB — starting it first ..."
        if ! start_mongo; then
            log_error "MongoDB failed to start; aborting Certifier"
            return 1
        fi
    fi

    local certifier_image
    certifier_image="$(_resolve_certifier_image)"
    # Export so compose's `image: ${CERTIFIER_IMAGE:-...}` resolves to the same value
    export CERTIFIER_IMAGE="${certifier_image}"
    # See ACE_INSTANCE_NAME comment above: container_name is host-wide unique,
    # so this must not collide with another checkout's certifier_app.
    export CERTIFIER_CONTAINER_NAME="${CERTIFIER_APP_CONTAINER}"

    if container_running "${CERTIFIER_APP_CONTAINER}" && [[ "${RESTART}" == false ]]; then
        log_success "Certifier already up (http://localhost:${API_PORT:-8000}/docs)"
        return 0
    fi

    # Acquire the image: pull from registry if --pull-certifier OR if the image
    # tag looks like a registry path and isn't local yet; otherwise build.
    if [[ "${PULL_CERTIFIER}" == true ]]; then
        log_info "Pulling certifier image: ${certifier_image} ..."
        if ! docker pull "${certifier_image}"; then
            log_error "Failed to pull '${certifier_image}'. Check the tag and your registry access."
            return 1
        fi
    elif ! docker image inspect "${certifier_image}" >/dev/null 2>&1; then
        log_info "Image '${certifier_image}' not found locally — building from ${CERTIFIER_DIR} ..."
        if ! (cd "${CERTIFIER_DIR}" && COMPOSE_PROJECT_NAME="ace-certifier-${ACE_INSTANCE_NAME}" docker compose --env-file "${ENV_FILE}" build app); then
            log_error "Certifier image build failed"
            return 1
        fi
    fi

    # Point the app at the script-managed mongo (auth + replSet on the host).
    # `host.docker.internal:host-gateway` is wired into compose's `extra_hosts`,
    # so the container can resolve the host network from inside its bridge.
    #
    # `directConnection=true` is required because the replica set was initialised
    # with `host: "localhost:27017"` (always 27017 — the container's own
    # internal port, regardless of MONGO_PORT; see the rs.initiate comment in
    # start_mongo() above) — from inside this container, that label resolves
    # to this container's own loopback (no mongo there), and even from the
    # host it wouldn't reliably mean "this checkout's mongo" once MONGO_PORT
    # differs from 27017. Direct-connect bypasses replica-set topology
    # discovery and uses the seed host:port (MONGO_PORT below) as-is.
    local mongo_user="${MONGO_ROOT_USER:-admin}"
    local mongo_pass="${MONGO_ROOT_PASS:-1234}"
    local mongo_db="${MONGODB_DATABASE:-agentcert}"
    export CERTIFIER_MONGODB_URI="mongodb://${mongo_user}:${mongo_pass}@host.docker.internal:${MONGO_PORT}/${mongo_db}?authSource=admin&directConnection=true"

    local up_args=(--no-deps app)
    [[ "${RESTART}" == true ]] && up_args=(--force-recreate --no-deps app)

    log_info "Starting Certifier (app only; uses shared monorepo mongo) ..."
    # -f compose/certifier.override.yml: parameterizes container_name that the
    # certifier submodule's own compose file hardcodes (see that file's
    # header for why this can't just be a hand-edit to the submodule).
    #
    # COMPOSE_PROJECT_NAME is NOT optional here. Without it, Compose derives
    # the project name from this directory's basename ("certifier") -- and
    # ANY other ACE checkout on this host has a submodule directory with that
    # exact same basename. Compose identifies "its" containers purely by the
    # com.docker.compose.project label, not by working directory, so two
    # checkouts sharing an implicit project name will each treat the other's
    # container as a stale instance of their own service and DELETE it on
    # `up` (this happened once already -- see git blame / incident notes).
    # Every docker compose invocation in this script must set this.
    if ! (cd "${CERTIFIER_DIR}" && COMPOSE_PROJECT_NAME="ace-certifier-${ACE_INSTANCE_NAME}" docker compose --env-file "${ENV_FILE}" -f docker-compose.yml -f "${REPO_ROOT}/compose/certifier.override.yml" up -d "${up_args[@]}"); then
        log_error "Certifier compose up failed"
        return 1
    fi

    # Wait for /docs to respond — covers app boot + lifespan handler
    local retries=0
    while (( retries < 30 )); do
        if curl -fsS -o /dev/null "http://localhost:${API_PORT:-8000}/docs" 2>/dev/null; then
            log_success "Certifier up. Swagger UI: http://localhost:${API_PORT:-8000}/docs"
            return 0
        fi
        sleep 2; ((retries++))
    done
    log_error "Certifier did not start responding within 60s on :${API_PORT:-8000}/docs"
    return 1
}

# ---------------------------------------------------------------------------
# Ollama inference server
#
# Runs as a plain `docker run` container (not compose) — same pattern as
# MongoDB above — so ownership is asserted purely by ACE_INSTANCE_NAME in the
# container name; no compose working_dir label is attached.
#
# Each ACE instance gets its own container (ollama-${ACE_INSTANCE_NAME}) and
# its own named volume (ollama-models-${ACE_INSTANCE_NAME}), completely
# isolated from the shared system Ollama on :11434 and from other checkouts.
# ---------------------------------------------------------------------------
start_ollama() {
    assert_not_foreign_container "${OLLAMA_NAME}" || return 1
    log_info "Ollama: checking port ${OLLAMA_PORT} ..."

    if port_in_use "${OLLAMA_PORT}"; then
        local existing
        existing=$(docker ps --filter "publish=${OLLAMA_PORT}" --format "{{.Names}}" | head -1)
        if [[ "${RESTART}" == true && "${existing}" == "${OLLAMA_NAME}" ]]; then
            log_warn "Restarting Ollama container '${existing}' ..."
            docker restart "${existing}" >/dev/null
            log_success "Ollama restarted on :${OLLAMA_PORT}"
            return 0
        elif [[ -n "${existing}" && "${existing}" != "${OLLAMA_NAME}" ]]; then
            log_error "Port ${OLLAMA_PORT} is already in use by a DIFFERENT container ('${existing}'). Set a different OLLAMA_PORT in .env for this checkout."
            return 1
        else
            log_success "Ollama already up (${existing:-external listener on :${OLLAMA_PORT}})"
            return 0
        fi
    fi

    if container_exists "${OLLAMA_NAME}"; then
        log_info "Starting existing Ollama container '${OLLAMA_NAME}' ..."
        docker start "${OLLAMA_NAME}" >/dev/null
    else
        log_info "Creating new Ollama container '${OLLAMA_NAME}' (port :${OLLAMA_PORT}, volume: ${OLLAMA_MODELS_VOL}) ..."
        # --gpus all: requires NVIDIA Container Toolkit (nvidia-container-runtime).
        # The container still starts on CPU if the toolkit is absent, but
        # inference for large models (qwen32b) will be unusably slow.
        if ! docker run -d \
                --name "${OLLAMA_NAME}" \
                --gpus all \
                -p "${OLLAMA_PORT}:11434" \
                -v "${OLLAMA_MODELS_VOL}:/root/.ollama" \
                -e OLLAMA_HOST="0.0.0.0" \
                --restart unless-stopped \
                "${OLLAMA_IMAGE}" >/dev/null 2>&1; then
            log_warn "docker run with --gpus all failed — retrying without GPU (CPU-only mode)"
            docker run -d \
                --name "${OLLAMA_NAME}" \
                -p "${OLLAMA_PORT}:11434" \
                -v "${OLLAMA_MODELS_VOL}:/root/.ollama" \
                -e OLLAMA_HOST="0.0.0.0" \
                --restart unless-stopped \
                "${OLLAMA_IMAGE}" >/dev/null
        fi
    fi

    # Wait for Ollama API to accept connections
    log_info "Waiting for Ollama API on :${OLLAMA_PORT} ..."
    local retries=0
    while (( retries < 20 )); do
        if curl -fsS -o /dev/null "http://localhost:${OLLAMA_PORT}/api/version" 2>/dev/null; then
            break
        fi
        sleep 1; (( retries++ ))
    done
    if (( retries == 20 )); then
        log_error "Ollama did not respond within 20s on :${OLLAMA_PORT}"
        return 1
    fi

    log_success "Ollama up on :${OLLAMA_PORT} (container: ${OLLAMA_NAME}, volume: ${OLLAMA_MODELS_VOL})"

    # Prompt to pull the configured model if it is not already present.
    if [[ -n "${OLLAMA_MODEL}" ]]; then
        local model_tag="${OLLAMA_MODEL%%:*}"  # strip tag for a partial-match check
        if ! docker exec "${OLLAMA_NAME}" ollama list 2>/dev/null | grep -qi "${model_tag}"; then
            log_info "Model '${OLLAMA_MODEL}' not yet in this instance's model store."
            log_info "Pull it with:  docker exec ${OLLAMA_NAME} ollama pull ${OLLAMA_MODEL}"
        else
            log_success "Model '${OLLAMA_MODEL}' already present in ${OLLAMA_MODELS_VOL}."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN}  Local supporting services${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

FAILED=()
run_step() {
    local label="$1"; shift
    if ! "$@"; then FAILED+=("${label}"); fi
    echo ""
}
[[ "${RUN_MONGO}"     == true ]] && run_step mongo     start_mongo
[[ "${RUN_LANGFUSE}"  == true ]] && run_step langfuse  start_langfuse
[[ "${RUN_OLLAMA}"    == true ]] && run_step ollama    start_ollama
[[ "${RUN_LITELLM}"   == true ]] && run_step litellm   start_litellm
[[ "${RUN_CERTIFIER}" == true ]] && run_step certifier start_certifier

echo -e "${CYAN}======================================${NC}"
if (( ${#FAILED[@]} == 0 )); then
    log_success "All requested services are up."
else
    log_warn "Failed: ${FAILED[*]}"
    exit 1
fi
