#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${PYTORCH_REPO:-$SCRIPT_DIR/../../pytorch}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$SCRIPT_DIR/artifacts}"
PY_VERS="${PY_VERS:-3.11}"
BUILD_DEVICE="${BUILD_DEVICE:-cuda}"
PLATFORM="${PLATFORM:-manylinux_2_28_x86_64}"
IS_RELEASE_TAG="${IS_RELEASE_TAG:-false}"

usage() {
  echo "Usage: $0 [triton-version]"
  echo
  echo "Environment overrides: PYTORCH_REPO, ARTIFACT_DIR, PY_VERS, BUILD_DEVICE, DOCKER_IMAGE, PLATFORM, IS_RELEASE_TAG"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 1
fi

TRITON_VERSION="${1:-}"

if [[ ! -f "${REPO_ROOT}/.github/scripts/build_triton_wheel.py" ]]; then
  echo "ERROR: build_triton_wheel.py not found under ${REPO_ROOT}." >&2
  echo "Set PYTORCH_REPO to a PyTorch checkout." >&2
  exit 1
fi

case "${PY_VERS}" in
  3.10) PYTHON_EXECUTABLE="/opt/python/cp310-cp310/bin/python" ;;
  3.11) PYTHON_EXECUTABLE="/opt/python/cp311-cp311/bin/python" ;;
  3.12) PYTHON_EXECUTABLE="/opt/python/cp312-cp312/bin/python" ;;
  3.13) PYTHON_EXECUTABLE="/opt/python/cp313-cp313/bin/python" ;;
  3.14) PYTHON_EXECUTABLE="/opt/python/cp314-cp314/bin/python" ;;
  3.14t) PYTHON_EXECUTABLE="/opt/python/cp314-cp314t/bin/python" ;;
  *)
    echo "Unsupported PY_VERS: ${PY_VERS}" >&2
    exit 1
    ;;
esac

case "${BUILD_DEVICE}" in
  cuda|xpu)
    DOCKER_IMAGE="${DOCKER_IMAGE:-pytorch/manylinux2_28-builder:cpu}"
    AUDITWHEEL_ARGS=(--plat "${PLATFORM}" --exclude libtriton.so)
    ;;
  rocm)
    DOCKER_IMAGE="${DOCKER_IMAGE:-pytorch/manylinux2_28-builder:rocm7.2}"
    AUDITWHEEL_ARGS=()
    ;;
  aarch64)
    DOCKER_IMAGE="${DOCKER_IMAGE:-pytorch/manylinux2_28_aarch64-builder:cpu-aarch64}"
    AUDITWHEEL_ARGS=()
    ;;
  *)
    echo "Unsupported BUILD_DEVICE: ${BUILD_DEVICE}" >&2
    exit 1
    ;;
esac

mkdir -p "${ARTIFACT_DIR}"

RELEASE=()
if [[ "${IS_RELEASE_TAG}" == "true" ]]; then
  RELEASE=(--release)
fi

WITH_CLANG_LDD=()
if [[ "${BUILD_DEVICE}" == "cuda" || "${BUILD_DEVICE}" == "rocm" || "${BUILD_DEVICE}" == "aarch64" ]]; then
  WITH_CLANG_LDD=(--with-clang-ldd)
fi

VERSION_ARG=()
if [[ -n "${TRITON_VERSION}" ]]; then
  VERSION_ARG=(--triton-version "${TRITON_VERSION}")
fi

cat <<EOF
============================================================
Local Triton manywheel build
============================================================
Repo root         : ${REPO_ROOT}
Artifact dir      : ${ARTIFACT_DIR}
Python version    : ${PY_VERS}
Python executable : ${PYTHON_EXECUTABLE}
Build device      : ${BUILD_DEVICE}
Docker image      : ${DOCKER_IMAGE}
Platform          : ${PLATFORM}
Release build     : ${IS_RELEASE_TAG}
Triton version    : ${TRITON_VERSION:-from PyTorch pin}
============================================================
EOF

container_name=$(
  docker run \
    --tty \
    --detach \
    -v "${REPO_ROOT}:/pytorch" \
    -v "${ARTIFACT_DIR}:/artifacts" \
    -w /artifacts \
    "${DOCKER_IMAGE}"
)

cleanup() {
  set +e
  if [[ -n "${container_name:-}" ]]; then
    docker rm -f "${container_name}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo
echo "== Install build dependencies =="
docker exec -t "${container_name}" yum install -y zlib-devel zip
docker exec -t "${container_name}" "${PYTHON_EXECUTABLE}" -m pip install -U \
  setuptools==78.1.0 \
  pybind11==3.0.1 \
  auditwheel \
  wheel

set +e
docker exec -t "${container_name}" command -v pip >/dev/null
has_pip=$?
set -e
if [[ ${has_pip} -eq 0 ]]; then
  docker exec -t "${container_name}" pip install -U cmake --force-reinstall
else
  docker exec -t "${container_name}" "${PYTHON_EXECUTABLE}" -m pip install -U cmake --force-reinstall
fi

if [[ ${#WITH_CLANG_LDD[@]} -gt 0 ]]; then
  echo
  echo "== Install clang/lld =="
  docker exec -t "${container_name}" dnf install -y clang lld
fi

echo
echo "== Build Triton wheel =="
docker exec -t "${container_name}" bash -lc "
  set -euxo pipefail
  ${PYTHON_EXECUTABLE} /pytorch/.github/scripts/build_triton_wheel.py \
    --device='${BUILD_DEVICE}' \
    ${RELEASE[*]} \
    ${WITH_CLANG_LDD[*]} \
    ${VERSION_ARG[*]}
"

echo
echo "== Raw wheel in /artifacts =="
docker exec -t "${container_name}" bash -lc "ls -lah /artifacts"

if [[ ${#AUDITWHEEL_ARGS[@]} -gt 0 ]]; then
  echo
  echo "== auditwheel repair =="
  docker exec -t "${container_name}" bash -lc "auditwheel repair ${AUDITWHEEL_ARGS[*]} /artifacts/*.whl"
else
  echo
  echo "== Move wheel directly to wheelhouse =="
  docker exec -t "${container_name}" bash -lc "mkdir -p /artifacts/wheelhouse && mv /artifacts/*.whl /artifacts/wheelhouse/"
fi

echo
echo "== Set ownership =="
docker exec -t "${container_name}" chown -R "$(id -u):$(id -g)" /artifacts/wheelhouse

echo
echo "Done. Result is in:"
echo "  ${ARTIFACT_DIR}/wheelhouse"
ls -lah "${ARTIFACT_DIR}/wheelhouse"
