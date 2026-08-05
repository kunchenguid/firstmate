# shellcheck shell=bash
# Shared origin-divergence guard for the firstmate primary checkout.
# Usage: . bin/fm-main-divergence-lib.sh
#
# Firstmate's self-update path (bin/fm-update.sh, /updatefirstmate) is
# fast-forward ONLY: it advances the primary checkout's default branch to
# origin/<default> and refuses the moment the local branch is not an ancestor of
# origin, reporting "skipped: diverged from origin/<default>" (fm-ff-lib.sh).
# That report only reaches anyone who runs /updatefirstmate, and nothing else in
# the daily loop compares local to origin - so a shared fix landed directly on
# the local default branch (bypassing the normal PR path) diverges it and every
# later self-update declines to advance it with no one watching. This guard
# closes that gap by surfacing the state at every session start instead.
#
# fm_primary_diverged_branch detects exactly that and nothing else: the local
# default branch carries commits origin/<default> does not, so a fast-forward
# can no longer reconcile it. Like the tangle guard it is scoped to the PRIMARY
# checkout, using the same discriminator - the checked-out branch - because
# refs/heads/<default> and refs/remotes/origin/<default> live in the shared
# common git dir, so every linked worktree reads the identical refs and would
# otherwise raise the primary's alarm in its own name. Detached HEAD (how
# crewmate worktrees and secondmate homes legitimately sit) and a named
# non-default branch (the tangled primary, which TANGLE owns and reports) both
# stay silent here; only the primary sitting on its default branch - precisely
# the state in which the fast-forward self-update applies - can flag.
#
# It is likewise silent for every healthy or inconclusive state - no origin
# remote, no origin/<default> ref, an unresolvable default branch, or a local
# default branch that is behind or equal to origin/<default> - so a local-only
# or offline install never produces a false alarm. It never fetches: it reads
# the already-known origin/<default> ref, so the check stays cheap and
# offline-safe.

# shellcheck source=bin/fm-tangle-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-tangle-lib.sh"

# If the primary checkout at <root> has diverged its default branch from
# origin/<default> such that `git merge --ff-only` can no longer reconcile it,
# echo the default branch name and return 0. Echo nothing and return 1 for
# every other state: not a git work tree, detached HEAD, a named non-default
# branch (TANGLE's condition, reported there), and a plain "behind origin"
# checkout, which is healthy and must never be reported as diverged.
fm_primary_diverged_branch() {
  local root=$1 cur default
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  cur=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$cur" ] || return 1
  default=$(fm_default_branch "$root") || return 1
  [ "$cur" = "$default" ] || return 1
  git -C "$root" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$root" rev-parse --verify --quiet "refs/heads/$default^{commit}" >/dev/null 2>&1 || return 1
  git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$default^{commit}" >/dev/null 2>&1 || return 1
  if git -C "$root" merge-base --is-ancestor "refs/heads/$default" "refs/remotes/origin/$default" 2>/dev/null; then
    return 1
  fi
  printf '%s\n' "$default"
  return 0
}
