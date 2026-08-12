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
# This script launches the watcher detached into its own session/process group,
# then follows that process and VERIFIES the outcome before it settles in. It
# confirms a watcher process is genuinely alive AND the liveness beacon
# (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the single source of
# truth, shared with fm-watch.sh and fm-guard.sh), and prints exactly one
# unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: attached pid=<N> (beacon <age>s)            - arm mode found a live+fresh watcher
#                                                          holding the lock and waits for that cycle
#   watcher: healthy pid=<N> (beacon <age>s)             - restart-only healthy peer
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# dead holder, or a reused PID whose current process no longer matches the stored
# watcher identity, self-heals through the singleton steal path and is confirmed;
# a live holder with no stale-identity proof returns the FAILED line. Started and
# attached arms follow the detached watcher until that verified cycle ends;
# restart-only healthy exits zero; on FAILED it exits non-zero so the failure is
# loud and a caller can react. A second arm that finds both a healthy cycle and a
# live follower reports attached and exits zero instead of stacking another long
# waiter.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and start a fresh one. It resolves and signals exactly that
# pid, so it can never touch another home's watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "watch arm" || exit 1
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-detach-lib.sh
. "$SCRIPT_DIR/fm-detach-lib.sh"
# shellcheck source=bin/fm-watcher-protocol-lib.sh
. "$SCRIPT_DIR/fm-watcher-protocol-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
ARM_PATH="$SCRIPT_DIR/fm-watch-arm.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
WATCH_OUT="$STATE/.watch.out"
ARM_LOCK="$STATE/.watch-arm.lock"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
# How long to wait for a freshly detached watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}
FOLLOWER_CLAIM_TIMEOUT=${FM_ARM_FOLLOWER_CLAIM_TIMEOUT:-10}

new_detach_token() {
  local token_file token
  token_file=$(mktemp "${TMPDIR:-/tmp}/firstmate-watch-token.XXXXXX") || return 1
  token=${token_file##*/}
  rm -f "$token_file"
  printf '%s\n' "$token"
}

watch_lock_matches_pid() {
  fm_watcher_lock_matches_pid "$WATCH_LOCK" "$1" "$FM_HOME" "$WATCH"
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
  [ "$(cat "$WATCH_LOCK/pending-reply-protocol" 2>/dev/null || true)" = "$FM_WATCHER_PROTOCOL_VERSION" ] || return 1
  age=$(fm_path_age "$BEAT")
  [ "$age" -lt "$GRACE" ] || return 1
  HEALTHY_PID=$pid
  return 0
}

legacy_watcher() {
  local pid
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  watch_lock_matches_pid "$pid" || return 1
  [ "$(cat "$WATCH_LOCK/pending-reply-protocol" 2>/dev/null || true)" != "$FM_WATCHER_PROTOCOL_VERSION" ] \
    || return 1
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
    # The attached watcher ended or lost its verified identity. Its output is
    # shared per-home because the watcher is detached and is not waitable by this
    # process.
    print_watch_output "$WATCH_OUT"
    exit 0
  done
}

ARM_LOCK_HELD=0
FOLLOWER_CLAIMED=0
ARM_FOLLOWER_UNVERIFIED=0
# shellcheck disable=SC2317 # called indirectly by the EXIT trap
release_arm_lock() {
  [ "$ARM_LOCK_HELD" -eq 1 ] || return 0
  fm_lock_release "$ARM_LOCK" 2>/dev/null || true
  ARM_LOCK_HELD=0
}

trap 'release_arm_lock' EXIT

# Claim the one follower slot for this home's current watcher cycle. A live
# holder means another arm is already waiting and this arm must not become a
# second hour-long waiter. A dead holder is allowed to age out and be reclaimed;
# this is the re-arm path after a harness reaped the previous follower.
claim_arm_follower() {
  local deadline=$(( $(date +%s) + FOLLOWER_CLAIM_TIMEOUT ))
  ARM_FOLLOWER_UNVERIFIED=0
  while :; do
    if fm_lock_try_acquire "$ARM_LOCK" "$ARM_PATH" "$FM_HOME" "$ARM_PATH"; then
      ARM_LOCK_HELD=1
      return 0
    fi
    if [ "${FM_LOCK_HELD_UNVERIFIED:-0}" -eq 1 ]; then
      ARM_FOLLOWER_UNVERIFIED=1
      return 2
    fi
    if [ -n "${FM_LOCK_HELD_PID:-}" ] && fm_pid_alive "$FM_LOCK_HELD_PID"; then
      return 1
    fi
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.1
  done
}

claim_arm_follower_after_handoff() {
  local deadline=$(( $(date +%s) + FOLLOWER_CLAIM_TIMEOUT ))
  ARM_FOLLOWER_UNVERIFIED=0
  while :; do
    if fm_lock_try_acquire "$ARM_LOCK" "$ARM_PATH" "$FM_HOME" "$ARM_PATH"; then
      ARM_LOCK_HELD=1
      return 0
    fi
    if [ "${FM_LOCK_HELD_UNVERIFIED:-0}" -eq 1 ]; then
      ARM_FOLLOWER_UNVERIFIED=1
      return 2
    fi
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.1
  done
}

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

watch_output_has_startup_failure() {
  local out=$1
  grep -Eq '^(PR_CHECK_MIGRATION:|watcher: PR check migration blocked)' "$out" 2>/dev/null
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

finish_cycle() {
  print_watch_output "$WATCH_OUT"
  if grep -qF 'watcher: FAILED' "$WATCH_OUT" 2>/dev/null; then
    exit 1
  fi
  exit 0
}

stop_recorded_watcher() {
  local lock_pid lock_start i
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  lock_start=$(cat "$WATCH_LOCK/pid-start" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if watch_lock_matches_pid "$lock_pid"; then
      if [ -z "$lock_start" ]; then
        echo "watcher: FAILED - watcher identity is not safely pinned for restart"
        return 1
      fi
      if ! fm_detach_kill "$lock_pid" "$lock_start"; then
        if fm_pid_alive "$lock_pid" && ! fm_pid_is_zombie "$lock_pid"; then
          echo "watcher: FAILED - watcher identity is not safely pinned for restart"
          return 1
        fi
      fi
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
      if fm_pid_alive "$lock_pid" && ! fm_pid_is_zombie "$lock_pid"; then
        echo "watcher: FAILED - watcher did not stop for restart"
        return 1
      fi
    else
      clear_stale_recorded_watcher_lock
    fi
  fi
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  --restart-verify) mode=restart_verify ;;
  *) echo "usage: $(basename "$0") [--restart|--restart-verify]" >&2; exit 2 ;;
esac

if [ "$mode" = arm ] && legacy_watcher; then
  if [ -e "$STATE/.afk" ]; then
    echo "watcher: FAILED - AFK daemon owns watcher lifecycle"
    exit 1
  fi
  fm_watcher_protocol_mark_reread_required "$STATE" || {
    echo "watcher: FAILED - reread obligation could not be persisted"
    exit 1
  }
  mode=restart
fi

if [ "$mode" = restart_verify ]; then
  fm_watcher_protocol_mark_required "$STATE" || {
    echo "watcher: FAILED - protocol fence could not be persisted"
    exit 1
  }
  if healthy_watcher \
    && fm_watcher_protocol_follower_proves_current "$STATE" "$FM_HOME" "$ARM_PATH" \
    && fm_watcher_protocol_gate "$STATE" "$FM_HOME" "$WATCH"; then
    report_healthy
    exit 0
  fi
  if [ -e "$STATE/.afk" ]; then
    echo "watcher: FAILED - AFK daemon owns watcher lifecycle"
    exit 1
  fi
  if ! fm_watcher_protocol_follower_proves_current "$STATE" "$FM_HOME" "$ARM_PATH"; then
    echo "watcher: FAILED - no verified harness follower for protocol handoff"
    exit 1
  fi
  fm_watcher_protocol_mark_reread_required "$STATE" || {
    echo "watcher: FAILED - reread obligation could not be persisted"
    exit 1
  }
  stop_recorded_watcher || exit 1
  echo "watcher: FAILED - legacy cycle stopped; harness follower must re-arm"
  exit 1
fi

if [ "$mode" = restart ]; then
  if claim_arm_follower; then
    FOLLOWER_CLAIMED=1
  elif [ "$ARM_FOLLOWER_UNVERIFIED" -eq 1 ]; then
    echo "watcher: FAILED - follower ownership is unverified"
    exit 1
  fi
  stop_recorded_watcher || exit 1
  if [ "$FOLLOWER_CLAIMED" -eq 0 ]; then
    if ! claim_arm_follower_after_handoff; then
      if [ "$ARM_FOLLOWER_UNVERIFIED" -eq 1 ]; then
        echo "watcher: FAILED - follower ownership is unverified"
        exit 1
      fi
      echo "watcher: FAILED - no follower slot available for restart"
      exit 1
    fi
    FOLLOWER_CLAIMED=1
  fi
fi

# A normal arm owns the one follower slot. If another arm already owns it, a
# healthy watcher is already being waited on and this invocation must not add a
# second long-lived process. The startup case uses the same slot so concurrent
# fresh arms cannot launch a pile of detached watchers before the singleton race
# settles.
if [ "$mode" = arm ]; then
  if healthy_watcher; then
    if claim_arm_follower; then
      FOLLOWER_CLAIMED=1
      fm_watcher_protocol_gate "$STATE" "$FM_HOME" "$WATCH" || {
        echo "watcher: FAILED - watcher protocol is not ready"
        exit 1
      }
      report_attached
      attach_and_wait "$HEALTHY_PID"
    fi
    if [ "$ARM_FOLLOWER_UNVERIFIED" -eq 1 ]; then
      echo "watcher: FAILED - follower ownership is unverified"
      exit 1
    fi
    if healthy_watcher; then
      if [ -n "${FM_LOCK_HELD_PID:-}" ] && fm_pid_alive "$FM_LOCK_HELD_PID"; then
        echo "watcher: follower already waiting pid=$FM_LOCK_HELD_PID"
        exit 0
      fi
      echo "watcher: FAILED - no follower slot available"
      exit 1
    fi
    echo "watcher: FAILED - no live watcher with a fresh beacon"
    exit 1
  fi
  if ! claim_arm_follower; then
    if [ "$ARM_FOLLOWER_UNVERIFIED" -eq 1 ]; then
      echo "watcher: FAILED - follower ownership is unverified"
      exit 1
    fi
    if [ -n "${FM_LOCK_HELD_PID:-}" ] && fm_pid_alive "$FM_LOCK_HELD_PID"; then
      echo "watcher: follower already waiting pid=$FM_LOCK_HELD_PID"
      exit 0
    fi
    echo "watcher: FAILED - no live watcher with a fresh beacon"
    exit 1
  fi
  FOLLOWER_CLAIMED=1
fi

# Start the watcher detached and confirm it before settling in. The arm follows
# the detached process by its home-scoped lock and beacon; it never waits on or
# kills this process as its child. The shared output survives an arm reap and is
# read by whichever follower attaches to the still-live watcher next.
child=
child_start=
child_token=
cleanup_detached_child() {
  # This is only the bounded startup-confirmation failure path. HUP/TERM traps
  # intentionally do not call it: a harness reap must leave the detached watcher
  # and its durable queue alive.
  if [ -n "$child" ]; then
    fm_detach_cleanup_unconfirmed "$child" "$child_start" "$WATCH" \
      "--fm-detach-token=$child_token" "__fm_detach_launcher__" || true
  fi
}
trap 'exit 129' HUP
trap 'exit 143' TERM INT

: > "$WATCH_OUT" || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
child_token=$(new_detach_token) || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
detach_status=0
child=$(fm_detach_spawn "$WATCH_OUT" "$WATCH" "--fm-detach-token=$child_token") || detach_status=$?
if [ "$detach_status" -ne 0 ]; then
  cleanup_detached_child
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
fi
child_start=$(fm_pid_start "$child" 2>/dev/null || true)

# Verify the outcome: poll until this detached watcher is the confirmed healthy
# holder, until another watcher legitimately holds the singleton, or until this
# detached process gives up.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      if [ "$FOLLOWER_CLAIMED" -eq 1 ]; then
        fm_watcher_protocol_gate "$STATE" "$FM_HOME" "$WATCH" || {
          echo "watcher: FAILED - watcher protocol is not ready"
          exit 1
        }
        echo "watcher: started pid=$child (beacon fresh)"
        attach_and_wait "$child"
      fi
      report_healthy
      exit 0
    fi
    # Another watcher won the singleton; this detached process stood down.
    if [ "$FOLLOWER_CLAIMED" -eq 1 ]; then
      fm_watcher_protocol_gate "$STATE" "$FM_HOME" "$WATCH" || {
        echo "watcher: FAILED - watcher protocol is not ready"
        exit 1
      }
      report_attached
      # The detached loser can only have written the watcher's benign singleton
      # status. Do not replay that startup race as a false wake when the peer's
      # cycle eventually ends.
      : > "$WATCH_OUT"
      attach_and_wait "$HEALTHY_PID"
    fi
    report_healthy
    exit 0
  fi
  if ! fm_pid_alive "$child"; then
    if watch_output_has_wake "$WATCH_OUT"; then
      finish_cycle
    fi
    if watch_output_has_startup_failure "$WATCH_OUT"; then
      print_watch_output "$WATCH_OUT"
      exit 1
    fi
    # A detached watcher can lose a startup singleton race before the peer's
    # beacon becomes fresh. Keep the arm's confirmation window open so it can
    # attach to that peer instead of reporting a false FAILED immediately.
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
echo "watcher: FAILED - no live watcher with a fresh beacon"
cleanup_detached_child
exit 1
