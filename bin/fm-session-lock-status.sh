#!/usr/bin/env bash
# Print whether the current process descends from the verified harness process
# that owns this Firstmate home's session lock.
#
# Output is exactly one of owned, missing, or other.  This is the executable
# bridge from Pi extensions to fm-session-lock-lib.sh, which remains the sole
# owner of verified harness ancestry.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-session-lock-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if fm_session_lock_owned_by_self "$STATE"; then
  printf 'owned\n'
  exit 0
fi

lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
case "$lock_pid" in
  ''|*[!0-9]*)
    printf 'missing\n'
    ;;
  *)
    if fm_harness_pid_alive "$lock_pid"; then
      printf 'other\n'
    else
      printf 'missing\n'
    fi
    ;;
esac
exit 1
