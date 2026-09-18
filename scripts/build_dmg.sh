#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-MenuBox}"
PRODUCT_NAME="${PRODUCT_NAME:-$APP_NAME}"
APP_VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")}"
ARCH="${1:-${ARCH:-}}"
VOL_NAME="${VOL_NAME:-MenuBox}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_PATH="$DIST_DIR/$PRODUCT_NAME.app"
DMG_PATH="$DIST_DIR/${APP_NAME}-${APP_VERSION}-${ARCH}.dmg"
RW_DMG_PATH="$DIST_DIR/${APP_NAME}-${APP_VERSION}-${ARCH}-rw.dmg"
TMP_DIR="$(mktemp -d /tmp/${APP_NAME}-dmg.${ARCH}.XXXXXX)"
STAGE_DIR="$TMP_DIR/stage"
BG_DIR="$STAGE_DIR/.background"
BG_IMAGE="$BG_DIR/background.png"
DEVICE_NAME=""

if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  echo "Usage: $0 <arm64|x86_64>"
  echo "Universal DMGs are intentionally excluded from this release policy."
  exit 1
fi

cleanup() {
  if [[ -n "$DEVICE_NAME" ]]; then
    hdiutil detach "$DEVICE_NAME" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ARCH="$ARCH" bash "$ROOT_DIR/scripts/build_app.sh" "$ARCH"

if [[ "${NOTARIZE:-0}" == "1" ]]; then
  bash "$ROOT_DIR/scripts/notarize.sh" "$APP_PATH" "$ARCH"
fi

mkdir -p "$STAGE_DIR" "$BG_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/$PRODUCT_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

swift "$ROOT_DIR/scripts/create_dmg_background.swift" "$BG_IMAGE" "$PRODUCT_NAME"

rm -f "$DMG_PATH" "$RW_DMG_PATH"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$RW_DMG_PATH" >/dev/null

ATTACH_OUTPUT="$(
hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  "$RW_DMG_PATH"
)"

DEVICE_NAME="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '/GUID_partition_scheme/ {gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1; exit}')"
if [[ -z "$DEVICE_NAME" ]]; then
  DEVICE_NAME="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '/Apple_HFS/ {gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1; exit}')"
fi
MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '/Apple_HFS/ {gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit}')"

if [[ -z "$DEVICE_NAME" || -z "$MOUNT_POINT" ]]; then
  echo "Failed to parse mounted DMG information."
  echo "$ATTACH_OUTPUT"
  exit 1
fi

osascript <<OSA
set mountAlias to POSIX file "${MOUNT_POINT}" as alias
set bgAlias to POSIX file "${MOUNT_POINT}/.background/background.png" as alias
tell application "Finder"
  open mountAlias
  set dmgWindow to container window of mountAlias
  set current view of dmgWindow to icon view
  set the bounds of dmgWindow to {120, 120, 800, 540}
  set opts to the icon view options of dmgWindow
  set arrangement of opts to not arranged
  set icon size of opts to 128
  set text size of opts to 13
  set background picture of opts to bgAlias
  set position of item "${PRODUCT_NAME}.app" of mountAlias to {180, 260}
  set position of item "Applications" of mountAlias to {500, 260}
  delay 1
end tell
OSA

hdiutil detach "$DEVICE_NAME" >/dev/null || hdiutil detach "$DEVICE_NAME" -force >/dev/null
DEVICE_NAME=""

hdiutil convert "$RW_DMG_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$RW_DMG_PATH"

if [[ "${SIGN_DMG:-0}" == "1" ]]; then
  if [[ "${SIGN_IDENTITY:--}" == "-" ]]; then
    codesign --force --sign - "$DMG_PATH"
  else
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  fi
fi

hdiutil verify "$DMG_PATH" >/dev/null
if [[ "${NOTARIZE:-0}" == "1" ]]; then
  bash "$ROOT_DIR/scripts/notarize.sh" "$DMG_PATH" "$ARCH"
fi
echo "DMG created: $DMG_PATH"
