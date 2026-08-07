#!/usr/bin/env bash
# Review a task's exact registered revision against the authoritative base.
#
# PR tasks must first run fm-pr-check.sh; local-only tasks must first run
# fm-merge-local.sh --prepare. Both write ready_head=. This command verifies the
# movable PR or branch still resolves to that immutable commit and refuses any
# mismatch instead of silently reviewing newer code under an older approval.
# Re-run the owning readiness command after an intentional rebase or fix.
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints only the stat summary; default prints stat plus full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() { echo "usage: fm-review-diff.sh <task-id> [--stat]" >&2; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
ID=${1:-}
fm_pr_task_id_valid "$ID" || { usage; exit 2; }
STAT_ONLY=false
case "${2:-}" in '') ;; --stat) STAT_ONLY=true ;; *) usage; exit 2 ;; esac
[ "$#" -le 2 ] || { usage; exit 2; }

META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: no regular metadata for task $ID at $META" >&2
  exit 1
fi

meta_exact() {  # <key>
  local key=$1 count value
  count=$(grep -c "^${key}=" "$META" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^${key}=" "$META" | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

WT=$(meta_exact worktree) || { echo "error: task $ID has an absent or ambiguous worktree identity" >&2; exit 1; }
PROJ=$(meta_exact project) || { echo "error: task $ID has an absent or ambiguous project identity" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }
READY_HEAD=$(meta_exact ready_head) || {
  echo "REFUSED: task $ID has no exact review-ready revision; register PR readiness or prepare the local merge first." >&2
  exit 1
}
fm_pr_head_valid "$READY_HEAD" || { echo "REFUSED: task $ID has a malformed review-ready revision." >&2; exit 1; }

PR_URL=$(grep '^pr=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
COMPARE_REF=$READY_HEAD
if [ -n "$PR_URL" ]; then
  fm_pr_metadata_identity_parse "$META" || {
    echo "REFUSED: task $ID has malformed or inconsistent PR revision metadata; run bin/fm-pr-check.sh again." >&2
    exit 1
  }
  fm_pr_poll_artifacts_valid "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
    echo "REFUSED: task $ID has no complete authenticated PR readiness registration; run bin/fm-pr-check.sh again." >&2
    exit 1
  }
  [ "$FM_PR_META_READY_HEAD" = "$READY_HEAD" ] || exit 1
  CURRENT_HEAD=$(fm_pr_remote_head "$FM_PR_META_PROVIDER" "$FM_PR_META_URL" \
    "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER") || {
    echo "REFUSED: the forge's current PR head is unavailable; refusing an unverified review diff." >&2
    exit 1
  }
  [ "$CURRENT_HEAD" = "$READY_HEAD" ] || {
    echo "REFUSED: PR head moved from registered revision $READY_HEAD to $CURRENT_HEAD." >&2
    echo "Run bin/fm-pr-check.sh $ID $FM_PR_META_URL before reviewing or approving the new revision." >&2
    exit 1
  }
  if ! git -C "$WT" cat-file -e "$READY_HEAD^{commit}" 2>/dev/null; then
    case "$FM_PR_META_PROVIDER" in
      github)
        git -C "$WT" fetch --quiet origin \
          "+refs/pull/$FM_PR_META_NUMBER/head:refs/fm-review/pull/$FM_PR_META_NUMBER/head" >/dev/null 2>&1 || {
          echo "REFUSED: registered PR revision $READY_HEAD cannot be fetched for review." >&2
          exit 1
        }
        ;;
      gitlab)
        git -C "$WT" fetch --quiet origin \
          "+refs/merge-requests/$FM_PR_META_NUMBER/head:refs/fm-review/merge-request/$FM_PR_META_NUMBER/head" >/dev/null 2>&1 || {
          echo "REFUSED: registered merge-request revision $READY_HEAD cannot be fetched for review." >&2
          exit 1
        }
        ;;
    esac
  fi
else
  BRANCH="fm/$ID"
  BRANCH_HEAD=$(git -C "$WT" rev-parse --verify "refs/heads/$BRANCH^{commit}" 2>/dev/null) || {
    echo "error: branch $BRANCH does not exist in $WT" >&2
    exit 1
  }
  WT_HEAD=$(git -C "$WT" rev-parse "HEAD^{commit}" 2>/dev/null) || exit 1
  [ "$BRANCH_HEAD" = "$READY_HEAD" ] && [ "$WT_HEAD" = "$READY_HEAD" ] || {
    echo "REFUSED: local branch moved after readiness was registered at $READY_HEAD." >&2
    echo "Run bin/fm-merge-local.sh $ID --prepare before reviewing or approving the new revision." >&2
    exit 1
  }
fi

git -C "$WT" cat-file -e "$COMPARE_REF^{commit}" 2>/dev/null || {
  echo "error: registered review revision $COMPARE_REF is unavailable in $WT" >&2
  exit 1
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }
if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
  BASE="origin/$DEFAULT"
else
  BASE="$DEFAULT"
fi
git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "error: base $BASE does not exist in $WT" >&2; exit 1; }

echo "diff base: $BASE"
echo "diff head: $READY_HEAD"
if git -C "$WT" diff --quiet "$BASE...$COMPARE_REF" --; then
  echo "no changes vs $BASE"
  exit 0
fi

git -C "$WT" diff --stat "$BASE...$COMPARE_REF" --
if ! "$STAT_ONLY"; then
  echo
  git -C "$WT" diff "$BASE...$COMPARE_REF" --
fi
