#!/usr/bin/env bash
# Shared owner of the watcher's native push-transition escalation.
#
# The watcher and event-wait smoke tests source this library instead of loading
# the whole watcher to obtain handle_push_transition. Its source list is limited
# to the production boundaries the transition handler actually calls.

FM_PUSH_TRANSITION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-transition-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-transition-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-timeout-lib.sh"

TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
FM_WAKE_POST_OUTPUT_ACTION=
# Set only after this watcher has printed a durable actionable reason. The
# watcher's EXIT cleanup uses it to distinguish an ordinary delivered close from
# an interruption that leaves a recovery gap before the next arm.
FM_WATCH_DELIVERED_REASON=
FM_WATCH_DELIVERY_PID=
FM_WATCH_DELIVERY_IDENTITY=
FM_WAKE_QUEUE_LOCK_HELD=0
FM_WAKE_PROGRESS_LOCK_HELD=0
WATCH_DELIVERY_LOG="$STATE/.watch-deliveries.log"
WATCH_DELIVERY_LOCK="$STATE/.watch-deliveries.lock"
WATCH_DELIVERY_PROGRESS="$STATE/.watch-delivery-progress"
WATCH_DELIVERY_PROGRESS_LOCK="$STATE/.watch-delivery-progress.lock"
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

watch_delivery_serialization_acquire() {
  case "$FM_WAKE_QUEUE_LOCK_HELD:$FM_WAKE_PROGRESS_LOCK_HELD" in
    0:0)
      fm_lock_acquire_wait "$WATCH_DELIVERY_PROGRESS_LOCK" || return 1
      FM_WAKE_PROGRESS_LOCK_HELD=1
      fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || {
        fm_lock_release "$WATCH_DELIVERY_PROGRESS_LOCK"
        FM_WAKE_PROGRESS_LOCK_HELD=0
        return 1
      }
      FM_WAKE_QUEUE_LOCK_HELD=1
      ;;
    1:1) ;;
    *) return 1 ;;
  esac
}

watch_delivery_serialization_release() {
  if [ "$FM_WAKE_QUEUE_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    FM_WAKE_QUEUE_LOCK_HELD=0
  fi
  if [ "$FM_WAKE_PROGRESS_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$WATCH_DELIVERY_PROGRESS_LOCK"
    FM_WAKE_PROGRESS_LOCK_HELD=0
  fi
}

watch_delivery_progress_watermark_locked() {
  local watermark
  watermark=$(cat "$STATE/.wake-queue.seq" 2>/dev/null || echo 0)
  case "$watermark" in ''|*[!0-9]*) watermark=0 ;; esac
  printf '%s\n' "$watermark"
}

watch_delivery_progress_publish_locked() {
  local watermark=$1 transition previous previous_transition previous_watermark extra tab tmp status=0
  case "$watermark" in ''|*[!0-9]*) return 1 ;; esac
  transition=$(date +%s 2>/dev/null) || return 1
  case "$transition" in ''|*[!0-9]*) return 1 ;; esac
  previous=$(awk -F '\t' '
    NR == 1 && NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { value = $1 "\t" $2 }
    END { if (NR == 1) print value }
  ' "$WATCH_DELIVERY_PROGRESS" 2>/dev/null || true)
  tab=$(printf '\t')
  IFS="$tab" read -r previous_transition previous_watermark extra <<EOF
$previous
EOF
  case "$previous_transition" in
    ''|*[!0-9]*) ;;
    *)
      case "$previous_watermark" in
        ''|*[!0-9]*) ;;
        *)
          if [ -z "$extra" ]; then
            if [ "$previous_transition" -gt "$transition" ]; then
              transition=$previous_transition
            fi
          fi
          ;;
      esac
      ;;
  esac
  tmp=$(umask 077; mktemp "$STATE/.watch-delivery-progress.XXXXXX" 2>/dev/null) || status=1
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\n' "$transition" "$watermark" > "$tmp" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    mv -f -- "$tmp" "$WATCH_DELIVERY_PROGRESS" 2>/dev/null || status=1
  fi
  [ "$status" -eq 0 ] || rm -f -- "${tmp:-}" 2>/dev/null || true
  return "$status"
}

watch_delivery_publish() {
  local reason=$1 i size tmp raw
  [ -n "$FM_WATCH_DELIVERY_PID" ] || return 0
  [ -n "$FM_WATCH_DELIVERY_IDENTITY" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$WATCH_DELIVERY_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  printf '%s\t%s\t%s\n' \
    "$FM_WATCH_DELIVERY_PID" \
    "$(watch_delivery_clean_identity "$FM_WATCH_DELIVERY_IDENTITY")" \
    "$(watch_delivery_clean_reason "$reason")" >> "$WATCH_DELIVERY_LOG" 2>/dev/null || true
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

# Exit after reporting one actionable wake. Tests override this callback.
wake() {
  local output_status=0 progress_watermark
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  watch_delivery_serialization_acquire || {
    printf 'fm-watch: could not serialize actionable wake progress.\n' >&2
    exit 1
  }
  progress_watermark=$(watch_delivery_progress_watermark_locked)
  trap '' HUP INT TERM
  [ -z "$FM_WAKE_POST_OUTPUT_ACTION" ] || trap '' PIPE
  if fm_run_timed 2 bash -c "printf '%s' \"\$1\" && sleep 0.02 && printf '\\n'" _ "$1"; then
    if watch_delivery_progress_publish_locked "$progress_watermark"; then
      output_status=0
      # shellcheck disable=SC2034 # Read by bin/fm-watch.sh's EXIT cleanup.
      FM_WATCH_DELIVERED_REASON=$1
    else
      printf 'fm-watch: could not publish actionable wake progress.\n' >&2
      output_status=1
    fi
  else
    output_status=1
  fi
  if [ -n "$FM_WAKE_POST_OUTPUT_ACTION" ]; then
    "$FM_WAKE_POST_OUTPUT_ACTION" "$output_status" || true
  fi
  watch_delivery_serialization_release
  if [ "$output_status" -eq 0 ]; then
    watch_delivery_publish "$1" || true
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

# Act on a fresh actionable transition from a push-capable backend.
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  # A declared wait already names the human this transition would report: an
  # external dependency, or the captain a verified hold transferred the work to.
  # Either way the wait is durably recorded, so absorb the immediate escalation
  # and leave the bounded re-surface to the watcher's own pause cadence.
  if status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared wait, awaiting external or captain): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}
