#!/usr/bin/env bash
# Sourced by the Firstmate watcher once, just before its main loop. The lead-wake
# policy: a secondmate home sitting below its lane floor (or with no worker
# provably working) while fm-tasks-axi.sh ready has dispatchable work raises one
# `check: ready work waiting ...` wake, re-raised every FM_READY_WORK_RESURFACE_SECS;
# an emptied ready set withdraws the queued row; a stalled lead's drain ring names
# the frozen row and its acknowledgement. The caller supplies the watcher's own
# STATE, SCRIPT_DIR, HEARTBEAT, age_of, triage_log, wake, fm_wake_append,
# crew_is_provably_working, the wake-lib lock helpers and the ring's inbox and
# backend helpers; only the drain-ring body repeats Kun's, around the fork's text.
# Public names match the fork's, so the current fork keeps working with this loaded.

READY_WORK_RESURFACE_SECS=${FM_READY_WORK_RESURFACE_SECS:-1800}
case "$READY_WORK_RESURFACE_SECS" in ''|*[!0-9]*|0) READY_WORK_RESURFACE_SECS=1800 ;; esac

# Remove every queued row for exactly <kind>/<key> under the append lock; idempotent,
# a no-op without a match. Stale scratch is swept under the same lock.
fm_wake_withdraw() {  # <kind> <key>
  local kind=$1 key=$2 clean_key status=0 tmp
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_withdraw: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac
  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  rm -f -- "$STATE"/.wake-queue.withdraw.* 2>/dev/null || true
  if [ -f "$FM_WAKE_QUEUE" ] && awk -F '\t' -v kind="$kind" -v key="$clean_key" \
    'NF >= 5 && $3 == kind && $4 == key { found = 1 } END { exit(found ? 0 : 1) }' "$FM_WAKE_QUEUE"; then
    if tmp=$(mktemp "$STATE/.wake-queue.withdraw.XXXXXX") && chmod 0600 "$tmp"; then
      if awk -F '\t' -v kind="$kind" -v key="$clean_key" \
        '!(NF >= 5 && $3 == kind && $4 == key) { print }' "$FM_WAKE_QUEUE" > "$tmp" \
        && _fm_atomic_replace "$tmp" "$FM_WAKE_QUEUE"; then
        tmp=
      else
        status=1
      fi
    else
      status=1
    fi
    [ -z "$tmp" ] || rm -f -- "$tmp"
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

# config/lane-target: one positive integer; returns 0 and prints it only for that.
lane_target_value() {
  local path=$FM_HOME/config/lane-target raw
  [ -f "$path" ] && [ ! -L "$path" ] && raw=$(awk 'NF { print }' "$path" 2>/dev/null) || return 1
  case "$raw" in ''|*"$'\n'"*) return 1 ;; esac
  case "$raw" in *[!0-9]*) return 1 ;; esac
  [ "$raw" -gt 0 ] || return 1
  printf '%s\n' "$raw"
}

# Open lanes: ship (default) or scout metas; the fleet-flow check's `counted` column
# wins when present, else the meta count.
open_lane_count() {
  local check counted meta kind count=0
  check=${XDG_DATA_HOME:-$HOME/.local/share}/fm-fleet-flow/fm-flow-check.sh
  if [ -f "$check" ] && [ -x "$check" ] \
    && counted=$(fm_run_timed "${FM_FLOW_CHECK_TIMEOUT_SECS:-10}" "$check" "$FM_HOME" --summary 2>/dev/null); then
    counted=$(printf '%s\n' "$counted" | awk -F '\t' 'NF == 9 && NR == 1 { print $8 }')
    case "$counted" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "$counted"; return 0 ;;
    esac
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(grep '^kind=' "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true)
    case "${kind:-ship}" in
      ship|scout) count=$((count + 1)) ;;
    esac
  done
  printf '%s\n' "$count"
}

warn_invalid_lane_target_once() {
  local marker=$STATE/.ready-work-lane-target-invalid current
  current=$(cat "$FM_HOME/config/lane-target" 2>/dev/null) || current=unreadable
  [ "$(cat "$marker" 2>/dev/null)" = "$current" ] && return 0
  printf '%s' "$current" > "$marker" 2>/dev/null || true
  triage_log "lane-target is not a positive integer; using the no-worker-working rule instead"
}

# 0 when this secondmate home has ready work and sits below its lane floor (or, without
# a usable target or at it, no worker is provably working). Sets READY_WORK_IDS/REASON.
# A still-holding set re-raises after READY_WORK_RESURFACE_SECS, a new set at once; an
# empty set on a good read withdraws the queued row but keeps the resurface record.
ready_work_waits_idle() {
  local meta task target open now surfaced surfaced_at surfaced_ids ready_out ready_rc
  READY_WORK_IDS=
  READY_WORK_REASON=
  [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] || return 1
  ready_out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" ready 2>/dev/null)
  ready_rc=$?
  READY_WORK_IDS=$(printf '%s\n' "$ready_out" \
    | awk '/^ready\[[0-9]+\]/ { on = 1; next } on && /^  / { sub(/^  /, ""); split($0, f, ","); print f[1]; next } { on = 0 }' \
    | sort | paste -sd ' ' -)
  if [ -z "$READY_WORK_IDS" ]; then
    [ "$ready_rc" -eq 0 ] || return 1
    fm_wake_withdraw check ready-work || true
    return 1
  fi
  target=$(lane_target_value) || target=
  if [ -z "$target" ] && [ -f "$FM_HOME/config/lane-target" ]; then
    warn_invalid_lane_target_once
  fi
  if [ -n "$target" ] && open=$(open_lane_count) && [ "$open" -lt "$target" ]; then
    READY_WORK_REASON="check: ready work waiting with free lane slots ($open/$target open): $READY_WORK_IDS - start the top ready item now, or record why it waits"
  else
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      task=${meta##*/}
      crew_is_provably_working "${task%.meta}" && return 1
    done
    READY_WORK_REASON="check: ready work waiting with no worker working: $READY_WORK_IDS - start each or record why it waits"
  fi
  fm_epoch_seconds_to now
  surfaced=$(cat "$STATE/.ready-work-surfaced" 2>/dev/null) || surfaced=
  case "$surfaced" in
    *$'\t'*) surfaced_at=${surfaced%%$'\t'*}; surfaced_ids=${surfaced#*$'\t'} ;;
    *) surfaced_at=0; surfaced_ids=$surfaced ;;
  esac
  [ "$surfaced_ids" != "$READY_WORK_IDS" ] && return 0
  case "$surfaced_at" in ''|*[!0-9]*) surfaced_at=0 ;; esac
  [ "$(( now - surfaced_at ))" -ge "$READY_WORK_RESURFACE_SECS" ]
}

record_ready_work_surfaced() {
  local now; fm_epoch_seconds_to now
  printf '%s\t%s\n' "$now" "$READY_WORK_IDS" > "$STATE/.ready-work-surfaced"
}

# The stalled-lead drain ring, redefined over Kun's because this file loads after it:
# the steer names the frozen row and its acknowledgement, since a mate told only to
# drain presented the row, cut WAKE_ACK_REQUIRED off its output and left it queued.
# Kun's call passes <task> <window>; the row is then the oldest actionable one in the
# mate's home queue, the one the stall tick read. A queue already drained needs no ring.
secondmate_ring_to_drain() {  # <task> <window> [<seq>]
  local task=$1 w=$2 seq=${3:-} rec backend delivery_id home
  if [ -z "$seq" ]; then
    home=$(fm_meta_get "$STATE/$task.meta" home)
    seq=$(secondmate_oldest_queue_row "$home/state/.wake-queue" | cut -f2)
    [ -n "$seq" ] || return 0
  fi
  backend=$(window_backend "$w")
  delivery_id=$(LC_ALL=C od -An -v -tx1 -N 8 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  case "$delivery_id" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#delivery_id}" -eq 16 ] || return 1
  rec=$(fm_task_inbox_write "$STATE" "$task" \
    "${FM_FROMFIRST_MARK}delivery=${delivery_id} Wake row $seq is still queued in this home. Run bin/fm-wake-drain.sh and read its whole output, handle what it presents, then run the exact WAKE_ACK_REQUIRED command it prints, which is what removes the row. Then resume idle supervision." \
    fire-and-forget) || return 1
  fm_task_inbox_ring "$backend" "$w" "$rec" "$(window_label "$w")"
}

# The watcher's single call, once per base HEARTBEAT (no idle backoff).
lead_wake_tick() {
  [ "$(age_of "$STATE/.last-ready-work-check")" -ge "$HEARTBEAT" ] || return 0
  touch "$STATE/.last-ready-work-check"
  ready_work_waits_idle || return 0
  fm_wake_append check ready-work "$READY_WORK_REASON" || exit 1
  record_ready_work_surfaced
  wake "$READY_WORK_REASON"
}
