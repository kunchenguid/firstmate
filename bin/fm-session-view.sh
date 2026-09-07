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

Show everything running for this firstmate home in one overview: workers, open
Lavish review pages, background services, and concurrent harness background
sessions. Anything at or over the stale threshold (3 days, see
FM_SESSION_STALE_DAYS) is marked with a leading "!".

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

use_color() {
  case "$COLOR" in
    always) return 0 ;;
    never) return 1 ;;
  esac
  [ -z "${NO_COLOR:-}" ] && [ -t 1 ]
}

term_width() {
  local cols=''
  if [ -t 1 ]; then
    cols=$(tput cols 2>/dev/null || true)
  fi
  [ -n "$cols" ] || cols=${COLUMNS:-}
  case "$cols" in ''|*[!0-9]*|0) cols=100 ;; esac
  [ "$cols" -ge 40 ] || cols=40
  printf '%s\n' "$cols"
}

render_once() {
  local json width colored
  json=$("$SCRIPT_DIR/fm-session-inventory.sh" --json) || return $?
  width=$(term_width)
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
      if .kind == "harness-session" then "\(.id) \(if .label == "spare" then "idle spare" elif .label == "session" then "live session" else "unclassified" end)"
      elif .kind == "worker" then "\(.id) (\(.label // "task"))"
      else (.label // .id) end;
    def kind_text:
      if .kind == "harness-session" then "harness"
      elif .kind == "review" then "review"
      else .kind end;

    ($width) as $w
    | (if $w < 60 then 1 else 0 end) as $narrow
    # Idle pool processes are not sessions and there can be many of them, so the
    # quiet ones collapse into one line. Every one that is old enough to act on
    # still gets its own row, and --stale-only and --json keep them all.
    | ([.rows[] | select(.kind == "harness-session" and .label == "spare" and (.stale | not))]) as $idle
    | ([.rows[] | select($stale_only == 0 or .stale)
        | select(.kind != "harness-session" or .label != "spare" or .stale)]) as $shown
    | ([.rows[] | select(.notify) | select($stale_only == 0 or .stale)]) as $closeable
    | 7 as $kindw
    | ([($w - 7 - 12 - 12), 34] | min) as $whatw
    | (if $narrow == 1 then 0 else ([($w - $kindw - $whatw - 12), 12] | max) end) as $belongw
    | bold("Sessions - \(.fm_home)"),
      dim("\(.generated) - \(.counts.total) running, \(.counts.stale) over \(.stale_after_days) days"
          + (if $watching == 1 then " - redraw every \($interval)s" else "" end)),
      (.harness_sessions as $h
       | if $h.lock_owner == "ambiguous" then
           warn("! \($h.sessions + $h.unknown) background sessions share harness daemon \($h.root_pid) and none can be told apart as the driver of this home")
         elif $h.lock_owner == "stale" then
           warn("! the recorded session lock (\($h.lock_pid)) is no longer a live harness process")
         elif $h.lock_owner == "none" then
           dim("no live background session under harness daemon \($h.root_pid)")
         elif $h.lock_owner == "single" or $h.lock_owner == "unique" then
           dim("one background session drives this home")
         else
           dim("background sessions: \($h.lock_owner)")
         end),
      ([.sources[] | select(.ok | not)] | .[]? | warn("! \(.name) unreadable: \(.reason)")),
      "",
      (if ($shown | length) == 0 then
         (if $stale_only == 1 then "Nothing is older than \(.stale_after_days) days."
          else "Nothing is running." end)
       else
         bold("  " + pad("KIND"; $kindw) + " " + pad("WHAT"; $whatw)
              + (if $narrow == 1 then "" else " " + pad("BELONGS TO"; $belongw) end)
              + "  AGE"),
         ($shown[] |
           (if .stale then warn("!") else " " end) + " "
           + pad(kind_text; $kindw) + " " + pad(clip(what; $whatw); $whatw)
           + (if $narrow == 1 then "" else " " + pad(clip_tail(.belongs_to; $belongw); $belongw) end)
           + "  " + age_text)
       end),
      (if ($idle | length) == 0 or $stale_only == 1 then empty else
         dim("  " + pad("harness"; $kindw) + " "
             + pad(clip("+\($idle | length) idle spares (pool, not sessions)"; $whatw); $whatw)
             + (if $narrow == 1 then "" else " " + pad(""; $belongw) end)
             + "  " + age_of(([$idle[].age_seconds] | max); ([$idle[].age_days] | max)))
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
  render_once
  exit $?
fi

# Redraw in place. Cursor-home then clear, rather than a full terminal reset, so
# the pane stops flickering and the captain's scrollback survives.
trap 'exit 0' INT TERM
while :; do
  if [ -t 1 ]; then
    printf '\033[H\033[2J'
  fi
  render_once || printf 'fm-session-view: could not read the inventory this pass\n' >&2
  sleep "$INTERVAL"
done
