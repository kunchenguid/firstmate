#!/usr/bin/env bash
# fm-cmux-war-room.sh - thin operator helpers for a cmux war-room session.
#
# These are manual convenience wrappers around the cmux CLI for an operator
# running a multi-pane war-room (docs/cmux-war-room.md). They are NOT part of
# the fm-spawn.sh crewmate lifecycle and do not change the 1:1 task-workspace
# backend contract owned by docs/cmux-backend.md and bin/backends/cmux.sh.
#
# Usage:
#   fm-cmux-war-room.sh banner --surface <ref> --label <text> [--color <name-or-hex>]
#   fm-cmux-war-room.sh color-for-harness <harness>
#   fm-cmux-war-room.sh teardown-surfaces --workspace <ref> [--keep <surface-ref>] [--close-workspace]
#   fm-cmux-war-room.sh --help
#
# banner            renames the pane tab and writes a colored ANSI banner line
#                    into the surface so a war-room grid stays scannable.
# color-for-harness  prints the workspace color configured for one harness in
#                    local config/harness-visual.json, or a fallback default
#                    when the file or the harness key is absent.
# teardown-surfaces  closes every surface in one named workspace except an
#                    optionally kept one, scoped to exactly that workspace's
#                    own list-panes response; never a broad close. Pass
#                    --close-workspace to also close the now-single-surface
#                    workspace afterward (cmux refuses to close a last surface
#                    directly - see docs/cmux-backend.md "Current operation
#                    and safety").
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FM_CMUX_WAR_ROOM_BUNDLE_BIN="${FM_CMUX_WAR_ROOM_BUNDLE_BIN:-/Applications/cmux.app/Contents/Resources/bin/cmux}"

fm_cmux_war_room_usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_cmux_war_room_bin() {
  if command -v cmux >/dev/null 2>&1; then
    printf '%s\n' "cmux"
    return 0
  fi
  if [ -x "$FM_CMUX_WAR_ROOM_BUNDLE_BIN" ]; then
    printf '%s\n' "$FM_CMUX_WAR_ROOM_BUNDLE_BIN"
    return 0
  fi
  echo "fm-cmux-war-room: cmux CLI not found on PATH or at $FM_CMUX_WAR_ROOM_BUNDLE_BIN" >&2
  return 1
}

fm_cmux_war_room_require_jq() {
  command -v jq >/dev/null 2>&1 || {
    echo "fm-cmux-war-room: jq is required" >&2
    return 1
  }
}

fm_cmux_war_room_banner() {
  local surface="" label="" color="36" cmux_bin
  while [ $# -gt 0 ]; do
    case "$1" in
      --surface) surface=${2:-}; shift 2 ;;
      --label) label=${2:-}; shift 2 ;;
      --color) color=${2:-}; shift 2 ;;
      *) echo "fm-cmux-war-room banner: unknown argument: $1" >&2; return 1 ;;
    esac
  done
  [ -n "$surface" ] || { echo "fm-cmux-war-room banner: --surface is required" >&2; return 1; }
  cmux_bin=$(fm_cmux_war_room_bin) || return 1
  if [ -n "$label" ]; then
    "$cmux_bin" rename-tab --surface "$surface" "$label"
  fi
  "$cmux_bin" send --surface "$surface" "printf '\\033[1;97;${color}m\\n  ${label:-WAR ROOM}  \\n\\033[0m\\n'"
  "$cmux_bin" send-key --surface "$surface" enter
}

fm_cmux_war_room_color_for_harness() {
  local harness="${1:-}" file="$CONFIG/harness-visual.json" color=""
  [ -n "$harness" ] || { echo "fm-cmux-war-room color-for-harness: a harness name is required" >&2; return 1; }
  if [ -f "$file" ]; then
    fm_cmux_war_room_require_jq || return 1
    color=$(jq -r --arg h "$harness" '.workspace_colors[$h] // empty' "$file")
  fi
  if [ -z "$color" ]; then
    echo "fm-cmux-war-room: no color configured for '$harness' in $file, using default Grey" >&2
    color="Grey"
  fi
  printf '%s\n' "$color"
}

fm_cmux_war_room_teardown_surfaces() {
  local workspace="" keep="" close_workspace=0 cmux_bin surface
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) workspace=${2:-}; shift 2 ;;
      --keep) keep=${2:-}; shift 2 ;;
      --close-workspace) close_workspace=1; shift ;;
      *) echo "fm-cmux-war-room teardown-surfaces: unknown argument: $1" >&2; return 1 ;;
    esac
  done
  [ -n "$workspace" ] || { echo "fm-cmux-war-room teardown-surfaces: --workspace is required" >&2; return 1; }
  cmux_bin=$(fm_cmux_war_room_bin) || return 1
  fm_cmux_war_room_require_jq || return 1

  local surfaces
  surfaces=$("$cmux_bin" list-panes --workspace "$workspace" --json --id-format both \
    | jq -r '[.panes[].surface_ids[]?, .panes[].surface_refs[]?] | unique | .[]')

  while IFS= read -r surface; do
    [ -n "$surface" ] || continue
    [ "$surface" = "$keep" ] && continue
    "$cmux_bin" close-surface --surface "$surface"
  done <<EOF
$surfaces
EOF

  if [ "$close_workspace" -eq 1 ]; then
    "$cmux_bin" close-workspace --workspace "$workspace"
  fi
}

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    banner) fm_cmux_war_room_banner "$@" ;;
    color-for-harness) fm_cmux_war_room_color_for_harness "$@" ;;
    teardown-surfaces) fm_cmux_war_room_teardown_surfaces "$@" ;;
    -h|--help|"") fm_cmux_war_room_usage ;;
    *) echo "fm-cmux-war-room: unknown subcommand: $cmd" >&2; fm_cmux_war_room_usage >&2; return 1 ;;
  esac
}

main "$@"
