#!/bin/bash
# Runs the complete local verification suite.
set -euo pipefail
cd "$(dirname "$0")/.."

# Swift 6.2 compiler workaround for debug type round-trip crash in UI tests.
swift build -Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types
TRANSFER_QUEUE=$(mktemp /tmp/bm-ui-transfer-queue.XXXXXX)
TEMP_REGISTRY=$(mktemp /tmp/bm-ui-temp-registry.XXXXXX)
rm -f "$TRANSFER_QUEUE" "$TEMP_REGISTRY"
trap 'rm -f "$TRANSFER_QUEUE" "$TEMP_REGISTRY"' EXIT
S3C_TRANSFER_QUEUE_STATE="$TRANSFER_QUEUE" S3C_DOWNLOAD_TEMP_REGISTRY="$TEMP_REGISTRY" .build/debug/BucketManager --uitest
./scripts/run-e2e.sh
