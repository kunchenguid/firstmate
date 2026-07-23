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
#   watcher: attached pid=<N> (beacon <age>s)            - a live+fresh successor holds the lock;
#                                                          this arm attaches and follows it
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
#   watcher: FAILED - cycle ended without an actionable reason
#                                                        - a clean cycle ended with no wake and no
#                                                          verified healthy successor
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started it waits the child and propagates the wake
# reason; on attached it stays live across identity-matched successors. An
# attached cycle that ends without a healthy successor is a typed nonzero failure,
# never a clean empty completion. On FAILED it exits non-zero so the failure is
# loud. A live cycle already present means re-arm attaches - do not start a second
# watcher.
#
# Every observed watcher cycle holds one tab-separated lifecycle record in
# state/.watch-cycle-exits.log. The arm layer owns that bounded ledger; it records
# arm/watcher identities, timestamps, exit/signal classification, beacon age,
# lock identity before and after close, and successor disposition. The separate
# state/.watch-triage.log remains exclusively the watcher's absorbed-wake debug
# log and is never written here.
#
# The record is written OPEN when the cycle begins (ended_at=0, exit_code=open,
# reason=cycle-open, lock_after=pending, successor=none) and rewritten in place
# with its classified outcome when the cycle ends. SIGKILL and process-group kills
# cannot run the traps below, so a cycle that dies that way leaves its open record
# behind instead of vanishing from the ledger built to explain exactly that. Find
# those cycles with:
#   grep 'exit_code=open' state/.watch-cycle-exits.log
# and treat a row whose arm_pid is no longer alive as an unexplained cycle death;
# a row whose arm_pid is still alive is simply the cycle running right now. A row
# its own arm could not close because the ledger lock was contended is retired as
# exit_code=superseded reason=cycle-superseded when that arm opens its next cycle,
# so one arm never leaves a second unclosed row to be read as a kill. An arm
# retires only rows it published itself, matched on arm pid AND start stamp, so a
# kill recorded under a pid the system has since recycled keeps its open row.
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
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}
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

cycle_active=0
cycle_watcher_pid=none
cycle_origin=unknown
cycle_started_at=0
cycle_lock_before='pid:none|identity:none'
# Space-delimited start stamps THIS process published and has not reconciled yet.
# A pid is not proof of ownership - it is recycled - so a row is this arm's only
# when its start stamp is one this process itself wrote.
cycle_open_stamps=' '

# One record shape for both ends of a cycle: the OPEN row written when the cycle
# begins and the classified record that replaces it in place when the cycle ends.
# The field order is the ledger's contract (tests/fm-watcher-lock.test.sh guards
# it); change it there and here together.
cycle_record_line() {  # <ended_at> <exit_code> <signal> <reason> <beacon_age> <lock_after> <successor>
  printf 'arm_pid=%s\twatcher_pid=%s\torigin=%s\tstarted_at=%s\tended_at=%s\texit_code=%s\tsignal=%s\treason=%s\tbeacon_age=%s\tlock_before=%s\tlock_after=%s\tsuccessor=%s\n' \
    "$ARM_PID" \
    "$(cycle_clean_field "$cycle_watcher_pid")" \
    "$(cycle_clean_field "$cycle_origin")" \
    "$cycle_started_at" \
    "$1" \
    "$(cycle_clean_field "$2")" \
    "$(cycle_clean_field "$3")" \
    "$(cycle_clean_field "$4")" \
    "$5" \
    "$(cycle_clean_field "$cycle_lock_before")" \
    "$(cycle_clean_field "$6")" \
    "$(cycle_clean_field "$7")"
}

# Bounded, best-effort serialization for every ledger mutation. A budget-exhausted
# caller gives up on the write rather than delaying the cycle it is describing.
cycle_log_lock() {
  local i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 1
    sleep 0.02
    i=$((i + 1))
  done
  return 0
}

# Hold the ledger to its bounded size. Every write path calls this while it still
# holds CYCLE_LOG_LOCK, so a home whose arms are repeatedly killed untrappably
# cannot grow the log without bound through open rows alone. Trimming keeps the
# TAIL, so the row the caller just wrote survives and an in-place record rewrite
# cannot be corrupted. Best-effort like every other ledger write: a failed trim
# leaves the log as it was and never fails the cycle.
cycle_log_trim() {
  local size tmp raw
  size=$(wc -c < "$CYCLE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$size" -ge "$CYCLE_LOG_MAX_BYTES" ] || return 0
  tmp="$CYCLE_LOG.tmp.$ARM_PID"
  raw="$tmp.raw"
  tail -n "$CYCLE_LOG_KEEP_LINES" "$CYCLE_LOG" 2>/dev/null \
    | tail -c "$CYCLE_LOG_MAX_BYTES" > "$raw" 2>/dev/null \
    && awk 'NR > 1 || /^arm_pid=/' "$raw" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
  rm -f "$tmp" "$raw" 2>/dev/null || true
  return 0
}

# A close that loses the ledger lock gives up on its rewrite, so this arm's row
# stays open while the arm moves on. Retire any still-open row left by an EARLIER
# cycle of this same arm before publishing the next one: one live arm must never
# show two unclosed rows, or the older one reads for the rest of the ledger's life
# as the untrappable kill the open row exists to report. The retired row keeps the
# cycle it describes (arm, watcher, origin, start stamp, lock identity before) and
# any successor already linked onto it, and carries its own classified reason so it
# is never confused with a normal close or with a genuine unexplained death.
# A row is eligible only when its arm pid AND its start stamp are this process's
# own, exactly as the close rewrite below matches, so a dead arm's kill evidence
# under a recycled pid is never rewritten. Idempotent: a retired row is no longer
# open, and the reconciled stamps are dropped once the pass has run. Callers hold
# CYCLE_LOG_LOCK.
cycle_supersede_stranded_rows() {
  local tmp rc
  case "$cycle_open_stamps" in
    *[0-9]*) ;;
    *) return 0 ;;
  esac
  [ -f "$CYCLE_LOG" ] || return 0
  tmp="$CYCLE_LOG.supersede.$ARM_PID"
  FM_CYCLE_TARGET="arm_pid=$ARM_PID" \
    FM_CYCLE_STAMPS="$cycle_open_stamps" \
    FM_CYCLE_ENDED="$(date +%s)" \
    FM_CYCLE_BEACON="$(fm_path_age "$BEAT")" \
    FM_CYCLE_LOCK_AFTER="$(cycle_clean_field "$(lock_snapshot)")" awk '
    BEGIN {
      FS = "\t"
      OFS = "\t"
      count = split(ENVIRON["FM_CYCLE_STAMPS"], published, " ")
      for (i = 1; i <= count; i += 1)
        if (published[i] != "") mine["started_at=" published[i]] = 1
    }
    NF == 12 && $1 == ENVIRON["FM_CYCLE_TARGET"] && $6 == "exit_code=open" && ($4 in mine) {
      $5 = "ended_at=" ENVIRON["FM_CYCLE_ENDED"]
      $6 = "exit_code=superseded"
      $7 = "signal=none"
      $8 = "reason=cycle-superseded"
      $9 = "beacon_age=" ENVIRON["FM_CYCLE_BEACON"]
      $11 = "lock_after=" ENVIRON["FM_CYCLE_LOCK_AFTER"]
      retired = 1
    }
    { print }
    END { if (!retired) exit 1 }
  ' "$CYCLE_LOG" > "$tmp" 2>/dev/null
  rc=$?
  if [ "$rc" -eq 0 ]; then
    mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null && cycle_open_stamps=' '
  elif [ "$rc" -eq 1 ]; then
    cycle_open_stamps=' '
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# Publish the cycle's row BEFORE the cycle runs. SIGKILL and process-group kills
# cannot run the traps that close a record, so a cycle that dies that way used to
# leave no ledger evidence at all - the one death mode the ledger most needs to
# explain. The open row survives instead, and close rewrites it in place, so the
# ledger keeps exactly one row per observed cycle.
cycle_log_open_row() {
  cycle_log_lock || return 0
  cycle_supersede_stranded_rows
  cycle_record_line 0 open none cycle-open "$(fm_path_age "$BEAT")" pending none >> "$CYCLE_LOG" 2>/dev/null || true
  cycle_open_stamps="$cycle_open_stamps$cycle_started_at "
  cycle_log_trim
  fm_lock_release "$CYCLE_LOG_LOCK"
}

cycle_begin() {
  cycle_watcher_pid=$1
  cycle_origin=$2
  cycle_started_at=$(date +%s)
  cycle_lock_before=$(lock_snapshot)
  cycle_active=1
  cycle_log_open_row
}

cycle_refresh_lock_before() {
  [ "$cycle_active" -eq 1 ] || return 0
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
  local exit_code=$1 signal=$2 reason=$3 successor=$4 ended_at beacon_age lock_after record closed=0 tmp
  [ "$cycle_active" -eq 1 ] || return 0
  ended_at=$(date +%s)
  beacon_age=$(fm_path_age "$BEAT")
  lock_after=$(lock_snapshot)
  record=$(cycle_record_line "$ended_at" "$exit_code" "$signal" "$reason" "$beacon_age" "$lock_after" "$successor")

  # A budget-exhausted close drops its record, but the cycle it describes is over
  # either way, so the cycle is never left half-open.
  cycle_log_lock || { cycle_active=0; return 0; }
  # Close this cycle's own open row in place, identified by arm pid AND start
  # stamp so a reused pid's abandoned row is never rewritten. The values reach awk
  # through the environment, never -v, so no field can be reinterpreted as an
  # escape. If the row is gone (rotated away) or the rewrite fails, fall back to a
  # plain append so a classified record is never lost to an observability failure.
  if [ -f "$CYCLE_LOG" ]; then
    tmp="$CYCLE_LOG.close.$ARM_PID"
    if FM_CYCLE_TARGET="arm_pid=$ARM_PID" \
      FM_CYCLE_STARTED="started_at=$cycle_started_at" \
      FM_CYCLE_RECORD="$record" awk '
      BEGIN { FS = "\t" }
      {
        lines[NR] = $0
        if ($1 == ENVIRON["FM_CYCLE_TARGET"] && $4 == ENVIRON["FM_CYCLE_STARTED"] && $6 == "exit_code=open") {
          open_row = NR
          open_successor = $NF
        }
      }
      END {
        if (!open_row) exit 1
        record = ENVIRON["FM_CYCLE_RECORD"]
        # A successor already linked onto this row by the next arm outranks the
        # closing default, so linking and closing the same cycle cannot race.
        if (open_successor != "successor=none" && record ~ /\tsuccessor=none$/)
          sub(/\tsuccessor=none$/, "\t" open_successor, record)
        for (i = 1; i <= NR; i += 1) print (i == open_row ? record : lines[i])
      }
    ' "$CYCLE_LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null; then
      closed=1
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi
  [ "$closed" -eq 1 ] || printf '%s\n' "$record" >> "$CYCLE_LOG" 2>/dev/null || true

  cycle_log_trim
  fm_lock_release "$CYCLE_LOG_LOCK"
  cycle_active=0
}

# A persistent adapter passes the arm pid that just closed. Once this new arm
# verifies its watcher, update that predecessor's final record in place so the
# one-record-per-cycle ledger captures the actual successor outcome without an
# extra synthetic lifecycle row.
cycle_mark_predecessor_successor() {
  local successor=$1 predecessor=${FM_WATCH_PREDECESSOR_ARM_PID:-} tmp
  case "$predecessor" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ -f "$CYCLE_LOG" ] || return 0
  cycle_log_lock || return 0
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

# Stay alive across identity-matched healthy holders. If one cycle ends, attach
# to a verified successor. With no successor, fail loudly instead of returning a
# clean empty completion that an adapter could mistake for a no-op.
attach_and_wait() {
  local attached_pid=$1
  while :; do
    if healthy_watcher; then
      if [ "$HEALTHY_PID" != "$attached_pid" ]; then
        cycle_log_append unknown unknown lock-replaced "attached:$HEALTHY_PID"
        attached_pid=$HEALTHY_PID
        cycle_begin "$attached_pid" attached
        report_attached
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    if wait_for_healthy_successor; then
      cycle_log_append unknown unknown attached-cycle-ended "attached:$HEALTHY_PID"
      attached_pid=$HEALTHY_PID
      cycle_begin "$attached_pid" attached
      report_attached
      continue
    fi
    cycle_log_append unknown unknown attached-cycle-ended none
    fail_unexplained_cycle
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
  cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
  cycle_begin "$HEALTHY_PID" attached
  report_attached
  attach_and_wait "$HEALTHY_PID"
  exit $?
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

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_arm_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
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
"$WATCH" >"$child_out" &
child=$!
cycle_begin "$child" started
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
      cycle_begin "$HEALTHY_PID" attached
      attach_and_wait "$HEALTHY_PID"
      return $?
    fi
    cycle_log_append "$rc" "$signal" unexpected-clean-exit none
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    fail_unexplained_cycle
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
      cycle_mark_predecessor_successor "started:$child"
      echo "watcher: started pid=$child (beacon fresh)"
      wait "$child"
      rc=$?
      owned_child_finished "$rc"
      exit $?
    fi
    # Another watcher won the singleton; our child stood down.
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
wait "$child" 2>/dev/null
rc=$?
cycle_log_append "$rc" "$(cycle_signal_name "$rc")" confirmation-timeout none
echo "watcher: FAILED - no live watcher with a fresh beacon"
exit 1
