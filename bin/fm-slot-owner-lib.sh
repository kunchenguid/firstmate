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
#   1. another task recorded in a discoverable home names the same physical
#      slot - the observed incident, and it needs no cooperation from the
#      occupant;
#   2. the slot's ownership stamp names a different task or home - the metadata
#      being trusted is positively stale because the slot was reissued;
#   3. a declared worker process is running inside the slot, whether or not its
#      current endpoint metadata still points at the slot (bin/fm-agent-cwd-lib.sh's
#      authoritative process cwd).
#
# Retain means the lease is not returned to the pool: firstmate finishes the
# rest of the teardown (records and endpoint) and leaves the directory on disk,
# so the slot can never be reissued out from under its other holder. That is
# the records-and-panes-only policy that kept the 2026-07-25 collision harmless,
# made deterministic. It is NOT a work-preservation check and therefore is NOT
# waived by --force: --force is the captain's authority to discard THIS task's
# work, never authority to release another task's slot.
#
# Absence of evidence is not evidence: a slot with no stamp, or a stamp whose
# ownership record cannot be proved, retains its lease. This is deliberately
# fail-closed: a missing or ambiguous stamp must never expose a pooled slot to
# a different task.
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
# the slot without replacing another owner's evidence.
fm_slot_stamp_write() {
  local wt=$1 id=$2 home=$3 path tmp
  [ -n "$id" ] && [ -n "$home" ] || return 1
  path=$(fm_slot_stamp_path "$wt") || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    fm_slot_stamp_record "$wt" || return 1
    [ "$FM_SLOT_STAMP_TASK" = "$id" ] \
      && [ "$FM_SLOT_STAMP_HOME" = "$home" ] || return 1
    return 0
  fi
  tmp="$path.$$"
  if ! { umask 077 && printf 'task=%s\nhome=%s\n' "$id" "$home" > "$tmp"; }; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! ( set -C; : > "$path" ) 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! cat "$tmp" > "$path" 2>/dev/null; then
    rm -f "$tmp" "$path" 2>/dev/null || true
    return 1
  fi
  rm -f "$tmp" 2>/dev/null || true
  fm_slot_stamp_record "$wt"
}

# fm_slot_stamp_record <worktree>: load one exact, regular ownership record.
# Returns 1 for a missing record and 2 for a present malformed record.
fm_slot_stamp_record() {
  local wt=$1 path line task_seen=0 home_seen=0 invalid=0
  FM_SLOT_STAMP_TASK=
  FM_SLOT_STAMP_HOME=
  path=$(fm_slot_stamp_path "$wt") || return 1
  [ -e "$path" ] || [ -L "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      task=*)
        [ "$task_seen" -eq 0 ] || invalid=1
        FM_SLOT_STAMP_TASK=${line#task=}
        task_seen=1
        ;;
      home=*)
        [ "$home_seen" -eq 0 ] || invalid=1
        FM_SLOT_STAMP_HOME=${line#home=}
        home_seen=1
        ;;
      *) invalid=1 ;;
    esac
  done < "$path" 2>/dev/null || return 2
  [ "$task_seen" -eq 1 ] && [ "$home_seen" -eq 1 ] \
    && [ -n "$FM_SLOT_STAMP_TASK" ] && [ -n "$FM_SLOT_STAMP_HOME" ] \
    && [ "$invalid" -eq 0 ] || return 2
}

# fm_slot_stamp_field <worktree> <task|home>: the stamped value, or 1.
fm_slot_stamp_field() {
  local wt=$1 field=$2
  fm_slot_stamp_record "$wt" || return 1
  case "$field" in
    task) printf '%s' "$FM_SLOT_STAMP_TASK" ;;
    home) printf '%s' "$FM_SLOT_STAMP_HOME" ;;
    *) return 1 ;;
  esac
}

# fm_slot_stamp_clear <worktree>: drop the stamp once the slot is released.
fm_slot_stamp_clear() {
  local wt=$1 path
  if [ ! -e "$wt" ] && [ ! -L "$wt" ]; then
    return 0
  fi
  path=$(fm_slot_stamp_path "$wt") || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    rm -f "$path" || return 1
  fi
  [ ! -e "$path" ] && [ ! -L "$path" ]
}

fm_slot_lock_path() {
  local wt=$1 stamp_path
  stamp_path=$(fm_slot_stamp_path "$wt") || return 1
  printf '%s.lock' "$stamp_path"
}

fm_slot_lock_acquire() {
  local wt=$1 path
  command -v fm_lock_acquire_wait >/dev/null 2>&1 || return 1
  path=$(fm_slot_lock_path "$wt") || return 1
  fm_lock_acquire_wait "$path" || return 1
  FM_SLOT_LOCK_PATH=$path
}

fm_slot_lock_release() {
  local path=${1:-${FM_SLOT_LOCK_PATH:-}}
  [ -n "$path" ] || return 0
  command -v fm_lock_release >/dev/null 2>&1 || return 1
  fm_lock_release "$path"
}

fm_slot_stamp_clear_after_return() {
  local wt=$1 task=$2 path
  if [ ! -e "$wt" ] && [ ! -L "$wt" ]; then
    return 0
  fi
  path=$(fm_slot_stamp_path "$wt") || return 1
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  fm_slot_stamp_record "$wt" || return 1
  [ "$FM_SLOT_STAMP_TASK" = "$task" ] || return 0
  fm_slot_stamp_clear "$wt"
}

# fm_slot_meta_worktree <meta-file>: the recorded worktree path, or empty.
fm_slot_meta_worktree() {
  local meta=$1
  [ -f "$meta" ] || return 0
  grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_slot_registry_homes() {
  local file=$1 line candidate section=all
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ -r "$file" ] || return 2
  case "$file" in
    */AGENTS.md|*/data/backlog.md) section=none ;;
  esac
  while IFS= read -r line; do
    if [ "$section" = none ]; then
      case "$line" in
        '## Secondmate Backlogs') section=all ;;
        '## '*) section=none ;;
        *) continue ;;
      esac
    fi
    candidate=$(printf '%s\n' "$line" \
      | sed -n 's/.*(home:[[:space:]]*\([^;)]*\);.*/\1/p' \
      | sed 's/[[:space:]]*$//')
    case "$candidate" in
      /*) printf '%s\n' "$candidate" ;;
    esac
  done < "$file"
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
# ids in every discoverable home whose metadata names the same slot, newline
# separated.
fm_slot_meta_referencing_tasks() {
  local state=$1 self=$2 wt=$3 current_home home home_real meta id other
  local meta_state registry registry_homes line candidate worktrees found=1 i
  local -a homes=()
  local -A seen=()
  [ -d "$state" ] || return 1
  current_home=$(cd "${state%/}/.." 2>/dev/null && pwd -P) || return 2
  homes+=("$current_home")
  worktrees=$(git -C "$wt" worktree list --porcelain 2>/dev/null) || return 2
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) homes+=("${line#worktree }") ;;
    esac
  done <<< "$worktrees"
  for ((i=0; i<${#homes[@]}; i++)); do
    home=${homes[i]}
    if [ -e "$home" ] || [ -L "$home" ]; then
      home_real=$(fm_agent_canonical_dir "$home" 2>/dev/null) || return 2
    else
      continue
    fi
    [ -n "${seen[$home_real]+seen}" ] && continue
    seen[$home_real]=1
    meta_state="$home_real/state"
    if [ -e "$meta_state" ] && [ ! -d "$meta_state" ]; then
      return 2
    fi
    if [ -d "$meta_state" ] && [ ! -r "$meta_state" ]; then
      return 2
    fi
    for meta in "$meta_state"/*.meta; do
      [ -f "$meta" ] || continue
      [ -r "$meta" ] || return 2
      id=$(basename "$meta" .meta)
      [ "$home_real" = "$current_home" ] && [ "$id" = "$self" ] && continue
      other=$(fm_slot_meta_worktree "$meta")
      [ -n "$other" ] || continue
      fm_slot_same_path "$other" "$wt" || continue
      printf '%s\n' "$id"
      found=0
      candidate=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      case "$candidate" in
        /*) homes+=("$candidate") ;;
      esac
    done
    for registry in "$home_real/data/secondmates.md" \
      "$home_real/data/backlog.md" "$home_real/AGENTS.md"; do
      registry_homes=$(fm_slot_registry_homes "$registry") || return 2
      while IFS= read -r candidate; do
        case "$candidate" in
          /*) homes+=("$candidate") ;;
        esac
      done <<< "$registry_homes"
    done
  done
  return "$found"
}

# fm_slot_endpoint_occupant_tasks <worktree> <task-id> <home> <role> <backend> <target>:
# inspect only the process bound to this task's already-validated backend
# endpoint. A durable task lease prevents Treehouse from assigning the slot to
# another task, so a host-wide process census adds no ownership proof and lets
# unrelated unreadable /proc entries block every clean teardown.
#
# Returns 0 with a foreign or unidentified occupant proven inside the slot, 1
# when the endpoint process is this exact task or is proven outside the slot,
# and 2 when the endpoint-bound process cannot be proved stably.
fm_slot_endpoint_occupant_tasks() {
  local wt=$1 self=$2 self_home=$3 self_role=$4 backend=$5 target=$6
  local wt_real pid current cwd env task home role
  wt_real=$(fm_agent_canonical_dir "$wt") || return 2
  command -v fm_backend_foreground_process_pid >/dev/null 2>&1 || return 2
  pid=$(fm_backend_foreground_process_pid "$backend" "$target") || return 2
  fm_agent_pid_is_numeric "$pid" || return 2
  cwd=$(fm_agent_proc_cwd "$pid") || return 2
  cwd=$(fm_agent_canonical_dir "$cwd") || return 2
  env=$(fm_agent_environ "$pid" 2>/dev/null || true)
  current=$(fm_backend_foreground_process_pid "$backend" "$target") || return 2
  [ "$current" = "$pid" ] || return 2
  fm_agent_path_within "$wt_real" "$cwd" || return 1
  task=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_TASK=//p' | head -1)
  home=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_OWNER_HOME=//p' | head -1)
  role=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_ROLE=//p' | head -1)
  if [ "$task" = "$self" ] && [ "$role" = "$self_role" ] \
     && fm_slot_same_path "$home" "$self_home"; then
    return 1
  fi
  printf '%s\n' "${task:-unidentified-process-$pid}"
}

fm_slot_process_occupant_tasks() {
  fm_agent_worktree_process_census "$1"
}

# fm_slot_join_ids <newline-separated>: comma-joined single line.
fm_slot_join_ids() {
  printf '%s' "$1" | LC_ALL=C sort -u | tr '\n' ',' | sed 's/,$//'
}

# fm_slot_disposal_verdict <state-dir> <task-id> <worktree> <stamp-home> <worker-home> <role> <endpoint-state> <backend> <target>
# Print exactly `dispose` or `retain: <reason>`.
fm_slot_disposal_verdict() {
  local state=$1 self=$2 wt=$3 stamp_owner_home=${4:-}
  local worker_home=${5:-$stamp_owner_home} role=${6:-crewmate}
  local endpoint_state=${7:-unknown} backend=${8:-} target=${9:-}
  local stamp_task stamp_home stamp_path refs occupants process_occupants
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'retain: recorded worktree is missing; lease ownership cannot be proved'
    return 0
  fi
  if refs=$(fm_slot_meta_referencing_tasks "$state" "$self" "$wt"); then
    printf '%s%s' "$FM_SLOT_RETAIN_META_PREFIX" "$(fm_slot_join_ids "$refs")"
    return 0
  elif [ "$?" -eq 2 ]; then
    printf 'retain: all-home slot metadata evidence is unavailable'
    return 0
  fi
  stamp_path=$(fm_slot_stamp_path "$wt" 2>/dev/null || true)
  if [ -z "$stamp_path" ]; then
    printf 'retain: slot ownership stamp path is unavailable'
    return 0
  fi
  if [ ! -e "$stamp_path" ] && [ ! -L "$stamp_path" ]; then
    printf 'retain: slot ownership stamp is missing'
    return 0
  fi
  if ! fm_slot_stamp_record "$wt"; then
    printf 'retain: slot ownership stamp is present but malformed'
    return 0
  fi
  stamp_task=$FM_SLOT_STAMP_TASK
  stamp_home=$FM_SLOT_STAMP_HOME
  if [ "$stamp_task" != "$self" ]; then
    printf 'retain: slot ownership stamp names task %s, not %s' "$stamp_task" "$self"
    return 0
  fi
  if [ -n "$stamp_owner_home" ] && ! fm_slot_same_path "$stamp_home" "$stamp_owner_home"; then
    printf 'retain: slot ownership stamp names home %s, not %s' "$stamp_home" "$stamp_owner_home"
    return 0
  fi
  case "$endpoint_state" in
    closed)
      if process_occupants=$(fm_slot_process_occupant_tasks "$wt"); then
        printf 'retain: declared worker process for task(s) %s is running in the slot' \
          "$(fm_slot_join_ids "$process_occupants")"
        return 0
      elif [ "$?" -eq 2 ]; then
        printf 'retain: authoritative slot-occupant evidence is unavailable'
        return 0
      fi
      ;;
    live)
      if occupants=$(fm_slot_endpoint_occupant_tasks \
        "$wt" "$self" "$worker_home" "$role" "$backend" "$target"); then
        printf 'retain: the endpoint-bound process for task(s) %s is running in the slot' \
          "$(fm_slot_join_ids "$occupants")"
        return 0
      elif [ "$?" -eq 2 ]; then
        printf 'retain: authoritative endpoint-occupant evidence is unavailable'
        return 0
      fi
      ;;
    *)
      printf 'retain: authoritative endpoint-occupant evidence is unavailable'
      return 0
      ;;
  esac
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
# Returns nonzero when clearing this task's current stamp cannot be verified.
fm_slot_stamp_relinquish() {  # <worktree> <task-id> <verdict>
  local wt=$1 self=$2 verdict=$3 stamp_task
  case "$verdict" in
    "$FM_SLOT_RETAIN_META_PREFIX"*) ;;
    *) return 0 ;;
  esac
  stamp_task=$(fm_slot_stamp_field "$wt" task) || return 1
  [ "$stamp_task" = "$self" ] || return 0
  fm_slot_stamp_clear "$wt"
}
