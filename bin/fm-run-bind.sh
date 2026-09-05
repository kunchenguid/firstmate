#!/usr/bin/env bash
# Bind a no-mistakes pipeline run to the task that started it, by run id.
#
# Why this exists: bin/fm-crew-state.sh attributes a run by BRANCH plus code
# identity, and no-mistakes exposes nothing that names the worktree a run was
# invoked from - `axi status` is repo-scoped and answers the identical run from
# any worktree of that repo, the `runs` listing has no such column, and the
# private `runs.worktree_dir` record holds the pipeline's own internal checkout
# rather than the caller's (verified 2026-09-04 against two live worktrees of one
# branch on no-mistakes v1.57.0). So once a one-PR-per-repo posture puts several
# crews' worktrees on ONE long-lived feature branch, every one of them satisfies
# the branch-and-head rule for whichever run is current, and a crew that has
# exited reads as its neighbour's running pipeline.
#
# The run id is the one identifier that IS unambiguous, and only the crew that
# started the run knows which id is its own. So the crew records it here, right
# after `no-mistakes axi run` reports it, and attribution matches on that binding
# (bin/fm-crew-state.sh owns the matching rule and its legacy fallback).
#
# Writes exactly one key, `nm_run=<run-id>`, into state/<task-id>.meta. Re-binding
# replaces the previous value, so a restarted or superseded run is rebound rather
# than accumulating. The write takes the task's own metadata lock and lands
# through the atomic record publication owned by bin/fm-backlog-transition-lib.sh,
# so a concurrent supervisor read never observes a partial record. An unknown
# task, an unusable record, or a malformed run id is refused and nothing is
# changed.
#
# Usage: fm-run-bind.sh <task-id> <run-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  echo "usage: fm-run-bind.sh <task-id> <run-id>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
ID=$1
RUN_ID=$2

fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }

# no-mistakes run ids are ULIDs today (26 Crockford base32 characters). This
# accepts that shape plus any comparable opaque token a later CLI might emit,
# while refusing anything that could carry a path, a separator, or shell syntax
# into the task record: the value is written verbatim and read back by every
# supervisor.
case "$RUN_ID" in
  ''|*[!0-9A-Za-z_-]*) echo "error: invalid run id" >&2; exit 2 ;;
  -*|_*) echo "error: invalid run id" >&2; exit 2 ;;
esac
[ "${#RUN_ID}" -ge 8 ] && [ "${#RUN_ID}" -le 64 ] || { echo "error: invalid run id" >&2; exit 2; }

[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }
META="$STATE/$ID.meta"
META_LOCK=
META_LOCK_HELD=0
TMP=
run_bind_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  return "$status"
}
trap run_bind_cleanup EXIT

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
if ! fm_backlog_record_present "$META" "task record" "$STATE"; then
  echo "error: no task record for $ID ($FM_BACKLOG_TRANSITION_ERROR)" >&2
  exit 1
fi

PREVIOUS=$(grep '^nm_run=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
if [ "$PREVIOUS" = "$RUN_ID" ]; then
  echo "bound $ID to run $RUN_ID (unchanged)"
  exit 0
fi

TMP="$STATE/.$ID.meta.run-bind.${BASHPID:-$$}"
grep -v '^nm_run=' "$META" > "$TMP" || true
printf 'nm_run=%s\n' "$RUN_ID" >> "$TMP"
if ! fm_backlog_atomic_transition publish "$TMP" "$META" "task record" "$STATE"; then
  echo "error: task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
  exit 1
fi
TMP=
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

if [ -n "$PREVIOUS" ]; then
  echo "bound $ID to run $RUN_ID (replaced $PREVIOUS)"
else
  echo "bound $ID to run $RUN_ID"
fi
