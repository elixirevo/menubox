#!/usr/bin/env bash
set -euo pipefail
export HOMEBREW_NO_AUTO_UPDATE=1

TAP_DIR="${1:?Usage: audit_cask.sh <tap-checkout>}"
CHECK_TAP="elixirevo/menubox-release-check"
if brew tap | grep -qx "$CHECK_TAP"; then
  echo "Temporary audit tap already exists: $CHECK_TAP"
  exit 1
fi
# Current Homebrew accepts cask names for audit, not filesystem paths.
# Use an isolated tap to avoid changing the user's installed cask or tap checkout.
brew tap --custom-remote "$CHECK_TAP" "$TAP_DIR"
CHECK_DIR="$(brew --repository "$CHECK_TAP")"
# Only the cask under review belongs in this disposable tap.
find "$CHECK_DIR/Casks" -type f -name '*.rb' -delete
cp "$TAP_DIR/Casks/menubox.rb" "$CHECK_DIR/Casks/menubox.rb"
cp "$TAP_DIR/cask_renames.json" "$CHECK_DIR/cask_renames.json"
cleanup() {
  brew untap "$CHECK_TAP" >/dev/null
  brew untrust --cask "$CHECK_TAP/menubox" >/dev/null
}
trap cleanup EXIT
brew trust --cask "$CHECK_TAP/menubox"
brew audit --cask "$CHECK_TAP/menubox"
brew style "$CHECK_DIR/Casks/menubox.rb"
brew info --json=v2 --cask "$CHECK_TAP/status-box" | python3 -c '
import json, sys
cask = json.load(sys.stdin)["casks"][0]
assert cask["token"] == "menubox"
assert "status-box" in cask["old_tokens"]
print("Homebrew resolves status-box to menubox.")
'
