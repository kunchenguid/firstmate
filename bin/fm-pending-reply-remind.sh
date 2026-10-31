#!/usr/bin/env bash
# fm-pending-reply-remind.sh - one reminder for an unresolved pending-reply escalation.
#
# Usage: fm-pending-reply-remind.sh <state-dir>
#        fm-pending-reply-remind.sh --token <state-dir>
#        fm-pending-reply-remind.sh --decisions <state-dir>
#
# The reminder is one check wake per later live session, with no second recovery
# and no second status line. It runs only when config/pending-reply-resurface
# is present (docs/configuration.md). --token prints the live session token
# and does not wake. --decisions prints the Bearings JSON, or [] when the home
# has not opted in. An empty token and an unchanged token are no-ops. The
# library stays free of these wake and session-lock calls so every script that
# sources it does not re-analyse them.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || SCRIPT_DIR="."
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-pending-reply-resurface-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-resurface-lib.sh"

# Live session token. FM_PENDING_REPLY_SESSION, when set, is the token (tests).
# Otherwise a held session lock's pid, joined with the recorded session id.
fm_pending_reply_session_token() {  # <state-dir>
  local state=$1 recorded
  if [ -n "${FM_PENDING_REPLY_SESSION+x}" ]; then
    printf '%s' "$FM_PENDING_REPLY_SESSION"
    return 0
  fi
  fm_session_lock_inspect "$state"
  [ "${FM_LOCK_INSPECT_STATE:-}" = held ] || return 0
  printf '%s' "$FM_LOCK_INSPECT_PID"
  if recorded=$(fm_session_lock_recorded_session_id "$state"); then
    printf ':%s' "$recorded"
  fi
}

_fm_pending_reply_stamp_escalated() {  # <state-dir> <record-path> <field> <value>
  local state=$1 rec=$2 field=$3 value=$4 lock rc=0
  lock="$state/.pending-reply-$(basename "$rec").lock"
  fm_lock_acquire_wait "$lock" || return 1
  if [ "$(fm_pending_reply_get "$rec" phase)" = escalated ]; then
    fm_pending_reply_set "$rec" "$field" "$value" || rc=$?
  fi
  fm_lock_release "$lock"
  return "$rc"
}

# Under the record lock: save the dismissal verdict or scan, then 0 when the
# record still needs a reminder in session <token>, 1 when it does not, 2 when
# a save failed. The scan runs under the lock because a resend can reset and
# re-escalate the record between a scan and its save; a verdict read before
# the lock would then close the new escalation the operator never saw.
_fm_pending_reply_select_locked() {  # <record-path> <token>
  local rec=$1 token=$2 scan
  [ "$(fm_pending_reply_get "$rec" phase)" = escalated ] || return 1
  [ -z "$(fm_pending_reply_get "$rec" escalation_dismissed_epoch)" ] || return 1
  if fm_pending_reply_escalation_dismissed "$rec" scan; then
    fm_pending_reply_set "$rec" escalation_dismissed_epoch "$(fm_pending_reply_now)" || return 2
    return 1
  fi
  [ -z "$scan" ] || fm_pending_reply_set "$rec" escalation_dismiss_scan "$scan" || return 2
  [ "$(fm_pending_reply_get "$rec" surfaced_session)" != "$token" ]
}

# Under the queue lock: enqueue one check wake naming the records still due in
# session <token>, then stamp them before the lock is released. Session start
# and a watcher tick carry the same token and select without this lock, so
# both can select one record; the first to get here stamps it, and its wake
# may be handled and acknowledged before the second arrives. The recheck
# drops what the first pass named, and stamping under the lock keeps the
# drain from consuming the wake before the stamp lands.
_fm_pending_reply_remind_locked() {  # <state-dir> <token> <record-path>...
  local state=$1 token=$2 rec corr task summary payload
  local -a due=()
  shift 2
  for rec in "$@"; do
    [ "$(fm_pending_reply_get "$rec" phase)" = escalated ] || continue
    [ -z "$(fm_pending_reply_get "$rec" escalation_dismissed_epoch)" ] || continue
    [ "$(fm_pending_reply_get "$rec" surfaced_session)" != "$token" ] || continue
    due+=("$rec")
  done
  [ "${#due[@]}" -gt 0 ] || return 0
  payload='pending-reply-escalated:'
  for rec in "${due[@]}"; do
    corr=$(fm_pending_reply_get "$rec" corr_id)
    task=$(fm_pending_reply_get "$rec" task_id)
    summary=$(fm_pending_reply_get "$rec" request_summary)
    payload="$payload task=$task pending-reply-id=$corr request=$summary;"
  done
  fm_wake_append_locked check pending-reply-escalated "$payload" || return $?
  for rec in "${due[@]}"; do
    _fm_pending_reply_stamp_escalated "$state" "$rec" surfaced_session "$token" || return 1
  done
}

# Remind unresolved escalations once per later live session.
fm_pending_reply_remind_escalated() {  # <state-dir>
  local state=$1 token dir rec lock selected queued rc=0
  local -a open=() recs=()
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  fm_pending_reply_resurface_enabled || return 0
  dir=$(fm_pending_reply_dir "$state")
  [ -d "$dir" ] || return 0
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    case "$(basename "$rec")" in .*) continue ;; esac
    [ "$(fm_pending_reply_get "$rec" phase)" = escalated ] || continue
    [ -z "$(fm_pending_reply_get "$rec" escalation_dismissed_epoch)" ] || continue
    open+=("$rec")
  done
  [ "${#open[@]}" -gt 0 ] || return 0
  token=$(fm_pending_reply_session_token "$state")
  [ -n "$token" ] || return 0
  STATE=$state
  for rec in "${open[@]}"; do
    lock="$state/.pending-reply-$(basename "$rec").lock"
    fm_lock_acquire_wait "$lock" || return 1
    _fm_pending_reply_select_locked "$rec" "$token" && selected=0 || selected=$?
    fm_lock_release "$lock"
    case "$selected" in
      0) recs+=("$rec") ;;
      1) ;;
      *) return 1 ;;
    esac
  done
  [ "${#recs[@]}" -gt 0 ] || return 0
  FM_WAKE_QUEUE="$state/.wake-queue"
  FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  queued=$(fm_wake_queued_keys_locked check)
  case "
$queued
" in
    # A still-queued reminder does not name these records; remind them on a later pass.
    *"
pending-reply-escalated
"*) ;;
    *) _fm_pending_reply_remind_locked "$state" "$token" "${recs[@]}" || rc=$? ;;
  esac
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$rc"
}

if [ "${1:-}" = --token ]; then
  [ -n "${2:-}" ] || exit 2
  fm_pending_reply_session_token "$2"
  exit $?
fi
if [ "${1:-}" = --decisions ]; then
  [ -n "${2:-}" ] || exit 2
  if fm_pending_reply_resurface_enabled; then
    fm_pending_reply_escalated_decisions_json "$2"
  else
    printf '[]'
  fi
  exit $?
fi
[ -n "${1:-}" ] || exit 2
fm_pending_reply_remind_escalated "$1"
