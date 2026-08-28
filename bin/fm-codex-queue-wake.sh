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
#   fm-codex-queue-wake.sh acknowledge <recovery-generation>
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
  fm_operational_input_encode watcher \
    'Drain durable wakes with bin/fm-wake-drain.sh, handle every presented item, run the printed post-handling acknowledgement, and preserve watcher continuity per the emitted supervision protocol.' \
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

fm_codex_queue_acknowledge() { # <recovery-generation> [<session-generation>]
  local generation=$1 session_gen=${2:-} stored stored_session record record_header field_count
  case "$generation" in *[!A-Za-z0-9._-]*|'') return 2 ;; esac
  case "$session_gen" in *[!A-Za-z0-9._-]*) return 2 ;; esac
  mkdir -p "$STATE" || return 1
  fm_lock_acquire_wait "$FM_CODEX_PRIMARY_LOCK" || return 1
  if [ -z "$session_gen" ] && fm_codex_record_shape_valid "$FM_CODEX_PRIMARY_BINDING" fm-codex-primary-binding-v1 6; then
    session_gen=$(fm_codex_record_field "$FM_CODEX_PRIMARY_BINDING" session_generation 2>/dev/null || true)
  fi
  for record in "$OUTSTANDING" "$FALLBACK_OUTSTANDING"; do
    if [ -f "$record" ] && [ ! -L "$record" ]; then
      case "$record" in
        *".codex-queue-outstanding") record_header=fm-codex-queue-outstanding-v1 field_count=5 ;;
        *) record_header=fm-codex-present-fallback-v1 field_count=4 ;;
      esac
      stored=$(fm_codex_record_field "$record" recovery_generation 2>/dev/null || true)
      stored_session=$(fm_codex_record_field "$record" session_generation 2>/dev/null || true)
      if [ "$stored" = "$generation" ] \
        && { [ -z "$session_gen" ] || [ "$stored_session" = "$session_gen" ]; } \
        && fm_codex_record_shape_valid "$record" "$record_header" "$field_count"; then
        rm -f -- "$record"
      fi
    fi
  done
  fm_lock_release "$FM_CODEX_PRIMARY_LOCK"
}

case "${1:-}" in
  capability) fm_codex_queue_capable ;;
  deliver) fm_codex_queue_deliver ;;
  acknowledge)
    case "$#" in 2|3) ;; *) exit 2 ;; esac
    fm_codex_queue_acknowledge "$2" "${3:-}"
    ;;
  *) printf 'usage: fm-codex-queue-wake.sh capability|deliver|acknowledge RECOVERY_GENERATION [SESSION_GENERATION]\n' >&2; exit 2 ;;
esac
