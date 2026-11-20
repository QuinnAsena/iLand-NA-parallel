#!/bin/bash
# Build the iLand console version (ilandc) with the patches in gpu/patches:
#   bin/ilandc_cpu  - CPU build with the multithreading fixes
#   bin/ilandc_gpu  - the same plus the CUDA path (only if nvcc is found)
#
# Usage:  gpu/build_iland.sh [DEST]        (default DEST: ./iland-build)
#
# Needs git, make, a C++17 compiler, Qt 6.5-6.8 (Qt 6.12 is too new for iLand 2.2: moc fails
# in bite/biteagent) with the core, xml, sql (SQLite driver), qml and concurrent modules, and
# FreeImage. For the GPU build also the CUDA toolkit (nvcc, CUDA 12 or 13). The easiest way to
# get Qt and FreeImage is pixi (https://pixi.sh), using gpu/pixi.toml:
#     pixi run --manifest-path gpu/pixi.toml gpu/build_iland.sh
# Set CUDA_DIR if nvcc is not in /usr/local/cuda, and CUDA_ARCH to build for one GPU only
# (e.g. CUDA_ARCH="-arch=sm_80" for A100; the default builds for all major GPU generations).
set -euo pipefail

ILAND_REPO=https://github.com/edfm-tum/iland-model.git
ILAND_COMMIT=4dd4e6faf84f65bfa1cffb792bb49e4e01575468   # iLand 2.2, main of 2026-10-14
here=$(cd "$(dirname "$0")" && pwd)
dest=$(mkdir -p "${1:-$PWD/iland-build}" && cd "${1:-$PWD/iland-build}" && pwd)
src="${dest}/iland-model"
jobs=$(nproc 2>/dev/null || echo 8)
qmake=$(command -v qmake6 || command -v qmake || true)
[ -n "$qmake" ] || { echo "qmake not found (install Qt 6, or use pixi with gpu/pixi.toml)"; exit 1; }

if [ ! -d "$src/.git" ]; then
    git clone "$ILAND_REPO" "$src"
fi
git -C "$src" checkout -q "$ILAND_COMMIT"
if git -C "$src" apply --check "$here"/patches/*.patch 2>/dev/null; then
    git -C "$src" apply "$here"/patches/*.patch
    echo "applied $(ls "$here"/patches/*.patch | wc -l) patches"
else
    git -C "$src" apply --reverse --check "$here"/patches/*.patch && echo "patches already applied"
fi

# extra include/library paths for conda/pixi environments (FreeImage, Qt)
extra=()
if [ -n "${CONDA_PREFIX:-}" ]; then
    extra=("INCLUDEPATH+=$CONDA_PREFIX/include" "LIBS+=-L$CONDA_PREFIX/lib -Wl,-rpath,$CONDA_PREFIX/lib")
fi

mkdir -p "$src/src/plugins/build/release" "${dest}/bin"
(cd "$src/src/plugins/build/release" && "$qmake" ../../plugins.pro && make -j"$jobs" -s)

build() {   # build VARIANT [qmake args...]
    local variant=$1; shift
    mkdir -p "$src/src/ilandc/build/$variant"
    (cd "$src/src/ilandc/build/$variant" && "$qmake" ../../ilandc.pro "$@" "${extra[@]}" && make -j"$jobs" -s)
    cp "$src/src/ilandc/build/$variant/ilandc" "${dest}/bin/ilandc_${variant}"
    echo "built ${dest}/bin/ilandc_${variant}"
}
build cpu
cuda_dir=${CUDA_DIR:-${CUDA_HOME:-/usr/local/cuda}}
if [ -x "$cuda_dir/bin/nvcc" ]; then
    args=(CONFIG+=cuda "CUDA_DIR=$cuda_dir")
    [ -n "${CUDA_ARCH:-}" ] && args+=("CUDA_ARCH=$CUDA_ARCH")
    build gpu "${args[@]}"
else
    echo "nvcc not found in $cuda_dir: skipping the GPU build (set CUDA_DIR)"
fi
