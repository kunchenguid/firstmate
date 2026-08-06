#!/usr/bin/env bash
# fm-calm.sh - read or atomically update the effective Firstmate Calm preference.
#
# Usage:
#   fm-calm.sh status
#   fm-calm.sh on
#   fm-calm.sh off
#   fm-calm.sh toggle
#
# The preference is the exact lowercase value "on" or "off" plus one newline
# in config/calm under the effective Firstmate home.
# Resolution is FM_CONFIG_OVERRIDE, then FM_HOME/config, then
# FM_ROOT_OVERRIDE/config, then this tracked code root's config directory.
# An absent, unreadable, or unrecognized value reads as off.
# Mutations create the config directory when needed and replace the preference
# atomically, so a write failure leaves the prior preference unchanged.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PREFERENCE="$CONFIG/calm"

usage() {
  printf '%s\n' \
    'Usage:' \
    '  fm-calm.sh status' \
    '  fm-calm.sh on' \
    '  fm-calm.sh off' \
    '  fm-calm.sh toggle'
}

read_preference() {
  local value
  value=$(cat "$PREFERENCE" 2>/dev/null || true)
  case "$value" in
    on) printf '%s\n' on ;;
    *) printf '%s\n' off ;;
  esac
}

write_preference() {
  local value=$1 temporary
  mkdir -p "$CONFIG" || return 1
  temporary=$(mktemp "$CONFIG/.calm.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  if ! mv -f "$temporary" "$PREFERENCE"; then
    rm -f "$temporary"
    return 1
  fi
}

case "${1:-}" in
  status)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    read_preference
    ;;
  on|off)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    write_preference "$1" || { printf 'error: could not update %s\n' "$PREFERENCE" >&2; exit 1; }
    printf '%s\n' "$1"
    ;;
  toggle)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    case "$(read_preference)" in
      on) write_preference off || { printf 'error: could not update %s\n' "$PREFERENCE" >&2; exit 1; }; printf '%s\n' off ;;
      *) write_preference on || { printf 'error: could not update %s\n' "$PREFERENCE" >&2; exit 1; }; printf '%s\n' on ;;
    esac
    ;;
  -h|--help)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
