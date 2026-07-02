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
#
# This script forks the watcher as a tracked child, then VERIFIES the outcome
# before it settles in. It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the
# single source of truth, shared with fm-watch.sh and fm-guard.sh), and prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: healthy pid=<N> (beacon <age>s)             - a genuinely live+fresh watcher already held the lock
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
# It NEVER reports started/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started/healthy it exits zero; on FAILED it exits
# non-zero so the failure is loud and a caller can react. A healthy line means a
# live cycle already exists; do not churn extra no-op arms until that cycle fires.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and start a fresh one. It resolves and signals exactly that
# pid, so it can never touch another home's watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Overnight blackout predicate (fm_in_blackout, FM_BLACKOUT_EXIT_CODE): during the
# quiet-hours window this arm does NOT start an active watcher; it schedules a
# zero-token sleeper that starts the real watcher when the window ends.
# shellcheck source=bin/fm-blackout-lib.sh
. "$SCRIPT_DIR/fm-blackout-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
# Blackout sleeper wakes to refresh its beacon every chunk; keep it well under
# GRACE so the beacon never goes stale mid-blackout.
BLACKOUT_CHUNK=${FM_BLACKOUT_SLEEP_CHUNK:-60}

watch_lock_matches_pid() {
  local pid=$1 lock_home lock_path lock_identity current_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 1
  [ "$lock_path" = "$WATCH" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ]
}

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
  local pid age
  HEALTHY_PID=
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  watch_lock_matches_pid "$pid" || return 1
  age=$(fm_path_age "$BEAT")
  [ "$age" -lt "$GRACE" ] || return 1
  HEALTHY_PID=$pid
  return 0
}

report_healthy() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: healthy pid=$HEALTHY_PID (beacon ${age}s)"
}

# --- overnight blackout sleeper ---------------------------------------------
# During the quiet-hours window firstmate must burn zero autonomous tokens, so
# this arm does not fork a watcher. Instead THIS arm process becomes a zero-token
# sleeper: it holds the watcher's singleton lock (so a second arm no-ops and
# fm-guard sees supervision as live), refreshes the liveness beacon, and blocks in
# bash - no polling, no wakes - until the window ends, then returns so the caller
# starts the real watcher. Because the sleeper IS this (harness-tracked) arm
# process, the background task simply stays alive through the night and never
# completes, so firstmate is never woken until the watcher resumes and fires.
SLEEPER_HOLDS_LOCK=0

release_sleeper_lock() {
  if [ "$SLEEPER_HOLDS_LOCK" = 1 ]; then
    fm_lock_release "$WATCH_LOCK"
    SLEEPER_HOLDS_LOCK=0
  fi
}

# Acquire the watcher singleton lock for the sleeper and record the same identity
# fields a real watcher records, so healthy_watcher() (and thus a second arm and
# fm-guard) recognizes the live cycle. Returns non-zero if another live holder
# already owns it.
claim_blackout_lock() {
  local pid=${BASHPID:-$$}
  fm_lock_try_acquire "$WATCH_LOCK" || return 1
  printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" 2>/dev/null || true
  printf '%s\n' "$WATCH" > "$WATCH_LOCK/watcher-path" 2>/dev/null || true
  fm_pid_identity "$pid" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true
  SLEEPER_HOLDS_LOCK=1
  touch "$BEAT" 2>/dev/null || true
  return 0
}

# The blackout end hour as HH:00 for the status line (e.g. 05:00).
blackout_end_label() {
  local end=${FM_BLACKOUT_END_HOUR:-5}
  case "$end" in ''|*[!0-9]*) end=5 ;; esac
  printf '%02d:00 ET' "$end"
}

# Block (zero tokens, no polling) until the blackout window ends, then release the
# lock and return 0 so the caller starts the real watcher. If another live cycle
# already holds the singleton, report it and exit 0 without starting a duplicate.
run_blackout_sleeper() {
  local pid=${BASHPID:-$$} holder
  if ! claim_blackout_lock; then
    holder=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
    echo "watcher: blackout until $(blackout_end_label) (resume scheduled) pid=${holder:-?} (already scheduled)"
    exit 0
  fi
  echo "watcher: blackout until $(blackout_end_label) (resume scheduled) pid=$pid"
  while fm_in_blackout; do
    # Self-eviction: if the singleton lock no longer names us, another cycle took
    # over; stand down without releasing its lock.
    if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$pid" ]; then
      SLEEPER_HOLDS_LOCK=0
      exit 0
    fi
    touch "$BEAT" 2>/dev/null || true
    sleep "$BLACKOUT_CHUNK"
  done
  # Window ended: hand the lock back so the real watcher acquires it fresh.
  release_sleeper_lock
  return 0
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
    if watch_lock_matches_pid "$lock_pid"; then
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

# The watcher runs as a tracked child that stays ours for its whole life: we wait
# on it, so killing this arm (the harness-tracked task) tears the watcher down too,
# and the watcher's eventual wake exit propagates out so the harness re-notifies
# firstmate. child/child_out are (re)set per active pass; declared here so the
# traps can reference them across the blackout outer loop.
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
# On signal or exit, tear down the watcher child (if any) and release the blackout
# sleeper lock (if held) so neither is orphaned.
trap 'cleanup_child; release_sleeper_lock; exit 129' HUP
trap 'cleanup_child; release_sleeper_lock; exit 143' TERM INT
trap 'release_sleeper_lock' EXIT

# Outer loop for the blackout transition: an active watcher that crosses INTO the
# quiet-hours window exits with FM_BLACKOUT_EXIT_CODE, and we loop back into the
# sleeper instead of surfacing that as a wake - so crossing into blackout, like
# the whole night, costs zero tokens. Every other outcome exits directly.
while :; do
  # Overnight blackout: do NOT start an active watcher. Block (zero tokens, no
  # polling) until the window ends, then fall through to start the real watcher.
  # If a cycle is already scheduled, run_blackout_sleeper reports it and exits.
  if fm_in_blackout; then
    run_blackout_sleeper
  fi

  # If a genuinely live+fresh watcher already holds the lock, do not start a second
  # one - the singleton would no-op anyway. Report it honestly and return success.
  # (--restart skips this on the first pass: it just stopped this home's watcher.)
  if [ "$mode" = arm ] && healthy_watcher; then
    report_healthy
    exit 0
  fi
  mode=arm  # later passes (after a blackout leg) are ordinary arms.

  child=
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
  reenter_blackout=0
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
  while :; do
    if healthy_watcher; then
      if [ "$HEALTHY_PID" = "$child" ]; then
        echo "watcher: started pid=$child (beacon fresh)"
        wait "$child"
        rc=$?
        # An active watcher that crossed into blackout exits with the blackout
        # code: loop back to the sleeper instead of surfacing a wake.
        if [ "$rc" -eq "$FM_BLACKOUT_EXIT_CODE" ]; then
          rm -f "$child_out" 2>/dev/null || true
          child= ; child_out=
          reenter_blackout=1
          break
        fi
        print_watch_output "$child_out"
        rm -f "$child_out" 2>/dev/null || true
        exit "$rc"
      fi
      # Another watcher won the singleton; our child stood down. Report the live one.
      report_healthy
      wait "$child" 2>/dev/null || true
      rm -f "$child_out" 2>/dev/null || true
      exit 0
    fi
    if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
      wait "$child"
      rc=$?
      child_done=1
      # The window flipped to blackout mid-startup (6pm landed during confirm):
      # go sleep instead of reporting FAILED.
      if [ "$rc" -eq "$FM_BLACKOUT_EXIT_CODE" ]; then
        rm -f "$child_out" 2>/dev/null || true
        child= ; child_out=
        reenter_blackout=1
        break
      fi
      if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
        print_watch_output "$child_out"
        rm -f "$child_out" 2>/dev/null || true
        exit 0
      fi
    fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.2
  done

  # Broke out because the watcher entered the blackout window: loop back to the
  # sleeper (no wake, no FAILED).
  [ "$reenter_blackout" = 1 ] && continue

  echo "watcher: FAILED - no live watcher with a fresh beacon"
  cleanup_child
  wait "$child" 2>/dev/null || true
  exit 1
done
