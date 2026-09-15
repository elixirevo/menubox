#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")}"
APP_NAME="MenuBox"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
ZIP_PATH="$ROOT_DIR/dist/$APP_NAME-$VERSION.zip"

"$ROOT_DIR/scripts/build_app.sh"

rm -f "$ZIP_PATH"
cd "$ROOT_DIR/dist"
ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_PATH"

echo "Created $ZIP_PATH"
echo
echo "SHA256:"
shasum -a 256 "$ZIP_PATH" | awk '{print $1}'
