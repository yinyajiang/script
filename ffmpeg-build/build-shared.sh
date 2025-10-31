#!/bin/bash
set -euo pipefail

# install prefix
PREFIX="$(pwd)/dist"

FFMPEG_TARBALL="ffmpeg-7.1.1.tar.xz"
FFMPEG_URL="https://ffmpeg.org/releases/${FFMPEG_TARBALL}"
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

if [ ! -f "${FFMPEG_TARBALL}" ]; then
  download_file "${FFMPEG_URL}" "${FFMPEG_TARBALL}"
fi

dirName=$(basename "${FFMPEG_TARBALL}" .tar.xz)
echo "dirName: ${dirName}"
if [ ! -d "${dirName}" ]; then
  tar xvf "${FFMPEG_TARBALL}"
fi
echo "cd ${dirName}"
cd "${dirName}"
pwd

# 安装依赖库（已安装则跳过），并且不触发 brew 自动更新
echo "installing dependencies..."
export HOMEBREW_NO_AUTO_UPDATE=1
deps=(
  nasm
  yasm
  x264
  x265
  libvpx
  opus
  libvorbis
  lame
  fdk-aac
  libass
  freetype
  pkg-config
  dav1d
  # webp
)

for dep in "${deps[@]}"; do
  if brew ls --versions "${dep}" >/dev/null 2>&1; then
    echo "- ${dep} already installed, skipping"
  else
    echo "- installing ${dep}..."
    brew install "${dep}"
  fi
done


# make clean || true

echo "compile ffmpeg..."

MIN_VERSION_FLAGS="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"


BREW_PREFIX="$(brew --prefix)"
echo "BREW_PREFIX: $BREW_PREFIX"
export PKG_CONFIG_PATH="$BREW_PREFIX/lib/pkgconfig:$BREW_PREFIX/opt/lame/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
EXTRA_INC="-I$BREW_PREFIX/include"
EXTRA_LIB="-L$BREW_PREFIX/lib"

./configure \
  --prefix=$PREFIX \
  --disable-ffplay \
  --disable-ffprobe \
  --disable-debug \
  --disable-sdl2 \
  --disable-outdevs \
  --enable-shared \
  --disable-static \
  --enable-pic \
  --enable-gpl \
  --enable-nonfree \
  --enable-libx264 \
  --enable-libx265 \
  --enable-libdav1d \
  --enable-libvpx \
  --enable-libopus \
  --enable-libvorbis \
  --enable-libmp3lame \
  --enable-libfdk-aac \
  --enable-libass \
  --enable-libfreetype \
  --enable-optimizations \
  --extra-cflags="${MIN_VERSION_FLAGS} ${EXTRA_INC}" \
  --extra-ldflags="${MIN_VERSION_FLAGS} ${EXTRA_LIB}" \
  --pkg-config-flags="--static" \
  --disable-autodetect
# 禁用自动检测外部库, 避免引入不必要的依赖
# --enable-libwebp \

make -j4
make install

echo "copying dependents..."
dist_ffmpeg_path="${PREFIX}/bin/ffmpeg"
dist_lib_path="${PREFIX}/lib"
cd ../../macos
python3 dependents.py copy-dependents -t "${dist_ffmpeg_path}" -o "${dist_lib_path}"

pkgconfig_dir="${dist_lib_path}/pkgconfig"
if [ -d "${pkgconfig_dir}" ]; then
  echo "rewriting pkg-config files in ${pkgconfig_dir}..."
  for pc in "${pkgconfig_dir}"/*.pc; do
    [ -f "${pc}" ] || continue
    sed -E -i '' \
      -e 's|^prefix=.*$|prefix=\${pcfiledir}/../..|' \
      -e 's|^exec_prefix=.*$|exec_prefix=\${prefix}|' \
      -e 's|^libdir=.*$|libdir=\${pcfiledir}/..|' \
      -e 's|^includedir=.*$|includedir=\${prefix}/include|' \
      "${pc}"
  done
  echo "done!!!"
fi
