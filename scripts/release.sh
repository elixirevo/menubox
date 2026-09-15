#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="${APP_NAME:-MenuBox}"
PRODUCT_NAME="${PRODUCT_NAME:-$APP_NAME}"
APP_VERSION="${APP_VERSION:-1.1.0}"
APP_BUILD="${APP_BUILD:-110}"
APP_BUILD_ARM64="${APP_BUILD_ARM64:-111}"
APP_BUILD_X86_64="${APP_BUILD_X86_64:-110}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-elixirevo/menubox}"
RELEASE_TAG="${RELEASE_TAG:-}"
CASK_TOKEN="${CASK_TOKEN:-menubox}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APPCAST_ARCHIVE_DIR="${APPCAST_ARCHIVE_DIR:-$DIST_DIR/appcast}"
GENERATE_APPCAST="${GENERATE_APPCAST:-1}"
DRY_RUN="${DRY_RUN:-0}"
CLEAN_BUILD_ARTIFACTS_AFTER_RELEASE="${CLEAN_BUILD_ARTIFACTS_AFTER_RELEASE:-1}"

if [[ -z "$APP_VERSION" ]]; then
  echo "Set APP_VERSION before releasing."
  exit 1
fi

if [[ -z "$RELEASE_TAG" ]]; then
  RELEASE_TAG="v$APP_VERSION"
fi

if [[ -z "$GITHUB_REPOSITORY" ]]; then
  GITHUB_REPOSITORY="$(git -C "$ROOT_DIR" config --get remote.origin.url | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##' || true)"
fi

if [[ -z "$GITHUB_REPOSITORY" ]]; then
  echo "Set GITHUB_REPOSITORY as owner/repo."
  exit 1
fi

if [[ -n "${HOMEBREW_TAP_DIR:-}" ]]; then
  TAP_DIR="$HOMEBREW_TAP_DIR"
elif [[ -d "$ROOT_DIR/homebrew-tap" ]]; then
  TAP_DIR="$ROOT_DIR/homebrew-tap"
elif [[ -d "$ROOT_DIR/../homebrew-tap" ]]; then
  TAP_DIR="$ROOT_DIR/../homebrew-tap"
else
  echo "Unable to find homebrew-tap. Set HOMEBREW_TAP_DIR."
  exit 1
fi

CASK_PATH="$TAP_DIR/Casks/$CASK_TOKEN.rb"

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY_RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

for arch in arm64 x86_64; do
  build_env=(
    APP_NAME="$APP_NAME"
    PRODUCT_NAME="$PRODUCT_NAME"
    APP_VERSION="$APP_VERSION"
    SIGN_IDENTITY="$SIGN_IDENTITY"
    ARCH="$arch"
  )

  arch_build=""
  case "$arch" in
    arm64)
      arch_build="$APP_BUILD_ARM64"
      ;;
    x86_64)
      arch_build="$APP_BUILD_X86_64"
      ;;
  esac

  if [[ -n "$arch_build" ]]; then
    build_env+=(APP_BUILD="$arch_build")
  elif [[ -n "$APP_BUILD" ]]; then
    build_env+=(APP_BUILD="$APP_BUILD")
  fi

  run env "${build_env[@]}" bash "$ROOT_DIR/scripts/build_dmg.sh" "$arch"
done

ARM_DMG="$DIST_DIR/${APP_NAME}-${APP_VERSION}-arm64.dmg"
INTEL_DMG="$DIST_DIR/${APP_NAME}-${APP_VERSION}-x86_64.dmg"

if [[ "$DRY_RUN" != "1" ]]; then
  test -f "$ARM_DMG"
  test -f "$INTEL_DMG"
fi

ARM_SHA256="$(shasum -a 256 "$ARM_DMG" | awk '{print $1}')"
INTEL_SHA256="$(shasum -a 256 "$INTEL_DMG" | awk '{print $1}')"

NOTES_FILE="${RELEASE_NOTES_FILE:-$DIST_DIR/release-notes-$APP_VERSION.md}"
if [[ -z "${RELEASE_NOTES_FILE:-}" ]]; then
  mkdir -p "$DIST_DIR"
  PREVIOUS_TAG="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
  {
    printf '# %s %s\n\n' "$PRODUCT_NAME" "$APP_VERSION"
    printf '## Changes\n\n'
    if [[ -n "$PREVIOUS_TAG" ]]; then
      git -C "$ROOT_DIR" log --pretty=format:'- %s' "$PREVIOUS_TAG..HEAD"
    else
      git -C "$ROOT_DIR" log --pretty=format:'- %s' --max-count=20
    fi
    printf '\n\n## Downloads\n\n'
    printf -- '- Apple Silicon: `%s`\n' "$(basename "$ARM_DMG")"
    printf -- '- Intel: `%s`\n' "$(basename "$INTEL_DMG")"
  } > "$NOTES_FILE"
fi

if [[ "$GENERATE_APPCAST" == "1" ]]; then
  mkdir -p "$APPCAST_ARCHIVE_DIR"
  cp "$NOTES_FILE" "$APPCAST_ARCHIVE_DIR/$(basename "$ARM_DMG" .dmg).md"
  cp "$NOTES_FILE" "$APPCAST_ARCHIVE_DIR/$(basename "$INTEL_DMG" .dmg).md"
fi

if [[ "$GENERATE_APPCAST" == "1" && -x "$ROOT_DIR/scripts/generate_appcast.sh" ]]; then
  run env \
    APP_NAME="$APP_NAME" \
    APP_VERSION="$APP_VERSION" \
    GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
    RELEASE_TAG="$RELEASE_TAG" \
    APPCAST_ARCHIVE_DIR="$APPCAST_ARCHIVE_DIR" \
    RELEASE_NOTES_FILE="$NOTES_FILE" \
    bash "$ROOT_DIR/scripts/generate_appcast.sh"
fi

ASSETS=("$ARM_DMG" "$INTEL_DMG")
if [[ -f "$APPCAST_ARCHIVE_DIR/appcast.xml" ]]; then
  ASSETS+=("$APPCAST_ARCHIVE_DIR/appcast.xml")
fi

if [[ "$DRY_RUN" != "1" ]]; then
  if ! git -C "$ROOT_DIR" rev-parse "$RELEASE_TAG" >/dev/null 2>&1; then
    run git -C "$ROOT_DIR" tag -a "$RELEASE_TAG" -m "$PRODUCT_NAME $APP_VERSION"
  fi
  run git -C "$ROOT_DIR" push origin "$RELEASE_TAG"

  if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    run gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --title "$PRODUCT_NAME $APP_VERSION" --notes-file "$NOTES_FILE"
    run gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --clobber "${ASSETS[@]}"
  else
    run gh release create "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --title "$PRODUCT_NAME $APP_VERSION" --notes-file "$NOTES_FILE" "${ASSETS[@]}"
  fi
fi

run python3 "$SCRIPT_DIR/update_cask.py" \
  --cask "$CASK_PATH" \
  --token "$CASK_TOKEN" \
  --app-name "$APP_NAME" \
  --version "$APP_VERSION" \
  --repository "$GITHUB_REPOSITORY" \
  --arm-sha256 "$ARM_SHA256" \
  --intel-sha256 "$INTEL_SHA256"

if [[ "$DRY_RUN" != "1" ]]; then
  run brew audit --cask "$CASK_TOKEN"
  run brew style --cask "$CASK_TOKEN"
  run git -C "$TAP_DIR" add "Casks/$CASK_TOKEN.rb"
  if ! git -C "$TAP_DIR" diff --cached --quiet; then
    run git -C "$TAP_DIR" commit -m "Update $CASK_TOKEN to $APP_VERSION"
    run git -C "$TAP_DIR" push
  else
    echo "No Homebrew cask changes to commit."
  fi
fi

if [[ "$DRY_RUN" != "1" && "$CLEAN_BUILD_ARTIFACTS_AFTER_RELEASE" == "1" ]]; then
  CLEANUP_SCRIPT="$SCRIPT_DIR/cleanup_build_artifacts.sh"
  if [[ -f "$CLEANUP_SCRIPT" ]]; then
    run bash "$CLEANUP_SCRIPT" "$ROOT_DIR"
  else
    echo "Build artifact cleanup skipped: $CLEANUP_SCRIPT was not found."
  fi
fi

echo "Release complete: $RELEASE_TAG"
