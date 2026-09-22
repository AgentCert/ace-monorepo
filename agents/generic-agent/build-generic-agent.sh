#!/usr/bin/env bash
# Build the generic-agent image and make it available to the local kind cluster.
#
#   ./build-generic-agent.sh              # build + kind load
#   ./build-generic-agent.sh --push       # build + docker push (no kind load)
#   IMAGE_TAG=v1.0.1 ./build-generic-agent.sh
#
# KIND_CLUSTER defaults to the only kind cluster on the host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

IMAGE_REPO="${IMAGE_REPO:-agentcert/generic-agent}"
IMAGE_TAG="${IMAGE_TAG:-v1.0.0}"
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
PUSH=0
[[ "${1:-}" == "--push" ]] && PUSH=1

echo "==> docker build ${IMAGE}"
docker build -t "${IMAGE}" .

if [[ ${PUSH} -eq 1 ]]; then
    echo "==> docker push ${IMAGE}"
    docker push "${IMAGE}"
    exit 0
fi

KIND_CLUSTER="${KIND_CLUSTER:-$(kind get clusters 2>/dev/null | head -1)}"
if [[ -z "${KIND_CLUSTER}" ]]; then
    echo "!! no kind cluster found; image built locally only" >&2
    exit 0
fi

echo "==> kind load docker-image ${IMAGE} --name ${KIND_CLUSTER}"
kind load docker-image "${IMAGE}" --name "${KIND_CLUSTER}"
echo "==> done: ${IMAGE} available in kind cluster ${KIND_CLUSTER}"
