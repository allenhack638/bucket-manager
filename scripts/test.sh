#!/bin/bash
# Runs the complete local verification suite.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
TRANSFER_QUEUE=$(mktemp /tmp/bm-ui-transfer-queue.XXXXXX)
TEMP_REGISTRY=$(mktemp /tmp/bm-ui-temp-registry.XXXXXX)
rm -f "$TRANSFER_QUEUE" "$TEMP_REGISTRY"
trap 'rm -f "$TRANSFER_QUEUE" "$TEMP_REGISTRY"' EXIT
S3C_TRANSFER_QUEUE_STATE="$TRANSFER_QUEUE" S3C_DOWNLOAD_TEMP_REGISTRY="$TEMP_REGISTRY" .build/debug/BucketManager --uitest
./scripts/run-e2e.sh
