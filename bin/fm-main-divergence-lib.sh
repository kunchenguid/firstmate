# shellcheck shell=bash
# Shared origin-divergence guard for the firstmate primary checkout.
# Usage: . bin/fm-main-divergence-lib.sh
#
# Firstmate's self-update path (bin/fm-update.sh, /updatefirstmate) is
# fast-forward ONLY: it advances the primary checkout's default branch to
# origin/<default> and refuses, silently skipping, the moment the local branch
# is not an ancestor of origin. That silent skip is the failure mode this guard
# surfaces loudly at session start instead: a shared fix landed directly on the
# local default branch (bypassing the normal PR path) diverges it from origin,
# and every later self-update quietly does nothing until someone notices.
#
# fm_primary_diverged_branch detects exactly that and nothing else: the local
# default branch carries commits origin/<default> does not, so a fast-forward
# can no longer reconcile it. It is deliberately silent for every healthy or
# inconclusive state - no origin remote, no origin/<default> ref, an
# unresolvable default branch, or a local default branch that is behind or
# equal to origin/<default> - so a local-only or offline install never produces
# a false alarm. It never fetches: it reads the already-known origin/<default>
# ref, so the check stays cheap and offline-safe.

# shellcheck source=bin/fm-tangle-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-tangle-lib.sh"

# If the git checkout at <root> has diverged its default branch from
# origin/<default> such that `git merge --ff-only` can no longer reconcile it,
# echo the default branch name and return 0. Echo nothing and return 1 for
# every other state, including a plain "behind origin" checkout, which is
# healthy and must never be reported as diverged.
fm_primary_diverged_branch() {
  local root=$1 default
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$root" remote get-url origin >/dev/null 2>&1 || return 1
  default=$(fm_default_branch "$root") || return 1
  git -C "$root" rev-parse --verify --quiet "refs/heads/$default^{commit}" >/dev/null 2>&1 || return 1
  git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$default^{commit}" >/dev/null 2>&1 || return 1
  if git -C "$root" merge-base --is-ancestor "refs/heads/$default" "refs/remotes/origin/$default" 2>/dev/null; then
    return 1
  fi
  printf '%s\n' "$default"
  return 0
}
