#!/usr/bin/env bash
# Return one completed local-only task branch from a validated local secondmate
# project copy into the bound main-home project repository.
#
# Usage: fm-local-branch-return.sh <secondmate-id> <task-id>
#
# This is a branch-conveyance operation only. The main home fetches one exact
# branch from the isolated secondmate project copy, verifies the capability,
# route, repository identities, task metadata, clean source worktree, current
# destination ancestry, stable source and destination tips, and branch-owner
# collision state, then creates refs/heads/fm/<task-id> with update-ref CAS.
# It never merges, checks out, stashes, pushes, rewrites, deletes, or cleans any
# source work. A matching existing branch and receipt is an idempotent replay.
# Captain-controlled landing remains bin/fm-merge-local.sh --secondmate.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"

# shellcheck source=bin/fm-local-project-route-lib.sh
. "$SCRIPT_DIR/fm-local-project-route-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'REFUSED: %s\n' "$1" >&2; exit 1; }
[ "$#" -eq 2 ] || { echo "usage: fm-local-branch-return.sh <secondmate-id> <task-id>" >&2; exit 2; }
ID=$1
TASK=$2
fm_local_route_safe_id "$ID" || die "unsafe secondmate or task identity"
fm_local_route_safe_id "$TASK" || die "unsafe secondmate or task identity"
BRANCH="fm/$TASK"

MAIN_HOME=$(fm_local_route_canonical_dir "$FM_HOME") \
  || die "main home path is unsafe or symlinked"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || die "main state directory is unavailable or unsafe"
LOCK="$STATE/.local-branch-return.lock"
LOCK_HELD=0
release_lock() {
  local rc=$?
  if [ "$LOCK_HELD" -eq 1 ]; then fm_lock_release "$LOCK" || true; fi
  return "$rc"
}
trap release_lock EXIT
fm_lock_acquire_wait "$LOCK" || die "branch-return ownership lock is unavailable"
LOCK_HELD=1

[ -f "$REG" ] && [ ! -L "$REG" ] || die "secondmate registry is unavailable or unsafe"
secondmate_registry_validate_bindings "$REG" secondmate_registry_path_key \
  || die "$SECONDMATE_REGISTRY_ERROR"
secondmate_registry_line_for_id "$REG" "$ID" || die "secondmate route is missing or ambiguous"
[ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || die "local-only branch return requires a local secondmate home"
SECOND_HOME=$(fm_local_route_canonical_dir "$SECONDMATE_REGISTRY_HOME") \
  || die "secondmate home path is unsafe or symlinked"
[ -f "$SECOND_HOME/.fm-secondmate-home" ] && [ ! -L "$SECOND_HOME/.fm-secondmate-home" ] \
  || die "secondmate home identity is unavailable or unsafe"
[ "$(cat "$SECOND_HOME/.fm-secondmate-home" 2>/dev/null || true)" = "$ID" ] \
  || die "secondmate home identity does not match the route"

META="$SECOND_HOME/state/$TASK.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "source task record is unavailable or unsafe"
KIND=$(fm_local_route_value_exact "$META" kind) || die "source task record has ambiguous kind identity"
MODE=$(fm_local_route_value_exact "$META" mode) || die "source task record has ambiguous delivery identity"
SOURCE_PROJECT_RAW=$(fm_local_route_value_exact "$META" project) || die "source task record has ambiguous project identity"
WORKTREE_RAW=$(fm_local_route_value_exact "$META" worktree) || die "source task record has ambiguous worktree identity"
[ "$KIND" = ship ] && [ "$MODE" = local-only ] || die "source task is not a local-only ship task"
SOURCE_PROJECT=$(fm_local_route_canonical_dir "$SOURCE_PROJECT_RAW") \
  || die "source project path is unsafe or symlinked"
PROJECT=$(basename "$SOURCE_PROJECT")
fm_local_route_safe_id "$PROJECT" || die "source task has an unsafe project identity"

CAPABILITY=$(fm_local_route_capability_path "$MAIN_HOME" "$ID" "$PROJECT") \
  || die "local-project capability path is invalid"
fm_local_route_record_load "$CAPABILITY" || die "$FM_LOCAL_ROUTE_ERROR"
[ "$FM_LOCAL_ROUTE_SECONDMATE_ID" = "$ID" ] && [ "$FM_LOCAL_ROUTE_PROJECT" = "$PROJECT" ] \
  || die "local-project capability does not own this secondmate and project"
[ "$FM_LOCAL_ROUTE_MAIN_HOME" = "$MAIN_HOME" ] && [ "$FM_LOCAL_ROUTE_SECONDMATE_HOME" = "$SECOND_HOME" ] \
  || die "local-project home identity drifted"
[ "$FM_LOCAL_ROUTE_SECONDMATE_PROJECT" = "$SOURCE_PROJECT" ] \
  || die "source project identity drifted"
MAIN_PROJECT=$(fm_local_route_canonical_dir "$FM_LOCAL_ROUTE_MAIN_PROJECT") \
  || die "destination project path is unsafe or symlinked"
[ "$(basename "$MAIN_PROJECT")" = "$PROJECT" ] || die "destination project identity drifted"
MAIN_GIT=$(fm_local_route_git_common_dir "$MAIN_PROJECT") \
  || die "destination repository identity drifted"
SOURCE_GIT=$(fm_local_route_git_common_dir "$SOURCE_PROJECT") \
  || die "source repository identity drifted"
[ "$MAIN_GIT" = "$FM_LOCAL_ROUTE_MAIN_GIT_COMMON_DIR" ] \
  && [ "$(fm_local_route_path_identity "$MAIN_GIT" 2>/dev/null || true)" = "$FM_LOCAL_ROUTE_MAIN_GIT_IDENTITY" ] \
  || die "destination repository identity drifted"
[ "$SOURCE_GIT" = "$FM_LOCAL_ROUTE_SECONDMATE_GIT_COMMON_DIR" ] \
  && [ "$(fm_local_route_path_identity "$SOURCE_GIT" 2>/dev/null || true)" = "$FM_LOCAL_ROUTE_SECONDMATE_GIT_IDENTITY" ] \
  || die "source repository identity drifted"
ANCHOR_OID=$FM_LOCAL_ROUTE_ANCHOR_OID
git -C "$MAIN_PROJECT" cat-file -e "$ANCHOR_OID^{commit}" 2>/dev/null \
  || die "destination repository identity drifted"
git -C "$SOURCE_PROJECT" cat-file -e "$ANCHOR_OID^{commit}" 2>/dev/null \
  || die "source repository identity drifted"

read -r REGISTERED_MODE _ <<EOF
$(FM_HOME="$MAIN_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" "$PROJECT")
EOF
[ "$REGISTERED_MODE" = local-only ] || die "project is no longer explicitly registered local-only"
fm_local_route_all_remotes_local "$MAIN_PROJECT" "main local-only project" || die "$FM_LOCAL_ROUTE_ERROR"
fm_local_route_all_remotes_local "$SOURCE_PROJECT" "secondmate local-only project" || die "$FM_LOCAL_ROUTE_ERROR"
fm_local_route_exact_origin "$SOURCE_PROJECT" "$MAIN_PROJECT" || die "$FM_LOCAL_ROUTE_ERROR"

WORKTREE=$(fm_local_route_canonical_dir "$WORKTREE_RAW") \
  || die "unsafe or symlinked worktree path"
[ "$WORKTREE" != "$SOURCE_PROJECT" ] || die "source task is not in an isolated project copy"
WORKTREE_TOP=$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null || true)
WORKTREE_TOP=$(fm_local_route_canonical_dir "$WORKTREE_TOP" 2>/dev/null || true)
[ "$WORKTREE_TOP" = "$WORKTREE" ] || die "source worktree identity is ambiguous"
WORKTREE_GIT=$(fm_local_route_git_common_dir "$WORKTREE") \
  || die "source worktree repository identity is ambiguous"
[ "$WORKTREE_GIT" = "$SOURCE_GIT" ] || die "source worktree does not belong to the guarded secondmate project"
CURRENT_BRANCH=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ "$CURRENT_BRANCH" = "$BRANCH" ] || die "source worktree is not on the canonical task branch $BRANCH"
SOURCE_HEAD=$(git -C "$SOURCE_PROJECT" rev-parse --verify "refs/heads/$BRANCH" 2>/dev/null || true)
[ -n "$SOURCE_HEAD" ] || die "source branch commit is missing"
git -C "$SOURCE_PROJECT" cat-file -e "$SOURCE_HEAD^{commit}" 2>/dev/null \
  || die "source branch commit is missing"
[ "$(git -C "$WORKTREE" rev-parse --verify HEAD 2>/dev/null || true)" = "$SOURCE_HEAD" ] \
  || die "source worktree and task branch identities differ"
SOURCE_STATUS=$(git -C "$WORKTREE" status --porcelain 2>/dev/null) \
  || die "source worktree cannot be inspected safely"
[ -z "$SOURCE_STATUS" ] || die "source worktree is dirty; commit or preserve its work before return"

# A task id has one owner fleet-wide. Main-home metadata or the same task record
# in another local secondmate home makes refs/heads/fm/<task> ambiguous.
if [ -e "$STATE/$TASK.meta" ] || [ -L "$STATE/$TASK.meta" ]; then
  die "task identity is already owned in the main home"
fi
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in "- "*) ;; *) continue ;; esac
  secondmate_registry_parse_line "$line" || die "secondmate registry became malformed"
  [ "$SECONDMATE_REGISTRY_ID" != "$ID" ] || continue
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
  OTHER_HOME=$(fm_local_route_canonical_dir "$SECONDMATE_REGISTRY_HOME" 2>/dev/null || true)
  [ -n "$OTHER_HOME" ] || die "another local secondmate home is unsafe"
  if [ -e "$OTHER_HOME/state/$TASK.meta" ] || [ -L "$OTHER_HOME/state/$TASK.meta" ]; then
    die "task identity is already owned by another secondmate home"
  fi
done < "$REG"

DEFAULT=$(fm_local_route_default_branch "$MAIN_PROJECT") \
  || die "destination repository has an ambiguous or missing local default branch"
BASE_OID=$(git -C "$MAIN_PROJECT" rev-parse --verify "refs/heads/$DEFAULT^{commit}" 2>/dev/null || true)
[ -n "$BASE_OID" ] || die "destination default commit is missing"
git -C "$MAIN_PROJECT" merge-base --is-ancestor "$ANCHOR_OID" "$BASE_OID" 2>/dev/null \
  || die "destination repository identity drifted"
git -C "$SOURCE_PROJECT" merge-base --is-ancestor "$ANCHOR_OID" "$SOURCE_HEAD" 2>/dev/null \
  || die "source branch has unexpected ancestry"
RECEIPT_DIR="$STATE/local-branch-returns/$ID"
RECEIPT="$RECEIPT_DIR/$TASK.return"
if [ -e "$RECEIPT" ] || [ -L "$RECEIPT" ]; then
  fm_local_return_receipt_load "$RECEIPT" || die "$FM_LOCAL_ROUTE_ERROR"
  [ "$FM_LOCAL_ROUTE_SECONDMATE_ID" = "$ID" ] && [ "$FM_LOCAL_ROUTE_PROJECT" = "$PROJECT" ] \
    && [ "$FM_LOCAL_RETURN_TASK_ID" = "$TASK" ] && [ "$FM_LOCAL_RETURN_BRANCH" = "$BRANCH" ] \
    && [ "$FM_LOCAL_ROUTE_MAIN_HOME" = "$MAIN_HOME" ] && [ "$FM_LOCAL_ROUTE_MAIN_PROJECT" = "$MAIN_PROJECT" ] \
    && [ "$FM_LOCAL_ROUTE_MAIN_GIT_COMMON_DIR" = "$MAIN_GIT" ] \
    && [ "$FM_LOCAL_ROUTE_SECONDMATE_HOME" = "$SECOND_HOME" ] \
    && [ "$FM_LOCAL_ROUTE_SECONDMATE_PROJECT" = "$SOURCE_PROJECT" ] \
    && [ "$FM_LOCAL_ROUTE_SECONDMATE_GIT_COMMON_DIR" = "$SOURCE_GIT" ] \
    && [ "$FM_LOCAL_RETURN_HEAD_OID" = "$SOURCE_HEAD" ] \
    || die "existing branch-return receipt is owned by different work"
fi

DEST_HEAD=$(git -C "$MAIN_PROJECT" rev-parse --verify "refs/heads/$BRANCH" 2>/dev/null || true)
if [ -n "$DEST_HEAD" ] && [ "$DEST_HEAD" != "$SOURCE_HEAD" ]; then
  die "destination branch $BRANCH is owned by different work"
fi
if [ -n "$DEST_HEAD" ] && [ -f "$RECEIPT" ]; then
  git -C "$MAIN_PROJECT" merge-base --is-ancestor "$BASE_OID" "$DEST_HEAD" 2>/dev/null \
    || die "$BRANCH is not a fast-forward of the current destination $DEFAULT"
  echo "already returned $BRANCH at $SOURCE_HEAD into $MAIN_PROJECT"
  exit 0
fi

# Fetch from the canonical local project path only. This transfers objects into
# FETCH_HEAD without updating any branch; update-ref below conveys the branch
# only after every post-fetch stability check succeeds.
git -C "$MAIN_PROJECT" fetch --quiet --no-tags "$SOURCE_PROJECT" "refs/heads/$BRANCH" \
  || die "local branch object transfer failed; source work was preserved"
FETCHED_HEAD=$(awk 'NR == 1 { print $1 }' "$MAIN_GIT/FETCH_HEAD" 2>/dev/null || true)
[ "$FETCHED_HEAD" = "$SOURCE_HEAD" ] \
  || die "fetched branch identity or objects do not match the guarded source"
git -C "$MAIN_PROJECT" cat-file -e "$FETCHED_HEAD^{commit}" 2>/dev/null \
  || die "fetched branch identity or objects do not match the guarded source"
git -C "$MAIN_PROJECT" merge-base --is-ancestor "$BASE_OID" "$FETCHED_HEAD" 2>/dev/null \
  || die "$BRANCH is not a fast-forward of the current destination $DEFAULT"
[ "$(git -C "$SOURCE_PROJECT" rev-parse --verify "refs/heads/$BRANCH" 2>/dev/null || true)" = "$SOURCE_HEAD" ] \
  || die "source branch changed during return; no destination branch was updated"
[ "$(git -C "$MAIN_PROJECT" rev-parse --verify "refs/heads/$DEFAULT" 2>/dev/null || true)" = "$BASE_OID" ] \
  || die "destination default branch changed during return; no destination branch was updated"
[ "$(fm_local_route_path_identity "$MAIN_GIT" 2>/dev/null || true)" = "$FM_LOCAL_ROUTE_MAIN_GIT_IDENTITY" ] \
  || die "destination repository changed during return; no destination branch was updated"
[ "$(fm_local_route_path_identity "$SOURCE_GIT" 2>/dev/null || true)" = "$FM_LOCAL_ROUTE_SECONDMATE_GIT_IDENTITY" ] \
  || die "source repository changed during return; no destination branch was updated"
[ -z "$(git -C "$WORKTREE" status --porcelain 2>/dev/null)" ] \
  || die "source worktree changed during return; no destination branch was updated"

if [ -z "$DEST_HEAD" ]; then
  ZERO=$(printf '%0*d' "${#SOURCE_HEAD}" 0)
  git -C "$MAIN_PROJECT" update-ref "refs/heads/$BRANCH" "$SOURCE_HEAD" "$ZERO" \
    || die "destination branch ownership changed during return"
fi
fm_local_return_receipt_write "$RECEIPT" "$ID" "$PROJECT" "$TASK" \
  "$MAIN_HOME" "$MAIN_PROJECT" "$MAIN_GIT" "$SECOND_HOME" "$SOURCE_PROJECT" "$SOURCE_GIT" \
  "$BASE_OID" "$SOURCE_HEAD" || die "branch arrived but its guarded return receipt could not be published; replay the return"
printf 'returned %s at %s into %s; default branch %s remains at %s\n' \
  "$BRANCH" "$SOURCE_HEAD" "$MAIN_PROJECT" "$DEFAULT" "$BASE_OID"
