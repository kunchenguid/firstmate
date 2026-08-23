#!/usr/bin/env bash
# bin/fm-treehouse-pool-sweep.sh - Pre-acquire worktree pool safety sweep.
#
# This is a MITIGATION (not a fix) for the worktree reuse incident. It inspects
# pooled worktrees before acquisition and refuses to request one when unsafe pool
# state is observed. The upstream invariant is: "No consumer can reuse a worktree
# whose state is unsafe." This mitigation can only observe and refuse; it cannot
# enforce the invariant across all consumers.
#
# Two structural gaps this mitigation cannot close:
#   1. A direct `treehouse get` by anything other than firstmate bypasses this sweep.
#   2. Another firstmate home can race between sweep and acquire.
#
# Usage: fm-treehouse-pool-sweep.sh <worktree-path>
# Exit codes:
#   0 - Worktree is safe to acquire (or sweep is disabled)
#   1 - Worktree is unsafe: dirty
#   2 - Worktree is unsafe: HEAD contains commits not reachable from durable refs
#   3 - Worktree is unsafe: HEAD covered only by remote-tracking refs (prunable)
#   4 - Worktree does not exist
#  64 - Usage error (no worktree path given)
set -euo pipefail

usage() {
  cat <<EOF
fm-treehouse-pool-sweep.sh - Pre-acquire worktree pool safety sweep

This is a MITIGATION for the worktree reuse incident (not a fix for the
underlying invariant). It inspects pooled worktrees before acquisition and
refuses to request one when unsafe pool state is observed.

Usage: fm-treehouse-pool-sweep.sh <worktree-path>

The sweep checks two conditions and refuses on either:
  1. Dirty worktree: tracked modifications, staged changes, or untracked
     non-ignored files.
  2. HEAD contains at least one commit not reachable from an approved durable ref:
     - refs/heads/* (local branches)
     - refs/tags/* (tags)
     - refs/firstmate/rescue/* (reserved rescue namespace)

Reflogs are NOT refs. A commit reachable only from a reflog is unreferenced.

For refs/remotes/*: they are counted for reachability so an ordinary freshly-
checked-out pool worktree is not falsely refused, but the case where HEAD's
commits are covered ONLY by remote-tracking refs (and no local head or tag) is
classified as unsafe.

Exit codes:
  0 - Worktree is safe to acquire (or sweep is disabled)
  1 - Worktree is unsafe: dirty
  2 - Worktree is unsafe: HEAD contains commits not reachable from durable refs
  3 - Worktree is unsafe: HEAD covered only by remote-tracking refs (prunable)
  4 - Worktree does not exist
 64 - Usage error (no worktree path given)

Activation:
  The sweep is disabled by default. To enable, create:
    $HOME/.firstmate/config/worktree-pool-sweep
  containing "on" (or any non-empty value other than "off").
  A missing file, an empty file, or the value "off" leaves the sweep disabled.

This mitigation is distinct from the upstream Treehouse invariant:
  - MITIGATION: "Firstmate refuses to request a worktree when it observes unsafe pool state."
  - INVARIANT:  "No consumer can reuse a worktree whose state is unsafe."

Structural gaps this mitigation cannot close:
  1. A direct treehouse get by anything other than firstmate bypasses the sweep.
  2. Another firstmate home can race between sweep and acquire:

     T1  Firstmate A sweeps -> safe
     T2  Firstmate B acquires/modifies the same pool
     T3  Firstmate A calls treehouse get

     This race can cause the worktree to be unsafe when Firstmate A uses it.
     The eventual Treehouse fix must kill this atomically at allocation time.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

WT="${1:-}"
if [ -z "$WT" ]; then
  echo "error: worktree path required" >&2
  usage >&2
  exit 64
fi

CONFIG_DIR="${FM_ROOT:-$HOME/.firstmate}/config"
SWEEP_CONFIG="$CONFIG_DIR/worktree-pool-sweep"

is_sweep_enabled() {
  if [ -f "$SWEEP_CONFIG" ]; then
    local val
    val=$(cat "$SWEEP_CONFIG" 2>/dev/null | tr -d '[:space:]')
    [ -n "$val" ] && [ "$val" != "off" ]
  else
    return 1
  fi
}

if ! is_sweep_enabled; then
  exit 0
fi

if [ ! -d "$WT" ]; then
  exit 4
fi

is_dirty() {
  local wt=$1
  if ! git -C "$wt" diff-index --quiet --ignore-submodules HEAD 2>/dev/null; then
    return 0
  fi
  if ! git -C "$wt" diff-index --quiet --ignore-submodules --cached HEAD 2>/dev/null; then
    return 0
  fi
  local untracked
  untracked=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null)
  if [ -n "$untracked" ]; then
    return 0
  fi
  return 1
}

count_refs() {
  local wt=$1 pattern=$2
  git -C "$wt" for-each-ref --format='%(refname)' "$pattern" 2>/dev/null | wc -l
}

has_durable_refs() {
  local wt=$1
  local count
  count=$(count_refs "$wt" 'refs/heads/')
  count=$((count + $(count_refs "$wt" 'refs/tags/')))
  count=$((count + $(count_refs "$wt" 'refs/firstmate/rescue/')))
  [ "$count" -gt 0 ]
}

has_only_remote_refs() {
  local wt=$1
  local local_count remote_count
  local_count=$(count_refs "$wt" 'refs/heads/')
  local_count=$((local_count + $(count_refs "$wt" 'refs/tags/')))
  remote_count=$(count_refs "$wt" 'refs/remotes/')
  [ "$local_count" -eq 0 ] && [ "$remote_count" -gt 0 ]
}

check_head_reachable() {
  local wt=$1
  local unique_count
  if ! has_durable_refs "$wt"; then
    if has_only_remote_refs "$wt"; then
      return 3
    fi
    return 2
  fi
  unique_count=$(git -C "$wt" rev-list --count HEAD --not --branches --tags \
    --glob='refs/firstmate/rescue/*' 2>/dev/null) || return 2
  case "$unique_count" in
    '' | *[!0-9]*) return 2 ;;
  esac
  if [ "$unique_count" -gt 0 ]; then
    return 2
  fi
  return 0
}

if is_dirty "$WT"; then
  echo "unsafe: dirty worktree at $WT" >&2
  exit 1
fi

rc=0
check_head_reachable "$WT" || rc=$?

if [ $rc -eq 2 ]; then
  echo "unsafe: HEAD contains commits not reachable from durable refs in $WT" >&2
  exit 2
elif [ $rc -eq 3 ]; then
  echo "unsafe: HEAD commits covered only by remote-tracking refs (prunable) in $WT" >&2
  exit 3
fi

exit 0
