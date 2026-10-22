#!/bin/bash
# Full end-to-end suite: real AWS SDK + BrowserModel against a local fake S3.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build >/dev/null
LOG=/tmp/s3c-e2e-server.log
rm -f "$LOG"
STATE=$(mktemp /tmp/s3c-multipart-state.XXXXXX)
LOGDIR=$(mktemp -d /tmp/s3c-logs.XXXXXX)
METRICS=$(mktemp /tmp/s3c-metrics.XXXXXX)
SETTINGS_SUITE="BucketManagerE2ESettings.$$"
rm -f "$STATE" "$METRICS"
FAKE_MULTIPART_DELAY=0.3 python3 scripts/fake_s3.py 0 >"$LOG" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true; rm -rf "$STATE" "$LOGDIR" "$METRICS"; defaults delete "$SETTINGS_SUITE" >/dev/null 2>&1 || true' EXIT

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

S3C_MULTIPART_PART_SIZE=5242880 S3C_MULTIPART_STATE="$STATE" \
S3C_LOG_DIR="$LOGDIR" S3C_METRICS_FILE="$METRICS" \
S3C_LOG_SETTINGS_SUITE="$SETTINGS_SUITE" \
    .build/debug/BucketManager --e2e "$PORT"
