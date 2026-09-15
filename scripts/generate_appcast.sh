#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-MenuBox}"
APP_VERSION="${APP_VERSION:-1.1.0}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-elixirevo/menubox}"
RELEASE_TAG="${RELEASE_TAG:-}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APPCAST_ARCHIVE_DIR="${APPCAST_ARCHIVE_DIR:-$DIST_DIR/appcast}"
SPARKLE_GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-}"
SPARKLE_MAXIMUM_VERSIONS="${SPARKLE_MAXIMUM_VERSIONS:-1}"
SPARKLE_MAXIMUM_DELTAS="${SPARKLE_MAXIMUM_DELTAS:-0}"
ARCHS="${ARCHS:-arm64 x86_64}"

if [[ -z "$APP_VERSION" ]]; then
  echo "Set APP_VERSION before generating an appcast."
  exit 1
fi

if [[ -z "$GITHUB_REPOSITORY" ]]; then
  GITHUB_REPOSITORY="$(git -C "$ROOT_DIR" config --get remote.origin.url | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##' || true)"
fi

if [[ -z "$GITHUB_REPOSITORY" ]]; then
  echo "Set GITHUB_REPOSITORY as owner/repo."
  exit 1
fi

if [[ -z "$RELEASE_TAG" ]]; then
  RELEASE_TAG="v$APP_VERSION"
fi

SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_TAG/}"
SPARKLE_PRODUCT_LINK="${SPARKLE_PRODUCT_LINK:-https://github.com/$GITHUB_REPOSITORY}"

find_sparkle_tool() {
  local tool_name="$1"
  if [[ -d "$ROOT_DIR/.build" ]]; then
    find "$ROOT_DIR/.build" -type f -name "$tool_name" | sort | head -n 1
  fi
}

if [[ -z "$SPARKLE_GENERATE_APPCAST" ]]; then
  SPARKLE_GENERATE_APPCAST="$(find_sparkle_tool generate_appcast || true)"
fi

if [[ -z "$SPARKLE_GENERATE_APPCAST" || ! -x "$SPARKLE_GENERATE_APPCAST" ]]; then
  echo "Sparkle generate_appcast was not found. Resolving package first..."
  swift build
  SPARKLE_GENERATE_APPCAST="$(find_sparkle_tool generate_appcast || true)"
fi

if [[ -z "$SPARKLE_GENERATE_APPCAST" || ! -x "$SPARKLE_GENERATE_APPCAST" ]]; then
  echo "Unable to find Sparkle generate_appcast under .build."
  echo "Set SPARKLE_GENERATE_APPCAST=/path/to/generate_appcast and retry."
  exit 1
fi

mkdir -p "$APPCAST_ARCHIVE_DIR"

for arch in $ARCHS; do
  if [[ "$arch" != "arm64" && "$arch" != "x86_64" ]]; then
    echo "Unsupported ARCH in ARCHS: $arch"
    exit 1
  fi

  dmg_path="$DIST_DIR/${APP_NAME}-${APP_VERSION}-${arch}.dmg"
  if [[ ! -f "$dmg_path" ]]; then
    echo "Missing DMG for appcast: $dmg_path"
    echo "Build arm64 and x86_64 DMGs before generating the appcast."
    exit 1
  fi
  cp "$dmg_path" "$APPCAST_ARCHIVE_DIR/"
done

"$SPARKLE_GENERATE_APPCAST" \
  --download-url-prefix "$SPARKLE_DOWNLOAD_URL_PREFIX" \
  --link "$SPARKLE_PRODUCT_LINK" \
  --maximum-versions "$SPARKLE_MAXIMUM_VERSIONS" \
  --maximum-deltas "$SPARKLE_MAXIMUM_DELTAS" \
  "$APPCAST_ARCHIVE_DIR"

echo "Appcast created: $APPCAST_ARCHIVE_DIR/appcast.xml"
