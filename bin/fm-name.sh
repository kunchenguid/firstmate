#!/usr/bin/env bash
# Inspect and rename persistent Firstmate and task identities.
# Usage: fm-name.sh home|rename-home <name>|rename <selector> <name>|resolve <selector>|history
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:?error: FM_HOME is not set}
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-identity-lib.sh
. "$SCRIPT_DIR/fm-identity-lib.sh"

usage() { echo "usage: fm-name.sh home|rename-home <name>|rename <selector> <name>|resolve <selector>|history"; }
case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac
command=$1
shift
case "$command" in
  home) [ "$#" -eq 0 ] || { usage >&2; exit 2; }; printf '%s (Firstmate home)\n' "$(fm_identity_ensure_home)" ;;
  rename-home) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; printf '%s (Firstmate home)\n' "$(fm_identity_rename_home "$1")" ;;
  rename)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    result=$(fm_identity_rename_task "$STATE" "$1" "$2")
    printf '%s (%s)\n' "${result%%$'\t'*}" "${result#*$'\t'}"
    ;;
  resolve)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    id=$(fm_identity_resolve_selector "$STATE" "$1")
    printf '%s (%s)\n' "$(fm_identity_display_callsign "$id")" "$id"
    ;;
  history)
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    while IFS=$'\t' read -r callsign id status; do printf '%s (%s) %s\n' "$callsign" "$id" "$status"; done < <(fm_identity_history)
    ;;
  *) usage >&2; exit 2 ;;
esac
