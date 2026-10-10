#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and local-only projects against the local default branch.
# A task whose meta records base_branch= (bin/fm-spawn.sh) compares against
# origin/<base_branch> instead of the default branch.
# When state/<id>.meta records pr= as a GitHub pull-request or GitLab
# merge-request URL (or a bare number for an open GitHub PR), the compare side is
# ALWAYS a freshly fetched forge head ref by default - refs/pull/<n>/head on
# GitHub, refs/merge-requests/<n>/head on GitLab - so review stays current after
# no-mistakes fix rounds push to the request, and on GitLab after the source
# branch itself is deleted, because the merge request's own head ref survives
# that. A recorded pr_head= is only a fallback when fetch fails (stale recorded
# SHAs must never win over a reachable remote head). If neither forge head can be
# resolved, fall back to the local branch with a warning; a Gerrit change exposes
# no comparable ref and records no pr_head, so a task recording one always takes
# that warning path, and docs/architecture.md owns that fallback. Without pr=,
# compare the task's immutable ship branch recorded in state/<id>.meta
# ("fm/<id>" for records created before that field existed), or the worktree's
# checked-out branch when that branch does not exist in the worktree. A recorded
# branch that is not a valid git branch name is refused instead of taking that
# fallback, the same refusal fm-merge-local.sh applies, so a corrupt meta record
# can never turn a review into a diff of the wrong content.
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints only the stat summary; default prints stat summary plus full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

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

DEFAULT=$(grep '^base_branch=' "$META" | cut -d= -f2- || true)
[ -n "$DEFAULT" ] || DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi
if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  WANT=$BRANCH
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: ship branch $WANT does not exist and worktree $WT is detached" >&2; exit 1; }
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

# The provider whose head ref the recorded pr= names, and that ref's number.
# Validation is bin/fm-pr-lib.sh's, the one owner of the canonical URL shapes;
# a target it refuses keeps the legacy GitHub-only reading, so a bare number and
# an enterprise pull-request URL still resolve exactly as before. A Gerrit URL
# parses but publishes no head ref, so it resolves to nothing and takes the
# warning path below.
pr_target_provider() {  # <target>
  local target=$1 n
  if fm_pr_url_parse "$target" 2>/dev/null; then
    case "$FM_PR_PROVIDER" in
      github|gitlab)
        printf '%s %s' "$FM_PR_PROVIDER" "$FM_PR_NUMBER"
        return 0
        ;;
      *) return 1 ;;
    esac
  fi
  n=$(pr_number_from_target "$target") || return 1
  printf 'github %s' "$n"
}

# Fetch the forge's current head ref into a private review ref and print the
# commit it resolves to, or fail. The fetch names the remote explicitly, so
# nothing depends on the caller's directory, and the private ref keeps a later
# base-branch fetch from clobbering the compare tip via FETCH_HEAD, so a stale
# local object is never reviewed. The ref must resolve to a commit: a ref that
# exists but names no commit object is treated as unavailable rather than
# compared against.
fetch_forge_head() {  # <provider> <number>
  local provider=$1 n=$2 ref dst resolved
  ref=$(fm_pr_forge_head_ref "$provider" "$n") || return 1
  case "$provider" in
    github) dst="refs/fm-review/pull/$n/head" ;;
    gitlab) dst="refs/fm-review/mr/$n/head" ;;
    *) return 1 ;;
  esac
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "+$ref:$dst" >/dev/null 2>&1 || return 1
  resolved=$(git -C "$WT" rev-parse --verify "$dst^{commit}" 2>/dev/null) || return 1
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
}

resolve_pr_head() {
  local provider=$1 n=$2 recorded_head=$3 resolved
  if resolved=$(fetch_forge_head "$provider" "$n"); then
    printf '%s' "$resolved"
    return 0
  fi
  # Offline / unreachable remote: recorded pr_head is better than the local
  # branch, but never preferred over a successful forge-head fetch above.
  if [ -n "$recorded_head" ] \
    && git -C "$WT" cat-file -e "$recorded_head^{commit}" 2>/dev/null; then
    printf '%s' "$recorded_head"
    return 0
  fi
  return 1
}

PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
COMPARE_REF=$BRANCH
if [ -n "$PR_URL" ]; then
  if PR_TARGET=$(pr_target_provider "$PR_URL") \
    && PR_HEAD=$(resolve_pr_head "${PR_TARGET%% *}" "${PR_TARGET#* }" "$PR_HEAD_RECORDED"); then
    COMPARE_REF=$PR_HEAD
  else
    echo "warning: PR head unavailable; diff may lag the open PR (using local branch $BRANCH)" >&2
  fi
fi

if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  # Update the remote-tracking ref itself; a bare single-branch fetch can leave
  # origin/<default> stale on some Git versions and only refresh FETCH_HEAD.
  git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
  BASE="origin/$DEFAULT"
else
  BASE="$DEFAULT"
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
