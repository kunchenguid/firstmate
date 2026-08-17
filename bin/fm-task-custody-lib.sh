#!/usr/bin/env bash
# Shared task-worktree custody validator.
#
# state/<id>.meta is the authoritative custody record until supported cleanup
# removes it. A valid record has exactly one non-empty worktree= whose physical
# path is the Git worktree root. Custody compares both that physical root and
# the worktree-specific absolute Git directory, so symlink spellings and pooled
# path reuse cannot let two task records claim one isolated copy.
#
# fm_task_custody_validate <state-dir> <task-id> <worktree>
# validates the requested task's own record when present, scans every other task
# record for the same worktree identity, and refuses ambiguous matching records.
# The same task may reuse its exact recorded copy for recovery. A different copy
# under the same task id, or the same copy under a different task id, refuses.
# On success it sets FM_TASK_CUSTODY_WORKTREE and FM_TASK_CUSTODY_GIT_DIR.

# shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
FM_TASK_CUSTODY_WORKTREE=
# shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
FM_TASK_CUSTODY_GIT_DIR=

fm_task_custody_id_valid() {
  case "${1:-}" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_task_custody_physical_dir() {  # <path>
  local path=$1
  [ -d "$path" ] || return 1
  (CDPATH='' cd -- "$path" 2>/dev/null && pwd -P)
}

fm_task_custody_identity() {  # <worktree>
  local worktree=$1 physical top top_physical git_dir
  physical=$(fm_task_custody_physical_dir "$worktree") || return 1
  top=$(git -C "$physical" rev-parse --show-toplevel 2>/dev/null) || return 1
  top_physical=$(fm_task_custody_physical_dir "$top") || return 1
  [ "$physical" = "$top_physical" ] || return 1
  git_dir=$(git -C "$physical" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  case "$git_dir" in /*) ;; *) return 1 ;; esac
  [ -d "$git_dir" ] || return 1
  git_dir=$(fm_task_custody_physical_dir "$git_dir") || return 1
  printf '%s\t%s\n' "$physical" "$git_dir"
}

fm_task_custody_meta_exact_value() {  # <meta> <key>
  local meta=$1 key=$2 count value
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  printf '%s\n' "$value"
}

fm_task_custody_record_identity() {  # <meta>
  local meta=$1 worktree
  worktree=$(fm_task_custody_meta_exact_value "$meta" worktree) || return 1
  fm_task_custody_identity "$worktree"
}

fm_task_custody_meta_mentions_identity() {  # <meta> <physical> <git-dir>
  local meta=$1 expected_physical=$2 expected_git_dir=$3 candidate identity physical git_dir
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    identity=$(fm_task_custody_identity "$candidate" 2>/dev/null || true)
    [ -n "$identity" ] || continue
    physical=${identity%%$'\t'*}
    git_dir=${identity#*$'\t'}
    if [ "$physical" = "$expected_physical" ] || [ "$git_dir" = "$expected_git_dir" ]; then
      return 0
    fi
  done < <(grep '^worktree=' "$meta" 2>/dev/null | cut -d= -f2- || true)
  return 1
}

fm_task_custody_validate() {  # <state-dir> <task-id> <worktree>
  local state=$1 id=$2 requested=$3 identity physical git_dir own meta other_id other_identity
  local other_physical other_git_dir endpoint_count endpoint_binding
  FM_TASK_CUSTODY_WORKTREE=
  FM_TASK_CUSTODY_GIT_DIR=

  fm_task_custody_id_valid "$id" || {
    echo "REFUSED: invalid task identity for worktree custody." >&2
    return 1
  }
  [ -d "$state" ] && [ ! -L "$state" ] || {
    echo "REFUSED: task state directory is unavailable for custody validation: $state" >&2
    return 1
  }
  identity=$(fm_task_custody_identity "$requested") || {
    echo "REFUSED: task $id worktree is absent, malformed, or not a Git worktree root: $requested" >&2
    return 1
  }
  physical=${identity%%$'\t'*}
  git_dir=${identity#*$'\t'}
  own="$state/$id.meta"

  if [ -e "$own" ] || [ -L "$own" ]; then
    other_identity=$(fm_task_custody_record_identity "$own") || {
      echo "REFUSED: task $id has an absent, malformed, or ambiguous worktree identity in $own; preserve it for reconciliation." >&2
      return 1
    }
    other_physical=${other_identity%%$'\t'*}
    other_git_dir=${other_identity#*$'\t'}
    if [ "$other_physical" != "$physical" ] || [ "$other_git_dir" != "$git_dir" ]; then
      echo "REFUSED: task $id already owns a different isolated copy at $other_physical; recover that copy or clean it up before spawning another." >&2
      return 1
    fi
    endpoint_count=$(grep -c '^endpoint_task_id=' "$own" 2>/dev/null || true)
    case "$endpoint_count" in
      0) ;;
      1)
        endpoint_binding=$(grep '^endpoint_task_id=' "$own" | cut -d= -f2-)
        [ "$endpoint_binding" = "$id" ] || {
          echo "REFUSED: task $id metadata is bound to endpoint task ${endpoint_binding:-<empty>}; preserve it for reconciliation." >&2
          return 1
        }
        ;;
      *)
        echo "REFUSED: task $id has ambiguous endpoint identity fields; preserve it for reconciliation." >&2
        return 1
        ;;
    esac
  fi

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ "$meta" = "$own" ] && continue
    other_id=${meta##*/}
    other_id=${other_id%.meta}
    if fm_task_custody_meta_mentions_identity "$meta" "$physical" "$git_dir"; then
      if ! other_identity=$(fm_task_custody_record_identity "$meta"); then
        echo "REFUSED: task $other_id has an ambiguous custody record for isolated copy $physical; preserve both records and reconcile it before reuse." >&2
        return 1
      fi
      other_physical=${other_identity%%$'\t'*}
      other_git_dir=${other_identity#*$'\t'}
      if [ "$other_physical" = "$physical" ] || [ "$other_git_dir" = "$git_dir" ]; then
        echo "REFUSED: isolated copy $physical is still owned by task $other_id; finish or safely clean up that task before reuse." >&2
        return 1
      fi
    fi
  done

  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_TASK_CUSTODY_WORKTREE=$physical
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_TASK_CUSTODY_GIT_DIR=$git_dir
  return 0
}
