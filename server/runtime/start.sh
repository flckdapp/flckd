#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-serve}" != serve && "${1:-}" != control ]]; then
  exec /bin/bash "$@"
fi
if [[ "${BUILDER_ENABLED:-true}" == false ]]; then
  exec bun /opt/flckd/backend/index.ts
fi
mkdir -p "$DATA_DIR/control" "$DATA_DIR/work" "$DOCROOT"
chmod 700 "$DATA_DIR/control"
exec 9>"$DATA_DIR/control/instance.lock"
flock -n 9 || { printf 'Another builder is using this data directory.\n' >&2; exit 1; }
for asset in index.html logo.png; do
  cp "/opt/flckd/site/$asset" "$DOCROOT/.$asset.tmp"
  mv "$DOCROOT/.$asset.tmp" "$DOCROOT/$asset"
done
exec bun /opt/flckd/backend/index.ts
