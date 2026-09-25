#!/usr/bin/env bash
set -euo pipefail

SPARKLE_VERSION="2.10.0"
CACHE_DIR="${SPARKLE_TOOLS_DIR:-/private/tmp/magsafe-watch-sparkle-$SPARKLE_VERSION}"
ARCHIVE_PATH="$CACHE_DIR/Sparkle.tar.xz"

if [[ ! -x "$CACHE_DIR/bin/generate_appcast" ]]; then
  mkdir -p "$CACHE_DIR"
  curl -fsSL \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    -o "$ARCHIVE_PATH"
  tar -xJf "$ARCHIVE_PATH" -C "$CACHE_DIR"
fi

echo "$CACHE_DIR/bin"
