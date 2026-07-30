# shellcheck shell=bash
# Single owner of "which remote holds this checkout's landed work".
# Usage: . bin/fm-remote-lib.sh   then   remote=$(fm_publish_remote "$dir") || ...
#
# A checkout can track two remotes: `origin`, the upstream it was forked from, and
# `fork`, the publish target this fleet actually pushes branches and PRs to. Work
# lands on the PUBLISH remote, so every script that fast-forwards a checkout,
# computes a review base, or proves a branch landed must resolve that remote
# instead of assuming `origin`. Assuming `origin` in a fork-backed checkout makes a
# self-update or clone refresh either skip as "diverged" forever or, worse, follow
# the upstream's history instead of the fleet's own.
#
# Resolution is deliberately trivial: `fork` when that remote exists, else
# `origin`. A single-remote clone - the common case, including CI checkouts - keeps
# today's behavior byte for byte, and nothing here fetches, writes, or mutates a
# remote, so it is safe to call from a read-only path.
#
# Branch-NAME resolution stays with each caller's own default_branch helper: the
# publish remote and its upstream share the default branch name, and the local
# main/master fallback already covers a checkout with no origin/HEAD.

# Print the publish remote resolved above for the git repo at <dir>.
# Returns 1 without printing when neither candidate exists, so a caller reports a
# remote-less checkout instead of building a ref that cannot resolve.
fm_publish_remote() {
  local dir=$1 remote
  for remote in fork origin; do
    if git -C "$dir" remote get-url "$remote" >/dev/null 2>&1; then
      printf '%s\n' "$remote"
      return 0
    fi
  done
  return 1
}
