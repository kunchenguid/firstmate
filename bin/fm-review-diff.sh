#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<branch> after fetching
# it, and local-only projects against the local branch.
# The diff base is the repo default branch, unless state/<id>.meta records a
# non-default base= (a task whose intended base is a feature branch, declared
# with fm-spawn.sh --base): then it is that base, so review shows the crewmate's
# own change rather than the entire feature base's unmerged history on top of it.
#
# WHAT MAKES A DECLARED BASE THE RIGHT DIFF BASE IS THAT THE BRANCH UNDER REVIEW IS
# ACTUALLY ROOTED IN IT (fm_base_head_rooted) - that its fork point is a commit the
# default branch cannot reach. That is asked first, and it stays true even after the base
# merges: a squash merge leaves the base's own commits out of the default branch by
# commit id, so a branch still stacked on them still forks where it always did.
# Two ways the declared base stops being the right diff base, each falling back to the
# default branch with a warning rather than erroring out, so the review is never blocked:
#   - the base is gone from origin, so there is nothing to diff against;
#   - the branch under review is NOT rooted in it, because the pipeline rebased the
#     branch onto the default branch, or because the base ancestor-merged into it and
#     carries no history of its own any more. Diffing against the base would then take
#     the old fork point as the merge base and add every default-branch commit since -
#     the very misleading diff a declared base exists to prevent, in the other direction.
# A probe origin cannot answer at all still stops. bin/fm-base-lib.sh owns the shared
# rootedness and landedness predicates, which bin/fm-pr-check.sh's guard decides on
# too, so review and merge never disagree about what the declared base means.
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

# Update the remote-tracking ref itself; a bare single-branch fetch can leave
# origin/<branch> stale on some Git versions and only refresh FETCH_HEAD. The refspec
# is fully qualified so a dash-leading branch name cannot be read as an option.
fetch_origin_branch() {  # <branch>; echoes the fetched commit
  local branch=$1 err
  if ! err=$(git -C "$WT" fetch --quiet origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>&1); then
    echo "error: cannot fetch base branch $branch from origin for task $ID" >&2
    [ -z "$err" ] || printf '  git: %s\n' "$err" >&2
    return 1
  fi
  git -C "$WT" rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}"
}

# Is the declared base still a base worth diffing against? Falling back to the default
# branch is never a guess: it is the honest question at review time, since everything
# the diff then shows is what the merge would land on the default branch - the task's
# own change if the base merged, the abandoned base's commits too if it did not.
# Reviewing that is the point; deciding it is fm-pr-check.sh's job, and its guard
# refuses the second case. A probe origin could not answer is different: that is an
# infrastructure failure, and reviewing against the wrong base silently would be worse
# than stopping.
PREFETCHED=""
if [ -n "$BASE_DECLARED" ] && "$HAS_ORIGIN"; then
  PROBE_RC=0
  fm_base_probe_origin "$WT" "$BASE_DECLARED" || PROBE_RC=$?
  case "$PROBE_RC" in
    "$FM_BASE_ABSENT")
      echo "warning: task $ID declares intended base $BASE_DECLARED, but that branch no longer exists on origin; diffing against the default branch $DEFAULT instead, so this shows everything the PR would land on $DEFAULT" >&2
      BASE_BRANCH=$DEFAULT
      ;;
    "$FM_BASE_PROBE_FAILED")
      echo "error: task $ID declares intended base $BASE_DECLARED, but origin could not be asked whether that branch still exists" >&2
      [ -z "$FM_BASE_PROBE_ERR" ] || printf '  git: %s\n' "$FM_BASE_PROBE_ERR" >&2
      exit 1
      ;;
    *)
      BASE_SHA=$(fetch_origin_branch "$BASE_DECLARED") || exit 1
      DEFAULT_SHA=$(fetch_origin_branch "$DEFAULT") || exit 1
      PREFETCHED=" $BASE_DECLARED $DEFAULT "
      COMPARE_SHA=$(git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}") \
        || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }
      LANDED_RC=0
      fm_base_work_landed "$WT" "$BASE_SHA" "$DEFAULT_SHA" || LANDED_RC=$?
      ROOTED_RC=0
      fm_base_head_rooted "$WT" "$BASE_SHA" "$COMPARE_SHA" "$DEFAULT_SHA" || ROOTED_RC=$?
      if [ "$ROOTED_RC" -eq "$FM_BASE_HEAD_ROOTED" ]; then
        # The branch forks from a commit $DEFAULT cannot reach, so the base is where it
        # actually sits and the fork point is real. That stays true after the base
        # merges: a squash merge leaves the base's own commits out of $DEFAULT by commit
        # id, so falling back to $DEFAULT here would take the OLD fork point as the merge
        # base and show every one of the base's already-merged changes as part of this
        # task's - the very diff a declared base exists to prevent, in the other direction.
        if [ "$LANDED_RC" -eq "$FM_BASE_WORK_LANDED" ]; then
          echo "warning: task $ID declares intended base $BASE_DECLARED, and that base has already merged - its work is carried by $DEFAULT ($FM_BASE_WORK_HOW) - but the branch under review is still rooted in the base's own pre-merge commits, so $BASE_DECLARED remains its real fork point and the diff below is taken against it; the head must be rebased onto $DEFAULT before this can merge, and bin/fm-pr-check.sh refuses it until then" >&2
        fi
      elif [ "$LANDED_RC" -eq "$FM_BASE_WORK_LANDED" ]; then
        echo "warning: task $ID declares intended base $BASE_DECLARED, but that base has already merged - its work is carried by $DEFAULT ($FM_BASE_WORK_HOW), so it has no unmerged history left to subtract; diffing against the default branch $DEFAULT instead, so this shows everything the PR would land on $DEFAULT" >&2
        BASE_BRANCH=$DEFAULT
      else
        echo "warning: task $ID declares intended base $BASE_DECLARED, but the branch under review is not rooted in that base's unmerged history (the pipeline rebased it onto $DEFAULT); diffing against it would present every $DEFAULT commit since the base forked as part of the change, so diffing against the default branch $DEFAULT instead" >&2
        BASE_BRANCH=$DEFAULT
      fi
      ;;
  esac
fi

if "$HAS_ORIGIN"; then
  # The probe above already fetched the declared base and the default branch into
  # their remote-tracking refs, and BASE_BRANCH is always one of them by then, so
  # fetching again would just buy a second network round-trip for the same ref.
  case "$PREFETCHED" in
    *" $BASE_BRANCH "*) : ;;
    *) fetch_origin_branch "$BASE_BRANCH" >/dev/null || exit 1 ;;
  esac
  BASE="origin/$BASE_BRANCH"
else
  BASE="$BASE_BRANCH"
fi

git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "error: base $BASE does not exist in $WT" >&2; exit 1; }
git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }

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
