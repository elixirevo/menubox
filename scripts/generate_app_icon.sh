#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ICON="$ROOT_DIR/icon.png"
ICONSET_DIR="$ROOT_DIR/Resources/MenuBox.iconset"
ICNS_PATH="$ROOT_DIR/Resources/MenuBox.icns"
MODULE_CACHE_DIR="$ROOT_DIR/.build/module-cache"

if [[ ! -f "$SOURCE_ICON" ]]; then
  echo "Missing source icon: $SOURCE_ICON" >&2
  exit 1
fi

mkdir -p "$ICONSET_DIR" "$MODULE_CACHE_DIR"

sips -s format png -z 16 16 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -s format png -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -s format png -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -s format png -z 64 64 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -s format png -z 128 128 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -s format png -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -s format png -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -s format png -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -s format png -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -s format png -z 1024 1024 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

swift -module-cache-path "$MODULE_CACHE_DIR" "$ROOT_DIR/scripts/create_icns.swift" \
  "$ICNS_PATH" \
  "icp4:$ICONSET_DIR/icon_16x16.png" \
  "icp5:$ICONSET_DIR/icon_32x32.png" \
  "icp6:$ICONSET_DIR/icon_32x32@2x.png" \
  "ic07:$ICONSET_DIR/icon_128x128.png" \
  "ic08:$ICONSET_DIR/icon_256x256.png" \
  "ic09:$ICONSET_DIR/icon_512x512.png" \
  "ic10:$ICONSET_DIR/icon_512x512@2x.png"

echo "Generated $ICNS_PATH from $SOURCE_ICON"
