#!/usr/bin/env bash
# fm-pending-reply-remind.sh - one reminder for an unresolved pending-reply escalation.
#
# Usage: fm-pending-reply-remind.sh <state-dir>
#        fm-pending-reply-remind.sh --token <state-dir>
#
# The reminder is one check wake per later live session, with no second recovery
# and no second status line. --token prints the live session token and does not
# wake. An empty token and an unchanged token are no-ops. The library stays free
# of these wake and session-lock calls so every script that sources it does not
# re-analyse them.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || SCRIPT_DIR="."
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

# Live session token. FM_PENDING_REPLY_SESSION, when set, is the token (tests).
# Otherwise a held session lock's pid, joined with the recorded session id.
fm_pending_reply_session_token() {  # <state-dir>
  local state=$1 recorded
  if [ -n "${FM_PENDING_REPLY_TOKEN_HOOK:-}" ]; then
    eval "$FM_PENDING_REPLY_TOKEN_HOOK"
  fi
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

# Remind unresolved escalations once per later live session.
fm_pending_reply_remind_escalated() {  # <state-dir>
  local state=$1 token dir rec corr task summary payload key queued rc=0
  local -a open=() recs=()
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
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
    [ "$(fm_pending_reply_get "$rec" surfaced_session)" != "$token" ] || continue
    if fm_pending_reply_escalation_dismissed "$rec"; then
      _fm_pending_reply_stamp_escalated "$state" "$rec" escalation_dismissed_epoch "$(fm_pending_reply_now)" || return 1
      continue
    fi
    recs+=("$rec")
  done
  [ "${#recs[@]}" -gt 0 ] || return 0
  FM_WAKE_QUEUE="$state/.wake-queue"
  FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock"
  key=pending-reply-escalated
  payload='pending-reply-escalated:'
  for rec in "${recs[@]}"; do
    corr=$(fm_pending_reply_get "$rec" corr_id)
    task=$(fm_pending_reply_get "$rec" task_id)
    summary=$(fm_pending_reply_get "$rec" request_summary)
    payload="$payload task=$task pending-reply-id=$corr request=$summary;"
  done
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  queued=$(fm_wake_queued_keys_locked check)
  case "
$queued
" in
    *"
$key
"*) ;;
    *) fm_wake_append_locked check "$key" "$payload" || rc=$? ;;
  esac
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  [ "$rc" -eq 0 ] || return "$rc"
  for rec in "${recs[@]}"; do
    _fm_pending_reply_stamp_escalated "$state" "$rec" surfaced_session "$token" || return 1
  done
  return 0
}

if [ "${1:-}" = --token ]; then
  [ -n "${2:-}" ] || exit 2
  fm_pending_reply_session_token "$2"
  exit $?
fi
[ -n "${1:-}" ] || exit 2
fm_pending_reply_remind_escalated "$1"
