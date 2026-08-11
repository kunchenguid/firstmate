#!/usr/bin/env bash
# Register exact decision correlation for the final Assistant response of the
# current bound Pi session.
#
# This helper does not create outbound text and is not an importance classifier.
# It records only an existing decision_ref -> exact decision_key mapping so a
# later Feishu reply can resolve that one decision by reply-to message ID.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

case "${1:-}" in
  register)
    [ "$#" -eq 3 ] || {
      printf 'usage: fm-feishu-decision.sh register <decision-ref> <decision-key>\n' >&2
      exit 2
    }
    [ -n "${PI_SESSION_ID:-}" ] || {
      printf 'fm-feishu-decision: PI_SESSION_ID is required; run inside the current Pi session\n' >&2
      exit 2
    }
    exec env FM_HOME="$FM_HOME" node "$SCRIPT_DIR/fm-feishu-state.mjs" decision-register "$2" "$3"
    ;;
  -h|--help|help)
    sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
    ;;
  *)
    printf 'usage: fm-feishu-decision.sh register <decision-ref> <decision-key>\n' >&2
    exit 2
    ;;
esac
