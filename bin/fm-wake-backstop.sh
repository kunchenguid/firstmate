#!/usr/bin/env bash
# fm-wake-backstop.sh - independent recovery for a Claude primary whose
# Stop-hook rewake was lost (docs/watcher-continuity.md "Wake backstop").
#
# Usage:
#   fm-wake-backstop.sh ensure   # start this home's loop unless one serves this session
#   fm-wake-backstop.sh check    # one detection pass; prints one verdict line
#   fm-wake-backstop.sh stop     # stop this home's recorded loop
#   fm-wake-backstop.sh run      # the loop itself (ensure launches it)
#
# WHY. Every re-arm and rewake of a Claude primary hangs off a Stop. When one
# Stop chain drops its wake (on 2026-10-23 the hook refused a rewake commit
# and exited 0), nothing else can start a turn in an idle session, so queued
# wakes wait until a human types. The `WATCHER DOWN` banner reaches only a
# session that runs a command. This loop is the one path that does not wait
# for a Stop.
#
# DETECTION (check). A wake is stranded when, in a genuine primary home that is
# not a secondmate home: no away or quiet record's daemon flag (state/.afk)
# exists, the session lock names a live harness, the oldest durable wake
# (state/.wake-queue) has waited at least FM_WAKE_BACKSTOP_SECS, and no live
# Stop-hook generation claim is open (fm_autoarm_claim_open, the same open-claim
# predicate both Stop participants use). A live open claim owns the delivery of
# its cycle's close; without one, no watcher cycle can reach an idle Claude
# session, so watcher health alone does not count as a live cycle: the cycle a
# pass-through leaves for main is healthy and still has no owner.
#
# RECOVERY (run). The loop delivers only after two consecutive passes see the
# same stranded oldest wake, so a rewake turn that is just starting is not
# doubled. It rings the primary's own pane with one record-backed operational
# doorbell of kind watcher (bin/fm-operational-input.sh), through the
# same backend primitives and guards the away daemon uses: the pane must exist,
# must not be busy, and its composer must be confirmed empty, so it never
# types into a turn or over the captain's half-typed text. The doorbell tells
# main to drain, handle, and acknowledge; that turn's end re-arms supervision
# through the ordinary Stop hook. The loop starts, stops, and attaches to no
# watcher, never runs a second supervision cycle, and never touches the
# auto-arm ledger. After a delivery it waits FM_WAKE_BACKSTOP_SECS before it
# rings again for a wake that is still stranded. A deferred delivery retries on
# the next pass. When no pane was proven at ensure time, it records
# state/.wake-backstop-alarm once per stranded wake and keeps checking.
#
# LIFETIME. ensure runs inside the primary's own process tree (bin/fm-session-
# start.sh and every Claude Stop through bin/fm-claude-stop-autoarm.sh) because
# pane discovery (bin/fm-supervisor-target-lib.sh) proves a Rex pane by
# ancestry. It resolves the pane, then launches the loop detached (nohup, its
# own process group, stdio away from the caller) bound to the session-lock pid.
# The loop records itself in state/.wake-backstop (pid, identity, primary pid)
# under a micro-mutex, so concurrent ensures leave one loop, and exits when its
# record names another process, when the session lock moves off its primary,
# or when its home is gone. ensure keeps a loop that serves the current
# session and replaces one bound to an ended session. stop and every
# replacement act only on the recorded pid with its recorded identity, never by
# name, so sibling homes are untouched.
#
# State (under state/): .wake-backstop (the loop record), .wake-backstop.lock
# (the micro-mutex), .wake-backstop.log (a bounded ledger of state changes and
# deliveries), .wake-backstop-delivered (the oldest wake sequence last rung and
# when), .wake-backstop-alarm (an undeliverable stranded wake).
#
# Tunables: FM_WAKE_BACKSTOP_SECS (600; 0 turns the backstop off: ensure and
# check are inert and a running loop exits), FM_WAKE_BACKSTOP_TICK (60).
# Only when FM_TEST_SEAM=1, FM_TEST_WAKE_BACKSTOP_DELIVER names a command run
# with the doorbell body as its one argument in place of pane delivery.
# Sourcing this file defines its functions and runs no mode, so a test can
# drive deliver against fake backend primitives.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  cat <<'EOF'
Usage: fm-wake-backstop.sh ensure | check | stop | run

Independent recovery for a Claude primary whose Stop-hook rewake was lost.
  ensure  start this home's loop for the current session unless one runs
  check   one detection pass; prints "wake-backstop: <verdict> - <detail>"
  stop    stop this home's recorded loop
  run     the loop itself; ensure launches it detached
Verdicts: inert (does not apply), clear (nothing stranded), stranded.
FM_WAKE_BACKSTOP_SECS (600, 0 = off), FM_WAKE_BACKSTOP_TICK (60).
EOF
}

THRESHOLD=${FM_WAKE_BACKSTOP_SECS:-600}
case "$THRESHOLD" in ''|*[!0-9]*) THRESHOLD=600 ;; esac
TICK=${FM_WAKE_BACKSTOP_TICK:-60}
case "$TICK" in ''|*[!0-9]*|0) TICK=60 ;; esac

RECORD="$STATE/.wake-backstop"
MUTEX="$STATE/.wake-backstop.lock"
LOG="$STATE/.wake-backstop.log"
DELIVERED="$STATE/.wake-backstop-delivered"
ALARM="$STATE/.wake-backstop-alarm"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}

log_line() {  # <text>
  local now tmp
  fm_epoch_seconds_to now
  printf '%s\t%s\n' "$now" "$1" >> "$LOG" 2>/dev/null || return 0
  if [ "$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')" -gt 400 ]; then
    tmp="$LOG.tmp.$$"
    tail -n 200 "$LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$LOG" 2>/dev/null
    rm -f "$tmp" 2>/dev/null || true
  fi
}

session_lock_pid() {
  local pid
  pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$pid"
}

# One detection pass. Sets VERDICT (inert|clear|stranded), DETAIL, and, for a
# queue with wakes, OLDEST_SEQ, OLDEST_AGE, WAKE_COUNT, and OLDEST_REASON.
VERDICT=
DETAIL=
OLDEST_SEQ=
OLDEST_AGE=
WAKE_COUNT=0
OLDEST_REASON=
backstop_check() {
  local lock_pid row now
  VERDICT=inert
  OLDEST_SEQ=
  OLDEST_AGE=
  WAKE_COUNT=0
  OLDEST_REASON=
  if [ "$THRESHOLD" -eq 0 ]; then
    DETAIL="turned off (FM_WAKE_BACKSTOP_SECS=0)"
    return
  fi
  if fm_root_is_secondmate_home "$FM_ROOT" || fm_root_is_secondmate_home "$FM_HOME"; then
    DETAIL="a secondmate home; its parent supervises it"
    return
  fi
  if ! fm_primary_scope_matches "$FM_ROOT" "$STATE"; then
    DETAIL="not a primary home"
    return
  fi
  if [ -e "$STATE/.afk" ]; then
    DETAIL="away or quiet mode: its daemon owns supervision"
    return
  fi
  if ! lock_pid=$(session_lock_pid) || ! fm_harness_pid_alive "$lock_pid"; then
    DETAIL="no live primary session holds the lock"
    return
  fi
  VERDICT=clear
  row=$(awk -F '\t' 'NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      n++
      if (min == "" || $1 + 0 < min + 0) { min = $1; seq = $2; reason = $5 }
    }
    END { if (n) printf "%s\t%s\t%s\t%s\n", n, min, seq, reason }' "$STATE/.wake-queue" 2>/dev/null || true)
  if [ -z "$row" ]; then
    DETAIL="no durable wake is queued"
    return
  fi
  IFS="$(printf '\t')" read -r WAKE_COUNT OLDEST_AGE OLDEST_SEQ OLDEST_REASON <<EOF
$row
EOF
  fm_epoch_seconds_to now
  OLDEST_AGE=$((now - OLDEST_AGE))
  [ "$OLDEST_AGE" -ge 0 ] || OLDEST_AGE=0
  if [ "$OLDEST_AGE" -lt "$THRESHOLD" ]; then
    DETAIL="$WAKE_COUNT wake(s) queued, the oldest for ${OLDEST_AGE}s (under ${THRESHOLD}s)"
    return
  fi
  if fm_autoarm_claim_open "$STATE" "$GRACE"; then
    DETAIL="$WAKE_COUNT wake(s) queued, the oldest for ${OLDEST_AGE}s, and a live Stop-hook cycle owns their delivery"
    return
  fi
  VERDICT=stranded
  DETAIL="$WAKE_COUNT wake(s) queued, the oldest (row $OLDEST_SEQ) for ${OLDEST_AGE}s, with no live Stop-hook cycle to deliver them"
}

doorbell_body() {
  printf 'firstmate wake backstop - %s durable wake(s) have waited %s minute(s) with no live supervision cycle, and no Stop-hook rewake reached this session (oldest: %s). Run bin/fm-wake-drain.sh first, handle the wakes, then run its exact WAKE_ACK_REQUIRED --ack-through command. This turn'"'"'s end re-arms supervision automatically - do NOT run bin/fm-watch-arm.sh.' \
    "$WAKE_COUNT" "$((OLDEST_AGE / 60))" "$(printf '%s' "$OLDEST_REASON" | cut -c1-200)"
  # The Stop hook's own rewake banner carries the same note.
  if [ -e "$STATE/.afk-contract" ] \
    && [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" != quiet ]; then
    printf ' This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture.'
  fi
}

# Ring the primary's pane once. Returns 0 when the backend confirmed the
# submit, 1 when the delivery was deferred or failed (DELIVER_WHY says why),
# and 3 when no pane was proven at ensure time.
DELIVER_WHY=
DELIVERY_LIBS=0
deliver() {
  local body msg backend=${FM_SUPERVISOR_BACKEND:-} target=${FM_SUPERVISOR_TARGET:-} native screen verdict
  DELIVER_WHY=
  body=$(doorbell_body)
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_TEST_WAKE_BACKSTOP_DELIVER:-}" ]; then
    "$FM_TEST_WAKE_BACKSTOP_DELIVER" "$body" && return 0
    DELIVER_WHY="the test delivery refused"
    return 1
  fi
  if [ -z "$backend" ] || [ -z "$target" ]; then
    DELIVER_WHY="no primary pane was proven when the backstop started"
    return 3
  fi
  if [ "$DELIVERY_LIBS" -eq 0 ]; then
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh" || { DELIVER_WHY="the backend library could not be loaded"; return 1; }
    # shellcheck source=bin/fm-operational-input.sh
    . "$SCRIPT_DIR/fm-operational-input.sh" || { DELIVER_WHY="the operational-input library could not be loaded"; return 1; }
    DELIVERY_LIBS=1
  fi
  if ! fm_backend_target_exists "$backend" "$target"; then
    DELIVER_WHY="the primary pane $target is gone on $backend"
    return 1
  fi
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || true)
  if [ "$native" = busy ]; then
    DELIVER_WHY="the primary is mid-turn"
    return 1
  fi
  # The away daemon's busy guard (pane_is_busy): native state, then the
  # harness's busy lines on the visible tail.
  if screen=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) \
    && declare -F fm_busy_lines_match >/dev/null \
    && printf '%s' "$screen" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match claude; then
    DELIVER_WHY="the primary is mid-turn"
    return 1
  fi
  if [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" != empty ]; then
    DELIVER_WHY="the primary's composer is not confirmed empty"
    return 1
  fi
  if fm_operational_harness_needs_record claude; then
    fm_operational_record_write "$STATE" watcher "$body" msg \
      || { DELIVER_WHY="the doorbell record could not be written"; return 1; }
  else
    fm_operational_input_encode watcher "$body" msg \
      || { DELIVER_WHY="the wake could not be encoded"; return 1; }
  fi
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$msg" 3 0.5 0.5 2>/dev/null)
  [ "$verdict" = empty ] && return 0
  DELIVER_WHY="the submit was not confirmed (verdict=${verdict:-none})"
  return 1
}

# True while the record names this process with its own identity.
still_recorded() {
  local pid identity
  IFS="$(printf '\t')" read -r pid identity _ 2>/dev/null < "$RECORD" || return 1
  [ "$pid" = "$SELF_PID" ] && [ "$identity" = "$SELF_IDENTITY" ]
}

# True when the recorded loop is alive under its recorded identity; sets
# RECORDED_PID and RECORDED_PRIMARY.
RECORDED_PID=
RECORDED_PRIMARY=
recorded_live() {
  local pid identity primary
  RECORDED_PID=
  RECORDED_PRIMARY=
  IFS="$(printf '\t')" read -r pid identity primary 2>/dev/null < "$RECORD" || return 1
  fm_pid_alive "$pid" || return 1
  [ -n "$identity" ] && [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$identity" ] || return 1
  RECORDED_PID=$pid
  RECORDED_PRIMARY=$primary
}

stop_recorded() {
  local i=0
  recorded_live || return 0
  kill -TERM "$RECORDED_PID" 2>/dev/null || true
  while [ "$i" -lt 50 ] && fm_pid_alive "$RECORDED_PID"; do
    sleep 0.1
    i=$((i + 1))
  done
}

run_loop() {
  local lock_pid stranded_seq='' last_seq last_at now rc last_why=''
  SELF_PID=${BASHPID:-$$}
  SELF_IDENTITY=$(fm_pid_identity "$SELF_PID" 2>/dev/null) || exit 1
  PRIMARY_PID=${FM_WAKE_BACKSTOP_PRIMARY_PID:-}
  case "$PRIMARY_PID" in ''|*[!0-9]*) exit 1 ;; esac
  fm_lock_acquire_wait "$MUTEX" || exit 1
  if recorded_live && [ "$RECORDED_PRIMARY" = "$PRIMARY_PID" ]; then
    fm_lock_release "$MUTEX"
    exit 0
  fi
  printf '%s\t%s\t%s\n' "$SELF_PID" "$SELF_IDENTITY" "$PRIMARY_PID" > "$RECORD.tmp.$SELF_PID" \
    && mv -f "$RECORD.tmp.$SELF_PID" "$RECORD"
  fm_lock_release "$MUTEX"
  SLEEP_PID=
  trap '[ -z "$SLEEP_PID" ] || kill "$SLEEP_PID" 2>/dev/null; exit 0' TERM INT HUP
  log_line "start	pid=$SELF_PID primary=$PRIMARY_PID pane=${FM_SUPERVISOR_BACKEND:-none}:${FM_SUPERVISOR_TARGET:-none}"
  while :; do
    # A waited background sleep lets a TERM end the loop at once.
    sleep "$TICK" &
    SLEEP_PID=$!
    wait "$SLEEP_PID"
    SLEEP_PID=
    [ -d "$STATE" ] || exit 0
    still_recorded || exit 0
    if ! lock_pid=$(session_lock_pid) || [ "$lock_pid" != "$PRIMARY_PID" ] || ! fm_harness_pid_alive "$lock_pid"; then
      log_line "exit	the session this loop served has ended"
      exit 0
    fi
    [ "$THRESHOLD" -ne 0 ] || exit 0
    backstop_check
    if [ "$VERDICT" != stranded ]; then
      stranded_seq=
      last_why=
      continue
    fi
    # Confirm across two passes on the same oldest wake.
    if [ "$stranded_seq" != "$OLDEST_SEQ" ]; then
      stranded_seq=$OLDEST_SEQ
      log_line "stranded	$DETAIL"
      continue
    fi
    last_seq='' last_at=0
    IFS="$(printf '\t')" read -r last_seq last_at 2>/dev/null < "$DELIVERED" || true
    case "$last_at" in ''|*[!0-9]*) last_at=0 ;; esac
    fm_epoch_seconds_to now
    if [ "$last_seq" = "$OLDEST_SEQ" ] && [ $((now - last_at)) -lt "$THRESHOLD" ]; then
      continue
    fi
    deliver
    rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\t%s\n' "$OLDEST_SEQ" "$now" > "$DELIVERED" 2>/dev/null || true
      rm -f "$ALARM" 2>/dev/null || true
      log_line "delivered	$DETAIL"
    elif [ "$rc" -eq 3 ]; then
      if [ "$(cat "$ALARM" 2>/dev/null)" != "$OLDEST_SEQ" ]; then
        printf '%s\n' "$OLDEST_SEQ" > "$ALARM" 2>/dev/null || true
        log_line "undeliverable	$DELIVER_WHY; $DETAIL"
      fi
    elif [ "$DELIVER_WHY" != "$last_why" ]; then
      log_line "deferred	$DELIVER_WHY"
    fi
    last_why=$DELIVER_WHY
  done
}

# Start this home's loop for the current session unless one already serves it.
ensure_loop() {
  local lock_pid target backend rex_server
  backstop_check
  if [ "$VERDICT" = inert ]; then
    printf 'wake-backstop: inert - %s\n' "$DETAIL"
    return 0
  fi
  lock_pid=$(session_lock_pid) || return 0
  if recorded_live; then
    if [ "$RECORDED_PRIMARY" = "$lock_pid" ]; then
      printf 'wake-backstop: running pid=%s\n' "$RECORDED_PID"
      return 0
    fi
    fm_lock_acquire_wait "$MUTEX" || return 1
    stop_recorded
    fm_lock_release "$MUTEX"
  fi
  # Resolve the primary's pane here, inside its process tree, and hand it to
  # the detached loop, which runs outside that tree. An unproven pane (the
  # discovery's bare fallback) is not handed on.
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
  rex_server=
  if target=$(discover_supervisor_target) && backend=$(discover_supervisor_backend); then
    [ "$backend" != rex ] || rex_server=$(discover_supervisor_rex_server 2>/dev/null || true)
  else
    target=
    backend=
  fi
  # The shape bin/fm-startup-network.sh uses for a worker that outlives its
  # launcher: its own process group, nohup, stdio detached.
  set -m 2>/dev/null || true
  FM_WAKE_BACKSTOP_PRIMARY_PID=$lock_pid FM_SUPERVISOR_TARGET=$target FM_SUPERVISOR_BACKEND=$backend \
    FM_REX_SERVER=${rex_server:-${FM_REX_SERVER:-}} \
    nohup "$SCRIPT_DIR/fm-wake-backstop.sh" run >/dev/null 2>&1 </dev/null &
  printf 'wake-backstop: started pid=%s pane=%s\n' "$!" "${backend:-none}:${target:-none}"
}

fm_wake_backstop_main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    ensure|check|stop|run) [ "$#" -eq 1 ] || { usage >&2; return 2; } ;;
    *) usage >&2; return 2 ;;
  esac
  case "$1" in
    check)
      backstop_check
      printf 'wake-backstop: %s - %s\n' "$VERDICT" "$DETAIL"
      ;;
    stop)
      fm_lock_acquire_wait "$MUTEX" || return 1
      stop_recorded
      rm -f "$RECORD" 2>/dev/null || true
      fm_lock_release "$MUTEX"
      ;;
    run) run_loop ;;
    ensure) ensure_loop ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_wake_backstop_main "$@"
  exit $?
fi
