#!/usr/bin/env bash
# Process-event adapter owning the Slack Socket Mode worker lifecycle.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SOURCE_ID=slack-captain-socket

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { printf 'usage: fm-procevent-slack-socket.sh arm|retire|source-id|terminal\n' >&2; exit 2; }

case "${1-}" in
  arm)
    command -v node >/dev/null 2>&1 || die "node is not installed"
    registration="$STATE/procevent/$SOURCE_ID.source"
    if [ -f "$registration" ] && [ ! -L "$registration" ]; then
      adapter=$(sed -n 's/^adapter=//p' "$registration" | head -1)
      argc=$(sed -n 's/^argc=//p' "$registration" | head -1)
      argv=$(sed -n '/^argv:$/,$p' "$registration" | tail -n +2)
      if [ "$adapter" = slack-socket ] && [ "$argc" = 1 ] \
        && [ "$argv" = "$SCRIPT_DIR/fm-slack-socket.sh" ]; then
        printf 'already armed: %s\n' "$SOURCE_ID"
        exit 0
      fi
      die "existing socket registration differs; retire it before re-arming"
    fi
    "$SCRIPT_DIR/fm-procevent.sh" register slack-socket "$SOURCE_ID" -- "$SCRIPT_DIR/fm-slack-socket.sh"
    ;;
  retire) "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID" ;;
  source-id) printf '%s\n' "$SOURCE_ID" ;;
  terminal) exit 1 ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
