#!/usr/bin/env bash
# fm-heavy-suite.sh - serialize one machine's heavy frontend and browser suites.
# Usage: fm-heavy-suite.sh -- <suite command> [args...]
#
# The portable advisory lock is shared by worktrees through the process TMPDIR,
# which is stable for terminals owned by one local user. A contender waits,
# reports that wait as intentional serialization, and runs after the holder exits.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "${1:-}" != -- ] || [ "$#" -lt 2 ]; then
  echo "usage: fm-heavy-suite.sh -- <suite command> [args...]" >&2
  exit 2
fi
shift

LOCK="${TMPDIR:-/tmp}/firstmate-heavy-frontend-suite-$(id -u).lock"
LOCK_HELD=0

release_lock() {
  [ "$LOCK_HELD" -eq 0 ] || fm_lock_release "$LOCK"
}
trap release_lock EXIT

if fm_lock_try_acquire "$LOCK"; then
  LOCK_HELD=1
else
  echo "heavy-suite: another heavy frontend suite is running; waiting for it to finish (this is not a test failure)" >&2
  fm_lock_acquire_wait "$LOCK"
  LOCK_HELD=1
  echo "heavy-suite: lock acquired; starting the waiting suite" >&2
fi

"$@"
