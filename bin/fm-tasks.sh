#!/usr/bin/env bash
# Compact captain task table and central task-name maintenance surface.
# Usage: fm-tasks.sh [--json|--table] [<task-selector>]
#        fm-tasks.sh name <task-selector> <two-to-four-token-name>
#        fm-tasks.sh resolve <task-selector>
# The table consumes the canonical fleet snapshot and never maintains a second
# current-state list. Reference and name assignments live in private state.
# JSON rows are ordered by numeric short reference then canonical id and include
# the spawn owner's authoritative started_at timestamp when one is available.
# Table width follows a positive COLUMNS value, then `tput cols`, then 120;
# widths below 33 use the smallest aligned layout and may exceed the terminal.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-callsigns-lib.sh
. "$SCRIPT_DIR/fm-callsigns-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-tasks.sh [--json|--table] [<task-selector>]
       fm-tasks.sh name <task-selector> <two-to-four-token-name>
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
  def event_note($t): ($t.hints.last_event_text // "" | sub("^[^:]+:[[:space:]]*"; ""));
  def current_detail($t):
    ([$t.current_state.detail, event_note($t)] | map(select(. != null and . != "")) | .[0]) // "";
  def row_status($r; $t):
    if $r.state == "done" then "done"
    elif $t.mode == "local-only" and ($t.current_state.state // "unknown") == "done" then "ready"
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
    else "unknown" end;
  def outcome($r; $t; $status):
    if $status == "done" then "Ready to close"
    elif $status == "queued" then "queued"
    elif $status == "blocked" then (($r.unresolved_blocker_ids // [] | join(", ")) as $b | if $b == "" then ($r.blocked_reason // "blocked") else "waiting on " + $b end)
    elif $status == "needs-you" then ($r.hold_reason // (current_detail($t) | if . == "" then "needs your input" else . end))
    elif $status == "waiting" then ($r.hold_reason // (current_detail($t) | if . == "" then "external delay" else . end))
    elif $status == "ready" and $t.mode == "local-only" then
      ($r.hold_reason // current_detail($t)) as $detail
      | if $detail == "" then "awaiting landing approval"
        elif ($detail | test("await|approval|landing"; "i")) then $detail
        else $detail + "; awaiting landing approval" end
    elif (current_detail($t)) != "" then current_detail($t)
    elif $status == "unknown" then "current state unavailable"
    else $status end;
  def make($id; $r; $t):
    (call($id)) as $c
    | (if ($c.name // "") != "" then $c.name else $id end) as $name
    | (row_status($r; $t)) as $status
    | {id:$id, ref:($c.ref // "-"), name:$name, status:$status,
       started_at:($t.started_at // null),
       outcome:(outcome($r; $t; $status) | trunc(100))};
  . as $snapshot
  | def task($id): ([$snapshot.tasks[]? | select(.id == $id)] | first) // {};
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
  exit 0
fi

TABLE_WIDTH=${COLUMNS:-}
case "$TABLE_WIDTH" in
  ''|*[!0-9]*|0)
    TABLE_WIDTH=$(tput cols 2>/dev/null || true)
    case "$TABLE_WIDTH" in ''|*[!0-9]*|0) TABLE_WIDTH=120 ;; esac
    ;;
esac
[ "$TABLE_WIDTH" -ge 33 ] || TABLE_WIDTH=33
[ "$TABLE_WIDTH" -le 160 ] || TABLE_WIDTH=160

# Four columns need 13 cells for outer/inter-column borders and padding.
CONTENT_WIDTH=$((TABLE_WIDTH - 13))
REF_WIDTH=3
STATUS_WIDTH=9
NAME_WIDTH=24
OUTCOME_WIDTH=$((CONTENT_WIDTH - REF_WIDTH - STATUS_WIDTH - NAME_WIDTH))
while [ "$OUTCOME_WIDTH" -lt 15 ] && [ "$NAME_WIDTH" -gt 4 ]; do
  NAME_WIDTH=$((NAME_WIDTH - 1))
  OUTCOME_WIDTH=$((OUTCOME_WIDTH + 1))
done
while [ "$OUTCOME_WIDTH" -lt 7 ] && [ "$STATUS_WIDTH" -gt 6 ]; do
  STATUS_WIDTH=$((STATUS_WIDTH - 1))
  OUTCOME_WIDTH=$((OUTCOME_WIDTH + 1))
done

printf '%s\n' "$MODEL" | jq -r \
  --argjson rw "$REF_WIDTH" \
  --argjson nw "$NAME_WIDTH" \
  --argjson sw "$STATUS_WIDTH" \
  --argjson ow "$OUTCOME_WIDTH" '
  def pad($text; $width):
    ($text // "" | tostring) as $text
    | $text + (" " * ($width - ($text | length)));
  def wrap($text; $width):
    ($text // "" | tostring | gsub("^\\s+|\\s+$"; "")) as $text
    | if ($text | length) <= $width then [$text]
      else ($text[0:$width] | rindex(" ") // -1) as $break
      | if $break > 0
        then [$text[0:$break]] + wrap($text[($break + 1):]; $width)
        else [$text[0:$width]] + wrap($text[$width:]; $width)
        end
      end;
  def border($left; $middle; $right):
    $left + ("─" * ($rw + 2)) + $middle
    + ("─" * ($nw + 2)) + $middle
    + ("─" * ($sw + 2)) + $middle
    + ("─" * ($ow + 2)) + $right;
  def render_row($row):
    (wrap($row.ref; $rw)) as $refs
    | (wrap($row.name; $nw)) as $names
    | (wrap($row.status; $sw)) as $statuses
    | (wrap($row.outcome; $ow)) as $outcomes
    | ([$refs, $names, $statuses, $outcomes] | map(length) | max) as $height
    | range(0; $height) as $line
    | "│ " + pad($refs[$line]; $rw)
      + " │ " + pad($names[$line]; $nw)
      + " │ " + pad($statuses[$line]; $sw)
      + " │ " + pad($outcomes[$line]; $ow) + " │";
  border("┌"; "┬"; "┐"),
  render_row({ref:"Ref", name:"Name", status:"Status", outcome:"Current outcome"}),
  border("├"; "┼"; "┤"),
  (.[] | render_row(.)),
  border("└"; "┴"; "┘")
'
