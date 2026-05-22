#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Config: hier bei Bedarf anpassen
# ============================================================
PY_VERS="3.11"
CUDA_VERSION="13.0"
BUILD_DEVICE="cuda"
PLATFORM="manylinux_2_28_x86_64"
DOCKER_IMAGE="pytorch/manylinux2_28-builder:cpu"
ARTIFACT_DIR="${PWD}/artifacts"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$SCRIPT_DIR/../../wheelhouse_artifacts}"
REPO_ROOT="${PYTORCH_REPO:-$SCRIPT_DIR/../../pytorch}"

# ============================================================
# Usage
# ============================================================
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <triton-version>"
  echo
  echo "Beispiel:"
  echo "  $0 3.6.0+git65232356"
  exit 1
fi

TRITON_VERSION="$1"

# ============================================================
# Checks
# ============================================================
if [[ ! -f "${REPO_ROOT}/.github/scripts/build_triton_wheel.py" ]]; then
  echo "Fehler: build_triton_wheel.py nicht gefunden."
  echo "Bitte dieses Script im Root eines PyTorch-Repos ausführen."
  exit 1
fi

if [[ ! -f "${REPO_ROOT}/.ci/docker/ci_commit_pins/triton.txt" ]]; then
  echo "Fehler: .ci/docker/ci_commit_pins/triton.txt nicht gefunden."
  exit 1
fi

mkdir -p "${ARTIFACT_DIR}"

case "${PY_VERS}" in
  3.10) PYTHON_EXECUTABLE="/opt/python/cp310-cp310/bin/python" ;;
  3.11) PYTHON_EXECUTABLE="/opt/python/cp311-cp311/bin/python" ;;
  3.12) PYTHON_EXECUTABLE="/opt/python/cp312-cp312/bin/python" ;;
  3.13) PYTHON_EXECUTABLE="/opt/python/cp313-cp313/bin/python" ;;
  3.13t) PYTHON_EXECUTABLE="/opt/python/cp313-cp313t/bin/python" ;;
  3.14) PYTHON_EXECUTABLE="/opt/python/cp314-cp314/bin/python" ;;
  3.14t) PYTHON_EXECUTABLE="/opt/python/cp314-cp314t/bin/python" ;;
  *)
    echo "Unsupported PY_VERS: ${PY_VERS}"
    exit 1
    ;;
esac

TRITON_COMMIT="$(tr -d '\n' < "${REPO_ROOT}/.ci/docker/ci_commit_pins/triton.txt")"

WITH_CLANG_LDD=""
if [[ "${BUILD_DEVICE}" == "cuda" || "${BUILD_DEVICE}" == "rocm" || "${BUILD_DEVICE}" == "aarch64" ]]; then
  WITH_CLANG_LDD="--with-clang-ldd"
fi

echo "============================================================"
echo "Local Triton manywheel build"
echo "============================================================"
echo "Repo root         : ${REPO_ROOT}"
echo "Artifact dir      : ${ARTIFACT_DIR}"
echo "Python version    : ${PY_VERS}"
echo "Python executable : ${PYTHON_EXECUTABLE}"
echo "CUDA version      : ${CUDA_VERSION}"
echo "Build device      : ${BUILD_DEVICE}"
echo "Docker image      : ${DOCKER_IMAGE}"
echo "Platform          : ${PLATFORM}"
echo "Triton version    : ${TRITON_VERSION}"
echo "Pinned commit     : ${TRITON_COMMIT}"
echo "============================================================"

container_name="$(
  docker run \
    --tty \
    --detach \
    -e "CUDA_VERSION=${CUDA_VERSION}" \
    -v "${REPO_ROOT}:/pytorch" \
    -v "${ARTIFACT_DIR}:/artifacts" \
    -w /artifacts \
    "${DOCKER_IMAGE}" \
    bash -lc "sleep infinity"
)"

cleanup() {
  set +e
  if [[ -n "${container_name:-}" ]]; then
    docker rm -f "${container_name}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo
echo "== Installiere Build-Abhängigkeiten =="
docker exec -t "${container_name}" yum install -y zlib-devel zip
docker exec -t "${container_name}" "${PYTHON_EXECUTABLE}" -m pip install -U \
  setuptools==78.1.0 \
  pybind11==3.0.1 \
  auditwheel \
  wheel
docker exec -t "${container_name}" "${PYTHON_EXECUTABLE}" -m pip install -U cmake --force-reinstall

if [[ -n "${WITH_CLANG_LDD}" ]]; then
  echo
  echo "== Installiere clang/lld =="
  docker exec -t "${container_name}" dnf install -y clang lld
fi

echo
echo "== Baue Triton-Wheel =="
docker exec -t "${container_name}" bash -lc "
  export PATH=\"$(dirname "${PYTHON_EXECUTABLE}"):\$PATH\"
  which python
  python --version
  which cmake
  cmake --version
  ${PYTHON_EXECUTABLE} /pytorch/.github/scripts/build_triton_wheel.py \
    --device=${BUILD_DEVICE} \
    --commit-hash=${TRITON_COMMIT} \
    --triton-version='${TRITON_VERSION}' \
    ${WITH_CLANG_LDD}
"

echo
echo "== Rohes Wheel in /artifacts =="
docker exec -t "${container_name}" bash -lc "ls -lah /artifacts"

if [[ "${BUILD_DEVICE}" == "cuda" || "${BUILD_DEVICE}" == "xpu" ]]; then
  echo
  echo "== auditwheel repair =="
  docker exec -t "${container_name}" bash -lc "
    auditwheel repair --plat ${PLATFORM} /artifacts/*.whl
  "
else
  echo
  echo "== Verschiebe Wheel direkt nach wheelhouse =="
  docker exec -t "${container_name}" bash -lc "
    mkdir -p /artifacts/wheelhouse
    mv /artifacts/*.whl /artifacts/wheelhouse/
  "
fi

echo
echo "== Setze Besitzrechte =="
docker exec -t "${container_name}" bash -lc "
  chown -R $(id -u):$(id -g) /artifacts/wheelhouse
"

echo
echo "Fertig. Ergebnis liegt in:"
echo "  ${ARTIFACT_DIR}/wheelhouse"
ls -lah "${ARTIFACT_DIR}/wheelhouse"
