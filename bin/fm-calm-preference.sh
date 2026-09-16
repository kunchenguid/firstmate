#!/usr/bin/env bash
# Read, write, and toggle Firstmate's home-local Calm preference (config/calm).
#
# Cursor's /calm skill and Cursor sessionStart policy injection use this helper
# so they share Pi's file, values, home resolution, and atomic persist rules
# without a second preference file. Pi's extension and the Claude Code mod keep
# their own writers; this script does not change those paths.
# docs/configuration.md owns the preference schema; docs/calm.md owns the
# captain-facing contract, including the Cursor presentation gap.
#
# Usage:
#   fm-calm-preference.sh read
#   fm-calm-preference.sh write on|off
#   fm-calm-preference.sh toggle
#   fm-calm-preference.sh context
#   fm-calm-preference.sh --help
#
# Home resolution matches Pi: FM_CONFIG_OVERRIDE names the config directory
# outright when set, otherwise config/ under FM_HOME, then FM_ROOT_OVERRIDE,
# then this script's tracked code root. Empty values read as unset.
#
# read prints on or off. An absent, unreadable, or unrecognized value is off.
# Legacy max is read as on.
# write persists on or off followed by one newline at mode 0600 via
# temp-plus-rename. A failed write leaves the current file unchanged and
# exits 1 rather than claiming persistence.
# toggle writes the opposite of the current read, then prints the new value.
# context prints Cursor's additional_context policy when the preference is
# on, and prints nothing when it is off.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,29{s/^# \{0,1\}//;p;}' "$0"
}

# Empty is unset, matching Pi's `process.env.FM_HOME || ...` resolution.
fm_calm_config_dir() {
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_CONFIG_OVERRIDE"
    return 0
  fi
  local home=""
  if [ -n "${FM_HOME:-}" ]; then
    home=$FM_HOME
  elif [ -n "${FM_ROOT_OVERRIDE:-}" ]; then
    home=$FM_ROOT_OVERRIDE
  else
    home=$FM_ROOT
  fi
  printf '%s/config\n' "$home"
}

fm_calm_preference_path() {
  printf '%s/calm\n' "$(fm_calm_config_dir)"
}

fm_calm_trim() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Prints on or off. Missing or unreadable files are off.
fm_calm_read() {
  local path stored
  path=$(fm_calm_preference_path)
  stored=""
  if [ -f "$path" ] && [ -r "$path" ]; then
    stored=$(cat "$path" 2>/dev/null || true)
  fi
  stored=$(fm_calm_trim "$stored")
  case "$stored" in
    on|max) printf 'on\n' ;;
    *) printf 'off\n' ;;
  esac
}

fm_calm_write() {
  local value=$1 path dir tmp
  case "$value" in
    on|off) ;;
    *) return 2 ;;
  esac
  path=$(fm_calm_preference_path)
  dir=$(fm_calm_config_dir)
  mkdir -p "$dir" || return 1
  tmp=$(umask 077; mktemp "${path}.tmp.XXXXXX") || return 1
  if ! printf '%s\n' "$value" >"$tmp" || ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

# Cursor has no transcript-row filter, tool-shell override, or working-ship
# widget. This is the strongest supported surface: a conversation policy the
# sessionStart adapter injects as additional_context while config/calm is on.
# docs/calm.md owns the captain-facing Cursor gap this text implements.
fm_calm_context() {
  [ "$(fm_calm_read)" = on ] || return 0
  cat <<'EOF'
FIRSTMATE CALM is on.
Cursor has no transcript-row filter, tool-shell override, or working-ship widget.
Apply Calm in this conversation only: keep genuine captain prompts and your final answers; do not narrate tool calls, mid-turn working notes, or Firstmate operational input.
Do not claim tool rows are hidden in this TUI, and do not draw or describe an animated boat.
Keep using tools normally.
Delivery, tool execution, model context, session storage, and export stay unchanged.
Toggle with /calm.
EOF
}

cmd=${1:-}
case "$cmd" in
  read)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    fm_calm_read
    ;;
  write)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    fm_calm_write "$2"
    status=$?
    [ "$status" -eq 2 ] && { usage >&2; exit 2; }
    exit "$status"
    ;;
  toggle)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    current=$(fm_calm_read)
    if [ "$current" = on ]; then
      next=off
    else
      next=on
    fi
    fm_calm_write "$next" || exit 1
    printf '%s\n' "$next"
    ;;
  context)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    fm_calm_context
    ;;
  --help|-h)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
