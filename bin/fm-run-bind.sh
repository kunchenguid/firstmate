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
# so a concurrent supervisor read never observes a partial record, and the
# republished record keeps the mode it already had rather than the ambient
# umask. An unknown task, an unreadable record, a record that would be reduced
# to its binding line alone, or a malformed run id is refused and nothing is
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

# Read the record ONCE, keeping every line that is not a binding. A read loop
# rather than `grep -v`, and an unreadable record is an error rather than an
# empty result: a swallowed read failure would stage a file holding nothing but
# the binding line, and publishing that would leave every supervisor reading
# worktree=, kind= and spawn_gen= as empty for a live task. The same shape
# bin/fm-pr-check.sh already uses for its own single-key rewrite.
KEPT=()
PREVIOUS=''
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    nm_run=*) PREVIOUS=${line#nm_run=} ;;
    *) KEPT+=("$line") ;;
  esac
done < "$META" || { echo "error: task record for $ID could not be read: $META" >&2; exit 1; }

if [ "$PREVIOUS" = "$RUN_ID" ]; then
  echo "bound $ID to run $RUN_ID (unchanged)"
  exit 0
fi

if [ "${#KEPT[@]}" -eq 0 ]; then
  echo "error: task record for $ID carries no keys besides its run binding; refusing to publish a record that would lose its identity" >&2
  exit 1
fi

# The staged file inherits the RECORD's mode rather than the ambient umask, so a
# bind after bin/fm-pr-check.sh has hardened the same record to 0600 cannot
# widen it back (bin/fm-captain-hold.sh's binding writer chmods its staged file
# for the same reason).
META_MODE=$(fm_pr_file_mode "$META" || true)
case "$META_MODE" in ''|*[!0-7]*) META_MODE=600 ;; esac
TMP="$STATE/.$ID.meta.run-bind.${BASHPID:-$$}"
stage_failed() {
  echo "error: task record for $ID could not be staged at $TMP; nothing was changed" >&2
  exit 1
}
: > "$TMP" || stage_failed
for line in "${KEPT[@]}"; do
  printf '%s\n' "$line" >> "$TMP" || stage_failed
done
printf 'nm_run=%s\n' "$RUN_ID" >> "$TMP" || stage_failed
chmod "$META_MODE" "$TMP" || stage_failed
# Every kept line plus exactly one binding line, or the rewrite lost content on
# the way to disk and the original record is left untouched.
STAGED_LINES=$(wc -l < "$TMP" | tr -d '[:space:]')
if [ "$STAGED_LINES" != "$(( ${#KEPT[@]} + 1 ))" ]; then
  echo "error: task record for $ID lost content while staging the binding; nothing was changed" >&2
  exit 1
fi
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
