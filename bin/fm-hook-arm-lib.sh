#!/usr/bin/env bash
# Shared hook-owned watcher arm primitive.
# Sourced by harness-specific hook adapters (cursor stop-hook, claude Stop
# auto-arm) so each harness pays only the translation cost, not the full
# decision tree.
#
# The single owner of: foreground arm lifecycle, actionable-wake
# classification, healthy-watcher verification, and interruption-marker
# naming. Harness adapters call these functions and translate the outcomes.
#
# Contract:
#   fm_hook_arm_foreground <state-dir> <arm-output-file-var>
#     Returns 0 with arm output in the named variable.
#     Caller must supply a writable temp file path.
#
#   fm_hook_arm_classify <arm-output>
#     Prints one line on stdout: actionable=<0|1> reason=<canonical-wake-or-empty>
#     An actionable close means a wake record is present.
#     A non-actionable close with a live identity-matched watcher whose beacon
#     is within grace is benign; without one it is a supervision failure.
#
#   fm_hook_arm_interrupted_park_reason <state-dir>
#     Prints a followup message on stdout when durable interrupt evidence exists,
#     empty string otherwise. Reads the hook-arm-interrupted marker and wake queue.
#
#   INTERRUPT_MARKER is the harness-neutral state/.hook-arm-interrupted path.
#   It is written by fm-watch-arm.sh signal traps and cleared by fm-wake-drain.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

HOOK_ARM_INTERRUPT_MARKER_SUFFIX=".hook-arm-interrupted"

fm_hook_arm_interrupt_marker() {  # <state-dir>
  printf '%s/%s' "${1%/}" "$HOOK_ARM_INTERRUPT_MARKER_SUFFIX"
}

# Foreground the watcher arm inside a hook-owned process tree. Never shell &:
# the harness owns the process group, so its timeout tears arm and watcher down
# together; a backgrounded child would exit leaving a stranded watcher and false
# "already running" on the next arm.
fm_hook_arm_foreground() {  # <state-dir> <arm-output-file> -> 0, output in file
  local state_dir=$1 out_file=$2
  STATE="$state_dir" "$SCRIPT_DIR/fm-watch-arm.sh" >"$out_file" 2>&1 || true
}

fm_hook_arm_has_actionable() {  # <arm-output>
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$1" 2>/dev/null
}

fm_hook_arm_wake_reason() {  # <arm-output> -> canonical reason line or empty
  grep -Em1 '^(signal:|stale:|check:|heartbeat($|:))' "$1" 2>/dev/null || true
}

fm_hook_arm_interrupted_park_reason() {  # <state-dir>
  local state_dir=$1 marker queue_file msg
  marker=$(fm_hook_arm_interrupt_marker "$state_dir")
  queue_file="${FM_WAKE_QUEUE:-$state_dir/.wake-queue}"
  msg=
  if [ -f "$marker" ]; then
    msg='Hook-owned supervision was interrupted while parked; the durable wake queue may hold undelivered events.'
  fi
  if [ -s "$queue_file" ]; then
    msg="$msg Undelivered watcher wake records are queued."
  fi
  if [ -z "$msg" ]; then
    return 1
  fi
  printf '%s Run bin/fm-wake-drain.sh and reconcile before ending blind.' "$msg"
}

# Canonicalize a wake reason line so repeated same-reason firings are
# deduplicated and counted, while a genuinely new reason resets the counter.
fm_hook_arm_canonical_reason() {  # <raw-reason>
  local reason=$1 check_reason
  case "$reason" in
    stale:*) reason=${reason%% (*} ;;
    check:*)
      check_reason=${reason#check: }
      case "$check_reason" in
        procevent\ *\ *\ *) check_reason=${check_reason% *} ;;
        *': '*) check_reason=${check_reason%%: *} ;;
      esac
      reason="check: $check_reason"
      ;;
    heartbeat:*) reason=heartbeat ;;
  esac
  printf '%s' "$reason"
}
