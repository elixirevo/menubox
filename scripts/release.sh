#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
APP_VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
APP_BUILD_X86_64="${APP_BUILD_X86_64:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)}"
APP_BUILD_ARM64="${APP_BUILD_ARM64:-$((APP_BUILD_X86_64 + 1))}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-elixirevo/menubox}"
RELEASE_TAG="${RELEASE_TAG:-v$APP_VERSION}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APPCAST_ARCHIVE_DIR="$DIST_DIR/appcast-$APP_VERSION"
TAP_DIR="${HOMEBREW_TAP_DIR:-$ROOT_DIR/../homebrew-tap}"
NOTES_FILE="${RELEASE_NOTES_FILE:-$ROOT_DIR/docs/releases/$APP_VERSION.md}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-menubox}"
NOTARY_PROFILE="${NOTARY_PROFILE:-menubox}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
PHASE="${RELEASE_PHASE:-prepare}"
export APP_VERSION APP_BUILD_ARM64 APP_BUILD_X86_64 GITHUB_REPOSITORY RELEASE_TAG DIST_DIR
export APPCAST_ARCHIVE_DIR SPARKLE_KEY_ACCOUNT NOTARY_PROFILE SIGN_IDENTITY

if [[ "$PHASE" != "prepare" && "$PHASE" != "publish" ]]; then
  echo "RELEASE_PHASE must be prepare or publish."
  exit 1
fi
test -f "$NOTES_FILE"
test -f "$TAP_DIR/Casks/menubox.rb"

if [[ "$PHASE" == "prepare" ]]; then
  if [[ "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "Set SIGN_IDENTITY to a valid Developer ID Application identity."
    exit 1
  fi
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null
  KEY_TOOL="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
  test -x "$KEY_TOOL"
  EXPECTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)"
  if [[ "$("$KEY_TOOL" --account "$SPARKLE_KEY_ACCOUNT" -p)" != "$EXPECTED_KEY" ]]; then
    echo "Sparkle keychain public key does not match Resources/Info.plist."
    exit 1
  fi
  if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    for arch in arm64 x86_64; do
      if [[ "$arch" == "arm64" ]]; then build="$APP_BUILD_ARM64"; else build="$APP_BUILD_X86_64"; fi
      APP_BUILD="$build" SIGN_DMG=1 NOTARIZE=1 bash scripts/build_dmg.sh "$arch"
    done
  fi
  for arch in arm64 x86_64; do
    dmg="$DIST_DIR/MenuBox-$APP_VERSION-$arch.dmg"
    codesign --verify --strict "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature "$dmg"
    mkdir -p "$APPCAST_ARCHIVE_DIR"
    cp "$NOTES_FILE" "$APPCAST_ARCHIVE_DIR/MenuBox-$APP_VERSION-$arch.md"
  done
  bash scripts/generate_appcast.sh
  ARM_SHA256="$(shasum -a 256 "$DIST_DIR/MenuBox-$APP_VERSION-arm64.dmg" | awk '{print $1}')"
  INTEL_SHA256="$(shasum -a 256 "$DIST_DIR/MenuBox-$APP_VERSION-x86_64.dmg" | awk '{print $1}')"
  for cask in "$ROOT_DIR/homebrew/Casks/menubox.rb" "$TAP_DIR/Casks/menubox.rb"; do
    python3 scripts/update_cask.py --cask "$cask" --token menubox --app-name MenuBox \
      --version "$APP_VERSION" --repository "$GITHUB_REPOSITORY" \
      --arm-sha256 "$ARM_SHA256" --intel-sha256 "$INTEL_SHA256"
  done
  (cd "$DIST_DIR" && shasum -a 256 "MenuBox-$APP_VERSION-arm64.dmg" "MenuBox-$APP_VERSION-x86_64.dmg" > SHA256SUMS.txt)
fi

python3 scripts/validate_release.py --dist "$DIST_DIR" --version "$APP_VERSION" \
  --account "$SPARKLE_KEY_ACCOUNT" --repository "$GITHUB_REPOSITORY" --tag "$RELEASE_TAG"
cmp "$ROOT_DIR/homebrew/Casks/menubox.rb" "$TAP_DIR/Casks/menubox.rb"
bash scripts/audit_cask.sh "$TAP_DIR"

if [[ "$PHASE" == "prepare" ]]; then
  echo "Prepared and validated $RELEASE_TAG. Commit the app changes, then run RELEASE_PHASE=publish."
  exit 0
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit app changes before publishing so the release tag matches the artifacts."
  exit 1
fi
if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "Release already exists; refusing to overwrite published artifacts."
  exit 1
fi
if git rev-parse "$RELEASE_TAG" >/dev/null 2>&1; then
  test "$(git rev-parse "$RELEASE_TAG^{commit}")" = "$(git rev-parse HEAD)"
else
  git tag -a "$RELEASE_TAG" -m "MenuBox $APP_VERSION"
fi
git push origin HEAD
git push origin "$RELEASE_TAG"
gh release create "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --verify-tag --draft \
  --title "MenuBox $APP_VERSION" --notes-file "$NOTES_FILE" \
  "$DIST_DIR/MenuBox-$APP_VERSION-arm64.dmg" "$DIST_DIR/MenuBox-$APP_VERSION-x86_64.dmg" \
  "$APPCAST_ARCHIVE_DIR/menubox-appcast.xml" "$APPCAST_ARCHIVE_DIR/appcast.xml" "$DIST_DIR/SHA256SUMS.txt"
gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --draft=false --latest

# Commit the rename metadata and cask together so existing installations can migrate.
git -C "$TAP_DIR" add -A -- Casks cask_renames.json README.md
if ! git -C "$TAP_DIR" diff --cached --quiet; then
  git -C "$TAP_DIR" commit -m "menubox $APP_VERSION: renamed from status-box"
fi
git -C "$TAP_DIR" push
echo "Published MenuBox $APP_VERSION to GitHub and Homebrew."
