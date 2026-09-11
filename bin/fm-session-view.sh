#!/usr/bin/env bash
# fm-session-view.sh - human renderer over fm-session-inventory.sh.
#
# This command intentionally does not inspect fleet state, processes, or Lavish
# itself. It shells out to bin/fm-session-inventory.sh --json and renders that
# stable structured contract, exactly as bin/fm-fleet-view.sh renders the fleet
# snapshot. It closes nothing: every close command is printed for a human to
# read and paste, never executed here.
#
# BUILT FOR A PANE LEFT OPEN. `--watch` redraws in place on a fixed cadence, so
# the captain never has to re-run anything to see what changed.
#
# WHY 60 SECONDS BY DEFAULT. One pass costs roughly one to two seconds of purely
# local reads (the fleet snapshot dominates; the Lavish listing and one process
# table make up the rest). At 60s that is a low single-digit percentage of one
# core, four times slower than the fleet's own 15s supervision cycle and far
# cheaper than its 300s slow-check sweep. It also takes no lock: it never
# acquires the session lock or the watcher lock, never writes a state record,
# and never signals a process, so no supervision cycle, lock, or background
# service can be disturbed by how often this redraws. The floor is 15s
# (FM_SESSION_VIEW_MIN_INTERVAL) because anything faster would poll harder than
# supervision itself for a display that changes on the scale of minutes.
#
# READABLE WITHOUT COLOUR AND IN A NARROW PANE. Age and attention are carried by
# text: a leading "!" marks anything at or over the stale threshold, and the
# harness-session verdict is spelled out in words. Colour is decoration on top of
# that, auto-enabled only on a terminal and suppressed by NO_COLOR. Columns are
# computed from the real terminal width, the "belongs to" column is dropped
# below 60 columns, and long table values are truncated with a trailing
# ellipsis. Three things are deliberately left whole and allowed to wrap
# instead: the home path, an unreadable-source reason, and every close command.
# A cut-off path, reason, or command is worse than a wrapped one - the command
# in particular has to stay pasteable at any width.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: fm-session-view.sh [--watch] [--interval <seconds>] [--stale-only]
       fm-session-view.sh --json

Show everything running in one overview: this home's workers, its background
services, and the concurrent harness background sessions working in it, plus
every open Lavish review page on this machine (that listing is machine-wide, not
scoped to one home). Anything at or over the stale threshold (3 days, see
FM_SESSION_STALE_DAYS) is marked with a leading "!". The captain's own
background session is marked "(yours)" and is never offered as one to close; a
session whose owner cannot be established from here says "(owner unknown)" and
is not offered either, since ending the wrong one is worse than ending none.

--watch          redraw in place forever; for a pane you leave open.
--interval N     seconds between redraws with --watch (default 60, minimum 15).
--stale-only     show only the rows at or over the stale threshold.
--color <when>   always | never | auto (default auto: colour on a terminal
                 unless NO_COLOR is set).
--json           print the underlying inventory instead of rendering it.

It never closes anything: close commands are printed for you to run.
EOF
}

WATCH=0
STALE_ONLY=0
COLOR=auto
INTERVAL=${FM_SESSION_VIEW_INTERVAL:-60}
MIN_INTERVAL=${FM_SESSION_VIEW_MIN_INTERVAL:-15}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) "$SCRIPT_DIR/fm-session-inventory.sh" --json; exit $? ;;
    --watch) WATCH=1; shift ;;
    --stale-only) STALE_ONLY=1; shift ;;
    --interval) [ "$#" -gt 1 ] || { usage >&2; exit 2; }; INTERVAL=$2; shift 2 ;;
    --interval=*) INTERVAL=${1#--interval=}; shift ;;
    --color) [ "$#" -gt 1 ] || { usage >&2; exit 2; }; COLOR=$2; shift 2 ;;
    --color=*) COLOR=${1#--color=}; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$INTERVAL" in
  ''|*[!0-9]*|0) echo "fm-session-view: --interval must be a positive integer" >&2; exit 2 ;;
esac
case "$MIN_INTERVAL" in ''|*[!0-9]*|0) MIN_INTERVAL=15 ;; esac
if [ "$INTERVAL" -lt "$MIN_INTERVAL" ]; then
  echo "fm-session-view: --interval below the ${MIN_INTERVAL}s floor would poll harder than supervision itself" >&2
  exit 2
fi
case "$COLOR" in
  always|never|auto) ;;
  *) echo "fm-session-view: --color takes always, never, or auto" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-session-view: jq not found" >&2; exit 1; }

# THE PANE IS MEASURED THROUGH THE TERMINAL, NEVER THROUGH WHEREVER OUTPUT IS
# GOING. A frame is assembled inside a command substitution, and the layout is
# decided there, so at that moment stdout is a pipe: `[ -t 1 ]` answers for the
# pipe, and `tput cols` loses the window size with it. Both would then quietly
# report a colourless 100-column terminal for a colour pane 46 columns wide,
# which is the narrow-pane promise this file opens with failing silently.
#
# So the real stdout is duplicated once here, before anything can capture it,
# and the two questions are answered from that descriptor instead: whether it is
# a terminal, decided now, and how wide it is, read with `stty` - which takes
# its terminal from a descriptor rather than from where its own output goes, and
# so keeps answering for the pane from inside any capture. The size is read
# again every pass, so a pane the captain resizes mid-watch is followed.
STDOUT_IS_TTY=0
TTY_FD_SAVED=0
if [ -t 1 ]; then
  STDOUT_IS_TTY=1
  if { exec 3<&1; } 2>/dev/null; then TTY_FD_SAVED=1; fi
fi

use_color() {
  case "$COLOR" in
    always) return 0 ;;
    never) return 1 ;;
  esac
  [ -z "${NO_COLOR:-}" ] && [ "$STDOUT_IS_TTY" = 1 ]
}

term_width() {
  local cols='' size=''
  if [ "$TTY_FD_SAVED" = 1 ]; then
    size=$(stty size <&3 2>/dev/null || true)
  elif [ "$STDOUT_IS_TTY" = 1 ]; then
    size=$(stty size </dev/tty 2>/dev/null || true)
  fi
  case "$size" in *' '*) cols=${size##* } ;; esac
  [ -n "$cols" ] || cols=${COLUMNS:-}
  case "$cols" in ''|*[!0-9]*|0) cols=100 ;; esac
  [ "$cols" -ge 40 ] || cols=40
  printf '%s\n' "$cols"
}

render_once() {  # <width>
  local json colored width=$1
  json=$("$SCRIPT_DIR/fm-session-inventory.sh" --json) || return $?
  if use_color; then colored=1; else colored=0; fi
  printf '%s\n' "$json" | jq -r \
    --argjson width "$width" \
    --argjson color "$colored" \
    --argjson stale_only "$STALE_ONLY" \
    --argjson interval "$INTERVAL" \
    --argjson watching "$WATCH" '
    def paint($code; $text):
      if $color == 1 then "\u001b[\($code)m\($text)\u001b[0m" else $text end;
    def bold($t): paint("1"; $t);
    def warn($t): paint("31"; $t);
    def dim($t): paint("2"; $t);
    def pad($s; $n): ($s // "-") as $v
      | if ($v | length) >= $n then ($v[0:$n]) else $v + (" " * ($n - ($v | length))) end;
    def clip($s; $n): ($s // "-") as $v
      | if $n < 2 then $v[0:$n]
        elif ($v | length) > $n then ($v[0:($n - 1)] + "…")
        else $v end;
    # A path is identified by its tail, so trim it from the left instead.
    def clip_tail($s; $n): ($s // "-") as $v
      | if ($v | length) <= $n or $n < 2 then clip($v; $n)
        else "…" + $v[(($v | length) - $n + 1):] end;
    def age_of($secs; $days):
      if $days == null then "?"
      elif $days > 0 then "\($days)d"
      elif ($secs // 0) >= 3600 then "\((($secs / 3600) | floor))h"
      else "\((($secs // 0) / 60) | floor)m" end;
    def age_text: age_of(.age_seconds; .age_days);
    def what:
      if .kind == "harness-session" then
        "\(.id) live session"
        + (if .self then " (yours)"
           elif (.self_known | not) then " (owner unknown)"
           else "" end)
      elif .kind == "worker" then "\(.id) (\(.label // "task")\(if .held then ", held" else "" end))"
      else (.label // .id) end;
    def task_age_text:
      if .task_age_days == null then "" else "\(.task_age_days)d" end;
    def kind_text:
      if .kind == "harness-session" then "harness"
      elif .kind == "review" then "review"
      else .kind end;

    ($width) as $w
    | (if $w < 60 then 1 else 0 end) as $narrow
    | ([.rows[] | select($stale_only == 0 or .stale)]) as $shown
    # The unasked session-start line and this overview are two different things
    # and do not share a cutoff: notify is the rule for that line, not for this
    # one. Everything shown here that HAS a close command gets it, whatever its
    # age and whether or not the captain is holding it - asking for the overview
    # is asking to be able to close things. Safety is unchanged: close_safety
    # and its note still travel with every command.
    | ([.rows[] | select(.close != null) | select($stale_only == 0 or .stale)]) as $closeable
    | 7 as $kindw
    # AGE is what the "!" marks: running time for a worker with a live process,
    # and the age of the work itself for one with none. TASK is how long the
    # work has existed, and is shown only when there is room for it.
    | (if $w < 78 then 0 else 6 end) as $taskw
    | ([($w - 7 - 12 - 12 - $taskw), 34] | min) as $whatw
    | (if $narrow == 1 then 0 else ([($w - $kindw - $whatw - $taskw - 12), 12] | max) end) as $belongw
    | bold("Sessions - \(.fm_home)"),
      dim("\(.generated) - \(.counts.total) running, \(.counts.stale) over \(.stale_after_days) days"
          + (if $watching == 1 then " - redraw every \($interval)s" else "" end)),
      (.harness_sessions as $h
       | if $h.lock_owner == "ambiguous" then
           warn("! \($h.sessions) background sessions are working in this home at once, under worker runtime \($h.root_pid)")
         elif $h.lock_owner == "stale" then
           warn("! the recorded session lock (\($h.lock_pid)) is no longer a live harness process")
         elif $h.lock_owner == "none" then
           dim("no background session is working in this home")
         elif $h.lock_owner == "absent" then
           dim("no session is currently driving this home")
         elif $h.lock_owner == "single" then
           dim("one background session drives this home")
         elif $h.lock_owner == "not_checked" then
           # With rows, their own note says what was missing. Without them the
           # collector failed before any row existed, and sources[] names that
           # on the very next line - so saying it here too would state one
           # condition twice, and the guess this branch used to make named the
           # wrong one.
           ([.rows[] | select(.kind == "harness-session") | .close_note | select(. != null)]
            | if length == 0 then empty else warn("! " + .[0]) end)
         else
           dim("background sessions: \($h.lock_owner)")
         end),
      (.harness_sessions as $h
       | if $h.self_resolution == "unresolved" and ($h.sessions // 0) > 0 then
           dim("which of these is your own session cannot be told from here, so none is offered for closing")
         else empty end),
      ([.sources[] | select(.ok | not)] | .[]? | warn("! \(.name) unreadable: \(.reason)")),
      "",
      (if ($shown | length) == 0 then
         (if $stale_only == 1 then "Nothing is older than \(.stale_after_days) days."
          else "Nothing is running." end)
       else
         bold("  " + pad("KIND"; $kindw) + " " + pad("WHAT"; $whatw)
              + (if $narrow == 1 then "" else " " + pad("BELONGS TO"; $belongw) end)
              + "  " + pad("AGE"; 8)
              + (if $taskw == 0 then "" else pad("TASK"; $taskw) end)),
         ($shown[] |
           (if .stale then warn("!") else " " end) + " "
           + pad(kind_text; $kindw) + " " + pad(clip(what; $whatw); $whatw)
           + (if $narrow == 1 then "" else " " + pad(clip_tail(.belongs_to; $belongw); $belongw) end)
           + "  " + pad(age_text; 8)
           + (if $taskw == 0 then "" else pad(task_age_text; $taskw) end))
       end),
      (.harness_sessions as $h
       | if ($h.elsewhere // 0) == 0 or $stale_only == 1 then empty
         else dim("  \($h.elsewhere) other process(es) under the same worker runtime belong to the pool or to other homes")
         end),
      (if ($closeable | length) == 0 then empty else
         "",
         bold("To close"),
         ($closeable[] |
           "  " + .close
           + (if .close_safety == "safe" then ""
              else "\n      " + dim("\(.close_safety): \(.close_note // "check before closing")") end))
       end)
    '
}

if [ "$WATCH" = 0 ]; then
  render_once "$(term_width)"
  exit $?
fi

# Redraw in place. Cursor-home then clear, rather than a full terminal reset, so
# the pane stops flickering and the captain's scrollback survives.
#
# THE FRAME IS BUILT BEFORE THE PANE IS CLEARED. Clearing first left the pane
# blank for the whole of every pass - the second or two a normal collection
# costs, and up to the sum of the per-source bounds when one of them wedges.
# That is the same cleared-and-frozen pane those bounds exist to prevent, just
# time-boxed. So the frame is rendered into a variable and the pane is cleared
# only once there is something to put in its place; a pass that could not read
# the inventory at all leaves the previous frame standing rather than wiping it
# for an error.
trap 'exit 0' INT TERM
while :; do
  pane_width=$(term_width)
  if frame=$(render_once "$pane_width"); then
    if [ "$STDOUT_IS_TTY" = 1 ]; then
      printf '\033[H\033[2J'
    fi
    printf '%s\n' "$frame"
  else
    printf 'fm-session-view: could not read the inventory this pass\n' >&2
  fi
  sleep "$INTERVAL"
done
