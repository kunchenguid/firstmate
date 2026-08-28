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
# shellcheck source=bin/fm-human-notify-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-human-notify-lib.sh"

TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
FM_WAKE_POST_OUTPUT_ACTION=
# Set only after this watcher has printed a durable actionable reason. The
# watcher's EXIT cleanup uses it to distinguish an ordinary delivered close from
# an interruption that leaves a recovery gap before the next arm.
FM_WATCH_DELIVERED_REASON=
FM_WATCH_DELIVERY_PID=
FM_WATCH_DELIVERY_IDENTITY=
WATCH_DELIVERY_LOG="$STATE/.watch-deliveries.log"
WATCH_DELIVERY_LOCK="$STATE/.watch-deliveries.lock"
WATCH_DELIVERY_MAX_BYTES=${FM_WATCH_DELIVERY_MAX_BYTES:-65536}
WATCH_DELIVERY_KEEP_LINES=${FM_WATCH_DELIVERY_KEEP_LINES:-64}
case "$WATCH_DELIVERY_MAX_BYTES" in ''|*[!0-9]*|0) WATCH_DELIVERY_MAX_BYTES=65536 ;; esac
case "$WATCH_DELIVERY_KEEP_LINES" in ''|*[!0-9]*|0) WATCH_DELIVERY_KEEP_LINES=64 ;; esac

watch_delivery_clean_identity() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

watch_delivery_clean_reason() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-4096
}

watch_delivery_clean_payload() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

watch_delivery_publish() {
  local reason=$1 sequence=$2 payload=$3 i size tmp raw
  [ -n "$FM_WATCH_DELIVERY_PID" ] || return 0
  [ -n "$FM_WATCH_DELIVERY_IDENTITY" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$WATCH_DELIVERY_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$FM_WATCH_DELIVERY_PID" \
    "$(watch_delivery_clean_identity "$FM_WATCH_DELIVERY_IDENTITY")" \
    "$(watch_delivery_clean_reason "$reason")" \
    "$sequence" \
    "$(watch_delivery_clean_payload "$payload")" >> "$WATCH_DELIVERY_LOG" 2>/dev/null || true
  size=$(wc -c < "$WATCH_DELIVERY_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$WATCH_DELIVERY_MAX_BYTES" ]; then
        tmp="$WATCH_DELIVERY_LOG.tmp.$FM_WATCH_DELIVERY_PID"
        raw="$tmp.raw"
        tail -n "$WATCH_DELIVERY_KEEP_LINES" "$WATCH_DELIVERY_LOG" 2>/dev/null \
          | tail -c "$WATCH_DELIVERY_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^[0-9]+\t/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$WATCH_DELIVERY_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$WATCH_DELIVERY_LOCK"
}

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

FM_WATCH_DELIVERY_SEQUENCE=
FM_WATCH_DELIVERY_PAYLOAD=
FM_WATCH_DELIVERY_PRESELECTED=
watch_delivery_preselect() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  FM_WATCH_DELIVERY_SEQUENCE=$1
  FM_WATCH_DELIVERY_PAYLOAD=$2
  FM_WATCH_DELIVERY_PRESELECTED=1
}

watch_delivery_select() {
  local requested=${FM_WAKE_APPENDED_SEQUENCE:-} selected
  FM_WATCH_DELIVERY_SEQUENCE=
  FM_WATCH_DELIVERY_PAYLOAD=
  FM_WATCH_DELIVERY_PRESELECTED=
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if [ -n "$requested" ]; then
    selected=$(awk -F '\t' -v sequence="$requested" 'NF >= 5 && $2 == sequence { print $2 "\t" $5; exit }' "$FM_WAKE_QUEUE" 2>/dev/null)
  else
    selected=$(awk -F '\t' 'NF >= 5 && $2 ~ /^[0-9]+$/ { value=$2 "\t" $5 } END { print value }' "$FM_WAKE_QUEUE" 2>/dev/null)
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  if [ -z "$selected" ] && [ -n "$requested" ]; then
    selected="$requested$(printf '\t')$FM_WAKE_APPENDED_PAYLOAD"
  fi
  FM_WATCH_DELIVERY_SEQUENCE=${selected%%"$(printf '\t')"*}
  [ "$FM_WATCH_DELIVERY_SEQUENCE" != "$selected" ] || FM_WATCH_DELIVERY_SEQUENCE=
  FM_WATCH_DELIVERY_PAYLOAD=${selected#*"$(printf '\t')"}
  case "$FM_WATCH_DELIVERY_SEQUENCE" in ''|*[!0-9]*) return 1 ;; esac
}

# Exit after reporting one actionable wake. Tests override this callback.
wake() {
  local output_status=0
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  trap '' HUP INT TERM
  [ -z "$FM_WAKE_POST_OUTPUT_ACTION" ] || trap '' PIPE
  if [ "$FM_WATCH_DELIVERY_PRESELECTED" != 1 ]; then
    watch_delivery_select || true
  fi
  if echo "$1"; then
    output_status=0
    watch_delivery_publish "$1" "$FM_WATCH_DELIVERY_SEQUENCE" "$FM_WATCH_DELIVERY_PAYLOAD" || true
    # shellcheck disable=SC2034 # Read by bin/fm-watch.sh's EXIT cleanup.
    FM_WATCH_DELIVERED_REASON=$1
  else
    output_status=1
  fi
  if [ -n "$FM_WAKE_POST_OUTPUT_ACTION" ]; then
    "$FM_WAKE_POST_OUTPUT_ACTION" "$output_status" || true
  fi
  [ "$output_status" -eq 0 ] || exit "$output_status"
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

fm_push_transition_apply_status() {  # <state> <window> <backend-status>
  local state=$1 window=$2 to=$3 task status_file last line
  FM_PUSH_TRANSITION_STATUS_LINE=
  task=$(window_to_task "$window" "$state")
  [ -n "$task" ] || return 1
  status_file="$state/$task.status"
  [ ! -L "$status_file" ] || return 1
  last=$(last_status_line "$status_file")
  case "$to" in
    working)
      line='working: live supervision reported active work'
      ;;
    blocked)
      if [ "$(status_line_verb "$last")" = blocked ]; then
        line=$last
      else
        line='blocked: live supervision reported the worker blocked'
      fi
      ;;
    *)
      return 1
      ;;
  esac
  if [ "$last" != "$line" ]; then
    printf '%s\n' "$line" >> "$status_file" || return 1
  fi
  fm_human_notify_apply_transition "$state" "$task" "$line" || true
  FM_PUSH_TRANSITION_STATUS_LINE=$line
}

# Act on a fresh actionable transition from a push-capable backend.
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason last display
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  if [ -f "$STATE/$task.meta" ]; then
    display=$(fm_display_name_for_meta "$STATE/$task.meta" "$task")
  else
    display=$(fm_display_name_fallback "$task")
  fi
  # External waits retain their bounded cadence. Captain-owned waits remain
  # silent until evidence changes or the captain answers.
  if status_is_paused "$last" || status_is_captain_held "$last"; then
    triage_log "absorbed push $to (declared wait): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  if [ "$to" = blocked ]; then
    fm_push_transition_apply_status "$STATE" "$window" "$to" || exit 1
    last=$FM_PUSH_TRANSITION_STATUS_LINE
  fi
  if fm_human_notify_class "$last" >/dev/null 2>&1; then
    if fm_backend_transition_reopened "$backend" "$STATE" "$session" "$record"; then
      fm_human_notify_reopen_blocker "$STATE" "$task"
    fi
    if ! fm_human_notify_pending "$STATE" "$task" "$last"; then
      triage_log "absorbed push $to (unchanged human-owned condition): $window"
      fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
      return
    fi
    reason="stale: $(fm_human_notify_summary "$STATE" "$task" "$last")"
  else
    reason="stale: $display: live supervision reported the worker $to without a declared wait. Action required: inspect the worker and choose recovery."
  fi
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status"
  fm_human_notify_record "$STATE" "$task" "$last" 2>/dev/null || true
  wake "$reason"
}
