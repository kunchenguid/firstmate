#!/usr/bin/env bash
# fm-dibs-lib.sh - optional dibs task scopes for ship and scout workers (one owner).
#
# WHY. dibs (owner-and-expiry leases for local resources) can only reclaim what
# it knows an owner for. A task scope gives every resource a worker leases -
# Compose labs, kind or k3d clusters, jobs, its worktree - one owner that lives
# exactly as long as the task, so nothing a finished or abandoned task held is
# left running without an owner dibs can prove dead.
#
# OPT-IN. A home opts in through dibs itself, never through Firstmate config:
# the `dibs` CLI is on PATH and its user config turns scopes on ("scopes": true
# or DIBS_SCOPES=1), which `dibs scope show` reports without changing anything.
# Without dibs, or with scopes off, every function here returns success having
# run nothing but that read, so such a home spawns and tears down as before.
# An opted-in home also needs exec_owner and lease_policies on and jq on PATH;
# anything less refuses the spawn and names what is missing.
#
# CONTRACT.
#   - Key: fm-<first 16 hex of sha256(physical state dir)>-<task-id>, so equal
#     task ids in different homes never share a scope.
#   - Owner: exec:test -e '<physical state dir>/<task-id>.meta'. The scope is
#     alive exactly while the task record exists - through worker exits,
#     relaunches, and supervisor outages - and its owner reads dead once
#     teardown removes the record or an aborted spawn rolls it back, so dibs
#     sweep reclaims anything the scope still holds. The scope must be
#     owner-bound (lease_policies on); a time-bound scope would expire under a
#     live task, so spawn refuses one.
#   - Spawn, after the task record is published: fm_dibs_scope_start starts
#     the scope, or rejoins it on relaunch (same key and owner), and sets
#     FM_DIBS_SCOPE for the DIBS_TASK=<task-id> and DIBS_SCOPE=<scope id>
#     worker exports. fm_dibs_adopt_worktree then adopts the task worktree as a
#     treehouse-worktree lease in that scope, but only when it is a slot
#     treehouse holds durably leased to this task; a slot taken by an
#     interactive `treehouse get` has no lease id and is not adopted, and a
#     dibs with the treehouse-worktree adapter off declines with a note. Every
#     other dibs failure in an opted-in home refuses the spawn.
#   - Teardown runs two phases. After the task's processes are reaped and its
#     work is proved again, fm_dibs_release_members releases every scope member
#     except the adopted task worktree and refuses teardown while
#     any member is retained (unlanded work, resource busy) or the scope cannot
#     be read; --force adds --discard-unlanded for worktree members only, and
#     dibs never kills their processes. Teardown still returns the task worktree
#     itself with its own landed-work proof; after that return fm_dibs_scope_end
#     ends the scope, whose worktree lease then reads absent and is forgotten.
#     A failed end only warns, because the record removal that follows kills
#     the owner and dibs sweep finishes it.
# shellcheck shell=bash

# Physical path of a state directory, the identity both key and owner use.
fm_dibs_state_real() {  # <state-dir>
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

fm_dibs_scope_key() {  # <state-dir> <task-id>
  local real hash
  real=$(fm_dibs_state_real "$1") || return 1
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$real" | shasum -a 256 | cut -c1-16)
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$real" | sha256sum | cut -c1-16)
  else
    return 1
  fi
  case "$hash" in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  printf 'fm-%s-%s\n' "$hash" "$2"
}

fm_dibs_scope_owner() {  # <state-dir> <task-id>
  local real meta
  real=$(fm_dibs_state_real "$1") || return 1
  meta="$real/$2.meta"
  # dibs runs an exec owner with /bin/sh, so the path is single-quoted.
  printf "exec:test -e '%s'\n" "${meta//\'/\'\\\'\'}"
}

# Read the task's scope. Returns 0 with the scope JSON on stdout, 1 when this
# home has no scope to manage (no dibs, scopes off, or no scope for the key),
# and 2 with a diagnostic on stderr when the scope cannot be read.
fm_dibs_scope_read() {  # <state-dir> <task-id>
  local key out rc=0 reason
  command -v dibs >/dev/null 2>&1 || return 1
  # Spawn refuses a scope without jq, so a home without it has none to manage.
  command -v jq >/dev/null 2>&1 || return 1
  key=$(fm_dibs_scope_key "$1" "$2") || {
    echo "error: could not derive the dibs scope key for $2" >&2
    return 2
  }
  out=$(dibs scope show --key "$key" --json 2>/dev/null) || rc=$?
  case "$rc" in
    0)
      printf '%s\n' "$out"
      return 0
      ;;
    2) return 1 ;;
  esac
  reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null || true)
  [ "$reason" != not_found ] || return 1
  echo "error: dibs could not read the scope for task $2 (exit $rc${reason:+, $reason}): $out" >&2
  return 2
}

# Start or rejoin the task scope. Sets FM_DIBS_SCOPE to its id, or empty when
# this home has no dibs or scopes are off. Returns 1 with a diagnostic when an
# opted-in home cannot give the task an owner-bound scope.
fm_dibs_scope_start() {  # <state-dir> <task-id>
  local state=$1 id=$2 key owner out rc=0 binding
  FM_DIBS_SCOPE=
  command -v dibs >/dev/null 2>&1 || return 0
  key=$(fm_dibs_scope_key "$state" "$id") || {
    echo "error: could not derive the dibs scope key for $id" >&2
    return 1
  }
  dibs scope show --key "$key" --json >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 2 ] || return 0
  command -v jq >/dev/null 2>&1 || {
    echo "error: dibs scopes are on but jq is not on PATH; install jq or turn dibs scopes off" >&2
    return 1
  }
  owner=$(fm_dibs_scope_owner "$state" "$id") || return 1
  out=$(dibs scope start --key "$key" --owner "$owner" --json 2>&1) || {
    echo "error: dibs could not start the task scope for $id: $out" >&2
    return 1
  }
  FM_DIBS_SCOPE=$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null || true)
  case "$FM_DIBS_SCOPE" in
    '' | *[!0-9a-f]*)
      FM_DIBS_SCOPE=
      echo "error: dibs reported no scope id for $id: $out" >&2
      return 1
      ;;
  esac
  binding=$(dibs scope show "$FM_DIBS_SCOPE" --json 2>/dev/null |
    jq -r '"\(.record.policy.binding // "")/\(.count // "")"' 2>/dev/null || true)
  if [ "${binding%/*}" != owner ]; then
    echo "error: dibs scope $FM_DIBS_SCOPE for $id is not owner-bound, so it would expire under a live task; turn on dibs lease_policies or turn dibs scopes off" >&2
    # An empty refused scope is ended so a retry after the fix starts afresh
    # instead of rejoining it; one that already owns leases is left alone.
    [ "${binding#*/}" != 0 ] || dibs scope end "$FM_DIBS_SCOPE" --confirm --json >/dev/null 2>&1 || true
    FM_DIBS_SCOPE=
    return 1
  fi
}

# Adopt the task worktree into the scope when treehouse holds it durably
# leased to this task. Returns 1 with a diagnostic when dibs fails to adopt it.
fm_dibs_adopt_worktree() {  # <scope-id> <state-dir> <task-id> <worktree> <project>
  local scope=$1 state=$2 id=$3 wt=$4 proj=$5 lease_id key out rc=0
  [ -n "$scope" ] || return 0
  lease_id=$( (CDPATH='' cd -- "$proj" && treehouse status --json) 2>/dev/null |
    jq -r --arg p "$wt" --arg h "$id" \
      '.[]? | select(.path == $p and .status == "leased" and .lease_holder == $h) | .lease_id // empty' 2>/dev/null |
    head -n 1) || lease_id=
  [ -n "$lease_id" ] || return 0
  key=$(fm_dibs_scope_key "$state" "$id") || return 1
  out=$(dibs adopt treehouse-worktree "$wt" --lease-id "$lease_id" --owner "scope:$scope" \
    --key "$key-worktree" --json 2>&1) || rc=$?
  case "$rc" in
    0) return 0 ;;
    2)
      echo "note: dibs did not adopt worktree $wt into scope $scope: $out" >&2
      return 0
      ;;
  esac
  echo "error: dibs could not adopt worktree $wt into scope $scope for $id: $out" >&2
  return 1
}

# Teardown phase one: release every scope member except the adopted task
# worktree. Returns 1 with a diagnostic while any member is retained.
fm_dibs_release_members() {  # <state-dir> <task-id> <worktree> <force:0|1>
  local id=$2 wt=$3 force=$4 scope_json rc=0 scope lease adapter out failed=0
  local flags
  scope_json=$(fm_dibs_scope_read "$1" "$id") || rc=$?
  [ "$rc" -ne 1 ] || return 0
  [ "$rc" -eq 0 ] || {
    echo "REFUSED: cannot read task $id's dibs scope, so its leases cannot be released; inspect it with dibs scope show, then re-run teardown." >&2
    return 1
  }
  scope=$(printf '%s' "$scope_json" | jq -r '.id')
  while IFS=$'\t' read -r lease adapter; do
    [ -n "$lease" ] || continue
    flags=(--confirm --json)
    [ "$force" != 1 ] || [ "$adapter" != treehouse-worktree ] || flags+=(--discard-unlanded)
    if ! out=$(dibs release "$lease" "${flags[@]}" 2>&1); then
      echo "REFUSED: task $id's dibs scope $scope still holds lease $lease ($adapter): $out" >&2
      failed=1
    fi
  done < <(printf '%s' "$scope_json" | jq -r --arg wt "$wt" \
    '.records[] | select((.resource.adapter == "treehouse-worktree" and .resource.path == $wt) | not) | [.id, .resource.adapter] | @tsv')
  [ "$failed" -eq 0 ] && return 0
  echo "Inspect with dibs explain <lease>, free or release it, then re-run teardown." >&2
  return 1
}

# Teardown phase two, after the task worktree is returned: end the scope.
fm_dibs_scope_end() {  # <state-dir> <task-id>
  local scope_json rc=0 scope out
  scope_json=$(fm_dibs_scope_read "$1" "$2") || rc=$?
  [ "$rc" -ne 1 ] || return 0
  if [ "$rc" -eq 0 ]; then
    scope=$(printf '%s' "$scope_json" | jq -r '.id')
    out=$(dibs scope end "$scope" --confirm --json 2>&1) && return 0
  fi
  echo "warning: task $2's dibs scope did not end${out:+: $out}; dibs sweep reclaims it once this task's record is gone" >&2
  return 0
}
