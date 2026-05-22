#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$SCRIPT_DIR/../../wheelhouse_artifacts}"
PYTORCH_REPO="${PYTORCH_REPO:-$SCRIPT_DIR/../../pytorch}"
export DESIRED_CUDA="${DESIRED_CUDA:-cu130}"
export DESIRED_PYTHON="${DESIRED_PYTHON:-3.11}"
WORKFLOW_FILE="${PYTORCH_REPO}/.github/workflows/generated-linux-binary-manywheel-nightly.yml"
DOCKER_IMAGE_OVERRIDE="${DOCKER_IMAGE:-}"

if [[ ! -f "${WORKFLOW_FILE}" ]]; then
  echo "ERROR: PyTorch workflow not found: ${WORKFLOW_FILE}" >&2
  echo "Set PYTORCH_REPO to a PyTorch checkout." >&2
  exit 1
fi

readarray -t BUILD_ENV < <(
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
    "cu126": "cuda-cu126",
    "cu130": "cuda-cu130",
    "cu132": "cuda-cu132",
    "cpu": "cpu",
}

job_key = cuda_job_map.get(desired_cuda)
if job_key is None:
    print(f"ERROR: unsupported DESIRED_CUDA={desired_cuda}", file=sys.stderr)
    sys.exit(1)

job_name = f"manywheel-{job_key}-build"

try:
    job = data["jobs"][job_name]
    container = job["container"]
    env = dict(job.get("env", {}))
except KeyError:
    print(f"ERROR: could not find job {job_name} with env/container block", file=sys.stderr)
    sys.exit(1)

available_pythons = env.get("DESIRED_PYTHONS", "").split()
if desired_python not in available_pythons:
    print(
        f"ERROR: DESIRED_PYTHON={desired_python} is not in CI DESIRED_PYTHONS={available_pythons}",
        file=sys.stderr,
    )
    sys.exit(1)

env["DOCKER_IMAGE"] = container["image"]
env["DESIRED_PYTHONS"] = desired_python

for key in sorted(env):
    value = env[key]
    if value is None:
        value = ""
    print(f"{key}={value}")
PY
)

for entry in "${BUILD_ENV[@]}"; do
  export "${entry}"
done

if [[ -n "${DOCKER_IMAGE_OVERRIDE}" ]]; then
  DOCKER_IMAGE="${DOCKER_IMAGE_OVERRIDE}"
  export DOCKER_IMAGE
fi

export PACKAGE_TYPE="manywheel"
export PYTORCH_ROOT="/pytorch"
export BINARY_ENV_FILE="/tmp/env"
export BUILD_ENVIRONMENT="linux-binary-manywheel"
export PYTORCH_FINAL_PACKAGE_DIR="/artifacts"

mkdir -p "${ARTIFACTS_DIR}"

echo "Using repo: ${PYTORCH_REPO}"
echo "Artifacts:  ${ARTIFACTS_DIR}"
echo "Image:      ${DOCKER_IMAGE}"
echo "CUDA:       ${DESIRED_CUDA}"
echo "Python:     ${DESIRED_PYTHONS}"

container_name=$(
  docker run \
    -e BINARY_ENV_FILE \
    -e BUILD_ENVIRONMENT \
    -e DESIRED_CUDA \
    -e DESIRED_PYTHONS \
    -e DOCKER_IMAGE \
    -e GPU_ARCH_TYPE \
    -e GPU_ARCH_VERSION \
    -e PACKAGE_TYPE \
    -e PYTORCH_EXTRA_INSTALL_REQUIREMENTS \
    -e PYTORCH_FINAL_PACKAGE_DIR \
    -e PYTORCH_ROOT \
    -e SKIP_ALL_TESTS \
    -e BUILD_NAME_PREFIX \
    -e BUILD_NAME_SUFFIX \
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

docker exec -t -w "${PYTORCH_ROOT}" "${container_name}" git config --global --add safe.directory "${PYTORCH_ROOT}"
docker exec -t -w "${PYTORCH_ROOT}" "${container_name}" bash -lc \
  "bash .ci/pytorch/binary_populate_env.sh"

docker exec -t "${container_name}" bash -lc \
  "set -euxo pipefail; source ${BINARY_ENV_FILE}; bash /pytorch/.ci/${PACKAGE_TYPE}/build_all.sh"

echo "Done. Wheels/artifacts in: ${ARTIFACTS_DIR}"
ls -lah "${ARTIFACTS_DIR}"
