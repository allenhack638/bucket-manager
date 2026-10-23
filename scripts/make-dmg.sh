#!/bin/bash
set -euo pipefail

APP_PATH="${1:-build/Bucket Manager.app}"
OUTPUT_PATH="${2:-build/BucketManager.dmg}"
VOLUME_NAME="${3:-Bucket Manager}"

if [ ! -d "$APP_PATH" ]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

STAGE="$(mktemp -d /tmp/bucketmanager-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP_PATH" "$STAGE/Bucket Manager.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$OUTPUT_PATH"

shasum -a 256 "$OUTPUT_PATH" > "$OUTPUT_PATH.sha256"
echo "Created $OUTPUT_PATH"
cat "$OUTPUT_PATH.sha256"
