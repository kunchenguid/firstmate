#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to local_done_head= in state/<task-id>.meta,
# recorded when the done report was accepted by bin/fm-dod-lib.sh. Missing or
# malformed heads refuse. Legacy tasks with no head must report readiness again
# before approval. The recorded ship branch must still point at that exact commit.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves; while away, per the away gate below), and only as a clean
# fast-forward. A diverged branch needs a
# rebase and a new task/approval record under bin/fm-dod-lib.sh's head-latching
# contract before landing. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
# A per-checkout lock in the project's Git directory serializes different
# tasks across the checks, checkout update, ref transaction, and rollback.
# tests/fm-merge-local.test.sh covers pinned-head landing and race refusals.
# Usage: fm-merge-local.sh <task-id> [--attended-override]
#   --attended-override: pass only for an explicit captain instruction naming
#   this landing. While away it lets main land a task whose recorded merge
#   posture is not yolo=on; the supervision branch is refused it, because it
#   cannot hear the captain. It skips no other check.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
ATTENDED_OVERRIDE=false
if [ "$#" -eq 2 ] && [ "$2" = --attended-override ]; then
  ATTENDED_OVERRIDE=true
elif [ "$#" -ne 1 ]; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
if ! fm_pr_task_id_valid "$1"; then
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
# Role partition: landing local-only work is MAIN-owned; attended, the Pi
# supervision branch reports readiness and never lands (contract:
# bin/fm-lease-lib.sh; no-op in homes without a branch actor). While the
# away-posture record exists main is parked and this action relocates to the
# branch, held by the away gate below - the same gate main meets in that
# posture. This precedes reading the task record, because the wrong actor is
# refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)" --away-relocated
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"

# Away gate: the away posture never approves less than the standing authority
# the captain already granted, and never more. While an away record exists (a
# quiet-mode record is a present captain, so its landings stay attended:
# bin/fm-afk-contract.sh mode) a task whose recorded merge posture is yolo=on -
# firstmate's standing authority to land green, in-scope work - lands for
# either actor. Any other task lands only for main with --attended-override,
# passed for an explicit captain instruction naming this landing, as
# bin/fm-pr-merge.sh's attended override; with no such word it waits for the
# return. The supervision branch is refused the override in every posture,
# because it cannot hear the captain. An unreadable record refuses rather than
# being skipped. Rechecked under the task locks, after the record is read and
# before the fast-forward, so a record archived meanwhile restores the
# attended role partition for the branch.
merge_local_require_away_standing_authority() {
  fm_lease_forbid_branch "local-only landing (fm-merge-local)" --away-relocated
  if [ "$ATTENDED_OVERRIDE" = true ] && [ "$(fm_lease_actor)" = branch ]; then
    echo "error: local merge refused - --attended-override carries an explicit captain instruction, which the supervision branch cannot hear; nothing was landed" >&2
    exit 1
  fi
  [ -f "$STATE/.afk-contract" ] || return 0
  if ! FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" validate >/dev/null 2>&1; then
    echo "error: local merge refused - the away-posture record could not be read; nothing was landed" >&2
    exit 1
  fi
  fm_afk_contract_away_present "$STATE" || return 0
  [ "$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2-)" = on ] && return 0
  [ "$ATTENDED_OVERRIDE" = true ] && return 0
  echo "error: local merge refused while away - task $ID's recorded merge posture is not yolo=on, so its landing waits for the captain's word; pass --attended-override only for an explicit captain instruction naming this landing; nothing was landed" >&2
  exit 1
}

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN
MERGE_EXPECTED_HEAD=$(fm_dod_local_done_head "$META") || {
  echo "error: missing or malformed local done head for task $ID; report readiness before approval" >&2
  exit 1
}

MERGE_CONTROL_LOCK=
MERGE_META_LOCK=
MERGE_PROJECT_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_PROJECT_LOCK" ] || fm_lock_release "$MERGE_PROJECT_LOCK" || true
  [ -z "$MERGE_META_LOCK" ] || fm_lock_release "$MERGE_META_LOCK" || true
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
MERGE_META_LOCK=$(fm_meta_lock_path "$META")
fm_lock_acquire_wait "$MERGE_META_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi
MERGE_HEAD=$(fm_dod_local_done_head "$META") || {
  echo "error: missing or malformed local done head for task $ID" >&2
  exit 1
}
[ "$MERGE_HEAD" = "$MERGE_EXPECTED_HEAD" ] || {
  echo "error: task $ID local done head changed while waiting to merge; refusing" >&2
  exit 1
}

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }
merge_local_require_away_standing_authority

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

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi
local_head_matches() {
  [ "$(git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}")" = "$MERGE_HEAD" ]
}
project_git_dir=$(git -C "$PROJ" rev-parse --absolute-git-dir) || {
  echo "error: cannot determine the project checkout's Git directory" >&2
  exit 1
}
MERGE_PROJECT_LOCK="$project_git_dir/fm-local-landing.lock"
fm_lock_acquire_wait "$MERGE_PROJECT_LOCK"
local_head_matches || { echo "error: branch $BRANCH differs from the recorded local done head; refusing" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
before=$(git -C "$PROJ" rev-parse "$DEFAULT")
if ! git -C "$PROJ" merge-base --is-ancestor "$before" "$MERGE_HEAD"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

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
# Recheck after the approval read. Git's ref transaction below verifies and
# locks the worker head together with the default-branch update.
if [ "$(fm_dod_local_done_head "$META")" != "$MERGE_HEAD" ] || ! local_head_matches; then
  echo "error: local done head or branch changed during approval check; refusing" >&2
  exit 1
fi
merge_status=0
# Stage the fast-forward with Git's two-tree checkout, which preserves local
# changes made since the clean-tree check and refuses obstructing files.
git -C "$PROJ" read-tree -m -u "$before" "$MERGE_HEAD" || exit $?
git -C "$PROJ" update-ref -m "merge $BRANCH: Fast-forward" --stdin >/dev/null <<EOF || merge_status=$?
start
verify refs/heads/$BRANCH $MERGE_HEAD
update refs/heads/$DEFAULT $MERGE_HEAD $before
prepare
commit
EOF
if [ "$merge_status" -ne 0 ]; then
  # The transaction left main untouched. Undo only the staged fast-forward;
  # the two-tree checkout also protects any intervening local edits here.
  git -C "$PROJ" read-tree -m -u "$MERGE_HEAD" "$before" || {
    echo "error: local merge refused and checkout restoration failed in $PROJ" >&2
    exit 1
  }
fi
fm_lock_release "$MERGE_META_LOCK" || true
MERGE_META_LOCK=
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
fm_lock_release "$MERGE_PROJECT_LOCK" || true
MERGE_PROJECT_LOCK=
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" merged "$ID" local || true
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
