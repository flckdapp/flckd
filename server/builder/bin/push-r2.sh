#!/usr/bin/env bash
# Push a published docroot to an S3-compatible bucket: Cloudflare R2, AWS S3,
# MinIO, or anything else rclone's s3 backend speaks to.
#
# Why a bucket rather than serving from home:
#
# 1. Terms. Cloudflare's Service-Specific Terms, under "Content Delivery
#    Network (Free, Pro, or Business)", reserve the right to limit or disable
#    the CDN for anyone serving "a disproportionate percentage of pictures,
#    audio files, or other large files" without a paid product such as the
#    Developer Platform. Pro and Business are covered by the same clause. R2
#    is part of the Developer Platform and carries no such restriction.
# 2. Home bandwidth. With a self-hosted origin, every edge cache miss pulls
#    from the house. A bucket removes home upload entirely.
# 3. Availability. The origin becomes the bucket, so the build box can be off,
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
# Environment:
#   S3_ENDPOINT            https://<account>.r2.cloudflarestorage.com,
#                          https://s3.<region>.amazonaws.com, http://minio:9000
#   S3_BUCKET              bucket name
#   S3_ACCESS_KEY_ID       access key
#   S3_SECRET_ACCESS_KEY   secret key
#   S3_PROVIDER            rclone provider name (default Cloudflare): AWS, Other, Minio...
#   S3_REGION              default auto (right for R2; AWS needs its region)
# The older R2 names still work and take effect when the S3 name is unset:
#   R2_ACCOUNT_ID (derives the endpoint), R2_BUCKET, R2_ACCESS_KEY_ID,
#   R2_SECRET_ACCESS_KEY
# Optional:
#   WWW_DIR=/srv/www       dashboard files, used only if the docroot lacks them
#   R2_PRUNE=0             keep orphaned remote objects (default 1: delete them)
#   DRY_RUN=1              show what would transfer, change nothing
#   STATUS_FILE            private progress file for the control plane

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DOCROOT="${1:-${DOCROOT:-/srv/tiles}}"
WWW_DIR="${WWW_DIR:-/srv/www}"
need rclone

S3_BUCKET="${S3_BUCKET:-${R2_BUCKET:-}}"
S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-${R2_ACCESS_KEY_ID:-}}"
S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-${R2_SECRET_ACCESS_KEY:-}}"
S3_PROVIDER="${S3_PROVIDER:-Cloudflare}"
S3_REGION="${S3_REGION:-auto}"
if [ -z "${S3_ENDPOINT:-}" ] && [ -n "${R2_ACCOUNT_ID:-}" ]; then
  S3_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
fi
for v in S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
  [ -n "${!v:-}" ] || die "$v is not set (or its R2_ equivalent)"
done
case "$S3_ENDPOINT" in
  https://*) ;;
  http://*) log "WARNING: plain HTTP endpoint; only use this on a private network" ;;
  *) die "S3_ENDPOINT must be an http(s) URL" ;;
esac
[ -d "$DOCROOT/v1" ] || die "no published tree at $DOCROOT/v1 - run publish.py first"

# Dashboard assets come from the docroot, which run-build.sh makes a complete
# site. Fall back to WWW_DIR for docroots published by older builds.
ASSET_DIR="$DOCROOT"
[ -f "$ASSET_DIR/index.html" ] && [ -f "$ASSET_DIR/logo.png" ] || ASSET_DIR="$WWW_DIR"
[ -f "${ASSET_DIR}/logo.png" ]   || die "required dashboard asset missing: ${ASSET_DIR}/logo.png"
[ -f "${ASSET_DIR}/index.html" ] || die "required dashboard asset missing: ${ASSET_DIR}/index.html"

UPLOAD_PASSES=5
pass() {
  log "$1/${UPLOAD_PASSES} $2"
  progress "$(( $1 - 1 ))" "$UPLOAD_PASSES" "$2"
}

STATUS_REMOTE_PUBLISHED=false
trap 'write_status_file "failed" "upload aborted at line $LINENO"' ERR
write_status_file "upload" "uploading to ${S3_BUCKET}"

# Configure rclone entirely from the environment so no credentials are ever
# written to disk.
export RCLONE_CONFIG_S3_TYPE=s3
export RCLONE_CONFIG_S3_PROVIDER="$S3_PROVIDER"
export RCLONE_CONFIG_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export RCLONE_CONFIG_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_S3_ENDPOINT="$S3_ENDPOINT"
export RCLONE_CONFIG_S3_REGION="$S3_REGION"
# R2 ignores ACLs and does not implement per-object checksum trailers the same
# way S3 does; this is Cloudflare's own documented rclone setting. It is
# harmless elsewhere: the bucket must already exist.
export RCLONE_CONFIG_S3_NO_CHECK_BUCKET=true
export RCLONE_S3_ACL=private

DEST="S3:${S3_BUCKET}"
FLAGS=(--transfers 8 --checkers 16 --fast-list --s3-chunk-size 64M --stats 30s --stats-one-line)
[ "${DRY_RUN:-0}" = "1" ] && FLAGS+=(--dry-run)

IMMUTABLE="public, max-age=31536000, immutable, stale-if-error=2592000"
POINTER="public, max-age=60, stale-while-revalidate=600, stale-if-error=2592000"
DASHBOARD_LOGO="public, max-age=86400"
DASHBOARD_INDEX="public, max-age=300"

# --header-upload applies to every object in a single rclone run, so each
# cache class needs its own pass. Order matters. Only Cache-Control and
# Content-Type are settable this way on the s3 backend; nosniff is added by
# the front door, not the bucket.

# 1. Pack parts. Additive only: an older release manifest may still reference
#    a blob that is about to become unreferenced.
pass 1 "uploading pack parts"
rclone copy "${DOCROOT}/v1/packs" "${DEST}/v1/packs" "${FLAGS[@]}" \
  --exclude "COMPLETE" \
  --header-upload "Cache-Control: ${IMMUTABLE}" \
  --header-upload "Content-Type: application/octet-stream"

# 2. Immutable per-release manifests.
pass 2 "uploading release manifests"
rclone copy "${DOCROOT}/v1/releases" "${DEST}/v1/releases" "${FLAGS[@]}" \
  --header-upload "Cache-Control: ${IMMUTABLE}" \
  --header-upload "Content-Type: application/json"

# 3. The pointer, last. It must never advertise a pack that is not uploaded.
pass 3 "uploading pointer manifest"
rclone copyto "${DOCROOT}/v1/manifest.json" "${DEST}/v1/manifest.json" "${FLAGS[@]}" \
  --header-upload "Cache-Control: ${POINTER}" \
  --header-upload "Content-Type: application/json"

if [ -f "${DOCROOT}/v1/build-status.json" ]; then
  rclone copyto "${DOCROOT}/v1/build-status.json" "${DEST}/v1/build-status.json" \
    "${FLAGS[@]}" \
    --header-upload "Cache-Control: no-store" \
    --header-upload "Content-Type: application/json"
fi

# 4. Dashboard assets. R2 custom domains do not provide index fallback, so the
#    Cloudflare front door rewrites / to /index.html.
pass 4 "uploading dashboard assets"
rclone copyto "${ASSET_DIR}/logo.png" "${DEST}/logo.png" "${FLAGS[@]}" \
  --header-upload "Cache-Control: ${DASHBOARD_LOGO}" \
  --header-upload "Content-Type: image/png"
rclone copyto "${ASSET_DIR}/index.html" "${DEST}/index.html" "${FLAGS[@]}" \
  --header-upload "Cache-Control: ${DASHBOARD_INDEX}" \
  --header-upload "Content-Type: text/html; charset=utf-8"

# 5. Only now is it safe to delete. publish.py has already pruned the local
#    tree by reference count, so anything absent locally is unreferenced by
#    every retained release and by the pointer just uploaded. The control
#    plane sets R2_PRUNE=0: unattended runs never delete remote objects.
if [ "${R2_PRUNE:-1}" = "1" ]; then
  pass 5 "pruning objects no retained release references"
  rclone sync "${DOCROOT}/v1/packs" "${DEST}/v1/packs" "${FLAGS[@]}" \
    --exclude "COMPLETE" \
    --header-upload "Cache-Control: ${IMMUTABLE}" \
    --header-upload "Content-Type: application/octet-stream"
  rclone sync "${DOCROOT}/v1/releases" "${DEST}/v1/releases" "${FLAGS[@]}" \
    --header-upload "Cache-Control: ${IMMUTABLE}" \
    --header-upload "Content-Type: application/json"
else
  pass 5 "R2_PRUNE=0, leaving orphaned objects in place"
fi

progress "$UPLOAD_PASSES" "$UPLOAD_PASSES" "upload complete"
STATUS_REMOTE_PUBLISHED=true
write_status_file "done" "uploaded to ${S3_BUCKET}"
log "upload complete: $(rclone size "${DEST}/v1" --json 2>/dev/null || echo '{}')"
log "reminder: purge <base>/v1/manifest.json for an immediate pointer update; dashboard files use short cache lifetimes"
