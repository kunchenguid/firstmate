# shellcheck shell=bash
# Shared fail-safe ownership proof for a task worktree resolved from state/<id>.meta.
# Usage: source this file after bin/fm-backend.sh when Orca tasks are possible.
#
# fm_worktree_ownership_prove <state-dir> <task-id> <meta-file>
# proves that the meta has one inspectable worktree claim, no other task in the
# same home claims the canonical path, and the strongest available positive
# provider binding agrees with the task.
# An Orca worktree id must resolve back to the exact path.
# A secondmate home must carry its exact .fm-secondmate-home marker.
# A crewmate worktree must never carry another task's .fm-task-owner marker;
# that marker binds both task id and spawn generation to protect a slot recycled
# to a later spawn of the same task id.
# A matching owner marker proves an ordinary ship or scout without requiring a
# branch, which covers every unbranched scout and ship before its first action.
# A new claim records task_owner_marker=1 alongside the spawn generation that
# its marker binds. An absent marker on a live path carrying that bit is not a
# missing proof but the signature of a slot that left this task, and it refuses
# by name unless the provider's own id-to-path binding already spoke for that
# path independently. Records without the bit keep the legacy chain unchanged,
# including records from before this marker that already carry spawn_gen=:
# refs/heads/fm/<task-id> proves ownership, another fm/<id> branch refuses, and
# an unattributed checkout falls back to membership in the recorded project.
# No migration rewrites a live legacy record. A duplicated, empty, unreadable,
# or unsupported awareness bit refuses instead of being inferred absent; when
# the bit is set, an unusable generation likewise refuses rather than reopening
# the legacy fallbacks.
# A recorded path that no longer exists holds nothing this task could destroy,
# so it is proved once no other task claims it and no provider binding
# contradicts it. A record that claims no path at all has nothing to prove and
# publishes an empty path, unless an interrupted retirement's backup is still
# sitting beside it; either way every path-keyed destructive helper still
# refuses through fm_worktree_claim_retire_begin's expected-path match.
# The function prints a concrete REFUSED reason and returns nonzero whenever a
# proof is missing, contradictory, unreadable, or ambiguous.
# On success it sets FM_WORKTREE_OWNERSHIP_PATH and
# FM_WORKTREE_OWNERSHIP_PROOF. FM_WORKTREE_OWNERSHIP_PROOF names the single
# strongest binding, so an independently verified Orca id/path match is
# published separately as FM_WORKTREE_OWNERSHIP_ORCA_PATH_MATCH=1: a marker
# that outranks it in the proof string must not cost the caller a second
# provider round trip it has already paid for.
#
# fm_worktree_claim_retire_begin <meta-file> <expected-worktree>
# removes the exact worktree= claim before a provider return or removal can
# make the path reusable, while retaining a byte-for-byte recovery copy. It
# retires the worktree's .fm-task-owner marker in the same step, since that
# marker is the in-worktree half of the same claim. Only a marker this record
# can prove is its own is retired; any other entry at that path - foreign,
# malformed, not a regular file, or unprovable because the record itself is
# incomplete - leaves ownership conflicting or unproved. That is settled by a
# read-only preflight BEFORE the claim is stripped, so such an entry refuses
# with the record, the entry, and the slot exactly as they were and no
# retirement ever begins: clearing the stray entry and rerunning is a real
# recovery, not a manual drill. Only an absent marker is silent, which is what
# a legacy or unmarked slot looks like.
# This ordering makes a crash leave an unclaimed retained slot rather than a
# returned slot with a stale destructive claim.
#
# fm_worktree_claim_retire_release ends the retirement only when the provider
# reports the path released. The claim and marker are gone for good, their
# backups are discarded, and a retirement receipt lets a rerun finish record
# cleanup without recovering path authority. If the receipt cannot be written,
# the claim copy becomes released evidence that is never authority.
#
# Every other exit parks the retirement. There is deliberately no automatic
# restore: provider failure, interrupted outcome, or retirement-preparation
# failure preserves every receipt and backup, leaves worktree= absent, refuses
# further destructive action, and prints the same deliberate manual-recovery
# drill. That drill requires independent proof that the provider never released
# or reissued the path, forbids touching another owner's marker, restores only
# the matching marker and worktree line while preserving current metadata, and
# leaves the backups until an ordinary lifecycle retry proves ownership and
# cleans the record. Unknown outcome stays parked; no conditional attempts to
# infer that automatic restoration became safe.
#
# fm_worktree_claim_retire_commit discards a retirement's leftovers once the
# record it describes is gone, and fm_worktree_retirement_receipt_clear sweeps
# whatever an earlier interrupted run left beside that record, except the one
# marker copy an unfinished retirement still names for manual recovery.
#
# fm_worktree_owner_pending_write/_read/_clear carry the durable half of the
# owner-marker binding across the window in which a spawn holds a slot but has
# not published its task record yet. Each record is keyed by task id AND spawn
# generation, so a same-id recovery adds its own rather than overwriting the
# evidence of the incarnation it is recovering from, and _read/_clear bind id,
# generation, and canonical path together. A record that is rewriting this same
# task's existing marker also names the generation it replaces, and
# fm_worktree_owner_handoff_read is what turns that pair back into proof that an
# interrupted restamp is still this task's own ownership rather than a recycled
# slot. fm_worktree_owner_pending_list is the discovery half a fresh spawn uses
# to refuse a second slot while an earlier claim is unresolved, and
# fm_worktree_owner_pending_retire_released is how a proved provider release
# retracts every record naming that exact path while preserving any that name
# another. fm_worktree_owner_marker_attribution reads a marker back against all
# of it, so a refusal over another task's marker can tell an operator whether a
# teardown owns the slot, an interrupted spawn does, a record that moved on
# does, nothing does, or - when the record does not say clearly enough -
# that ownership is unknown and nothing may be removed.

FM_WORKTREE_OWNERSHIP_PATH=
FM_WORKTREE_OWNERSHIP_PROOF=
FM_WORKTREE_OWNERSHIP_ORCA_PATH_MATCH=0
FM_WORKTREE_CLAIM_RETIRE_META=
FM_WORKTREE_CLAIM_RETIRE_BACKUP=
FM_WORKTREE_CLAIM_RETIRE_PATH=
FM_WORKTREE_CLAIM_RETIRE_ACTIVE=0
# Distinguishes "the provider released the path but the retirement could not be
# recorded" from an ordinary provider failure, which is the opposite situation.
FM_WORKTREE_RETIREMENT_UNRECORDED=4
FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=
# Stamped by bin/fm-spawn.sh into a crewmate worktree once the task owns it, and
# removed by bin/fm-teardown.sh when the slot is released.
FM_WORKTREE_TASK_OWNER_MARKER=.fm-task-owner
FM_WORKTREE_TASK_BRANCH_CONFLICT=

fm_worktree_meta_exact_value() {  # <meta-file> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ -n "$count" ] || count=0
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# 0 and prints the single value, 2 when the key is absent, 4 when the one line
# that carries it is empty, 3 when duplicate lines make it ambiguous, and 1 when
# the file itself could not be read. Neither ambiguity nor emptiness is
# collapsed into "absent": a record that says two things about ownership says
# nothing safe, a record that wrote the key and then said nothing is not a
# record from before the key existed, and a caller that cannot tell those apart
# ends up acting on a difference it never established.
fm_worktree_meta_probe() {  # <meta-file> <key>
  local meta=$1 key=$2 count value
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || return 1
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ -n "$count" ] || return 1
  case "$count" in
    0) return 2 ;;
    1) ;;
    *) return 3 ;;
  esac
  value=$(grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$value" ] || return 4
  printf '%s' "$value"
}

# 0 and prints the single nonempty claim, 2 when the record carries no claim at
# all (absent or empty), 1 when several lines make the claim ambiguous.
fm_worktree_meta_claim() {  # <meta-file> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ -n "$count" ] || count=0
  case "$count" in
    0) return 2 ;;
    1) ;;
    *) return 1 ;;
  esac
  value=$(grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$value" ] || return 2
  printf '%s' "$value"
}

fm_worktree_canonical_existing_dir() {  # <path>
  local path=$1
  [ -n "$path" ] && [ -d "$path" ] || return 1
  (CDPATH='' cd -- "$path" 2>/dev/null && pwd -P)
}

fm_worktree_claim_comparison_path() {  # <path>
  local path=$1 parent base
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  if [ -d "$path" ]; then
    fm_worktree_canonical_existing_dir "$path"
    return
  fi
  parent=${path%/*}
  base=${path##*/}
  [ -n "$parent" ] || parent=/
  # A vanished parent still leaves the absolute claim comparable against every
  # other absolute claim, so a removed pool root cannot strand the record.
  parent=$(fm_worktree_canonical_existing_dir "$parent") || {
    printf '%s\n' "$path"
    return 0
  }
  printf '%s/%s\n' "${parent%/}" "$base"
}

# Names an interrupted claim retirement's preserved copy, so a record whose
# worktree= was stripped before the provider verdict points at the file that
# still holds the claim for deliberate manual recovery.
fm_worktree_claim_backup_hint() {  # <meta-file>
  local meta=$1 dir base candidate
  dir=${meta%/*}
  base=${meta##*/}
  for candidate in "$dir/.${base}.worktree-claim-backup."*; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# The owner-marker copy parked beside an interrupted claim retirement. It is
# evidence for deliberate manual recovery only; no runtime path restores it.
fm_worktree_marker_backup_hint() {  # <meta-file>
  local meta=$1 dir base candidate
  dir=${meta%/*}
  base=${meta##*/}
  for candidate in "$dir/.${base}.task-owner-backup."*; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# The observed type of whatever sits at a path, decided from the path entry
# alone: nothing here opens, follows, or reads through it, so an entry that is
# unsafe to touch can still be named in a refusal. A symlink is reported as a
# symlink even when it resolves to a regular file.
fm_worktree_path_entry_type() {  # <path>
  local path=$1
  if [ -L "$path" ]; then
    printf '%s' symlink
  elif [ -d "$path" ]; then
    printf '%s' directory
  elif [ -f "$path" ]; then
    printf '%s' 'regular file'
  elif [ -e "$path" ]; then
    printf '%s' 'special file'
  else
    printf '%s' 'missing entry'
  fi
}

# The single manual drill printed beside every interrupted-retirement refusal.
# It names the exact on-disk state and never performs, offers, or infers an
# automatic restore. The operator must independently prove the provider never
# released the path before deliberately rebuilding the two authoritative lines.
fm_worktree_interrupted_retirement_manual_drill() {  # <meta-file>
  local meta=$1 claim marker path marker_path receipt receipt_state marker_state marker_step entry
  claim=$(fm_worktree_claim_backup_hint "$meta" 2>/dev/null) || claim=
  [ -n "$claim" ] || return 0
  marker=$(fm_worktree_marker_backup_hint "$meta" 2>/dev/null) || marker=
  path=$(fm_worktree_meta_exact_value "$claim" worktree 2>/dev/null || true)
  marker_path=${path:+$path/$FM_WORKTREE_TASK_OWNER_MARKER}
  receipt=$(fm_worktree_retirement_receipt_path "$meta")
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    receipt_state="a retirement receipt is present at $receipt"
  else
    receipt_state="no retirement receipt is present at $receipt"
  fi
  if [ -n "$marker" ]; then
    marker_state="the preserved owner-marker copy is at $marker"
    marker_step="only if ${marker_path%/*} is still the exact provider-owned directory for this task and $marker_path is absent, copy $marker to that exact path without removing the backup; if the directory is gone or any marker exists, do not create or touch anything and stop."
  elif [ -n "$marker_path" ] && { [ -e "$marker_path" ] || [ -L "$marker_path" ]; }; then
    entry=$(fm_worktree_path_entry_type "$marker_path")
    if [ "$entry" = 'regular file' ]; then
      marker_state="no owner-marker backup exists because the live marker remains at $marker_path"
      marker_step="leave the existing marker at $marker_path untouched; unless it is a readable $FM_WORKTREE_TASK_OWNER_MARKER naming exactly the parked record's task and generation, stop."
    else
      marker_state="no owner-marker backup exists because $marker_path is a live $entry, not a regular ownership marker"
      marker_step="leave the $entry at $marker_path exactly as it is - do not read, follow, move, or remove it - and stop, because nothing can attribute it and ownership of this path is unproved."
    fi
  else
    marker_state='this legacy or unmarked claim has no owner-marker copy'
    marker_step='skip marker restoration because no marker copy exists.'
  fi
  printf ' Automatic restoration is disabled; the retirement is parked and every destructive lifecycle action refuses. Preserved state: claim copy %s records path %s; %s; %s. Manual recovery drill: (1) keep the task stopped and confirm from the provider and fleet records that %s was never released or reissued; if a receipt exists, any other task claims the path, or ownership is uncertain, stop and do not reclaim it. (2) %s (3) atomically add only the exact worktree=%s line from the claim copy to the current record %s while preserving every other current line; never replace the record wholesale. (4) leave all backups in place and rerun the intended lifecycle command, which must independently prove ownership before acting and will sweep the copies only after cleanup succeeds.' \
    "$claim" "${path:-unknown}" "$marker_state" "$receipt_state" "${path:-the recorded path}" \
    "$marker_step" \
    "${path:-<path-from-claim-copy>}" "$meta"
}

# Names the quarantined copy of a record whose provider release SUCCEEDED but
# whose retirement receipt could not be written. It is deliberately outside
# fm_worktree_claim_backup_hint's parked-retirement namespace: the path it
# records belongs to the provider again, so it is evidence of a completed
# release and never a claim any consumer may recover.
fm_worktree_released_evidence_hint() {  # <meta-file>
  local meta=$1 dir base candidate
  dir=${meta%/*}
  base=${meta##*/}
  for candidate in "$dir/.${base}.worktree-released."*; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# Moves the retirement's copy of the record out of the parked namespace the
# moment the provider reports the path released. A rename inside the same
# directory reuses the copy's existing unique suffix under a shorter name, so it
# still completes when writing the receipt itself failed for want of space.
fm_worktree_released_evidence_quarantine() {  # <meta-file> <claim-backup>
  local meta=$1 backup=$2 dir base evidence
  [ -n "$meta" ] && [ -n "$backup" ] || return 1
  [ -f "$backup" ] && [ ! -L "$backup" ] || return 1
  dir=${meta%/*}
  base=${meta##*/}
  evidence="$dir/.${base}.worktree-released.${backup##*.}"
  mv -f -- "$backup" "$evidence" || return 1
  printf '%s' "$evidence"
}

# 0 and prints the path the provider released, 1 otherwise. Bound to this exact
# record incarnation the same way the receipt is: to the record's identity
# through the metadata filename it is derived from, to its spawn generation, and
# believed only while the record still claims no path of its own. The copy is
# taken before the claim is stripped, so one it cannot produce is not evidence
# of any release.
fm_worktree_released_evidence_present() {  # <meta-file>
  local meta=$1 evidence released claim_rc=0
  evidence=$(fm_worktree_released_evidence_hint "$meta") || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_worktree_meta_exact_value "$evidence" spawn_gen 2>/dev/null || true)" \
    = "$(fm_worktree_meta_exact_value "$meta" spawn_gen 2>/dev/null || true)" ] || return 1
  fm_worktree_meta_claim "$meta" worktree >/dev/null || claim_rc=$?
  [ "$claim_rc" -eq 2 ] || return 1
  released=$(fm_worktree_meta_exact_value "$evidence" worktree 2>/dev/null) || return 1
  printf '%s' "$released"
}

# The durable evidence that a provider already released this record's worktree.
# It carries no path authority: nothing resolves a target through it, and a
# record that has one still proves ownership of no path at all.
fm_worktree_retirement_receipt_path() {  # <meta-file>
  local meta=$1 dir base
  dir=${meta%/*}
  base=${meta##*/}
  printf '%s/.%s.worktree-retired' "$dir" "$base"
}

fm_worktree_record_identity() {  # <meta-file>
  local meta=$1 base=${1##*/}
  printf '%s' "${base%.meta}"
}

# 0 and prints the path the provider released, 1 otherwise. A receipt speaks
# only for the exact incarnation that wrote it: it is bound to the record's task
# id and spawn generation, and it is only believed while the record still claims
# no path. A leaked receipt therefore says nothing about a later task that
# reuses the id, and never about a record holding a live claim.
fm_worktree_retirement_receipt_file_present() {  # <meta-file>
  local meta=$1 receipt released claim_rc=0
  receipt=$(fm_worktree_retirement_receipt_path "$meta")
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_worktree_meta_exact_value "$receipt" schema 2>/dev/null || true)" = fm-worktree-retired.v1 ] || return 1
  [ "$(fm_worktree_meta_exact_value "$receipt" task_id 2>/dev/null || true)" \
    = "$(fm_worktree_record_identity "$meta")" ] || return 1
  [ "$(fm_worktree_meta_exact_value "$receipt" spawn_gen 2>/dev/null || true)" \
    = "$(fm_worktree_meta_exact_value "$meta" spawn_gen 2>/dev/null || true)" ] || return 1
  fm_worktree_meta_claim "$meta" worktree >/dev/null || claim_rc=$?
  [ "$claim_rc" -eq 2 ] || return 1
  released=$(fm_worktree_meta_exact_value "$receipt" released_worktree 2>/dev/null || true)
  printf '%s' "$released"
}

# This record's retirement, however it ended up recorded. A release whose
# receipt could not be written leaves the same proof in its quarantined
# released-evidence copy, bound to the record the same way, so the one I/O
# failure that made the receipt impossible to write cannot wedge the cleanup a
# receipt would have let a rerun finish.
fm_worktree_retirement_receipt_present() {  # <meta-file>
  fm_worktree_retirement_receipt_file_present "$1" && return 0
  fm_worktree_released_evidence_present "$1"
}

fm_worktree_retirement_receipt_write() {  # <meta-file> <released-worktree>
  local meta=$1 released=$2 receipt tmp generation
  receipt=$(fm_worktree_retirement_receipt_path "$meta")
  generation=$(fm_worktree_meta_exact_value "$meta" spawn_gen 2>/dev/null || true)
  tmp="$receipt.next.${BASHPID:-$$}"
  if ! (umask 077; {
      printf '%s\n' 'schema=fm-worktree-retired.v1'
      printf 'task_id=%s\n' "$(fm_worktree_record_identity "$meta")"
      printf 'spawn_gen=%s\n' "$generation"
      printf 'released_worktree=%s\n' "$released"
    } > "$tmp") || ! mv -f -- "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Called only once the authoritative task record is gone, so every copy bound to
# it - the receipt, a superseded claim, quarantined released evidence for either
# half of a claim, the owner marker's stash, and the prior-marker copy an
# aborted relaunch left behind - has nothing left to describe. The one exception
# is a marker copy still owned by a currently active retirement; its caller must
# settle or park that operation before a later record-removal sweep may delete
# the preserved file.
fm_worktree_retirement_receipt_clear() {  # <meta-file>
  local meta=$1 receipt candidate dir base rc=0
  receipt=$(fm_worktree_retirement_receipt_path "$meta")
  rm -f -- "$receipt" || rc=1
  dir=${meta%/*}
  base=${meta##*/}
  for candidate in "$dir/.${base}.worktree-claim-backup."* "$dir/.${base}.worktree-released."* \
    "$dir/.${base}.task-owner-backup."* "$dir/.${base%.meta}.task-owner-prior."*; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    if [ "$FM_WORKTREE_CLAIM_RETIRE_ACTIVE" != 0 ] \
      && [ "$candidate" = "$FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP" ]; then
      continue
    fi
    rm -f -- "$candidate" || rc=1
  done
  return "$rc"
}

# The durable half of the owner-marker binding. bin/fm-spawn.sh publishes it
# into the state directory, alongside the task records, BEFORE it stamps
# .fm-task-owner into the slot and before the base freshen and harness launch
# that follow, so a spawn killed anywhere in that window leaves a marker
# something can still attribute to a task, a spawn generation, and a path - not
# an orphan that refuses the slot to every later spawn with no record to name
# as its remedy.
# The file name carries the spawn generation, because recovery is told to keep
# the same task identity: a later incarnation of the same id publishes its own
# record beside an interrupted one rather than overwriting the only evidence of
# the slot that one took.
# When it is rewriting a marker this same task already owns, the record also
# names the generation being replaced. That makes the rewrite one exact
# transition rather than two disagreeing halves: a crash between the restamp and
# the record's publication leaves marker=new, metadata=old, and a handoff naming
# exactly that pair for exactly this path, which fm_worktree_task_owner_marker_binding
# accepts as the task's own ownership mid-transition instead of refusing it as a
# recycled slot.
# It records an intent, never an outcome: nothing resolves a destructive target
# through it, it satisfies no ownership proof on its own, and it is superseded
# the moment state/<id>.meta publishes the same generation.
fm_worktree_owner_pending_path() {  # <state-dir> <task-id> <spawn-gen>
  local state=$1 id=$2 generation=$3
  [ -n "$state" ] || return 1
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case "$generation" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s/.%s.meta.worktree-owner-pending.%s' "$state" "$id" "$generation"
}

fm_worktree_owner_pending_write() {  # <state-dir> <task-id> <spawn-gen> <worktree> [prior-spawn-gen]
  local state=$1 id=$2 generation=$3 worktree=$4 prior=${5:-} pending tmp
  [ -n "$worktree" ] || return 1
  [ "$prior" != "$generation" ] || prior=
  pending=$(fm_worktree_owner_pending_path "$state" "$id" "$generation") || return 1
  # Outside the discovery namespace, so an interrupted write can never read as
  # an unresolved claim of its own.
  tmp="$state/.$id.meta.worktree-owner-pending-next.${BASHPID:-$$}"
  if ! (umask 077; {
      printf '%s\n' 'schema=fm-task-owner-pending.v1'
      printf 'task_id=%s\n' "$id"
      printf 'spawn_gen=%s\n' "$generation"
      printf 'worktree=%s\n' "$worktree"
      [ -z "$prior" ] || printf 'prior_spawn_gen=%s\n' "$prior"
    } > "$tmp") || ! mv -f -- "$tmp" "$pending"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# 0 and prints the worktree this exact task and generation was being launched
# into, 1 for every other state. Bound on all three axes: a record left by
# another generation never attributes this one's marker, and an expected
# worktree, when given, must be the same canonical path the record names.
fm_worktree_owner_pending_read() {  # <state-dir> <task-id> <spawn-gen> [expected-worktree]
  local state=$1 id=$2 generation=$3 expected=${4:-} pending recorded expected_canonical
  pending=$(fm_worktree_owner_pending_path "$state" "$id" "$generation") || return 1
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  [ "$(fm_worktree_meta_exact_value "$pending" schema 2>/dev/null || true)" \
    = fm-task-owner-pending.v1 ] || return 1
  [ "$(fm_worktree_meta_exact_value "$pending" task_id 2>/dev/null || true)" = "$id" ] || return 1
  [ "$(fm_worktree_meta_exact_value "$pending" spawn_gen 2>/dev/null || true)" \
    = "$generation" ] || return 1
  recorded=$(fm_worktree_meta_exact_value "$pending" worktree 2>/dev/null) || return 1
  if [ -n "$expected" ]; then
    expected_canonical=$(fm_worktree_claim_comparison_path "$expected" 2>/dev/null || true)
    [ -n "$expected_canonical" ] || return 1
    [ "$(fm_worktree_claim_comparison_path "$recorded" 2>/dev/null || true)" \
      = "$expected_canonical" ] || return 1
  fi
  printf '%s' "$recorded"
}

# 0 only when an unresolved record proves this exact generation handoff: the
# same task, from exactly the generation the caller still records, to exactly
# the generation now stamped, for exactly this path. Every axis is compared;
# nothing is inferred from a partial match.
fm_worktree_owner_handoff_read() {  # <state-dir> <task-id> <new-gen> <expected-worktree> <prior-gen>
  local state=$1 id=$2 generation=$3 expected=$4 prior=$5 pending
  [ -n "$prior" ] && [ -n "$expected" ] && [ "$prior" != "$generation" ] || return 1
  fm_worktree_owner_pending_read "$state" "$id" "$generation" "$expected" >/dev/null || return 1
  pending=$(fm_worktree_owner_pending_path "$state" "$id" "$generation") || return 1
  [ "$(fm_worktree_meta_exact_value "$pending" prior_spawn_gen 2>/dev/null || true)" \
    = "$prior" ] || return 1
}

# Retracts only the record this exact task, generation, and path published, so
# neither an abort nor a teardown can withdraw a different incarnation's claim
# on a slot it may still be holding.
fm_worktree_owner_pending_clear() {  # <state-dir> <task-id> <spawn-gen> [expected-worktree]
  local state=$1 id=$2 generation=$3 expected=${4:-} pending
  fm_worktree_owner_pending_read "$state" "$id" "$generation" "$expected" >/dev/null 2>&1 || return 0
  pending=$(fm_worktree_owner_pending_path "$state" "$id" "$generation") || return 0
  rm -f -- "$pending"
}

# Every ownership record this task id still has in the state directory, one
# path per line. Discovery only: it exists so a fresh spawn can refuse to take a
# second slot while an earlier incarnation's claim is unresolved, and nothing
# here selects a generation to act on - a destructive step names its own.
fm_worktree_owner_pending_list() {  # <state-dir> <task-id>
  local state=$1 id=$2 candidate
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  for candidate in "$state/.$id.meta.worktree-owner-pending."*; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    printf '%s\n' "$candidate"
  done
}

# The generation an ownership record's own file name carries. Reading it back
# from the name is what lets a caller retract that exact record instead of
# globbing for whichever one it happens to find first.
fm_worktree_owner_pending_generation_of() {  # <pending-record-path>
  local pending=$1 generation=${1##*.worktree-owner-pending.}
  [ "$generation" != "$pending" ] || return 1
  case "$generation" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s' "$generation"
}

# Once a provider release is proved, every ownership record this task published
# for that exact path is resolved: the slot belongs to the provider again and
# carries no marker of this task's, so nothing is stranded behind that record.
# Records naming any OTHER path are not this release's to retract - one may
# still be holding a slot somewhere - so they are preserved and printed for the
# caller to report. Returns 1 when a retraction it attempted failed.
fm_worktree_owner_pending_retire_released() {  # <state-dir> <task-id> <released-path>
  local state=$1 id=$2 released=$3 pending generation rc=0
  while IFS= read -r pending; do
    [ -n "$pending" ] || continue
    generation=$(fm_worktree_owner_pending_generation_of "$pending") || {
      printf '%s\n' "$pending"
      continue
    }
    if [ -n "$released" ] \
      && fm_worktree_owner_pending_read "$state" "$id" "$generation" "$released" >/dev/null 2>&1; then
      fm_worktree_owner_pending_clear "$state" "$id" "$generation" "$released" || rc=1
      continue
    fi
    printf '%s\n' "$pending"
  done <<EOF
$(fm_worktree_owner_pending_list "$state" "$id")
EOF
  return "$rc"
}

# What durable metadata, if any, still stands behind an owner marker, so a
# refusal over a foreign one can name a remedy that exists rather than a
# teardown that will never touch this slot. Prints exactly one of:
#   record     - the marked task's record binds this marker: it publishes the
#                marker's own spawn generation, it claims this very slot, or an
#                exact handoff proves this marker is that record mid-transition,
#                so that task's teardown is what retires this marker
#   pending    - the marked task's own spawn published this exact generation's
#                ownership record for this slot and was then interrupted
#   stale      - positive evidence that the record moved on: an exact spawn
#                generation that differs AND an exact worktree that canonically
#                is somewhere else, so its teardown will never clear this marker
#   unreadable - a record exists but does not say clearly enough who owns this
#                slot; ownership is unknown and nothing may be removed on it
#   orphan     - nothing in this home attributes the marker to any task
# It only reads: the marker is never moved, rewritten, or removed here.
fm_worktree_owner_marker_attribution() {  # <state-dir> <marker-path>
  local state=$1 marker=$2 owner generation meta slot slot_canonical
  local recorded_gen='' recorded_wt='' recorded_canonical='' gen_rc=0 wt_rc=0
  local record_present=0 undecidable=0
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  owner=$(fm_worktree_meta_exact_value "$marker" task_id 2>/dev/null || true)
  case "$owner" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  generation=$(fm_worktree_meta_exact_value "$marker" spawn_gen 2>/dev/null || true)
  slot=${marker%/*}
  slot_canonical=$(fm_worktree_claim_comparison_path "$slot" 2>/dev/null || true)
  meta="$state/$owner.meta"
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    record_present=1
    recorded_gen=$(fm_worktree_meta_probe "$meta" spawn_gen) || gen_rc=$?
    recorded_wt=$(fm_worktree_meta_probe "$meta" worktree) || wt_rc=$?
    if [ "$gen_rc" -eq 0 ] && [ -n "$generation" ] && [ "$recorded_gen" = "$generation" ]; then
      printf '%s' record
      return 0
    fi
    if [ "$wt_rc" -eq 0 ]; then
      recorded_canonical=$(fm_worktree_claim_comparison_path "$recorded_wt" 2>/dev/null || true)
      if [ -n "$slot_canonical" ] && [ -n "$recorded_canonical" ] \
        && [ "$recorded_canonical" = "$slot_canonical" ]; then
        printf '%s' record
        return 0
      fi
    fi
    if [ "$gen_rc" -eq 0 ] \
      && fm_worktree_owner_handoff_read "$state" "$owner" "$generation" "$slot" "$recorded_gen" \
        >/dev/null 2>&1; then
      printf '%s' record
      return 0
    fi
    # Only a readable, exact, differing generation AND a readable, exact
    # worktree that canonically is somewhere else prove the record moved on.
    # Anything less is unknown ownership, and the marker may be a live
    # worker's - the one thing this marker exists to protect.
    if [ "$gen_rc" -ne 0 ] || [ "$wt_rc" -ne 0 ] || [ -z "$generation" ] \
      || [ -z "$slot_canonical" ] || [ -z "$recorded_canonical" ]; then
      undecidable=1
    fi
  fi
  if fm_worktree_owner_pending_read "$state" "$owner" "$generation" "$slot" >/dev/null 2>&1; then
    printf '%s' pending
    return 0
  fi
  if [ "$record_present" -eq 1 ]; then
    if [ "$undecidable" -eq 1 ]; then
      printf '%s' unreadable
    else
      printf '%s' stale
    fi
    return 0
  fi
  printf '%s' orphan
}

fm_worktree_refuse() {  # <message>
  printf 'REFUSED: %s\n' "$1" >&2
  return 1
}

fm_worktree_no_conflicting_claim() {  # <state-dir> <task-id> <meta-file> <canonical-worktree>
  local state=$1 id=$2 own_meta=$3 canonical=$4 other_meta other_id count other other_canonical
  [ -d "$state" ] || {
    fm_worktree_refuse "cannot inspect task $id ownership because state directory $state is unavailable."
    return 1
  }
  for other_meta in "$state"/*.meta; do
    [ -e "$other_meta" ] || [ -L "$other_meta" ] || continue
    [ "$other_meta" != "$own_meta" ] || continue
    other_id=${other_meta##*/}
    other_id=${other_id%.meta}
    if [ ! -f "$other_meta" ] || [ -L "$other_meta" ]; then
      fm_worktree_refuse "cannot prove task $id owns $canonical because task $other_id has unsafe metadata at $other_meta."
      return 1
    fi
    count=$(grep -c '^worktree=' "$other_meta" 2>/dev/null || true)
    if [ -z "$count" ]; then
      fm_worktree_refuse "cannot prove task $id owns $canonical because task $other_id's metadata at $other_meta could not be read."
      return 1
    fi
    case "$count" in
      0) continue ;;
      1) ;;
      *)
        fm_worktree_refuse "cannot prove task $id owns $canonical because task $other_id has $count recorded worktree claims."
        return 1
        ;;
    esac
    other=$(grep '^worktree=' "$other_meta" | cut -d= -f2-)
    [ -n "$other" ] || continue
    if [ "$other" = "$canonical" ]; then
      fm_worktree_refuse "worktree $canonical is also claimed by task $other_id; task $id cannot act on it."
      return 1
    fi
    other_canonical=$(fm_worktree_claim_comparison_path "$other" 2>/dev/null || true)
    if [ -n "$other_canonical" ] && [ "$other_canonical" = "$canonical" ]; then
      fm_worktree_refuse "worktree $canonical is also claimed by task $other_id as $other; task $id cannot act on it."
      return 1
    fi
  done
}

# 0 when the checkout positively attributes the worktree to this task, 1 only
# when it positively attributes it to a DIFFERENT fm task, and 2 for every state
# that attributes it to nobody. A checkout is legitimately unattributed far more
# often than it is foreign: a scout never leaves a detached HEAD, a ship stays
# detached until its agent runs `git checkout -b fm/<id>`, and a conflicted
# rebase or a bisect detaches HEAD off the task branch tip for as long as the
# operation is in progress - exactly the wedged state stuck-crewmate recovery
# has to act on. Those stay inconclusive so the owner marker or legacy project
# membership can decide rather than deadlocking every lifecycle verb.
fm_worktree_task_branch_proves_owner() {  # <canonical-worktree> <task-id>
  local worktree=$1 id=$2 branch expected="fm/$2" head expected_head
  FM_WORKTREE_TASK_BRANCH_CONFLICT=
  branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -n "$branch" ]; then
    [ "$branch" != "$expected" ] || return 0
    case "$branch" in
      fm/*)
        FM_WORKTREE_TASK_BRANCH_CONFLICT=$branch
        return 1
        ;;
    esac
    return 2
  fi
  head=$(git -C "$worktree" rev-parse --verify HEAD 2>/dev/null) || return 2
  expected_head=$(git -C "$worktree" rev-parse --verify "refs/heads/$expected" 2>/dev/null) || return 2
  [ "$head" = "$expected_head" ] || return 2
}

# The weakest proof an unbranched worktree can still offer: it must be one of
# the recorded project's registered worktrees. This is the only evidence left at
# that point, so an uninspectable project is a refusal, never a pass - the same
# polarity as worktree_registered_for_project in bin/fm-teardown.sh.
fm_worktree_project_worktree_binding() {  # <project> <canonical-worktree> <task-id>
  local project=$1 canonical=$2 id=$3 listed line listed_path
  [ -n "$project" ] || {
    fm_worktree_refuse "worktree $canonical is detached with no task $id branch and no owner marker, and task $id records no project to attribute it to."
    return 1
  }
  [ -d "$project" ] || {
    fm_worktree_refuse "worktree $canonical is detached with no task $id branch and no owner marker, and task $id's project $project is unavailable to attribute it to."
    return 1
  }
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || {
    fm_worktree_refuse "worktree $canonical is detached with no task $id branch and no owner marker, and task $id's project $project is not an inspectable git repository."
    return 1
  }
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || {
    fm_worktree_refuse "worktree $canonical is detached with no task $id branch and no owner marker, and task $id's project $project could not list its worktrees."
    return 1
  }
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_path=$(fm_worktree_claim_comparison_path "${line#worktree }" 2>/dev/null || true)
        [ "$listed_path" = "$canonical" ] || continue
        return 0
        ;;
    esac
  done <<EOF
$listed
EOF
  fm_worktree_refuse "worktree $canonical is detached with no task $id branch and no owner marker, and is no longer a registered worktree of its project $project."
  return 1
}

# The per-task ownership marker bin/fm-spawn.sh stamps into every crewmate
# worktree once it owns the slot. 0 when task id and spawn generation match this
# task's metadata, 1 when either differs or the marker cannot be read, 2 when no
# marker has been stamped there yet and the record carries no marker-awareness
# bit, and 3 when a marker-aware record finds none. A generation mismatch
# refuses even when the task id was reused.
# Absence is only inconclusive for a legacy record, because for every aware one
# it is the signature of a slot that left this task: a pool return, a reaper, or
# the `git clean -fdx` this marker is only info/exclude'd against. The caller
# decides what an absent marker costs an aware record, since the provider's own
# id-to-path binding can still speak for a path no marker does.
fm_worktree_task_owner_marker_binding() {  # <canonical-worktree> <task-id> <spawn-generation> <marker-aware:0|1> [state-dir]
  local canonical=$1 id=$2 expected_gen=$3 marker_aware=$4 state=${5:-} marker=$1/$FM_WORKTREE_TASK_OWNER_MARKER
  local schema owner generation
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    [ "$marker_aware" != 1 ] || return 3
    return 2
  fi
  if [ ! -f "$marker" ] || [ -L "$marker" ]; then
    fm_worktree_refuse "worktree $canonical has a $FM_WORKTREE_TASK_OWNER_MARKER that is not a regular ownership marker, so task $id cannot be proved to own it."
    return 1
  fi
  schema=$(fm_worktree_meta_exact_value "$marker" schema 2>/dev/null || true)
  owner=$(fm_worktree_meta_exact_value "$marker" task_id 2>/dev/null || true)
  generation=$(fm_worktree_meta_exact_value "$marker" spawn_gen 2>/dev/null || true)
  if [ "$schema" != fm-task-owner.v1 ] || [ -z "$owner" ] || [ -z "$generation" ]; then
    fm_worktree_refuse "worktree $canonical has an unreadable or incomplete $FM_WORKTREE_TASK_OWNER_MARKER, so task $id cannot be proved to own it."
    return 1
  fi
  if [ "$owner" != "$id" ]; then
    fm_worktree_refuse "worktree $canonical is marked as task $owner's workspace, not task $id's."
    return 1
  fi
  if [ -z "$expected_gen" ]; then
    fm_worktree_refuse "$marker marks worktree $canonical for task $id generation $generation, but task metadata has no exact spawn generation."
    return 1
  fi
  if [ "$generation" != "$expected_gen" ]; then
    # A restamp publishes its handoff before it rewrites the marker, so a crash
    # between the rewrite and the record's own advance is distinguishable from a
    # slot recycled to a later spawn of this id: only the former leaves an
    # unresolved record naming exactly this transition, for exactly this path.
    if [ -n "$state" ] \
      && fm_worktree_owner_handoff_read "$state" "$id" "$generation" "$canonical" "$expected_gen" \
        >/dev/null 2>&1; then
      return 0
    fi
    fm_worktree_refuse "$marker marks worktree $canonical for task $id generation $generation, not recorded generation $expected_gen, and no unresolved generation handoff for this path proves task $id restamped it."
    return 1
  fi
  return 0
}

fm_worktree_ownership_prove() {  # <state-dir> <task-id> <meta-file>
  local state=$1 id=$2 meta=$3 worktree canonical kind backend project spawn_gen
  local marker worktree_id resolved resolved_canonical provider_proof='' rc=0 claim_rc=0 present=0
  local backup evidence marker_rc=0 gen_rc=0 gen_unusable=''
  local marker_aware=0 awareness awareness_rc=0 awareness_unusable=''
  FM_WORKTREE_OWNERSHIP_PATH=
  FM_WORKTREE_OWNERSHIP_PROOF=
  FM_WORKTREE_OWNERSHIP_ORCA_PATH_MATCH=0
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      fm_worktree_refuse "cannot prove worktree ownership for invalid task id '${id:-missing}'."
      return 1
      ;;
  esac
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    fm_worktree_refuse "task $id has no regular metadata at $meta for worktree ownership proof."
    return 1
  }

  kind=$(fm_worktree_meta_exact_value "$meta" kind 2>/dev/null || true)
  [ -n "$kind" ] || kind=ship
  backend=$(fm_worktree_meta_exact_value "$meta" backend 2>/dev/null || true)
  [ -n "$backend" ] || backend=tmux
  project=$(fm_worktree_meta_exact_value "$meta" project 2>/dev/null || true)
  # spawn_gen predates owner markers, so it cannot distinguish a legacy record
  # from one that promises a positive marker. Only this explicit bit does that;
  # its absence leaves old records byte-for-byte and behavior-for-behavior
  # legacy, while any malformed attempt to carry it stays unknown rather than
  # silently becoming legacy.
  awareness=$(fm_worktree_meta_probe "$meta" task_owner_marker) || awareness_rc=$?
  case "$awareness_rc" in
    0)
      if [ "$awareness" = 1 ]; then
        marker_aware=1
      else
        awareness_unusable="names unsupported task-owner marker awareness '$awareness'"
      fi
      ;;
    2) marker_aware=0 ;;
    3) awareness_unusable='names more than one task-owner marker-awareness value' ;;
    4) awareness_unusable='names an empty task-owner marker-awareness value' ;;
    *) awareness_unusable='could not be read for task-owner marker awareness' ;;
  esac

  spawn_gen=$(fm_worktree_meta_probe "$meta" spawn_gen) || gen_rc=$?
  case "$gen_rc" in
    0) ;;
    2) spawn_gen='' ;;
    3) spawn_gen=''; gen_unusable='names more than one spawn generation' ;;
    4) spawn_gen=''; gen_unusable='names an empty spawn generation' ;;
    *) spawn_gen=''; gen_unusable='could not be read for a spawn generation' ;;
  esac

  worktree=$(fm_worktree_meta_claim "$meta" worktree) || claim_rc=$?
  if [ "$claim_rc" -eq 1 ]; then
    fm_worktree_refuse "task $id has an ambiguous worktree claim in $meta."
    return 1
  fi
  if [ "$claim_rc" -eq 2 ]; then
    # No recorded path at all: there is nothing this task could destroy by
    # path, and fm_worktree_claim_retire_begin still refuses every path-keyed
    # helper whose target the record does not claim.
    backup=$(fm_worktree_claim_backup_hint "$meta" || true)
    evidence=$(fm_worktree_released_evidence_hint "$meta" || true)
    if fm_worktree_retirement_receipt_present "$meta" >/dev/null 2>&1; then
      # The receipt settles what the copy can only guess at: this record's
      # provider step completed, so the claim was retired rather than
      # interrupted and that copy describes a path this task no longer owns.
      [ -z "$backup" ] \
        || echo "warning: task $id's retirement is recorded, but a superseded copy of its claim remains at $backup; it names a released path and must never be restored over the record." >&2
      [ -z "$evidence" ] \
        || echo "warning: the provider already released the worktree task $id recorded; the quarantined copy at $evidence is evidence of that release only and must never be restored over the record." >&2
      FM_WORKTREE_OWNERSHIP_PROOF=no-worktree-claim
      return 0
    fi
    if [ -n "$backup" ]; then
      fm_worktree_refuse "task $id has no worktree claim in $meta because an interrupted retirement is parked.$(fm_worktree_interrupted_retirement_manual_drill "$meta")"
      return 1
    fi
    FM_WORKTREE_OWNERSHIP_PROOF=no-worktree-claim
    return 0
  fi

  canonical=$(fm_worktree_claim_comparison_path "$worktree") || {
    fm_worktree_refuse "task $id's recorded worktree $worktree is not an absolute path, so ownership cannot be proved."
    return 1
  }
  if [ -d "$canonical" ]; then present=1; fi
  fm_worktree_no_conflicting_claim "$state" "$id" "$meta" "$canonical" || return 1

  if [ "$backend" = orca ] && [ "$kind" != secondmate ]; then
    worktree_id=$(fm_worktree_meta_exact_value "$meta" orca_worktree_id) || {
      fm_worktree_refuse "task $id has no exact Orca worktree id to prove ownership of $canonical."
      return 1
    }
    if ! declare -F fm_backend_worktree_path >/dev/null 2>&1; then
      fm_worktree_refuse "Orca ownership resolver is unavailable for task $id worktree id $worktree_id."
      return 1
    fi
    if resolved=$(fm_backend_worktree_path orca "$worktree_id"); then
      resolved_canonical=$(fm_worktree_claim_comparison_path "$resolved") || {
        fm_worktree_refuse "Orca worktree id $worktree_id for task $id resolved to unusable path ${resolved:-missing}."
        return 1
      }
      if [ "$resolved_canonical" != "$canonical" ]; then
        fm_worktree_refuse "Orca worktree id $worktree_id for task $id resolves to $resolved_canonical, not recorded path $canonical."
        return 1
      fi
      provider_proof=orca-worktree-id
      # Published to callers that source this library.
      # shellcheck disable=SC2034
      FM_WORKTREE_OWNERSHIP_ORCA_PATH_MATCH=1
    else
      # An id the provider cannot resolve binds to no live worktree, so it can
      # only stay a refusal while the recorded path is still there to inspect.
      if [ "$present" -eq 1 ]; then
        fm_worktree_refuse "Orca worktree id $worktree_id for task $id could not be resolved."
        return 1
      fi
    fi
  fi

  if [ "$present" -eq 0 ]; then
    # The recorded path holds nothing: no marker, HEAD, or branch survives to
    # inspect, and no live worker can be destroyed at a path that is gone.
    [ -n "$provider_proof" ] || provider_proof=vacant-worktree
  elif [ "$kind" = secondmate ]; then
    marker="$canonical/.fm-secondmate-home"
    if [ ! -f "$marker" ] || [ -L "$marker" ]; then
      fm_worktree_refuse "secondmate $id worktree $canonical has no regular .fm-secondmate-home ownership marker."
      return 1
    fi
    if [ "$(cat "$marker" 2>/dev/null || true)" != "$id" ]; then
      fm_worktree_refuse "secondmate worktree $canonical is marked for task $(cat "$marker" 2>/dev/null || printf unknown), not task $id."
      return 1
    fi
    [ -n "$provider_proof" ] || provider_proof=secondmate-marker
  else
    if [ -n "$awareness_unusable" ] && [ -z "$provider_proof" ]; then
      fm_worktree_refuse "task $id's record $meta $awareness_unusable, so marker ownership of worktree $canonical is ambiguous and the legacy fallback cannot be inferred."
      return 1
    fi
    if [ "$marker_aware" -eq 1 ] && [ -n "$gen_unusable" ] && [ -z "$provider_proof" ]; then
      fm_worktree_refuse "task $id's marker-aware record $meta $gen_unusable, so no exact marker generation proves ownership of worktree $canonical."
      return 1
    fi
    marker_rc=0
    fm_worktree_task_owner_marker_binding "$canonical" "$id" "$spawn_gen" "$marker_aware" "$state" || marker_rc=$?
    [ "$marker_rc" -ne 1 ] || return 1
    if [ "$marker_rc" -eq 3 ] && [ -z "$provider_proof" ]; then
      # A marker-aware record with no marker has already lost the only binding
      # that distinguishes its slot from one reissued to another task, and the
      # remaining fallbacks cannot tell them apart: an unbranched scout leaves
      # no fm/<id> branch to contradict this record, and a reissued pool slot is
      # still a registered worktree of the same project.
      fm_worktree_refuse "task $id's marker-aware record names spawn generation $spawn_gen for worktree $canonical, but $canonical/$FM_WORKTREE_TASK_OWNER_MARKER is absent, so nothing proves task $id still owns that path.$(fm_worktree_interrupted_retirement_manual_drill "$meta")"
      return 1
    fi
    if [ "$marker_rc" -eq 0 ]; then
      provider_proof=task-owner-marker
    elif [ -n "$provider_proof" ]; then
      :
    else
      rc=0
      fm_worktree_task_branch_proves_owner "$canonical" "$id" || rc=$?
      case "$rc" in
        0) provider_proof=task-branch ;;
        2)
          fm_worktree_project_worktree_binding "$project" "$canonical" "$id" || return 1
          provider_proof='project-worktree'
          ;;
        *)
          fm_worktree_refuse "worktree $canonical is checked out on task branch $FM_WORKTREE_TASK_BRANCH_CONFLICT, not task $id branch fm/$id, and nothing else proves task $id still owns it."
          return 1
          ;;
      esac
    fi
  fi

  # Published to callers that source this library.
  # shellcheck disable=SC2034
  FM_WORKTREE_OWNERSHIP_PATH=$canonical
  # shellcheck disable=SC2034
  FM_WORKTREE_OWNERSHIP_PROOF=$provider_proof
  return 0
}

# Takes the worktree= claim out of a record and leaves a byte-for-byte copy of
# what it said beside it for deliberate manual recovery. Prints the copy's path.
# The record is rewritten by rename, so no reader ever sees one that neither
# claims a path nor has a copy naming it.
fm_worktree_claim_strip_into_backup() {  # <meta-file>
  local meta=$1 dir base backup tmp
  dir=${meta%/*}
  base=${meta##*/}
  backup=$(umask 077; mktemp "$dir/.${base}.worktree-claim-backup.XXXXXX") || return 1
  tmp=$(umask 077; mktemp "$dir/.${base}.worktree-claim-next.XXXXXX") || {
    rm -f -- "$backup"
    return 1
  }
  if ! cp -p -- "$meta" "$backup" \
    || ! awk '!/^worktree=/' "$meta" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! mv -f -- "$tmp" "$meta"; then
    rm -f -- "$tmp" "$backup"
    return 1
  fi
  printf '%s' "$backup"
}

fm_worktree_claim_retire_begin() {  # <meta-file> <expected-worktree>
  local meta=$1 expected=$2 recorded expected_canonical recorded_canonical dir base backup
  local claim_rc=0 hint released receipt_rc=1
  if [ "$FM_WORKTREE_CLAIM_RETIRE_ACTIVE" != 0 ]; then
    fm_worktree_refuse "cannot retire worktree claim in $meta because another claim retirement is already active on $FM_WORKTREE_CLAIM_RETIRE_META."
    return 1
  fi
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    fm_worktree_refuse "cannot clear worktree claim because $meta is not a regular metadata file."
    return 1
  }
  recorded=$(fm_worktree_meta_claim "$meta" worktree) || claim_rc=$?
  if [ "$claim_rc" -eq 1 ]; then
    fm_worktree_refuse "cannot clear worktree claim because $meta has an ambiguous worktree claim."
    return 1
  fi
  if [ "$claim_rc" -eq 2 ]; then
    if [ -n "$expected" ]; then
      # A retirement this record actually recorded outranks any copy left beside
      # it: the provider owns that path again, so naming the copy as recoverable
      # would advise the one action this library forbids.
      released=$(fm_worktree_retirement_receipt_present "$meta") && receipt_rc=0 || receipt_rc=$?
      hint=$(fm_worktree_claim_backup_hint "$meta" || true)
      if [ "$receipt_rc" -eq 0 ]; then
        fm_worktree_refuse "cannot clear worktree claim in $meta because the provider already released ${released:-its worktree} and this record must never be pointed back at that path; expected $expected."
      elif [ -n "$hint" ]; then
        fm_worktree_refuse "cannot clear worktree claim in $meta because it claims no path, yet expected $expected; an interrupted retirement is parked.$(fm_worktree_interrupted_retirement_manual_drill "$meta")"
      else
        fm_worktree_refuse "cannot clear worktree claim in $meta because it claims no path, yet expected $expected."
      fi
      return 1
    fi
    # Nothing is claimed and nothing is targeted by path, so the invariant the
    # retirement exists to establish already holds.
    FM_WORKTREE_CLAIM_RETIRE_META=$meta
    FM_WORKTREE_CLAIM_RETIRE_BACKUP=
    FM_WORKTREE_CLAIM_RETIRE_PATH=
    FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=
    FM_WORKTREE_CLAIM_RETIRE_ACTIVE=1
    return 0
  fi
  recorded_canonical=$(fm_worktree_claim_comparison_path "$recorded" 2>/dev/null || true)
  expected_canonical=$(fm_worktree_claim_comparison_path "$expected" 2>/dev/null || true)
  if [ -z "$recorded_canonical" ] || [ -z "$expected_canonical" ] \
    || [ "$recorded_canonical" != "$expected_canonical" ]; then
    fm_worktree_refuse "cannot clear worktree claim in $meta because it records $recorded, not expected path $expected."
    return 1
  fi
  dir=${meta%/*}
  base=${meta##*/}
  fm_worktree_marker_retire_admissible "$dir" "$base" "$expected" || {
    echo "No retirement was started, so $meta keeps its recorded worktree claim and no copy of it was made; resolve that entry and rerun." >&2
    return 1
  }
  backup=$(fm_worktree_claim_strip_into_backup "$meta") || {
    fm_worktree_refuse "could not atomically clear task worktree claim in $meta before provider return."
    return 1
  }
  FM_WORKTREE_CLAIM_RETIRE_META=$meta
  FM_WORKTREE_CLAIM_RETIRE_BACKUP=$backup
  FM_WORKTREE_CLAIM_RETIRE_PATH=$expected
  FM_WORKTREE_CLAIM_RETIRE_ACTIVE=1
  fm_worktree_marker_retire "$dir" "$base" "$expected" || {
    fm_worktree_claim_retire_abandon || true
    return 1
  }
}

# Whether this record may touch whatever sits at its slot's owner-marker path.
# 0 when nothing is there - a legacy or unmarked slot - or when the entry is
# exactly this record's marker. 1 for every other entry: another task's marker,
# an unreadable or incomplete one, something that is not a regular file, or a
# record too incomplete to name the generation it would bind. A secondmate home
# is proved by its .fm-secondmate-home identity and never carries a marker of
# its own, so anything at that path there is by construction not this record's.
# Nothing here creates, moves, reads through, or removes anything, so a refusal
# leaves the slot and the record exactly as they were. It reports only what it
# established - that ownership of the path is conflicting or unproved - because
# it is called both before and after the claim is rewritten; each caller adds
# the context its own state makes true. The binding prints the exact reason it
# could not attribute the entry. On every path whose ownership proof already ran
# the same binding this is a no-op.
fm_worktree_marker_retire_admissible() {  # <state-dir> <meta-basename> <expected-worktree>
  local dir=$1 base=$2 expected=$3 marker meta id generation awareness
  local marker_aware=0 bind_rc=0
  [ -n "$expected" ] && [ -d "$expected" ] || return 0
  marker="$expected/$FM_WORKTREE_TASK_OWNER_MARKER"
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  meta="$dir/$base"
  id=$(fm_worktree_record_identity "$meta")
  generation=$(fm_worktree_meta_probe "$meta" spawn_gen) || generation=
  awareness=$(fm_worktree_meta_probe "$meta" task_owner_marker) || awareness=
  [ "$awareness" != 1 ] || marker_aware=1
  fm_worktree_task_owner_marker_binding "$expected" "$id" "$generation" "$marker_aware" "$dir" \
    || bind_rc=$?
  [ "$bind_rc" -ne 0 ] || return 0
  fm_worktree_refuse "task $id cannot prove the $FM_WORKTREE_TASK_OWNER_MARKER at $marker is its own, so ownership of that path is conflicting or unproved; it is left exactly as it is and nothing may return or remove $expected for task $id until that entry is resolved."
  return 1
}

# The in-worktree owner marker is the other half of the same claim, so it is
# retired in the same step and gone before the provider can recycle the slot.
# No runtime path puts it or the worktree claim back after retirement starts;
# the header above owns the deliberate manual-recovery contract.
# The admissibility gate above already ran before the claim was stripped, so by
# here the path holds either nothing or exactly this record's marker. It is
# re-checked because the claim rewrite sits between the two, and a slot that
# changed under us in that window must park rather than stash an entry this
# record can no longer prove is its own.
fm_worktree_marker_retire() {  # <state-dir> <meta-basename> <expected-worktree>
  local dir=$1 base=$2 expected=$3 marker stash
  FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=
  fm_worktree_marker_retire_admissible "$dir" "$base" "$expected" || {
    echo "That entry appeared after the worktree claim in $dir/$base was already cleared, so this retirement cannot complete and parks instead; the drill below names every preserved copy." >&2
    return 1
  }
  [ -n "$expected" ] && [ -d "$expected" ] || return 0
  marker="$expected/$FM_WORKTREE_TASK_OWNER_MARKER"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  stash=$(umask 077; mktemp "$dir/.${base}.task-owner-backup.XXXXXX") || return 1
  if ! cp -p -- "$marker" "$stash" || ! rm -f -- "$marker"; then
    rm -f -- "$stash"
    fm_worktree_refuse "could not retire the $FM_WORKTREE_TASK_OWNER_MARKER in $expected before the provider could reuse it."
    return 1
  fi
  FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=$stash
}

fm_worktree_claim_retire_release() {
  local meta=$FM_WORKTREE_CLAIM_RETIRE_META backup=$FM_WORKTREE_CLAIM_RETIRE_BACKUP
  local released=$FM_WORKTREE_CLAIM_RETIRE_PATH
  local marker_backup=$FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP
  local recorded=0 evidence=
  [ "$FM_WORKTREE_CLAIM_RETIRE_ACTIVE" != 0 ] || return 0
  FM_WORKTREE_CLAIM_RETIRE_META=
  FM_WORKTREE_CLAIM_RETIRE_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_PATH=
  FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_ACTIVE=0
  if [ -n "$marker_backup" ] && ! rm -f -- "$marker_backup"; then
    echo "warning: the retired owner marker's copy at $marker_backup could not be removed; it names a slot this task no longer owns and is safe to delete." >&2
  fi
  if [ -z "$released" ] || [ -z "$meta" ] || fm_worktree_retirement_receipt_write "$meta" "$released"; then
    recorded=1
  fi
  if [ "$recorded" -ne 1 ]; then
    # The path is the provider's again, but with the retirement unrecorded this
    # copy is the only evidence of what was released, so it is renamed out of
    # the parked claim-backup namespace and kept until
    # the record it describes is gone.
    evidence=$(fm_worktree_released_evidence_quarantine "$meta" "$backup") || evidence=
    if [ -n "$evidence" ]; then
      fm_worktree_refuse "the provider released $released and that path may already belong to another task, but the retirement beside $meta could not be recorded; the released record was quarantined at $evidence as evidence of the release only and must never be restored over the record."
    else
      fm_worktree_refuse "the provider released $released and that path may already belong to another task, but the retirement beside $meta could not be recorded and ${backup:-no copy of the record} could not be quarantined; nothing may restore it over the record."
    fi
    return "$FM_WORKTREE_RETIREMENT_UNRECORDED"
  fi
  if [ -n "$backup" ] && ! rm -f -- "$backup"; then
    echo "warning: the retired worktree claim's copy at $backup could not be removed; $released is released and that copy must never be restored over the record." >&2
  fi
}

fm_worktree_claim_retire_commit() {
  local backup=$FM_WORKTREE_CLAIM_RETIRE_BACKUP
  local marker_backup=$FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP
  [ "$FM_WORKTREE_CLAIM_RETIRE_ACTIVE" != 0 ] || return 0
  if [ -n "$backup" ] && ! rm -f -- "$backup"; then
    fm_worktree_refuse "worktree claim was cleared, but its retirement backup could not be removed at $backup."
    return 1
  fi
  if [ -n "$marker_backup" ] && ! rm -f -- "$marker_backup"; then
    fm_worktree_refuse "the worktree owner marker was retired, but its backup could not be removed at $marker_backup."
    return 1
  fi
  FM_WORKTREE_CLAIM_RETIRE_META=
  FM_WORKTREE_CLAIM_RETIRE_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_PATH=
  FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_ACTIVE=0
}

# Parks any retirement that did not reach a confirmed provider release. No
# claim, marker, receipt, or backup is rewritten here. The same manual drill is
# printed for preparation failure, synchronous provider failure, signal-driven
# interruption, and every later lifecycle refusal over the claimless record.
fm_worktree_claim_retire_abandon() {
  local meta=$FM_WORKTREE_CLAIM_RETIRE_META
  local backup=$FM_WORKTREE_CLAIM_RETIRE_BACKUP
  local marker_backup=$FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP
  [ "$FM_WORKTREE_CLAIM_RETIRE_ACTIVE" != 0 ] || return 0
  FM_WORKTREE_CLAIM_RETIRE_META=
  FM_WORKTREE_CLAIM_RETIRE_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_PATH=
  FM_WORKTREE_CLAIM_RETIRE_MARKER_BACKUP=
  FM_WORKTREE_CLAIM_RETIRE_ACTIVE=0
  if [ -n "$backup" ] && [ -f "$backup" ] && [ -f "$meta" ] && [ ! -L "$meta" ]; then
    fm_worktree_refuse "worktree retirement for $meta did not reach a confirmed provider release.$(fm_worktree_interrupted_retirement_manual_drill "$meta")"
    return 0
  fi
  if [ -n "$backup" ] || [ -n "$marker_backup" ]; then
    fm_worktree_refuse "worktree retirement for ${meta:-an unknown record} stopped with incomplete preserved state: claim copy ${backup:-missing}, owner-marker copy ${marker_backup:-missing}. Automatic restoration is disabled; preserve every surviving file, keep the task stopped, and do not act on any worktree until the provider outcome and record are reconciled manually."
  fi
}
