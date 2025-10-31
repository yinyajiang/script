#!/bin/bash
set -euo pipefail

# install prefix
PREFIX="$(pwd)/dist"

FFTW_TARBALL="fftw-3.3.10.tar.gz"
FFTW_URL="https://www.fftw.org/${FFTW_TARBALL}"
export MACOSX_DEPLOYMENT_TARGET=11.0

download_file() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --progress-bar -o "${out}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${out}" "${url}"
  else
    echo "curl or wget not found, please install one of them" >&2
    exit 1
  fi
}

if [ ! -f "${FFTW_TARBALL}" ]; then
  download_file "${FFTW_URL}" "${FFTW_TARBALL}"
fi

dirName=$(basename "${FFTW_TARBALL}" .tar.gz)
echo "dirName: ${dirName}"
if [ ! -d "${dirName}" ]; then
  tar xvf "${FFTW_TARBALL}"
fi
echo "cd ${dirName}"
cd "${dirName}"
pwd

# 安装依赖库（已安装则跳过），并且不触发 brew 自动更新
echo "installing dependencies..."
export HOMEBREW_NO_AUTO_UPDATE=1
deps=(
  cmake
)

for dep in "${deps[@]}"; do
  if brew ls --versions "${dep}" >/dev/null 2>&1; then
    echo "- ${dep} already installed, skipping"
  else
    echo "- installing ${dep}..."
    brew install "${dep}"
  fi
done


echo "compile fftw..."

# 将CMakeLists.txt拷贝到当前目录,覆盖原来的CMakeLists.txt
cp ../CMakeLists.txt .
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
cmake --build build
cmake --install build

echo done!!
