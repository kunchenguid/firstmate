#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and local-only projects against the local default branch.
# When state/<id>.meta records pr= (URL or number) for an open PR, the compare
# side is ALWAYS a freshly fetched refs/pull/<n>/head by default so review stays
# current after no-mistakes fix rounds push to the PR. A recorded pr_head= is
# only a fallback when fetch fails (stale recorded SHAs must never win over a
# reachable remote PR head). If neither PR head can be resolved, fall back to
# the local branch with a warning. Without pr=, compare the local branch.
#
# A task whose workspace bin/fm-workspace.sh already released
# (workspace_state=released, worktree= cleared) has no local copy and needs none
# to be read: the review runs in the durable project clone without any checkout.
# The forge's current canonical PR identity is authoritative, because the head
# may have advanced and GitHub retargets an upper stacked PR once the branch
# below it merges. The helper reads the PR's current head commit, base branch,
# and base commit from the forge, requires the answer to be for the recorded
# pr= URL, fetches refs/pull/<n>/head and that base branch into
# refs/fm-review/<task-id>/, requires the fetched head to equal the forge head
# and the forge base commit to lie on the fetched base branch, then atomically
# refreshes the record's pr_head= and workspace_base= and reports any change.
# Unavailable identity, forge access, fetch, or hash proof refuses; nothing
# falls back to a local branch, because a released task has none.
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints only the stat summary; default prints stat summary plus full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
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
WORKSPACE_STATE=$(grep '^workspace_state=' "$META" | tail -1 | cut -d= -f2- || true)

print_diff() {  # <git-dir> <base-label> <base-ref> <compare-ref>
  echo "diff base: $2"
  if git -C "$1" diff --quiet "$3...$4" --; then
    echo "no changes vs $2"
    return 0
  fi
  git -C "$1" diff --stat "$3...$4" --
  if ! "$STAT_ONLY"; then
    echo
    git -C "$1" diff "$3...$4" --
  fi
}

META_LOCK=
META_LOCK_HELD=0
META_TMP=
released_cleanup() {
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  [ "$META_LOCK_HELD" != 1 ] || fm_lock_release "$META_LOCK" || true
}

# Publish the forge's current head and base as the record's durable proof. The
# pr= tail stays last (bin/fm-pr-lib.sh's identity parser accepts only PR-owned
# lines from pr= onward), so workspace_base goes before it and pr_head after it.
refresh_released_proof() {  # <pr-url> <head> <base>
  local pr_url=$1 head=$2 base=$3 line wrote_base=0
  META_LOCK=$(fm_meta_lock_path "$META") || { echo "error: cannot resolve the metadata lock for task $ID" >&2; exit 1; }
  fm_lock_acquire_wait "$META_LOCK" || { echo "error: cannot lock metadata for task $ID" >&2; exit 1; }
  META_LOCK_HELD=1
  [ "$(grep '^workspace_state=' "$META" | tail -1 | cut -d= -f2-)" = released ] \
    && [ "$(grep '^pr=' "$META" | tail -1 | cut -d= -f2-)" = "$pr_url" ] \
    || { echo "error: task $ID's record changed while its PR was being verified; rerun the review" >&2; exit 1; }
  META_TMP=$(mktemp "$STATE/.fm-review-meta.XXXXXX") || { echo "error: cannot stage metadata for task $ID" >&2; exit 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      workspace_base=*|pr_head=*) ;;
      pr=*)
        [ "$wrote_base" = 1 ] || printf 'workspace_base=%s\n' "$base"
        wrote_base=1
        printf '%s\npr_head=%s\n' "$line" "$head"
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$META" > "$META_TMP" || { echo "error: cannot stage metadata for task $ID" >&2; exit 1; }
  { chmod 0600 "$META_TMP" && mv -f -- "$META_TMP" "$META"; } \
    || { echo "error: cannot publish refreshed PR proof for task $ID" >&2; exit 1; }
  META_TMP=
  fm_lock_release "$META_LOCK" || true
  META_LOCK_HELD=0
}

review_released() {
  local pr_url recorded recorded_base row rest forge_state forge_head forge_base forge_base_oid forge_url
  local n head_ref base_ref fetched
  [ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
  [ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }
  pr_url=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
  recorded=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
  [ -n "$recorded" ] || recorded=$(grep '^workspace_head=' "$META" | tail -1 | cut -d= -f2- || true)
  recorded_base=$(grep '^workspace_base=' "$META" | tail -1 | cut -d= -f2- || true)
  fm_pr_url_parse "$pr_url" && [ "$FM_PR_PROVIDER" = github ] \
    || { echo "error: released task $ID records no canonical GitHub pull-request URL in pr=; cannot review without its workspace" >&2; exit 1; }
  pr_url=$FM_PR_URL
  n=$FM_PR_NUMBER
  git -C "$PROJ" remote get-url origin >/dev/null 2>&1 \
    || { echo "error: project $PROJ has no origin to fetch released task $ID's PR from" >&2; exit 1; }
  command -v gh >/dev/null 2>&1 \
    || { echo "error: gh is required to read released task $ID's current PR head and base; remote proof is unavailable" >&2; exit 1; }

  # The forge's current canonical identity is authoritative: a head may have
  # advanced, and GitHub retargets an upper stacked PR once the branch below it
  # merges, so neither the recorded head nor the recorded base is trusted.
  row=$(CDPATH='' cd -- "$PROJ" && gh pr view "$pr_url" \
    --json state,headRefOid,baseRefName,baseRefOid,url \
    -q '[.state,.headRefOid,.baseRefName,.baseRefOid,.url] | @tsv' 2>/dev/null) \
    || { echo "error: could not read PR #$n from the forge for released task $ID; remote proof is unavailable" >&2; exit 1; }
  forge_state=${row%%$'\t'*}; rest=${row#*$'\t'}
  forge_head=${rest%%$'\t'*}; rest=${rest#*$'\t'}
  forge_base=${rest%%$'\t'*}; rest=${rest#*$'\t'}
  forge_base_oid=${rest%%$'\t'*}
  forge_url=${rest#*$'\t'}
  [ "$forge_state" != "$row" ] && [ "$forge_url" != "$rest" ] \
    || { echo "error: the forge returned incomplete PR data for released task $ID" >&2; exit 1; }
  [ "$forge_url" = "$pr_url" ] \
    || { echo "error: the forge answered for $forge_url, not task $ID's recorded $pr_url; refusing to review another PR's identity" >&2; exit 1; }
  { fm_pr_head_valid "$forge_head" && fm_pr_head_valid "$forge_base_oid"; } \
    || { echo "error: the forge returned an invalid head or base commit for PR #$n" >&2; exit 1; }
  case "$forge_base" in ''|*[$'\n\r\t']*) echo "error: the forge returned no usable base branch for PR #$n" >&2; exit 1 ;; esac
  git -C "$PROJ" check-ref-format "refs/heads/$forge_base" >/dev/null 2>&1 \
    || { echo "error: the forge returned an invalid base branch for PR #$n: $forge_base" >&2; exit 1; }

  head_ref="refs/fm-review/$ID/head"
  base_ref="refs/fm-review/$ID/base"
  git -C "$PROJ" fetch --quiet origin "+refs/pull/$n/head:$head_ref" "+refs/heads/$forge_base:$base_ref" >/dev/null 2>&1 \
    || { echo "error: could not fetch PR #$n head and base branch $forge_base for released task $ID; remote proof is unavailable" >&2; exit 1; }
  fetched=$(git -C "$PROJ" rev-parse --verify "$head_ref^{commit}" 2>/dev/null) \
    || { echo "error: fetched PR #$n head for released task $ID is not a commit" >&2; exit 1; }
  [ "$fetched" = "$forge_head" ] || {
    echo "error: fetched PR #$n head $fetched does not match the forge's head $forge_head; the PR moved mid-read, rerun the review" >&2
    exit 1
  }
  # The base branch may have advanced past the commit the PR is measured
  # against; pin the ref to that exact forge-reported commit once it is proven
  # to be part of the fetched base branch.
  { git -C "$PROJ" cat-file -e "$forge_base_oid^{commit}" 2>/dev/null \
    && git -C "$PROJ" merge-base --is-ancestor "$forge_base_oid" "$base_ref" 2>/dev/null; } \
    || { echo "error: the forge's base commit $forge_base_oid for PR #$n is not on the fetched base branch $forge_base; refusing an unverifiable base" >&2; exit 1; }
  git -C "$PROJ" update-ref "$base_ref" "$forge_base_oid" \
    || { echo "error: could not pin the verified base commit for released task $ID" >&2; exit 1; }

  if [ -n "$recorded" ] && [ "$recorded" != "$forge_head" ]; then
    echo "changed: PR #$n head advanced from $recorded to $forge_head since it was recorded"
  fi
  if [ -n "$recorded_base" ] && [ "$recorded_base" != "$forge_base" ]; then
    echo "changed: PR #$n base was retargeted from $recorded_base to $forge_base"
  fi
  refresh_released_proof "$pr_url" "$forge_head" "$forge_base"
  print_diff "$PROJ" "origin/$forge_base (PR #$n base $forge_base_oid) at $forge_head" "$base_ref" "$head_ref"
}

if [ "$WORKSPACE_STATE" = released ] && [ -z "$WT" ]; then
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  trap released_cleanup EXIT
  review_released
  exit 0
fi
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
COMPARE_REF=$BRANCH
if [ -n "$PR_URL" ]; then
  if PR_HEAD=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
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

print_diff "$WT" "$BASE" "$BASE" "$COMPARE_REF"
