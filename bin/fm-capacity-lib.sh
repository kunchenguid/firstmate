#!/usr/bin/env bash
# shellcheck shell=bash
# fm-capacity-lib.sh - the single owner of the treehouse pool capacity hold.
#
# A full worktree pool used to be a silent 60-second wait followed by a failed
# spawn whose item stayed dispatchable, so a busy pool produced a retry loop
# with no record. This library turns that refusal into a recorded hold:
#
#   bin/fm-spawn.sh detects treehouse's exact "all N worktrees are in use"
#   refusal during the treehouse-get wait and holds the item through
#   fm_capacity_hold; bin/fm-teardown.sh releases the oldest hold recorded for
#   the same pool through fm_capacity_release_oldest right after a worktree is
#   returned to that pool.
#
# Reason contract (owned here, consumed by both call sites and the tests):
#   pool <pool-root> full <N>/<max>
#   pool <pool-root> full <N>          (when the refusal carries no max_trees)
# The pool identity is the canonical treehouse pool root directory, falling
# back to the project root when the pool cannot be resolved. Spawn records
# whichever identity it can resolve; teardown scans for the worktree-derived
# pool root first and, when nothing matched, for the project-root fallback
# identity, so a hold recorded under either identity is released.
#
# Hold kind: "load". tasks-axi has no capacity kind; load is its load-based
# hold, and the reason prefix above is what distinguishes a capacity hold from
# any other load hold, so release never touches a hold it did not record.
#
# tasks-axi also refuses reasons containing parentheses, which is why the
# reason spells "full <N>/<max>" instead of the parenthesized form.
#
# Every mutation runs from the owning home's backlog root with `--file` only
# for the markdown backend, mirroring fm_backlog_row_show's backend awareness
# in bin/fm-backlog-transition-lib.sh so backend-owned state stays discoverable.
# Usage: . bin/fm-capacity-lib.sh

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-tasks-axi-lib.sh"

fm_capacity_resolve_dir() {  # <dir>
  local dir=$1
  [ -n "$dir" ] || return 1
  CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P
}

fm_capacity_canonical_or_raw() {  # <path>
  local path=$1 canon
  if [ -d "$path" ]; then
    canon=$(fm_capacity_resolve_dir "$path") || canon=$path
    printf '%s\n' "$canon"
  else
    printf '%s\n' "$path"
  fi
}

# The pool root a worktree belongs to: worktrees live at <pool>/<n>/<repo>, so
# the pool is the worktree path's grandparent directory. Both this and
# fm_capacity_pool_of_project must keep deriving pool identity from real
# worktree paths for recorded holds and later releases to agree.
fm_capacity_pool_of_worktree() {  # <worktree-path>
  local wt=$1 pool
  [ -n "$wt" ] || return 1
  pool=$(dirname "$wt")
  pool=$(dirname "$pool")
  fm_capacity_canonical_or_raw "$pool"
}

# The pool root a project resolves to, taken from treehouse's own pool status
# (any worktree path in it answers the layout); the project root itself when
# treehouse cannot answer, so the identity stays unique per project either way.
fm_capacity_pool_of_project() {  # <project-dir>
  local proj=$1 out first pool
  [ -n "$proj" ] || return 1
  proj=$(fm_capacity_canonical_or_raw "$proj")
  if command -v treehouse >/dev/null 2>&1 \
     && out=$( (cd "$proj" 2>/dev/null && treehouse status --json 2>/dev/null) ) \
     && [ -n "$out" ]; then
    first=$(printf '%s\n' "$out" \
      | jq -r 'if (type == "array") and (length > 0) and (.[0].path != null) then .[0].path else empty end' 2>/dev/null)
    if [ -n "$first" ]; then
      pool=$(dirname "$first")
      pool=$(dirname "$pool")
      if [ -n "$pool" ]; then
        fm_capacity_canonical_or_raw "$pool"
        return 0
      fi
    fi
  fi
  printf '%s\n' "$proj"
}

fm_capacity_reason() {  # <pool> <in-use-count> [max]
  local pool=$1 n=$2 max=${3:-}
  if [ -n "$max" ]; then
    printf 'pool %s full %s/%s\n' "$pool" "$n" "$max"
  else
    printf 'pool %s full %s\n' "$pool" "$n"
  fi
}

# Run one tasks-axi command against the backlog owned by <data-dir>'s home,
# with `--file` only for the markdown backend. Prints tasks-axi's combined
# output; the exit status is tasks-axi's.
fm_capacity_axi() {  # <data-dir> <verb> <id> [flag...]
  local data=$1 verb=$2 id=$3 root
  shift 3
  data=$(fm_capacity_resolve_dir "$data") || return 1
  root=$(dirname "$data")
  if [ "$(fm_tasks_axi_backend "$root")" = markdown ]; then
    (cd "$root" 2>/dev/null && tasks-axi "$verb" "$id" --file "$data/backlog.md" "$@" 2>&1)
  else
    (cd "$root" 2>/dev/null && tasks-axi "$verb" "$id" "$@" 2>&1)
  fi
}

# Hold <id> for capacity: a load-kind hold whose reason carries the pool
# identity. Idempotent per tasks-axi's own hold semantics.
fm_capacity_hold() {  # <data-dir> <id> <reason>
  local data=$1 id=$2 reason=$3
  fm_capacity_axi "$data" hold "$id" --reason "$reason" --kind load >/dev/null
}

# Release the oldest capacity hold recorded for <pool> and print which item
# became ready. Candidate rows are the held rows whose hold kind is load and
# whose reason is exactly this library's reason contract for this pool; the
# oldest is the smallest created date, with same-date ties broken by id so
# the choice is deterministic regardless of backend list order (tasks-axi
# exposes only the day, not the hold time). A row set that matches nothing
# releases nothing and stays silent. Never fatal: a release failure is
# reported on stderr and leaves the hold in place for the next teardown to
# retry.
FM_CAPACITY_RELEASED_ID=
fm_capacity_release_oldest() {  # <data-dir> <pool>
  local data=$1 pool=$2 out line prefix reason created id
  local best_id='' best_created=''
  FM_CAPACITY_RELEASED_ID=
  data=$(fm_capacity_resolve_dir "$data") || return 0
  command -v tasks-axi >/dev/null 2>&1 || return 0
  out=$(fm_capacity_axi "$data" list --state held --fields created,hold_kind,hold_reason) || {
    printf 'teardown: capacity release could not read held rows: %s\n' "$(printf '%s\n' "$out" | sed -n '1p')" >&2
    return 0
  }
  while IFS= read -r line; do
    case "$line" in
      '  '*) ;;
      *) continue ;;
    esac
    reason=${line##*,load,}
    [ "$reason" != "$line" ] || continue
    case "$reason" in
      "pool $pool full"|"pool $pool full "*) ;;
      *) continue ;;
    esac
    prefix=${line%,load,*}
    created=${prefix##*,}
    case "$created" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    id=${line#'  '}
    id=${id%%,*}
    [ -n "$id" ] || continue
    if [ -z "$best_id" ] || [ "$created" \< "$best_created" ] \
       || { [ "$created" = "$best_created" ] && [ "$id" \< "$best_id" ]; }; then
      best_id=$id
      best_created=$created
    fi
  done <<EOF
$out
EOF
  [ -n "$best_id" ] || return 0
  if ! fm_capacity_axi "$data" unhold "$best_id" >/dev/null; then
    printf 'teardown: capacity release of %s failed; the hold stays recorded\n' "$best_id" >&2
    return 0
  fi
  # Part of this library's output contract: fm-teardown.sh reads it after a
  # successful release, so ShellCheck's in-file use check is a false positive.
  # shellcheck disable=SC2034
  FM_CAPACITY_RELEASED_ID=$best_id
  printf 'ready: %s - capacity hold released for pool %s\n' "$best_id" "$pool"
}
