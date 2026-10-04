#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ICON="$ROOT_DIR/menubox.icon"
OUTPUT_DIR="${1:-$ROOT_DIR/.build/app-icon}"
ICONSET_DIR="$OUTPUT_DIR/MenuBox.iconset"

# Icon Composer needs full Xcode, even when Swift uses Command Line Tools.
ICON_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ ! -x "$ICON_DEVELOPER_DIR/usr/bin/actool" && -d /Applications/Xcode.app ]]; then
  ICON_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
ACTOOL="$ICON_DEVELOPER_DIR/usr/bin/actool"
ICTOOL="$ICON_DEVELOPER_DIR/../Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ ! -x "$ACTOOL" || ! -x "$ICTOOL" ]]; then
  echo "Icon generation requires Xcode with Icon Composer; set DEVELOPER_DIR to its Contents/Developer directory." >&2
  exit 1
fi
if [[ ! -f "$SOURCE_ICON/icon.json" ]]; then
  echo "Missing Icon Composer document: $SOURCE_ICON" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/menubox-icon.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/MenuBox.iconset" "$OUTPUT_DIR"
DEVELOPER_DIR="$ICON_DEVELOPER_DIR" "$ACTOOL" "$SOURCE_ICON" \
  --compile "$WORK_DIR" --output-format human-readable-text \
  --app-icon menubox --include-all-app-icons --target-device mac \
  --platform macosx --minimum-deployment-target "${MIN_MACOS:-13.0}" \
  --output-partial-info-plist "$WORK_DIR/partial.plist"

# Render small permission-list icons at their target point size and scale,
# preserving the document rendering instead of resizing the old PNG.
# actool's compatibility ICNS omits some sizes; supply the complete legacy set.
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=""
    if [[ "$scale" == 2 ]]; then suffix="@2x"; fi
    "$ICTOOL" "$SOURCE_ICON" --export-image \
      --output-file "$WORK_DIR/MenuBox.iconset/icon_${size}x${size}${suffix}.png" \
      --platform macOS --rendition Default --width "$size" --height "$size" --scale "$scale" >/dev/null
  done
done
iconutil -c icns "$WORK_DIR/MenuBox.iconset" -o "$WORK_DIR/MenuBox.icns"
mkdir -p "$ICONSET_DIR"
cp "$WORK_DIR/MenuBox.iconset/"*.png "$ICONSET_DIR/"
cp "$WORK_DIR/MenuBox.icns" "$OUTPUT_DIR/MenuBox.icns"
cp "$WORK_DIR/Assets.car" "$OUTPUT_DIR/Assets.car"
echo "Generated layered assets and complete compatibility icons from $SOURCE_ICON"
