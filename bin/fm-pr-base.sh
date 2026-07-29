#!/usr/bin/env bash
# Converge a checkout so the tools that build their OWN checkout from it agree
# on which repository pull requests target. Report what cannot be converged.
#
# WHY THIS EXISTS
# `gh repo set-default` records the pull-request base repository in ONE
# checkout's git config, and nothing else reads that record. The no-mistakes
# validation pipeline does not open pull requests from this checkout: it builds
# a worktree of a bare mirror whose only remote is whatever origin was when the
# gate was initialized. On a fleet that ships to its own fork - origin the
# shared upstream, a second remote the fork - that mirror sees only the
# upstream, so it opens pull requests against the upstream and rebases branches
# onto the upstream's default branch.
#
# This converges the mirror onto the configured base repository, on both keys
# that decide it: the URL its rebase step resolves, and the gh-resolved record
# its `gh pr create` resolves. The expectation is always derived from
# configuration (bin/fm-pr-base-lib.sh), never hardcoded, so each fleet
# resolves its own fork.
#
# It deliberately does NOT rewrite the checkout's own remote names or URLs. The
# origin/fork split is load-bearing: bin/fm-update.sh and bin/fm-ff-lib.sh treat
# origin as ingest-only and advance every home from the fork, and renaming
# either remote would silently break that. The branch-cut half of the same
# problem - a worktree pool that starts every branch on origin's default branch
# - is handled where firstmate actually holds the worktree, in
# bin/fm-worktree-base.sh.
#
# Convergence is idempotent by design and safe to re-run every session: a tool
# that rewrites its own mirror configuration is simply re-converged next time.
#
# Usage: fm-pr-base.sh check [<checkout>]
#          Print one "PR_BASE: <problem> (<remediation>)" line per divergence
#          and exit 0. Silent = nothing to converge.
#        fm-pr-base.sh repair [<checkout>]
#          Converge what can be converged, printing one
#          "BOOTSTRAP_INFO: pr base: <what changed>" line per applied change and
#          one "PR_BASE: ..." line per remaining divergence. Exits 0.
#
# <checkout> defaults to FM_ROOT. Repair only ever writes git remote
# configuration - a remote URL, a gh-resolved record, a remote-tracking HEAD. It
# never touches a working tree, a branch, a commit, or any unlanded work.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-pr-base-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-base-lib.sh"

MODE=${1:-check}
DIR=${2:-$FM_ROOT}
case "$MODE" in
  check|repair) ;;
  *) echo "usage: fm-pr-base.sh check|repair [<checkout>]" >&2; exit 2 ;;
esac

problem() { printf 'PR_BASE: %s\n' "$1"; }
applied() { printf 'BOOTSTRAP_INFO: pr base: %s\n' "$1"; }

if [ ! -d "$DIR" ] || ! git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

# A checkout with no forge remote at all - a purely local repository - has no
# pull-request target to converge. bin/fm-pr-check.sh is where an unresolvable
# expectation is reported, because that is the point where it would otherwise
# let a wrong pull request through.
fm_pr_base_resolve "$DIR" || exit 0
BASE_HOST=$FM_PR_BASE_HOST
BASE_PATH=$FM_PR_BASE_PATH
BASE_REMOTE=$FM_PR_BASE_REMOTE

origin_url=$(git -C "$DIR" config --get remote.origin.url 2>/dev/null || true)
origin_is_base=0
if fm_pr_base_url_identity "$origin_url" \
  && fm_pr_base_identity_equal "$FM_PR_BASE_URL_HOST" "$FM_PR_BASE_URL_PATH" "$BASE_HOST" "$BASE_PATH"; then
  origin_is_base=1
fi

# Everything below matters only when the base repository is NOT origin. When it
# is, every tool that reads origin is already right and there is nothing to
# converge.
if [ "$origin_is_base" -eq 1 ]; then
  exit 0
fi

# --- the remote that supplies the base branch -------------------------------
#
# bin/fm-worktree-base.sh cuts branches from this remote's default branch. It
# needs the remote to exist and its default branch to be recorded.

if [ -z "$BASE_REMOTE" ]; then
  problem "$DIR: pull requests target $BASE_HOST/$BASE_PATH but no remote fetches it, so branches cannot be cut from its default branch (add one with: git -C $DIR remote add fork https://$BASE_HOST/$BASE_PATH.git)"
elif ! fm_pr_base_default_branch "$DIR" "$BASE_REMOTE" >/dev/null 2>&1; then
  if [ "$MODE" = check ]; then
    problem "$DIR: remote '$BASE_REMOTE' has no recorded default branch, so branches cannot be cut from $BASE_HOST/$BASE_PATH (repair with: $SCRIPT_DIR/fm-pr-base.sh repair $DIR)"
  elif git -C "$DIR" remote set-head "$BASE_REMOTE" --auto >/dev/null 2>&1; then
    applied "$DIR: recorded $BASE_HOST/$BASE_PATH's default branch"
  else
    problem "$DIR: remote '$BASE_REMOTE' has no recorded default branch and it could not be resolved (repair with: git -C $DIR fetch $BASE_REMOTE && git -C $DIR remote set-head $BASE_REMOTE --auto)"
  fi
fi

# --- the no-mistakes gate mirror --------------------------------------------

# gate_is_local_mirror <path> <checkout-toplevel>: true only for an existing bare
# repository outside the checkout's working tree. The gate mirror is local tool
# state; this fence is what keeps the convergence from ever reaching a project
# worktree.
gate_is_local_mirror() {
  local path=${1-} top=${2-}
  [ -n "$path" ] && [ -d "$path" ] || return 1
  [ "$(git -C "$path" config --get core.bare 2>/dev/null || true)" = true ] || return 1
  [ -n "$top" ] || return 0
  case "$path" in
    "$top"|"$top"/*) return 1 ;;
  esac
}

gate=$(git -C "$DIR" config --get remote.no-mistakes.url 2>/dev/null || true)
worktree_top=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$gate" ] && gate_is_local_mirror "$gate" "$worktree_top"; then
  gate_url=$(git -C "$gate" config --get remote.origin.url 2>/dev/null || true)
  gate_resolved=$(git -C "$gate" config --get remote.origin.gh-resolved 2>/dev/null || true)
  gate_url_ok=0
  if fm_pr_base_url_identity "$gate_url" \
    && fm_pr_base_identity_equal "$FM_PR_BASE_URL_HOST" "$FM_PR_BASE_URL_PATH" "$BASE_HOST" "$BASE_PATH"; then
    gate_url_ok=1
  fi
  # An explicit gh-resolved record is required even once the URL is right:
  # without one, `gh pr create` resolves whatever remotes that worktree happens
  # to have, which is exactly the resolution that opened three pull requests on
  # a third party's repository.
  gate_resolved_ok=0
  if [ "$gate_url_ok" -eq 1 ] && [ "$gate_resolved" = base ]; then
    gate_resolved_ok=1
  elif [ -n "$gate_resolved" ] && [ "$gate_resolved" != base ] \
    && fm_pr_base_identity_equal "$BASE_HOST" "$gate_resolved" "$BASE_HOST" "$BASE_PATH"; then
    gate_resolved_ok=1
  fi
  if [ "$gate_url_ok" -eq 0 ] || [ "$gate_resolved_ok" -eq 0 ]; then
    if [ "$gate_url_ok" -eq 0 ]; then
      detail="$DIR: the validation pipeline builds its own checkout from ${gate_url:-no repository}, not $BASE_HOST/$BASE_PATH, so it opens pull requests there and rebases branches onto that repository's default branch"
    else
      detail="$DIR: the validation pipeline's own checkout has no recorded base repository, so it opens pull requests against whichever remote it happens to see"
    fi
    if [ "$MODE" = check ]; then
      problem "$detail (repair with: $SCRIPT_DIR/fm-pr-base.sh repair $DIR)"
    else
      # Reuse the base remote's own URL so the captain's spelling and
      # credentials carry over rather than being guessed at.
      base_url=
      [ -z "$BASE_REMOTE" ] \
        || base_url=$(git -C "$DIR" config --get "remote.$BASE_REMOTE.url" 2>/dev/null || true)
      [ -n "$base_url" ] || base_url="https://$BASE_HOST/$BASE_PATH.git"
      if git -C "$gate" config remote.origin.url "$base_url" >/dev/null 2>&1 \
        && git -C "$gate" config remote.origin.gh-resolved "$BASE_PATH" >/dev/null 2>&1; then
        git -C "$gate" fetch --quiet origin >/dev/null 2>&1 || true
        applied "$DIR: the validation pipeline now targets $BASE_HOST/$BASE_PATH"
      else
        problem "$detail; it could not be updated (resolve by hand)"
      fi
    fi
  fi
fi

exit 0
