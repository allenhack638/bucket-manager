#!/bin/bash
# Full end-to-end suite: real AWS SDK + BrowserModel against a local fake S3.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types >/dev/null
LOG=/tmp/s3c-e2e-server.log
LOG2=/tmp/s3c-e2e-server-2.log
APP_LOG=/tmp/s3c-e2e-app.log
rm -f "$LOG" "$LOG2" "$APP_LOG"
STATE=$(mktemp /tmp/s3c-multipart-state.XXXXXX)
LOGDIR=$(mktemp -d /tmp/s3c-logs.XXXXXX)
METRICS=$(mktemp /tmp/s3c-metrics.XXXXXX)
TRANSFER_QUEUE=$(mktemp /tmp/s3c-transfer-queue.XXXXXX)
TEMP_REGISTRY=$(mktemp /tmp/s3c-temp-registry.XXXXXX)
SETTINGS_SUITE="BucketManagerE2ESettings.$$"
rm -f "$STATE" "$METRICS" "$TRANSFER_QUEUE" "$TEMP_REGISTRY"
PYTHONUNBUFFERED=1 FAKE_MULTIPART_DELAY=0.25 FAKE_MULTIPART_STAGGER=1 python3 scripts/fake_s3.py 0 >"$LOG" 2>&1 &
SERVER=$!
PYTHONUNBUFFERED=1 FAKE_MULTIPART_DELAY=0.25 FAKE_MULTIPART_STAGGER=1 python3 scripts/fake_s3.py 0 >"$LOG2" 2>&1 &
SERVER2=$!
trap 'kill "$SERVER" "$SERVER2" 2>/dev/null || true; rm -rf "$STATE" "$LOGDIR" "$METRICS" "$TRANSFER_QUEUE" "$TEMP_REGISTRY" "$APP_LOG" "$LOG2"; defaults delete "$SETTINGS_SUITE" >/dev/null 2>&1 || true' EXIT

PORT=""
PORT2=""
for _ in $(seq 1 300); do
  PORT=$(grep -o 'LISTENING [0-9]*' "$LOG" 2>/dev/null | awk '{print $2}' | tail -1 || true)
  PORT2=$(grep -o 'LISTENING [0-9]*' "$LOG2" 2>/dev/null | awk '{print $2}' | tail -1 || true)
  [ -n "$PORT" ] && [ -n "$PORT2" ] && break
  sleep 0.1
done
if [ -z "$PORT" ] || [ -z "$PORT2" ]; then
  cat "$LOG"
  cat "$LOG2"
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

echo "E2E starting"
python3 - "$PORT" "$PORT2" "$APP_LOG" <<'PY'
import os, subprocess, sys, time
port, port2, log_path = sys.argv[1], sys.argv[2], sys.argv[3]
cmd = [".build/debug/BucketManager", "--e2e", port, "--e2e-second", port2]
start = time.time()
try:
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=240)
    output = p.stdout or ""
    status = p.returncode
except subprocess.TimeoutExpired as e:
    output = (e.stdout or "") if isinstance(e.stdout, str) else (e.stdout or b"").decode("utf-8", "replace")
    output += "\nE2E TIMEOUT after 240s\n"
    status = 1
open(log_path, "w").write(output)
sys.stdout.write(output)
sys.stdout.write(f"E2E exit status: {status} after {time.time()-start:.1f}s\n")
raise SystemExit(0 if status == 0 else 1)
PY
STATUS=$?
echo "--- fake S3 log ---"
cat "$LOG"
echo "--- fake S3 secondary log ---"
cat "$LOG2"
exit "$STATUS"
