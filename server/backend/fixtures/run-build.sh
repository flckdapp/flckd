#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$DOCROOT/v1" "$(dirname "$STATUS_FILE")"
echo '{"build_id":"'"$BUILD_ID"'","stage":"publish","detail":"local site ready","local_published":true,"remote_published":false}' > "$STATUS_FILE"
if [ "${1:-}" = "--cameras-only" ]; then
  [ -f "$DOCROOT/v1/manifest.json" ] || exit 3
  sed -i.bak 's/}$/,"speed_cameras":{"build_id":"'"$BUILD_ID"'"}}/' "$DOCROOT/v1/manifest.json"
  rm -f "$DOCROOT/v1/manifest.json.bak"
  printf 'refreshing speed cameras with %s\n' "${S3_SECRET_ACCESS_KEY:-}"
  exit 0
fi
sleep 1
cat > "$DOCROOT/v1/manifest.json" <<JSON
{"build_id":"$BUILD_ID","packs":[{"id":"${1:-oklahoma}"}]}
JSON
printf 'building %s with %s cameras=%s\n' "${1:-all}" "${S3_SECRET_ACCESS_KEY:-}" "${SPEED_CAMERAS:-unset}"
