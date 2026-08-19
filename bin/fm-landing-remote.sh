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
# `origin` or `fork` at `origin`, sets `checkout.defaultRemote` and
# `remote.pushDefault` to `origin`, points `gh repo set-default` at `origin`
# when `gh` is on PATH, and re-inits no-mistakes without --fork-url when
# `no-mistakes` is on PATH so its PR target follows the new origin.
# apply has one outcome: it exits 0 only when every one of those steps
# succeeded. Everything that can refuse runs before anything is written, and
# every later failure - the refetch, the gh default, the no-mistakes re-init -
# restores the remotes, the branch tracking, and the git defaults it found, so
# a failed apply leaves the checkout as it was and can be re-run.
# Restoring cannot recreate remote-tracking refs that a fetch replaced or that
# `git remote remove` deleted, so it refetches the remotes it puts back and
# leaves those refs holding the landing remote's tips when it cannot reach them.
# It refuses to run inside a linked worktree: the remotes are shared with the
# primary checkout, so firstmate applies this on the primary and a worker
# must not.
# status prints the current origin, upstream, leftover fork remote, and the gh
# default gh recorded locally in `remote.origin.gh-resolved`; it needs no
# network.
# verify exits 0 only when origin matches --ours; otherwise it exits 1 and
# names the remote it actually found.
#
# URL comparison is spelling-tolerant for the GitHub https / ssh / trailing
# .git forms. apply is a no-op, and touches the network not at all, once origin,
# upstream, the git defaults, and the gh default are all in place already.
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

git_config_get() {  # <key>
  git -C "$REPO" config --get "$1" 2>/dev/null || true
}

# `gh repo set-default` records its choice locally, in `remote.<name>.gh-resolved`,
# so whether origin is already gh's default is readable with no network.
gh_default_is_origin() {
  command -v gh >/dev/null 2>&1 || return 0
  [ "$(git_config_get remote.origin.gh-resolved)" = base ]
}

# `git remote rename` rewrites branch.<name>.remote for every branch that
# tracked the renamed remote, and `git remote remove` deletes that branch's
# `remote` and `merge` keys outright. Capture every branch's tracking pair
# before the first write: the same record repoints branches at the surviving
# origin on success and puts them back verbatim on a failed apply. Which
# branches track what is a fact of the repository, never a main/master guess.
capture_branch_tracking() {
  local branch remote merge
  git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads \
  | while IFS= read -r branch; do
      remote=$(git -C "$REPO" config --get "branch.${branch}.remote" 2>/dev/null || true)
      [ -n "$remote" ] || continue
      merge=$(git -C "$REPO" config --get "branch.${branch}.merge" 2>/dev/null || true)
      printf '%s\t%s\t%s\n' "$branch" "$remote" "$merge"
    done
  return 0
}

# `fork` and `origin` both named the landing remote before the remap, because
# apply refuses a fork whose URL is not --ours, so a branch that tracked either
# one must still track the landing remote under its one surviving name.
repoint_landing_branch_tracking() {  # <captured tracking>
  local branch remote merge
  [ -n "$1" ] || return 0
  while IFS="$(printf '\t')" read -r branch remote merge; do
    [ -n "$branch" ] || continue
    case $remote in
      origin|fork) ;;
      *) continue ;;
    esac
    git -C "$REPO" config "branch.${branch}.remote" origin
    if [ -n "$merge" ]; then
      git -C "$REPO" config "branch.${branch}.merge" "$merge"
    fi
  done <<TRACKED
$1
TRACKED
}

restore_captured_branch_tracking() {  # <captured tracking>
  local branch remote merge
  [ -n "$1" ] || return 0
  while IFS="$(printf '\t')" read -r branch remote merge; do
    [ -n "$branch" ] || continue
    git -C "$REPO" config "branch.${branch}.remote" "$remote"
    if [ -n "$merge" ]; then
      git -C "$REPO" config "branch.${branch}.merge" "$merge"
    fi
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

# Put the checkout back the way apply found it. The two rename shapes invert
# exactly, refs included. The rewrite shapes cannot recreate remote-tracking
# refs a later fetch replaced or `git remote remove` deleted, so they refetch
# what they put back and leave those refs holding the landing remote's tips
# when the network they are being restored because of is still down.
restore_pre_apply_remotes() {
  case $REMAP_SHAPE in
    renamed-fork)
      git -C "$REPO" remote rename origin fork || return 1
      git -C "$REPO" remote rename upstream origin || return 1
      ;;
    added-origin)
      git -C "$REPO" remote remove origin || return 1
      git -C "$REPO" remote rename upstream origin || return 1
      ;;
    reurled-origin|tidied-remotes)
      git -C "$REPO" remote set-url origin "$ORIGIN_BEFORE" || return 1
      if [ -z "$UPSTREAM_BEFORE" ] && remote_exists upstream; then
        git -C "$REPO" remote remove upstream || return 1
      fi
      if [ -n "$FORK_BEFORE" ] && ! remote_exists fork; then
        git -C "$REPO" remote add fork "$FORK_BEFORE" || return 1
        git -C "$REPO" fetch --prune --quiet fork || true
      fi
      if [ "$REMAP_SHAPE" = reurled-origin ]; then
        git -C "$REPO" fetch --prune --quiet origin || true
      fi
      ;;
  esac
  return 0
}

restore_git_default_config() {
  if [ -n "$DEFAULT_REMOTE_BEFORE" ]; then
    git -C "$REPO" config checkout.defaultRemote "$DEFAULT_REMOTE_BEFORE"
  else
    git -C "$REPO" config --unset checkout.defaultRemote 2>/dev/null || true
  fi
  if [ -n "$PUSH_DEFAULT_BEFORE" ]; then
    git -C "$REPO" config remote.pushDefault "$PUSH_DEFAULT_BEFORE"
  else
    git -C "$REPO" config --unset remote.pushDefault 2>/dev/null || true
  fi
  return 0
}

restore_pre_apply_state() {
  restore_pre_apply_remotes \
    || echo "warning: could not restore the remotes this apply rewrote; run fm-landing-remote.sh status and repair them by hand" >&2
  restore_captured_branch_tracking "$TRACKING_BEFORE"
  restore_git_default_config
  return 0
}

# gh ranks the remote named `upstream` above `origin` when no default repo is
# recorded, so after this remap both remotes exist and an unset gh default sends
# a flagless `gh pr create` to the third-party parent. That is the exact defect
# this script exists to kill, so a gh that is present but did not take the
# default is a failed apply, not a warning over a green exit code.
record_gh_default() {
  local recorded
  if ! command -v gh >/dev/null 2>&1; then
    echo "warning: gh is not on PATH; git origin is the landing remote, but gh has no default repo, so run 'gh repo set-default origin' once gh is installed" >&2
    return 0
  fi
  if ! ( cd "$REPO" && gh repo set-default origin >/dev/null 2>&1 ); then
    echo "warning: gh repo set-default origin exited non-zero" >&2
    return 1
  fi
  recorded=$(cd "$REPO" && gh repo set-default --view 2>/dev/null || true)
  if [ -z "$recorded" ]; then
    echo "warning: gh recorded no default repository" >&2
    return 1
  fi
  return 0
}

refresh_no_mistakes() {
  if ! command -v no-mistakes >/dev/null 2>&1; then
    echo "warning: no-mistakes is not on PATH; after origin points at the landing remote, run: no-mistakes --yes init" >&2
    return 0
  fi
  ( cd "$REPO" && no-mistakes --yes init ) || return 1
}

cmd_status() {
  local origin upstream fork_url gh_default
  require_repo
  origin=$(remote_url origin)
  upstream=$(remote_url upstream)
  fork_url=$(remote_url fork)
  gh_default=$(git_config_get remote.origin.gh-resolved)
  case $gh_default in
    base) gh_default=origin ;;
  esac
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

# Nothing to change means nothing to run: no reachability probe, no fetch, no
# gh, no no-mistakes. A correctly remapped primary must apply with the network
# down, so every network step stays behind a decision to change something.
apply_has_nothing_to_change() {
  urls_equal "$ORIGIN_BEFORE" "$OURS" || return 1
  [ -n "$UPSTREAM_BEFORE" ] || return 1
  [ -z "$FORK_BEFORE" ] || return 1
  [ "$DEFAULT_REMOTE_BEFORE" = origin ] || return 1
  [ "$PUSH_DEFAULT_BEFORE" = origin ] || return 1
  gh_default_is_origin
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
  if ! urls_equal "$origin" "$OURS" && ! urls_equal "$origin" "$UPSTREAM"; then
    fail "origin is $origin, which is neither --ours $OURS nor --upstream $UPSTREAM; refusing to guess"
  fi

  ORIGIN_BEFORE=$origin
  UPSTREAM_BEFORE=$upstream_url
  FORK_BEFORE=$fork_url
  TRACKING_BEFORE=$(capture_branch_tracking)
  DEFAULT_REMOTE_BEFORE=$(git_config_get checkout.defaultRemote)
  PUSH_DEFAULT_BEFORE=$(git_config_get remote.pushDefault)
  REMAP_SHAPE=

  if apply_has_nothing_to_change; then
    echo "landing-remote: origin already points at the landing remote"
    cmd_status
    return 0
  fi

  if urls_equal "$origin" "$OURS"; then
    REMAP_SHAPE=tidied-remotes
    if [ -z "$upstream_url" ]; then
      git -C "$REPO" remote add upstream "$UPSTREAM"
    fi
    if [ -n "$fork_url" ]; then
      git -C "$REPO" remote remove fork
    fi
  else
    require_landing_remote_reachable
    if [ -z "$upstream_url" ]; then
      git -C "$REPO" remote rename origin upstream
      if [ -n "$fork_url" ]; then
        git -C "$REPO" remote rename fork origin
        REMAP_SHAPE=renamed-fork
      else
        git -C "$REPO" remote add origin "$OURS"
        REMAP_SHAPE=added-origin
      fi
    else
      git -C "$REPO" remote set-url origin "$OURS"
      if [ -n "$fork_url" ]; then
        git -C "$REPO" remote remove fork
      fi
      REMAP_SHAPE=reurled-origin
    fi
    if ! refresh_origin_tracking; then
      restore_pre_apply_state
      fail "could not fetch $OURS after the remap, so origin's tracking refs would still name the previous remote; the checkout was restored, so re-run apply once the landing remote is reachable"
    fi
  fi

  repoint_landing_branch_tracking "$TRACKING_BEFORE"
  git -C "$REPO" config checkout.defaultRemote origin
  git -C "$REPO" config remote.pushDefault origin

  if ! record_gh_default; then
    restore_pre_apply_state
    fail "gh did not record origin as its default repository; with no gh default and both origin and upstream present, gh ranks upstream above origin, so a flagless 'gh pr create' can still open the PR on the third-party parent. The checkout was restored, so re-run apply once gh can record the default"
  fi
  if ! refresh_no_mistakes; then
    restore_pre_apply_state
    fail "no-mistakes --yes init failed, so its stored PR target would still name the previous remote and the pipeline would open PRs there; the checkout was restored, so re-run apply once init can succeed"
  fi

  if [ "$REMAP_SHAPE" = tidied-remotes ]; then
    echo "landing-remote: origin already points at the landing remote"
  else
    echo "landing-remote: origin now points at the landing remote"
  fi
  cmd_status
}

REPO=.
OURS=
UPSTREAM=
CMD=
ORIGIN_BEFORE=
UPSTREAM_BEFORE=
FORK_BEFORE=
TRACKING_BEFORE=
DEFAULT_REMOTE_BEFORE=
PUSH_DEFAULT_BEFORE=
REMAP_SHAPE=
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
