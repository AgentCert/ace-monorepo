#!/usr/bin/env bash
# =============================================================================
# Ownership-checked wrapper around `docker compose` for the root
# docker-compose.yml one-command bring-up.
#
# docker-compose.yml's project name and every container_name are suffixed
# with ACE_INSTANCE_NAME so two checkouts of this monorepo on the same
# shared host don't collide by default (see CLAUDE.md section 0). But
# Compose itself has no hook to refuse an action against a container it
# didn't create -- it matches "its" containers purely by the
# com.docker.compose.project label, not by working directory. This wrapper
# is the missing check: before handing off to `docker compose`, it inspects
# every container name this stack's docker-compose.yml (+ its `include`s)
# would create or touch, and refuses to proceed if any of them already
# exists under a DIFFERENT checkout's working directory -- e.g. because two
# checkouts happen to share the same ACE_INSTANCE_NAME, or because
# ACE_INSTANCE_NAME was never configured (both fall back to the same
# "unconfigured" suffix).
#
# This is the same incident CLAUDE.md section 0 describes for the old
# start-local-services.sh flow (assert_not_foreign_container there), just
# for the newer one-command `docker compose up` flow.
#
# Usage: identical to `docker compose`, e.g.:
#   ./scripts/compose-up-guard.sh up -d
#   ./scripts/compose-up-guard.sh down
#   ./scripts/compose-up-guard.sh logs -f graphql
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
err()  { echo -e "${RED}[compose-guard]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[compose-guard]${NC} $*"; }

command -v docker >/dev/null 2>&1 || { err "docker not found"; exit 1; }

# Every container_name docker-compose.yml (+ its `include`s) can create,
# resolved through Compose's own config/interpolation so this list can never
# drift out of sync with the compose file itself.
mapfile -t CONTAINER_NAMES < <(
    cd "${REPO_ROOT}" && docker compose config 2>/dev/null \
        | python3 -c "
import sys, yaml
cfg = yaml.safe_load(sys.stdin) or {}
for svc in (cfg.get('services') or {}).values():
    name = svc.get('container_name')
    if name:
        print(name)
" 2>/dev/null
)

if [[ "${#CONTAINER_NAMES[@]}" -eq 0 ]]; then
    warn "Could not resolve container names via 'docker compose config' -- skipping the ownership preflight."
    warn "(docker compose will still run below and surface any real error itself.)"
fi

foreign_found=false
for name in "${CONTAINER_NAMES[@]}"; do
    docker inspect "${name}" >/dev/null 2>&1 || continue   # doesn't exist -- nothing to check
    owner="$(docker inspect "${name}" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)"
    if [[ -n "${owner}" && "${owner}" != "${REPO_ROOT}" ]]; then
        err "Container '${name}' already exists but belongs to a DIFFERENT checkout (working_dir: ${owner}, ours: ${REPO_ROOT})."
        err "Refusing to proceed -- this is exactly the collision that has previously deleted another checkout's containers."
        err "Set a unique ACE_INSTANCE_NAME in .env for this checkout, then re-run."
        foreign_found=true
    fi
done

if [[ "${foreign_found}" == true ]]; then
    exit 1
fi

exec docker compose "$@"
