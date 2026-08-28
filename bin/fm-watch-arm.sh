#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background), or - for a Claude
# primary - inside the Stop asyncRewake hook's foreground process tree
# (bin/fm-claude-stop-autoarm.sh), where the harness owns the process group and
# the hook's exit-2 rewake is the notification. Run it as its own standalone
# background task, never bundled onto the tail of another command.
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
#   watcher: attached pid=<N> (beacon <age>s)            - a live+fresh successor holds the lock;
#                                                          this arm attaches and follows it
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
#   watcher: FAILED - cycle ended without an actionable reason
#                                                        - a clean cycle ended with no wake and no
#                                                          verified healthy successor
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. After started it keeps verifying the owned child instead
# of reducing liveness to process existence: a live identity-matched child whose
# beacon reaches the shared grace is retired with a bounded TERM/KILL sequence,
# its stale ownership is released through the watcher-down recovery transition,
# and this arm fails loudly so a persistent adapter can retry without a primary
# session restart. On attached it stays live across identity-matched successors. A cycle
# that ends with no reason line and no healthy successor is resolved against the
# watcher's identity-bound delivery record: a matching record reports that wake
# and exits 0, and only a cycle that delivered nothing is the typed nonzero
# failure. Neither is ever a clean empty completion. On FAILED it exits non-zero
# so the failure is loud. A live cycle already present means re-arm attaches - do
# not start a second watcher.
#
# Every observed watcher cycle appends one tab-separated lifecycle record to
# state/.watch-cycle-exits.log. The arm layer owns that bounded ledger; it records
# arm/watcher identities, timestamps, exit/signal classification, beacon age,
# lock identity before and after close, and successor disposition. The separate
# state/.watch-triage.log remains exclusively the watcher's absorbed-wake debug
# log and is never written here.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and own a fresh cycle, or attach if a verified live peer
# wins the singleton while the duplicate child stands down. It
# resolves and signals exactly that pid, so it can never touch another home's
# watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings.
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
# Git Bash/MSYS pays a much higher fork cost while the watcher completes its
# required pre-lock migration, so its bounded default covers that cold start.
case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*) ARM_CONFIRM_DEFAULT=30 ;;
  *) ARM_CONFIRM_DEFAULT=10 ;;
esac
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-$ARM_CONFIRM_DEFAULT}
# Poll interval while attached to an existing healthy watcher; also the
# cadence for the owned-child wait loop and the watchdog's stale-beacon recheck.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}
# Seconds allowed for a stalled owned watcher to retire after TERM before its
# isolated process group receives KILL. This is deliberately much shorter than
# the liveness grace: once that grace has elapsed, keeping stale singleton
# ownership longer cannot restore supervision.
STALL_RETIRE_TIMEOUT=${FM_WATCH_STALL_RETIRE_TIMEOUT:-2}
case "$STALL_RETIRE_TIMEOUT" in ''|*[!0-9]*|0) STALL_RETIRE_TIMEOUT=2 ;; esac
CYCLE_LOG="$STATE/.watch-cycle-exits.log"
CYCLE_LOG_LOCK="$STATE/.watch-cycle-exits.lock"
CYCLE_LOG_MAX_BYTES=${FM_WATCH_CYCLE_LOG_MAX_BYTES:-262144}
CYCLE_LOG_KEEP_LINES=${FM_WATCH_CYCLE_LOG_KEEP_LINES:-1000}
ARM_PID=${BASHPID:-$$}
case "$CYCLE_LOG_MAX_BYTES" in ''|*[!0-9]*|0) CYCLE_LOG_MAX_BYTES=262144 ;; esac
case "$CYCLE_LOG_KEEP_LINES" in ''|*[!0-9]*|0) CYCLE_LOG_KEEP_LINES=1000 ;; esac

# The lifecycle ledger is diagnostic evidence, not a supervision dependency.
# Writes are bounded and best-effort so an observability failure cannot stall an
# otherwise healthy watcher cycle.
cycle_clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-512
}

lock_snapshot() {
  local pid identity
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  printf 'pid:%s|identity:%s' "$(cycle_clean_field "${pid:-none}")" "$(cycle_clean_field "${identity:-none}")"
}

WATCH_DELIVERY_LOG="$STATE/.watch-deliveries.log"
WATCH_DELIVERY_LOCK="$STATE/.watch-deliveries.lock"

cycle_active=0
cycle_watcher_pid=none
cycle_watcher_identity=none
cycle_origin=unknown
cycle_started_at=0
cycle_lock_before='pid:none|identity:none'

cycle_begin() {
  cycle_watcher_pid=$1
  cycle_origin=$2
  cycle_watcher_identity=$3
  cycle_started_at=$(date +%s)
  cycle_lock_before=$(lock_snapshot)
  cycle_active=1
}

cycle_refresh_lock_before() {
  [ "$cycle_active" -eq 1 ] || return 0
  if [ "$HEALTHY_PID" = "$cycle_watcher_pid" ] && [ -n "$HEALTHY_IDENTITY" ]; then
    cycle_watcher_identity=$HEALTHY_IDENTITY
  fi
  cycle_lock_before=$(lock_snapshot)
}

cycle_signal_name() {
  local rc=$1 signal_number
  case "$rc" in
    ''|*[!0-9]*) printf 'unknown'; return ;;
  esac
  [ "$rc" -gt 128 ] || { printf 'none'; return; }
  signal_number=$((rc - 128))
  kill -l "$signal_number" 2>/dev/null || printf '%s' "$signal_number"
}

cycle_log_append() {
  local exit_code=$1 signal=$2 reason=$3 successor=$4 ended_at beacon_age lock_after size tmp raw i
  [ "$cycle_active" -eq 1 ] || return 0
  ended_at=$(date +%s)
  beacon_age=$(fm_path_age "$BEAT")
  lock_after=$(lock_snapshot)

  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  printf 'arm_pid=%s\twatcher_pid=%s\torigin=%s\tstarted_at=%s\tended_at=%s\texit_code=%s\tsignal=%s\treason=%s\tbeacon_age=%s\tlock_before=%s\tlock_after=%s\tsuccessor=%s\n' \
    "$ARM_PID" \
    "$(cycle_clean_field "$cycle_watcher_pid")" \
    "$(cycle_clean_field "$cycle_origin")" \
    "$cycle_started_at" \
    "$ended_at" \
    "$(cycle_clean_field "$exit_code")" \
    "$(cycle_clean_field "$signal")" \
    "$(cycle_clean_field "$reason")" \
    "$beacon_age" \
    "$(cycle_clean_field "$cycle_lock_before")" \
    "$(cycle_clean_field "$lock_after")" \
    "$(cycle_clean_field "$successor")" >> "$CYCLE_LOG" 2>/dev/null || true

  size=$(wc -c < "$CYCLE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$CYCLE_LOG_MAX_BYTES" ]; then
        tmp="$CYCLE_LOG.tmp.$ARM_PID"
        raw="$tmp.raw"
        tail -n "$CYCLE_LOG_KEEP_LINES" "$CYCLE_LOG" 2>/dev/null \
          | tail -c "$CYCLE_LOG_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^arm_pid=/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$CYCLE_LOG_LOCK"
  cycle_active=0
}

# A persistent adapter passes the arm pid that just closed. Once this new arm
# verifies its watcher, update that predecessor's final record in place so the
# one-record-per-cycle ledger captures the actual successor outcome without an
# extra synthetic lifecycle row.
cycle_mark_predecessor_successor() {
  local successor=$1 predecessor=${FM_WATCH_PREDECESSOR_ARM_PID:-} i tmp
  case "$predecessor" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ -f "$CYCLE_LOG" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  tmp="$CYCLE_LOG.link.$ARM_PID"
  awk -v target="arm_pid=$predecessor" -v replacement="successor=$(cycle_clean_field "$successor")" '
    {
      lines[NR] = $0
      count = split($0, fields, "\t")
      if (fields[1] == target) {
        for (i = 1; i <= count; i += 1) {
          if (fields[i] == "successor=none") last = NR
        }
      }
    }
    END {
      for (i = 1; i <= NR; i += 1) {
        if (i == last) sub(/\tsuccessor=none$/, "\t" replacement, lines[i])
        print lines[i]
      }
    }
  ' "$CYCLE_LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  fm_lock_release "$CYCLE_LOG_LOCK"
}

clear_stale_recorded_watcher_lock() {
  local expected_pid=${1:-} lock_pid lock_home lock_path lock_identity
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if [ -n "$expected_pid" ]; then
    [ "$lock_pid" = "$expected_pid" ] || return 0
    fm_pid_alive "$lock_pid" && return 1
  fi
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$WATCH" ] || return 0
  [ -n "$lock_identity" ] || return 0
  fm_recovery_transition "$STATE/.watcher-down" clear-stale-lock "$WATCH_LOCK" downtime
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
HEALTHY_IDENTITY=
healthy_watcher() {
  HEALTHY_PID=
  HEALTHY_IDENTITY=
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" || return 1
  HEALTHY_PID=$FM_WATCHER_HEALTHY_PID
  HEALTHY_IDENTITY=$FM_WATCHER_HEALTHY_IDENTITY
}

report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: attached pid=$HEALTHY_PID (beacon ${age}s)"
}

# Give a successor the same bounded confirmation window used for a fresh child.
# Adapter-owned continuations normally win immediately, but the bound avoids a
# false failure when process-close delivery and lock publication cross briefly.
wait_for_healthy_successor() {
  local deadline
  # date(1) exposes whole seconds. Add one rounding second so a timeout of one
  # second cannot collapse to a few milliseconds when called near a boundary.
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
  while :; do
    healthy_watcher && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

fail_unexplained_cycle() {
  echo "watcher: FAILED - cycle ended without an actionable reason"
  return 1
}

# Close a cycle whose reason line this arm could not read against the bounded
# terminal-delivery ledger the watcher publishes before releasing its lock.
close_unobserved_cycle() {
  local i reason clean_identity record_pid record_identity record_reason
  clean_identity=$(printf '%s' "$cycle_watcher_identity" | tr '\t\r\n' '   ')
  i=0
  while ! fm_lock_try_acquire "$WATCH_DELIVERY_LOCK"; do
    [ "$i" -lt 20 ] || {
      fail_unexplained_cycle
      return 1
    }
    sleep 0.02
    i=$((i + 1))
  done
  reason=
  if [ -f "$WATCH_DELIVERY_LOG" ]; then
    while IFS=$'\t' read -r record_pid record_identity record_reason; do
      if [ "$record_pid" = "$cycle_watcher_pid" ] && [ "$record_identity" = "$clean_identity" ]; then
        reason=$record_reason
      fi
    done < "$WATCH_DELIVERY_LOG"
  fi
  fm_lock_release "$WATCH_DELIVERY_LOCK"
  if [ -n "$reason" ]; then
    printf '%s\n' "$reason"
    return 0
  fi
  fail_unexplained_cycle
  return 1
}

# Stay alive across identity-matched healthy holders. If one cycle ends, attach
# to a verified successor. With no successor, report the wake that cycle durably
# delivered, or fail loudly - never a clean empty completion that an adapter could
# mistake for a no-op.
attach_and_wait() {
  local attached_pid=$1
  while :; do
    if healthy_watcher; then
      if [ "$HEALTHY_PID" != "$attached_pid" ] || [ "$HEALTHY_IDENTITY" != "$cycle_watcher_identity" ]; then
        cycle_log_append unknown unknown lock-replaced "attached:$HEALTHY_PID"
        attached_pid=$HEALTHY_PID
        cycle_begin "$attached_pid" attached "$HEALTHY_IDENTITY"
        report_attached
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    if wait_for_healthy_successor; then
      cycle_log_append unknown unknown attached-cycle-ended "attached:$HEALTHY_PID"
      attached_pid=$HEALTHY_PID
      cycle_begin "$attached_pid" attached "$HEALTHY_IDENTITY"
      report_attached
      continue
    fi
    if close_unobserved_cycle; then
      cycle_log_append unknown unknown attached-delivered-wake none
      return 0
    fi
    cycle_log_append unknown unknown attached-cycle-ended none
    return 1
  done
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_attached_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  cycle_log_append "$rc" "$signal" arm-interrupted none
  exit "$rc"
}

trap 'handle_attached_signal HUP 129' HUP
trap 'handle_attached_signal TERM 143' TERM
trap 'handle_attached_signal INT 130' INT

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

watch_output_reason_type() {
  local out=$1 line
  line=$(grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null | head -1 || true)
  case "$line" in
    signal:*) printf 'actionable-signal' ;;
    stale:*) printf 'actionable-stale' ;;
    check:*) printf 'actionable-check' ;;
    heartbeat*) printf 'actionable-heartbeat' ;;
    *) printf 'none' ;;
  esac
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

handling_successor_generation() {
  [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ] || return 0
  fm_recovery_marker_snapshot "$STATE/.watcher-down" || return 1
  case "$FM_RECOVERY_MARKER_TOKEN" in
    pending:downtime:*|pending:handling:*|announced:downtime:*|announced:handling:*) printf '%s' "${FM_RECOVERY_MARKER_TOKEN##*:}" ;;
    acked:*|'') ;;
    *) return 1 ;;
  esac
}

mode=arm
handling_generation=
handling_watcher_pid=
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  --handling-delivered)
    mode=handling-delivered
    handling_generation=${2:-}
    [ "${3:-}" = --watcher-pid ] || { echo "watcher: invalid handling delivery confirmation" >&2; exit 2; }
    handling_watcher_pid=${4:-}
    case "$handling_generation" in ''|*[!A-Za-z0-9._-]*) echo "watcher: invalid recovery generation" >&2; exit 2 ;; esac
    case "$handling_watcher_pid" in ''|*[!0-9]*) echo "watcher: invalid successor watcher pid" >&2; exit 2 ;; esac
    [ "$#" -eq 4 ] || { echo "watcher: unexpected handling delivery arguments" >&2; exit 2; }
    ;;
  *) echo "usage: $(basename "$0") [--restart | --handling-delivered GENERATION --watcher-pid PID]" >&2; exit 2 ;;
esac

if [ "$mode" = handling-delivered ]; then
  fm_pid_alive "$handling_watcher_pid" \
    && fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$handling_watcher_pid" "$FM_HOME" \
    && fm_recovery_marker_begin_handling "$STATE/.watcher-down" "$handling_generation"
  exit $?
fi

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
      if ! clear_stale_recorded_watcher_lock; then
        echo "watcher: FAILED - stale watcher recovery state could not be persisted" >&2
        exit 1
      fi
    fi
  fi
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - attach to that cycle and wait until it ends so the harness notify fires
# then, not as an immediate empty wake. (--restart skips this: it just stopped
# this home's watcher and wants a fresh one.)
if [ "$mode" = arm ] && healthy_watcher; then
  cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
  cycle_begin "$HEALTHY_PID" attached "$HEALTHY_IDENTITY"
  report_attached
  attach_and_wait "$HEALTHY_PID"
  exit $?
fi

# Start a watcher as a tracked child and confirm it before settling in. The child
# stays our child for its whole life: we wait on it, so killing this arm (the
# harness-tracked task) tears the watcher down too, and the watcher's eventual
# wake exit propagates out so the harness re-notifies firstmate.
child=
child_group=
child_out=
watchdog_pid=
watchdog_status=

watch_child_running() {
  local proc_root stat state_line
  local -a stat_fields
  [ -n "$child" ] || return 1
  fm_pid_alive "$child" || return 1
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$child/stat" ]; then
    state_line=$(cat "$proc_root/$child/stat" 2>/dev/null) || return 0
    read -r -a stat_fields <<< "${state_line##*)}"
    stat=${stat_fields[0]:-}
  else
    stat=$(ps -p "$child" -o stat= 2>/dev/null | sed 's/^[[:space:]]*//' || true)
  fi
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

signal_watch_child() {  # <signal>
  local signal=$1
  if [ -n "$child_group" ]; then
    kill -"$signal" -- "-$child_group" 2>/dev/null || true
  elif [ -n "$child" ]; then
    kill -"$signal" "$child" 2>/dev/null || true
  fi
}

# Retire the owned watcher without ever waiting indefinitely on the same child
# that caused the liveness failure. WATCH_CHILD_RC records the reaped status, or
# 124 if even KILL could not make the direct child waitable inside the bound.
# TERM is sent first and the child is given STALL_RETIRE_TIMEOUT to exit on its
# own, so a healthy watcher keeps the chance to persist recovery through its own
# EXIT trap. KILL escalates to the whole isolated process group only when the
# child is STILL alive after that bound: a routine teardown of a watcher that
# honored TERM never lands a group-wide SIGKILL on a fresh-beacon holder.
WATCH_CHILD_RC=0
retire_watch_child() {
  local deadline
  WATCH_CHILD_RC=0
  [ -n "$child" ] || return 0
  if watch_child_running; then
    signal_watch_child TERM
    deadline=$(( $(date +%s) + STALL_RETIRE_TIMEOUT + 1 ))
    while watch_child_running && [ "$(date +%s)" -lt "$deadline" ]; do
      sleep 0.05
    done
  fi
  if watch_child_running; then
    # The watcher did not exit in the TERM bound: sweep the whole isolated group
    # so a hung backend helper is not orphaned next to the stalled lock holder.
    signal_watch_child KILL
    deadline=$(( $(date +%s) + 2 ))
    while watch_child_running && [ "$(date +%s)" -lt "$deadline" ]; do
      sleep 0.05
    done
  fi
  if watch_child_running; then
    WATCH_CHILD_RC=124
    return 1
  fi
  if wait "$child" 2>/dev/null; then
    WATCH_CHILD_RC=0
  else
    WATCH_CHILD_RC=$?
  fi
  child=
  child_group=
  return 0
}

owned_child_has_stale_beacon() {
  local lock_pid age
  age=$(fm_path_age "$BEAT")
  [ "$age" -ge "$GRACE" ] || return 1
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$child" ] || return 1
  fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$child" "$FM_HOME" || return 1
  return 0
}

stop_owned_watchdog() {
  [ -n "$watchdog_pid" ] || return 0
  kill -TERM "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  watchdog_pid=
}

# Keep the arm following the child through a short poll so an actionable child
# close still propagates promptly, and once the watchdog has retired the
# stalled group the same poll is bounded by the retire deadline below instead
# of hanging on a child KILL cannot make waitable. A separate arm-owned
# watchdog performs only the stale-beacon check and retires the isolated
# watcher group when the shared grace expires.
start_owned_watchdog() {
  watchdog_status="$child_out.liveness"
  rm -f "$watchdog_status" 2>/dev/null || true
  (
    watchdog_sleep_pid=
    # shellcheck disable=SC2329 # Invoked indirectly by the signal trap below.
    stop_watchdog_sleep() {
      [ -z "$watchdog_sleep_pid" ] || kill -TERM "$watchdog_sleep_pid" 2>/dev/null || true
      exit 0
    }
    trap stop_watchdog_sleep HUP TERM INT
    while fm_pid_alive "$child"; do
      if owned_child_has_stale_beacon; then
        fm_path_age "$BEAT" > "$watchdog_status"
        signal_watch_child TERM
        sleep "$STALL_RETIRE_TIMEOUT"
        signal_watch_child KILL
        exit 0
      fi
      # Wait through a background sleep so the arm's stop signal interrupts the
      # wait immediately; a foreground sleep defers Bash's trap and delays every
      # healthy actionable close by the full polling interval.
      sleep "$ATTACH_POLL" &
      watchdog_sleep_pid=$!
      wait "$watchdog_sleep_pid" 2>/dev/null || true
      watchdog_sleep_pid=
    done
  ) &
  watchdog_pid=$!
}

cleanup_child() {
  stop_owned_watchdog
  retire_watch_child || true
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_arm_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  cycle_log_append "$rc" "$signal" arm-interrupted none
  cleanup_child
  exit "$rc"
}

trap 'handle_arm_signal HUP 129' HUP
trap 'handle_arm_signal TERM 143' TERM
trap 'handle_arm_signal INT 130' INT

child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
# Give the owned watcher a separate process group. The stale-beacon path can
# then retire a hung backend helper together with the watcher instead of killing
# only the lock holder and orphaning the subprocess it was blocked on.
monitor_was_on=0
case $- in *m*) monitor_was_on=1 ;; esac
set -m
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  ( set +m; export FM_WATCH_HANDLING_SUCCESSOR=1; exec "$WATCH" ) >"$child_out" &
else
  ( set +m; exec "$WATCH" ) >"$child_out" &
fi
child=$!
[ "$monitor_was_on" -eq 1 ] || set +m
child_group=$(ps -p "$child" -o pgid= 2>/dev/null | tr -d '[:space:]' || true)
[ "$child_group" = "$child" ] || child_group=
cycle_begin "$child" started "$(fm_pid_identity "$child" 2>/dev/null || true)"
child_done=0

owned_child_finished() {
  local rc=$1 signal reason_type status
  signal=$(cycle_signal_name "$rc")
  if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
    reason_type=$(watch_output_reason_type "$child_out")
    cycle_log_append "$rc" "$signal" "$reason_type" none
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    return 0
  fi

  if [ "$rc" -eq 0 ]; then
    if wait_for_healthy_successor; then
      cycle_log_append "$rc" "$signal" unexpected-clean-exit "attached:$HEALTHY_PID"
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      child=
      child_out=
      cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
      report_attached
      cycle_begin "$HEALTHY_PID" attached "$HEALTHY_IDENTITY"
      attach_and_wait "$HEALTHY_PID"
      return $?
    fi
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    if close_unobserved_cycle; then
      cycle_log_append "$rc" "$signal" clean-exit-delivered-wake none
      return 0
    fi
    cycle_log_append "$rc" "$signal" unexpected-clean-exit none
    return 1
  fi

  reason_type="nonzero-exit"
  [ "$signal" = none ] || reason_type="signal-exit"
  cycle_log_append "$rc" "$signal" "$reason_type" none
  print_watch_output "$child_out"
  if ! grep -q '^watcher: FAILED' "$child_out" 2>/dev/null; then
    echo "watcher: FAILED - watcher cycle exited $rc without an actionable reason"
  fi
  rm -f "$child_out" 2>/dev/null || true
  child=
  child_out=
  status=$rc
  [ "$status" -gt 0 ] || status=1
  return "$status"
}

# Follow a watcher this arm actually forked while rechecking the same strict
# identity+beacon predicate used for initial readiness. The old raw `wait`
# could never observe an alive-but-stalled watcher, so Pi/OpenCode kept an arm
# claim forever and every repair call became an ownership no-op.
wait_owned_child() {
  local stalled_pid age rc retire_deadline
  stalled_pid=$child
  start_owned_watchdog
  rc=124
  retire_deadline=
  while watch_child_running; do
    if [ -z "$retire_deadline" ] && [ -s "$watchdog_status" ]; then
      retire_deadline=$(( $(date +%s) + STALL_RETIRE_TIMEOUT + 3 ))
    fi
    if [ -n "$retire_deadline" ] && [ "$(date +%s)" -ge "$retire_deadline" ]; then
      break
    fi
    sleep "$ATTACH_POLL"
  done
  if watch_child_running; then
    WATCH_CHILD_RC=124
  elif wait "$child" 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi
  stop_owned_watchdog
  if [ -s "$watchdog_status" ]; then
    age=$(cat "$watchdog_status" 2>/dev/null || fm_path_age "$BEAT")
    signal_watch_child KILL
    # If the deadline broke the loop with the child still running, it was never
    # reaped by the `elif wait` above. Give the KILL a bounded moment to drop the
    # process into a reapable state so the arm does not leave a zombie or a lock
    # holder behind before returning.
    bail_deadline=$(( $(date +%s) + 2 ))
    while fm_pid_alive "$child" && [ "$(date +%s)" -lt "$bail_deadline" ]; do
      sleep 0.05
    done
    # Only reap when the child is dead or a reapable zombie; a child that truly
    # survives SIGKILL (an uninterruptible D-state wait) must not block this arm
    # forever on `wait` - that would reintroduce the unbounded hang the bounded
    # retirement exists to prevent. Reaping a zombie always returns immediately,
    # so a normal retire is unchanged. A still-alive child then fails the stale
    # release below, keeping its lock exactly as the retirement contract records.
    if [ -n "$child" ] && { ! fm_pid_alive "$child" || ! watch_child_running; }; then
      wait "$child" 2>/dev/null || true
    fi
    child=
    child_group=
    if ! fm_recovery_marker_publish "$STATE/.watcher-down" downtime \
      || ! clear_stale_recorded_watcher_lock "$stalled_pid"; then
      cycle_log_append "$rc" "$(cycle_signal_name "$rc")" stale-beacon-release-failed none
      echo "watcher: FAILED - watcher pid=$stalled_pid stopped advancing its beacon for ${age}s; recovery state could not release stale ownership"
      return 1
    fi
    cycle_log_append "$rc" "$(cycle_signal_name "$rc")" stale-beacon-retired none
    rm -f "$child_out" "$watchdog_status" 2>/dev/null || true
    child=
    child_group=
    child_out=
    watchdog_status=
    echo "watcher: FAILED - watcher pid=$stalled_pid stopped advancing its beacon for ${age}s; retired the stalled cycle and released stale ownership for bounded recovery"
    return 1
  fi
  rm -f "$watchdog_status" 2>/dev/null || true
  watchdog_status=
  owned_child_finished "$rc"
}

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
# date(1) exposes whole seconds. Keep the configured confirmation budget from
# collapsing when startup begins just before the next second boundary.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      cycle_refresh_lock_before
      if ! handling_generation=$(handling_successor_generation); then
        cleanup_child
        cycle_log_append 1 none handling-handoff-failed none
        echo "watcher: FAILED - established successor could not inspect handling state"
        exit 1
      fi
      cycle_mark_predecessor_successor "started:$child"
      if [ -n "$handling_generation" ]; then
        echo "watcher: started pid=$child (beacon fresh) recovery-generation=$handling_generation"
      else
        echo "watcher: started pid=$child (beacon fresh)"
      fi
      wait_owned_child
      exit $?
    fi
    # Another watcher won the singleton; our child stood down. Give it a
    # bounded chance to exit so a live-but-stalled child can never block the
    # arm in wait forever, mirroring the won-race retirement above.
    if watch_child_running; then
      retire_deadline=$(( $(date +%s) + STALL_RETIRE_TIMEOUT + CONFIRM_TIMEOUT ))
      while watch_child_running && [ "$(date +%s)" -lt "$retire_deadline" ]; do
        sleep "$ATTACH_POLL"
      done
    fi
    if watch_child_running; then
      stalled_pid=$child
      cleanup_child
      cycle_log_append "$WATCH_CHILD_RC" "$(cycle_signal_name "$WATCH_CHILD_RC")" child-stand-down-stalled none
      echo "watcher: FAILED - our child pid=$stalled_pid stalled before standing down; retired the stalled child"
      exit 1
    fi
    wait "$child"
    rc=$?
    owned_child_finished "$rc"
    exit $?
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    wait "$child"
    rc=$?
    child_done=1
    owned_child_finished "$rc"
    exit $?
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
print_watch_output "$child_out"
cleanup_child
rc=$WATCH_CHILD_RC
cycle_log_append "$rc" "$(cycle_signal_name "$rc")" confirmation-timeout none
echo "watcher: FAILED - no live watcher with a fresh beacon"
exit 1
