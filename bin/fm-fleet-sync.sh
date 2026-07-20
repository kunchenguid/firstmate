#!/usr/bin/env bash
# Refresh project clones: fast-forward the checked-out local default branch to
# origin/<default> when safe, and prune local branches whose upstream tracking
# branch is gone (the remote branch was deleted, i.e. its PR merged) and that no
# worktree still needs. Project entries that are symlinks are resolved first, so
# all git operations apply to the canonical target checkout.
# Skips local-only/no-origin projects, dirty clones, non-default checkouts,
# diverged branches, and fetch/fast-forward failures without forcing or stashing.
# Pruning never deletes the checked-out branch or a branch that still has a
# worktree, so it cannot discard unlanded work; set FM_FLEET_PRUNE=0 to disable it.
# By default every unsafe condition is a best-effort skip with a zero exit,
# matching bootstrap/fleet refresh behavior. --require-current is the fail-closed
# single-project form: it exits non-zero after any reported skip, so callers can
# refuse to use a clone whose currency could not be proven by this fetch.
# Usage: fm-fleet-sync.sh [--require-current] [<project-dir>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-fleet-sync.sh [--require-current] [<project-dir>]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
REQUIRE_CURRENT=0
if [ "${1:-}" = "--require-current" ]; then
  REQUIRE_CURRENT=1
  shift
fi
[ $# -le 1 ] || { usage; exit 1; }
[ "$REQUIRE_CURRENT" = 0 ] || [ $# -eq 1 ] || { usage; exit 1; }
SYNC_CURRENT=0

project_label() {
  case "$PROJ" in
    "$PROJECTS"/*) basename "$PROJ" ;;
    projects/*) basename "$PROJ" ;;
    *) printf '%s\n' "$PROJ" ;;
  esac
}

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

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

working_tree_status() {
  local rc=0
  STATUS_OUTPUT=$(git -C "$PROJ" status --porcelain 2>/dev/null) || rc=$?
  STATUS_ERR=
  if [ "$rc" != 0 ]; then
    STATUS_ERR=$(first_line "$(git -C "$PROJ" status --porcelain 2>&1 1>/dev/null || true)")
  fi
  return "$rc"
}

remote_default_snapshot() {
  REMOTE_HEAD_REF=
  REMOTE_HEAD_OID=
  REMOTE_HEAD_ERROR=
  if ! remote_head_output=$(git -C "$PROJ" ls-remote --symref origin HEAD 2>&1); then
    REMOTE_HEAD_ERROR=$(first_line "$remote_head_output")
    return 1
  fi
  REMOTE_HEAD_REF=$(printf '%s\n' "$remote_head_output" | awk '$1 == "ref:" && $3 == "HEAD" { print $2; exit }')
  REMOTE_HEAD_OID=$(printf '%s\n' "$remote_head_output" | awk '$2 == "HEAD" && $1 != "ref:" { print $1; exit }')
  case "$REMOTE_HEAD_REF" in refs/heads/*) : ;; *) REMOTE_HEAD_ERROR="origin HEAD is not a branch"; return 1 ;; esac
  case "$REMOTE_HEAD_OID" in ''|*[!0-9a-fA-F]*) REMOTE_HEAD_ERROR="origin HEAD has no valid commit"; return 1 ;; esac
  return 0
}

fetched_default_is_still_current() {
  local phase=$1
  if ! remote_default_snapshot; then
    reason="cannot verify origin default $phase"
    [ -z "$REMOTE_HEAD_ERROR" ] || reason="$reason: $REMOTE_HEAD_ERROR"
    echo "$label: skipped: $reason"
    return 1
  fi
  if [ "$REMOTE_HEAD_REF" != "$fetched_ref" ] || [ -z "$fetched_oid" ] || [ "$REMOTE_HEAD_OID" != "$fetched_oid" ]; then
    echo "$label: skipped: origin default changed $phase"
    return 1
  fi
  return 0
}

prune_gone_branches() {
  # Delete local branches whose upstream tracking branch is gone - the remote
  # branch was deleted, which in this fleet means its PR merged - as long as
  # nothing still needs them. Never the checked-out branch, and never a branch
  # that still has a worktree (a live or not-yet-torn-down task). "Gone" plus
  # "no worktree" already proves the work landed: teardown removes a branch's
  # worktree only after confirming the work reached the remote. We deliberately
  # do NOT also require the branch to be an ancestor of origin/<default> - PRs in
  # this fleet are squash-merged, so a merged branch is never an ancestor and
  # such a check would prune nothing. The no-worktree guard is the real safety
  # net. Set FM_FLEET_PRUNE=0 to skip pruning entirely.
  [ "${FM_FLEET_PRUNE:-1}" != "0" ] || return 0

  local worktree_branches current refline branch track
  worktree_branches=$(git -C "$PROJ" worktree list --porcelain 2>/dev/null \
    | sed -n 's#^branch refs/heads/##p')
  current=$(git -C "$PROJ" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

  while IFS= read -r refline; do
    branch=${refline%% *}
    track=${refline#* }
    [ "$track" = "[gone]" ] || continue
    [ -n "$branch" ] || continue
    [ "$branch" != "$current" ] || continue
    if printf '%s\n' "$worktree_branches" | grep -Fxq -- "$branch"; then
      continue
    fi
    if git -C "$PROJ" branch -D -- "$branch" >/dev/null 2>&1; then
      echo "$label: pruned $branch"
    fi
  done < <(git -C "$PROJ" for-each-ref \
    --format='%(refname:short) %(upstream:track)' refs/heads 2>/dev/null)
}

sync_project() {
  PROJ=$1
  label=$(project_label)
  SYNC_CURRENT=0

  if [ -L "$PROJ" ]; then
    if ! resolved=$(CDPATH='' cd -- "$PROJ" 2>/dev/null && pwd -P); then
      echo "$label: skipped: cannot resolve symlink target"
      return 0
    fi
    PROJ=$resolved
  fi

  if [ ! -d "$PROJ" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$PROJ" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi
  mode_line=$("$FM_ROOT/bin/fm-project-mode.sh" "$label" 2>/dev/null || echo "no-mistakes off")
  mode=${mode_line%% *}
  if [ "$mode" = "local-only" ]; then
    echo "$label: skipped: local-only project"
    return 0
  fi
  if ! git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
    echo "$label: skipped: no origin remote"
    return 0
  fi

  if [ "$REQUIRE_CURRENT" = 1 ]; then
    # Discover the server's advertised default independently of the clone's
    # possibly stale origin/HEAD and configured fetch refspec. Fetch that exact
    # branch into its remote-tracking ref without '+': a force-pushed/divergent
    # remote ref is an unsafe skip, never a forced update. Then query the server
    # again and require the fetched OID/default to match that later snapshot.
    if ! remote_default_snapshot; then
      reason="fetch failed"
      [ -z "$REMOTE_HEAD_ERROR" ] || reason="$reason: $REMOTE_HEAD_ERROR"
      echo "$label: skipped: $reason"
      return 0
    fi
    fetched_ref=$REMOTE_HEAD_REF
    DEFAULT=${fetched_ref#refs/heads/}
    fetch_refspec="$fetched_ref:refs/remotes/origin/$DEFAULT"
    if ! fetch_output=$(git -C "$PROJ" fetch origin --prune --quiet "$fetch_refspec" 2>&1); then
      reason="fetch failed"
      [ -z "$fetch_output" ] || reason="$reason: $(first_line "$fetch_output")"
      echo "$label: skipped: $reason"
      return 0
    fi
    if ! git -C "$PROJ" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$DEFAULT" 2>/dev/null; then
      echo "$label: skipped: cannot refresh origin/HEAD for $DEFAULT"
      return 0
    fi
    fetched_oid=$(git -C "$PROJ" rev-parse "refs/remotes/origin/$DEFAULT" 2>/dev/null || echo "")
    if ! fetched_default_is_still_current "during refresh"; then
      return 0
    fi
  else
    if ! fetch_output=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); then
      reason="fetch failed"
      if [ -n "$fetch_output" ]; then
        reason="$reason: $(first_line "$fetch_output")"
      fi
      echo "$label: skipped: $reason"
      return 0
    fi
  fi

  prune_gone_branches || true

  if [ "$REQUIRE_CURRENT" != 1 ]; then
    DEFAULT=$(default_branch) || {
      echo "$label: skipped: cannot determine default branch"
      return 0
    }
  fi
  BASE="origin/$DEFAULT"
  if ! git -C "$PROJ" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
    echo "$label: skipped: $BASE does not exist"
    return 0
  fi

  cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ "$cur" != "$DEFAULT" ]; then
    [ -n "$cur" ] || cur="detached HEAD"
    echo "$label: skipped: on $cur, expected $DEFAULT"
    return 0
  fi
  if ! working_tree_status; then
    reason="cannot read working tree status"
    [ -z "$STATUS_ERR" ] || reason="$reason: $STATUS_ERR"
    echo "$label: skipped: $reason"
    return 0
  fi
  if [ -n "$STATUS_OUTPUT" ]; then
    echo "$label: skipped: dirty working tree"
    return 0
  fi
  if ! git -C "$PROJ" rev-parse --verify --quiet "$DEFAULT^{commit}" >/dev/null; then
    echo "$label: skipped: local $DEFAULT does not exist"
    return 0
  fi

  local_rev=$(git -C "$PROJ" rev-parse "$DEFAULT") || {
    echo "$label: skipped: cannot read local $DEFAULT"
    return 0
  }
  remote_rev=$(git -C "$PROJ" rev-parse "$BASE") || {
    echo "$label: skipped: cannot read $BASE"
    return 0
  }
  if [ "$local_rev" = "$remote_rev" ]; then
    if [ "$REQUIRE_CURRENT" = 1 ] && ! fetched_default_is_still_current "before launch"; then
      return 0
    fi
    SYNC_CURRENT=1
    echo "$label: already current"
    return 0
  fi
  if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BASE"; then
    echo "$label: skipped: local $DEFAULT has diverged from $BASE"
    return 0
  fi

  before=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    echo "$label: skipped: cannot read local $DEFAULT"
    return 0
  }
  if ! merge_output=$(git -C "$PROJ" merge --ff-only "$BASE" 2>&1); then
    reason="fast-forward failed"
    if [ -n "$merge_output" ]; then
      reason="$reason: $(first_line "$merge_output")"
    fi
    echo "$label: skipped: $reason"
    return 0
  fi
  after=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    echo "$label: skipped: fast-forward completed but cannot read local $DEFAULT"
    return 0
  }
  if [ "$REQUIRE_CURRENT" = 1 ]; then
    post_cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
    post_local=$(git -C "$PROJ" rev-parse HEAD 2>/dev/null || echo "")
    post_remote=$(git -C "$PROJ" rev-parse "$BASE" 2>/dev/null || echo "")
    if ! working_tree_status; then
      reason="post-sync status failed"
      [ -z "$STATUS_ERR" ] || reason="$reason: $STATUS_ERR"
      echo "$label: skipped: $reason"
      return 0
    fi
    if [ "$post_cur" != "$DEFAULT" ] || [ -z "$post_local" ] || [ "$post_local" != "$post_remote" ] \
      || [ -n "$STATUS_OUTPUT" ]; then
      echo "$label: skipped: post-sync verification did not prove a clean $DEFAULT at $BASE"
      return 0
    fi
    if ! fetched_default_is_still_current "before launch"; then
      return 0
    fi
  fi
  SYNC_CURRENT=1
  echo "$label: synced $before..$after"
  return 0
}

if [ $# -eq 1 ]; then
  sync_project "$1"
  if [ "$REQUIRE_CURRENT" = 1 ] && [ "$SYNC_CURRENT" != 1 ]; then
    exit 1
  fi
  exit 0
fi

[ -d "$PROJECTS" ] || exit 0
for proj in "$PROJECTS"/*; do
  if [ -L "$proj" ]; then
    sync_project "$proj"
    continue
  fi
  [ -e "$proj" ] || continue
  [ -d "$proj" ] || continue
  sync_project "$proj"
done
