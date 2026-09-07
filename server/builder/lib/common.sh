#!/usr/bin/env bash
# Shared helpers for the FLCKD tile builder.
# Sourced by every script in server/builder/bin/.

set -euo pipefail

log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# A parent script sees only a child's exit code, so leave the reason in
# FATAL_FILE for it to report. Without this a failed child is shown to the
# operator as a line number in a file they have never read.
die() {
  log "FATAL: $*"
  if [ -n "${FATAL_FILE:-}" ]; then
    printf '%s' "$*" > "$FATAL_FILE" 2>/dev/null || true
  fi
  exit 1
}

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

# Progress for the control plane, written to $STATUS_FILE when set. That file
# lives in the private control directory, never under the docroot. Callers
# set STATUS_LOCAL_PUBLISHED / STATUS_REMOTE_PUBLISHED (true/false) once they
# know; unset means "not known by this script" and is reported as null.
#   write_status_file <stage> [detail]
write_status_file() {
  [ -n "${STATUS_FILE:-}" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    log "WARNING: jq not found, not writing $STATUS_FILE"
    return 0
  fi
  local tmp="${STATUS_FILE}.tmp"
  mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || true
  if jq -nc \
      --arg build_id "${BUILD_ID:-}" --arg stage "$1" --arg detail "${2:-}" \
      --argjson progress "${STATUS_PROGRESS:-null}" \
      --argjson local "${STATUS_LOCAL_PUBLISHED:-null}" \
      --argjson remote "${STATUS_REMOTE_PUBLISHED:-null}" \
      --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{build_id:$build_id, stage:$stage, detail:$detail, progress:$progress,
        local_published:$local, remote_published:$remote, updated_at:$at}' \
      > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$STATUS_FILE"
  else
    log "WARNING: could not write $STATUS_FILE"
  fi
}

# Counted work within the current stage, never an estimate.
#   progress <done> <total> [detail]   fraction of counted units
#   progress "" "" [detail]            indeterminate
progress() {
  STATUS_PROGRESS="$(fraction "$1" "$2")"
  write_status_file "${CURRENT_STAGE:-running}" "${3:-}"
  STATUS_PROGRESS=
}

fraction() {
  awk -v done="${1:-0}" -v total="${2:-0}" 'BEGIN {
    if (total + 0 <= 0) { print "null"; exit }
    f = done / total
    if (f > 1) f = 1
    if (f < 0) f = 0
    printf "%.4f", f
  }'
}

# Geofabrik boundary for one region as GeoJSON, cached under $DATA_DIR/poly.
# Clipping the source and cutting the packs must agree on the shape of a
# region, so both go through here rather than fetching their own copy.
#   region_geojson <region-id>    prints the cached .geojson path
region_geojson() {
  local id="$1"
  local set_file="${REGION_SET:-/opt/flckd/regions/us-states.json}"
  local cache="${DATA_DIR:-/data}/poly"
  local poly="${cache}/${id}.poly" gj="${cache}/${id}.geojson"
  if [ ! -s "$gj" ]; then
    local url name
    read -r url name < <(python3 -c '
import json,sys
sid=sys.argv[2]
for p in json.load(open(sys.argv[1]))["packs"]:
    if p["id"]==sid:
        print(p["poly_url"], p["name"].replace(" ","_")); break
else:
    sys.exit(1)' "$set_file" "$id") || die "region '$id' not found in $set_file"
    mkdir -p "$cache"
    [ -s "$poly" ] || curl --fail --location --silent --show-error \
        --retry 3 --retry-delay 5 -o "$poly" "$url"
    python3 "$(dirname "${BASH_SOURCE[0]}")/../bin/poly2geojson.py" \
        "$poly" "$gj" --id "$id" --name "$name" >/dev/null
  fi
  printf '%s' "$gj"
}

remote_size() {
  curl --fail --silent --location --head "$1" 2>/dev/null \
    | tr -d '\r' \
    | awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }'
}

# One readable line per interval, in place of a redrawing meter.
report_growth() {
  local path="$1" total="$2" pid="$3" have
  while kill -0 "$pid" 2>/dev/null; do
    sleep 20
    kill -0 "$pid" 2>/dev/null || break
    have="$(stat -c %s "$path" 2>/dev/null || echo 0)"
    if [ "$total" -gt 0 ]; then
      progress "$have" "$total" "downloaded $(human "$have") of $(human "$total")"
      log "downloaded $(human "$have") of $(human "$total")"
    else
      progress "" "" "downloaded $(human "$have")"
      log "downloaded $(human "$have")"
    fi
  done
}

# Download with resume + retries, then verify against Geofabrik's .md5 sidecar.
fetch_verified() {
  local url="$1" dest="$2"
  need curl
  log "fetching $url -> $dest"

  local total rc=0 fetch_pid watch_pid
  total="$(remote_size "$url")"
  [ "$total" -gt 0 ] && log "expecting $(human "$total")"

  # --no-progress-meter: curl's meter redraws one line with carriage returns.
  # This output is captured into the job log, where a redraw stream is noise.
  curl --fail --location --retry 5 --retry-delay 10 --retry-all-errors \
       --continue-at - --no-progress-meter --output "$dest" "$url" &
  fetch_pid=$!
  report_growth "$dest" "$total" "$fetch_pid" &
  watch_pid=$!

  set +e
  wait "$fetch_pid"
  rc=$?
  set -e
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  [ "$rc" -eq 0 ] || die "download failed: $url (curl exit $rc)"
  progress "" "" "verifying download"

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
