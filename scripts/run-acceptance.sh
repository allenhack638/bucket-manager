#!/bin/bash
# Real S3-protocol acceptance run.
#
# Local run uses rclone's SigV4 S3 server over a temporary local backend:
#   ./scripts/run-acceptance.sh
#
# External endpoint (use a disposable bucket/prefix):
#   BM_ACCEPT_ENDPOINT=https://... BM_ACCEPT_REGION=... \
#   BM_ACCEPT_ACCESS_KEY=... BM_ACCEPT_SECRET=... \
#   BM_ACCEPT_BUCKET=disposable-bucket ./scripts/run-acceptance.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build >/dev/null

LOGDIR=$(mktemp -d /tmp/bm-acceptance-logs.XXXXXX)
METRICS=$(mktemp /tmp/bm-acceptance-metrics.XXXXXX)
MULTIPART=$(mktemp /tmp/bm-acceptance-multipart.XXXXXX)
TRANSFER_QUEUE=$(mktemp /tmp/bm-acceptance-transfer-queue.XXXXXX)
SETTINGS_SUITE="BucketManagerAcceptanceSettings.$$"
rm -f "$METRICS" "$MULTIPART" "$TRANSFER_QUEUE"
cleanup_runtime() {
  rm -rf "$LOGDIR" "$METRICS" "$MULTIPART" "$TRANSFER_QUEUE"
  defaults delete "$SETTINGS_SUITE" >/dev/null 2>&1 || true
}
trap cleanup_runtime EXIT

run_acceptance() {
  S3C_LOG_DIR="$LOGDIR" \
  S3C_METRICS_FILE="$METRICS" \
  S3C_MULTIPART_STATE="$MULTIPART" \
  S3C_LOG_SETTINGS_SUITE="$SETTINGS_SUITE" \
  S3C_TRANSFER_QUEUE_STATE="$TRANSFER_QUEUE" \
    .build/debug/BucketManager --acceptance
}

if [ -n "${BM_ACCEPT_ENDPOINT:-}" ]; then
  : "${BM_ACCEPT_ACCESS_KEY:?set BM_ACCEPT_ACCESS_KEY}"
  : "${BM_ACCEPT_SECRET:?set BM_ACCEPT_SECRET}"
  run_acceptance
  exit $?
fi

if ! command -v rclone >/dev/null 2>&1; then
  echo "rclone is required for the local acceptance run." >&2
  exit 1
fi

mkdir -p /tmp/bm-acceptance
DATA=$(mktemp -d /tmp/bm-acceptance/rclone.XXXXXX)
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
LOG=/tmp/bm-acceptance/rclone.log
rm -f "$LOG"

cleanup() {
  if [ -n "${SERVER:-}" ]; then
    kill "$SERVER" >/dev/null 2>&1 || true
    wait "$SERVER" 2>/dev/null || true
  fi
  rm -rf "$DATA"
  cleanup_runtime
}
trap cleanup EXIT

rclone serve s3 \
  --addr "127.0.0.1:$PORT" \
  --auth-key "bmadmin,$(uuidgen)" \
  ":local:$DATA" >"$LOG" 2>&1 &
SERVER=$!

for _ in $(seq 1 100); do
  if (echo >"/dev/tcp/127.0.0.1/$PORT") >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if ! (echo >"/dev/tcp/127.0.0.1/$PORT") >/dev/null 2>&1; then
  echo "rclone S3 server did not start:" >&2
  cat "$LOG" >&2 || true
  exit 1
fi

BM_ACCEPT_ENDPOINT="http://127.0.0.1:$PORT" \
BM_ACCEPT_REGION="us-east-1" \
BM_ACCEPT_ACCESS_KEY="bmadmin" \
BM_ACCEPT_SECRET="$(uuidgen)" \
BM_ACCEPT_PATH_STYLE="1" \
  run_acceptance
