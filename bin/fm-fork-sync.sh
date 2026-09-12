#!/usr/bin/env bash
# Best-effort fork sync for a firstmate home that runs against a personal fork.
#
# Entirely inert unless this checkout has a distinct `upstream` git remote
# configured alongside `origin` - the standard fork workflow (`origin` = your
# fork and push target, `upstream` = the real upstream, pull-only). A home with
# only a single `origin` remote takes zero action.
#
# When `upstream` exists: fetch it, and if its default branch is a genuine
# fast-forward ahead of `origin`'s same-named branch (verified with
# `git merge-base --is-ancestor`), push `upstream/<default>` to
# `origin/<default>`. Never force-pushes. Assumes the fork's default branch
# shares its name with upstream's (the ordinary GitHub fork convention); a
# renamed fork default branch is left alone.
#
# Then, only if the locally checked-out branch is that default branch, the
# tracked tree is clean, and local HEAD can fast-forward to the freshly synced
# `origin/<default>`, fast-forwards the local branch. Every other case (dirty
# tree, feature branch, diverged history, no genuine fast-forward available)
# is a silent no-op, optionally with one quiet diagnostic line on stderr when
# FM_FORK_SYNC_QUIET is unset.
#
# Runs only against the genuine primary firstmate checkout - never a project
# clone, a crewmate/scout worktree, or a secondmate home - by requiring both
# git-dir == git-common-dir (not a linked worktree) and the absence of the
# `.fm-secondmate-home` marker, and silently no-ops from inside a no-mistakes
# gate agent (see bin/fm-gate-refuse-lib.sh) since it pushes to a live remote.
# See docs/configuration.md "Fork sync" for the opt-in contract and
# bin/fm-sessionstart-nudge.sh for how session start launches this in the
# background so it can never block or delay the nudge.
#
# Usage: bin/fm-fork-sync.sh
# FM_ROOT_OVERRIDE overrides the detected repo root (tests only).
# FM_FORK_SYNC_QUIET=1 suppresses the single-line stderr diagnostics.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

# Never prompt for credentials and never let a stalled transfer hang around.
export GIT_TERMINAL_PROMPT=0
GIT_NET_OPTS=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10)

log() {
  [ "${FM_FORK_SYNC_QUIET:-0}" = 1 ] && return 0
  printf 'fm-fork-sync: %s\n' "$1" >&2
}

git_c() {
  git -C "$FM_ROOT" "$@"
}

# Gate: the genuine primary checkout only, never a secondmate home.
fm_root_is_secondmate_home "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$FM_ROOT/state" || exit 0

# Gate: never push from inside a no-mistakes gate agent (best-effort, silent).
fm_is_gate_agent "$FM_ROOT" && exit 0

# Gate: fork topology only - a distinct `upstream` remote must exist.
upstream_url=$(git_c remote get-url upstream 2>/dev/null) || exit 0
origin_url=$(git_c remote get-url origin 2>/dev/null) || exit 0
[ -n "$upstream_url" ] && [ -n "$origin_url" ] || exit 0
[ "$upstream_url" != "$origin_url" ] || exit 0

if ! git_c "${GIT_NET_OPTS[@]}" fetch --quiet upstream >/dev/null 2>&1; then
  log "could not fetch upstream, skipping"
  exit 0
fi

symref=$(git_c "${GIT_NET_OPTS[@]}" ls-remote --symref upstream HEAD 2>/dev/null | awk '$1 == "ref:" { print $2 }')
default_branch=${symref#refs/heads/}
if [ -z "$default_branch" ] || [ "$default_branch" = "$symref" ]; then
  log "could not determine upstream's default branch, skipping"
  exit 0
fi

upstream_ref="refs/remotes/upstream/$default_branch"
if ! git_c rev-parse --verify --quiet "$upstream_ref" >/dev/null; then
  log "no local $upstream_ref after fetch, skipping"
  exit 0
fi

origin_ref="refs/remotes/origin/$default_branch"
if ! git_c rev-parse --verify --quiet "$origin_ref" >/dev/null; then
  git_c "${GIT_NET_OPTS[@]}" fetch --quiet origin "$default_branch" >/dev/null 2>&1 || true
fi
if ! git_c rev-parse --verify --quiet "$origin_ref" >/dev/null; then
  log "no local $origin_ref, skipping"
  exit 0
fi

upstream_sha=$(git_c rev-parse "$upstream_ref")
origin_sha=$(git_c rev-parse "$origin_ref")

if [ "$upstream_sha" != "$origin_sha" ]; then
  if git_c merge-base --is-ancestor "$origin_sha" "$upstream_sha" 2>/dev/null; then
    if git_c "${GIT_NET_OPTS[@]}" push origin "${upstream_ref}:refs/heads/$default_branch" >/dev/null 2>&1; then
      log "fast-forwarded origin/$default_branch to upstream/$default_branch"
      origin_sha="$upstream_sha"
    else
      log "push to origin/$default_branch was not a fast-forward or failed, skipping"
      exit 0
    fi
  else
    log "origin/$default_branch is not an ancestor of upstream/$default_branch, skipping"
    exit 0
  fi
fi

# Fast-forward the local checkout only when it is unambiguously safe.
current_branch=$(git_c symbolic-ref --quiet --short HEAD 2>/dev/null) || exit 0
[ "$current_branch" = "$default_branch" ] || exit 0

if [ -n "$(git_c status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  log "local tree has uncommitted tracked changes, skipping local fast-forward"
  exit 0
fi

head_sha=$(git_c rev-parse HEAD 2>/dev/null) || exit 0
[ "$head_sha" != "$origin_sha" ] || exit 0

if git_c merge --ff-only --quiet "$origin_ref" >/dev/null 2>&1; then
  log "fast-forwarded local $default_branch to origin/$default_branch"
else
  log "local $default_branch cannot fast-forward to origin/$default_branch, skipping"
fi
exit 0
