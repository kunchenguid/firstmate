#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<branch> after fetching
# it, and local-only projects against the local branch.
# The diff base is the repo default branch, unless state/<id>.meta records a
# non-default base= (a task whose intended base is a feature branch, declared
# with fm-spawn.sh --base), that base is still a LIVE feature base on origin, AND the
# reviewed head is actually rooted in it: then it is that base, so review shows the
# crewmate's own change rather than the entire feature base's unmerged history on top of it.
#
# All three conditions matter, and the diff is wrong in a different direction without each. A
# base that is gone cannot be diffed against at all. A base that is still on origin but that
# the default branch has already absorbed carries nothing to diff against, and rootedness is
# not observable against it. A base that is still live but that the head was REBASED OFF -
# what the no-mistakes pipeline does to every head, and the state fm-pr-check.sh refuses - is
# worse than useless as a diff base: the merge base is then the old fork point, so the diff
# would show every default-branch commit since the fork as part of the crewmate's change.
# Liveness is bin/fm-base-lib.sh's fm_base_liveness - the one predicate every base-aware
# consumer decides on, and the one owner of what "live" means - and rootedness is its
# fm_base_head_rooted, asked in that order, so review and the merge gate can never tell
# different stories about one head.
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
git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }

# A task that declared a non-default intended base is reviewed against that base;
# diffing it against the repo default would present the whole feature base's
# unmerged history as part of the crewmate's change.
BASE_DECLARED=$(grep '^base=' "$META" | tail -1 | cut -d= -f2- || true)
if [ -n "$BASE_DECLARED" ] && ! fm_base_valid_branch_name "$BASE_DECLARED"; then
  echo "error: task $ID records base='$BASE_DECLARED', which is not a valid git branch name (it must be non-empty, free of whitespace, and must not begin with '-')" >&2
  exit 1
fi
BASE_BRANCH=${BASE_DECLARED:-$DEFAULT}
# fm_base_liveness fetches the refs it compares, so whatever it settled on is already
# current and must not be fetched a second time below.
BASE_BRANCH_FETCHED=false

HAS_ORIGIN=false
if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  HAS_ORIGIN=true
fi

# A declared base is the honest diff base only while it is a LIVE feature base - one that
# still carries unmerged work of its own - AND the reviewed head is actually ROOTED in it.
# Both are asked with the bin/fm-base-lib.sh predicates bin/fm-pr-check.sh's guard decides
# on, in the same order, so review and the merge gate can never tell different stories about
# one head.
#
# Liveness first, and for the same reason the guard asks it first: a base that is still on
# origin but that the default branch has already absorbed carries nothing to diff against,
# and rootedness cannot even be asked of it (every fork point with such a base is reachable
# from the default branch, so a correctly stacked head reads UNROOTED and the warning below
# would tell the reviewer something untrue about it).
#
# Then rootedness. A head the no-mistakes pipeline has rebased onto the default branch is not
# rooted in the base: its merge base with the declared base is the OLD fork point, so a
# three-dot diff against that base would show every default-branch commit since the fork as
# part of the crewmate's change - the inflated diff this helper exists to prevent, arriving
# from the other side. And that is precisely the head bin/fm-pr-check.sh refuses, which is
# when firstmate is most likely to be running this.
#
# In every case that rules the declared base out, review falls back to the default branch and
# SAYS SO, rather than erroring or guessing: what that diff shows is everything the PR would
# land on the default branch, which is exactly what firstmate needs while sorting out a base
# the guard has deferred or refused, so review is never the thing that is blocked.
if [ -n "$BASE_DECLARED" ] && "$HAS_ORIGIN"; then
  LIVENESS_RC=0
  fm_base_liveness "$WT" "$BASE_DECLARED" "$DEFAULT" || LIVENESS_RC=$?
  case "$LIVENESS_RC" in
    "$FM_BASE_LIVE")
      ROOTED_RC=0
      fm_base_head_rooted "$WT" "$FM_BASE_TIP" "$COMPARE_REF" "$FM_BASE_DEFAULT_SHA" \
        || ROOTED_RC=$?
      case "$ROOTED_RC" in
        "$FM_BASE_HEAD_ROOTED") BASE_BRANCH_FETCHED=true ;;
        "$FM_BASE_HEAD_UNROOTED")
          echo "warning: task $ID declares intended base $BASE_DECLARED, but the reviewed head is not rooted in that base's history - it was rebased onto the default branch - so diffing against $BASE_DECLARED would present every $DEFAULT commit since the fork as part of this change; diffing against the default branch $DEFAULT instead, which shows what this head actually adds. This is the head bin/fm-pr-check.sh refuses before merge." >&2
          BASE_BRANCH=$DEFAULT
          BASE_BRANCH_FETCHED=true
          ;;
        *)
          echo "warning: task $ID declares intended base $BASE_DECLARED, but the reviewed head shares no history with that base at all, so it cannot be the diff base; diffing against the default branch $DEFAULT instead" >&2
          BASE_BRANCH=$DEFAULT
          BASE_BRANCH_FETCHED=true
          ;;
      esac
      ;;
    "$FM_BASE_ABSORBED")
      echo "warning: task $ID declares intended base $BASE_DECLARED, but that branch carries no commits $DEFAULT does not already have, so it is no longer a live feature base and is no longer a distinct diff base; diffing against the default branch $DEFAULT instead, which shows what this head actually adds" >&2
      BASE_BRANCH=$DEFAULT
      BASE_BRANCH_FETCHED=true
      ;;
    "$FM_BASE_GONE")
      echo "warning: task $ID declares intended base $BASE_DECLARED, but that branch no longer exists on origin, so it cannot be the diff base; diffing against the default branch $DEFAULT instead, which shows everything this PR would land on $DEFAULT" >&2
      BASE_BRANCH=$DEFAULT
      ;;
    *)
      echo "warning: task $ID declares intended base $BASE_DECLARED, but whether it is still a live feature base could not be settled - $FM_BASE_LIVENESS_WHY; diffing against the default branch $DEFAULT instead, which shows everything this PR would land on $DEFAULT" >&2
      [ -z "$FM_BASE_LIVENESS_ERR" ] || printf '  git: %s\n' "$FM_BASE_LIVENESS_ERR" >&2
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
  if ! "$BASE_BRANCH_FETCHED"; then
    if ! FETCH_ERR=$(fetch_tracking_ref "$BASE_BRANCH"); then
      echo "error: cannot fetch base branch $BASE_BRANCH from origin for task $ID" >&2
      [ -z "$FETCH_ERR" ] || printf '  git: %s\n' "$FETCH_ERR" >&2
      exit 1
    fi
  fi
  BASE="origin/$BASE_BRANCH"
else
  BASE="$BASE_BRANCH"
fi

git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "error: base $BASE does not exist in $WT" >&2; exit 1; }

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
