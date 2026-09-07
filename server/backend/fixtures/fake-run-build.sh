#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$DOCROOT/v1" "$(dirname "$STATUS_FILE")"
echo '{"build_id":"'"$BUILD_ID"'","stage":"publish","detail":"local site ready","local_published":true,"remote_published":false}' > "$STATUS_FILE"
cat > "$DOCROOT/v1/manifest.json" <<JSON
{"build_id":"$BUILD_ID","packs":[{"id":"${1:-oklahoma}"}]}
JSON
printf 'building %s with %s\n' "${1:-all}" "$S3_SECRET_ACCESS_KEY"
