#!/bin/bash
set -euo pipefail

# build-litellm.sh (azure_build edition)
# -----------------------------------------------------------------------
# LiteLLM uses the PUBLIC upstream image -- no custom Docker build,
# nothing to push to Docker Hub, no cluster changes made here.
#
# This script ONLY writes to .env:
#   LITELLM_PROXY_IMAGE  -- the public image tag to record
#   LITELLM_PROFILE      -- azure | openai | all
#   LITELLM_MASTER_KEY   -- read from .env (or default)
#
# K8s deployment of LiteLLM on the cluster is done once, separately.
# -----------------------------------------------------------------------

ENV_FILE=""
LITELLM_VERSION="v1.82.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)    ENV_FILE="${2:-}"; shift 2 ;;
    --litellm-dir) shift 2 ;;  # accepted but ignored in azure_build
    *) echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${ENV_FILE}" ]]; then
  echo "[ERROR] --env-file is required" >&2; exit 1
fi
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[ERROR] .env not found: ${ENV_FILE}" >&2; exit 1
fi

# Profile selection (non-interactive when LITELLM_PROFILE already exported)
if [ -n "${LITELLM_PROFILE:-}" ]; then
  PROFILE="${LITELLM_PROFILE}"
  echo "[INFO] Using LITELLM_PROFILE=${PROFILE} from environment"
else
  echo ""
  echo "Select LiteLLM provider profile:"
  echo "  1) azure   - Azure OpenAI"
  echo "  2) openai  - OpenAI"
  echo "  3) all     - All providers"
  echo ""
  read -r -p "Enter choice [1/2/3] (default: 1): " PROFILE_CHOICE
  case "${PROFILE_CHOICE:-1}" in
    1|azure)  PROFILE="azure" ;;
    2|openai) PROFILE="openai" ;;
    3|all)    PROFILE="all" ;;
    *) echo "[ERROR] Invalid choice." >&2; exit 1 ;;
  esac
fi

IMAGE="docker.io/litellm/litellm:${LITELLM_VERSION}-stable"
echo "[INFO] Profile: ${PROFILE} | Image: ${IMAGE}"

# Safe .env reader
read_env_value() {
  local key="$1" value
  value=$(grep -E "^${key}=" "${ENV_FILE}" | tail -1 | cut -d= -f2- || true)
  value=$(echo "${value}" | tr -d "\r\n")
  value=${value#'"'}; value=${value%'"'}
  value=${value#"'"}; value=${value%"'"}
  echo "${value}"
}

LITELLM_MASTER_KEY=$(read_env_value "LITELLM_MASTER_KEY")
if [ -z "${LITELLM_MASTER_KEY}" ]; then
  LITELLM_MASTER_KEY="sk-litellm-local-dev"
  echo "[WARN] LITELLM_MASTER_KEY not in .env; using default"
fi

# Write key=value into .env (update if exists, append if not)
upsert() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    printf "\n%s=%s\n" "${key}" "${val}" >> "${ENV_FILE}"
  fi
}

upsert "LITELLM_PROXY_IMAGE" "${IMAGE}"
upsert "LITELLM_PROFILE"     "${PROFILE}"
upsert "LITELLM_MASTER_KEY"  "${LITELLM_MASTER_KEY}"

echo "[OK] .env updated: LITELLM_PROXY_IMAGE=${IMAGE} LITELLM_PROFILE=${PROFILE}"

# ── Push LiteLLM image to Docker Hub ──────────────────────────────────────────
DH_USER=$(read_env_value "DOCKERHUB_USERNAME")
DH_TOKEN=$(read_env_value "DOCKERHUB_TOKEN")
PROXY_IMAGE="agentcert/agentcert-litellm-proxy"

if [[ -z "${DH_USER}" || -z "${DH_TOKEN}" ]]; then
  echo "[WARN] DOCKERHUB_USERNAME or DOCKERHUB_TOKEN not set in .env; skipping push"
else
  echo "[INFO] Pulling upstream image: ${IMAGE}"
  docker pull "${IMAGE}"
  docker tag "${IMAGE}" "${PROXY_IMAGE}:latest"
  echo "${DH_TOKEN}" | docker login -u "${DH_USER}" --password-stdin
  docker push "${PROXY_IMAGE}:latest"
  docker logout >/dev/null 2>&1 || true
  echo "[OK] Pushed ${PROXY_IMAGE}:latest to Docker Hub"
  upsert "LITELLM_PROXY_IMAGE" "${PROXY_IMAGE}:latest"
fi

echo "[DONE] LiteLLM sync complete (no cluster changes made)"
