#!/usr/bin/env bash
# fm-session-inventory.sh - structured "what is running right now" inventory.
#
# Output contract: `--json` prints one object with schema
# `fm-session-inventory.v1`. The command is READ-ONLY over this home: it never
# acquires the session lock, drains wakes, arms or signals a watcher, touches
# the backlog, or writes any state record. It never stops, kills, or signals
# anything it reports; every close instruction is data in a `close` field for a
# human to run, never something this command executes.
#
# WHY IT EXISTS. Four unrelated things can be running at once and no single
# surface showed them together: this home's workers, the review pages Lavish is
# serving, the background services that keep the fleet moving, and - the case
# that caused real damage - two concurrent harness background sessions under one
# shared harness daemon, each believing it owned this home.
#
# SCOPE, HONESTLY. Workers, services, and harness sessions are scoped to this
# home. Review pages are NOT: Lavish keeps one machine-wide list, and showing
# all of it here is deliberate - the captain works across many projects and
# asked for exactly that. Only the unasked --stale-lines output narrows, and
# only so that every home on the machine does not repeat the same review lines;
# the note on that mode at the end of this file gives the reasoning.
#
# ONE TRUTH, NOT A SECOND ONE. Worker rows are derived from
# bin/fm-fleet-snapshot.sh --json, which stays the single owner of fleet state;
# this script adds only what that snapshot does not model (Lavish review pages,
# background services, harness sessions) and never re-parses backlog or task
# metadata itself. bin/fm-session-view.sh is the human renderer over this
# output, exactly as bin/fm-fleet-view.sh renders the fleet snapshot.
#
# Top-level fields:
#   schema            stable schema id.
#   generated         UTC observation time; generated_epoch is the same instant.
#   fm_home, fm_root  resolved operational home and tracked code root.
#   stale_after_days  the age at or above which a row is marked stale.
#   rows[]            uniform rows, ordered kind-then-age, described below.
#   counts            {total, stale, notify, by_kind{worker,review,service,harness_session}}.
#   harness_sessions  {root_pid, lock_pid, lock_owner, self_resolution,
#                     sessions, own_workers, elsewhere}.
#                     `sessions` counts the live harness sessions working in THIS
#                     home. `own_workers` counts the harness processes running
#                     one of this home's own workers, which are reported as
#                     worker rows and are deliberately not counted anywhere else:
#                     one running thing is one row. `elsewhere` counts what is
#                     left under the same harness - pool machinery and other
#                     homes' sessions - which is neither listed nor claimed here.
#                     The three together account for every harness process under
#                     the recorded lock's harness, which is what lets the live
#                     drift guard prove none has been quietly lost.
#                     self_resolution says which signal answered "which of these
#                     is the captain's own session": "ancestry", "unresolved"
#                     when it could not, and "not_applicable" when there is no
#                     session to ask it about. See WHOSE SESSION IS THIS below;
#                     "unresolved" is why a row can be a live session and still
#                     carry no close command.
#                     lock_owner is the honest answer to "which background
#                     session drives this home": "single" when exactly one
#                     session under the recorded lock's harness works in this
#                     home, "ambiguous" when several do and no single one can be
#                     attributed, "none" when the lock's harness is alive but
#                     none of its sessions works in this home, "stale" when the
#                     recorded pid is not a live harness process, "absent" when
#                     no lock is recorded, and "not_checked" when an input the
#                     verdict rests on could not be read at all - the process
#                     working directories, or the fleet snapshot that says which
#                     of these processes are this home's own workers. sources[]
#                     always names which one it was. "not_checked" withholds
#                     every session close command for that reason.
#   sources[]         {name, ok, reason} - one per collector, so an unreadable
#                     source is disclosed instead of silently reported as zero.
#                     `ok` is false ONLY when the collector could not read its
#                     input. One that read everything and reached a definite
#                     answer stays ok and carries that answer as its reason -
#                     because false is what spends the unasked session-start
#                     line, and a completed check may never spend it.
#
# Row fields:
#   kind          worker | review | service | harness-session.
#   id            stable identifier within the kind.
#   label         short human name.
#   belongs_to    what it belongs to (project, task, home, daemon).
#   detail        one extra descriptive string, or null.
#   pid           process id when the row is a live process, else null.
#   started       UTC start time when known, else null.
#   age_seconds   how long this row has been around, in seconds, or null when
#                 that cannot be established. age_days is whole days. For a
#                 worker this is its RUNNING time whenever a live harness
#                 process is working in its worktree, and the age of the work
#                 itself when no process is running - abandoned work still
#                 holding a worktree is exactly what the overdue warning is for.
#   age_source    where that age came from: "process" (running time),
#                 "backlog-since" (nothing running, so the work's own date),
#                 "file-mtime", or null.
#   stale         true when age_days >= stale_after_days.
#   task_age_seconds, task_age_days
#                 how long the WORK has existed, for a worker row. Always
#                 reported, so a running worker shows its running time and the
#                 age of its task side by side.
#   held          true when the captain is deliberately holding this work.
#   self          true for a harness-session row proven to be the captain's own
#                 session. It carries no close command, because an overview that
#                 offers to end the conversation it is being read in is worse
#                 than no overview.
#   self_known    false when ownership of a harness-session row could not be
#                 established at all, which also withholds its close command.
#                 Both fields carry meaning only on harness-session rows.
#   notify        true when the row is stale, has a close command, and is not
#                 held. A row with no single safe close command is not something
#                 a human can act on by age, so long-lived shared infrastructure
#                 stays visible in the view without occupying the unasked
#                 session-start line. A captain hold is excluded for a different
#                 reason: it is deliberate, and the backlog captain-hold
#                 lifecycle already owns surfacing it, so repeating it here would
#                 report one parked decision from two places.
#   close         exact command a human may run to close it, or null.
#   close_safety  safe | confirm | manual. "confirm" means closing it can lose
#                 work in progress and needs an explicit decision first;
#                 "manual" means there is no single safe command here.
#   close_note    why, when close_safety is not "safe".
#
# HARNESS-SESSION IDENTITY is built on kernel facts only. Whether a process is a
# verified harness is decided by bin/fm-session-lock-lib.sh, the fleet's single
# owner of that question; the parent/child relation and the working directory
# come from the kernel. No vendor argv string is read at all.
#
# That matters because a harness pre-warms pooled processes and turns one into a
# session by CLAIMING it, and a claimed process keeps the argv it started with.
# Reading argv therefore cannot tell a live session from an idle spare - measured
# against the real fleet, it reported four live sessions in one home as zero.
# The working directory does change on a claim: an unclaimed process still sits
# in the harness pool, a claimed one works in the home it was claimed for. So a
# process is a session FOR THIS HOME when its working directory is this home,
# and everything else under the same harness is counted without being claimed.
#
# NO NETWORK, NO WRITES. The fleet snapshot underneath is run with
# FM_SNAPSHOT_LOCAL_ONLY=1, which is what makes the read-only promise above
# true. That flag closes both of the snapshot's write paths: cross-home
# secondmate ledgers (its only network read and its only cache refresh), and the
# per-task busy classifier's own memo of muse's resolved session log, which it
# runs read-only through FM_BUSY_READ_ONLY. This overview uses no cross-home
# data at all, and it sits both on the blocking session-start path and in a pane
# that redraws on a timer - neither may leave the machine, and neither may
# rewrite a state file underneath the watcher that owns it.
#
# Bounds. FM_SESSION_INVENTORY_FLEET_TIMEOUT (default 20s) bounds the fleet
# snapshot, FM_SESSION_INVENTORY_LAVISH_TIMEOUT (default 8s) bounds the Lavish
# listing, and FM_SESSION_INVENTORY_CWD_TIMEOUT (default 8s) bounds the working
# directory read; a bound that is hit is reported as an unreadable source, never
# as an empty result. FM_SESSION_STALE_DAYS (default 3) sets the stale
# threshold.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# EVERY DIRECTORY COMPARED AGAINST A PROCESS IS PHYSICAL, ON BOTH SIDES. The
# kernel reports a process working directory with every symlink already
# resolved - /private/var rather than /var on macOS, and any symlinked component
# of a home anywhere. A home or worktree left in its logical form therefore
# matches no running process at all: every session would be counted as belonging
# elsewhere, lock_owner would read "none", and the source would still be
# reported ok. That is the silent form of the exact failure this command exists
# to make loud, so both sides are resolved here, once, rather than at any single
# comparison.
physical_path() {  # <path>
  local phys=''
  [ -n "$1" ] || return 1
  phys=$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)
  printf '%s\n' "${phys:-$1}"
}
FM_ROOT=$(physical_path "$FM_ROOT")
FM_HOME=$(physical_path "$FM_HOME")
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-session-lock-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-session-lock-lib.sh"  # fm_harness_process_matches: the one harness-identity owner
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"  # fm_run_timed: the shared hard bound
# shellcheck source=bin/fm-primary-scope-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"  # fm_root_is_secondmate_home: the one main-vs-secondmate owner

STALE_DAYS=${FM_SESSION_STALE_DAYS:-3}
case "$STALE_DAYS" in
  ''|*[!0-9]*) echo "fm-session-inventory: FM_SESSION_STALE_DAYS must be a non-negative integer" >&2; exit 2 ;;
esac
FLEET_TIMEOUT=${FM_SESSION_INVENTORY_FLEET_TIMEOUT:-20}
LAVISH_TIMEOUT=${FM_SESSION_INVENTORY_LAVISH_TIMEOUT:-8}
CWD_TIMEOUT=${FM_SESSION_INVENTORY_CWD_TIMEOUT:-8}
for bound_name in FLEET_TIMEOUT LAVISH_TIMEOUT CWD_TIMEOUT; do
  case "${!bound_name}" in
    ''|*[!0-9]*|0)
      echo "fm-session-inventory: FM_SESSION_INVENTORY_${bound_name} must be a positive integer" >&2
      exit 2
      ;;
  esac
done

NOW_EPOCH=${FM_SESSION_INVENTORY_NOW_EPOCH:-$(date -u +%s)}
case "$NOW_EPOCH" in ''|*[!0-9]*) NOW_EPOCH=$(date -u +%s) ;; esac

usage() {
  cat <<'EOF'
usage: fm-session-inventory.sh --json
       fm-session-inventory.sh --stale-lines

Print what is running: this home's workers, its background services, and the
harness background sessions working in it, plus every open Lavish review page.
Review pages are MACHINE-WIDE and deliberately so - Lavish keeps one list for
every project on this machine, and seeing all of them in one place is the point.
Everything else is scoped to this home.

--json         the stable machine-readable contract (schema fm-session-inventory.v1).
--stale-lines  one short line per row at or over the stale threshold, and
               nothing at all when none is. This is what the session-start
               bootstrap surfaces unasked. Because the review pages are
               machine-wide, only the main home names them here; a secondmate
               home leaves them to it rather than every home on the machine
               repeating the same lines at every session start.

Read-only: it never closes, kills, or signals anything it reports.
EOF
}

MODE=
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) MODE=json ;;
  --stale-lines) MODE=stale ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "fm-session-inventory: jq not found" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-session-inventory.XXXXXX") || exit 1
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT
ROWS="$WORK/rows.tsv"
SOURCES="$WORK/sources.tsv"
: > "$ROWS"
: > "$SOURCES"

note_source() {  # <name> <ok:0|1> <reason>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SOURCES"
}

# Every close command in the output is meant to be pasted into a shell exactly
# as printed, and real paths here contain spaces (a Lavish artifact under
# "Project Files", a home with a space in it). A value that needs quoting is
# quoted; one that does not is left bare, so an ordinary command still reads as
# the plain command it is.
shell_quote() {  # <value>
  case $1 in
    ''|*[!A-Za-z0-9_/.:@%+,=-]*)
      printf "'%s'" "$(printf '%s' "$1" | LC_ALL=C sed "s/'/'\\\\''/g")"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

# One row per line. Empty field = null in JSON. The trailing `held` column is 1
# for work the captain is deliberately holding, and the `self` column is 1 for
# the one row that IS the process running this command.
emit_row() {  # kind id label belongs_to detail pid age_seconds age_source close close_safety close_note [held] [task_age_seconds] [self]
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12:-0}" "${13:-}" "${14:-0}" >> "$ROWS"
}

# --- the one process-table read ----------------------------------------------
# pid \t ppid \t age_seconds \t args. `etime` is used rather than `lstart`
# because both BSD and procps render it and it needs no timezone parsing;
# macOS has no `etimes` at all.
PSTABLE="$WORK/ps.tsv"
if ps -eo pid=,ppid=,etime=,args= 2>/dev/null | LC_ALL=C awk '
    function etime_secs(s,   n,a,d,hh,mm,ss,p) {
      d = 0
      if (index(s, "-") > 0) { split(s, p, "-"); d = p[1] + 0; s = p[2] }
      n = split(s, a, ":")
      if (n == 3) { hh = a[1] + 0; mm = a[2] + 0; ss = a[3] + 0 }
      else if (n == 2) { hh = 0; mm = a[1] + 0; ss = a[2] + 0 }
      else return -1
      return ((d * 24 + hh) * 60 + mm) * 60 + ss
    }
    {
      pid = $1; ppid = $2; secs = etime_secs($3)
      args = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]*/, "", args)
      gsub(/[\t\r\n]/, " ", args)
      if (pid ~ /^[0-9]+$/ && ppid ~ /^[0-9]+$/ && secs >= 0)
        printf "%s\t%s\t%s\t%s\n", pid, ppid, secs, args
    }' > "$PSTABLE" && [ -s "$PSTABLE" ]; then
  note_source process-table 1 ''
else
  : > "$PSTABLE"
  note_source process-table 0 'ps produced no readable process table'
fi

# Working directory per pid, read once for every harness process found.
#
# THIS IS THE SIGNAL THAT DECIDES WHAT IS A LIVE SESSION. A harness pre-warms
# pooled processes and turns one into a session by CLAIMING it, and the claimed
# process keeps the argv it was started with - so argv cannot tell a live
# session from an idle spare, and reading it that way reported four live
# sessions in one home as zero. What does change on a claim is the working
# directory: an unclaimed process still sits in the harness pool, and a claimed
# one is working in the home or worktree it was claimed for. That is a kernel
# fact, not a vendor string, and it is also what ties a running process to the
# task it is running.
CWDMAP="$WORK/cwd.tsv"
: > "$CWDMAP"
# BOUNDED LIKE ITS SIBLINGS. Without `-p` this stats the working directory of
# every process on the machine, so a single cwd on a wedged mount blocks it for
# as long as that mount stays wedged. The session-start path is covered from
# outside, but the pane the captain leaves open all day is not: a redraw that
# never returns leaves it cleared and frozen, which is this overview failing
# silently in the one mode it exists for. The bound is the Lavish listing's 8s -
# the same order as the reads it sits beside, and forty times the 0.19s a real
# machine-wide pass measures - and reaching it resolves nothing, which the
# callers already disclose as an unreadable source.
CWD_READ_NOTE='cannot read process working directories here'
bounded_lsof_cwds() {  # [lsof args...]
  local rc=0 raw="$WORK/lsof.out"
  : > "$raw"
  fm_run_timed "$CWD_TIMEOUT" lsof -a -d cwd -Fpn "$@" > "$raw" 2>/dev/null || rc=$?
  if [ "$rc" = 124 ]; then
    CWD_READ_NOTE="reading process working directories exceeded ${CWD_TIMEOUT}s"
    return 1
  fi
  LC_ALL=C awk '
    /^p/ { pid = substr($0, 2); next }
    /^n/ { if (pid != "") { printf "%s\t%s\n", pid, substr($0, 2); pid = "" } }' \
    < "$raw" > "$CWDMAP"
}
# A reader that produced no directory at all read nothing, whatever the exit
# status of the last pipeline stage was. Saying so is what keeps a denied or
# sandboxed lsof from being reported as "nothing is running here".
cwdmap_has_a_directory() {
  LC_ALL=C awk -F'\t' '$2 != "" { found = 1; exit } END { exit(found ? 0 : 1) }' "$CWDMAP"
}
read_cwds() {  # <pid>...
  local pid joined
  [ "$#" -gt 0 ] || return 0
  if [ -r /proc/self/cwd ]; then
    for pid in "$@"; do
      printf '%s\t%s\n' "$pid" "$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    done > "$CWDMAP"
    cwdmap_has_a_directory
    return
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  joined=$(printf '%s,' "$@"); joined=${joined%,}
  # One batched call: per-pid invocations cost more than the whole rest of the
  # collection put together.
  bounded_lsof_cwds -p "$joined" || return 1
  cwdmap_has_a_directory
}
# Every process's working directory in one call. Used where the interesting set
# is not known in advance, so that filtering on the directory can come before
# the far more expensive question of whether a pid is a verified harness.
read_all_cwds() {
  local pid
  if [ -r /proc/self/cwd ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      printf '%s\t%s\n' "$pid" "$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    done < <(LC_ALL=C awk -F'\t' '{ print $1 }' "$PSTABLE") > "$CWDMAP"
    cwdmap_has_a_directory
    return
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  bounded_lsof_cwds || return 1
  cwdmap_has_a_directory
}

cwd_of() {  # <pid>
  LC_ALL=C awk -F'\t' -v want="$1" '$1 == want { print $2; exit }' "$CWDMAP"
}
# True when <cwd> is <dir> itself or lies inside it.
path_within() {  # <cwd> <dir>
  local cwd=$1 dir=$2
  [ -n "$cwd" ] && [ -n "$dir" ] || return 1
  [ "$cwd" = "$dir" ] && return 0
  case "$cwd" in "$dir"/*) return 0 ;; esac
  return 1
}

ps_field() {  # <pid> <1=ppid|2=age|3=args>
  LC_ALL=C awk -F'\t' -v want="$1" -v col="$2" '$1 == want { print $(col + 1); exit }' "$PSTABLE"
}
ps_alive() { [ -n "$(ps_field "$1" 1)" ]; }
ps_children() { LC_ALL=C awk -F'\t' -v parent="$1" '$2 == parent { print $1 }' "$PSTABLE"; }

file_age_seconds() {  # <path>
  local mtime
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m -- "$1" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y -- "$1" 2>/dev/null) || return 1
  fi
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((NOW_EPOCH - mtime))"
}

# Every live harness process working in one of this home's worker worktrees.
# A worker is matched to its running process by that directory: the process a
# worker is running in has the worker's own worktree as its cwd, whatever
# backend hosts the pane and whatever the harness called itself.
#
# WORKING DIRECTORY IS READ FIRST, ON PURPOSE. Deciding whether a pid is a
# verified harness is the expensive question here - the owning library shells
# out per process - and asking it of every process on the machine cost about
# fifteen seconds on a 900-process desktop, five times the whole rest of the
# command and well past the budget the session-start line is allowed. Working
# directories come from one batched read for every process at once, so filtering
# on them first leaves only the handful of processes actually sitting in a
# worker's worktree to verify. Same answer, one cheap question before the dear
# one.
WORKER_PROCS="$WORK/worker-procs.tsv"
: > "$WORKER_PROCS"
# The worktrees this home's workers occupy, resolved once. They are recorded
# separately from the process scan because the harness-session collector needs
# them too: a worker's worktree lives INSIDE the home (bin/fm-spawn.sh puts them
# under $FM_HOME/projects), so a bare containment test would claim a worker's
# own process a second time as a standalone background session - offering a bare
# `kill` for work whose real close command refuses rather than discarding
# unlanded work, and, with two such workers, raising the "several sessions in
# this home at once" alarm for something that is not that condition at all.
WORKER_DIRS="$WORK/worker-dirs.tsv"
: > "$WORKER_DIRS"
# WHETHER THAT LIST CAN BE BELIEVED AT ALL. The worktrees come from the fleet
# snapshot, so a snapshot that could not be read leaves this file empty - and an
# empty list is indistinguishable from "this home has no workers". Telling those
# two apart is the whole basis for calling a process a background session rather
# than a worker, so the difference is recorded rather than inferred from the
# file being empty.
FLEET_SNAPSHOT_OK=1
collect_worker_processes() {  # <worktree>...
  local pid cwd age dir saved keep
  local -a dirs=()
  [ "$#" -gt 0 ] || return 0
  # Physical on both sides, for the reason physical_path states: a worktree
  # reached through a symlink would match none of its own running processes.
  # The home itself is never subtracted: a task whose recorded path IS this home
  # would otherwise erase every session working in it.
  for dir in "$@"; do
    dir=$(physical_path "$dir")
    [ "$dir" != "$FM_HOME" ] || continue
    dirs+=("$dir")
    printf '%s\n' "$dir" >> "$WORKER_DIRS"
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  [ -s "$PSTABLE" ] || return 0
  saved=$CWDMAP
  CWDMAP="$WORK/worker-cwd.tsv"
  if ! read_all_cwds; then
    note_source worker-processes 0 \
      "$CWD_READ_NOTE, so a running worker cannot be matched to its own process"
    CWDMAP=$saved
    return 0
  fi
  note_source worker-processes 1 ''
  while IFS=$'\t' read -r pid cwd; do
    [ -n "$pid" ] && [ -n "$cwd" ] || continue
    keep=0
    for dir in "${dirs[@]}"; do
      if path_within "$cwd" "$dir"; then keep=1; break; fi
    done
    [ "$keep" = 1 ] || continue
    # Only now, for the few survivors, ask the expensive question.
    is_harness_pid "$pid" || continue
    age=$(ps_field "$pid" 2)
    printf '%s\t%s\t%s\n' "$pid" "$age" "$cwd" >> "$WORKER_PROCS"
  done < "$CWDMAP"
  CWDMAP=$saved
}

# True when <cwd> lies in one of this home's worker worktrees, which makes the
# process a worker's own - already reported as a worker row, with the close
# command that refuses rather than discarding unlanded work - and never a
# standalone background session.
within_a_worker_worktree() {  # <cwd>
  local dir
  [ -s "$WORKER_DIRS" ] || return 1
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    path_within "$1" "$dir" && return 0
  done < "$WORKER_DIRS"
  return 1
}

# Longest-running harness process working in <dir>. Longest rather than newest
# because a worker's own process tree can be several harness processes deep, and
# the outermost one is the incarnation that has actually been up the whole time.
worker_runtime_seconds() {  # <worktree>
  local dir best='' pid age cwd
  [ -n "$1" ] || return 1
  dir=$(physical_path "$1")
  while IFS=$'\t' read -r pid age cwd; do
    [ -n "$pid" ] || continue
    path_within "$cwd" "$dir" || continue
    case "$age" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$best" ] || [ "$age" -gt "$best" ]; then best=$age; fi
  done < "$WORKER_PROCS"
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# --- 1. workers, from the fleet snapshot (the single owner of fleet state) ----
collect_workers() {
  local snapshot_file="$WORK/fleet.json" rc=0
  # FM_SNAPSHOT_LOCAL_ONLY is what keeps this command's read-only, no-network
  # promise honest. Without it the snapshot reads every registered REMOTE
  # secondmate ledger over the network and refreshes a parent-side cache - a
  # network call and a state write. Neither is acceptable here: this runs on the
  # blocking session-start path, where nothing may leave the machine, and in a
  # display that redraws on a timer. The overview uses no cross-home ledger data
  # at all, so nothing it shows is lost.
  FM_SNAPSHOT_LOCAL_ONLY=1 fm_run_timed "$FLEET_TIMEOUT" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json \
    > "$snapshot_file" 2>"$WORK/fleet.err" || rc=$?
  if [ "$rc" = 124 ]; then
    FLEET_SNAPSHOT_OK=0
    note_source fleet-snapshot 0 "fleet snapshot exceeded ${FLEET_TIMEOUT}s"
    return 0
  fi
  if [ "$rc" != 0 ] || ! jq -e . "$snapshot_file" >/dev/null 2>&1; then
    FLEET_SNAPSHOT_OK=0
    note_source fleet-snapshot 0 "fleet snapshot failed (exit $rc)"
    return 0
  fi
  note_source fleet-snapshot 1 ''
  local id kind repo window worktree since state hold_kind
  local busy close safety cnote age age_source held task_age
  # The worktrees come from the snapshot, so the process scan can be narrowed to
  # the directories that can possibly host a worker before any pid is verified.
  local -a worktrees=()
  while IFS= read -r worktree; do
    [ -n "$worktree" ] || continue
    worktrees+=("$worktree")
  done < <(jq -r '.tasks[]? | (.paths.worktree.path // .paths.home.path // "") | select(. != "")' \
    "$snapshot_file" | LC_ALL=C sort -u)
  collect_worker_processes ${worktrees[@]+"${worktrees[@]}"}
  while IFS=$'\t' read -r id kind repo window worktree since state hold_kind; do
    [ -n "$id" ] || continue
    # RUNNING TIME FIRST, TASK AGE ONLY WHEN NOTHING IS RUNNING. Reading the
    # task's own date whenever it existed flagged a worker that started ten
    # minutes ago as overdue, because the task had been filed weeks earlier;
    # that makes the warning worthless. So a worker with a live harness process
    # working in its own worktree is aged by that process.
    #
    # A worker with NO live process is not thereby uninteresting: it is
    # abandoned work still holding a worktree, and how long it has sat there is
    # exactly what the captain asked to be told about. For that row the task's
    # own date is the honest age, and age_source says so, so nothing is silently
    # dropped from the overdue warning just because its process is gone.
    task_age=''
    if [ -n "$since" ]; then
      # tasks-axi records a date; midnight UTC is the honest floor for its age.
      task_age=$(date -u -j -f '%Y-%m-%d %H:%M:%S' "$since 00:00:00" +%s 2>/dev/null \
        || date -u -d "$since 00:00:00" +%s 2>/dev/null || true)
      if [ -n "$task_age" ]; then
        task_age=$((NOW_EPOCH - task_age))
        [ "$task_age" -ge 0 ] || task_age=0
      fi
    fi
    age=''
    age_source=''
    if [ -n "$worktree" ] && age=$(worker_runtime_seconds "$worktree"); then
      age_source=process
    elif [ -n "$task_age" ]; then
      age=$task_age
      age_source=backlog-since
    fi
    busy=$state
    if [ "$kind" = secondmate ]; then
      close=''
      safety=manual
      cnote='persistent second mate; retire only through an explicit decision'
    else
      close="$(close_prefix)bin/fm-teardown.sh $(shell_quote "$id")"
      # The vocabulary here is bin/fm-crew-state.sh's, which is where this state
      # comes from: working | parked | done | blocked | paused | failed |
      # unknown. Anything that can still be holding unlanded work, and anything
      # whose state could not be read at all, has to be decided on rather than
      # presented as safe.
      case "$busy" in
        working)
          safety=confirm
          cnote='work in progress; cleanup refuses while anything is unlanded'
          ;;
        paused|blocked)
          safety=confirm
          cnote="$busy, so it can still be holding unlanded work"
          ;;
        ''|unknown)
          safety=confirm
          cnote='its state could not be read, so what it still holds is unknown'
          ;;
        *)
          safety=safe
          cnote='refuses rather than discarding unlanded work'
          ;;
      esac
    fi
    held=0
    [ "$hold_kind" != captain ] || held=1
    emit_row worker "$id" "$kind" "${repo:-$id}" "${window:+window $window}${worktree:+ in $worktree}" \
      '' "${age:-}" "$age_source" "$close" "$safety" "$cnote" "$held" "${task_age:-}"
  done < <(jq -r '
      .tasks[]? |
      [ .id,
        (.kind // "task"),
        (.backlog.repo // .project // ""),
        (.endpoint.target // ""),
        (.paths.worktree.path // .paths.home.path // ""),
        (.backlog.since // ""),
        (.current_state.state // ""),
        (.backlog.hold_kind // "")
      ] | @tsv' "$snapshot_file")
}

# Commands are written to be pasted from the firstmate root. A home that is not
# the code root needs its FM_HOME stated, or the command would act on the wrong
# home.
close_prefix() {
  [ "$FM_HOME" = "$FM_ROOT" ] || printf 'FM_HOME=%s ' "$(shell_quote "$FM_HOME")"
}

# --- 2. open Lavish review pages ---------------------------------------------
# The bare `lavish-axi` listing is the authoritative set of OPEN review pages,
# and it is MACHINE-WIDE: Lavish serves one list for every project on this
# machine, so these rows are not scoped to this home and are not meant to be.
# Age comes from the poll process actually serving that page when one is
# running, and from the artifact's own mtime otherwise.
collect_reviews() {
  local out="$WORK/lavish.txt" rc=0 file status url pending sid age age_source pid safety cnote
  if ! command -v lavish-axi >/dev/null 2>&1; then
    # Not installed is not unreadable: there are no review pages on this machine
    # to miss, so this collector answered zero truthfully and must not put a
    # "could not check everything" line on every session start forever.
    note_source lavish 1 'lavish-axi is not installed, so this machine serves no review pages'
    return 0
  fi
  fm_run_timed "$LAVISH_TIMEOUT" lavish-axi > "$out" 2>/dev/null || rc=$?
  if [ "$rc" = 124 ]; then
    note_source lavish 0 "lavish-axi listing exceeded ${LAVISH_TIMEOUT}s"
    return 0
  fi
  if ! LC_ALL=C grep -q '^sessions\[' "$out" 2>/dev/null; then
    note_source lavish 0 'lavish-axi printed no sessions listing'
    return 0
  fi
  note_source lavish 1 ''
  while IFS=$'\t' read -r file status url pending; do
    [ -n "$file" ] || continue
    sid=${url##*/session/}
    [ -n "$sid" ] && [ "$sid" != "$url" ] || sid=$(basename -- "$file")
    age=''
    age_source=''
    pid=$(LC_ALL=C awk -F'\t' -v needle="$file" '
      index($4, "lavish-axi") && index($4, "poll") && index($4, needle) { print $1; exit }' "$PSTABLE")
    if [ -n "$pid" ]; then
      age=$(ps_field "$pid" 2)
      age_source=process
    elif age=$(file_age_seconds "$file"); then
      age_source="file-mtime"
    fi
    if [ "${pending:-0}" != 0 ]; then
      safety=confirm
      cnote="$pending queued note(s) from the captain would be lost"
    else
      safety=safe
      cnote=''
    fi
    emit_row review "$sid" "$(basename -- "$file")" "$(dirname -- "$file")" \
      "${status:-open}${url:+ $url}" "$pid" "${age:-}" "$age_source" \
      "lavish-axi end $(shell_quote "$file")" "$safety" "$cnote"
  done < <(LC_ALL=C awk '
      /^sessions\[/ { inblock = 1; next }
      inblock && /^[^[:space:]]/ { inblock = 0 }
      inblock {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        if (line == "") next
        # file,status,"url",pending - the file path never contains a comma in a
        # Lavish artifact path, and the url is the only quoted field.
        n = split(line, f, ",")
        if (n < 4) next
        url = f[3]; gsub(/^"|"$/, "", url)
        printf "%s\t%s\t%s\t%s\n", f[1], f[2], url, f[n]
      }' "$out")
}

# --- 3. background services keeping this home running ------------------------
# Home-scoped by construction: every service is found through THIS home's own
# state records or through an argv that names a shared machine-wide service.
# Nothing here matches a sibling firstmate home's watcher.
service_row() {  # <id> <label> <belongs_to> <pid> <close> <safety> <note>
  local age='' age_source=''
  if [ -n "$4" ] && ps_alive "$4"; then
    age=$(ps_field "$4" 2)
    age_source=process
  fi
  emit_row service "$1" "$2" "$3" '' "$4" "$age" "$age_source" "$5" "$6" "$7"
}

collect_services() {
  local pid src id
  note_source services 1 ''

  pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) pid='' ;; esac
  if [ -n "$pid" ] && ps_alive "$pid"; then
    service_row watcher 'fleet monitoring' "$FM_HOME" "$pid" \
      '' manual 'closing it stops supervision of every running worker'
  fi

  pid=$(cat "$STATE/.supervise-daemon.lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) pid='' ;; esac
  if [ -n "$pid" ] && ps_alive "$pid"; then
    service_row away-supervisor 'away-mode supervision' "$FM_HOME" "$pid" \
      '' manual 'ends when away mode ends; do not close it by hand'
  fi

  # Registered process-event listeners this home owns. Lavish sources are
  # already reported as review rows, so they are not repeated here.
  for src in "$STATE"/procevent/*.runner; do
    [ -e "$src" ] || continue
    id=${src##*/}; id=${id%.runner}
    case "$id" in lavish-*) continue ;; esac
    pid=$(cat "$src" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    ps_alive "$pid" || continue
    service_row "listener-$id" "waiting on $id" "$FM_HOME" "$pid" \
      "$(close_prefix)bin/fm-procevent.sh retire $(shell_quote "$id")" safe \
      'retiring it stops the wait; it never touches worker code'
  done

  pid=$(LC_ALL=C awk -F'\t' '
    index($4, "lavish-axi") && index($4, " server") { print $1; exit }' "$PSTABLE")
  if [ -n "$pid" ]; then
    service_row lavish-server 'review page server' 'shared on this machine' "$pid" \
      '' manual 'stops by itself once the last review page is closed'
  fi

  pid=$(LC_ALL=C awk -F'\t' '
    index($4, "no-mistakes") && index($4, "daemon run") { print $1; exit }' "$PSTABLE")
  if [ -n "$pid" ]; then
    service_row no-mistakes-daemon 'validation service' 'shared on this machine' "$pid" \
      '' manual 'one shared instance; closing it kills every running validation'
  fi
}

# --- 4. concurrent harness background sessions -------------------------------
# Scope. Only harness processes descended from the harness that owns this home's
# recorded session lock are considered, so this can never claim a neighbouring
# firstmate installation's work. Among those, a process is a SESSION FOR THIS
# HOME when its working directory is this home; everything else under the same
# harness is pool machinery or another home's session, and is counted without
# being claimed or detailed.

is_harness_pid() {  # <pid>
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  [ -n "$comm" ] || return 1
  args=$(ps_field "$pid" 3)
  fm_harness_process_matches "$comm" "$args"
}

# The outermost contiguous harness ancestor of <pid>, which is the shared daemon
# when one parents this session and the session itself when none does.
harness_root_of() {  # <pid>
  local pid=$1 parent hop=0
  local outermost=$pid
  while [ "$hop" -lt 16 ]; do
    parent=$(ps_field "$pid" 1)
    case "$parent" in ''|0|1) break ;; esac
    is_harness_pid "$parent" || break
    outermost=$parent
    pid=$parent
    hop=$((hop + 1))
  done
  printf '%s\n' "$outermost"
}

# Every harness process descended from <pid>, breadth-first and depth-bounded.
# Two levels is what a pty host plus its session needs today; the bound is
# generous so a deeper vendor arrangement is still enumerated rather than
# silently cut off.
harness_descendants_of() {  # <pid>
  local depth=0 child parent
  local -a frontier=("$1") next=()
  while [ "${#frontier[@]}" -gt 0 ] && [ "$depth" -lt 6 ]; do
    next=()
    for parent in "${frontier[@]}"; do
      while IFS= read -r child; do
        [ -n "$child" ] || continue
        is_harness_pid "$child" || continue
        printf '%s\n' "$child"
        next+=("$child")
      done < <(ps_children "$parent")
    done
    frontier=("${next[@]+"${next[@]}"}")
    depth=$((depth + 1))
  done
}

HARNESS_ROOT=
HARNESS_LOCK_PID=
HARNESS_LOCK_OWNER=not_checked
HARNESS_OTHER=0
HARNESS_OWN_WORKERS=0

# WHOSE SESSION IS THIS? Handing the captain a `kill` for the conversation he is
# having is worse than telling him nothing, so no row may carry one until that
# question has an answer. Exactly ONE signal can answer it: ANCESTRY.
# bin/fm-session-lock-lib.sh already owns "which harness pids am I running
# inside", so that answer is reused rather than re-derived - every pid in this
# process's own contiguous harness ancestry is self. It is conclusive in both
# directions: if none of this home's sessions is in that ancestry, the captain is
# demonstrably talking to something else, and every row here is genuinely
# closeable. The session-start path always has it, because the bootstrap runs
# inside the session itself.
#
# A PANE HAS NO ANCESTRY TO WALK, AND NOTHING ELSE MAY SUBSTITUTE FOR IT. The
# pane the captain leaves open is a child of the terminal, not of any harness.
# The lock cannot stand in: it records the OUTERMOST pid of the contiguous run,
# which under a shared harness daemon is the daemon and never one of the sessions
# listed here. Nor may the lock writer record which session it was, because every
# session in the home rewrites that record - so the reader would learn who took
# the lock LAST and would then affirmatively offer a kill for a live session that
# may well be the one the captain is talking to. That is worse than not knowing.
#
# So when the ancestry is silent, ownership is simply unknown: those rows say so
# and carry no close command. The pid is still printed, so ending one
# deliberately stays possible; the overview just stops proposing it.
SELF_HARNESS_PIDS=
SELF_RESOLUTION=not_applicable
resolve_session_ownership() {
  local pid pids
  SELF_HARNESS_PIDS=' '
  if pids=$(fm_harness_ancestry_pids 2>/dev/null); then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      SELF_HARNESS_PIDS="$SELF_HARNESS_PIDS$pid "
    done <<EOF
$pids
EOF
    SELF_RESOLUTION=ancestry
    return 0
  fi
  SELF_RESOLUTION=unresolved
}
is_self_harness_pid() {  # <pid>
  case "$SELF_HARNESS_PIDS" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

session_detail() {  # <self:1|0|?>
  local drives=yes
  case "$HARNESS_LOCK_OWNER" in
    ambiguous) drives=ambiguous ;;
    not_checked) drives=unknown ;;
  esac
  case "$1" in
    1) printf 'drives this home: %s; this is your own session' "$drives" ;;
    '?') printf 'drives this home: %s; whose session this is could not be established here' "$drives" ;;
    *) printf 'drives this home: %s' "$drives" ;;
  esac
}

collect_harness_sessions() {
  local lock_pid root pid cwd age close safety cnote self
  local -a candidates=() mine=()
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) lock_pid='' ;; esac
  HARNESS_LOCK_PID=$lock_pid
  if [ ! -s "$PSTABLE" ]; then
    HARNESS_LOCK_OWNER=not_checked
    note_source harness-sessions 0 'no readable process table'
    return 0
  fi
  if [ -z "$lock_pid" ]; then
    HARNESS_LOCK_OWNER=absent
    note_source harness-sessions 1 'this home records no session lock, so no harness is scoped to it'
    return 0
  fi
  # A DETERMINED ANSWER, NOT AN UNREADABLE ONE. This collector read everything it
  # needed and reached a verdict: the lock names a process that is not a live
  # harness. lock_owner carries that verdict and the view states it in words, so
  # booking it as a failed source would report the same fact twice and, worse,
  # spend the unasked session-start line on a check that did in fact complete.
  # The `absent` branch above is the same shape for the same reason.
  if ! ps_alive "$lock_pid" || ! is_harness_pid "$lock_pid"; then
    HARNESS_LOCK_OWNER=stale
    note_source harness-sessions 1 "recorded session lock pid $lock_pid is not a live harness process"
    return 0
  fi
  root=$(harness_root_of "$lock_pid")
  HARNESS_ROOT=$root

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    candidates+=("$pid")
  done < <(harness_descendants_of "$root")
  # A harness with no descendants is itself the only thing that can be running.
  [ "${#candidates[@]}" -gt 0 ] || candidates=("$root")

  if ! read_cwds "${candidates[@]}"; then
    HARNESS_LOCK_OWNER=not_checked
    note_source harness-sessions 0 \
      "$CWD_READ_NOTE, so a live session cannot be told from an idle pool process"
    return 0
  fi
  note_source harness-sessions 1 ''

  for pid in "${candidates[@]}"; do
    cwd=$(cwd_of "$pid")
    if within_a_worker_worktree "$cwd"; then
      HARNESS_OWN_WORKERS=$((HARNESS_OWN_WORKERS + 1))
    elif path_within "$cwd" "$FM_HOME"; then
      mine+=("$pid")
    else
      HARNESS_OTHER=$((HARNESS_OTHER + 1))
    fi
  done

  # NO WORKER LIST, NO VERDICT. Without the snapshot there is no way to tell a
  # background session from a worker's own process: both are harness processes of
  # this harness working inside this home. Calling one a session would offer a
  # bare `kill` for work whose real close command refuses rather than discarding
  # anything unlanded, and counting two of them would raise the concurrent-session
  # alarm for a home that simply has two workers running. So the rows are still
  # listed - they are running, and seeing that is the point - but the verdict and
  # every close command are withheld, and the unreadable source says why.
  # Nothing to tell apart is not the same as being unable to tell things apart:
  # with no session in this home at all, `none` is the honest verdict whether or
  # not the worker list could be read, and the alarm below it would fire over an
  # empty set.
  if [ "$FLEET_SNAPSHOT_OK" != 1 ] && [ "${#mine[@]}" -gt 0 ]; then
    HARNESS_LOCK_OWNER=not_checked
  else
    case "${#mine[@]}" in
      0) HARNESS_LOCK_OWNER=none ;;
      1) HARNESS_LOCK_OWNER=single ;;
      *) HARNESS_LOCK_OWNER=ambiguous ;;
    esac
  fi
  # Ownership is a separate question with its own answer, and the ancestry
  # answers it perfectly well here. Withholding the close commands is what the
  # missing worker list forces; saying the captain's own session cannot be
  # identified when it demonstrably can would name the wrong cause and spend a
  # second line saying it.
  [ "${#mine[@]}" -eq 0 ] || resolve_session_ownership

  for pid in ${mine[@]+"${mine[@]}"}; do
    age=$(ps_field "$pid" 2)
    if [ "$FLEET_SNAPSHOT_OK" != 1 ]; then
      if is_self_harness_pid "$pid"; then self=1; elif [ "$SELF_RESOLUTION" = unresolved ]; then self='?'; else self=0; fi
      close=''
      safety=manual
      cnote='this home'"'"'s workers could not be read, so this may be a worker rather than a session; nothing is offered for closing until that is known'
    elif [ "$SELF_RESOLUTION" = unresolved ]; then
      self='?'
      close=''
      safety=manual
      cnote='which of this home'"'"'s sessions is your own could not be established from here, so none is offered for closing; the pid above is what you would end yourself'
    elif is_self_harness_pid "$pid"; then
      self=1
      close=''
      safety=manual
      cnote='this is the session you are talking to right now; end it yourself when you are done with it'
    else
      self=0
      close="kill $pid"
      safety=confirm
      cnote='a live session: closing it can lose an unfinished turn'
    fi
    emit_row harness-session "$pid" session "harness $root" "$(session_detail "$self")" \
      "$pid" "$age" process "$close" "$safety" "$cnote" 0 '' "$self"
  done
}

collect_workers
collect_reviews
collect_services
collect_harness_sessions

JSON=$(
  jq -R -s \
    --arg schema fm-session-inventory.v1 \
    --arg home "$FM_HOME" \
    --arg root "$FM_ROOT" \
    --argjson now "$NOW_EPOCH" \
    --argjson stale_days "$STALE_DAYS" \
    --arg harness_root "$HARNESS_ROOT" \
    --arg lock_pid "$HARNESS_LOCK_PID" \
    --arg lock_owner "$HARNESS_LOCK_OWNER" \
    --arg self_resolution "$SELF_RESOLUTION" \
    --argjson other "$HARNESS_OTHER" \
    --argjson own_workers "$HARNESS_OWN_WORKERS" \
    --rawfile sources_raw "$SOURCES" \
    '
    def blank_null: if . == "" then null else . end;
    def as_num: blank_null | if . == null then null else tonumber end;
    def rows_of:
      split("\n") | map(select(length > 0)) | map(split("\t")) | map(
        {kind: .[0],
         id: .[1],
         label: (.[2] | blank_null),
         belongs_to: (.[3] | blank_null),
         detail: (.[4] | blank_null),
         pid: (.[5] | as_num),
         age_seconds: (.[6] | as_num),
         age_source: (.[7] | blank_null),
         close: (.[8] | blank_null),
         close_safety: (.[9] // "manual"),
         close_note: (.[10] | blank_null),
         held: (.[11] == "1"),
         task_age_seconds: (.[12] | as_num),
         self: (.[13] == "1"),
         self_known: (.[13] != "?")}
        | .task_age_days = (if .task_age_seconds == null then null
                            else (.task_age_seconds / 86400 | floor) end)
        | .age_days = (if .age_seconds == null then null else (.age_seconds / 86400 | floor) end)
        | .stale = (.age_days != null and .age_days >= $stale_days)
        | .notify = (.stale and .close != null and (.held | not))
        | .started = (if .age_seconds == null then null
                      else (($now - .age_seconds) | strftime("%Y-%m-%dT%H:%M:%SZ")) end)
      );
    def kind_order: {"worker": 0, "harness-session": 1, "review": 2, "service": 3};
    (rows_of) as $rows
    | ($sources_raw | split("\n") | map(select(length > 0)) | map(split("\t"))
       | map({name: .[0], ok: (.[1] == "1"), reason: (.[2] | blank_null)})) as $sources
    | ($rows | sort_by([(kind_order[.kind] // 9), -(.age_seconds // -1), .id])) as $ordered
    | {schema: $schema,
       generated: ($now | strftime("%Y-%m-%dT%H:%M:%SZ")),
       generated_epoch: $now,
       fm_home: $home,
       fm_root: $root,
       stale_after_days: $stale_days,
       rows: $ordered,
       counts: {
         total: ($ordered | length),
         stale: ([$ordered[] | select(.stale)] | length),
         notify: ([$ordered[] | select(.notify)] | length),
         by_kind: {
           worker: ([$ordered[] | select(.kind == "worker")] | length),
           review: ([$ordered[] | select(.kind == "review")] | length),
           service: ([$ordered[] | select(.kind == "service")] | length),
           harness_session: ([$ordered[] | select(.kind == "harness-session")] | length)
         }
       },
       harness_sessions: {
         root_pid: ($harness_root | as_num),
         lock_pid: ($lock_pid | as_num),
         lock_owner: $lock_owner,
         self_resolution: $self_resolution,
         sessions: ([$ordered[] | select(.kind == "harness-session")] | length),
         own_workers: $own_workers,
         elsewhere: $other
       },
       sources: $sources}
    ' < "$ROWS"
) || { echo "fm-session-inventory: could not assemble the inventory" >&2; exit 1; }

if [ "$MODE" = json ]; then
  printf '%s\n' "$JSON"
  exit 0
fi

# --stale-lines: nothing at all when nothing is old. One short line each,
# bounded, because a session start pays for every line it prints.
#
# REVIEW PAGES ARE SAID ONCE PER MACHINE, NOT ONCE PER HOME. The Lavish listing
# is machine-wide by intent - the captain works across more than twenty projects
# and asked to see all of those pages - but an unasked line is a different
# budget: every firstmate home on the machine would otherwise print the same
# review lines at every session start. The main home says them; a secondmate
# home leaves them to it. The pages themselves stay in --json for every home,
# and in the view, unchanged.
#
# Which home is which is bin/fm-primary-scope-lib.sh's decision, not a second
# reading of the marker file here. A local `-e` test would call a symlinked
# marker a secondmate home where that owner does not, and would call a dangling
# one a main home where bin/fm-bootstrap.sh does not - and disagreeing about
# that is precisely how every home ends up repeating these lines again.
REVIEW_LINES=1
fm_root_is_secondmate_home "$FM_HOME" && REVIEW_LINES=0
#
# SILENCE MUST MEAN "NOTHING IS OLD", NEVER "I COULD NOT LOOK". This is the one
# surface the captain does not ask for, so an empty pass reads to him as good
# news - and a collector that failed produces exactly the same emptiness as a
# home with nothing overdue. sources[] already records every input that could
# not be read; this renders that record, as ONE short line naming the sources,
# ahead of whatever rows did survive. That is the single route: any collector
# that cannot read its input notes itself there and is disclosed here, rather
# than each one growing its own handling. The rows it could still gather are
# printed either way - one unreadable source must not drag the rest down with
# it - and a pass where everything was readable and nothing is old stays exactly
# as silent as before.
printf '%s\n' "$JSON" | jq -r --argjson cap 8 --argjson reviews "$REVIEW_LINES" '
  def row_label($r):
    if $r.kind == "harness-session" then "background session \($r.id)"
    elif $r.kind == "worker" then "worker \($r.id)"
    elif $r.kind == "review" then "review page \($r.label)"
    else "service \($r.label // $r.id)" end;
  # Oldest first across every kind, so the cap below can only ever drop the
  # least overdue lines.
  # The same main-home-only rule the review rows follow, and for the same reason:
  # Lavish is the one MACHINE-WIDE collector here, so its failure is a single
  # condition that every firstmate home on this machine would otherwise repeat on
  # every session start. The home-local collectors are about THIS home and keep
  # reporting from every home.
  ([.sources[] | select(.ok | not)
    | select($reviews == 1 or .name != "lavish") | .name] | join(", ")) as $unreadable
  | [.rows[] | select(.notify) | select($reviews == 1 or .kind != "review")]
  | sort_by(-(.age_seconds // 0)) as $stale
  | (if $unreadable == "" then empty
     else "SESSIONS_STALE: could not check everything - \($unreadable) unreadable; run bin/fm-session-view.sh"
     end),
    if ($stale | length) == 0 then empty
    else
      ($stale[:$cap][] |
        "SESSIONS_STALE: \(row_label(.)) - \(.age_days)d, \(.belongs_to // "-") - close: \(.close)" +
        (if .close_safety == "safe" then "" else " (\(.close_safety): \(.close_note // "check before closing"))" end)),
      (if ($stale | length) > $cap then
         "SESSIONS_STALE: and \(($stale | length) - $cap) more - see bin/fm-session-view.sh"
       else empty end)
    end'
