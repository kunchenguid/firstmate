#!/usr/bin/env bash
# Usage: FM_HOME=<home> admit.sh launch|owned-operation
# Required environment: FM_HOME; standard input must be empty with FM_NATIVE_ACK_EVIDENCE_KIND unset, or nonempty with the discriminator set to token|legacy.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
mode=${1:-}
[ "$#" -eq 1 ] || { printf 'usage: admit.sh launch|owned-operation\n' >&2; exit 2; }
case "$mode" in launch|owned-operation) ;; *) printf 'usage: admit.sh launch|owned-operation\n' >&2; exit 2 ;; esac
native_evidence=$(cat)
case "${FM_NATIVE_ACK_EVIDENCE_KIND:-}" in
  '') [ -z "$native_evidence" ] || { printf 'unexpected native acknowledgement evidence\n' >&2; exit 2; } ;;
  token) [ -n "$native_evidence" ] || { printf 'native acknowledgement evidence is empty\n' >&2; exit 2; } ;;
  legacy)
    native_evidence=$(printf '%s' "$native_evidence" | bash "$ROOT/bin/native-owner/ack-evidence.sh" legacy-token) || {
      printf 'legacy native acknowledgement evidence is unrecognized\n' >&2
      exit 2
    }
    ;;
  *) printf 'native acknowledgement evidence kind is unrecognized\n' >&2; exit 2 ;;
esac
export FM_HOME
FM_HOME=$(cygpath -u "${FM_HOME:?}")
cd "$ROOT"
if [ "$mode" = launch ] && ! FM_STATE_OVERRIDE="$FM_HOME/state" bin/fm-lock.sh native-admission-predicate; then
  printf 'the home has a live or unresolved session owner\n' >&2
  exit 2
fi
. bin/fm-tasks-axi-lib.sh
. bin/fm-backlog-transition-lib.sh
. bin/fm-pr-lib.sh
. bin/fm-procevent-lib.sh
. bin/fm-terminal-outcome-lib.sh
. bin/fm-supervision-lib.sh
if ! fm_backlog_empty_fleet_preflight "$FM_HOME/state" "$FM_HOME/data"; then
  printf '%s\n' "${FM_BACKLOG_EMPTY_ERROR:-the home contains work-bearing records}" >&2
  exit 2
fi
if ! fm_supervision_residual_inputs_absent "$FM_HOME/state"; then
  printf '%s\n' "${FM_SUP_RESIDUAL_ERROR:-the home contains residual supervision work}" >&2
  exit 2
fi
if [ -e "$FM_HOME/state" ] || [ -L "$FM_HOME/state" ]; then
  export FM_STATE_OVERRIDE="$FM_HOME/state"
  . bin/fm-wake-lib.sh
  # Read the inbox, queue, and recovery marker from one publication boundary.
  if ! fm_lock_acquire_wait_bounded "$FM_WAKE_QUEUE_LOCK" 10; then
    printf 'native admission could not acquire the wake queue lock within its bound\n' >&2
    exit 2
  fi
  trap 'fm_lock_release "$FM_WAKE_QUEUE_LOCK"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! fm_wake_native_empty_fleet_preflight "$FM_HOME/state" "$native_evidence"; then
    printf '%s\n' "${FM_WAKE_NATIVE_ADMISSION_ERROR:-the home contains unsupported wake state}" >&2
    exit 2
  fi
fi
