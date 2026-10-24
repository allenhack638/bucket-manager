#!/bin/bash
set -euo pipefail

TARGET="${1:-/tmp/bucket-manager-acceptance.env}"

read -r -p "S3 endpoint (https://...): " endpoint
read -r -p "Region: " region
read -r -p "Access key ID: " access_key
read -r -s -p "Secret access key: " secret
echo
read -r -p "Disposable bucket: " bucket
read -r -p "Second bucket for cross-account tests (optional): " bucket_2
read -r -p "Use path-style addressing? [Y/n]: " path_style

case "${path_style:-Y}" in
  [nN]*) path_style=0 ;;
  *) path_style=1 ;;
esac

umask 077
{
  printf "BM_ACCEPT_ENDPOINT=%q\n" "$endpoint"
  printf "BM_ACCEPT_REGION=%q\n" "$region"
  printf "BM_ACCEPT_ACCESS_KEY=%q\n" "$access_key"
  printf "BM_ACCEPT_SECRET=%q\n" "$secret"
  printf "BM_ACCEPT_BUCKET=%q\n" "$bucket"
  printf "BM_ACCEPT_BUCKET_2=%q\n" "$bucket_2"
  printf "BM_ACCEPT_PATH_STYLE=%q\n" "$path_style"
} > "$TARGET"
chmod 600 "$TARGET"

echo "Wrote $TARGET" 
echo "Run: set -a; source \"$TARGET\"; set +a; ./scripts/run-acceptance.sh"
