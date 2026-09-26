#!/usr/bin/env bash
# Startup detection of Treehouse pool slots a finished task never returned.
# Usage: . bin/fm-pool-leak-lib.sh   (needs bin/fm-backend.sh and
#                                     bin/fm-treehouse-slot-lib.sh sourced first)
#
# A pool slot stays out of the pool until cleanup returns it, and Treehouse
# refuses to hand out a slot whose copy is dirty, so a finished task whose
# cleanup never ran costs the whole fleet that slot until someone notices. On
# 2026-09-15 every launch for one project failed for an hour with 11 of 16 slots
# held by tasks that had already finished. Nothing here returns, resets, or
# claims a slot, and it prints no command that would: it names which slots are
# held and what was observed about each, because two of those slots held staged
# work no branch carried and an automatic sweep would have destroyed it.
#
# Scope: the slots of every pool this home's own task records reach, judged
# against the claim each slot carries (bin/fm-treehouse-slot-lib.sh) and against
# the pool's own treehouse-state.json. The claimant is asked first: a task whose
# worker is still running AND whose own record still names this slot holds it,
# which is the normal state and is never reported, whatever the pool says. A
# live claimant whose record names some other slot left this claim behind, so
# that one IS reported. Once the worker is gone, a slot the pool no longer
# records, a slot the pool records a running process under, and a pool state
# that cannot be read are each reported on their own terms. The pool file names no task - its per-slot fields are
# name, path, created_at, owner_pid, and owner_started_at - so "this slot was
# handed to a different task" is not a state this check can reach, and every
# report says so rather than inferring it from the pid. A claim
# names the task AND the home that took the slot, so the record it points at is
# read in that home rather than by searching every home on the machine. A claim
# whose home is a directory that does not exist here belongs to another machine
# and is left alone; a claim carrying no home at all names no record anywhere and
# is reported. A slot carrying NO claim is reported by nothing: claims arrived on
# 2026-09-07, so an unclaimed slot was taken before them, and nothing in the
# slot says which of the records naming it is its current holder - the same
# reason cleanup refuses one. Those are a closed, shrinking set.
#
# Pure detection: no locks, no writes, and no network. Every line is prefixed
# POOL_LEAK: and is safe to print in a read-only session.

_FM_POOL_LEAK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pools reachable from one home's task records, one absolute path per line.
# Discovery reads only this home's state/*.meta records carrying both worktree=
# and project=, so a pool no surviving record names is not discovered and none
# of its slots are examined.
fm_pool_leak_pools() {  # <state-dir>
  local state=$1 meta worktree project slot pool key seen
  seen=$'\n'
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    worktree=$(fm_meta_get "$meta" worktree)
    project=$(fm_meta_get "$meta" project)
    [ -n "$worktree" ] && [ -n "$project" ] || continue
    slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || continue
    pool=$(dirname "$(dirname "$slot")")
    key="$project -> $pool"
    case "$seen" in
      *$'\n'"$key"$'\n'*) printf '%s\n' "$pool"; continue ;;
    esac
    fm_treehouse_pool_slot "$project" "$worktree" || continue
    seen="$seen$key"$'\n'
    printf '%s\n' "$pool"
  done | LC_ALL=C sort -u
}

# What the pool itself records for each of its slots, one
# "<slot-directory><tab><owner pid><tab><owner started at>" line. Those are the
# only fields Treehouse writes per worktree besides name, path, and created_at:
# the pool records that SOMETHING is running under a slot, never which task it
# belongs to.
# Returns 2 when the pool's state cannot be read as the pool's state at all -
# missing, not JSON, or no jq to parse it - because an unreadable pool record is
# not evidence that a claim is still current.
fm_pool_leak_pool_slots() {  # <pool>
  local pool=$1 state raw path pid started dir
  state="$pool/treehouse-state.json"
  [ -f "$state" ] && [ ! -L "$state" ] || return 2
  command -v jq >/dev/null 2>&1 || return 2
  jq -e '(.worktrees | type) == "array"' "$state" >/dev/null 2>&1 || return 2
  raw=$(jq -r '.worktrees[]
                | [(.path // ""), (.owner_pid // "" | tostring),
                   (.owner_started_at // "" | tostring)] | @tsv' \
    "$state" 2>/dev/null) || return 2
  while IFS=$'\t' read -r path pid started; do
    [ -n "$path" ] || continue
    dir=$(CDPATH='' cd -- "$(dirname "$path")" 2>/dev/null && pwd -P) \
      || dir=$(dirname "$path")
    printf '%s\t%s\t%s\n' "$dir" "$pid" "$started"
  done <<EOF
$raw
EOF
}

# 0 = the pool records a worktree under this slot, and prints its
#     "<pid><tab><started at>";
# 1 = the pool's own record lists no worktree under this slot directory.
fm_pool_leak_slot_pool_entry() {  # <slot-lines> <slot>
  local lines=$1 slot=$2 line
  while IFS= read -r line; do
    case "$line" in
      "$slot"$'\t'*) printf '%s\n' "${line#*$'\t'}"; return 0 ;;
    esac
  done <<EOF
$lines
EOF
  return 1
}

# Whether the process the pool recorded under a slot is still that process.
# A pid whose start time cannot be read back is treated as running: this decides
# only whether a destructive command is offered, so an unresolvable process must
# hold the slot rather than release it.
fm_pool_leak_slot_in_use() {  # <pid> <started-at-ms>
  local pid=$1 started=$2 lstart epoch want delta
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 0 ] 2>/dev/null || return 1
  lstart=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  lstart=${lstart#"${lstart%%[![:space:]]*}"}
  [ -n "$lstart" ] || return 1
  case "$started" in ''|*[!0-9]*) return 0 ;; esac
  epoch=$(date -j -f '%a %b %e %T %Y' "$lstart" +%s 2>/dev/null) \
    || epoch=$(date -d "$lstart" +%s 2>/dev/null) \
    || return 0
  want=$(( started / 1000 ))
  delta=$(( epoch - want ))
  [ "$delta" -ge 0 ] || delta=$(( 0 - delta ))
  [ "$delta" -le 2 ]
}

# Whether the task a claim names still has a worker running.
# 0 = a live endpoint, 1 = no live endpoint, 2 = no record to tear down,
# 3 = liveness cannot be determined from this session, with the why in
#     FM_POOL_LEAK_STATE_REASON.
# rc 1 is not proof of death: bin/fm-backend.sh's fm_backend_target_exists
# deliberately reads a query it could not make - a herdr server that is down, an
# unreadable Orca terminal - as "does not exist". It is reported so a human can
# look, and no caller spends it on a destructive decision; nothing here prints a
# command that reaps processes or resets a copy.
FM_POOL_LEAK_STATE_REASON=
fm_pool_leak_task_state() {  # <home> <task-id>
  local meta="$1/state/$2.meta" id=$2 window target backend tool tools remote_host
  FM_POOL_LEAK_STATE_REASON=
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    FM_POOL_LEAK_STATE_REASON="its record could not be read back"
    return 2
  }
  # bin/fm-spawn.sh's remote secondmate record carries no backend= line at all
  # and its endpoint is remote_backend/remote_target on another machine, so the
  # local probe below would query a window that cannot exist here and read a
  # live home as dead. remote_host is the same authority switch
  # bin/fm-fleet-snapshot.sh reads.
  remote_host=$(fm_meta_get "$meta" remote_host)
  [ -z "$remote_host" ] || {
    FM_POOL_LEAK_STATE_REASON="its endpoint lives on remote host $remote_host, which this session cannot probe"
    return 3
  }
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || {
    FM_POOL_LEAK_STATE_REASON="its record carries no endpoint at all, so nothing here was read about a worker"
    return 3
  }
  backend=$(fm_backend_of_meta "$meta")
  tools=$(fm_backend_required_tools "$backend") || {
    FM_POOL_LEAK_STATE_REASON="its record names backend $backend, whose required tools this session cannot list"
    return 3
  }
  for tool in $tools; do
    fm_backend_required_tool_available "$backend" "$tool" || {
      FM_POOL_LEAK_STATE_REASON="its record names backend $backend, whose tool $tool this session cannot resolve"
      return 3
    }
  done
  target=$(fm_backend_target_of_meta "$meta")
  fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id" || return 1
  return 0
}

# One POOL_LEAK line per held slot, or nothing at all.
fm_pool_leak_report() {  # <state-dir>
  local state=$1 pool slot claim_home claim_id rc name known claim_wt claim_slot
  local pool_slots pool_rc entry entry_rc slot_pid slot_started
  while IFS= read -r pool; do
    [ -n "$pool" ] || continue
    pool_rc=0
    pool_slots=$(fm_pool_leak_pool_slots "$pool") || pool_rc=$?
    for slot in "$pool"/*; do
      [ -d "$slot" ] && [ ! -L "$slot" ] || continue
      rc=0
      fm_treehouse_slot_claim_read "$slot" || rc=$?
      name=$(basename "$slot")
      case "$rc" in
        1) continue ;;
        2)
          echo "POOL_LEAK: $pool slot $name carries a slot-owner claim that cannot be read, so nothing can prove whose slot it is; inspect $slot/.fm-slot-owner before any task reuses that slot"
          continue
          ;;
      esac
      claim_id=$FM_TREEHOUSE_SLOT_CLAIM_ID
      claim_home=$FM_TREEHOUSE_SLOT_CLAIM_HOME
      if [ -z "$claim_home" ]; then
        echo "POOL_LEAK: $pool slot $name claims task $claim_id, but its claim records no home, so nothing can find the record whose cleanup returns that slot; inspect $slot for unlanded work, then repair or clear $slot/.fm-slot-owner by hand"
        continue
      fi
      [ -d "$claim_home" ] || continue
      rc=0
      fm_pool_leak_task_state "$claim_home" "$claim_id" || rc=$?
      case "$rc" in
        0)
          claim_wt=$(fm_meta_get "$claim_home/state/$claim_id.meta" worktree)
          if [ -n "$claim_wt" ]; then
            claim_slot=$(CDPATH='' cd -- "$claim_wt" 2>/dev/null && pwd -P) \
              || claim_slot=${claim_wt%/}
            [ "$(dirname "$claim_slot")" = "$slot" ] && continue
          fi
          echo "POOL_LEAK: $pool slot $name is claimed by task $claim_id, whose worker is running but whose own record names ${claim_wt:-no worktree at all}, not this slot; that claim is orphaned, so no task's cleanup will ever return this slot - inspect $slot for unlanded work, then clear $slot/.fm-slot-owner by hand"
          continue
          ;;
        3)
          echo "POOL_LEAK: $pool slot $name is held by task $claim_id, and whether its worker is still running is unknown because $FM_POOL_LEAK_STATE_REASON; settle that before tearing the task down"
          continue
          ;;
      esac
      if [ "$pool_rc" -ne 0 ]; then
        echo "POOL_LEAK: $pool slot $name claims task $claim_id, but this pool's own $pool/treehouse-state.json could not be read, so nothing here can confirm the slot is still that task's; read that file and $slot by hand before returning anything"
        continue
      fi
      entry_rc=0
      entry=$(fm_pool_leak_slot_pool_entry "$pool_slots" "$slot") || entry_rc=$?
      if [ "$entry_rc" -ne 0 ]; then
        echo "POOL_LEAK: $pool slot $name claims task $claim_id, but this pool's own $pool/treehouse-state.json lists no worktree under that slot directory, so returning it is not the fix; inspect $slot for unlanded work, then clear $slot/.fm-slot-owner by hand"
        continue
      fi
      slot_pid=${entry%%$'\t'*}
      slot_started=${entry#*$'\t'}
      if fm_pool_leak_slot_in_use "$slot_pid" "$slot_started"; then
        case "$rc" in
          1) known="whose worker is gone" ;;
          *) known="for which home $claim_home holds no record at all, so nothing was read about that task's worker" ;;
        esac
        echo "POOL_LEAK: $pool slot $name is claimed by task $claim_id, $known, but the pool records process $slot_pid running under that slot; the pool records no task identity, so whether that process is a successor's cannot be told from it - no command is offered, inspect process $slot_pid and $slot by hand"
        continue
      fi
      case "$rc" in
        1)
          echo "POOL_LEAK: $pool slot $name is still held by task $claim_id, whose recorded endpoint did not answer and whose slot the pool records no live process under; a query that could not be made reads here exactly like an absent one, so confirm that task is finished (FM_HOME=$claim_home $_FM_POOL_LEAK_LIB_DIR/fm-crew-state.sh $claim_id) and inspect $slot for unlanded work before returning the slot"
          ;;
        2)
          echo "POOL_LEAK: $pool slot $name claims task $claim_id, but home $claim_home holds no record for it, so no cleanup command can return that slot; inspect $slot for unlanded work, then clear the claim by hand"
          ;;
      esac
    done
  done < <(fm_pool_leak_pools "$state")
}
