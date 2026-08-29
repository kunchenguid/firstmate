#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, write the ship
# completion report, then report done according to the project's delivery mode).
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
LIFECYCLE_LOCK=
META_LOCK=
release_locks() {
  [ -z "$META_LOCK" ] || fm_account_meta_lock_release "$META_LOCK" >/dev/null 2>&1 || true
  [ -z "$LIFECYCLE_LOCK" ] || fm_account_lifecycle_lock_release "$LIFECYCLE_LOCK" >/dev/null 2>&1 || true
}
trap release_locks EXIT
LIFECYCLE_LOCK=$(fm_account_lifecycle_lock_acquire "$STATE" "$ID") || exit 1
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
fm_account_safe_file_destination "$META" || { echo "error: unsafe meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }
[ "$(fm_account_meta_value "$META" account_rollback_cleanup)" != pending ] \
  || { echo "error: rollback cleanup is pending for $ID; refusing promotion" >&2; exit 1; }

TMP=$(mktemp "$STATE/.$ID.meta.promote.XXXXXX") || exit 1
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
fm_account_safe_file_destination "$META" || { rm -f "$TMP"; exit 1; }
mv "$TMP" "$META"
fm_account_meta_lock_release "$META_LOCK" || exit 1
META_LOCK=
fm_account_lifecycle_lock_release "$LIFECYCLE_LOCK" || exit 1
LIFECYCLE_LOCK=
trap - EXIT

MESSAGE="<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; write $DATA/$ID/completion.md with sections Summary, What changed, Verification, Visual evidence, Artifacts, and Follow-ups; report done>"
MESSAGE_Q=$(printf '%s' "$MESSAGE" | sed "s/'/'\\\\''/g")
echo "promoted $ID to ship (teardown protection restored)"
printf "next: FM_HOME=%q bin/fm-send.sh fm-%s '%s'\n" "$FM_HOME" "$ID" "$MESSAGE_Q"
