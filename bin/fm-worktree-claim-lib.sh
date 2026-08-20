# shellcheck shell=bash
# Shared pool-slot ownership guard: the one owner of "does another task still
# own this worktree".
# Usage: . bin/fm-worktree-claim-lib.sh
#
# A treehouse pool slot is free, from the pool's point of view, when no durable
# lease reserves it AND no process is running inside it. Firstmate's task
# records are invisible to that decision. Crewmate worktrees used to be taken
# with a bare `treehouse get`, which reserves nothing, so a slot was held only
# for as long as the AGENT lived - while the TASK that owns the work lives much
# longer, through a dead endpoint, an awaited captain decision, or a finished
# run that has not been cleaned up yet. When the agent went away the pool
# handed the slot to a second task, and the first task's cleanup then reset the
# shared directory and returned the slot out from under it.
#
# Two things close that gap, and they are deliberately independent:
#
#   1. fm-spawn.sh now leases every crewmate worktree for the life of the task
#      (bin/fm-spawn.sh, `treehouse get --lease` plus a `cd` into it), and
#      cleanup releases it. That is the structural fix: the pool itself stops
#      offering an owned slot, with no firstmate check in the loop.
#   2. The helpers below are the containment. They answer the ownership
#      question from firstmate's own records, so a slot whose lease was never
#      taken (a worktree acquired before the lease change), lost (a hand-run
#      `treehouse return` or `prune`), or otherwise drifted is still never
#      allocated into and never returned while a live task claims it.
#
# The liveness rule is deliberately asymmetric and fails closed. Only a backend
# that authoritatively reports its endpoint gone (`dead`/`missing`) clears a
# claim. `alive` obviously blocks, and so does every ambiguous, unreadable, or
# unverified answer: "I could not tell whether that agent is there" must never
# be spent as "it is gone" when the cost of being wrong is another task's work.

# Every local below is deliberately prefixed. ShellCheck analyses a sourced
# library in the context of each script that sources it, so an unprefixed local
# named `other` makes an unrelated literal like `other-home` in that script
# parse as arithmetic and raise a spurious warning there.
#
# Resolve <path> to a physical path for comparison, echoing the input unchanged
# when it cannot be resolved. Pool slots are reached through symlinked prefixes
# often enough (/tmp, /var, a symlinked home) that a raw string compare misses
# real collisions.
fm_worktree_claim_realpath() {  # <path>
  local claim_path=$1 claim_resolved
  [ -n "$claim_path" ] || return 0
  if claim_resolved=$(CDPATH='' cd -- "$claim_path" 2>/dev/null && pwd -P); then
    printf '%s' "$claim_resolved"
  else
    printf '%s' "$claim_path"
  fi
}

# Echo the liveness of the task recorded in <meta>: `live` when its endpoint is
# present or cannot be authoritatively ruled out, `gone` only when a backend
# confirms the endpoint is absent.
fm_worktree_claim_liveness() {  # <meta-file>
  local claim_meta=$1 claim_backend claim_window
  claim_window=$(fm_meta_get "$claim_meta" window)
  if [ -z "$claim_window" ]; then
    # A record with no endpoint at all is still a record of owned work; the
    # worktree it names may hold that work. Refuse to call it gone.
    printf 'live'
    return 0
  fi
  claim_backend=$(fm_backend_of_meta "$claim_meta")
  case "$(fm_backend_agent_alive "$claim_backend" "$claim_window")" in
    dead) printf 'gone' ;;
    *) printf 'live' ;;
  esac
}

# Find a task OTHER than <self-id> whose metadata still claims <worktree>.
# Prints "<task-id>" and returns 0 when a LIVE claimant exists, else returns 1.
# <self-id> may be empty to check every record.
fm_worktree_live_claimant() {  # <state-dir> <self-id> <worktree>
  local claim_state=$1 claim_self=$2 claim_wt=$3
  local claim_meta claim_id claim_other_wt claim_want
  [ -n "$claim_wt" ] || return 1
  [ -d "$claim_state" ] || return 1
  claim_want=$(fm_worktree_claim_realpath "$claim_wt")
  for claim_meta in "$claim_state"/*.meta; do
    [ -f "$claim_meta" ] || continue
    claim_id=$(basename "$claim_meta" .meta)
    [ "$claim_id" != "$claim_self" ] || continue
    claim_other_wt=$(fm_meta_get "$claim_meta" worktree)
    [ -n "$claim_other_wt" ] || continue
    [ "$(fm_worktree_claim_realpath "$claim_other_wt")" = "$claim_want" ] || continue
    if [ "$(fm_worktree_claim_liveness "$claim_meta")" = live ]; then
      printf '%s' "$claim_id"
      return 0
    fi
  done
  return 1
}
