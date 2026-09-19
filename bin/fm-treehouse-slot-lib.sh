#!/usr/bin/env bash
# Treehouse pool-slot identity and the Firstmate slot-owner claim.
# Usage: . bin/fm-treehouse-slot-lib.sh
# Pure: defines functions only, touches no state directory, and creates nothing
# at source time, so a read-only detect path can load it (bin/fm-bootstrap.sh).
# This is the single owner of the claim's location, format, and states; every
# reader and writer - spawn, cleanup, and the startup leak check - goes through
# these functions rather than parsing .fm-slot-owner itself.

# A Treehouse slot has the managed pool's fixed <pool>/<slot>/<repo> layout.
# Require both its pool state and the same Git common directory as the recorded
# project; an ordinary linked worktree is not evidence that Treehouse owns it.
fm_treehouse_pool_slot() {  # <project-dir> <worktree>
  local project=$1 worktree=$2 slot pool state project_common slot_common
  [ -d "$project" ] && [ -d "$worktree" ] || return 1
  slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || return 1
  pool=$(dirname "$(dirname "$slot")")
  state="$pool/treehouse-state.json"
  [ -f "$state" ] && [ ! -L "$state" ] || return 1
  project_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  slot_common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  project_common=$(CDPATH='' cd -- "$project_common" 2>/dev/null && pwd -P) || return 1
  slot_common=$(CDPATH='' cd -- "$slot_common" 2>/dev/null && pwd -P) || return 1
  [ "$project_common" = "$slot_common" ]
}

# Slot-owner claim: which task a Treehouse pool slot currently belongs to.
#
# Treehouse can record ownership durably: `treehouse get --lease --lease-holder`
# reserves a slot under a label until `treehouse return --if-lease-holder`
# releases it, and Firstmate uses exactly that for secondmate homes
# (bin/fm-home-seed.sh). Crewmate spawns do not take that path: they acquire
# their slot through the interactive pane-driven `treehouse get`, whose state
# entry is a live process lease (owner_pid plus owner_started_at, and `treehouse
# status` reports in-use from the processes actually running under the path).
# That answers "is anything running here", never "which task owns this", and it
# is released by the very event that makes a task record stale - the worker
# exiting - so a slot whose lease has lapsed reads identical whether it is still
# this task's or has since been handed to another one. Firstmate therefore keeps
# its own claim on top: one file naming the task that took the slot, written by
# bin/fm-spawn.sh under the same project lock that allocates the slot and
# released by bin/fm-teardown.sh when the slot goes back to the pool. Moving
# crewmate spawns onto the durable lease is separate follow-up work.
#
# The claim lives at <pool>/<slot>/.fm-slot-owner - a sibling of the repo
# checkout rather than a file inside it - so claiming a slot can never dirty the
# copy teardown's landed-work checks inspect, and a returned slot carries no
# untracked leftover from it.
# The claim is a SIBLING of the checkout, so it outlives a checkout deleted by
# hand and the marker must still resolve then: fall back to the recorded path
# lexically when it cannot be canonicalized.
fm_treehouse_slot_owner_marker() {  # <worktree>
  local worktree=$1 slot
  [ -n "$worktree" ] || return 1
  slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || slot=${worktree%/}
  printf '%s/.fm-slot-owner\n' "$(dirname "$slot")"
}

# Claim a pool slot for a task, replacing whatever the previous holder left.
# The rename is atomic, so a reader either sees the old claim or the new one.
fm_treehouse_slot_owner_claim() {  # <worktree> <task-id> <home>
  local worktree=$1 id=$2 home=$3 marker tmp
  [ -n "$id" ] || return 1
  marker=$(fm_treehouse_slot_owner_marker "$worktree") || return 1
  # Only a plain claim file may be replaced: renaming onto a directory would
  # move the new claim inside it and leave the slot reading as unclaimable.
  if { [ -e "$marker" ] || [ -L "$marker" ]; } \
     && { [ ! -f "$marker" ] || [ -L "$marker" ]; }; then
    return 1
  fi
  tmp="$marker.tmp.${BASHPID:-$$}"
  rm -f "$tmp" || return 1
  {
    printf 'task=%s\n' "$id"
    printf 'home=%s\n' "$home"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$marker" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# The claim beside one pool slot directory, parsed once for every reader.
# Sets FM_TREEHOUSE_SLOT_CLAIM_ID and FM_TREEHOUSE_SLOT_CLAIM_HOME and returns
# 0 when a claim was read, 1 when the slot carries none, and 2 when something
# is there that cannot be read as a claim.
fm_treehouse_slot_claim_read() {  # <slot-dir>
  local slot=$1 marker line owner_id='' owner_home=''
  FM_TREEHOUSE_SLOT_CLAIM_ID=
  FM_TREEHOUSE_SLOT_CLAIM_HOME=
  marker="$slot/.fm-slot-owner"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      task=*) owner_id=${line#task=} ;;
      home=*) owner_home=${line#home=} ;;
    esac
  done < "$marker" || return 2
  [ -n "$owner_id" ] || return 2
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_TREEHOUSE_SLOT_CLAIM_ID=$owner_id
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_TREEHOUSE_SLOT_CLAIM_HOME=$owner_home
  return 0
}

# Read the claim on a pool slot and compare it with a task id.
# Sets FM_TREEHOUSE_SLOT_OWNER to one of:
#   mine   - the claim names this task
#   other  - the claim names a different task, so the slot was reassigned
#   absent - no claim: the slot was taken before claims existed, or returned since
#   unsafe - a claim file exists but cannot be read as a claim
# FM_TREEHOUSE_SLOT_OWNER_ID and FM_TREEHOUSE_SLOT_OWNER_HOME carry the recorded
# claimant as evidence. The home is reported, never matched: a home that moved
# must not turn a task's own slot into a refusal.
fm_treehouse_slot_owner_state() {  # <worktree> <task-id>
  local worktree=$1 id=$2 marker rc=0
  FM_TREEHOUSE_SLOT_OWNER=unsafe
  FM_TREEHOUSE_SLOT_OWNER_ID=
  FM_TREEHOUSE_SLOT_OWNER_HOME=
  marker=$(fm_treehouse_slot_owner_marker "$worktree") || return 0
  fm_treehouse_slot_claim_read "$(dirname "$marker")" || rc=$?
  case "$rc" in
    1) FM_TREEHOUSE_SLOT_OWNER=absent; return 0 ;;
    2) return 0 ;;
  esac
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_TREEHOUSE_SLOT_OWNER_ID=$FM_TREEHOUSE_SLOT_CLAIM_ID
  # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
  FM_TREEHOUSE_SLOT_OWNER_HOME=$FM_TREEHOUSE_SLOT_CLAIM_HOME
  if [ "$FM_TREEHOUSE_SLOT_CLAIM_ID" = "$id" ]; then
    FM_TREEHOUSE_SLOT_OWNER=mine
  else
    FM_TREEHOUSE_SLOT_OWNER=other
  fi
}

# Drop a task's own claim once its slot is back in the pool. Never removes
# another task's claim, so a misdirected release cannot strip the evidence that
# protects the slot's real owner.
fm_treehouse_slot_owner_release() {  # <worktree> <task-id>
  local worktree=$1 id=$2 marker
  fm_treehouse_slot_owner_state "$worktree" "$id"
  [ "$FM_TREEHOUSE_SLOT_OWNER" = mine ] || return 0
  marker=$(fm_treehouse_slot_owner_marker "$worktree") || return 0
  rm -f "$marker" 2>/dev/null || true
}
