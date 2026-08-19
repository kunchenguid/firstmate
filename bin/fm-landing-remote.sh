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
# every later failure - a remote rename or add, a git config write, the
# refetch, the gh default, the no-mistakes re-init - restores the remotes, the
# branch tracking, and the git defaults it found, so a failed apply leaves the
# checkout as it was and can be re-run. The shape of the remap is known before
# the first write and an exit trap covers the whole mutating window, so an
# abort part-way through a rename pair still restores. When a restore step
# itself fails, apply says the remotes were not put back and need hand repair
# rather than claiming a re-appliable checkout.
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
  local branch remote merge rc=0
  [ -n "$1" ] || return 0
  while IFS="$(printf '\t')" read -r branch remote merge; do
    [ -n "$branch" ] || continue
    case $remote in
      origin|fork) ;;
      *) continue ;;
    esac
    git -C "$REPO" config "branch.${branch}.remote" origin || rc=1
    if [ -n "$merge" ]; then
      git -C "$REPO" config "branch.${branch}.merge" "$merge" || rc=1
    fi
  done <<TRACKED
$1
TRACKED
  return $rc
}

restore_captured_branch_tracking() {  # <captured tracking>
  local branch remote merge rc=0
  [ -n "$1" ] || return 0
  while IFS="$(printf '\t')" read -r branch remote merge; do
    [ -n "$branch" ] || continue
    git -C "$REPO" config "branch.${branch}.remote" "$remote" || rc=1
    if [ -n "$merge" ]; then
      git -C "$REPO" config "branch.${branch}.merge" "$merge" || rc=1
    fi
  done <<TRACKED
$1
TRACKED
  return $rc
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

# Put the checkout back the way apply found it. The shape is recorded before
# the first write, so this also runs against a half-written remap: every step
# is conditioned on the remote layout actually present, and a step whose write
# never landed is skipped instead of failing. The rewrite shapes cannot
# recreate remote-tracking refs a later fetch replaced or `git remote remove`
# deleted, so they refetch what they put back and leave those refs holding the
# landing remote's tips when the network they are being restored because of is
# still down.
restore_pre_apply_remotes() {
  case $REMAP_SHAPE in
    renamed-fork)
      if ! remote_exists fork && remote_exists origin; then
        git -C "$REPO" remote rename origin fork || return 1
      fi
      if ! remote_exists origin && remote_exists upstream; then
        git -C "$REPO" remote rename upstream origin || return 1
      fi
      ;;
    added-origin)
      if remote_exists origin && remote_exists upstream; then
        git -C "$REPO" remote remove origin || return 1
      fi
      if ! remote_exists origin && remote_exists upstream; then
        git -C "$REPO" remote rename upstream origin || return 1
      fi
      ;;
    reurled-origin|tidied-remotes)
      if remote_exists origin; then
        git -C "$REPO" remote set-url origin "$ORIGIN_BEFORE" || return 1
      fi
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
  local rc=0
  if [ -n "$DEFAULT_REMOTE_BEFORE" ]; then
    git -C "$REPO" config checkout.defaultRemote "$DEFAULT_REMOTE_BEFORE" || rc=1
  else
    git -C "$REPO" config --unset checkout.defaultRemote 2>/dev/null || true
  fi
  if [ -n "$PUSH_DEFAULT_BEFORE" ]; then
    git -C "$REPO" config remote.pushDefault "$PUSH_DEFAULT_BEFORE" || rc=1
  else
    git -C "$REPO" config --unset remote.pushDefault 2>/dev/null || true
  fi
  return $rc
}

# Returns non-zero when any part of the checkout could not be put back, so the
# caller can say what actually happened instead of promising a re-appliable
# checkout. Clearing APPLY_IN_FLIGHT here keeps the exit trap from restoring a
# second time on the way out.
restore_pre_apply_state() {
  local rc=0
  APPLY_IN_FLIGHT=0
  restore_pre_apply_remotes || rc=1
  restore_captured_branch_tracking "$TRACKING_BEFORE" || rc=1
  restore_git_default_config || rc=1
  return $rc
}

# Every mutating step ends here, so one failure and one restore produce one
# honest sentence. The trailing clause is decided by whether the restore
# actually worked, never assumed.
fail_after_restore() {  # <what failed>
  if restore_pre_apply_state; then
    fail "$1 The checkout was restored, so re-run apply once the cause is fixed"
  fi
  fail "$1 The remotes, branch tracking, or git defaults this apply rewrote were NOT restored; run fm-landing-remote.sh status and repair them by hand before using this checkout"
}

# `set -eu` can abort the mutating window at a command no `||` guard covers, and
# a half-written remap can leave the checkout with no origin at all. The trap is
# armed after the shape is recorded and before the first write, so any exit from
# inside that window still restores.
# Arm the restore before the first write, never after it. Every caller records
# REMAP_SHAPE first, so the trap knows what to undo even when the very first
# rename is the thing that fails.
begin_apply_mutations() {
  APPLY_IN_FLIGHT=1
  trap abort_apply_in_flight EXIT
}

abort_apply_in_flight() {
  local status=$?
  [ "$APPLY_IN_FLIGHT" = 1 ] || return 0
  APPLY_IN_FLIGHT=0
  echo "error: apply stopped part-way through rewriting the remotes of '$REPO' (status $status)" >&2
  if restore_pre_apply_state; then
    echo "error: the checkout was restored, so re-run apply once the cause is fixed" >&2
  else
    echo "error: the remotes, branch tracking, or git defaults this apply rewrote were NOT restored; run fm-landing-remote.sh status and repair them by hand before using this checkout" >&2
  fi
  return 0
}

# gh ranks the remote named `upstream` above `origin` when no default repo is
# recorded, so after this remap both remotes exist and an unset gh default sends
# a flagless `gh pr create` to the third-party parent. That is the exact defect
# this script exists to kill, so a gh that is present but did not take the
# default is a failed apply, not a warning over a green exit code.
record_gh_default() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "warning: gh is not on PATH; git origin is the landing remote, but gh has no default repo, so run 'gh repo set-default origin' once gh is installed" >&2
    return 0
  fi
  if ! ( cd "$REPO" && gh repo set-default origin >/dev/null 2>&1 ); then
    echo "warning: gh repo set-default origin exited non-zero" >&2
    return 1
  fi
  if ! gh_default_is_origin; then
    echo "warning: gh did not record origin as its default repository" >&2
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
    begin_apply_mutations
    if [ -z "$upstream_url" ]; then
      git -C "$REPO" remote add upstream "$UPSTREAM" \
        || fail_after_restore "could not add the upstream remote $UPSTREAM."
    fi
    if [ -n "$fork_url" ]; then
      git -C "$REPO" remote remove fork \
        || fail_after_restore "could not remove the leftover fork remote."
    fi
  else
    require_landing_remote_reachable
    if [ -z "$upstream_url" ]; then
      if [ -n "$fork_url" ]; then
        REMAP_SHAPE=renamed-fork
      else
        REMAP_SHAPE=added-origin
      fi
      begin_apply_mutations
      git -C "$REPO" remote rename origin upstream \
        || fail_after_restore "could not rename the origin remote to upstream."
      if [ -n "$fork_url" ]; then
        git -C "$REPO" remote rename fork origin \
          || fail_after_restore "could not rename the fork remote to origin."
      else
        git -C "$REPO" remote add origin "$OURS" \
          || fail_after_restore "could not add origin at $OURS."
      fi
    else
      REMAP_SHAPE=reurled-origin
      begin_apply_mutations
      git -C "$REPO" remote set-url origin "$OURS" \
        || fail_after_restore "could not point origin at $OURS."
      if [ -n "$fork_url" ]; then
        git -C "$REPO" remote remove fork \
          || fail_after_restore "could not remove the leftover fork remote."
      fi
    fi
    if ! refresh_origin_tracking; then
      fail_after_restore "could not fetch $OURS after the remap, so origin's tracking refs would still name the previous remote."
    fi
  fi

  repoint_landing_branch_tracking "$TRACKING_BEFORE" \
    || fail_after_restore "could not repoint the branches that tracked the renamed remotes at origin."
  git -C "$REPO" config checkout.defaultRemote origin \
    || fail_after_restore "could not set checkout.defaultRemote to origin."
  git -C "$REPO" config remote.pushDefault origin \
    || fail_after_restore "could not set remote.pushDefault to origin."

  if ! record_gh_default; then
    fail_after_restore "gh did not record origin as its default repository; with no gh default and both origin and upstream present, gh ranks upstream above origin, so a flagless 'gh pr create' can still open the PR on the third-party parent."
  fi
  if ! refresh_no_mistakes; then
    fail_after_restore "no-mistakes --yes init failed, so its stored PR target would still name the previous remote and the pipeline would open PRs there."
  fi

  APPLY_IN_FLIGHT=0
  trap - EXIT

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
APPLY_IN_FLIGHT=0
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
