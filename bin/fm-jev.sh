#!/usr/bin/env bash
# Configure or inspect Jev dispatch resolution for one Firstmate home.
#
# Usage:
#   fm-jev.sh [status|off|shadow|on]
#
# Modes live in config/jev-mode under the effective FM_HOME:
#   off     Do not call Jev. This is also the default when the file is absent.
#   shadow  Ask Jev and record its decision, but never emit an applicable profile.
#   on      Ask Jev and allow a clear result to drive dispatch.
#
# The OpenRouter key is never written by this command. It is read only to report
# configured/missing, from OPENROUTER_API_KEY in the environment first and then
# from FM_HOME/.env through bin/fm-env-lib.sh.
set -u

OPENROUTER_API_KEY_PRIVATE=${OPENROUTER_API_KEY:-}
export -n OPENROUTER_API_KEY_PRIVATE 2>/dev/null || true
unset OPENROUTER_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MODE_FILE="$CONFIG/jev-mode"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

read_mode() {
  local value
  if [ ! -e "$MODE_FILE" ] && [ ! -L "$MODE_FILE" ]; then
    printf 'off'
    return 0
  fi
  [ -f "$MODE_FILE" ] && [ ! -L "$MODE_FILE" ] && [ -r "$MODE_FILE" ] \
    || die "config/jev-mode must be a readable regular file"
  IFS= read -r value < "$MODE_FILE" || true
  value=${value%$'\r'}
  case "$value" in
    off|shadow|on) printf '%s' "$value" ;;
    *) die "config/jev-mode holds '$value'; accepted values are: off, shadow, on" ;;
  esac
}

report_status() {
  local mode key_state=missing
  mode=$(read_mode) || return $?
  if [ -z "$OPENROUTER_API_KEY_PRIVATE" ]; then
    OPENROUTER_API_KEY_PRIVATE=$(fmx_env_get OPENROUTER_API_KEY "$FM_HOME/.env")
  fi
  [ -z "$OPENROUTER_API_KEY_PRIVATE" ] || key_state=configured
  printf 'jev: mode=%s key=%s transport=openrouter model=~typesafe/jev-latest\n' \
    "$mode" "$key_state"
}

write_mode() {
  local mode=$1 tmp
  mkdir -p "$CONFIG" || die "could not create config directory: $CONFIG"
  [ ! -L "$CONFIG" ] || die "config directory must not be a symlink: $CONFIG"
  tmp=$(mktemp "$CONFIG/.jev-mode.XXXXXX") || die "could not create mode snapshot"
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$mode" > "$tmp" || die "could not write config/jev-mode"
  chmod 600 "$tmp" || die "could not protect config/jev-mode"
  mv "$tmp" "$MODE_FILE" || die "could not replace config/jev-mode"
  trap - EXIT
  report_status
}

case "${1:-status}" in
  status) [ "$#" -le 1 ] || usage; report_status ;;
  off|shadow|on) [ "$#" -eq 1 ] || usage; write_mode "$1" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
