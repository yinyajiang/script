#!/bin/bash
set -euo pipefail

# install prefix
PREFIX="$(pwd)/dist"

FFMPEG_TARBALL="ffmpeg-7.1.1.tar.xz"
FFMPEG_URL="https://ffmpeg.org/releases/${FFMPEG_TARBALL}"

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

# 安装依赖库
echo "installing dependencies..."
brew install \
  nasm \
  yasm \
  x264 \
  x265 \
  libvpx \
  opus \
  libvorbis \
  lame \
  fdk-aac \
  libass \
  freetype \
  pkg-config 
# webp \


cd "${dirName}"

# make clean || true

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
  --enable-libvpx \
  --enable-libopus \
  --enable-libvorbis \
  --enable-libmp3lame \
  --enable-libfdk-aac \
  --enable-libass \
  --enable-libfreetype \
  --enable-optimizations \
  --pkg-config-flags="--static" \
  --disable-autodetect
# 禁用自动检测外部库, 避免引入不必要的依赖
# --enable-libwebp \


make -j4
make install

echo "copying dependents..."
dict_ffmpeg_path="${PREFIX}/bin/ffmpeg"
dict_lib_path="${PREFIX}/lib"
cd ../../macos
python3 dependents.py copy-dependents -t "${dict_ffmpeg_path}" -o "${dict_lib_path}"

pkgconfig_dir="${dict_lib_path}/pkgconfig"
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
fi
