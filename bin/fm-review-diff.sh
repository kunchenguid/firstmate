#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<branch> after fetching
# it, and local-only projects against the local branch.
# The diff base is the repo default branch, unless state/<id>.meta records a
# non-default base= (a task whose intended base is a feature branch, declared
# with fm-spawn.sh --base), that base branch still exists on origin, AND the reviewed head
# is actually rooted in it: then it is that base, so review shows the crewmate's own change
# rather than the entire feature base's unmerged history on top of it.
#
# Both conditions matter, and the diff is wrong in a different direction without each. A base
# that is gone cannot be diffed against at all. A base that is still there but that the head
# was REBASED OFF - what the no-mistakes pipeline does to every head, and the state
# fm-pr-check.sh refuses - is worse than useless as a diff base: the merge base is then the old
# fork point, so the diff would show every default-branch commit since the fork as part of the
# crewmate's change. Rootedness is asked with the same bin/fm-base-lib.sh predicate the guard
# uses, so review and the merge gate never tell different stories about one head.
#
# In every case that rules the declared base out, this script falls back to the default branch
# and SAYS SO in one line, rather than erroring or guessing: review is exactly what firstmate
# needs while sorting out a refused base, so it is never blocked. It does not try to work out
# whether a gone base merged or was abandoned - git cannot tell those apart without a guess,
# and fm-pr-check.sh defers that same PR to a human.
# When state/<id>.meta records pr= for an open PR, the compare side is the PR
# head (recorded pr_head= when reachable, else refs/pull/<n>/head) so review
# stays current after no-mistakes fix rounds push to the PR; if the PR head
# cannot be resolved, the script falls back to the local branch with a warning.
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints only the stat summary; default prints stat summary plus full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-base-lib.sh
. "$SCRIPT_DIR/fm-base-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-review-diff.sh <task-id> [--stat]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
STAT_ONLY=false
case "${2:-}" in
  '') ;;
  --stat) STAT_ONLY=true ;;
  *) usage; exit 1 ;;
esac
[ $# -le 2 ] || { usage; exit 1; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
[ -n "$WT" ] || { echo "error: meta for task $ID is missing worktree=" >&2; exit 1; }
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }

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

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

BRANCH="fm/$ID"
if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: branch fm/$ID does not exist and worktree $WT is detached" >&2; exit 1; }
  git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $WT" >&2; exit 1; }
fi

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

resolve_pr_head() {
  local pr_url=$1 recorded_head=$2 n resolved
  if [ -n "$recorded_head" ] \
    && git -C "$WT" cat-file -e "$recorded_head^{commit}" 2>/dev/null; then
    printf '%s' "$recorded_head"
    return 0
  fi
  n=$(pr_number_from_target "$pr_url") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  resolved=$(git -C "$WT" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null) || return 1
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
}

PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
COMPARE_REF=$BRANCH
if [ -n "$PR_URL" ]; then
  if PR_HEAD=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
    COMPARE_REF=$PR_HEAD
  else
    echo "warning: PR head unavailable; diff may lag the open PR (using local branch $BRANCH)" >&2
  fi
fi

# A task that declared a non-default intended base is reviewed against that base;
# diffing it against the repo default would present the whole feature base's
# unmerged history as part of the crewmate's change.
BASE_DECLARED=$(grep '^base=' "$META" | tail -1 | cut -d= -f2- || true)
if [ -n "$BASE_DECLARED" ] && ! fm_base_valid_branch_name "$BASE_DECLARED"; then
  echo "error: task $ID records base='$BASE_DECLARED', which is not a valid git branch name (it must be non-empty, free of whitespace, and must not begin with '-')" >&2
  exit 1
fi
BASE_BRANCH=${BASE_DECLARED:-$DEFAULT}

HAS_ORIGIN=false
if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  HAS_ORIGIN=true
fi

# A declared base is only the diff base while that branch is still on origin. Once it is
# gone - or origin cannot be asked - review does not guess what became of it; it falls back
# to the default branch and says so, which is the same call bin/fm-pr-check.sh's guard
# makes on the same input (it defers that PR to a human). Review is never blocked by it:
# what the fallback diff shows is everything the PR would land on the default branch, which
# is exactly what firstmate needs while sorting the base out.
if [ -n "$BASE_DECLARED" ] && "$HAS_ORIGIN"; then
  PROBE_RC=0
  fm_base_probe_origin "$WT" "$BASE_DECLARED" || PROBE_RC=$?
  case "$PROBE_RC" in
    "$FM_BASE_PRESENT") ;;
    "$FM_BASE_ABSENT")
      echo "warning: task $ID declares intended base $BASE_DECLARED, but that branch no longer exists on origin, so it cannot be the diff base; diffing against the default branch $DEFAULT instead, which shows everything this PR would land on $DEFAULT" >&2
      BASE_BRANCH=$DEFAULT
      ;;
    *)
      echo "warning: task $ID declares intended base $BASE_DECLARED, but origin could not be asked whether that branch still exists; diffing against the default branch $DEFAULT instead, which shows everything this PR would land on $DEFAULT" >&2
      [ -z "$FM_BASE_PROBE_ERR" ] || printf '  git: %s\n' "$FM_BASE_PROBE_ERR" >&2
      BASE_BRANCH=$DEFAULT
      ;;
  esac
fi

# Update the remote-tracking ref itself; a bare single-branch fetch can leave origin/<branch>
# stale on some Git versions and only refresh FETCH_HEAD. The refspec is fully qualified so a
# dash-leading branch name cannot be read as an option.
fetch_tracking_ref() {  # <branch>; prints git's error on failure
  git -C "$WT" fetch --quiet origin "+refs/heads/$1:refs/remotes/origin/$1" 2>&1
}

if "$HAS_ORIGIN"; then
  if ! FETCH_ERR=$(fetch_tracking_ref "$BASE_BRANCH"); then
    echo "error: cannot fetch base branch $BASE_BRANCH from origin for task $ID" >&2
    [ -z "$FETCH_ERR" ] || printf '  git: %s\n' "$FETCH_ERR" >&2
    exit 1
  fi
  BASE="origin/$BASE_BRANCH"
else
  BASE="$BASE_BRANCH"
fi

git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "error: base $BASE does not exist in $WT" >&2; exit 1; }
git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }

# A declared base is the honest diff base only while the reviewed head is actually ROOTED in
# it. A head the no-mistakes pipeline has rebased onto the default branch is not: its merge
# base with the declared base is the OLD fork point, so a three-dot diff against that base
# would show every default-branch commit since the fork as part of the crewmate's change -
# the inflated diff this helper exists to prevent, arriving from the other side. And that is
# precisely the head bin/fm-pr-check.sh refuses, which is when firstmate is most likely to be
# running this. Same question, same predicate, so review and the merge gate never tell
# different stories about one head.
if [ -n "$BASE_DECLARED" ] && [ "$BASE_BRANCH" = "$BASE_DECLARED" ]; then
  if "$HAS_ORIGIN"; then
    if ! FETCH_ERR=$(fetch_tracking_ref "$DEFAULT"); then
      echo "error: cannot fetch default branch $DEFAULT from origin for task $ID" >&2
      [ -z "$FETCH_ERR" ] || printf '  git: %s\n' "$FETCH_ERR" >&2
      exit 1
    fi
    DEFAULT_REF="origin/$DEFAULT"
  else
    DEFAULT_REF="$DEFAULT"
  fi
  git -C "$WT" rev-parse --verify --quiet "$DEFAULT_REF^{commit}" >/dev/null \
    || { echo "error: default branch $DEFAULT_REF does not exist in $WT" >&2; exit 1; }

  ROOTED_RC=0
  fm_base_head_rooted "$WT" "$BASE" "$COMPARE_REF" "$DEFAULT_REF" || ROOTED_RC=$?
  case "$ROOTED_RC" in
    "$FM_BASE_HEAD_ROOTED") ;;
    "$FM_BASE_HEAD_UNROOTED")
      echo "warning: task $ID declares intended base $BASE_DECLARED, but the reviewed head is not rooted in that base's history - it was rebased onto the default branch - so diffing against $BASE_DECLARED would present every $DEFAULT commit since the fork as part of this change; diffing against the default branch $DEFAULT instead, which shows what this head actually adds. This is the head bin/fm-pr-check.sh refuses before merge." >&2
      BASE=$DEFAULT_REF
      ;;
    *)
      echo "warning: task $ID declares intended base $BASE_DECLARED, but the reviewed head shares no history with that base at all, so it cannot be the diff base; diffing against the default branch $DEFAULT instead" >&2
      BASE=$DEFAULT_REF
      ;;
  esac
fi

echo "diff base: $BASE"
if git -C "$WT" diff --quiet "$BASE...$COMPARE_REF" --; then
  echo "no changes vs $BASE"
  exit 0
fi

git -C "$WT" diff --stat "$BASE...$COMPARE_REF" --
if ! "$STAT_ONLY"; then
  echo
  git -C "$WT" diff "$BASE...$COMPARE_REF" --
fi
