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
# This script launches the watcher DETACHED (bin/fm-detach-lib.sh: its own
# session and process group), then FOLLOWS it. That split is what makes
# supervision survive a reaped background task: the harness's reap SIGTERMs the
# task's whole process group, which used to kill the watcher along with this arm.
# Now a reap kills only the follower - the watcher keeps the singleton lock, the
# liveness beacon, and the durable wake queue - and the reap still arrives as a
# task-completion notification, so firstmate wakes, drains nothing new, and
# re-arms straight onto the live watcher via the `attached` path below.
# The wake path is unchanged: the watcher enqueues an actionable wake and exits,
# this follower observes that exit, prints the reason, and completes - and the
# background task's completion is still what wakes the primary.
# Because the watcher outlives this process, its stdout goes to a stable per-home
# file (state/.watch.out, truncated by whichever arm launches it) rather than an
# arm-scoped temp file.
#
# It then VERIFIES the outcome before it settles in. It confirms a watcher
# process is genuinely alive AND the liveness beacon (state/.last-watcher-beat)
# is fresh within FM_GUARD_GRACE (the single source of truth, shared with
# fm-watch.sh and fm-guard.sh), and prints exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: attached pid=<N> (beacon <age>s)            - arm mode found a live+fresh watcher
#                                                          holding the lock; this arm attaches and
#                                                          waits until that cycle ends
#   watcher: healthy pid=<N> (beacon <age>s)             - restart mode found a live+fresh
#                                                          watcher it did not own
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh watcher steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started it follows the detached watcher and
# propagates the wake reason; on attached it stays live until the identity-matched
# holder is no longer healthy, then exits zero so the harness background-notify
# fires then (not as a false empty wake), propagating the watcher's idle-exit line
# if that is how the cycle ended. On restart-only healthy it exits zero
# after the duplicate watcher stands down. On FAILED it exits non-zero so the
# failure is loud, and it kills the watcher it launched but could not confirm, so
# an unconfirmable one is never left detached. A live cycle already present means
# re-arm attaches - do not start a second watcher.
# On HUP/TERM/INT this arm STANDS DOWN WITHOUT killing the watcher: surviving the
# death of its launcher is the whole point, so a signalled follower must never
# take supervision with it.
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
# shellcheck source=bin/fm-detach-lib.sh
. "$SCRIPT_DIR/fm-detach-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# The detached watcher outlives this arm, so its output needs a stable home.
WATCH_OUT="$STATE/.watch.out"
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

report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: attached pid=$HEALTHY_PID (beacon ${age}s)"
}

report_healthy() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: healthy pid=$HEALTHY_PID (beacon ${age}s)"
}

# Stay alive until the attached identity-matched healthy holder is gone.
# If a different healthy watcher appears mid-attach (rare steal), re-attach.
# Does not reprint the starter arm's wake reason line: a wake carries itself in
# the durable queue, so exit 0 lets the harness notify and firstmate drains
# state/.wake-queue on background completion. An IDLE-EXIT is the exception - it
# queues nothing, so an empty completion here would read as a plain harness reap
# (docs/supervision-protocols/claude.md step 9) and firstmate would re-arm a fresh
# watcher onto the same empty fleet for another full idle window. Surface the
# resting line the watcher actually wrote so step 10 fires on THIS completion.
attach_and_wait() {
  local attached_pid=$1
  while :; do
    if healthy_watcher; then
      if [ "$HEALTHY_PID" != "$attached_pid" ]; then
        attached_pid=$HEALTHY_PID
        report_attached
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    # Attached cycle ended (pid gone, identity mismatch, or beacon no longer fresh).
    if watch_output_has_idle_exit "$WATCH_OUT"; then
      print_watch_output "$WATCH_OUT"
    fi
    exit 0
  done
}

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

watch_output_has_idle_exit() {
  local out=$1
  grep -q '^watcher: idle-exit' "$out" 2>/dev/null
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

# Launch a DETACHED watcher and confirm it before settling in. It is deliberately
# NOT our child: it lives in its own session and process group, so a SIGTERM to
# this arm's process group (a harness reaping its background task) cannot reach
# it. We therefore poll its pid rather than `wait` on it, and we never kill it on
# a signal - only on the FAILED path, where we launched a watcher that could not
# be confirmed and must not be left behind.
# WATCHER_START pins that watcher's identity (fm_pid_start) the moment it is
# spawned, because being detached also means nothing holds its pid once it exits:
# an unconfirmable watcher may well have died already, and the retraction below
# must never signal whatever unrelated process inherited its number.
watcher_pid=
watcher_start=
kill_unconfirmed_watcher() {
  [ -n "$watcher_pid" ] || return 0
  # Never kill a watcher that legitimately holds the singleton: that one IS the
  # supervision cycle, whoever launched it.
  if healthy_watcher && [ "$HEALTHY_PID" = "$watcher_pid" ]; then
    return 0
  fi
  # Fails closed on a recycled or unreadable pid: no confirmed identity, no signal.
  fm_detach_kill "$watcher_pid" "$watcher_start" || true
}
# Stand down without touching the watcher: it must survive its launcher.
trap 'exit 129' HUP
trap 'exit 143' TERM INT

# Truncate the shared output BEFORE launching: a detached child that dies before
# it can open the file (a failed exec, say) must never leave the previous cycle's
# reason line behind, or this arm would re-read it and report a phantom wake.
: > "$WATCH_OUT"
watcher_pid=$(fm_detach_spawn "$WATCH_OUT" "$WATCH") || watcher_pid=
case "$watcher_pid" in
  ''|*[!0-9]*)
    echo "watcher: FAILED - no live watcher with a fresh beacon"
    exit 1
    ;;
esac
watcher_start=$(fm_pid_start "$watcher_pid" 2>/dev/null || true)
watcher_exited=0

# Verify the outcome: poll until the watcher we launched is the confirmed healthy
# one, or until some other watcher legitimately holds the singleton (a startup
# race), or until ours gives up. Only then print the honest line.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$watcher_pid" ]; then
      echo "watcher: started pid=$watcher_pid (beacon fresh)"
      # Follow the detached watcher: stay live for exactly as long as that cycle
      # lasts, so this background task completes when - and only when - the cycle
      # ends. Being reaped here is harmless now: the watcher keeps running.
      fm_detach_follow "$watcher_pid" "$ATTACH_POLL"
      print_watch_output "$WATCH_OUT"
      exit 0
    fi
    # Another watcher won the singleton; the one we launched stood down.
    if [ "$mode" = arm ]; then
      report_attached
      trap - HUP TERM INT
      attach_and_wait "$HEALTHY_PID"
    fi
    report_healthy
    exit 0
  fi
  if [ "$watcher_exited" -eq 0 ] && ! fm_pid_alive "$watcher_pid"; then
    watcher_exited=1
    # The watcher can wake and exit before it ever looks healthy here (an
    # immediate check wake). Its reason line is the proof; propagate it.
    if watch_output_has_wake "$WATCH_OUT"; then
      print_watch_output "$WATCH_OUT"
      exit 0
    fi
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
echo "watcher: FAILED - no live watcher with a fresh beacon"
kill_unconfirmed_watcher
exit 1
