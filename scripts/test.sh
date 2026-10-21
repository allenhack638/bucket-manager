#!/bin/bash
# Runs the complete local verification suite.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
.build/debug/BucketManager --uitest
./scripts/run-e2e.sh
