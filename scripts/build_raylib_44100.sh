#!/usr/bin/env bash
# Build a local raylib 5.5 with AUDIO_DEVICE_SAMPLE_RATE=44100 so device
# matches fastmix-ai project/stream rate (no miniaudio 44.1→48 SRC).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/raylib-src"
PREFIX="$ROOT/third_party/raylib-44100"
BUILD="$ROOT/third_party/raylib-build"
TAG="${RAYLIB_TAG:-5.5}"

mkdir -p "$ROOT/third_party"
if [[ ! -d "$SRC/.git" ]]; then
  rm -rf "$SRC"
  git clone --depth 1 --branch "$TAG" https://github.com/raysan5/raylib.git "$SRC"
fi

# Force device open at 44100 (config.h default is 0 = native, usually 48000 on macOS).
perl -i -pe 's/^#define AUDIO_DEVICE_SAMPLE_RATE\s+0\b/#define AUDIO_DEVICE_SAMPLE_RATE    44100/' \
  "$SRC/src/config.h"
grep -n 'AUDIO_DEVICE_SAMPLE_RATE' "$SRC/src/config.h"

rm -rf "$BUILD" "$PREFIX"
mkdir -p "$BUILD"
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_SHARED_LIBS=ON
cmake --build "$BUILD" -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
cmake --install "$BUILD"

echo "Installed to $PREFIX"
ls -la "$PREFIX/lib"
echo "OK: rebuild fastmix-ai with zig build (prefers this lib when present)."
