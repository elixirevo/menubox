#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-MenuBox}"
PRODUCT_NAME="${PRODUCT_NAME:-$APP_NAME}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-$APP_NAME}"
BUNDLE_ID="${BUNDLE_ID:-com.elixirevo.MenuBox}"
APP_VERSION="${APP_VERSION:-1.1.0}"
APP_BUILD="${APP_BUILD:-110}"
MIN_MACOS="${MIN_MACOS:-13.0}"
LSUIELEMENT="${LSUIELEMENT:-true}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ARCH="${1:-${ARCH:-}}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_DIR="$DIST_DIR/$PRODUCT_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  echo "Usage: $0 <arm64|x86_64>"
  echo "Universal builds are intentionally excluded from this release policy."
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

"$ROOT_DIR/scripts/generate_app_icon.sh"
swift build -c release --arch "$ARCH"
BIN_PATH="$(swift build -c release --arch "$ARCH" --show-bin-path)"

if [[ ! -f "$BIN_PATH/$EXECUTABLE_NAME" ]]; then
  echo "Executable not found: $BIN_PATH/$EXECUTABLE_NAME"
  echo "Set EXECUTABLE_NAME when it differs from APP_NAME."
  exit 1
fi

cp "$BIN_PATH/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

if ! otool -l "$MACOS_DIR/$EXECUTABLE_NAME" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$EXECUTABLE_NAME"
fi

copy_colon_list() {
  local list_value="$1"
  local destination="$2"
  local old_ifs="$IFS"
  IFS=':'
  for item in $list_value; do
    if [[ -n "$item" && -e "$ROOT_DIR/$item" ]]; then
      cp -R "$ROOT_DIR/$item" "$destination/"
    elif [[ -n "$item" && -e "$item" ]]; then
      cp -R "$item" "$destination/"
    elif [[ -n "$item" ]]; then
      echo "Resource not found: $item"
      exit 1
    fi
  done
  IFS="$old_ifs"
}

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $PRODUCT_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $PRODUCT_NAME" "$CONTENTS_DIR/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $PRODUCT_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE_NAME" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_MACOS" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSUIElement $LSUIELEMENT" "$CONTENTS_DIR/Info.plist"

find "$ROOT_DIR/Resources" -maxdepth 1 -type f ! -name "Info.plist" -exec cp {} "$RESOURCES_DIR/" \;

if [[ -n "${RESOURCE_FILES:-}" ]]; then
  copy_colon_list "$RESOURCE_FILES" "$RESOURCES_DIR"
fi

if [[ -n "${RESOURCE_DIRS:-}" ]]; then
  copy_colon_list "$RESOURCE_DIRS" "$RESOURCES_DIR"
fi

if [[ -n "${ICON_ICNS:-}" ]]; then
  cp "$ICON_ICNS" "$RESOURCES_DIR/MenuBox.icns"
elif [[ -n "${ICONSET_DIR:-}" ]]; then
  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/MenuBox.icns"
elif [[ -n "${ICON_PNG:-}" ]]; then
  cp "$ICON_PNG" "$RESOURCES_DIR/AppIcon.png"
fi

SPARKLE_FRAMEWORK_SOURCE="${SPARKLE_FRAMEWORK_SOURCE:-}"
if [[ -z "$SPARKLE_FRAMEWORK_SOURCE" && -d "$ROOT_DIR/.build" ]]; then
  SPARKLE_FRAMEWORK_SOURCE="$(find "$ROOT_DIR/.build/artifacts" -path "*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" -type d | sort | head -n 1 || true)"
fi

if [[ -z "$SPARKLE_FRAMEWORK_SOURCE" && -d "$ROOT_DIR/.build" ]]; then
  SPARKLE_FRAMEWORK_SOURCE="$(find "$ROOT_DIR/.build" -path "*/Sparkle.framework" -type d | sort | head -n 1)"
fi

if [[ -n "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
  if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
    echo "Sparkle.framework not found: $SPARKLE_FRAMEWORK_SOURCE"
    exit 1
  fi
  ditto "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS_DIR/Sparkle.framework"
fi

if [[ -n "${SPARKLE_FEED_URL:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL $SPARKLE_FEED_URL" "$CONTENTS_DIR/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$CONTENTS_DIR/Info.plist"
fi

if [[ -n "${SPARKLE_ENABLE_AUTOMATIC_CHECKS:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks $SPARKLE_ENABLE_AUTOMATIC_CHECKS" "$CONTENTS_DIR/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool $SPARKLE_ENABLE_AUTOMATIC_CHECKS" "$CONTENTS_DIR/Info.plist"
fi

SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_PUBLIC_ED_KEY_FILE="${SPARKLE_PUBLIC_ED_KEY_FILE:-$ROOT_DIR/sparkle-public-key.txt}"
if [[ -z "$SPARKLE_PUBLIC_ED_KEY" && -n "${SPARKLE_PUBLIC_ED_KEY_FILE:-}" && -f "$SPARKLE_PUBLIC_ED_KEY_FILE" ]]; then
  SPARKLE_PUBLIC_ED_KEY="$(tr -d '[:space:]' < "$SPARKLE_PUBLIC_ED_KEY_FILE")"
fi

if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$CONTENTS_DIR/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$CONTENTS_DIR/Info.plist"
fi

codesign_path() {
  local path="$1"
  shift || true

  if [[ ! -e "$path" ]]; then
    return
  fi

  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$@" "$path"
  else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@" "$path"
  fi
}

if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]]; then
  while IFS= read -r nested_item; do
    codesign_path "$nested_item"
  done < <(find "$FRAMEWORKS_DIR/Sparkle.framework" \( -name "*.xpc" -o -name "*.app" \) -type d | sort)

  while IFS= read -r nested_binary; do
    codesign_path "$nested_binary"
  done < <(find "$FRAMEWORKS_DIR/Sparkle.framework" \( -name "Autoupdate" -o -name "Downloader" \) -type f | sort)

  codesign_path "$FRAMEWORKS_DIR/Sparkle.framework"
fi

codesign_path "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "App bundle created: $APP_DIR"
