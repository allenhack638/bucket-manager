#!/bin/bash
# Runs the complete local verification suite.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
TRANSFER_QUEUE=$(mktemp /tmp/bm-ui-transfer-queue.XXXXXX)
rm -f "$TRANSFER_QUEUE"
trap 'rm -f "$TRANSFER_QUEUE"' EXIT
S3C_TRANSFER_QUEUE_STATE="$TRANSFER_QUEUE" .build/debug/BucketManager --uitest
./scripts/run-e2e.sh
