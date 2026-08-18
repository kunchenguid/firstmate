#!/usr/bin/env bash

FM_SHIP_PREFLIGHT_MAX_BYTES=${FM_SHIP_PREFLIGHT_MAX_BYTES:-65536}

fm_ship_preflight_bytes_of() {
  if [ "$(uname -s)" = Darwin ]; then stat -f %z "$1"; else stat -c %s "$1"; fi
}
fm_ship_preflight_within_limit() {
  local bytes
  bytes=$(fm_ship_preflight_bytes_of "$1" 2>/dev/null) || return 1
  case "$bytes" in ''|*[!0-9]*) return 1;; esac
  [ "$bytes" -le "$FM_SHIP_PREFLIGHT_MAX_BYTES" ]
}
fm_ship_preflight_validate_limit() {
  case "$FM_SHIP_PREFLIGHT_MAX_BYTES" in ''|*[!0-9]*|0) return 1;; esac
  [ "$FM_SHIP_PREFLIGHT_MAX_BYTES" -le 1048576 ]
}
fm_ship_preflight_copy_bounded_file() {
  local source=$1 target=$2
  fm_ship_preflight_within_limit "$source" || return 1
  dd if="$source" of="$target" bs="$FM_SHIP_PREFLIGHT_MAX_BYTES" count=1 2>/dev/null || return 1
  fm_ship_preflight_within_limit "$source" && fm_ship_preflight_within_limit "$target"
}
