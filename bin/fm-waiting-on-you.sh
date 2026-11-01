#!/usr/bin/env bash
# fm-waiting-on-you.sh - the always-visible "Waiting on you" line for a primary
# firstmate session's turn end.
#
# A captain call that lives only in chat can be asked again and again while
# nothing records it as waiting on him, and a reply claiming nothing waits on
# him cannot be checked. This line is computed at every primary turn end from
# the same live captain holds Bearings' Captain's Call reads
# (bin/fm-fleet-snapshot.sh --captain-calls: backlog records whose hold_bucket
# is "live"), so a real hold stays on screen until it is answered and a claim
# that nothing waits can be contradicted on sight. It is printed after every
# turn, including a plain acknowledgement, and a zero is printed as a zero.
#
# Usage:
#   fm-waiting-on-you.sh            print the line on stdout
#   fm-waiting-on-you.sh --claude   print it as a Claude Code hook
#                                   {"systemMessage": ...} object
#
# Line shape (this header is the one owner):
#   Waiting on you: 0
#   Waiting on you: <n> - <title> [<class>]; <title> [<class>] (+<k> more)
# Each title is cut to 60 characters, at most three are named, and a hold
# recorded before captain-hold classes existed shows [unclassed]. When the
# holds cannot be read the line says so instead of printing a false zero:
#   Waiting on you: unknown - the captain holds could not be read
#
# Scope: only a genuine primary home (bin/fm-primary-scope-lib.sh) prints
# anything; inside a crewmate or scout worktree it prints nothing. It never
# fails a turn: every outcome exits 0, so a harness hook can run it on every
# turn end without risk of blocking one. This home's own backlog is the input;
# a registered secondmate's holds reach main through its parent channel and
# Bearings, not this line.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MODE=plain

case "${1:-}" in
  '') ;;
  --claude) MODE=claude ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  *) echo "usage: $(basename "$0") [--claude]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: $(basename "$0") [--claude]" >&2; exit 2; }

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
command -v jq >/dev/null 2>&1 || exit 0

line=
if calls=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --captain-calls 2>/dev/null) \
  && line=$(printf '%s\n' "$calls" | jq -er '
    def cut($n): if length > $n then .[:($n - 1)] + "…" else . end;
    (.count | tostring) as $n
    | if .count == 0 then "Waiting on you: 0"
      else "Waiting on you: " + $n + " - "
        + ([.calls[:3][] | ((.title // .id) | gsub("\\s+"; " ") | cut(60))
            + " [" + (.class // "unclassed") + "]"] | join("; "))
        + (if .count > 3 then " (+" + ((.count - 3) | tostring) + " more)" else "" end)
      end' 2>/dev/null); then
  :
else
  line='Waiting on you: unknown - the captain holds could not be read'
fi

if [ "$MODE" = claude ]; then
  jq -cn --arg line "$line" '{systemMessage:$line}'
else
  printf '%s\n' "$line"
fi
exit 0
