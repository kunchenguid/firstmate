#!/usr/bin/env bash
# Point a clone's `origin` at the repository work lands on, and name the
# third-party parent `upstream`.
#
# Git, `gh`, and `no-mistakes` all default to `origin`. When `origin` is the
# parent we forked from, a worker doing the obvious thing branches from the
# parent's tip, opens a PR on the parent, and waits on the parent's CI.
# This script is the one owner of the remapping that makes the careless path
# land on our tree instead.
#
# Usage:
#   fm-landing-remote.sh apply --ours <url> --upstream <url> [--repo <dir>]
#   fm-landing-remote.sh status [--repo <dir>]
#   fm-landing-remote.sh verify --ours <url> [--repo <dir>]
#
# apply rewrites remotes in the named checkout so `origin` is --ours and
# `upstream` is --upstream, refetches `origin` so its remote-tracking refs stop
# holding the previous remote's tips, repoints every local branch that tracked
# `origin` back at `origin`, sets `checkout.defaultRemote` and
# `remote.pushDefault` to `origin`, points `gh repo set-default` at `origin`
# when `gh` is on PATH, and re-inits no-mistakes without --fork-url when
# `no-mistakes` is on PATH so its PR target follows the new origin.
# apply has one outcome: it exits 0 only when every one of those steps
# succeeded. Everything that can refuse runs before anything is written, and a
# refetch that fails after the rewrite restores the remotes it found, so a
# failed apply leaves the checkout exactly as it was and can be re-run.
# It refuses to run inside a linked worktree: the remotes are shared with the
# primary checkout, so firstmate applies this on the primary and a worker
# must not.
# status prints the current origin, upstream, leftover fork remote, and gh
# default.
# verify exits 0 only when origin matches --ours; otherwise it exits 1 and
# names the remote it actually found.
#
# URL comparison is spelling-tolerant for the GitHub https / ssh / trailing
# .git forms. apply is idempotent when origin is already --ours, and that path
# needs no network: reachability and refetch belong to the remap only.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  echo "error: $*" >&2
  exit 1
}

canonical_dir() {
  local target=$1
  ( cd "$target" 2>/dev/null && pwd -P ) || printf '%s\n' "$target"
}

# Collapse GitHub https / ssh / trailing-.git spellings so a stored remote
# matches the URL the caller passed. Other forges keep their scheme and host.
normalize_remote_url() {
  local url=$1
  url=${url%.git}
  url=${url%/}
  case $url in
    git@github.com:*)
      url=https://github.com/${url#git@github.com:}
      ;;
    ssh://git@github.com/*)
      url=https://github.com/${url#ssh://git@github.com/}
      ;;
  esac
  printf '%s\n' "$url"
}

urls_equal() {
  [ "$(normalize_remote_url "$1")" = "$(normalize_remote_url "$2")" ]
}

require_repo() {
  git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "'$REPO' is not a git work tree"
}

# Linked worktrees share remotes with the primary. apply must run against the
# primary checkout so a worker cannot silently retarget the fleet's remotes.
# The `.git`-is-a-file signal only exists at a worktree's top level, so a --repo
# pointing at any subdirectory of a linked worktree would slip past it. Compare
# the per-worktree git dir against the shared common dir instead: they differ
# for a linked worktree from any depth, and match in the primary.
require_primary_checkout() {
  local git_dir common_dir
  git_dir=$( cd "$REPO" && d=$(git rev-parse --git-dir) && cd "$d" && pwd -P ) || git_dir=
  common_dir=$( cd "$REPO" && d=$(git rev-parse --git-common-dir) && cd "$d" && pwd -P ) || common_dir=
  if [ -z "$git_dir" ] || [ -z "$common_dir" ]; then
    fail "could not resolve the git directory of '$REPO'; refusing to rewrite remotes"
  fi
  if [ "$git_dir" != "$common_dir" ]; then
    fail "refusing to rewrite remotes from a linked worktree; run this on the primary checkout"
  fi
}

remote_url() {
  git -C "$REPO" remote get-url "$1" 2>/dev/null || true
}

remote_exists() {
  git -C "$REPO" remote get-url "$1" >/dev/null 2>&1
}

# `git remote rename origin upstream` rewrites branch.<name>.remote for every
# local branch that tracked origin, so after the remap those branches pull from
# the third-party parent. Record them before anything moves and repoint them
# afterwards. Which branches actually track origin is a fact of the repository,
# never a main/master guess: the fleet already runs projects whose default
# branch is neither.
branches_tracking_origin() {
  local branch remote
  git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads \
  | while IFS= read -r branch; do
      remote=$(git -C "$REPO" config --get "branch.${branch}.remote" 2>/dev/null || true)
      if [ "$remote" = origin ]; then
        printf '%s\n' "$branch"
      fi
    done
  return 0
}

restore_origin_branch_tracking() {  # <newline-separated branch names>
  local branch
  [ -n "$1" ] || return 0
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    git -C "$REPO" config "branch.${branch}.remote" origin
  done <<TRACKED
$1
TRACKED
}

# Reachability is checked before the first write so an unreachable or mistyped
# --ours refuses while the checkout is still untouched and still re-appliable.
require_landing_remote_reachable() {
  git -C "$REPO" ls-remote --quiet "$OURS" >/dev/null 2>&1 \
    || fail "cannot reach --ours $OURS; nothing was changed, so re-run apply once the landing remote is reachable"
}

# Every remap leaves refs/remotes/origin/* holding whatever the previous origin
# published. Until they are refetched, `origin/<default>` still resolves to the
# parent's tip, so a careless checkout or a base-freshness read would keep
# taking upstream work from a remote that now claims to be ours. The caller
# treats a failure here as a failed apply and restores the remotes.
refresh_origin_tracking() {
  git -C "$REPO" fetch --prune --quiet origin || return 1
  git -C "$REPO" remote set-head origin --auto >/dev/null 2>&1 || return 1
}

# Put back exactly what the remap moved, so a refetch that fails after the
# rewrite is indistinguishable from an apply that never ran.
undo_remap() {  # <shape> <previous origin url> <previous fork url>
  case $1 in
    renamed-fork)
      git -C "$REPO" remote rename origin fork
      git -C "$REPO" remote rename upstream origin
      ;;
    added-origin)
      git -C "$REPO" remote remove origin
      git -C "$REPO" remote rename upstream origin
      ;;
    reurled-origin)
      git -C "$REPO" remote set-url origin "$2"
      [ -z "$3" ] || git -C "$REPO" remote add fork "$3"
      ;;
  esac
}

# gh ranks the remote named `upstream` above `origin` when no default repo is
# recorded, so after this remap both remotes exist and an unset gh default sends
# a flagless `gh pr create` to the third-party parent. That is the exact defect
# this script exists to kill, so a gh that is present but did not take the
# default is a failed apply, not a warning over a green exit code.
set_default_git_and_gh() {
  local recorded
  git -C "$REPO" config checkout.defaultRemote origin
  git -C "$REPO" config remote.pushDefault origin
  if ! command -v gh >/dev/null 2>&1; then
    echo "warning: gh is not on PATH; git origin is the landing remote, but gh has no default repo, so run 'gh repo set-default origin' once gh is installed" >&2
    return 0
  fi
  ( cd "$REPO" && gh repo set-default origin >/dev/null 2>&1 ) \
    || fail "gh repo set-default origin failed; with no gh default and both origin and upstream present, gh ranks upstream above origin, so a flagless 'gh pr create' can still open the PR on the third-party parent. git's origin is already the landing remote, so re-run apply once gh can record the default"
  recorded=$(cd "$REPO" && gh repo set-default --view 2>/dev/null || true)
  [ -n "$recorded" ] \
    || fail "gh recorded no default repository; with no gh default and both origin and upstream present, gh ranks upstream above origin, so a flagless 'gh pr create' can still open the PR on the third-party parent. git's origin is already the landing remote, so re-run apply once gh can record the default"
}

refresh_no_mistakes() {
  if ! command -v no-mistakes >/dev/null 2>&1; then
    echo "warning: no-mistakes is not on PATH; after origin points at the landing remote, run: no-mistakes --yes init" >&2
    return 0
  fi
  ( cd "$REPO" && no-mistakes --yes init ) \
    || fail "no-mistakes --yes init failed, so its stored PR target still names the previous remote and the pipeline would open PRs there; git's origin is already the landing remote, so re-run apply once init can succeed"
}

cmd_status() {
  local origin upstream fork_url gh_default
  require_repo
  origin=$(remote_url origin)
  upstream=$(remote_url upstream)
  fork_url=$(remote_url fork)
  gh_default=
  if command -v gh >/dev/null 2>&1; then
    gh_default=$(cd "$REPO" && gh repo set-default --view 2>/dev/null || true)
  fi
  printf 'origin=%s\n' "${origin:-absent}"
  printf 'upstream=%s\n' "${upstream:-absent}"
  printf 'fork=%s\n' "${fork_url:-absent}"
  printf 'gh-default=%s\n' "${gh_default:-absent}"
}

cmd_verify() {
  local origin
  [ -n "$OURS" ] || fail "verify requires --ours <url>"
  require_repo
  origin=$(remote_url origin)
  [ -n "$origin" ] || fail "origin remote is absent"
  if urls_equal "$origin" "$OURS"; then
    printf 'origin=%s\n' "$origin"
    return 0
  fi
  echo "origin is $origin, not the landing remote $OURS" >&2
  exit 1
}

cmd_apply() {
  local origin fork_url upstream_url tracked shape
  [ -n "$OURS" ] || fail "apply requires --ours <url>"
  [ -n "$UPSTREAM" ] || fail "apply requires --upstream <url>"
  if urls_equal "$OURS" "$UPSTREAM"; then
    fail "--ours and --upstream must be different remotes"
  fi
  require_repo
  require_primary_checkout

  origin=$(remote_url origin)
  [ -n "$origin" ] || fail "origin remote is absent"
  fork_url=$(remote_url fork)
  upstream_url=$(remote_url upstream)

  if [ -n "$upstream_url" ] && ! urls_equal "$upstream_url" "$UPSTREAM"; then
    fail "upstream remote already exists at $upstream_url, not --upstream $UPSTREAM"
  fi
  if [ -n "$fork_url" ] && ! urls_equal "$fork_url" "$OURS"; then
    fail "fork remote exists at $fork_url, not --ours $OURS"
  fi
  if ! urls_equal "$origin" "$OURS" && ! urls_equal "$origin" "$UPSTREAM"; then
    fail "origin is $origin, which is neither --ours $OURS nor --upstream $UPSTREAM; refusing to guess"
  fi

  tracked=$(branches_tracking_origin)

  if urls_equal "$origin" "$OURS"; then
    if [ -z "$upstream_url" ]; then
      git -C "$REPO" remote add upstream "$UPSTREAM"
    fi
    if [ -n "$fork_url" ]; then
      git -C "$REPO" remote remove fork
    fi
    restore_origin_branch_tracking "$tracked"
    set_default_git_and_gh
    refresh_no_mistakes
    echo "landing-remote: origin already points at the landing remote"
    cmd_status
    return 0
  fi

  require_landing_remote_reachable

  if [ -z "$upstream_url" ]; then
    git -C "$REPO" remote rename origin upstream
    if [ -n "$fork_url" ]; then
      git -C "$REPO" remote rename fork origin
      shape=renamed-fork
    else
      git -C "$REPO" remote add origin "$OURS"
      shape=added-origin
    fi
  else
    git -C "$REPO" remote set-url origin "$OURS"
    if [ -n "$fork_url" ]; then
      git -C "$REPO" remote remove fork
    fi
    shape=reurled-origin
  fi

  if ! refresh_origin_tracking; then
    undo_remap "$shape" "$origin" "$fork_url" \
      || echo "warning: could not restore the remotes this apply rewrote; run fm-landing-remote.sh status and repair them by hand" >&2
    fail "could not fetch $OURS after the remap, so origin's tracking refs would still name the previous remote; the remotes were restored, so re-run apply once the landing remote is reachable"
  fi

  restore_origin_branch_tracking "$tracked"
  set_default_git_and_gh
  refresh_no_mistakes
  echo "landing-remote: origin now points at the landing remote"
  cmd_status
}

REPO=.
OURS=
UPSTREAM=
CMD=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    apply|status|verify)
      [ -z "$CMD" ] || fail "only one command is allowed"
      CMD=$1
      shift
      ;;
    --ours)
      [ $# -ge 2 ] || fail "--ours requires a URL"
      OURS=$2
      shift 2
      ;;
    --upstream)
      [ $# -ge 2 ] || fail "--upstream requires a URL"
      UPSTREAM=$2
      shift 2
      ;;
    --repo)
      [ $# -ge 2 ] || fail "--repo requires a directory"
      REPO=$2
      shift 2
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[ -n "$CMD" ] || fail "usage: fm-landing-remote.sh apply|status|verify [options]"
REPO=$(canonical_dir "$REPO")

case "$CMD" in
  apply) cmd_apply ;;
  status) cmd_status ;;
  verify) cmd_verify ;;
esac
