#!/usr/bin/env bash
# Compact captain task table and central task-name maintenance surface.
# Usage: fm-tasks.sh [--json|--table] [<task-selector>]
#        fm-tasks.sh name <task-selector> <lowercase-hyphenated-name>
#        fm-tasks.sh resolve <task-selector>
# The table consumes the canonical fleet snapshot and never maintains a second
# current-state list. Reference and name assignments live in private state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-callsigns-lib.sh
. "$SCRIPT_DIR/fm-callsigns-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-tasks.sh [--json|--table] [<task-selector>]
       fm-tasks.sh name <task-selector> <lowercase-hyphenated-name>
       fm-tasks.sh resolve <task-selector>

Render the compact current task table. Selectors are canonical ids, t1-t99
references, or unambiguous lowercase hyphenated names. Done rows remain visible
only while the configured backlog retains them; lifecycle consumers not yet
ported to selectors continue to require canonical ids.
EOF
}

case "${1:-}" in
  name|set-name)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    fm_callsign_set_name "$2" "$3" >/dev/null || exit $?
    printf 'name updated: %s\n' "$3"
    exit 0
    ;;
  resolve)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    fm_callsign_resolve "$2"
    exit $?
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  --json|--table|"") : ;;
  *)
    SELECTOR=$1
    shift
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    ;;
esac

FORMAT=table
SELECTOR=${SELECTOR:-}
if [ "${1:-}" = --json ]; then FORMAT=json; SELECTOR=; elif [ "${1:-}" = --table ]; then FORMAT=table; SELECTOR=; fi
# Handle the flag when it was the first argument without losing a selector.
if [ "${1:-}" = --json ] || [ "${1:-}" = --table ]; then shift; fi
if [ "${1:-}" != "" ]; then
  [ -z "$SELECTOR" ] || { usage >&2; exit 2; }
  SELECTOR=$1
  shift
fi
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "fm-tasks: jq not found" >&2; exit 1; }
if [ -n "$SELECTOR" ]; then
  SELECTOR=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" fm_callsign_resolve "$SELECTOR") || exit 1
fi
SNAPSHOT=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || exit $?
# The library is sourced for its functions; capture its JSON through a tiny
# sourced-shell invocation so this command has one public mapping owner.
CALLSIGNS=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" bash -c \
  '. "$1"; fm_callsigns_json' _ "$SCRIPT_DIR/fm-callsigns-lib.sh") || {
  echo "fm-tasks: could not read private task references" >&2
  exit 1
}

MODEL=$(printf '%s\n' "$SNAPSHOT" | jq --argjson callsigns "$CALLSIGNS" --arg selector "$SELECTOR" '
  def trunc($n): tostring | gsub("\\s+"; " ") | gsub("\\|"; "/") | if length > $n then .[:($n-1)] + "…" else . end;
  def call($id): ([ $callsigns[] | select(.id == $id) ] | first) // {};
  def task($id): ([.tasks[]? | select(.id == $id)] | first) // {};
  def row_status($r; $t):
    if $r.state == "done" then "done"
    elif ($r.unresolved_blocker_ids // [] | length) > 0 then "blocked"
    elif $r.hold_kind == "captain" then "needs-you"
    elif $r.hold_kind != null then "waiting"
    elif ($t.hints.pending_decision // false) then "needs-you"
    elif ($t.hints.blocked_event // false) then "blocked"
    elif $r.state == "queued" then "queued"
    elif ($t.current_state.state // "unknown") == "working" then "working"
    elif ($t.current_state.state // "unknown") == "paused" then "waiting"
    elif ($t.current_state.state // "unknown") == "blocked" then "blocked"
    elif ($t.current_state.state // "unknown") == "parked" then "needs-you"
    elif ($t.current_state.state // "unknown") == "done" then "ready"
    elif ($t.current_state.state // "unknown") == "failed" then "failed"
    else "waiting" end;
  def outcome($r; $t; $status):
    if $status == "done" then ($r.pr_url // $r.report_path // $r.local_note // "completed")
    elif $status == "queued" then "queued"
    elif $status == "blocked" then (($r.unresolved_blocker_ids // [] | join(", ")) as $b | if $b == "" then ($r.blocked_reason // "blocked") else "waiting on " + $b end)
    elif $status == "needs-you" then ($r.hold_reason // ($t.current_state.detail // "needs your input"))
    elif ($t.current_state.detail // "") != "" then $t.current_state.detail
    elif ($t.hints.last_event_text // "") != "" then $t.hints.last_event_text
    else $status end;
  def make($id; $r; $t):
    (call($id)) as $c
    | (if ($c.name // "") != "" then $c.name else $id end) as $name
    | (row_status($r; $t)) as $status
    | {id:$id, ref:($c.ref // "-"), name:$name, status:$status,
       outcome:(outcome($r; $t; $status) | trunc(100))};
  ([.backlog.records[]? | select(.structured == true and (.state == "in_flight" or .state == "queued" or .state == "done"))
    | . as $r | make($r.id; $r; task($r.id))]) as $backlog_rows
  | ($backlog_rows | map(.id)) as $backlog_ids
  | ($backlog_rows
     + [.tasks[]? | select(.kind != "secondmate")
        | .id as $id | select(($backlog_ids | index($id)) == null)
        | make($id; {state:"in_flight",structured:true}; .)])
  | unique_by(.id)
  | if $selector == "" then . else map(select(.id == $selector or .ref == $selector or .name == $selector)) end
  | sort_by([(.ref | ltrimstr("t") | tonumber? // 1000), .id])
') || { echo "fm-tasks: could not build task table" >&2; exit 1; }

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$MODEL"
else
  printf '| Ref | Name | Status | Current outcome |\n'
  printf '| --- | --- | --- | --- |\n'
  printf '%s\n' "$MODEL" | jq -r '.[] | "| \(.ref) | \(.name) | \(.status) | \(.outcome) |"'
fi
