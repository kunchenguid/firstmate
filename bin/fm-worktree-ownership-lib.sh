#!/usr/bin/env bash
# Shared task-worktree ownership check.
#
# A live state/<task-id>.meta record owns the one canonical worktree named by
# its exactly-one worktree= field.  Callers must refuse allocation or destructive
# cleanup when another record names that same worktree, or when a record cannot
# be read well enough to rule out that claim.  The check never changes a branch,
# worktree, or task record.
#
# fm_worktree_claimed_by_other_task <state-dir> <task-id> <worktree>
#   Returns 0 when another task claims <worktree>, 1 when no other task claims
#   it, or 2 when the ownership record is ambiguous.  On 0, sets
#   FM_WORKTREE_OWNERSHIP_OWNER.  On 2, sets FM_WORKTREE_OWNERSHIP_REASON.
#   An already-absent target is safe only when every other record can still be
#   ruled out; an exact recorded-path match remains a collision.

# shellcheck disable=SC2034 # caller reads these result fields after the function returns
fm_worktree_claimed_by_other_task() {
  local state=$1 self=$2 worktree=$3 target='' target_resolved=0 meta id line claims claim claim_real
  FM_WORKTREE_OWNERSHIP_OWNER=
  FM_WORKTREE_OWNERSHIP_REASON=

  if [ ! -d "$state" ] || [ -L "$state" ]; then
    FM_WORKTREE_OWNERSHIP_REASON="task record directory is unavailable or unsafe: $state"
    return 2
  fi
  if target=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P); then
    target_resolved=1
  fi

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ "$id" = "$self" ] && continue
    if [ ! -f "$meta" ] || [ -L "$meta" ]; then
      FM_WORKTREE_OWNERSHIP_REASON="task record for $id is unreadable: $meta"
      return 2
    fi

    claims=0
    claim=
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        worktree=*)
          claims=$((claims + 1))
          claim=${line#worktree=}
          ;;
      esac
    done < "$meta"
    [ "$claims" -eq 0 ] && continue
    if [ "$claims" -ne 1 ] || [ -z "$claim" ]; then
      FM_WORKTREE_OWNERSHIP_REASON="task record for $id has an ambiguous worktree identity"
      return 2
    fi
    if [ "$claim" = "$worktree" ]; then
      FM_WORKTREE_OWNERSHIP_OWNER=$id
      return 0
    fi
    if ! claim_real=$(CDPATH='' cd -- "$claim" 2>/dev/null && pwd -P); then
      FM_WORKTREE_OWNERSHIP_REASON="task record for $id names an unresolvable worktree: $claim"
      return 2
    fi
    if [ "$target_resolved" -eq 1 ] && [ "$claim_real" = "$target" ]; then
      FM_WORKTREE_OWNERSHIP_OWNER=$id
      return 0
    fi
  done
  return 1
}
