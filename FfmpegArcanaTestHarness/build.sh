#!/bin/bash
set -e
cd "$(dirname "$0")"

SCRIPT_DIR="$(pwd)"
FFMPEG_ARCANA="${FFMPEG_ARCANA_ROOT:-$SCRIPT_DIR/../FfmpegArcana}"
FFMPEG_FW="${FFMPEG_ROOT:-$SCRIPT_DIR/../Frameworks}"

# Convert to absolute paths
FFMPEG_ARCANA="$(cd "$FFMPEG_ARCANA" && pwd)"
FFMPEG_FW="$(cd "$FFMPEG_FW" && pwd)"

mkdir -p build && cd build

cmake -G Ninja \
  -DFFMPEG_ARCANA_ROOT="$FFMPEG_ARCANA" \
  -DFFMPEG_ROOT="$FFMPEG_FW" \
  ..

ninja