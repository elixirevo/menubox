#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-MenuBox}"
PRODUCT_NAME="${PRODUCT_NAME:-$APP_NAME}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-$APP_NAME}"
BUNDLE_ID="${BUNDLE_ID:-com.elixirevo.MenuBox}"
APP_VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")}"
APP_BUILD="${APP_BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Resources/Info.plist")}"
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
cd "$ROOT_DIR"

"$ROOT_DIR/scripts/generate_app_icon.sh"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
swift build -c release --arch "$ARCH" --sdk "$SDK_PATH" \
  -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$SDK_VERSION"
BIN_PATH="$(swift build -c release --arch "$ARCH" --show-bin-path)"

if [[ ! -f "$BIN_PATH/$EXECUTABLE_NAME" ]]; then
  echo "Executable not found: $BIN_PATH/$EXECUTABLE_NAME"
  echo "Set EXECUTABLE_NAME when it differs from APP_NAME."
  exit 1
fi

cp "$BIN_PATH/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

BUILD_METADATA="$(xcrun vtool -show-build "$MACOS_DIR/$EXECUTABLE_NAME")"
ACTUAL_MINOS="$(awk '/minos / {print $2; exit}' <<< "$BUILD_METADATA")"
ACTUAL_SDK="$(awk '/sdk / {print $2; exit}' <<< "$BUILD_METADATA")"
canonical_version() { sed -E 's/(\.0)+$//' <<< "$1"; }
if [[ "$(canonical_version "$ACTUAL_MINOS")" != "$(canonical_version "$MIN_MACOS")" ||
      "$(canonical_version "$ACTUAL_SDK")" != "$(canonical_version "$SDK_VERSION")" ]]; then
  echo "Unexpected deployment metadata: minos=$ACTUAL_MINOS sdk=$ACTUAL_SDK"
  exit 1
fi

# SwiftPM's generated accessors resolve these from Contents/Resources in a .app.
for bundle in MenuBox_MenuBox MacAppEssentials_MacAppSettings MacAppEssentials_MacAppMainMenu; do
  if [[ ! -d "$BIN_PATH/$bundle.bundle" ]]; then
    echo "Required resource bundle missing: $bundle.bundle"
    exit 1
  fi
  ditto "$BIN_PATH/$bundle.bundle" "$RESOURCES_DIR/$bundle.bundle"
done


# Sentry is statically linked; package its privacy resource without embedding
# the static framework as a runtime dependency.
SENTRY_RESOURCES="$BIN_PATH/Sentry.framework/Resources"
if [[ ! -f "$SENTRY_RESOURCES/PrivacyInfo.xcprivacy" ]]; then
  echo "Sentry privacy manifest missing: $SENTRY_RESOURCES"
  exit 1
fi
SENTRY_BUNDLE="$RESOURCES_DIR/SentryResources.bundle/Contents"
mkdir -p "$SENTRY_BUNDLE/Resources"
cp "$SENTRY_RESOURCES/PrivacyInfo.xcprivacy" "$SENTRY_BUNDLE/Resources/"
cat > "$SENTRY_BUNDLE/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.sentry.MenuBoxResources</string>
<key>CFBundleName</key><string>SentryResources</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST

# Retain matching symbols per release/build/architecture, outside the shipped app.
DSYM_DIR="$DIST_DIR/symbols/$PRODUCT_NAME-$APP_VERSION-$APP_BUILD-$ARCH.app.dSYM"
mkdir -p "$(dirname "$DSYM_DIR")"
rm -rf "$DSYM_DIR"
if [[ -d "$BIN_PATH/$EXECUTABLE_NAME.dSYM" ]]; then
  ditto "$BIN_PATH/$EXECUTABLE_NAME.dSYM" "$DSYM_DIR"
else
  xcrun dsymutil "$BIN_PATH/$EXECUTABLE_NAME" -o "$DSYM_DIR"
fi
BINARY_UUIDS="$(xcrun dwarfdump --uuid "$MACOS_DIR/$EXECUTABLE_NAME" | awk '{print $2}' | sort)"
SYMBOL_UUIDS="$(xcrun dwarfdump --uuid "$DSYM_DIR" | awk '{print $2}' | sort)"
if [[ -z "$BINARY_UUIDS" || "$BINARY_UUIDS" != "$SYMBOL_UUIDS" ]]; then
  echo "App and dSYM UUIDs do not match."
  exit 1
fi

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
