#!/usr/bin/env bash
# Shared readers for config/proplane-agent-branches (PropPlane multi-agent ladder).
set -u

# Resolve the config path fail-closed. `${FM_HOME:-}/config/...` silently produced
# the filesystem-root path /config/proplane-agent-branches when FM_HOME was unset,
# which reads as "no sandboxes configured" to every caller — including the remote
# branch pruner, whose keeper list then narrowed to three hardcoded names.
if [ -z "${FM_PROPLANE_AGENT_CONFIG:-}" ]; then
  if [ -z "${FM_HOME:-}" ]; then
    echo "fm-proplane-agent-branches-lib: FM_HOME unset and FM_PROPLANE_AGENT_CONFIG unset" >&2
    # Resolve to a path that cannot exist rather than leaving the variable unset or
    # pointing at the filesystem root. `return` alone only stops callers that run
    # under `set -e`; with the sentinel, every reader below takes its
    # "config missing" branch and returns non-zero no matter how it was invoked.
    FM_PROPLANE_AGENT_CONFIG=/nonexistent/fm-proplane-agent-branches-unresolved
    # shellcheck disable=SC2317  # reachable when executed rather than sourced: `return` fails there, so `exit` is what stops it.
    return 1 2>/dev/null || exit 1
  fi
  FM_PROPLANE_AGENT_CONFIG="${FM_HOME}/config/proplane-agent-branches"
fi

fm_proplane_agent_git_root() {
  local key root
  [ -f "$FM_PROPLANE_AGENT_CONFIG" ] || return 1
  while IFS=$'\t' read -r key root _; do
    case "$key" in ''|'#'*) continue ;; esac
    if [ "$key" = GIT_ROOT ]; then
      printf '%s\n' "$root"
      return 0
    fi
  done < "$FM_PROPLANE_AGENT_CONFIG"
  return 1
}

# Prints one line per agent row: branch<TAB>worktree<TAB>port
fm_proplane_agent_rows() {
  [ -f "$FM_PROPLANE_AGENT_CONFIG" ] || return 1
  awk -F '\t' '
    /^#/ || NF < 3 { next }
    $1 == "GIT_ROOT" { next }
    { print $1 "\t" $2 "\t" $3 }
  ' "$FM_PROPLANE_AGENT_CONFIG"
}

fm_proplane_agent_integration_rows() {
  fm_proplane_agent_rows | awk -F '\t' '$1 == "prakrit" { print; found=1 } END { exit !found }'
}

fm_proplane_agent_sandbox_rows() {
  fm_proplane_agent_rows | awk -F '\t' '$1 != "prakrit" { print }'
}

# Sandboxes + prakrit integration row (for e2e across all review ports).
fm_proplane_agent_all_review_rows() {
  fm_proplane_agent_rows
}

# Keeper branches allowed on origin (agents never create others).
fm_proplane_agent_keeper_branches() {
  fm_proplane_agent_sandbox_rows | awk -F '\t' '{ print $1 }'
  printf '%s\n' prakrit main production
}

fm_proplane_agent_is_sandbox() {
  local want=$1
  fm_proplane_agent_sandbox_rows | awk -F '\t' -v w="$want" '$1 == w { found=1 } END { exit !found }'
}

# True when a worktree holds work that a hard reset would destroy: uncommitted
# tracked edits, staged changes, or untracked files that are not ignored.
# Firstmate never tears down unlanded work, so every reset path consults this.
#
# A `git status` that FAILS answers "unknown", not "clean". A stale .git pointer
# or a held index lock produces no porcelain output, and reading that as an empty
# worktree would let a hard reset through exactly when the guard cannot see what
# it would destroy. This guard may only ever become stricter, so it fails closed.
fm_proplane_worktree_is_dirty() {
  local worktree=$1 status
  status=$(git -C "$worktree" status --porcelain 2>/dev/null) || return 0
  [ -n "$status" ]
}

# Guard a destructive reset. Returns non-zero (caller should abort) when the
# worktree is dirty and the caller was not explicitly authorized to discard.
# $3 is the caller's force flag: 1 means the captain asked for the discard.
fm_proplane_assert_resettable() {
  local worktree=$1 label=$2 force=${3:-0} state
  fm_proplane_worktree_is_dirty "$worktree" || return 0
  if [ "$force" -eq 1 ]; then
    echo "$label: discarding uncommitted work in $worktree (--force)" >&2
    return 0
  fi
  # `git status` failing is why the refusal fired in the unreadable case, so its
  # error is the state to show; an operator who sees an empty listing instead
  # cannot tell a guard that worked from one that misfired.
  state=$(git -C "$worktree" status --short 2>&1) || state="(git status failed: $state)"
  {
    echo "$label: REFUSING to reset $worktree — it has uncommitted work that a"
    echo "  hard reset would destroy, or its state could not be read. Commit or"
    echo "  stash it, or re-run with --force only if you intend to discard it."
    echo "  Current state:"
    printf '%s\n' "$state" | sed 's/^/    /'
  } >&2
  return 1
}
