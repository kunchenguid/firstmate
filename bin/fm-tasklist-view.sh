#!/usr/bin/env bash
# fm-tasklist-view.sh - live, watchable board of this home's fleet task list.
#
# A read-only glanceable projection meant to sit in a persistent split pane
# (cmux/herdr) so the captain can SEE, continuously, what the fleet is doing:
# what is IN FLIGHT right now (and how much of it runs in parallel), what is
# QUEUED and ready, what is UPCOMING (waiting on a dependency or a captain
# hold), and what was recently DONE - in the backlog's own priority order.
#
# This command parses no fleet state itself. Like bin/fm-fleet-view.sh, it is a
# renderer over bin/fm-fleet-snapshot.sh --json (schema fm-fleet-snapshot.v1),
# so the board can never drift from the real backlog/state contract. Live
# workers come from that snapshot's tasks[] (each backed by a state/<id>.meta),
# queue/priority/done from its backlog.records[].
#
# Read-only: it never acquires the session lock, drains wakes, arms watchers,
# spawns, sends, or writes any data/ or state/ file. Its only child process is
# fm-fleet-snapshot.sh --json, itself read-only.
#
# Usage:
#   fm-tasklist-view.sh [--once] [--interval N] [--width N] [--done N]
#                       [--no-clear] [--no-color]
#
#   --once, -1        Render one frame and exit (no loop). Used for testing.
#   --interval N, -n  Seconds between redraws in the live loop
#                     (default 4, env FM_TASKLIST_INTERVAL). Ignored with --once.
#   --width N         Target column width for wrapping/truncation
#                     (default: $COLUMNS, else 80). Narrow panes are fine.
#   --done N          Max DONE-RECENT rows to show (default 8, env
#                     FM_TASKLIST_DONE).
#   --no-clear        Do not clear the screen each frame (stream frames instead).
#   --no-color        Disable ANSI color (also honored via NO_COLOR).
#   -h, --help        Show this help.
#
# FM_HOME selects which home's list is shown and is REQUIRED: like other fleet
# scripts, this refuses to guess a home rather than silently show the wrong one.
# The board degrades gracefully - a briefly absent or locked source keeps the
# last good frame with an "updating" footer instead of crashing the loop.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '20,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

INTERVAL="${FM_TASKLIST_INTERVAL:-4}"
DONE_LIMIT="${FM_TASKLIST_DONE:-8}"
WIDTH=""
ONCE=0
NO_CLEAR=0
USE_COLOR=1
[ -n "${NO_COLOR:-}" ] && USE_COLOR=0
[ -t 1 ] || USE_COLOR=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --once|-1) ONCE=1 ;;
    --interval|-n) shift; INTERVAL="${1:-}" ;;
    --width) shift; WIDTH="${1:-}" ;;
    --done) shift; DONE_LIMIT="${1:-}" ;;
    --no-clear) NO_CLEAR=1 ;;
    --no-color) USE_COLOR=0 ;;
    *) echo "fm-tasklist-view: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$INTERVAL" in ''|*[!0-9.]*|.) echo "fm-tasklist-view: --interval must be a positive number" >&2; exit 2 ;; esac
case "$DONE_LIMIT" in ''|*[!0-9]*) echo "fm-tasklist-view: --done must be a non-negative integer" >&2; exit 2 ;; esac
if [ -z "$WIDTH" ]; then WIDTH="${COLUMNS:-80}"; fi
case "$WIDTH" in ''|*[!0-9]*|0) WIDTH=80 ;; esac
[ "$WIDTH" -lt 48 ] && WIDTH=48

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-tasklist-view refuses to guess a firstmate home" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "fm-tasklist-view: jq not found" >&2; exit 1; }

# Color palette: empty strings when color is off, so the same jq program renders
# either way. These are the only ANSI this script emits.
if [ "$USE_COLOR" -eq 1 ]; then
  C_RST=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RUN=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_HDR=$'\033[36m'
else
  C_RST=''; C_BOLD=''; C_DIM=''; C_RUN=''; C_WARN=''; C_ERR=''; C_HDR=''
fi

# The board program. Pure formatting over the fm-fleet-snapshot.v1 contract;
# it reads only fields that contract owns and never re-derives fleet state.
read -r -d '' BOARD_JQ <<'JQ' || true
  def s: (. // "") | tostring;
  def trunc($n): s | if (length > $n) then (.[:($n-1)] + "…") else . end;
  def pad($n): s | . as $x | if (length >= $n) then $x else ($x + " " * ($n - length)) end;
  def cell($n): trunc($n) | pad($n);
  def hrule: ("\($hdr)" + ("─" * ($width)) + "\($rst)");
  def glyph($state):
    if $state == "working" then "\($run)▶\($rst)"
    elif $state == "parked" or $state == "paused" then "\($warn)⏸\($rst)"
    elif $state == "blocked" then "\($err)■\($rst)"
    elif $state == "done" then "\($run)✓\($rst)"
    elif $state == "failed" then "\($err)✗\($rst)"
    else "\($dim)·\($rst)" end;

  # Column budget for the IN FLIGHT rows.
  (9) as $stw
  | (16) as $idw
  | (12) as $rpw
  | (($width - ($stw + $idw + $rpw + 7)) | if . < 12 then 12 else . end) as $tiw
  | (.tasks // []) as $tasks
  | (.backlog.records // []) as $recs
  | ([$recs[] | select(.state == "in_flight" and .structured)]) as $inflight_bl
  | ([$inflight_bl[].id]) as $bl_order
  | ($inflight_bl | map({key:.id, value:.}) | from_entries) as $bl_by_id
  # Live workers are the truth for "what is being worked on now" (each has a
  # meta). Secondmates are persistent supervisors, not task-list work items.
  | ([$tasks[] | select(.kind != "secondmate")]) as $live
  | ($live | map({key:.id, value:.}) | from_entries) as $live_by_id
  # Priority order: backlog in-flight order first, then any live worker without
  # a backlog in-flight row (appended by id, snapshot already sorted them).
  | ( [ $bl_order[] | select($live_by_id[.] != null) | $live_by_id[.] ]
      + [ $live[] | .id as $lid | select(($bl_order | index($lid)) == null) ] ) as $inflight
  | ($inflight | map(select(.current_state.state == "working")) | length) as $parallel

  | ([$recs[] | select(.state == "queued" and .structured)]) as $queued
  | ([$queued[] | select(((.unresolved_blocker_ids // []) | length) == 0 and (.hold_reason == null))]) as $ready
  | ([$queued[] | select(((.unresolved_blocker_ids // []) | length) > 0 or (.hold_reason != null))]) as $upcoming
  | ([$recs[] | select(.state == "done" and .structured)]) as $done

  | [
      "\($bold)\($hdr)FLEET · \(.fm_home)\($rst)",
      "\($dim)as of \($now)\($rst)",
      "",
      ( "\($bold)IN FLIGHT\($rst)  \($dim)(\($inflight | length) live"
        + (if $parallel > 1 then " · \($parallel) in parallel" else "" end) + ")\($rst)" ),
      hrule,
      ( if ($inflight | length) == 0 then "  \($dim)nothing under way\($rst)"
        else ($inflight[]
          | ($bl_by_id[.id]) as $bl
          | (glyph(.current_state.state)) as $g
          | ((.current_state.state) | cell($stw)) as $st
          | (.id | cell($idw)) as $id
          | (((.project // $bl.repo // "-")) | cell($rpw)) as $rp
          | (($bl.title // .hints.last_event_text // .id) | cell($tiw)) as $ti
          | (if .hints.pending_decision then "  \($warn)⚠ needs decision\($rst)"
             elif .hints.blocked_event then "  \($err)⚠ blocked\($rst)"
             elif (.endpoint.exists == false) then "  \($dim)(no live worker)\($rst)"
             else "" end) as $flag
          # A review-ready PR link goes on its own line so it stays clickable.
          | (if ((.pr.url // "") != "") then "\n    \($dim)└ \(.pr.url)\($rst)" else "" end) as $prline
          | "  \($g) \($st) \($id) \($rp) \($ti)\($flag)\($prline)"
        ) end ),
      "",
      "\($bold)QUEUED\($rst)  \($dim)(ready, priority order)\($rst)",
      hrule,
      ( if ($ready | length) == 0 then "  \($dim)none ready\($rst)"
        else ($ready[]
          | "  \(.id | cell($idw)) \((.repo // "-") | cell($rpw)) \(.title | cell($tiw))"
        ) end ),
      "",
      "\($bold)UPCOMING\($rst)  \($dim)(waiting on a dependency or a hold)\($rst)",
      hrule,
      ( if ($upcoming | length) == 0 then "  \($dim)none\($rst)"
        else ($upcoming[]
          | (if (.hold_reason != null) then "hold: \(.hold_reason)"
             else "blocked-by: \(((.unresolved_blocker_ids // []) | join(", ")))" end) as $why
          | "  \(.id | cell($idw)) \(.title | cell($tiw))  \($dim)\($why | trunc($width - $idw - $tiw - 6))\($rst)"
        ) end ),
      "",
      "\($bold)DONE · recent\($rst)",
      hrule,
      ( if ($done | length) == 0 then "  \($dim)none\($rst)"
        else ($done[:$donelimit][]
          | ((.completion.date // "") | cell(10)) as $dt
          | ((.pr_url // .report_path // .local_note // "")) as $art
          | (if $art == "" then "" else "\n    \($dim)└ \($art)\($rst)" end) as $artline
          | "  \($dim)\($dt)\($rst) \(.id | cell($idw)) \(.title | cell($tiw))\($artline)"
        ) end )
    ]
  | .[]
JQ

# Render exactly one board frame to stdout. Returns non-zero (printing nothing)
# when the snapshot is unavailable, so the caller can keep the last good frame.
render_once() {
  local json
  json=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null) || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -r \
    --arg now "$(date '+%Y-%m-%d %H:%M:%S')" \
    --argjson width "$WIDTH" \
    --argjson donelimit "$DONE_LIMIT" \
    --arg rst "$C_RST" --arg bold "$C_BOLD" --arg dim "$C_DIM" \
    --arg run "$C_RUN" --arg warn "$C_WARN" --arg err "$C_ERR" --arg hdr "$C_HDR" \
    "$BOARD_JQ"
}

if [ "$ONCE" -eq 1 ]; then
  render_once || { echo "fm-tasklist-view: unable to read the fleet snapshot" >&2; exit 1; }
  exit 0
fi

# Live loop. Restore the cursor on exit; never let a transient read crash it.
cleanup() { printf '\033[?25h'; }
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT
[ "$USE_COLOR" -eq 1 ] && printf '\033[?25l'

LAST_FRAME=""
while :; do
  if frame=$(render_once); then
    LAST_FRAME=$frame
    footer="${C_DIM}refreshing every ${INTERVAL}s · Ctrl-C to quit${C_RST}"
  else
    footer="${C_WARN}updating… showing last good frame${C_RST}"
  fi
  [ "$NO_CLEAR" -eq 0 ] && printf '\033[H\033[2J'
  if [ -n "$LAST_FRAME" ]; then
    printf '%s\n' "$LAST_FRAME"
  else
    printf '%s\n' "${C_DIM}waiting for the first fleet snapshot…${C_RST}"
  fi
  printf '\n%b\n' "$footer"
  sleep "$INTERVAL"
done
