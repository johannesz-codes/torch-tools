#!/usr/bin/env bash
set -euo pipefail

# Verzeichnis des Scripts selbst
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTORCH_REPO="${PYTORCH_REPO:-$SCRIPT_DIR/../../pytorch}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$SCRIPT_DIR/../../wheelhouse_artifacts}"
DOCKER_IMAGE="${DOCKER_IMAGE:-docker.io/pytorch/manylinux2_28-builder:cuda13.0}"

# === Konfig ===
# entspricht deinem Job
export PYTORCH_ROOT="/pytorch"
export PACKAGE_TYPE="manywheel"
export DESIRED_CUDA="cu130"
export GPU_ARCH_VERSION="13.0"
export GPU_ARCH_TYPE="cuda"
export DESIRED_PYTHON="3.11"
export SKIP_ALL_TESTS="1"
export PYTORCH_EXTRA_INSTALL_REQUIREMENTS="cuda-toolkit[nvrtc,cudart,cupti,cufft,curand,cusolver,cusparse,cublas,cufile,nvjitlink,nvtx]==12.8.1; platform_system == 'Linux' | cuda-bindings==12.9.4; platform_system == 'Linux' | nvidia-cudnn-cu12==9.19.0.56; platform_system == 'Linux' | nvidia-cusparselt-cu12==0.7.1; platform_system == 'Linux' | nvidia-nccl-cu12==2.28.9; platform_system == 'Linux' | nvidia-nvshmem-cu12==3.4.5; platform_system == 'Linux'"

export BINARY_ENV_FILE="/tmp/env"
export BUILD_ENVIRONMENT="linux-binary-manywheel"
export PYTORCH_FINAL_PACKAGE_DIR="/artifacts"

mkdir -p "${ARTIFACTS_DIR}"

echo "Using repo: ${PYTORCH_REPO}"
echo "Artifacts:  ${ARTIFACTS_DIR}"
echo "Image:      ${DOCKER_IMAGE}"

# === Container starten ===
container_name=$(
  docker run \
    -e BINARY_ENV_FILE \
    -e BUILD_ENVIRONMENT \
    -e DESIRED_CUDA \
    -e DESIRED_PYTHON \
    -e GPU_ARCH_TYPE \
    -e GPU_ARCH_VERSION \
    -e PACKAGE_TYPE \
    -e PYTORCH_FINAL_PACKAGE_DIR \
    -e PYTORCH_ROOT \
    -e SKIP_ALL_TESTS \
    -e PYTORCH_EXTRA_INSTALL_REQUIREMENTS \
    --tty \
    --detach \
    -v "${PYTORCH_REPO}:/pytorch" \
    -v "${ARTIFACTS_DIR}:/artifacts" \
    -w / \
    "${DOCKER_IMAGE}"
)

cleanup() {
  echo "Stopping container ${container_name}..."
  docker rm -f "${container_name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Container: ${container_name}"

# === Env erzeugen (wie CI) ===
docker exec -t -w "${PYTORCH_ROOT}" "${container_name}" bash -lc \
  "bash .ci/pytorch/binary_populate_env.sh"

# === Build ===
docker exec -t "${container_name}" bash -lc \
  "set -euxo pipefail; source ${BINARY_ENV_FILE}; bash /pytorch/.ci/${PACKAGE_TYPE}/build.sh"

echo "Done. Wheels/artifacts in: ${ARTIFACTS_DIR}"
ls -lah "${ARTIFACTS_DIR}"
