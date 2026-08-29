#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background). Run it as its own
# standalone background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
# On a harness with a PreToolUse-equivalent hook, bin/fm-arm-pretool-check.sh
# applies the command-position policy before the command runs; see
# docs/arm-pretool-check.md for the blessed tree and deny reason codes. It is a
# pre-execution seatbelt, not a substitute for the verification here.
#
# This script forks the watcher as a tracked child, then VERIFIES the outcome
# before it settles in. It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the
# single source of truth, shared with fm-watch.sh and fm-guard.sh), and prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: attached pid=<N> (beacon <age>s as of <hh:mm:ss>)
#                                                        - arm mode found a live+fresh watcher
#                                                          holding the lock; this arm attaches and
#                                                          waits until that cycle ends
#   watcher: healthy pid=<N> (beacon <age>s)             - restart mode found a live+fresh
#                                                          watcher it did not own
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
#   watcher: FAILED - attached cycle ended ...           - an attach ended (below)
#   watcher: FAILED - attach interrupted ...             - this arm was signalled away (below)
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns a FAILED line. On started it waits the child and propagates the wake
# reason. On restart-only healthy it exits zero after the duplicate child stands
# down. On FAILED it exits non-zero so the failure is loud. A live cycle already
# present means re-arm attaches - do not start a second watcher.
#
# `attached` is a claim about the INSTANT it is printed, and this script's output
# outlives that instant: the caller reads the whole buffer after the task
# completes. So an attach is ALWAYS closed by a terminal line, non-zero, stating
# the truth at exit with a beacon age recomputed then rather than the frozen
# attach-time one:
#   watcher: FAILED - attached cycle ended (<which proof failed>), no live watcher
#     with a fresh beacon (was pid=<N>, beacon <age>s as of <hh:mm:ss>)
#   watcher: FAILED - attach interrupted ...   (this arm signalled away; says
#     whether the holder is still live, because "the watcher is up but nothing is
#     delivering its wakes" and "nothing is up" need different repairs)
# Without that closure the arm exited zero and SILENT, leaving `attached pid=<N>`
# as the caller's final word for a watcher that no longer existed and an age
# understated by however long the attach ran - a fleet nobody was watching, read
# as healthy. That fired constantly rather than rarely, because fm-watch.sh exits
# normally as soon as it surfaces a wake: in a busy home an attach lasts only
# until the next wake, so nearly every plain arm ended this way. No watcher crash
# is involved, and --restart was unaffected because it never attaches.
# The end of an attach is never "supervision is live": the holder is gone and any
# wake it surfaced is already durable in state/.wake-queue, so the honest report
# is the loud FAILED vocabulary the caller already repairs on (drain queued wakes,
# then re-arm) - and draining is what delivers that wake. Reporting FAILED here
# can at worst cost one redundant watcher if a successor appeared in the same
# instant; staying silent costs the whole fleet, so the ambiguity resolves toward
# supervision.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and own a fresh cycle, or report restart-only healthy if a
# live peer still holds the lock after the duplicate child stands down. It
# resolves and signals exactly that pid, so it can never touch another home's
# watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings. Restart never
# takes the attach path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}

clear_stale_recorded_watcher_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$WATCH" ] || return 0
  [ -n "$lock_identity" ] || return 0
  fm_lock_remove_path "$WATCH_LOCK" || true
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
healthy_watcher() {
  HEALTHY_PID=
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" || return 1
  HEALTHY_PID=$FM_WATCHER_HEALTHY_PID
}

# A beacon age is only true at the instant it is measured, and the `attached`
# line is the one reading that routinely gets read much later - it is printed
# once and then stands unchanged for the whole attach. Stamping the reading with
# the clock time it was taken is what makes it unmistakable: `beacon 11s as of
# 14:32:07` read at 14:32:36 states its own staleness, where a bare `beacon 11s`
# silently understated a true 40s by exactly the 29s since it was printed. The
# computation itself is exact at call time (verified against stat across the
# grace boundary), so the honest fix is to date the reading, not to change the
# arithmetic. Re-printing the line on a timer instead would only produce a stream
# of readings that each go stale the same way.
report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: attached pid=$HEALTHY_PID (beacon ${age}s as of $(date +%H:%M:%S))"
}

report_healthy() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: healthy pid=$HEALTHY_PID (beacon ${age}s)"
}

# Terminal line for an attach that has ended: the holder failed the same honesty
# gate that let it be reported in the first place (pid gone, identity mismatch, or
# a beacon that went stale), so no live cycle exists at exit. The age is measured
# HERE, not carried over from the attach-time line, which is exactly the reading
# that was understated by the attach duration.
report_attach_ended() {
  local ended_pid=$1 age cause
  age=$(fm_path_age "$BEAT")
  # Name which proof failed. Diagnosing this by hand (ps the pid, stat the
  # beacon) is exactly the work the silent exit used to push onto the operator.
  if ! fm_pid_alive "$ended_pid"; then
    cause="holder exited"
  elif ! fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$ended_pid" "$FM_HOME"; then
    cause="lock no longer names that watcher"
  else
    cause="beacon went stale"
  fi
  echo "watcher: FAILED - attached cycle ended ($cause), no live watcher with a fresh beacon (was pid=$ended_pid, beacon ${age}s as of $(date +%H:%M:%S))"
}

# Same closure for the other way an attach stops: this arm is signalled (harness
# restart, session teardown) while the holder may still be fine. Wake delivery
# still stops, so the post-condition the caller reads for is false either way -
# but say which, because "the watcher is still up, the notify path is not" and
# "nothing is up" need different repairs.
# shellcheck disable=SC2329 # Invoked from attach_and_wait's HUP/TERM/INT traps.
report_attach_interrupted() {
  local ended_pid=$1 age
  age=$(fm_path_age "$BEAT")
  if healthy_watcher; then
    echo "watcher: FAILED - attach interrupted; watcher pid=$HEALTHY_PID is still live (beacon ${age}s) but this arm stopped waiting on it, so no wake reaches the harness until re-armed"
  else
    echo "watcher: FAILED - attach interrupted, no live watcher with a fresh beacon (was pid=$ended_pid, beacon ${age}s)"
  fi
}

# Stay alive until the attached identity-matched healthy holder is gone.
# If a different healthy watcher appears mid-attach (rare steal), re-attach.
# Does not reprint the starter arm's wake reason line: any wake the holder
# surfaced is already durable in state/.wake-queue, and the caller's repair for
# the terminal line below is to drain that queue and then re-arm.
attach_and_wait() {
  local attached_pid=$1
  # Being signalled is the other way this arm stops waiting, and it must not be
  # silent either: the harness restarting or tearing down the task would
  # otherwise leave the buffered `attached` line as the final word. No child to
  # clean up here - the confirm path cleared its traps and reaped its child
  # before calling in, and the pre-fork path never forked one.
  trap 'report_attach_interrupted "$attached_pid"; exit 129' HUP
  trap 'report_attach_interrupted "$attached_pid"; exit 143' TERM INT
  while :; do
    if healthy_watcher; then
      if [ "$HEALTHY_PID" != "$attached_pid" ]; then
        attached_pid=$HEALTHY_PID
        report_attached
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    # Attached cycle ended (pid gone, identity mismatch, or beacon no longer
    # fresh). Never exit silently here: the buffered `attached` line would stand
    # as the caller's final word and read as live supervision.
    report_attach_ended "$attached_pid"
    exit 1
  done
}

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 2 ;;
esac

if [ "$mode" = restart ]; then
  # Home-scoped stop: only the watcher pid recorded in THIS home's lock.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$lock_pid" "$FM_HOME"; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      # Wait for it to actually exit before relaunching, so the fresh watcher
      # either takes a released lock or reclaims a now-dead-pid stale lock instead
      # of seeing the dying one as a live holder and no-opping.
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
    else
      clear_stale_recorded_watcher_lock
    fi
  fi
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - attach to that cycle and wait until it ends so the harness notify fires
# then, not as an immediate empty wake. (--restart skips this: it just stopped
# this home's watcher and wants a fresh one.)
if [ "$mode" = arm ] && healthy_watcher; then
  report_attached
  attach_and_wait "$HEALTHY_PID"
fi

# Start a watcher as a tracked child and confirm it before settling in. The child
# stays our child for its whole life: we wait on it, so killing this arm (the
# harness-tracked task) tears the watcher down too, and the watcher's eventual
# wake exit propagates out so the harness re-notifies firstmate.
child=
child_out=
cleanup_child() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
}
trap 'cleanup_child; exit 129' HUP
trap 'cleanup_child; exit 143' TERM INT

child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
"$WATCH" >"$child_out" &
child=$!
child_done=0

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      echo "watcher: started pid=$child (beacon fresh)"
      wait "$child"
      rc=$?
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      exit "$rc"
    fi
    # Another watcher won the singleton; our child stood down.
    if [ "$mode" = arm ]; then
      report_attached
      wait "$child" 2>/dev/null || true
      rm -f "$child_out" 2>/dev/null || true
      child=
      child_out=
      trap - HUP TERM INT
      attach_and_wait "$HEALTHY_PID"
    fi
    report_healthy
    wait "$child" 2>/dev/null || true
    rm -f "$child_out" 2>/dev/null || true
    exit 0
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    wait "$child"
    rc=$?
    child_done=1
    if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      exit 0
    fi
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
echo "watcher: FAILED - no live watcher with a fresh beacon"
cleanup_child
wait "$child" 2>/dev/null || true
exit 1
