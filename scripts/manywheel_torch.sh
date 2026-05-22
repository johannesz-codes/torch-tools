#!/usr/bin/env bash
set -euo pipefail

# Verzeichnis des Scripts selbst
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$SCRIPT_DIR/../../wheelhouse_artifacts}"
PYTORCH_REPO="${PYTORCH_REPO:-$SCRIPT_DIR/../../pytorch}"
export DESIRED_CUDA="${DESIRED_CUDA:-cu130}"
export DESIRED_PYTHON="${DESIRED_PYTHON:-3.11}"
WORKFLOW_FILE="${PYTORCH_REPO}/.github/workflows/generated-linux-binary-manywheel-nightly.yml"

readarray -t BUILD_VARS < <(
python3 - "$WORKFLOW_FILE" "${DESIRED_CUDA}" "${DESIRED_PYTHON}" <<'PY'
import sys
from pathlib import Path

workflow_path = Path(sys.argv[1])
desired_cuda = sys.argv[2]
desired_python = sys.argv[3]

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(1)

data = yaml.safe_load(workflow_path.read_text())

cuda_job_map = {
    "cu126": "cuda12_6",
    "cu130": "cuda13_0",
    "cu132": "cuda13_2",
    "cpu": "cpu",
}

cuda_job = cuda_job_map.get(desired_cuda)
if cuda_job is None:
    print(f"ERROR: unsupported DESIRED_CUDA={desired_cuda}", file=sys.stderr)
    sys.exit(1)

py_job = "py" + desired_python.replace(".", "_")
job_name = f"manywheel-{py_job}-{cuda_job}-build"

try:
    match = data["jobs"][job_name]["with"]
except KeyError:
    print(f"ERROR: could not find job {job_name} with .with block", file=sys.stderr)
    sys.exit(1)

print(match["DOCKER_IMAGE"])
print(match["DOCKER_IMAGE_TAG_PREFIX"])
print(match["build_name"])
print(match.get("GPU_ARCH_VERSION", ""))
print(match.get("PYTORCH_EXTRA_INSTALL_REQUIREMENTS", ""))
PY
)

# === Konfig ===
DOCKER_IMAGE_BASE="${BUILD_VARS[0]}"
DOCKER_IMAGE_TAG_PREFIX="${BUILD_VARS[1]}"
BUILD_NAME="${BUILD_VARS[2]}"
GPU_ARCH_VERSION="${BUILD_VARS[3]:-}"
PYTORCH_EXTRA_INSTALL_REQUIREMENTS="${BUILD_VARS[4]:-}"

export DOCKER_IMAGE_BASE
export DOCKER_IMAGE_TAG_PREFIX
export BUILD_NAME
export GPU_ARCH_VERSION
export PYTORCH_EXTRA_INSTALL_REQUIREMENTS


export GPU_ARCH_TYPE="cuda"
export PACKAGE_TYPE="manywheel"
export PYTORCH_ROOT="/pytorch"
export SKIP_ALL_TESTS="${SKIP_ALL_TESTS:-1}"
export BINARY_ENV_FILE="/tmp/env"
export BUILD_ENVIRONMENT="linux-binary-manywheel"
export PYTORCH_FINAL_PACKAGE_DIR="/artifacts"

DOCKER_IMAGE="${DOCKER_IMAGE:-docker.io/pytorch/${DOCKER_IMAGE_BASE}:${DOCKER_IMAGE_TAG_PREFIX}}"

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
