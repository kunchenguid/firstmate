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
# diff). Sets:
#   RESOLVE_BASE_REMOTE = remote to fetch (e.g. "fork" or "origin")
#   RESOLVE_BASE_BRANCH = branch name on that remote (usually <default>)
#   RESOLVE_BASE_REF    = "<remote>/<branch>", the fast-forward/diff base
#   RESOLVE_BASE_NOTE   = "" when an upstream was used, else a one-line reason
resolve_update_base() {
  local dir=$1 default=$2 upstream
  upstream=$(git -C "$dir" for-each-ref --format='%(upstream:short)' "refs/heads/$default" 2>/dev/null)
  if [ -n "$upstream" ]; then
    RESOLVE_BASE_REMOTE="${upstream%%/*}"
    RESOLVE_BASE_BRANCH="${upstream#*/}"
    RESOLVE_BASE_NOTE=""
  else
    RESOLVE_BASE_REMOTE="origin"
    RESOLVE_BASE_BRANCH="$default"
    RESOLVE_BASE_NOTE="no upstream configured for $default; using origin/$default"
  fi
  RESOLVE_BASE_REF="$RESOLVE_BASE_REMOTE/$RESOLVE_BASE_BRANCH"
}
