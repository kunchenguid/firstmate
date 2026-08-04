#!/usr/bin/env bash
# fm-away-session.sh - the canonical away-mode activation and return action, and
# the single owner of the three-state away-supervision health verdict.
#
# Why this exists: away mode's durable transition was previously reachable only
# because a model read AGENTS.md, decided a sentence meant "afk", and chose to
# run a script. This script is the canonical action that decision resolves TO.
# bin/fm-away-intent.sh is its deterministic caller; a harness prompt hook can
# invoke that without any model turn.
#
# ACTIVATION STAYS FIRSTMATE-LOCAL. It claims no Runtime authority and adds no
# authorization-matrix row, because ADR-0048's acceptance clause reserves any new
# runtime authority to an explicit operator ruling and no such ruling exists.
# Whether activation should instead become a Runtime operation is an open
# operator decision, and the seam for it is exactly one place: command_start
# below performs the transition and commits its record, rolling the owned launch
# back if that commit fails. Making activation a Runtime
# operation means dispatching that operation there, in place of the local record
# write, and nothing else in this slice changes - the session identity, the
# ledger, the classifier, the ruling-request contract and the reentry summary all
# read the session record rather than the mechanism that produced it. Do not
# widen that seam without the ruling.
#
# It does NOT reimplement away mode. The durable flag, daemon terminal record,
# stale-artifact clearing and rollback stay with bin/fm-afk-launch.sh, and the
# return catch-up gate stays with bin/fm-afk-return.sh. This script composes
# those owners and adds one thing they cannot express: a stable SESSION IDENTITY
# plus an append-only evidence ledger (bin/fm-away-lib.sh), so a classification,
# a ruling request and a reentry summary all bind to the same away stretch
# across a restart.
#
# Usage:
#   fm-away-session.sh start [--intent <text>] [--native] [--activation <src>]
#                           Canonical activation. Runs the existing away-mode
#                           launch, then records (or refreshes) the session;
#                           a failed initial record rolls the launch back.
#                           Idempotent: a second start while away mode is
#                           already active refreshes timestamps, keeps the same
#                           session id, and logs a repeat rather than opening a
#                           second session. --native prepares lifecycle state
#                           for a harness-native background daemon job
#                           (fm-afk-launch.sh start-native) instead of creating
#                           a terminal.
#   fm-away-session.sh return [--no-report]
#                           Canonical return. Runs the existing catch-up gate,
#                           records the return, prints the decision-oriented
#                           reentry summary, and closes the session record only
#                           after the gate actually cleared.
#   fm-away-session.sh show   Print the current session record.
#   fm-away-session.sh id     Print the current session id (empty when none).
#   fm-away-session.sh health [--report]
#                           Print away and supervision state. Default prints
#                           machine-readable away=/supervision=/detail= lines;
#                           --report prints the one-line session-start wording.
#   fm-away-session.sh event <kind> [<k>=<v> ...]
#                           Append one evidence line to the current ledger.
#   fm-away-session.sh ledger [<kind>]
#                           Print the current session's ledger lines.
#
# Supervision health is THREE-state and never collapses them, because an
# away-mode health report that can lie is worse than none:
#   active   the daemon lock names a live process whose identity still matches.
#   down     provably not running - no lock, a lock whose recorded pid is dead,
#            or a pid recycled by an unrelated process.
#   unknown  the lock exists but liveness genuinely cannot be decided here (an
#            unreadable owner, or no usable process-identity source).
set -u

FM_AWAY_SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-away-lib.sh
. "$FM_AWAY_SESSION_DIR/fm-away-lib.sh"
# fm-afk-start.sh exposes daemon_lock_owner and is sourceable behind a
# BASH_SOURCE guard. It enables errexit, so turn that back off immediately.
# shellcheck source=bin/fm-afk-start.sh
. "$FM_AWAY_SESSION_DIR/fm-afk-start.sh"
set +e

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

log() { printf 'fm-away-session: %s\n' "$*" >&2; }

# --- supervision health -----------------------------------------------------
#
# Sets FM_AWAY_SUPERVISION and FM_AWAY_SUPERVISION_DETAIL. Deliberately does not
# reuse daemon_lock_held_by_live_daemon: that predicate answers yes/no, and a no
# there covers both "provably not running" and "could not tell", which is the
# exact collapse this report must not make.
away_supervision_state() {
  local owner pid expected current command
  FM_AWAY_SUPERVISION=unknown
  FM_AWAY_SUPERVISION_DETAIL=

  if ! owner=$(daemon_lock_owner); then
    FM_AWAY_SUPERVISION=down
    FM_AWAY_SUPERVISION_DETAIL='no supervisor lock exists'
    return 0
  fi
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*)
      FM_AWAY_SUPERVISION=unknown
      FM_AWAY_SUPERVISION_DETAIL='supervisor lock is present without a readable owner pid'
      return 0
      ;;
  esac
  if ! fm_pid_alive "$pid"; then
    FM_AWAY_SUPERVISION=down
    FM_AWAY_SUPERVISION_DETAIL="recorded supervisor pid $pid is not running"
    return 0
  fi
  expected=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$expected" ]; then
    if ! current=$(fm_pid_identity "$pid"); then
      FM_AWAY_SUPERVISION=unknown
      FM_AWAY_SUPERVISION_DETAIL="pid $pid is alive but no process-identity source is readable here"
      return 0
    fi
    if [ "$current" = "$expected" ]; then
      FM_AWAY_SUPERVISION=active
      FM_AWAY_SUPERVISION_DETAIL="supervisor pid $pid is running"
      return 0
    fi
    FM_AWAY_SUPERVISION=down
    FM_AWAY_SUPERVISION_DETAIL="recorded supervisor pid $pid was recycled by an unrelated process"
    return 0
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  if [ -z "$command" ]; then
    FM_AWAY_SUPERVISION=unknown
    FM_AWAY_SUPERVISION_DETAIL="pid $pid is alive but its command line is not readable here"
    return 0
  fi
  case "$command" in
    *fm-supervise-daemon.sh*)
      FM_AWAY_SUPERVISION=active
      FM_AWAY_SUPERVISION_DETAIL="supervisor pid $pid is running"
      ;;
    *)
      FM_AWAY_SUPERVISION=down
      FM_AWAY_SUPERVISION_DETAIL="recorded supervisor pid $pid runs an unrelated command"
      ;;
  esac
}

away_flag_present() {
  [ -e "$FM_AWAY_STATE/.afk" ]
}

command_health() {
  local report=0 away=inactive
  [ "${1:-}" != --report ] || report=1
  away_supervision_state
  ! away_flag_present || away=active

  if [ "$report" -eq 0 ]; then
    printf 'away=%s\n' "$away"
    printf 'supervision=%s\n' "$FM_AWAY_SUPERVISION"
    printf 'detail=%s\n' "$FM_AWAY_SUPERVISION_DETAIL"
    return 0
  fi

  if [ "$away" = inactive ]; then
    printf 'absent\n'
    return 0
  fi
  case "$FM_AWAY_SUPERVISION" in
    active)
      printf 'present - away mode is on and away-mode supervision is running (%s).\n' \
        "$FM_AWAY_SUPERVISION_DETAIL"
      ;;
    down)
      printf 'present - away mode is on but away-mode supervision is NOT running (%s); nothing is supervising the fleet until it is restarted.\n' \
        "$FM_AWAY_SUPERVISION_DETAIL"
      ;;
    *)
      printf 'present - away mode is on and away-mode supervision could not be determined (%s); treat supervision as unconfirmed rather than active.\n' \
        "$FM_AWAY_SUPERVISION_DETAIL"
      ;;
  esac
}

# --- canonical activation ---------------------------------------------------

command_start() {
  local intent='' native=0 activation=canonical session now existing launch_mode was_away=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --intent) shift; intent=${1:-} ;;
      --activation) shift; activation=${1:-} ;;
      --native) native=1 ;;
      *) usage >&2; return 2 ;;
    esac
    shift
  done
  case "$activation" in
    ''|*[!A-Za-z0-9._-]*) log "activation source must be a slug"; return 2 ;;
  esac

  # FM_AWAY_LAUNCH_MODE is the test seam that lets the canonical action be
  # exercised without creating a real daemon terminal, mirroring
  # FM_AFK_LAUNCH_ENTRY in bin/fm-afk-launch.sh. It only ever selects between
  # the two modes fm-afk-launch.sh already supports.
  launch_mode=${FM_AWAY_LAUNCH_MODE:-}
  if [ -z "$launch_mode" ]; then
    launch_mode=start
    [ "$native" -eq 0 ] || launch_mode=start-native
  fi
  case "$launch_mode" in
    start|start-native) ;;
    *) log "FM_AWAY_LAUNCH_MODE must be start or start-native"; return 2 ;;
  esac
  ! away_flag_present || was_away=1
  if ! "$FM_AWAY_SESSION_DIR/fm-afk-launch.sh" "$launch_mode"; then
    log 'away-mode launch refused; no away session was opened'
    return 1
  fi

  now=$(date +%s)
  existing=$(fm_away_session_id)
  if [ -n "$existing" ] && fm_away_valid_session_id "$existing"; then
    session=$existing
    write_record "$session" "$(fm_away_field started)" "$now" \
      "$(fm_away_field activation)" "$(fm_away_field intent)" \
      || { rollback_launch "$was_away"; return 1; }
    fm_away_ledger_append "$session" activation-repeat \
      "source=$activation" "intent=$intent" \
      || { rollback_launch "$was_away"; return 1; }
    printf '%s\n' "$session"
    log "away session $session was already open; refreshed it (no second session)"
    return 0
  fi

  case "${FM_AWAY_TEST_FAILURE:-}" in
    allocation|allocation-rollback) session= ;;
    *) session=$(fm_away_new_session_id "$now") ;;
  esac
  if [ -z "$session" ]; then
    log 'could not allocate a session id'
    if [ "$was_away" -eq 1 ]; then
      log 'pre-existing away mode remains active without a session record; rollback was not permitted'
    else
      rollback_launch "$was_away"
    fi
    return 1
  fi
  case "${FM_AWAY_TEST_FAILURE:-}" in
    record|record-rollback)
      if [ "$was_away" -eq 1 ]; then
        log 'pre-existing away mode remains active without a session record; the record write failed and rollback was not permitted'
      else
        rollback_launch "$was_away"
      fi
      return 1
      ;;
  esac
  write_record "$session" "$now" "$now" "$activation" "$intent" \
    || {
      if [ "$was_away" -eq 1 ]; then
        log 'pre-existing away mode remains active without a session record; the record write failed and rollback was not permitted'
      else
        rollback_launch "$was_away"
      fi
      return 1
    }
  if [ "${FM_AWAY_TEST_FAILURE:-}" = ledger ]; then
    activation_ledger_failure "$session" "$was_away"
    return 1
  fi
  fm_away_ledger_append "$session" activation \
    "source=$activation" "intent=$intent" "home=$FM_HOME" \
    || { activation_ledger_failure "$session" "$was_away"; return 1; }
  printf '%s\n' "$session"
}

activation_ledger_failure() {  # <session> <was-away>
  if [ "$2" -eq 1 ]; then
    log "away session $1 record was preserved, but its activation ledger event is missing"
    return 1
  fi
  if rollback_launch "$2"; then
    fm_away_record_clear
    return 1
  fi
  log "away session $1 record was preserved because teardown is unconfirmed; its activation ledger event is missing"
  return 1
}

rollback_launch() {  # <was-away>
  [ "$1" -eq 0 ] || return 0
  case "${FM_AWAY_TEST_FAILURE:-}" in
    rollback|*-rollback) log 'away-mode rollback failed; teardown could not be confirmed'; return 1 ;;
  esac
  if ! "$FM_AWAY_SESSION_DIR/fm-afk-launch.sh" stop; then
    log 'away-mode rollback failed; teardown could not be confirmed'
    return 1
  fi
}

write_record() {  # <session> <started> <refreshed> <activation> <intent>
  {
    printf 'schema\t%s\n' "$FM_AWAY_SCHEMA"
    printf 'session\t%s\n' "$(fm_away_clean_field "$1")"
    printf 'started\t%s\n' "$(fm_away_clean_field "$2")"
    printf 'refreshed\t%s\n' "$(fm_away_clean_field "$3")"
    printf 'activation\t%s\n' "$(fm_away_clean_field "$4")"
    printf 'intent\t%s\n' "$(fm_away_clean_field "$5")"
  } | fm_away_record_write
}

# --- canonical return -------------------------------------------------------

command_return() {
  local report=1 session gate_rc=0
  [ "${1:-}" != --no-report ] || report=0
  session=$(fm_away_session_id)

  "$FM_AWAY_SESSION_DIR/fm-afk-return.sh"
  gate_rc=$?

  if [ -n "$session" ] && fm_away_valid_session_id "$session"; then
    if [ "$gate_rc" -eq 0 ]; then
      fm_away_ledger_append "$session" return 'outcome=cleared' || return 1
    else
      fm_away_ledger_append "$session" return-blocked "gate_rc=$gate_rc" || return 1
    fi
    if [ "$report" -eq 1 ]; then
      "$FM_AWAY_SESSION_DIR/fm-away-continuation.sh" reentry --session "$session" || true
    fi
    # The record is the pointer to the CURRENT session. Clear it only once the
    # gate actually cleared, so a blocked return keeps binding new evidence to
    # the same session. The ledger itself is never removed.
    [ "$gate_rc" -ne 0 ] || fm_away_record_clear || return 1
  fi
  return "$gate_rc"
}

# --- evidence ---------------------------------------------------------------

command_event() {
  local session kind
  [ "$#" -ge 1 ] || { usage >&2; return 2; }
  kind=$1
  shift
  session=$(fm_away_session_id)
  [ -n "$session" ] || { log 'no away session is open'; return 1; }
  fm_away_ledger_append "$session" "$kind" "$@"
}

command_ledger() {
  local session
  session=$(fm_away_session_id)
  [ -n "$session" ] || { log 'no away session is open'; return 1; }
  fm_away_ledger_read "$session" "${1:--}"
}

case "${1:-}" in
  start) shift; command_start "$@" ;;
  return) shift; command_return "$@" ;;
  show) [ -f "$FM_AWAY_RECORD" ] && cat "$FM_AWAY_RECORD" ;;
  id) fm_away_session_id; printf '\n' ;;
  health) shift; command_health "$@" ;;
  event) shift; command_event "$@" ;;
  ledger) shift; command_ledger "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
