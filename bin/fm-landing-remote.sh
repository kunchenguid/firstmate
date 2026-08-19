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
# `upstream` is --upstream, sets `checkout.defaultRemote` and
# `remote.pushDefault` to `origin`, points `gh repo set-default` at `origin`
# when `gh` is on PATH, and re-inits no-mistakes without --fork-url when
# `no-mistakes` is on PATH so its PR target follows the new origin.
# It refuses to run inside a linked worktree: the remotes are shared with the
# primary checkout, so firstmate applies this on the primary and a worker
# must not.
# status prints the current origin, upstream, leftover fork remote, and gh
# default.
# verify exits 0 only when origin matches --ours; otherwise it exits 1 and
# names the remote it actually found.
#
# URL comparison is spelling-tolerant for the GitHub https / ssh / trailing
# .git forms. apply is idempotent when origin is already --ours.
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
# A linked worktree has a `.git` file, not a directory; that signal is older
# and more portable than --absolute-git-common-dir.
require_primary_checkout() {
  if [ -f "$REPO/.git" ]; then
    fail "refusing to rewrite remotes from a linked worktree; run this on the primary checkout"
  fi
}

remote_url() {
  git -C "$REPO" remote get-url "$1" 2>/dev/null || true
}

remote_exists() {
  git -C "$REPO" remote get-url "$1" >/dev/null 2>&1
}

fix_default_branch_tracking() {
  local branch
  for branch in main master; do
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$REPO" config "branch.${branch}.remote" origin
      git -C "$REPO" config "branch.${branch}.merge" "refs/heads/${branch}"
    fi
  done
}

set_default_git_and_gh() {
  git -C "$REPO" config checkout.defaultRemote origin
  git -C "$REPO" config remote.pushDefault origin
  if command -v gh >/dev/null 2>&1; then
    if ! ( cd "$REPO" && gh repo set-default origin >/dev/null 2>&1 ); then
      echo "warning: gh repo set-default origin failed; origin is still the landing remote for git" >&2
    fi
  else
    echo "warning: gh is not on PATH; git origin is the landing remote, but gh has no default repo" >&2
  fi
}

refresh_no_mistakes() {
  if ! command -v no-mistakes >/dev/null 2>&1; then
    echo "warning: no-mistakes is not on PATH; after origin points at the landing remote, run: no-mistakes --yes init" >&2
    return 0
  fi
  if ! ( cd "$REPO" && no-mistakes --yes init ); then
    echo "warning: no-mistakes --yes init failed; firstmate must run it on the primary so PRs open on origin" >&2
  fi
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
  local origin fork_url upstream_url
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

  if urls_equal "$origin" "$OURS"; then
    if [ -z "$upstream_url" ]; then
      git -C "$REPO" remote add upstream "$UPSTREAM"
    fi
    if [ -n "$fork_url" ] && urls_equal "$fork_url" "$OURS"; then
      git -C "$REPO" remote remove fork
    fi
    fix_default_branch_tracking
    set_default_git_and_gh
    refresh_no_mistakes
    echo "landing-remote: origin already points at the landing remote"
    cmd_status
    return 0
  fi

  if ! urls_equal "$origin" "$UPSTREAM"; then
    fail "origin is $origin, which is neither --ours $OURS nor --upstream $UPSTREAM; refusing to guess"
  fi

  if [ -z "$upstream_url" ]; then
    git -C "$REPO" remote rename origin upstream
    if [ -n "$fork_url" ]; then
      git -C "$REPO" remote rename fork origin
    else
      git -C "$REPO" remote add origin "$OURS"
      git -C "$REPO" fetch --quiet origin || \
        echo "warning: fetched nothing from the new origin; tracking refs may be empty until a later fetch" >&2
    fi
  else
    git -C "$REPO" remote set-url origin "$OURS"
    if [ -n "$fork_url" ] && urls_equal "$fork_url" "$OURS"; then
      git -C "$REPO" remote remove fork
    fi
  fi

  fix_default_branch_tracking
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
