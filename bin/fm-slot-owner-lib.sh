#!/usr/bin/env bash
# bin/fm-slot-owner-lib.sh - the ONE owner of "may this pooled worktree slot be
# released?".
#
# A task's recorded `worktree=` is a HISTORICAL record of a slot the task once
# used, never proof that the task still owns it. Pooled slots are reused: a
# census on 2026-07-24 found ten treehouse slots recorded by more than one task,
# up to six each, and on 2026-07-25 the hazard fired - tearing down one task
# released a lease that a still-live quarantined-paused task also recorded, and
# the pool reissued that exact slot to a new spawn.
#
# So disposal is gated on POSITIVE evidence of a conflict, in three independent
# forms, any one of which retains the lease:
#
#   1. another task recorded in the same home names the same physical slot -
#      the observed incident, and it needs no cooperation from the occupant;
#   2. the slot's ownership stamp names a different task or home - the metadata
#      being trusted is positively stale because the slot was reissued;
#   3. a live agent declared for a DIFFERENT task is running inside the slot
#      (bin/fm-agent-cwd-lib.sh's authoritative process cwd).
#
# Retain means the lease is not returned to the pool: firstmate finishes the
# rest of the teardown (records and endpoint) and leaves the directory on disk,
# so the slot can never be reissued out from under its other holder. That is
# the records-and-panes-only policy that kept the 2026-07-25 collision harmless,
# made deterministic. It is NOT a work-preservation check and therefore is NOT
# waived by --force: --force is the captain's authority to discard THIS task's
# work, never authority to release another task's slot.
#
# Absence of evidence is not evidence: a slot with no stamp (every task spawned
# before stamping existed) and no conflicting reference still disposes normally.
#
# Retention must not be a one-way door either. A task that retains on rule 1 AND
# still completes its own teardown gives up its own stamp as it goes
# (fm_slot_stamp_relinquish), so the holder left behind can still release the
# slot once nothing references it. A caller that refuses outright keeps every
# record and therefore keeps the stamp too, because a refused operation changes
# nothing. A stamp naming someone ELSE is never cleared either, because that
# stamp is what stops a stale task from disposing of a slot whose real occupant
# is merely paused.
# docs/worker-isolation.md owns the operator reclaim path for a slot that was
# already leaked before this rule existed.
#
# The stamp lives in the worktree's PRIVATE git directory, never in the working
# tree, so it can never dirty a status check or leak into a commit. Writing is
# refused for anything that is not a linked worktree, so a primary checkout can
# never be stamped as a disposable slot.
#
# docs/worker-isolation.md owns how this mechanism fits with the other three.
#
# This file is sourced by scripts and has no side effects on source.

_FM_SLOT_OWNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-agent-cwd-lib.sh
. "$_FM_SLOT_OWNER_LIB_DIR/fm-agent-cwd-lib.sh"

FM_SLOT_OWNER_STAMP_NAME=fm-slot-owner

# The exact prefix of the rule-1 (metadata reference) retain verdict. One owner,
# because fm_slot_stamp_relinquish keys the only stamp clear that is safe off
# this specific reason.
FM_SLOT_RETAIN_META_PREFIX='retain: slot is also recorded by task(s) '

# fm_slot_stamp_path <worktree>: the stamp path for a LINKED worktree, or 1 for
# a plain checkout (whose git dir is shared and must never be stamped).
fm_slot_stamp_path() {
  local wt=$1 git_dir common_dir
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  git_dir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  common_dir=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$git_dir" ] && [ -n "$common_dir" ] || return 1
  # --git-common-dir can be relative to the worktree; resolve both physically
  # rather than depending on a git new enough for --path-format=absolute.
  case "$common_dir" in
    /*) ;;
    *) common_dir="$wt/$common_dir" ;;
  esac
  git_dir=$(fm_agent_canonical_dir "$git_dir") || return 1
  common_dir=$(fm_agent_canonical_dir "$common_dir") || return 1
  [ "$git_dir" != "$common_dir" ] || return 1
  printf '%s/%s' "$git_dir" "$FM_SLOT_OWNER_STAMP_NAME"
}

# fm_slot_stamp_write <worktree> <task-id> <home>: record current ownership of
# the slot. Best-effort by design - a slot that cannot be stamped simply has no
# stamp evidence later, which is the pre-existing behavior.
fm_slot_stamp_write() {
  local wt=$1 id=$2 home=$3 path
  [ -n "$id" ] && [ -n "$home" ] || return 1
  path=$(fm_slot_stamp_path "$wt") || return 1
  printf 'task=%s\nhome=%s\n' "$id" "$home" > "$path" 2>/dev/null || return 1
}

# fm_slot_stamp_field <worktree> <task|home>: the stamped value, or 1.
fm_slot_stamp_field() {
  local wt=$1 field=$2 path value
  path=$(fm_slot_stamp_path "$wt") || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  value=$(sed -n "s/^$field=//p" "$path" 2>/dev/null | head -1)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# fm_slot_stamp_clear <worktree>: drop the stamp once the slot is released.
fm_slot_stamp_clear() {
  local wt=$1 path
  path=$(fm_slot_stamp_path "$wt") || return 0
  rm -f "$path" 2>/dev/null || true
}

# fm_slot_meta_worktree <meta-file>: the recorded worktree path, or empty.
fm_slot_meta_worktree() {
  local meta=$1
  [ -f "$meta" ] || return 0
  grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# fm_slot_same_path <a> <b>: physical comparison where both paths exist, exact
# string comparison otherwise, so a recorded slot whose directory is already
# gone is still recognized as the same reference.
fm_slot_same_path() {
  local a=${1:-} b=${2:-} ra rb
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  ra=$(fm_agent_canonical_dir "$a") || return 1
  rb=$(fm_agent_canonical_dir "$b") || return 1
  [ "$ra" = "$rb" ]
}

# fm_slot_meta_referencing_tasks <state-dir> <task-id> <worktree>: other task
# ids in this home whose metadata names the same slot, newline separated.
fm_slot_meta_referencing_tasks() {
  local state=$1 self=$2 wt=$3 meta id other found=1
  [ -d "$state" ] || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$id" != "$self" ] || continue
    other=$(fm_slot_meta_worktree "$meta")
    [ -n "$other" ] || continue
    fm_slot_same_path "$other" "$wt" || continue
    printf '%s\n' "$id"
    found=0
  done
  return "$found"
}

# fm_slot_live_occupant_tasks <worktree> <task-id>: other tasks whose declared
# live agent process is running inside the slot right now, newline separated
# and deduplicated. Requires procfs; a host without it simply contributes no
# evidence from this source.
fm_slot_live_occupant_tasks() {
  local wt=$1 self=$2 wt_real entry pid task cwd hits
  wt_real=$(fm_agent_canonical_dir "$wt") || return 1
  [ -d /proc ] || return 1
  hits=
  for entry in /proc/[0-9]*; do
    [ -d "$entry" ] || continue
    pid=${entry#/proc/}
    task=$(fm_agent_proc_env "$pid" FM_AGENT_TASK) || continue
    [ -n "$task" ] || continue
    [ "$task" != "$self" ] || continue
    cwd=$(fm_agent_proc_cwd "$pid") || continue
    cwd=$(fm_agent_canonical_dir "$cwd") || continue
    fm_agent_path_within "$wt_real" "$cwd" || continue
    hits="$hits$task"$'\n'
  done
  [ -n "$hits" ] || return 1
  printf '%s' "$hits" | LC_ALL=C sort -u
}

# fm_slot_join_ids <newline-separated>: comma-joined single line.
fm_slot_join_ids() {
  printf '%s' "$1" | LC_ALL=C sort -u | tr '\n' ',' | sed 's/,$//'
}

# fm_slot_disposal_verdict <state-dir> <task-id> <worktree> <home>
# Print exactly `dispose` or `retain: <reason>`.
fm_slot_disposal_verdict() {
  local state=$1 self=$2 wt=$3 home=$4 stamp_task stamp_home refs occupants
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'dispose'
    return 0
  fi
  if refs=$(fm_slot_meta_referencing_tasks "$state" "$self" "$wt"); then
    printf '%s%s in this home' "$FM_SLOT_RETAIN_META_PREFIX" "$(fm_slot_join_ids "$refs")"
    return 0
  fi
  if stamp_task=$(fm_slot_stamp_field "$wt" task); then
    if [ "$stamp_task" != "$self" ]; then
      printf 'retain: slot ownership stamp names task %s, not %s' "$stamp_task" "$self"
      return 0
    fi
    if stamp_home=$(fm_slot_stamp_field "$wt" home); then
      if [ -n "$home" ] && ! fm_slot_same_path "$stamp_home" "$home"; then
        printf 'retain: slot ownership stamp names home %s, not %s' "$stamp_home" "$home"
        return 0
      fi
    fi
  fi
  if occupants=$(fm_slot_live_occupant_tasks "$wt" "$self"); then
    printf 'retain: a live agent for task(s) %s is running in the slot' "$(fm_slot_join_ids "$occupants")"
    return 0
  fi
  printf 'dispose'
}

# fm_slot_stamp_relinquish <worktree> <task-id> <verdict>
# Give up THIS task's claim on a slot it is retaining, so a retained lease can
# still be released later by whoever is left holding it.
#
# Only a caller that PROCEEDS past the gate and goes on to delete this task's
# own records may ask for this. A caller that refuses outright and preserves
# every record must not: nothing was torn down, ownership did not change, and
# erasing the stamp there would strip the rule-2 evidence that stops a stale
# sibling from later disposing of a slot still holding this task's paused work.
#
# Without this the gate is a one-way door. Task B stamps a slot, paused task A's
# stale metadata also names it, B tears down and retains on rule 1, and B's
# metadata is then removed. When A finally tears down, no reference is left to
# justify the retention - but the stamp still names B, so rule 2 retains forever
# and the pool has silently lost a slot that nothing references.
#
# The clear is deliberately NARROW, and the narrowness is the whole safety
# argument:
#   - retained by ANOTHER TASK'S METADATA while the stamp names SELF: this is
#     the true owner handing the slot back to the other holder, so its stamp
#     must not outlive it;
#   - retained because the stamp names a DIFFERENT task: PRESERVE it. The stamp
#     is positive evidence the slot was reissued to someone else, and clearing
#     it would let a later teardown of the stale task dispose of a slot whose
#     real occupant merely has no live process at that moment (paused or exited
#     work), destroying preserved work - strictly worse than the leak above;
#   - retained by a live occupant: PRESERVE it, for the same reason.
# Metadata references stay checked first and stay authoritative in
# fm_slot_disposal_verdict; that ordering is what protects a live-but-paused
# task from having its slot reissued, and nothing here weakens it.
#
# Always succeeds: a slot with no stamp, or one stamped for someone else, simply
# keeps whatever evidence it has.
fm_slot_stamp_relinquish() {  # <worktree> <task-id> <verdict>
  local wt=$1 self=$2 verdict=$3 stamp_task
  case "$verdict" in
    "$FM_SLOT_RETAIN_META_PREFIX"*) ;;
    *) return 0 ;;
  esac
  stamp_task=$(fm_slot_stamp_field "$wt" task) || return 0
  [ "$stamp_task" = "$self" ] || return 0
  fm_slot_stamp_clear "$wt"
  return 0
}
