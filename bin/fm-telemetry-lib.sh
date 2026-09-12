#!/usr/bin/env bash
# fm-telemetry-lib.sh - best-effort private lifecycle telemetry.
#
# Usage: source this file, then call fm_telemetry_record <stream> <json-object>.
# Streams are lifecycle, checks, and liveness. Rows are compact JSONL under
# data/telemetry, mode 0600; failed recording never changes the caller result.
set -u

FM_TELEMETRY_MAX_BYTES=${FM_TELEMETRY_MAX_BYTES:-52428800}
case "$FM_TELEMETRY_MAX_BYTES" in ''|*[!0-9]*|0) FM_TELEMETRY_MAX_BYTES=52428800 ;; esac

fm_telemetry_warn() {
  printf 'warning: telemetry %s\n' "$1" >&2
}

fm_telemetry_data_dir() {
  local data=${FM_DATA_OVERRIDE:-${FM_HOME:-${FM_ROOT:-.}}/data}
  printf '%s/telemetry\n' "${data%/}"
}

fm_telemetry_stream_valid() {
  case "$1" in lifecycle|checks|liveness) return 0 ;; esac
  return 1
}

fm_telemetry_home_id() {
  local home=${FM_HOME:-${FM_ROOT:-.}} id
  id=${FM_TELEMETRY_HOME_ID:-${home##*/}}
  case "$id" in
    ''|*[!A-Za-z0-9._:-]*) printf 'unknown' ;;
    *) printf '%s' "$id" ;;
  esac
}

fm_telemetry_now_ms() {
  case "${FM_TELEMETRY_NOW_MS:-}" in
    ''|*[!0-9]*) : ;;
    *) printf '%s\n' "$FM_TELEMETRY_NOW_MS"; return 0 ;;
  esac
  if declare -F fm_timing_now_ms >/dev/null 2>&1; then
    fm_timing_now_ms
  else
    date +%s000 2>/dev/null || printf '0\n'
  fi
}

fm_telemetry_record() { # <stream> <json-object>
  local stream=${1:-} payload=${2:-} dir file ts home row rc lock acquired size row_bytes
  fm_telemetry_stream_valid "$stream" || { fm_telemetry_warn 'invalid stream'; return 0; }
  dir=$(fm_telemetry_data_dir)
  file="$dir/$stream.jsonl"
  ts=$(fm_telemetry_now_ms) || { fm_telemetry_warn 'clock unavailable'; return 0; }
  home=$(fm_telemetry_home_id)
  if ! row=$(printf '%s' "$payload" | jq -ce --argjson ts "$ts" --arg home "$home" \
    'select(type=="object") | .ts=$ts | .home=$home'); then
    fm_telemetry_warn 'payload is not a JSON object'
    return 0
  fi
  if [ ! -d "$dir" ] && [ -e "$dir" ] || [ -L "$dir" ]; then
    fm_telemetry_warn 'directory is not safe'
    return 0
  fi
  if ! mkdir -p "$dir" 2>/dev/null || [ -L "$dir" ]; then
    fm_telemetry_warn 'directory is unavailable'
    return 0
  fi
  for path in "$file" "$file.1" "$file.2"; do
    [ ! -L "$path" ] || { fm_telemetry_warn 'stream path is symlinked'; return 0; }
    [ ! -e "$path" ] || [ -f "$path" ] || { fm_telemetry_warn 'stream path is not a file'; return 0; }
  done
  lock="$file.lock"
  acquired=0
  if mkdir "$lock" 2>/dev/null; then
    chmod 0700 "$lock" 2>/dev/null || true
    acquired=1
  fi
  if [ "$acquired" -ne 1 ]; then
    fm_telemetry_warn 'append lock unavailable'
    return 0
  fi
  size=0
  [ ! -e "$file" ] || size=$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  row_bytes=$(printf '%s\n' "$row" | wc -c | tr -d '[:space:]')
  if [ "$size" -gt 0 ] && [ "$((size + row_bytes))" -gt "$FM_TELEMETRY_MAX_BYTES" ]; then
    rm -f -- "$file.2" 2>/dev/null || true
    [ ! -e "$file.1" ] || mv -f -- "$file.1" "$file.2" || acquired=0
    [ "$acquired" -eq 1 ] && mv -f -- "$file" "$file.1" || acquired=0
  fi
  if [ "$acquired" -eq 1 ]; then
    if ! printf '%s\n' "$row" >> "$file" 2>/dev/null || ! chmod 0600 "$file" 2>/dev/null; then
      acquired=0
    fi
  fi
  rmdir "$lock" 2>/dev/null || true
  if [ "$acquired" -eq 1 ]; then return 0; fi
  rc=1
  fm_telemetry_warn "append failed (rc=$rc)"
  return 0
}
