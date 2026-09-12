#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and local-only projects against the local landing base.
# When state/<id>.meta records base_branch=, that name is the compare base
# instead of the default; when the field is absent the default path is unchanged.
# When state/<id>.meta records pr= (URL or number) for an open PR, the compare
# side is ALWAYS a freshly fetched refs/pull/<n>/head by default so review stays
# current after no-mistakes fix rounds push to the PR. A recorded pr_head= is
# only a fallback when fetch fails (stale recorded SHAs must never win over a
# reachable remote PR head). If neither PR head can be resolved, fall back to
# the local branch with a warning. Without pr=, compare the local branch.
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints only the stat summary; default prints stat summary plus full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
"$FM_ROOT/bin/fm-guard.sh" || true
# shellcheck source=bin/fm-brief-contract-lib.sh
. "$SCRIPT_DIR/fm-brief-contract-lib.sh"

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

RECORDED_BASE=$(grep '^base_branch=' "$META" | tail -1 | cut -d= -f2- || true)
MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
if [ -n "$RECORDED_BASE" ]; then
  COMPARE_BASE=$RECORDED_BASE
else
  DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }
  COMPARE_BASE=$DEFAULT
fi

BRANCH="fm/$ID"
BRIEF="$DATA/$ID/brief.md"
if [ -f "$BRIEF" ]; then
  RECORDED_BRANCH=$(fm_brief_crew_branch "$BRIEF")
  [ -z "$RECORDED_BRANCH" ] || BRANCH=$RECORDED_BRANCH
fi
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 \
  || { echo "error: $BRIEF records an invalid crew branch: $BRANCH" >&2; exit 1; }
BRANCH_REF="refs/heads/$BRANCH"
git -C "$WT" rev-parse --verify --quiet "$BRANCH_REF" >/dev/null \
  || { echo "error: recorded crew branch $BRANCH does not exist in $WT" >&2; exit 1; }

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

fetch_pull_head() {
  local n=$1 resolved
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  # Fetch into a private ref so a later base-branch fetch cannot clobber the
  # compare tip via FETCH_HEAD, and so we never review a stale local object.
  git -C "$WT" fetch --quiet origin \
    "+refs/pull/$n/head:refs/fm-review/pull/$n/head" >/dev/null 2>&1 || return 1
  resolved=$(git -C "$WT" rev-parse --verify "refs/fm-review/pull/$n/head^{commit}" 2>/dev/null) || return 1
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
}

resolve_pr_head() {
  local pr_url=$1 recorded_head=$2 n resolved
  n=$(pr_number_from_target "$pr_url") || true
  if [ -n "$n" ]; then
    if resolved=$(fetch_pull_head "$n"); then
      printf '%s' "$resolved"
      return 0
    fi
  fi
  # Offline / unreachable remote: recorded pr_head is better than the local
  # branch, but never preferred over a successful pull-head fetch above.
  if [ -n "$recorded_head" ] \
    && git -C "$WT" cat-file -e "$recorded_head^{commit}" 2>/dev/null; then
    printf '%s' "$recorded_head"
    return 0
  fi
  return 1
}

PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
COMPARE_REF=$BRANCH_REF
if [ -n "$PR_URL" ]; then
  if PR_HEAD=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
    COMPARE_REF=$PR_HEAD
  else
    echo "warning: PR head unavailable; diff may lag the open PR (using local branch $BRANCH)" >&2
  fi
fi

USE_LOCAL_BASE=0
if [ "$MODE" = local-only ]; then
  USE_LOCAL_BASE=1
elif [ "$KIND" = scout ] && [ -n "$RECORDED_BASE" ] \
  && git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  REMOTE_BASE_STATUS=0
  git -C "$PROJ" ls-remote --exit-code --heads origin "refs/heads/$COMPARE_BASE" >/dev/null 2>&1 \
    || REMOTE_BASE_STATUS=$?
  case "$REMOTE_BASE_STATUS" in
    0) ;;
    2) USE_LOCAL_BASE=1 ;;
    *) echo "error: could not determine whether origin/$COMPARE_BASE exists for scout review" >&2; exit 1 ;;
  esac
fi
if [ "$USE_LOCAL_BASE" -eq 1 ]; then
  BASE="$COMPARE_BASE"
  BASE_REF="refs/heads/$COMPARE_BASE"
elif git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  # Update the remote-tracking ref itself; a bare single-branch fetch can leave
  # origin/<base> stale on some Git versions and only refresh FETCH_HEAD.
  git -C "$WT" fetch origin "+refs/heads/$COMPARE_BASE:refs/remotes/origin/$COMPARE_BASE" --quiet
  BASE="origin/$COMPARE_BASE"
  BASE_REF="refs/remotes/origin/$COMPARE_BASE"
else
  BASE="$COMPARE_BASE"
  BASE_REF="refs/heads/$COMPARE_BASE"
fi

git -C "$WT" rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null || { echo "error: base $BASE does not exist in $WT" >&2; exit 1; }
git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }

echo "diff base: $BASE"
if git -C "$WT" diff --quiet "$BASE_REF...$COMPARE_REF" --; then
  echo "no changes vs $BASE"
  exit 0
fi

git -C "$WT" diff --stat "$BASE_REF...$COMPARE_REF" --
if ! "$STAT_ONLY"; then
  echo
  git -C "$WT" diff "$BASE_REF...$COMPARE_REF" --
fi
