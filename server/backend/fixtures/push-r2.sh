#!/usr/bin/env bash
set -euo pipefail

if [ "${S3_ENDPOINT:-}" = "https://fail.invalid" ]; then
  echo '{"build_id":"'"$BUILD_ID"'","stage":"upload","detail":"remote failed","local_published":true,"remote_published":false}' > "$STATUS_FILE"
  printf 'upload failed for %s using %s\n' "$S3_BUCKET" "$S3_SECRET_ACCESS_KEY" >&2
  exit 42
fi
echo '{"build_id":"'"$BUILD_ID"'","stage":"done","detail":"uploaded","local_published":true,"remote_published":true}' > "$STATUS_FILE"
printf 'uploaded %s with %s\n' "$S3_BUCKET" "$S3_SECRET_ACCESS_KEY"
