#!/usr/bin/env bash
# Push a published docroot to a Cloudflare R2 bucket.
#
# Why R2 rather than serving from home:
#
# 1. Terms. Cloudflare's Service-Specific Terms, under "Content Delivery
#    Network (Free, Pro, or Business)", reserve the right to limit or disable
#    the CDN for anyone serving "a disproportionate percentage of pictures,
#    audio files, or other large files" without a paid product such as the
#    Developer Platform. Pro and Business are covered by the same clause. R2
#    is part of the Developer Platform and carries no such restriction.
# 2. Home bandwidth. With a self-hosted origin, every edge cache miss pulls
#    from the house. R2 removes home upload entirely.
# 3. Availability. The origin becomes Cloudflare, so the build box can be off,
#    rebooting, or mid-build.
#
# Egress from R2 to the internet is free. A ~20-40 GB catalogue costs roughly
# $0.30-0.60/month in storage. Class A/B operation costs are negligible
# because the objects are immutable and cache well.
#
# What this does not change: R2 does not raise the 512 MB cacheable-object
# limit, so the 128 MB part split in publish.py is still required. Cloudflare
# still terminates TLS and still sees client IPs.
#
# Usage:  push-r2.sh [docroot]        (default $DOCROOT, else /srv/tiles)
#
# Environment (all required):
#   R2_ACCOUNT_ID          Cloudflare account id
#   R2_BUCKET              bucket name
#   R2_ACCESS_KEY_ID       R2 API token key id
#   R2_SECRET_ACCESS_KEY   R2 API token secret
# Optional:
#   WWW_DIR=/srv/www       dashboard files to upload at the bucket root
#   R2_PRUNE=0             skip deleting orphaned objects (default 1)
#   DRY_RUN=1              show what would transfer, change nothing

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DOCROOT="${1:-${DOCROOT:-/srv/tiles}}"
WWW_DIR="${WWW_DIR:-/srv/www}"
need rclone

for v in R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
  [ -n "${!v:-}" ] || die "$v is not set"
done
[ -d "$DOCROOT/v1" ] || die "no published tree at $DOCROOT/v1 - run publish.py first"
[ -f "${WWW_DIR}/logo.png" ] || die "required dashboard asset missing: ${WWW_DIR}/logo.png"
[ -f "${WWW_DIR}/index.html" ] || die "required dashboard asset missing: ${WWW_DIR}/index.html"

# Configure rclone entirely from the environment so no credentials are ever
# written to disk.
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
# R2 ignores ACLs and does not implement per-object checksum trailers the same
# way S3 does; this is Cloudflare's own documented rclone setting.
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
export RCLONE_S3_ACL=private

DEST="R2:${R2_BUCKET}"
FLAGS=(--transfers 8 --checkers 16 --fast-list --s3-chunk-size 64M --stats 30s)
[ "${DRY_RUN:-0}" = "1" ] && FLAGS+=(--dry-run)

IMMUTABLE="public, max-age=31536000, immutable, stale-if-error=2592000"
POINTER="public, max-age=60, stale-while-revalidate=600, stale-if-error=2592000"
DASHBOARD_LOGO="public, max-age=86400"
DASHBOARD_INDEX="public, max-age=300"

# --header-upload applies to every object in a single rclone run, so each
# cache class needs its own pass. Order matters.

# 1. Pack parts. Additive only: an older release manifest may still reference
#    a blob that is about to become unreferenced.
log "1/5 uploading pack parts"
rclone copy "${DOCROOT}/v1/packs" "${DEST}/v1/packs" "${FLAGS[@]}" \
  --exclude "COMPLETE" \
  --header-upload "Cache-Control: ${IMMUTABLE}" \
  --header-upload "Content-Type: application/octet-stream" \
  --header-upload "X-Content-Type-Options: nosniff"

# 2. Immutable per-release manifests.
log "2/5 uploading release manifests"
rclone copy "${DOCROOT}/v1/releases" "${DEST}/v1/releases" "${FLAGS[@]}" \
  --header-upload "Cache-Control: ${IMMUTABLE}" \
  --header-upload "Content-Type: application/json" \
  --header-upload "X-Content-Type-Options: nosniff"

# 3. The pointer, last. It must never advertise a pack that is not uploaded.
log "3/5 uploading pointer manifest"
rclone copyto "${DOCROOT}/v1/manifest.json" "${DEST}/v1/manifest.json" "${FLAGS[@]}" \
  --header-upload "Cache-Control: ${POINTER}" \
  --header-upload "Content-Type: application/json" \
  --header-upload "X-Content-Type-Options: nosniff"

if [ -f "${DOCROOT}/v1/build-status.json" ]; then
  rclone copyto "${DOCROOT}/v1/build-status.json" "${DEST}/v1/build-status.json" \
    "${FLAGS[@]}" \
    --header-upload "Cache-Control: no-store" \
    --header-upload "Content-Type: application/json"
fi

# 4. Dashboard assets. R2 custom domains do not provide index fallback, so the
#    Cloudflare front door rewrites / to /index.html.
log "4/5 uploading dashboard assets"
rclone copyto "${WWW_DIR}/logo.png" "${DEST}/logo.png" "${FLAGS[@]}" \
  --header-upload "Cache-Control: ${DASHBOARD_LOGO}" \
  --header-upload "Content-Type: image/png" \
  --header-upload "X-Content-Type-Options: nosniff"
rclone copyto "${WWW_DIR}/index.html" "${DEST}/index.html" "${FLAGS[@]}" \
  --header-upload "Cache-Control: ${DASHBOARD_INDEX}" \
  --header-upload "Content-Type: text/html; charset=utf-8" \
  --header-upload "X-Content-Type-Options: nosniff"

# 5. Only now is it safe to delete. publish.py has already pruned the local
#    tree by reference count, so anything absent locally is unreferenced by
#    every retained release and by the pointer just uploaded.
if [ "${R2_PRUNE:-1}" = "1" ]; then
  log "5/5 pruning objects no retained release references"
  rclone sync "${DOCROOT}/v1/packs" "${DEST}/v1/packs" "${FLAGS[@]}" \
    --exclude "COMPLETE" \
    --header-upload "Cache-Control: ${IMMUTABLE}" \
    --header-upload "Content-Type: application/octet-stream"
  rclone sync "${DOCROOT}/v1/releases" "${DEST}/v1/releases" "${FLAGS[@]}" \
    --header-upload "Cache-Control: ${IMMUTABLE}" \
    --header-upload "Content-Type: application/json"
else
  log "5/5 R2_PRUNE=0, leaving orphaned objects in place"
fi

log "R2 push complete: $(rclone size "${DEST}/v1" --json 2>/dev/null || echo '{}')"
log "reminder: purge <base>/v1/manifest.json for an immediate pointer update; dashboard files use short cache lifetimes"
