#!/usr/bin/env bash
# fm-codex-queue-wake.sh - Codex-native doorbell for durable Firstmate wakes.
#
# A successful `deliver` means only that the fixed drain prompt was accepted or
# an equivalent delivery is already outstanding. It never consumes wake rows.
# Only fm-wake-drain.sh's generation-bound post-handling acknowledgement does
# that. The outstanding v1 record is private, strict, and keyed by the validated
# primary binding plus the recovery generation and queue boundary.
#
# Usage:
#   fm-codex-queue-wake.sh capability
#   fm-codex-queue-wake.sh deliver
#   fm-codex-queue-wake.sh acknowledge <ack-through> <thread-uuid>
#     <session-generation> <recovery-generation>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
OUTSTANDING="$STATE/.codex-queue-outstanding"
FALLBACK_OUTSTANDING="$STATE/.codex-present-fallback-outstanding"
DIAGNOSTIC="$STATE/.codex-queue-diagnostic"
QUEUE_TIMEOUT=${FM_CODEX_QUEUE_TIMEOUT:-10}
DIAGNOSTIC_INTERVAL=${FM_CODEX_QUEUE_DIAGNOSTIC_INTERVAL:-300}
SETTLE_INTERVAL=${FM_CODEX_QUEUE_SETTLE_INTERVAL:-0.05}
SETTLE_SAMPLES=${FM_CODEX_QUEUE_SETTLE_SAMPLES:-5}
SETTLE_ATTEMPTS=${FM_CODEX_QUEUE_SETTLE_ATTEMPTS:-200}
CODEX_SESSIONS_ROOT=${FM_CODEX_SESSIONS_ROOT:-${CODEX_HOME:-${HOME:?}/.codex}/sessions}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-codex-primary.sh
. "$SCRIPT_DIR/fm-codex-primary.sh"

case "$QUEUE_TIMEOUT" in ''|*[!0-9]*|0) QUEUE_TIMEOUT=10 ;; esac
case "$DIAGNOSTIC_INTERVAL" in ''|*[!0-9]*) DIAGNOSTIC_INTERVAL=300 ;; esac
case "$SETTLE_INTERVAL" in ''|*[!0-9.]*|*.*.*) SETTLE_INTERVAL=0.05 ;; esac
case "$SETTLE_SAMPLES" in ''|*[!0-9]*|0) SETTLE_SAMPLES=5 ;; esac
case "$SETTLE_ATTEMPTS" in ''|*[!0-9]*|0) SETTLE_ATTEMPTS=200 ;; esac

fm_codex_queue_diagnostic() { # <code> <message>
  local code=$1 message=$2 now old_time old_code tmp
  now=$(date +%s)
  old_time=$(sed -n '1s/^epoch=//p' "$DIAGNOSTIC" 2>/dev/null || true)
  old_code=$(sed -n '2s/^code=//p' "$DIAGNOSTIC" 2>/dev/null || true)
  case "$old_time" in ''|*[!0-9]*) old_time=0 ;; esac
  if [ "$code" != "$old_code" ] || [ $((now - old_time)) -ge "$DIAGNOSTIC_INTERVAL" ]; then
    tmp=$(mktemp "$STATE/.codex-queue-diagnostic.XXXXXX") || return 0
    if printf 'epoch=%s\ncode=%s\n' "$now" "$code" > "$tmp" && chmod 0600 "$tmp" \
      && _fm_atomic_replace "$tmp" "$DIAGNOSTIC"; then
      printf 'fm-codex-queue-wake: %s\n' "$message" >&2
    else
      rm -f -- "$tmp"
    fi
  fi
}

fm_codex_queue_boundary_locked() {
  local highest generation
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  highest=$(awk -F '\t' 'NF >= 5 && $2 ~ /^[0-9]+$/ && $2 > max { max=$2 } END { print max+0 }' \
    "$FM_WAKE_QUEUE" 2>/dev/null) || highest=0
  generation=$(sed -n 's/^\(pending\|announced\):\(handling\|downtime\):\([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\3/p' \
    "$STATE/.watcher-down" 2>/dev/null | tail -1)
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  [ -n "$generation" ] || return 1
  FM_CODEX_QUEUE_HIGHEST=$highest
  FM_CODEX_QUEUE_RECOVERY=$generation
}

fm_codex_queue_outstanding_matches_locked() { # <thread> <binding-generation> <recovery-generation>
  local thread=$1 binding_generation=$2 recovery_generation=$3 stored_thread stored_binding stored_recovery status
  fm_codex_record_shape_valid "$OUTSTANDING" fm-codex-queue-outstanding-v1 5 || return 1
  stored_thread=$(fm_codex_record_field "$OUTSTANDING" thread_uuid) || return 1
  stored_binding=$(fm_codex_record_field "$OUTSTANDING" session_generation) || return 1
  stored_recovery=$(fm_codex_record_field "$OUTSTANDING" recovery_generation) || return 1
  status=$(fm_codex_record_field "$OUTSTANDING" status) || return 1
  case "$status" in submitting|accepted|ambiguous) ;; *) return 1 ;; esac
  [ "$stored_thread" = "$thread" ] && [ "$stored_binding" = "$binding_generation" ] \
    && [ "$stored_recovery" = "$recovery_generation" ] \
    || return 1
  FM_CODEX_QUEUE_OUTSTANDING_STATUS=$status
}

fm_codex_queue_write_outstanding_locked() { # <thread> <binding-gen> <recovery-gen> <highest> <status>
  {
    printf 'fm-codex-queue-outstanding-v1\n'
    printf 'thread_uuid=%s\n' "$1"
    printf 'session_generation=%s\n' "$2"
    printf 'recovery_generation=%s\n' "$3"
    printf 'wake_sequence=%s\n' "$4"
    printf 'status=%s\n' "$5"
  } | fm_codex_atomic_write "$OUTSTANDING"
}

fm_codex_queue_command() {
  if [ -n "${FM_CODEX_QUEUE_BIN:-}" ]; then
    [ -x "$FM_CODEX_QUEUE_BIN" ] || return 1
    printf '%s\n' "$FM_CODEX_QUEUE_BIN"
    return 0
  fi
  command -v codex 2>/dev/null
}

fm_codex_queue_capable() {
  local codex_bin help_tmp status=0
  codex_bin=$(fm_codex_queue_command) || return 1
  help_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-codex-queue-help.XXXXXX") || return 1
  fm_run_timed "$QUEUE_TIMEOUT" "$codex_bin" queue --help > "$help_tmp" 2>&1 || status=$?
  if [ "$status" -ne 0 ] \
    || ! grep -F -- '--thread' "$help_tmp" >/dev/null \
    || ! grep -F -- '--message' "$help_tmp" >/dev/null; then
    rm -f -- "$help_tmp"
    return 1
  fi
  rm -f -- "$help_tmp"
}

fm_codex_queue_session_file() { # <thread>
  local thread=$1 candidate count=0 match=
  [ -d "$CODEX_SESSIONS_ROOT" ] && [ ! -L "$CODEX_SESSIONS_ROOT" ] || return 1
  while IFS= read -r candidate; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    if sed -n '1p' "$candidate" 2>/dev/null | jq -e --arg thread "$thread" \
      '.type == "session_meta" and ((.payload.id // .payload.session_id) == $thread)' \
      >/dev/null 2>&1; then
      count=$((count + 1))
      match=$candidate
    fi
  done < <(find "$CODEX_SESSIONS_ROOT" -type f -name "*-${thread}.jsonl" -print 2>/dev/null)
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$match"
}

fm_codex_queue_terminal_snapshot() { # <session-file> <thread>
  local session_file=$1 thread=$2 before after parsed meta=0
  local event='' turn='' latest_start='' last_event='' last_turn='' invalid=false
  before=$(wc -c < "$session_file" 2>/dev/null | tr -d '[:space:]') || return 1
  case "$before" in ''|*[!0-9]*) return 1 ;; esac
  parsed=$(mktemp "$STATE/.codex-queue-lifecycle.XXXXXX") || return 1
  if ! jq -r --arg thread "$thread" '
      if .type == "session_meta" and ((.payload.id // .payload.session_id) == $thread) then
        ["meta", $thread] | @tsv
      elif .type == "event_msg" and (.payload.type == "task_started" or .payload.type == "task_complete") then
        [.payload.type, (.payload.turn_id // "")] | @tsv
      else empty end
    ' "$session_file" > "$parsed" 2>/dev/null; then
    rm -f -- "$parsed"
    return 1
  fi
  after=$(wc -c < "$session_file" 2>/dev/null | tr -d '[:space:]') || { rm -f -- "$parsed"; return 1; }
  [ "$before" = "$after" ] || { rm -f -- "$parsed"; return 1; }
  while IFS=$'\t' read -r event turn; do
    case "$event" in
      meta) meta=$((meta + 1)) ;;
      task_started) latest_start=$turn; last_event=$event; last_turn=$turn ;;
      task_complete)
        if [ -z "$latest_start" ] || [ "$turn" != "$latest_start" ]; then
          invalid=true
          break
        fi
        latest_start=
        last_event=$event
        last_turn=$turn
        ;;
    esac
  done < "$parsed"
  rm -f -- "$parsed"
  [ "$invalid" = false ] && [ "$meta" -eq 1 ] && [ "$last_event" = task_complete ] \
    && [ -z "$latest_start" ] && [ -n "$last_turn" ] || return 1
  printf '%s\t%s\n' "$after" "$last_turn"
}

fm_codex_queue_wait_settled() { # <thread>
  local thread=$1 session_file size stable=0 attempt=0
  local snapshot='' previous_size='' checked_size=''
  command -v jq >/dev/null 2>&1 || return 1
  session_file=$(fm_codex_queue_session_file "$thread") || return 1
  while [ "$attempt" -lt "$SETTLE_ATTEMPTS" ]; do
    size=$(wc -c < "$session_file" 2>/dev/null | tr -d '[:space:]') || return 1
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$size" = "$previous_size" ]; then
      stable=$((stable + 1))
    else
      previous_size=$size
      stable=0
    fi
    if [ "$stable" -ge "$SETTLE_SAMPLES" ] && [ "$checked_size" != "$size" ]; then
      snapshot=$(fm_codex_queue_terminal_snapshot "$session_file" "$thread" 2>/dev/null || true)
      checked_size=$size
      case "$snapshot" in
        "$size"$'\t'*) return 0 ;;
      esac
    fi
    attempt=$((attempt + 1))
    sleep "$SETTLE_INTERVAL"
  done
  return 1
}

fm_codex_queue_deliver() {
  local codex_bin call_tmp thread binding_generation prompt status=0
  mkdir -p "$STATE" || return 1
  fm_lock_acquire_wait "$FM_CODEX_PRIMARY_LOCK" || return 1
  if ! fm_codex_validate_locked; then
    fm_codex_queue_diagnostic invalid-binding 'native queue unavailable: the Codex primary binding is missing, stale, or invalid; preserving wakes for terminal/checkpoint fallback'
    fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
    return 1
  fi
  thread=$FM_CODEX_VALID_THREAD
  binding_generation=$FM_CODEX_VALID_GENERATION
  if ! fm_codex_queue_boundary_locked; then
    fm_codex_queue_diagnostic invalid-boundary 'native queue unavailable: no valid durable recovery generation is published; preserving wakes for terminal/checkpoint fallback'
    fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
    return 1
  fi
  if fm_codex_queue_outstanding_matches_locked "$thread" "$binding_generation" "$FM_CODEX_QUEUE_RECOVERY"; then
    if [ "$FM_CODEX_QUEUE_OUTSTANDING_STATUS" = submitting ]; then
      fm_codex_queue_diagnostic interrupted \
        'native queue submission was interrupted with acceptance unknown; suppressing duplicate native submission and preserving wakes for terminal/checkpoint fallback'
      fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
      return 1
    fi
    fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
    printf 'coalesced\n'
    return 0
  fi
  codex_bin=$(fm_codex_queue_command) || {
    fm_codex_queue_diagnostic missing-command 'native queue unavailable: codex command is missing; preserving wakes for terminal/checkpoint fallback'
    fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
    return 1
  }
  if ! fm_codex_queue_capable; then
    fm_codex_queue_diagnostic unsupported 'native queue unavailable: installed codex does not expose the required queue --thread/--message capability; preserving wakes for terminal/checkpoint fallback'
    fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
    return 1
  fi
  if ! fm_codex_queue_wait_settled "$thread"; then
    fm_codex_queue_diagnostic unsettled-session 'native queue deferred: the exact Codex thread has not reached an observable stable post-completion boundary; preserving wakes for a later retry or safe fallback'
    fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
    return 1
  fi
  fm_operational_input_encode watcher \
    'Drain durable wakes with bin/fm-wake-drain.sh, handle every presented item, run the printed post-handling acknowledgement, and preserve watcher continuity per the emitted supervision protocol. Then give the captain a project-facing outcome, re-anchor to the preceding captain conversation, and resume or explicitly close any captain goal that remained active before this operational message; do not end on internal Watcher mechanics alone.' \
    prompt || { fm_lock_release "$FM_CODEX_PRIMARY_LOCK"; return 1; }
  fm_codex_queue_write_outstanding_locked "$thread" "$binding_generation" \
    "$FM_CODEX_QUEUE_RECOVERY" "$FM_CODEX_QUEUE_HIGHEST" submitting \
    || { fm_lock_release "$FM_CODEX_PRIMARY_LOCK"; return 1; }
  call_tmp=$(mktemp "$STATE/.codex-queue-call.XXXXXX") || { fm_lock_release "$FM_CODEX_PRIMARY_LOCK"; return 1; }
  fm_run_timed "$QUEUE_TIMEOUT" "$codex_bin" queue --thread "$thread" --message "$prompt" > "$call_tmp" 2>&1
  status=$?
  case "$status" in
    0)
      fm_codex_queue_write_outstanding_locked "$thread" "$binding_generation" \
        "$FM_CODEX_QUEUE_RECOVERY" "$FM_CODEX_QUEUE_HIGHEST" accepted || status=1
      ;;
    124|137)
      fm_codex_queue_write_outstanding_locked "$thread" "$binding_generation" \
        "$FM_CODEX_QUEUE_RECOVERY" "$FM_CODEX_QUEUE_HIGHEST" ambiguous || true
      fm_codex_queue_diagnostic timeout 'native queue timed out and acceptance is ambiguous; suppressing duplicate native submission and preserving wakes for terminal/checkpoint fallback'
      ;;
    *)
      rm -f -- "$OUTSTANDING"
      fm_codex_queue_diagnostic rejected "native queue rejected the doorbell (exit $status); preserving wakes for terminal/checkpoint fallback"
      ;;
  esac
  rm -f -- "$call_tmp"
  fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
  [ "$status" -eq 0 ] || return 1
  printf 'accepted\n'
}

fm_codex_queue_acknowledge() { # <ack-through> <thread> <session-generation> <recovery-generation>
  local ack_through=$1 thread=$2 session_gen=$3 generation=$4
  local stored stored_thread stored_session stored_sequence record record_header field_count
  case "$ack_through" in *[!0-9]*|'') return 2 ;; esac
  fm_codex_uuid_valid "$thread" || return 2
  case "$session_gen" in *[!A-Za-z0-9._-]*|'') return 2 ;; esac
  case "$generation" in *[!A-Za-z0-9._-]*|'') return 2 ;; esac
  mkdir -p "$STATE" || return 1
  fm_lock_acquire_wait "$FM_CODEX_PRIMARY_LOCK" || return 1
  if ! fm_codex_validate_locked \
    || [ "$FM_CODEX_VALID_THREAD" != "$thread" ] \
    || [ "$FM_CODEX_VALID_GENERATION" != "$session_gen" ]; then
    fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
    return 1
  fi
  for record in "$OUTSTANDING" "$FALLBACK_OUTSTANDING"; do
    if [ -f "$record" ] && [ ! -L "$record" ]; then
      case "$record" in
        *".codex-queue-outstanding") record_header=fm-codex-queue-outstanding-v1 field_count=5 ;;
        *) record_header=fm-codex-present-fallback-v1 field_count=4 ;;
      esac
      stored=$(fm_codex_record_field "$record" recovery_generation 2>/dev/null || true)
      stored_thread=$(fm_codex_record_field "$record" thread_uuid 2>/dev/null || true)
      stored_session=$(fm_codex_record_field "$record" session_generation 2>/dev/null || true)
      if [ "$stored" = "$generation" ] \
        && [ "$stored_thread" = "$thread" ] \
        && [ "$stored_session" = "$session_gen" ] \
        && fm_codex_record_shape_valid "$record" "$record_header" "$field_count"; then
        if [ "$record" = "$OUTSTANDING" ]; then
          stored_sequence=$(fm_codex_record_field "$record" wake_sequence 2>/dev/null || true)
          case "$stored_sequence" in *[!0-9]*|'') continue ;; esac
          [ "$stored_sequence" -le "$ack_through" ] || continue
        fi
        if ! rm -f -- "$record"; then
          fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
          return 1
        fi
      fi
    fi
  done
  fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
}

case "${1:-}" in
  capability) fm_codex_queue_capable ;;
  deliver) fm_codex_queue_deliver ;;
  acknowledge)
    [ "$#" -eq 5 ] || exit 2
    fm_codex_queue_acknowledge "$2" "$3" "$4" "$5"
    ;;
  *) printf 'usage: fm-codex-queue-wake.sh capability|deliver|acknowledge ACK_THROUGH THREAD_UUID SESSION_GENERATION RECOVERY_GENERATION\n' >&2; exit 2 ;;
esac
