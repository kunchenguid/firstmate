#!/usr/bin/env bash
# fm-restored-recover.sh - put this home's restored workers back where their
# work is, after a machine restart.
#
# Usage: fm-restored-recover.sh [--dry-run]
#        fm-restored-recover.sh --background
#
# WHY. Herdr persists its session layout and, on restart, resumes each pane's
# recorded agent session (`claude --resume <id>`) in the pane's saved cwd. That
# cwd is the pane's TOP shell's directory, and a ship or scout pane's top shell
# sits in the project's primary checkout: `treehouse get` enters the task
# worktree in a nested shell, and no cd typed into that nested shell, nor an OSC 7
# report, reaches the saved layout (docs/verification/runtime-backends.md
# "Herdr restart resumes agents in the top shell's directory"). So after a
# reboot a worker comes back alive but in the primary checkout, where Claude
# Code often parks it on a startup gate such as the external CLAUDE.md imports
# consent. Nothing about that state is visible as `dead` or `missing`, so the
# ordinary dead-endpoint recovery never fires.
#
# WHAT. For every local direct report recorded in this home (ship, scout, or
# secondmate) on a backend with a recovery-grade agent-state classifier (tmux,
# herdr), whose agent reads `alive`, this sweep relaunches it through
# `bin/fm-control.sh <id> relaunch` when either holds:
#   - its viewport shows a harness startup gate (fm_composer_startup_dialog), or
#   - its foreground process runs outside its recorded worktree, read twice a
#     moment apart so a transient read cannot trigger it.
# A drifted endpoint is relaunched only on Herdr, whose relaunch moves the pane
# back into the worktree; elsewhere it is reported rather than stopped.
# The relaunch owns everything else: the checkpoint that proves the worktree and
# its unlanded work are intact, stopping the old agent without answering any
# gate, entering the recorded worktree, and launching the replacement there
# with a progress note appended to the worker's instructions. A secondmate's
# charter is never rewritten, so its note stays parent-side evidence.
# Relaunches run concurrently, and each worker's line is published the moment
# that worker is settled, never held back until the slowest one finishes.
#
# Every other state is left alone: `dead` and `missing` endpoints keep their own
# recovery paths (the secondmate liveness sweep and stuck-crewmate recovery),
# and an unreadable path, an unreadable viewport, or any non-`alive` verdict
# never triggers a relaunch. Remote secondmates are skipped by name.
#
# OUTPUT, one line per affected task, nothing for a healthy fleet:
#   BOOTSTRAP_INFO: worker <id> was <cause>; relaunched in its recorded worktree <path>
#   RESTORED_WORKER: <id>: was <cause>; relaunch failed: <first error line>
#   RESTORED_WORKER: <id>: was <cause>; not relaunched: a <backend> relaunch cannot move its endpoint back into <path>
#   RESTORED_WORKER: <id>: was <cause>; not relaunched (dry run)
#   RESTORED_WORKER: sweep: <why the sweep itself did not run or finish>
# Exit status is 0 unless the home itself cannot be read or a background job
# cannot be started. Only one sweep runs per home at a time (a lock under
# state/); a second one reports that and does nothing.
#
# MODES. Bare (or --dry-run, which flags but never relaunches) runs the sweep
# in the foreground and prints each line as it is settled; an operator may run
# it by hand from the lock-owning session, since each relaunch also takes
# fm-control's per-task lock and a healthy worker is a no-op.
# --background is how bin/fm-bootstrap.sh runs it from its deferred locked
# network phase: it starts the sweep as its own detached job and returns at
# once, printing nothing. A relaunch can legitimately outlast the deferred
# stage's aggregate deadline, and a deadline that killed it mid-transaction
# would leave the worker with no agent, so the job runs outside that stage's
# process group and deadline, under its own bound FM_RESTORED_RECOVER_TIMEOUT
# (default 300s, sized for fm-control's TERM and KILL waits plus its launch
# wait, all relaunches running concurrently). Each job writes its own results
# file, state/.restored-recover.results.<UTC timestamp>.<job pid>, line by line
# as each worker is settled, appends a `RESTORED_WORKER: sweep:` line if its
# bound expired, and enqueues one `check: restored-workers` wake naming that
# exact file whenever any line there is actionable (anything but
# BOOTSTRAP_INFO); a clean sweep stays silent. A later job never rewrites an
# earlier job's file; only the newest five results files are kept.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --job and --sweep-held are the background job's own internal stages: the
# detached job, and the bounded sweep it runs while it holds the home's lock.
MODE=foreground
DRY_RUN=0
case "${1:-}" in
  '') ;;
  --dry-run) DRY_RUN=1 ;;
  --background) MODE=background ;;
  --job) MODE=job ;;
  --sweep-held) MODE=sweep-held ;;
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "error: unexpected argument '$1'" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "error: unexpected argument '$2'" >&2; exit 2; }

[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || {
  echo "error: FM_HOME must name this firstmate home" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || exit 0

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$SCRIPT_DIR/fm-composer-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

RECHECK_DELAY=${FM_RESTORED_RECOVER_RECHECK:-1}
TIMEOUT=${FM_RESTORED_RECOVER_TIMEOUT:-300}
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=300 ;; esac
SWEEP_LOCK="$STATE/.restored-recover.lock"
RESULTS_PREFIX="$STATE/.restored-recover.results."
RESULTS_KEEP=5

real_dir() {  # <path>
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

# outside_worktree <seen> <worktree-real>: true when <seen> resolves to a
# directory that is neither the worktree nor inside it. An unresolvable path
# is not evidence of anything.
outside_worktree() {  # <seen> <worktree-real>
  local seen
  [ -n "$1" ] || return 1
  seen=$(real_dir "$1") || return 1
  case "$seen/" in
    "$2"/*) return 1 ;;
  esac
  return 0
}

# drifted <backend> <target> <worktree-real>: true when the endpoint runs
# outside the worktree on two reads a moment apart, and prints what it saw.
drifted() {  # <backend> <target> <worktree-real>
  local seen
  seen=$(fm_backend_current_path "$1" "$2" 2>/dev/null) || return 1
  outside_worktree "$seen" "$3" || return 1
  sleep "$RECHECK_DELAY"
  seen=$(fm_backend_current_path "$1" "$2" 2>/dev/null) || return 1
  outside_worktree "$seen" "$3" || return 1
  printf '%s' "$seen"
}

# restored_cause <backend> <target> <worktree-real>: why this alive agent needs
# a relaunch, as "<drifted 0|1><TAB><cause>", or nothing.
restored_cause() {  # <backend> <target> <worktree-real>
  local backend=$1 target=$2 wt_real=$3 screen gate seen
  gate=
  if fm_backend_visible_capture_supported "$backend" \
    && screen=$(fm_backend_visible_capture "$backend" "$target" 2>/dev/null); then
    gate=$(fm_composer_startup_dialog "$screen") || gate=
  fi
  if seen=$(drifted "$backend" "$target" "$wt_real"); then
    if [ -n "$gate" ]; then
      printf '1\tparked on the %s in %s instead of its recorded worktree' "$gate" "$seen"
    else
      printf '1\trunning in %s instead of its recorded worktree' "$seen"
    fi
  elif [ -n "$gate" ]; then
    printf '0\tparked on the %s' "$gate"
  else
    return 1
  fi
}

relaunch_note() {  # <cause> <worktree>
  printf '%s\n' \
    "The machine restarted, and your terminal came back with your previous session resumed but $1." \
    "Firstmate stopped that copy without answering any prompt and relaunched you in your recorded worktree $2." \
    "Every committed and uncommitted change there is exactly as you left it." \
    "Re-read these instructions, run git status and git log to see where the work stands, and continue from there."
}

# recover_one <meta> <id>: print at most one line for this task.
recover_one() {  # <meta> <id>
  local meta=$1 id=$2 kind wt wt_real backend target cause drift out rc first
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in ship|scout|secondmate) ;; *) return 0 ;; esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 0
  wt=$(fm_meta_get "$meta" worktree)
  [ -n "$wt" ] || return 0
  wt_real=$(real_dir "$wt") || return 0
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 || return 0
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  case "$backend" in tmux|herdr) ;; *) return 0 ;; esac
  [ "$(fm_backend_agent_state "$backend" "$target")" = alive ] || return 0
  cause=$(restored_cause "$backend" "$target" "$wt_real") || return 0
  drift=${cause%%$'\t'*}
  cause=${cause#*$'\t'}
  [ -n "$cause" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    echo "RESTORED_WORKER: $id: was $cause; not relaunched (dry run)"
    return 0
  fi
  # Only a Herdr relaunch moves a drifted endpoint back into its worktree
  # (bin/fm-spawn.sh --relaunch); any other backend would stop the agent and
  # then refuse to launch outside the worktree, so it is reported instead.
  if [ "$drift" = 1 ] && [ "$backend" != herdr ]; then
    echo "RESTORED_WORKER: $id: was $cause; not relaunched: a $backend relaunch cannot move its endpoint back into $wt"
    return 0
  fi
  rc=0
  out=$(FM_SPAWN_NO_GUARD=1 "$SCRIPT_DIR/fm-control.sh" "$id" relaunch \
    --note "$(relaunch_note "$cause" "$wt")" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "BOOTSTRAP_INFO: worker $id was $cause; relaunched in its recorded worktree $wt"
  else
    first=$(printf '%s\n' "$out" | grep -m1 '^error: ' || printf '%s\n' "$out" | sed -n '1p')
    echo "RESTORED_WORKER: $id: was $cause; relaunch failed: ${first#error: }"
  fi
}

# sweep: settle every recorded task concurrently. Each recover_one prints at
# most one short line with a single write, so lines from concurrent workers
# never interleave and each appears the moment its worker is settled.
sweep() {
  local meta id
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    recover_one "$meta" "$id" 2>/dev/null &
  done
  wait
}

has_candidates() {
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] && return 0
  done
  return 1
}

case "$MODE" in
  foreground)
    fm_lock_try_acquire "$SWEEP_LOCK" || {
      echo "RESTORED_WORKER: sweep: another restored-worker sweep is already running in this home (pid ${FM_LOCK_HELD_PID:-unknown}); nothing was done"
      exit 0
    }
    trap 'fm_lock_release "$SWEEP_LOCK" 2>/dev/null || true' EXIT
    sweep
    ;;
  sweep-held)
    sweep
    ;;
  background)
    has_candidates || exit 0
    # Its own process group (monitor mode), nohup, and no inherited stdio, for
    # the reasons bin/fm-startup-network.sh's own detach records: the caller
    # runs inside a bounded stage that terminates its whole process group, and
    # a job holding the caller's stdout would hold the digest open.
    set -m 2>/dev/null || true
    nohup "$0" --job >/dev/null 2>&1 </dev/null &
    exit 0
    ;;
  job)
    fm_lock_try_acquire "$SWEEP_LOCK" || exit 0
    trap 'fm_lock_release "$SWEEP_LOCK" 2>/dev/null || true' EXIT
    RESULTS="$RESULTS_PREFIX$(date -u +%Y%m%dT%H%M%SZ).$$"
    : > "$RESULTS" || exit 1
    # shellcheck disable=SC2012
    ls -1t "$RESULTS_PREFIX"* 2>/dev/null | tail -n "+$((RESULTS_KEEP + 1))" \
      | while IFS= read -r old; do rm -f -- "$old"; done
    rc=0
    fm_run_timed "$TIMEOUT" "$0" --sweep-held >> "$RESULTS" 2>/dev/null || rc=$?
    if fm_timed_out "$rc"; then
      echo "RESTORED_WORKER: sweep: stopped by its ${TIMEOUT}s bound (FM_RESTORED_RECOVER_TIMEOUT); a worker with no line above was not confirmed recovered" >> "$RESULTS"
    fi
    if awk 'NF && $0 !~ /^BOOTSTRAP_INFO:/ { found=1; exit } END { exit !found }' "$RESULTS" 2>/dev/null; then
      fm_wake_append check restored-workers \
        "check: restored-workers: restart recovery has results that need attention; read $RESULTS" || true
    fi
    ;;
esac
exit 0
