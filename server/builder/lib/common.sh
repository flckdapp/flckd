#!/usr/bin/env bash
# Shared helpers for the FLCKD tile builder.
# Sourced by every script in server/builder/bin/.

set -euo pipefail

log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()  { log "FATAL: $*"; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Free space in bytes on the filesystem holding $1.
free_bytes() {
  df -PB1 "$1" | awk 'NR==2 {print $4}'
}

human() {
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB",u," ");
    i=1; while (b>=1024 && i<5){ b/=1024; i++ }
    printf "%.1f %s", b, u[i]
  }'
}

# require_free <path> <bytes> <what-for>
require_free() {
  local path="$1" want="$2" what="$3" have
  have="$(free_bytes "$path")"
  log "disk check: $path has $(human "$have") free, need $(human "$want") for $what"
  if [ "$have" -lt "$want" ]; then
    die "not enough free space on $path: have $(human "$have"), need $(human "$want")"
  fi
}

# Download with resume + retries, then verify against Geofabrik's .md5 sidecar.
fetch_verified() {
  local url="$1" dest="$2"
  need curl
  log "fetching $url -> $dest"
  curl --fail --location --retry 5 --retry-delay 10 --retry-all-errors \
       --continue-at - --output "$dest" "$url"

  local md5url="${url}.md5"
  local expected actual
  if expected="$(curl --fail --silent --location "$md5url" 2>/dev/null | awk '{print $1}')"; then
    need md5sum
    actual="$(md5sum "$dest" | awk '{print $1}')"
    [ "$expected" = "$actual" ] || die "md5 mismatch for $dest (expected $expected, got $actual)"
    log "md5 verified: $actual"
  else
    log "WARNING: no .md5 sidecar at $md5url - could not verify download"
  fi
}
