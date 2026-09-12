#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# landing branch to the crewmate's recorded branch.
# The crew branch is the last `Crew branch: branch=<name>` in
# data/<id>/brief.md (written by bin/fm-brief.sh --branch-name). The landing
# branch is state/<id>.meta's base_branch=. Missing values retain the historical
# fm/<id> crew branch and default landing branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This precedes reading the task
# record, because the wrong actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-brief-contract-lib.sh
. "$SCRIPT_DIR/fm-brief-contract-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRIEF="$DATA/$ID/brief.md"
BRANCH="fm/$ID"
if [ -f "$BRIEF" ]; then
  recorded_branch=$(fm_brief_crew_branch "$BRIEF")
  if [ -n "$recorded_branch" ]; then
    git check-ref-format --branch "$recorded_branch" >/dev/null 2>&1 || {
      echo "error: $BRIEF records an invalid crew branch: $recorded_branch" >&2
      exit 1
    }
    BRANCH=$recorded_branch
  fi
fi
BRANCH_REF="refs/heads/$BRANCH"
git -C "$PROJ" rev-parse --verify --quiet "$BRANCH_REF" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

recorded_base=$(grep '^base_branch=' "$META" | tail -n 1 | cut -d= -f2- || true)
if [ -n "$recorded_base" ]; then
  git check-ref-format --branch "$recorded_base" >/dev/null 2>&1 || {
    echo "error: $META records an invalid base branch: $recorded_base" >&2
    exit 1
  }
  TARGET=$recorded_base
  DEFAULT=$(default_branch || true)
else
  DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }
  TARGET=$DEFAULT
fi
TARGET_REF="refs/heads/$TARGET"
git -C "$PROJ" rev-parse --verify --quiet "$TARGET_REF" >/dev/null || { echo "error: landing branch $TARGET does not exist in $PROJ" >&2; exit 1; }

# The project's main checkout must stay on its default branch unless it is
# already on the landing target. firstmate never writes here otherwise.
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ "$cur" != "$TARGET" ] && { [ -z "$DEFAULT" ] || [ "$cur" != "$DEFAULT" ]; }; then
  echo "error: $PROJ is on '$cur', expected default branch '${DEFAULT:-unresolved}' or landing branch '$TARGET'; cannot merge safely" >&2
  exit 1
fi
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: TARGET must be an ancestor of BRANCH.
branch_sha=$(git -C "$PROJ" rev-parse "$BRANCH_REF")
target_sha=$(git -C "$PROJ" rev-parse "$TARGET_REF")
if ! git -C "$PROJ" merge-base --is-ancestor "$target_sha" "$branch_sha"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $TARGET (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $TARGET, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$target_sha")
hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac
merge_status=0
if [ "$cur" = "$TARGET" ]; then
  git -C "$PROJ" merge --ff-only "$branch_sha" >/dev/null || merge_status=$?
else
  target_worktree=$(git -C "$PROJ" for-each-ref --format='%(worktreepath)' "$TARGET_REF")
  if [ -n "$target_worktree" ]; then
    echo "error: $TARGET is checked out in $target_worktree; refusing to update-ref it" >&2
    exit 1
  fi
  # Stay on the default checkout and fast-forward the named base in place.
  git -C "$PROJ" update-ref -m "fm-merge-local: fast-forward $TARGET to $BRANCH" \
    "$TARGET_REF" "$branch_sha" "$target_sha" || merge_status=$?
fi
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "$TARGET_REF")
echo "merged $BRANCH into local $TARGET ($before -> $after) in $PROJ"
