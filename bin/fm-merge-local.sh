#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# Usage: fm-merge-local.sh <task-id>
#        fm-merge-local.sh --secondmate <secondmate-id> <task-id>
#
# The second form consumes the immutable main-home receipt published by
# fm-local-branch-return.sh. It does not reach into a secondmate home to obtain
# or land work and therefore keeps return, validation, approval, and landing as
# separate operations owned by the main Firstmate.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-local-project-route-lib.sh
. "$SCRIPT_DIR/fm-local-project-route-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
SECOND_ID=
if [ "${1:-}" = --secondmate ]; then
  [ "$#" -eq 3 ] || { echo "usage: fm-merge-local.sh --secondmate <secondmate-id> <task-id>" >&2; exit 2; }
  SECOND_ID=$2
  ID=$3
  if ! fm_local_route_safe_id "$SECOND_ID" || ! fm_local_route_safe_id "$ID"; then
    echo "error: unsafe secondmate or task identity" >&2
    exit 1
  fi
  RECEIPT="$STATE/local-branch-returns/$SECOND_ID/$ID.return"
  fm_local_return_receipt_load "$RECEIPT" || { echo "error: $FM_LOCAL_ROUTE_ERROR" >&2; exit 1; }
  [ "$FM_LOCAL_ROUTE_SECONDMATE_ID" = "$SECOND_ID" ] \
    && [ "$FM_LOCAL_RETURN_TASK_ID" = "$ID" ] \
    && [ "$FM_LOCAL_RETURN_BRANCH" = "fm/$ID" ] \
    || { echo "error: returned branch receipt identity mismatch" >&2; exit 1; }
  MAIN_HOME=$(fm_local_route_canonical_dir "$FM_HOME") \
    || { echo "error: main home path is unsafe or symlinked" >&2; exit 1; }
  [ "$FM_LOCAL_ROUTE_MAIN_HOME" = "$MAIN_HOME" ] \
    || { echo "error: returned branch belongs to a different main home" >&2; exit 1; }
  PROJ=$(fm_local_route_canonical_dir "$FM_LOCAL_ROUTE_MAIN_PROJECT") \
    || { echo "error: returned branch destination path is unsafe or symlinked" >&2; exit 1; }
  PROJECT=$FM_LOCAL_ROUTE_PROJECT
  CAPABILITY=$(fm_local_route_capability_path "$MAIN_HOME" "$SECOND_ID" "$PROJECT") \
    || { echo "error: local-project capability path is invalid" >&2; exit 1; }
  RECEIPT_MAIN_GIT=$FM_LOCAL_ROUTE_MAIN_GIT_COMMON_DIR
  RECEIPT_HEAD=$FM_LOCAL_RETURN_HEAD_OID
  fm_local_route_record_load "$CAPABILITY" || { echo "error: $FM_LOCAL_ROUTE_ERROR" >&2; exit 1; }
  [ "$FM_LOCAL_ROUTE_SECONDMATE_ID" = "$SECOND_ID" ] \
    && [ "$FM_LOCAL_ROUTE_PROJECT" = "$PROJECT" ] \
    && [ "$FM_LOCAL_ROUTE_MAIN_HOME" = "$MAIN_HOME" ] \
    && [ "$FM_LOCAL_ROUTE_MAIN_PROJECT" = "$PROJ" ] \
    && [ "$FM_LOCAL_ROUTE_MAIN_GIT_COMMON_DIR" = "$RECEIPT_MAIN_GIT" ] \
    || { echo "error: local-project capability drifted after branch return" >&2; exit 1; }
  [ "$(fm_local_route_git_common_dir "$PROJ" 2>/dev/null || true)" = "$RECEIPT_MAIN_GIT" ] \
    && [ "$(fm_local_route_path_identity "$RECEIPT_MAIN_GIT" 2>/dev/null || true)" = "$FM_LOCAL_ROUTE_MAIN_GIT_IDENTITY" ] \
    || { echo "error: returned branch destination repository identity drifted" >&2; exit 1; }
  git -C "$PROJ" cat-file -e "$FM_LOCAL_ROUTE_ANCHOR_OID^{commit}" 2>/dev/null \
    || { echo "error: returned branch destination repository identity drifted" >&2; exit 1; }
  read -r MODE _ <<EOF
$(FM_HOME="$MAIN_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" "$PROJECT")
EOF
  [ "$MODE" = local-only ] \
    || { echo "error: returned project is no longer registered local-only" >&2; exit 1; }
  RETURN_LOCK="$STATE/.local-branch-return.lock"
  fm_lock_acquire_wait "$RETURN_LOCK" || { echo "error: returned branch is busy" >&2; exit 1; }
  trap 'fm_lock_release "$RETURN_LOCK" || true' EXIT
else
  [ "$#" -eq 1 ] || { echo "usage: fm-merge-local.sh <task-id>" >&2; exit 2; }
  ID=$1
  META="$STATE/$ID.meta"
  [ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
  PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
  MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
  [ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }
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

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }
if [ -n "$SECOND_ID" ]; then
  [ "$(git -C "$PROJ" rev-parse "refs/heads/$BRANCH")" = "$RECEIPT_HEAD" ] \
    || { echo "error: returned branch changed after its guarded receipt" >&2; exit 1; }
fi

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
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
