#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:?Usage: notarize.sh <app-or-dmg> <arch>}"
ARCH="${2:?Specify the architecture for separate submission logs}"
PROFILE="${NOTARY_PROFILE:-menubox}"
LOG_DIR="${DIST_DIR:-$ROOT_DIR/dist}/notarization"
mkdir -p "$LOG_DIR"
NAME="$(basename "$TARGET")-$ARCH"
UPLOAD="$TARGET"

codesign --verify --deep --strict "$TARGET"
if [[ "$TARGET" == *.app ]]; then
  UPLOAD="$LOG_DIR/$NAME.zip"
  ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$UPLOAD"
fi

# Save the submission ID before waiting so an interrupted run can be resumed.
xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" \
  --output-format json > "$LOG_DIR/$NAME-submission.json"
SUBMISSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$LOG_DIR/$NAME-submission.json")"
echo "Notarization submitted: $NAME ($SUBMISSION_ID)"
xcrun notarytool wait "$SUBMISSION_ID" --keychain-profile "$PROFILE" \
  --output-format json > "$LOG_DIR/$NAME-result.json"
xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" "$LOG_DIR/$NAME-log.json"
python3 - "$LOG_DIR/$NAME-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get("status") != "Accepted":
    raise SystemExit(f"Notarization was not accepted: {result}")
PY
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
if [[ "$TARGET" == *.app ]]; then
  spctl --assess --type execute --verbose=2 "$TARGET"
else
  spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
fi
