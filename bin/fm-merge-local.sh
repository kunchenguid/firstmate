#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's immutable ship branch recorded in
# state/<task-id>.meta ("fm/<id>" for records created before that field existed).
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
# A repository lock also serializes local landings across tasks and homes.
# The base and ship commits are captured once; validation and the fast-forward
# use those full object IDs, never a mutable ship ref. Ref/checkout changes
# during validation refuse before the merge, and the resulting tip is verified.
# A task whose owning home (the parent of its state directory) is opted in
# with config/knowledge-landing (docs/configuration.md), or FM_CONFIG_OVERRIDE's
# copy of that file, runs fm-knowledge-landing.py before landing; its header owns which repositories
# it applies to and the checker/approval protocol. Without that file, and for
# repositories it does not cover, projects keep their existing approval path.
# These locks coordinate this entrypoint, not arbitrary external Git writers;
# pause other checkout writers before landing.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
# Match the knowledge check's repository and object view, regardless of the
# invoking harness's inherited Git checkout/index/config overrides or replace refs.
# Without GIT_CONFIG_COUNT, Git ignores any GIT_CONFIG_KEY_n/VALUE_n pairs.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
  GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
export GIT_NO_REPLACE_OBJECTS=1
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
# no-op in homes without a branch actor). This action is deliberately NOT
# relocated under the away-posture record: unlike the PR merge it has no
# record-side grant gate of its own, so a parked main keeps it held for the
# captain's return. This precedes reading the task record, because the wrong
# actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
MERGE_PROJECT_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_PROJECT_LOCK" ] || fm_lock_release "$MERGE_PROJECT_LOCK" || true
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

common_directory() {
  local common
  common=$(git -C "$1" rev-parse --git-common-dir) || return 1
  (cd "$1" && cd "$common" && pwd -P)
}
PROJECT_COMMON=$(common_directory "$PROJ") || exit 1
MERGE_PROJECT_LOCK="$PROJECT_COMMON/fm-merge-local.lock"
if ! fm_lock_acquire_wait_max "$MERGE_PROJECT_LOCK" 30; then
  echo "error: another local landing holds $PROJECT_COMMON; retry when it finishes" >&2
  exit 1
fi

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
head=$(git -C "$PROJ" rev-parse --verify "refs/heads/$BRANCH^{commit}") || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }
base=$(git -C "$PROJ" rev-parse --verify "refs/heads/$DEFAULT^{commit}")

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
worktree_status=$(git -C "$PROJ" status --porcelain) || exit 1
if [ -n "$worktree_status" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$base" "$head"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

TASK_HOME=$(cd "$STATE/.." && pwd -P) || exit 1
KNOWLEDGE_CONFIG="${FM_CONFIG_OVERRIDE:-$TASK_HOME/config}/knowledge-landing"
if [ -e "$KNOWLEDGE_CONFIG" ] || [ -L "$KNOWLEDGE_CONFIG" ]; then
  python3 -I "$SCRIPT_DIR/fm-knowledge-landing.py" "$KNOWLEDGE_CONFIG" "$TASK_HOME" \
    "$PROJ" "$base" "$head" "$ID" || exit 1
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
# The check and any approval above describe exactly this pair. The immutable
# merge operand also closes the ship-ref race after this final comparison.
if [ "$(git -C "$PROJ" symbolic-ref --quiet HEAD)" != "refs/heads/$DEFAULT" ] \
  || [ "$(git -C "$PROJ" rev-parse --verify "refs/heads/$DEFAULT^{commit}")" != "$base" ] \
  || [ "$(git -C "$PROJ" rev-parse --verify "refs/heads/$BRANCH^{commit}")" != "$head" ]; then
  echo "error: checkout or landing refs changed during validation; refusing to merge" >&2
  exit 1
fi
worktree_status=$(git -C "$PROJ" status --porcelain) || exit 1
[ -z "$worktree_status" ] || { echo "error: working tree changed during validation; refusing to merge" >&2; exit 1; }
merge_status=0
git -C "$PROJ" merge --ff-only "$head" >/dev/null || merge_status=$?
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --verify "refs/heads/$DEFAULT^{commit}")
if [ "$after" != "$head" ] || [ "$(git -C "$PROJ" symbolic-ref --quiet HEAD)" != "refs/heads/$DEFAULT" ]; then
  echo "error: local landing did not leave the checked commit $head on $DEFAULT; inspect $PROJ before retrying" >&2
  exit 1
fi
fm_lock_release "$MERGE_PROJECT_LOCK" || true
MERGE_PROJECT_LOCK=
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" merged "$ID" local || true
echo "merged $BRANCH into local $DEFAULT ($base -> $after) in $PROJ"
