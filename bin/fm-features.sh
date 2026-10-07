#!/usr/bin/env bash
# fm-features.sh - show and change this home's feature switches.
#
# Usage:
#   fm-features.sh [show]               every switch, its effective value, and where it came from
#   fm-features.sh preset <lite|normal> write config/features from the tracked preset
#   fm-features.sh set <name> <on|off>  change one switch, keeping the rest
#   fm-features.sh enabled <name>       exit 0 when on, 1 when off
#   fm-features.sh seed                 start a brand-new home on the lite preset
#
# bin/fm-features-lib.sh owns the switch names, the file format, and the
# verdict. Presets are the tracked docs/examples/team/features-<preset> files;
# `preset` replaces config/features wholesale, so re-apply personal `set`
# overrides after switching presets.
#
# `seed` is what makes a new install default to lite while an existing home
# keeps every feature: it writes the lite preset only when config/features is
# absent, the home has no data/ directory and no other config/ entry yet, and
# the home is not a secondmate home. Any other home is left untouched.
# bin/fm-session-start.sh runs it once, under the session lock, before bootstrap.
set -eu

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)
# shellcheck source=bin/fm-features-lib.sh
. "$SCRIPT_DIR/fm-features-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

CONFIG=$(fm_features_config_dir)
HOME_DIR=${FM_HOME:-$FM_ROOT}
FILE=$CONFIG/features

preset_file() {  # <preset>
  case "$1" in
    lite|normal) printf '%s\n' "$FM_ROOT/docs/examples/team/features-$1" ;;
    *) echo "error: unknown preset '$1' (lite or normal)" >&2; return 1 ;;
  esac
}

write_file() {  # <content-file>
  local tmp
  mkdir -p "$CONFIG"
  tmp=$(mktemp "$CONFIG/.features.XXXXXX")
  cat "$1" > "$tmp"
  mv -f "$tmp" "$FILE"
}

cmd_show() {
  local name value source
  for name in $FM_FEATURE_NAMES; do
    value=$(fm_feature_declared "$CONFIG" "$name")
    if [ -n "$value" ]; then source=config/features; else value=on source=default; fi
    printf '%-15s %-3s (%s)\n' "$name" "$value" "$source"
  done
  [ -f "$FILE" ] || return 0
  awk -F= '/^[[:space:]]*#/ || /^[[:space:]]*$/ { next } { k = $1; gsub(/[[:space:]]/, "", k); print k }' "$FILE" \
    | while IFS= read -r name; do
        fm_feature_known "$name" || echo "warning: config/features names unknown switch '$name'; it is ignored" >&2
      done
}

cmd_set() {  # <name> <on|off>
  local name=$1 value=$2 tmp
  fm_feature_known "$name" || { echo "error: unknown switch '$name' (known: $FM_FEATURE_NAMES)" >&2; return 1; }
  case "$value" in on|off) ;; *) echo "error: value must be on or off" >&2; return 1 ;; esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-features.XXXXXX")
  if [ -f "$FILE" ]; then
    awk -F= -v want="$name" '{ k = $1; gsub(/[[:space:]]/, "", k); if (k != want || /^[[:space:]]*#/) print }' "$FILE" > "$tmp"
  fi
  printf '%s=%s\n' "$name" "$value" >> "$tmp"
  write_file "$tmp"
  rm -f "$tmp"
  echo "$name=$value"
}

case "${1:-show}" in
  -h|--help) usage ;;
  show) cmd_show ;;
  preset)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    src=$(preset_file "$2")
    write_file "$src"
    echo "config/features now holds the $2 preset"
    ;;
  set)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    cmd_set "$2" "$3"
    ;;
  enabled)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    fm_feature_known "$2" || { echo "error: unknown switch '$2'" >&2; exit 2; }
    fm_feature_enabled_in "$CONFIG" "$2"
    ;;
  seed)
    [ ! -e "$HOME_DIR/data" ] && [ ! -e "$HOME_DIR/.fm-secondmate-home" ] \
      && [ -z "$(ls -A "$CONFIG" 2>/dev/null)" ] || exit 0
    write_file "$(preset_file lite)"
    echo "FEATURES: new home started on the lite preset; bin/fm-features.sh show lists the switches"
    ;;
  *) usage >&2; exit 2 ;;
esac
