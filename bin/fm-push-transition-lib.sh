#!/usr/bin/env bash
# Shared owner of the watcher's native push-transition escalation.
#
# The watcher and event-wait smoke tests source this library instead of loading
# the whole watcher to obtain handle_push_transition. Its source list is limited
# to the four production boundaries the transition handler actually calls.

FM_PUSH_TRANSITION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-transition-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-transition-lib.sh"

TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}

# Append one bounded best-effort line for an absorbed supervision event.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

# Exit after reporting one actionable wake. Tests override this callback.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

_hb_surfaced_path() {
  printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"
}

# Record a captain-relevant status after its durable wake has been enqueued.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

fm_wake_append_stale_for_recorded_window() {  # <window> <reason>
  local window=$1 reason=$2 status=0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  if [ -z "$(fm_backend_meta_for_window "$window" "$STATE" 2>/dev/null || true)" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 3
  fi
  fm_wake_append_locked stale "$window" "$reason" || status=$?
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

# Act on a fresh actionable transition from a push-capable backend.
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason meta status
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  WAKE_QUEUE_LOCK_HELD=1
  meta=$(fm_backend_meta_for_window "$window" "$STATE" 2>/dev/null || true)
  if [ -z "$meta" ]; then
    WAKE_QUEUE_LOCK_HELD=0
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return
  fi
  task=$(basename "$meta")
  task=${task%.meta}
  if status_is_paused "$(last_status_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared pause, awaiting external): $window"
    if ! fm_backend_commit_transition "$backend" "$STATE" "$session" "$record"; then
      WAKE_QUEUE_LOCK_HELD=0
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      exit 1
    fi
    WAKE_QUEUE_LOCK_HELD=0
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  if ! fm_wake_append_locked stale "$window" "$reason"; then
    WAKE_QUEUE_LOCK_HELD=0
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    exit 1
  fi
  if ! fm_backend_commit_transition "$backend" "$STATE" "$session" "$record"; then
    WAKE_QUEUE_LOCK_HELD=0
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    exit 1
  fi
  mark_surfaced "$STATE/$task.status"
  status=0
  wake "$reason" || status=$?
  WAKE_QUEUE_LOCK_HELD=0
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  if [ "$status" -ne 0 ]; then
    exit 1
  fi
}
