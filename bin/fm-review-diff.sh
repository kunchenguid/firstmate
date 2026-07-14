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
# WHICH BASE IS RIGHT IS NOT A QUESTION THIS SCRIPT ANSWERS. It resolves the base's state
# and the branch's rootedness and asks bin/fm-base-lib.sh's fm_base_verdict, the same one
# decision bin/fm-pr-check.sh's guard gates the merge on, so review and merge can never
# reach opposite conclusions from the same facts. Branch existence decides nothing here
# either; it only chooses which tip the predicates reason from.
#
#   STACKED_LIVE / STACKED_LANDED  the branch is rooted in the declared base - its fork
#     point is a commit the default branch cannot reach - so the base is where the branch
#     actually sits and it is the diff base. That stays true after the base MERGES: a
#     squash leaves the base's own commits out of the default branch by commit id, so a
#     branch still stacked on them still forks where it always did, and falling back to
#     the default branch would take the OLD fork point as the merge base and present the
#     base's already-merged work as the crewmate's change. When the base branch is gone
#     from origin, the tip recorded at spawn (base_sha=) is the diff base instead - it is
#     reachable from the branch under review, so the diff is still exactly this task's.
#   ORDINARY / UNSTACKED / ABANDONED_BASE  the branch is not rooted in the base any more,
#     so the default branch is its real fork point and the honest diff base: what the diff
#     then shows is everything the PR would land on the default branch, which is precisely
#     what firstmate needs to see. Warn and fall back rather than erroring out - deciding
#     whether that is safe is fm-pr-check.sh's job, not review's, and review must never be
#     blocked.
#   INDETERMINATE  origin could not be asked at all is an infrastructure failure: stop,
#     because reviewing silently against the wrong base is worse. Anything else
#     indeterminate falls back to the default branch with a warning.
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
BASE_SHA_DECLARED=$(grep '^base_sha=' "$META" | tail -1 | cut -d= -f2- || true)
if [ -n "$BASE_DECLARED" ] && ! fm_base_valid_branch_name "$BASE_DECLARED"; then
  echo "error: task $ID records base='$BASE_DECLARED', which is not a valid git branch name (it must be non-empty, free of whitespace, and must not begin with '-')" >&2
  exit 1
fi
if [ -n "$BASE_SHA_DECLARED" ] && ! fm_base_valid_commit_id "$BASE_SHA_DECLARED"; then
  echo "error: task $ID records base_sha='$BASE_SHA_DECLARED', which is not a git object id" >&2
  exit 1
fi
BASE_BRANCH=${BASE_DECLARED:-$DEFAULT}
# Set only when the diff base is a bare commit rather than a branch: the declared base is
# gone from origin, yet the branch under review is still rooted in it, so its recorded
# spawn-time tip is the only ref-less fork point there is - and the honest one.
BASE_REF_OVERRIDE=

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

# Which base is the honest one to diff against? Asked of fm_base_verdict, the same single
# decision bin/fm-pr-check.sh's guard gates the merge on, so review can never tell the
# captain a different story from the one the guard is about to enforce.
PREFETCHED=""
if [ -n "$BASE_DECLARED" ] && "$HAS_ORIGIN"; then
  STATE_RC=0
  fm_base_resolve_state "$WT" "$BASE_DECLARED" "$BASE_SHA_DECLARED" "$DEFAULT" || STATE_RC=$?
  if [ "$FM_BASE_STATE_WHY" = probe-failed ]; then
    # An origin that cannot be ASKED is an infrastructure failure, not a verdict.
    # Reviewing silently against the wrong base would be worse than stopping.
    echo "error: task $ID declares intended base $BASE_DECLARED, but origin could not be asked whether that branch still exists" >&2
    [ -z "$FM_BASE_STATE_ERR" ] || printf '  git: %s\n' "$FM_BASE_STATE_ERR" >&2
    exit 1
  fi
  COMPARE_SHA=$(git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}") \
    || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }
  ROOTED_RC=0
  if [ "$STATE_RC" -ne "$FM_BASE_STATE_UNKNOWN" ]; then
    PREFETCHED=" $DEFAULT "
    if "$FM_BASE_STATE_PRESENT"; then
      PREFETCHED=" $BASE_DECLARED$PREFETCHED"
    fi
    fm_base_head_rooted "$WT" "$FM_BASE_STATE_TIP" "$COMPARE_SHA" \
      "$FM_BASE_STATE_DEFAULT_SHA" || ROOTED_RC=$?
  fi
  VERDICT_RC=0
  fm_base_verdict "$STATE_RC" "$ROOTED_RC" || VERDICT_RC=$?

  if [ "$FM_BASE_STATE_PRESENT" = false ] && [ -n "$FM_BASE_STATE_TIP" ]; then
    echo "notice: task $ID declares intended base $BASE_DECLARED, but that branch no longer exists on origin; reasoning from the tip recorded at spawn ($FM_BASE_STATE_TIP)" >&2
  fi

  case "$VERDICT_RC" in
    "$FM_BASE_VERDICT_STACKED_LIVE")
      : # The declared base is the fork point and the diff base, exactly as declared.
      ;;
    "$FM_BASE_VERDICT_STACKED_LANDED")
      echo "warning: task $ID declares intended base $BASE_DECLARED, and that base has already merged - its work is carried by $DEFAULT ($FM_BASE_VERDICT_WHY) - but the branch under review is still rooted in the base's own pre-merge commits, so $BASE_DECLARED remains its real fork point and the diff below is taken against it; the head must be rebased onto $DEFAULT before this can merge, and bin/fm-pr-check.sh refuses it until then" >&2
      if [ "$FM_BASE_STATE_PRESENT" = false ]; then
        BASE_REF_OVERRIDE=$FM_BASE_STATE_TIP
        echo "  That branch is gone from origin, so the diff base is its recorded spawn-time tip $FM_BASE_STATE_TIP, which the branch under review still descends from." >&2
      fi
      ;;
    "$FM_BASE_VERDICT_ORDINARY")
      echo "warning: task $ID declares intended base $BASE_DECLARED, but that base has already merged - its work is carried by $DEFAULT ($FM_BASE_VERDICT_WHY), so it has no unmerged history left to subtract; diffing against the default branch $DEFAULT instead, so this shows everything the PR would land on $DEFAULT" >&2
      BASE_BRANCH=$DEFAULT
      ;;
    "$FM_BASE_VERDICT_ABANDONED_BASE")
      echo "warning: task $ID declares intended base $BASE_DECLARED, but that branch was deleted from origin WITHOUT merging; diffing against the default branch $DEFAULT instead, so this shows everything the PR would land on $DEFAULT - the abandoned base's own commits included. bin/fm-pr-check.sh refuses this PR before merge" >&2
      BASE_BRANCH=$DEFAULT
      ;;
    "$FM_BASE_VERDICT_INDETERMINATE")
      case "$FM_BASE_VERDICT_WHY" in
        gone-no-tip|gone-tip-unknown)
          echo "warning: task $ID declares intended base $BASE_DECLARED, but that branch no longer exists on origin and its spawn-time tip is not usable ($FM_BASE_VERDICT_WHY), so whether it merged or was abandoned cannot be told apart; diffing against the default branch $DEFAULT instead, so this shows everything the PR would land on $DEFAULT" >&2
          ;;
        *)
          echo "warning: task $ID declares intended base $BASE_DECLARED, but what became of that base could not be determined ($FM_BASE_VERDICT_WHY); diffing against the default branch $DEFAULT instead, so this shows everything the PR would land on $DEFAULT" >&2
          ;;
      esac
      BASE_BRANCH=$DEFAULT
      ;;
    *)  # UNSTACKED
      echo "warning: task $ID declares intended base $BASE_DECLARED, but the branch under review is not rooted in that base's unmerged history (the pipeline rebased it onto $DEFAULT); diffing against it would present every $DEFAULT commit since the base forked as part of the change, so diffing against the default branch $DEFAULT instead" >&2
      BASE_BRANCH=$DEFAULT
      ;;
  esac
fi

if [ -n "$BASE_REF_OVERRIDE" ]; then
  BASE="$BASE_REF_OVERRIDE"
elif "$HAS_ORIGIN"; then
  # fm_base_resolve_state already fetched the declared base (when it is still on origin)
  # and the default branch into their remote-tracking refs, and BASE_BRANCH is one of
  # them by then, so fetching again would just buy a second network round-trip.
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
