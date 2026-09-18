#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_PUBLIC_ED_KEY_FILE="${SPARKLE_PUBLIC_ED_KEY_FILE:-$ROOT_DIR/sparkle-public-key.txt}"
SPARKLE_GENERATE_KEYS="${SPARKLE_GENERATE_KEYS:-}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-menubox}"

find_sparkle_tool() {
  local tool_name="$1"
  if [[ -d "$ROOT_DIR/.build" ]]; then
    find "$ROOT_DIR/.build" -type f -name "$tool_name" | sort | head -n 1
  fi
}

if [[ -f "$SPARKLE_PUBLIC_ED_KEY_FILE" && "${FORCE:-0}" != "1" ]]; then
  echo "Sparkle public key already exists: $SPARKLE_PUBLIC_ED_KEY_FILE"
  echo "Use FORCE=1 $0 to generate a new key pair."
  exit 0
fi

if [[ -z "$SPARKLE_GENERATE_KEYS" ]]; then
  SPARKLE_GENERATE_KEYS="$(find_sparkle_tool generate_keys || true)"
fi

if [[ -z "$SPARKLE_GENERATE_KEYS" || ! -x "$SPARKLE_GENERATE_KEYS" ]]; then
  echo "Sparkle generate_keys was not found. Resolving package first..."
  swift build
  SPARKLE_GENERATE_KEYS="$(find_sparkle_tool generate_keys || true)"
fi

if [[ -z "$SPARKLE_GENERATE_KEYS" || ! -x "$SPARKLE_GENERATE_KEYS" ]]; then
  echo "Unable to find Sparkle generate_keys under .build."
  echo "Set SPARKLE_GENERATE_KEYS=/path/to/generate_keys and retry."
  exit 1
fi

OUTPUT="$("$SPARKLE_GENERATE_KEYS" --account "$SPARKLE_KEY_ACCOUNT")"
printf '%s\n' "$OUTPUT"

PUBLIC_KEY="$(printf '%s\n' "$OUTPUT" | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p' | head -n 1)"

if [[ -z "$PUBLIC_KEY" ]]; then
  echo "Unable to parse SUPublicEDKey from generate_keys output."
  exit 1
fi

printf '%s\n' "$PUBLIC_KEY" > "$SPARKLE_PUBLIC_ED_KEY_FILE"
echo "Sparkle public key saved: $SPARKLE_PUBLIC_ED_KEY_FILE"
echo "Keep the private key in Keychain backed up; it is required to sign future updates."
