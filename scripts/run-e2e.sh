#!/bin/bash
# Full end-to-end suite: real AWS SDK + BrowserModel against a local fake S3.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types >/dev/null
LOG=/tmp/s3c-e2e-server.log
APP_LOG=/tmp/s3c-e2e-app.log
rm -f "$LOG" "$APP_LOG"
STATE=$(mktemp /tmp/s3c-multipart-state.XXXXXX)
LOGDIR=$(mktemp -d /tmp/s3c-logs.XXXXXX)
METRICS=$(mktemp /tmp/s3c-metrics.XXXXXX)
TRANSFER_QUEUE=$(mktemp /tmp/s3c-transfer-queue.XXXXXX)
TEMP_REGISTRY=$(mktemp /tmp/s3c-temp-registry.XXXXXX)
SETTINGS_SUITE="BucketManagerE2ESettings.$$"
rm -f "$STATE" "$METRICS" "$TRANSFER_QUEUE" "$TEMP_REGISTRY"
FAKE_MULTIPART_DELAY=0.25 FAKE_MULTIPART_STAGGER=1 python3 scripts/fake_s3.py 0 >"$LOG" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true; rm -rf "$STATE" "$LOGDIR" "$METRICS" "$TRANSFER_QUEUE" "$TEMP_REGISTRY" "$APP_LOG"; defaults delete "$SETTINGS_SUITE" >/dev/null 2>&1 || true' EXIT

PORT=""
for _ in $(seq 1 50); do
  PORT=$(grep -o 'LISTENING [0-9]*' "$LOG" 2>/dev/null | awk '{print $2}' | tail -1 || true)
  [ -n "$PORT" ] && break
  sleep 0.1
done
if [ -z "$PORT" ]; then
  cat "$LOG"
  exit 1
fi

export S3C_MULTIPART_PART_SIZE=5242880
export S3C_MULTIPART_STATE="$STATE"
export S3C_LOG_DIR="$LOGDIR"
export S3C_METRICS_FILE="$METRICS"
export S3C_LOG_SETTINGS_SUITE="$SETTINGS_SUITE"
export S3C_TRANSFER_QUEUE_STATE="$TRANSFER_QUEUE"
export S3C_DOWNLOAD_TEMP_REGISTRY="$TEMP_REGISTRY"
export NO_PROXY=127.0.0.1,localhost
export no_proxy=127.0.0.1,localhost
export NSUnbufferedIO=YES

set +e
.build/debug/BucketManager --e2e "$PORT" 2>&1 | tee "$APP_LOG"
STATUS=${PIPESTATUS[0]}
set -e
echo "E2E exit status: $STATUS"
if [ "$STATUS" -ne 0 ]; then
    echo "--- E2E app log ---"
    cat "$APP_LOG"
    echo "--- fake S3 log ---"
    cat "$LOG"
fi
exit "$STATUS"
