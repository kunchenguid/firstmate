# shellcheck shell=bash
# shellcheck disable=SC2034 # RESOLVE_BASE_* are output globals for sourcing callers.
# Resolve which git remote a firstmate checkout actually develops against.
#
# A checkout of this repo can have "origin" pointing at the public template it
# was forked from while the checkout's own branch tracks a separate fork it
# actually develops on, and the two can genuinely diverge (AGENTS.md task
# fm-fleet-follows-fork). Every tool that fetches, diffs, or reports
# divergence against "the development remote" must resolve it through
# resolve_update_base below rather than hardcoding origin, so it follows
# whatever a checkout's own branch is actually configured to track.
# Usage: . bin/fm-dev-remote-lib.sh   (pure git-config reads; no other setup, no network)

# Resolve which remote and ref a checkout's <default> branch should be updated
# from: its own CONFIGURED UPSTREAM (refs/heads/<default>@{upstream}) when one
# is set, so a checkout tracking a fork follows that fork rather than a
# hardcoded "origin" that may be a diverged upstream template; otherwise falls
# back to "origin/<default>" and says so via RESOLVE_BASE_NOTE, rather than
# guessing. Purely a local git-config read - no network, no existence check on
# the resolved ref (callers that need the ref to actually exist verify it
# themselves, since "exists" means different things to a fetcher vs. a local
# diff).
#
# The remote and the branch are read as their own git atoms
# (%(upstream:remotename) / %(upstream:remoteref)) rather than split out of
# %(upstream:short) on the first "/": a short upstream is only "<remote>/<branch>"
# for a remote-tracking upstream fetched under the default refspec. A branch
# tracking a LOCAL branch (branch.<name>.remote = ".") prints a bare branch
# name there, and a non-default fetch refspec prints the mapped tracking path,
# whose first component is not a remote name - either would otherwise hand
# every caller a remote that does not exist, and callers treat that as
# authoritative (fast-forward and pooled-worktree provisioning both refuse
# outright on an unknown remote).
#
# The two atoms are exact where the split was not: remotename is the real
# remote regardless of fetch refspec, and remoteref is always the upstream's
# refs/heads/<branch> on it. Only two shapes take the announced origin
# fallback: no upstream at all, and a local-branch upstream (remotename "."),
# which names no remote to fetch from. A non-default fetch refspec resolves
# normally to <remote>/<branch>; note that RESOLVE_BASE_REF then names the ref
# a caller's own explicit-refspec fetch creates, NOT the path that remote's
# refspec maps to, so a caller that instead runs a plain `git fetch <remote>`
# finds the ref absent and skips (safe, and visible as "does not exist").
# Sets:
#   RESOLVE_BASE_REMOTE = remote to fetch (e.g. "fork" or "origin")
#   RESOLVE_BASE_BRANCH = branch name on that remote (usually <default>)
#   RESOLVE_BASE_REF    = "<remote>/<branch>", the fast-forward/diff base
#   RESOLVE_BASE_NOTE   = "" when an upstream was used, else a one-line reason
resolve_update_base() {
  local dir=$1 default=$2 remote remoteref branch=
  remote=$(git -C "$dir" for-each-ref --format='%(upstream:remotename)' "refs/heads/$default" 2>/dev/null)
  remoteref=$(git -C "$dir" for-each-ref --format='%(upstream:remoteref)' "refs/heads/$default" 2>/dev/null)
  case "$remoteref" in
    refs/heads/?*) branch=${remoteref#refs/heads/} ;;
  esac
  if [ -n "$remote" ] && [ "$remote" != "." ] && [ -n "$branch" ]; then
    RESOLVE_BASE_REMOTE="$remote"
    RESOLVE_BASE_BRANCH="$branch"
    RESOLVE_BASE_NOTE=""
  else
    RESOLVE_BASE_REMOTE="origin"
    RESOLVE_BASE_BRANCH="$default"
    case "$remote" in
      '') RESOLVE_BASE_NOTE="no upstream configured for $default; using origin/$default" ;;
      .) RESOLVE_BASE_NOTE="$default tracks local branch ${remoteref#refs/heads/}, not a remote; using origin/$default" ;;
      *) RESOLVE_BASE_NOTE="upstream of $default ($remote $remoteref) is not a remote branch; using origin/$default" ;;
    esac
  fi
  RESOLVE_BASE_REF="$RESOLVE_BASE_REMOTE/$RESOLVE_BASE_BRANCH"
}
