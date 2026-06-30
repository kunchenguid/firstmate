#!/usr/bin/env bash
# Shared stat helpers. Always validate numeric output before callers use it in
# arithmetic; PATH may contain GNU stat even on Darwin.

fm_is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_stat_first_line() {
  sed -n '1p'
}

fm_path_mtime() {
  local path=$1 out
  if [ "$(uname)" = Darwin ]; then
    if [ -x /usr/bin/stat ]; then
      out=$(/usr/bin/stat -f %m "$path" 2>/dev/null | fm_stat_first_line) && fm_is_uint "$out" && { printf '%s\n' "$out"; return 0; }
    fi
    out=$(stat -f %m "$path" 2>/dev/null | fm_stat_first_line) && fm_is_uint "$out" && { printf '%s\n' "$out"; return 0; }
  fi
  out=$(stat -c %Y "$path" 2>/dev/null | fm_stat_first_line) && fm_is_uint "$out" && { printf '%s\n' "$out"; return 0; }
  return 1
}

fm_path_sig() {
  local path=$1 out
  if [ "$(uname)" = Darwin ]; then
    if [ -x /usr/bin/stat ]; then
      out=$(/usr/bin/stat -f '%z:%m' "$path" 2>/dev/null | fm_stat_first_line) && fm_valid_path_sig "$out" && { printf '%s\n' "$out"; return 0; }
    fi
    out=$(stat -f '%z:%m' "$path" 2>/dev/null | fm_stat_first_line) && fm_valid_path_sig "$out" && { printf '%s\n' "$out"; return 0; }
  fi
  out=$(stat -c '%s:%Y' "$path" 2>/dev/null | fm_stat_first_line) && fm_valid_path_sig "$out" && { printf '%s\n' "$out"; return 0; }
  return 1
}

fm_valid_path_sig() {
  case "${1:-}" in
    *[!0-9:]*|''|:*|*:) return 1 ;;
    *:*) return 0 ;;
    *) return 1 ;;
  esac
}
