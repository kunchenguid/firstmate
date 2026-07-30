#!/usr/bin/env bash
# Refresh project clones: fast-forward the checked-out local default branch to
# origin/<default> when safe, and prune local branches whose upstream tracking
# branch is gone (the remote branch was deleted, i.e. its PR merged) and that no
# worktree still needs.
# Self-heals a clean, detached HEAD that holds no unique commits (it is an
# ancestor of origin/<default>) and whose <default> branch is free to check out by
# re-attaching it before the normal fast-forward ("recovered:"). One additional
# narrow recovery handles a clean, checked-out default branch after a successful
# isolated mirror fetch whose configured ref updates are published through an
# expected-old no-dereference transaction, when the local and remote commits
# genuinely diverged with one unambiguous common base but resolve to the same
# root tree: create and verify the deterministic
# direct ref refs/fm-fleet-sync/squash-preserved/<default>/<full-old-oid> without
# dereferencing it or overwriting a conflict, then atomically move the local
# branch to the observed remote commit with no-dereference expected-old checks on
# the preservation, remote-tracking, and local refs. Active merge, cherry-pick,
# revert, rebase, or sequencer operations and symbolic forms of those refs refuse
# recovery before preservation and are rechecked immediately before the move.
# Post-move checks require HEAD and the local/remote-tracking refs at the remote
# OID, the preservation ref at the old local OID, a clean worktree, and the same
# root tree; failure attempts an expected-old no-dereference rollback. Repeated
# runs then converge through the already-current path.
# Every other off-default or diverged state may hold real work, so it is left
# untouched and reported as a quantified, loud "STUCK: ... N commits behind ...
# - needs attention" warning rather than quiet drift. Nothing is ever forced,
# stashed, or discarded.
# Still skips (benignly) local-only/no-origin projects, missing remotes/branches,
# and fetch failures.
# Pruning never deletes the checked-out branch or a branch that still has a
# worktree, so it cannot discard unlanded work; set FM_FLEET_PRUNE=0 to disable it.
# When fetched-ref publication fails on an orphaned .git/packed-refs.lock (left
# by a ref rewrite killed mid-write - e.g. a timed-out bootstrap sync or a
# teardown process kill), it is retried with a bounded wait and removed only when
# provably stale; see fetch_with_packed_refs_lock_guard and the
# FM_FLEET_SYNC_PACKED_REFS_LOCK_* knobs.
# Usage: fm-fleet-sync.sh [<project-dir-or-name>]
# The single-project form accepts either a path (absolute, or relative to the
# caller's cwd) or a bare "<name>"/"projects/<name>" form, resolved against
# this home's projects dir ($FM_HOME/projects, or $FM_PROJECTS_OVERRIDE).
# Bare names and "projects/<name>" forms prefer this home's projects dir before
# falling back to an explicit path. Example: from anywhere,
# `fm-fleet-sync.sh dotfiles-private` syncs just that one clone, same as
# passing its full projects/dotfiles-private path.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
FM_LOCK_LOG_PREFIX=fleet-sync
"$FM_ROOT/bin/fm-guard.sh" || true

# Bounded recovery for an orphaned .git/packed-refs.lock. A git ref rewrite
# (fetch --prune, branch -D, pack-refs) killed after creating the lock but before
# renaming it - e.g. bootstrap's fleet-sync timeout kill, or teardown's process
# kills - leaves a lock that makes the next sync's fetch fail with Git's
# "Unable to create '...packed-refs.lock': File exists". These knobs bound the
# patience-then-provably-stale-clear recovery; see fetch_with_packed_refs_lock_guard.
FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=${FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES:-3}
FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=${FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS:-1}
FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=${FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS:-30}
case "$FLEET_SYNC_PACKED_REFS_LOCK_RETRIES" in ''|*[!0-9]*) FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 ;; esac
case "$FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS" in ''|*[!0-9]*) FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30 ;; esac
if ! [[ "$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
  echo "fleet-sync: invalid packed-refs lock retry wait '$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1
fi

usage() {
  echo "usage: fm-fleet-sync.sh [<project-dir-or-name>]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -le 1 ] || { usage; exit 1; }

project_label() {
  case "$PROJ" in
    "$PROJECTS"/*) basename "$PROJ" ;;
    projects/*) basename "$PROJ" ;;
    *) printf '%s\n' "$PROJ" ;;
  esac
}

# resolve_project_arg <arg>: accept a path (used as-is when it already exists)
# or a bare/"projects/<name>" project name, resolved against $PROJECTS. Falls
# back to the original argument unresolved so a genuinely bad path still hits
# sync_project's existing "not a directory" skip.
resolve_project_arg() {
  local arg=$1 candidate
  case "$arg" in
    projects/*)
      candidate="$PROJECTS/${arg#projects/}"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      ;;
    */*)
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
    *)
      candidate="$PROJECTS/$arg"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$arg"
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

# True when git stderr shows the packed-refs.lock "File exists" race. The lock
# path can appear anywhere in the message (git prefixes it with the failed ref op,
# e.g. "could not delete reference ...:"). Other "File exists" errors must not match.
is_packed_refs_lock_error() {
  printf '%s\n' "$1" | grep -Eq "Unable to create ['\"].*packed-refs\\.lock['\"]: File exists"
}

# Absolute path to $PROJ's packed-refs.lock, or empty when it cannot be resolved.
packed_refs_lock_path() {
  local lock abs
  lock=$(git -C "$PROJ" rev-parse --git-path packed-refs.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs=$(cd "$PROJ" && pwd -P) || return 1
      printf '%s/%s\n' "$abs" "$lock"
      ;;
  esac
}

# Snapshot direct ref identities in an isolated bare repository.
snapshot_staged_refs() {
  git --git-dir="$1" for-each-ref --sort=refname \
    --format='%(refname)%09%(objectname)'
}

build_staged_ref_changes() {
  local before=$1 after=$2 changes=$3 unsorted filtered
  unsorted="$changes.unsorted"
  filtered="$changes.filtered"
  awk -F '\t' '
    FILENAME == ARGV[1] {
      before[$1] = $2
      before_seen[$1] = 1
      refs[$1] = 1
      next
    }
    {
      after[$1] = $2
      after_seen[$1] = 1
      refs[$1] = 1
    }
    END {
      for (ref in refs) {
        old = before_seen[ref] ? before[ref] : "-"
        new = after_seen[ref] ? after[ref] : "-"
        if (old != new)
          print old "\t" new "\t" ref
      }
    }
  ' "$before" "$after" >"$unsorted" || return 1
  awk -F '\t' '!($2 == "-" && $3 == "refs/remotes/origin/HEAD")' \
    "$unsorted" >"$filtered" \
    || return 1
  LC_ALL=C sort -t $'\t' -k3,3 "$filtered" >"$changes"
}

symbolic_fetch_refusal() {
  case "$1" in
    refs/remotes/*) printf 'symbolic remote-tracking ref %s\n' "$1" ;;
    refs/heads/*) printf 'symbolic local ref %s\n' "$1" ;;
    refs/fm-fleet-sync/squash-preserved/*)
      printf 'symbolic preservation ref %s\n' "$1"
      ;;
    *) printf 'symbolic fetch destination ref %s\n' "$1" ;;
  esac
}

staged_ref_changes_match() {
  local changes=$1 state=$2 old_oid new_oid ref expected actual
  while IFS=$'\t' read -r old_oid new_oid ref; do
    [ -n "$ref" ] || continue
    [ "$old_oid" != - ] || old_oid=
    [ "$new_oid" != - ] || new_oid=
    ref_is_symbolic "$ref" && return 1
    if [ "$state" = before ]; then
      expected=$old_oid
    else
      expected=$new_oid
    fi
    actual=$(direct_ref_oid "$ref" 2>/dev/null || true)
    [ "$actual" = "$expected" ] || return 1
  done <"$changes"
}

publish_staged_ref_changes() {
  local changes=$1 null_source null_oid old_oid new_oid ref actual commands=
  local transaction_rc transaction_output raced_ref
  local -a protected_refs=()

  [ -s "$changes" ] || return 0
  null_source=$(git -C "$PROJ" hash-object --stdin </dev/null) || {
    FETCH_OUTPUT="cannot determine repository object format"
    return 1
  }
  printf -v null_oid '%0*d' "${#null_source}" 0

  while IFS=$'\t' read -r old_oid new_oid ref; do
    [ -n "$ref" ] || continue
    [ "$old_oid" != - ] || old_oid=
    [ "$new_oid" != - ] || new_oid=
    if ! git check-ref-format "$ref" >/dev/null 2>&1; then
      FETCH_OUTPUT="invalid fetch destination $ref"
      return 1
    fi
    case "$ref" in
      refs/heads/*)
        FETCH_OUTPUT="configured fetch would update local branch $ref"
        return 1
        ;;
      refs/fm-fleet-sync/squash-preserved/*)
        FETCH_OUTPUT="configured fetch would update preservation ref $ref"
        return 1
        ;;
    esac
    if ref_is_symbolic "$ref"; then
      FETCH_REFUSAL=$(symbolic_fetch_refusal "$ref")
      return 2
    fi
    actual=$(direct_ref_oid "$ref" 2>/dev/null || true)
    if [ "$actual" != "$old_oid" ]; then
      FETCH_OUTPUT="fetch destination changed during staged fetch: $ref"
      return 1
    fi
    if [ -n "$new_oid" ]; then
      commands="${commands}option no-deref
update $ref $new_oid ${old_oid:-$null_oid}
"
    else
      commands="${commands}option no-deref
delete $ref $old_oid
"
    fi
    protected_refs+=("$ref")
  done <"$changes"

  commands=${commands%$'\n'}
  if direct_ref_transaction "$commands" "${protected_refs[@]}"; then
    transaction_rc=0
  else
    transaction_rc=$?
  fi
  transaction_output=$REF_TRANSACTION_OUTPUT
  if staged_ref_changes_match "$changes" after; then
    return 0
  fi
  if [ "$transaction_rc" -eq 2 ]; then
    raced_ref=${transaction_output#symbolic ref at }
    FETCH_REFUSAL=$(symbolic_fetch_refusal "$raced_ref")
    return 2
  fi
  if [ "$transaction_rc" -eq 3 ]; then
    if staged_ref_changes_match "$changes" before; then
      FETCH_OUTPUT="fetched-ref transaction did not commit after acknowledgement loss"
    else
      FETCH_OUTPUT="fetched-ref transaction outcome is indeterminate"
    fi
  else
    FETCH_OUTPUT=${transaction_output:-fetched-ref transaction rejected}
  fi
  return 1
}

stage_fetch_config_key() {
  case "$1" in
    remote.origin.*|url.*.insteadof|core.sshcommand|core.gitproxy|core.askpass)
      return 0
      ;;
    ssh.variant|http.*|credential.*|protocol.*.allow)
      return 0
      ;;
  esac
  return 1
}

apply_fetch_config_dump() {
  local stage=$1 config_dump=$2 record key value
  while IFS= read -r -d '' record; do
    key=${record%%$'\n'*}
    stage_fetch_config_key "$key" || continue
    if [[ "$record" == *$'\n'* ]]; then
      value=${record#*$'\n'}
    else
      value=true
    fi
    git --git-dir="$stage" config --add "$key" "$value" || return 1
  done <"$config_dump"
}

copy_fetch_config_to_stage() {
  local stage=$1 local_config=$2 worktree_config=$3
  git --git-dir="$stage" config --remove-section remote.origin >/dev/null 2>&1 \
    || return 1
  apply_fetch_config_dump "$stage" "$local_config" \
    && apply_fetch_config_dump "$stage" "$worktree_config"
}

staged_fetch_scope_cleanup() {
  if [ -n "${stage_root:-}" ]; then
    rm -rf -- "$stage_root" 2>/dev/null || true
    stage_root=
  fi
}

staged_fetch_scope_restore_traps() {
  trap - EXIT TERM INT
  [ -z "$saved_exit_trap" ] || eval "$saved_exit_trap"
  [ -z "$saved_term_trap" ] || eval "$saved_term_trap"
  [ -z "$saved_int_trap" ] || eval "$saved_int_trap"
}

staged_fetch_scope_restore_signal_traps() {
  trap - TERM INT
  [ -z "$saved_term_trap" ] || eval "$saved_term_trap"
  [ -z "$saved_int_trap" ] || eval "$saved_int_trap"
}

staged_fetch_scope_finish() {
  staged_fetch_scope_cleanup
  staged_fetch_scope_restore_traps
}

staged_fetch_scope_status() {
  return "$1"
}

staged_fetch_scope_exit() {
  local exit_rc=$1
  staged_fetch_scope_cleanup
  trap - EXIT TERM INT
  [ -z "$saved_term_trap" ] || eval "$saved_term_trap"
  [ -z "$saved_int_trap" ] || eval "$saved_int_trap"
  if [ -n "$saved_exit_trap" ]; then
    eval "$saved_exit_trap"
    if staged_fetch_scope_status "$exit_rc"; then
      eval "$saved_exit_action"
    else
      eval "$saved_exit_action"
    fi
  fi
  return "$exit_rc"
}

staged_fetch_scope_signal() {
  local signal=$1 signal_rc=$2
  staged_fetch_scope_cleanup
  staged_fetch_scope_restore_signal_traps
  kill -s "$signal" "$$"
  return "$signal_rc"
}

fetch_and_publish_configured_refs() {
  local git_dir stage_root stage before after changes local_config worktree_config
  local output rc old_oid new_oid ref
  local saved_exit_trap saved_exit_action saved_term_trap saved_int_trap
  local -a fetched_refs=()

  FETCH_OUTPUT=
  FETCH_REFUSAL=
  git_dir=$(git -C "$PROJ" rev-parse --absolute-git-dir 2>/dev/null) || {
    FETCH_OUTPUT="cannot resolve Git directory"
    return 1
  }
  stage_root=
  saved_exit_trap=$(trap -p EXIT)
  saved_term_trap=$(trap -p TERM)
  saved_int_trap=$(trap -p INT)
  saved_exit_action=
  if [ -n "$saved_exit_trap" ]; then
    eval "set -- ${saved_exit_trap#trap -- }"
    saved_exit_action=$1
  fi
  trap 'staged_fetch_scope_exit "$?"' EXIT
  trap 'staged_fetch_scope_signal TERM 143' TERM
  trap 'staged_fetch_scope_signal INT 130' INT
  stage_root=$(mktemp -d "$git_dir/fm-fleet-sync-fetch.XXXXXX") || {
    FETCH_OUTPUT="cannot create staged fetch repository"
    staged_fetch_scope_finish
    return 1
  }
  stage="$stage_root/repository.git"
  before="$stage_root/refs-before"
  after="$stage_root/refs-after"
  changes="$stage_root/ref-changes"
  local_config="$stage_root/local-config"
  worktree_config="$stage_root/worktree-config"

  if ! output=$(git clone --quiet --mirror --shared --origin origin \
      "$PROJ" "$stage" 2>&1); then
    FETCH_OUTPUT=$output
    staged_fetch_scope_finish
    return 1
  fi
  if ! git -C "$PROJ" config --includes --local --null --list >"$local_config"; then
    FETCH_OUTPUT="cannot read repository fetch configuration"
    staged_fetch_scope_finish
    return 1
  fi
  : >"$worktree_config"
  if [ "$(git -C "$PROJ" config --local --type=bool \
      --get extensions.worktreeConfig 2>/dev/null || true)" = true ] \
      && ! git -C "$PROJ" config --includes --worktree --null \
        --list >"$worktree_config"; then
    FETCH_OUTPUT="cannot read worktree fetch configuration"
    staged_fetch_scope_finish
    return 1
  fi
  if ! copy_fetch_config_to_stage "$stage" "$local_config" "$worktree_config"; then
    FETCH_OUTPUT="cannot stage repository fetch configuration"
    staged_fetch_scope_finish
    return 1
  fi
  if ! snapshot_staged_refs "$stage" >"$before"; then
    FETCH_OUTPUT="cannot snapshot refs before staged fetch"
    staged_fetch_scope_finish
    return 1
  fi
  if ! output=$(git -C "$PROJ" --git-dir="$stage" fetch --quiet --prune origin 2>&1); then
    FETCH_OUTPUT=$output
    staged_fetch_scope_finish
    return 1
  fi
  if ! snapshot_staged_refs "$stage" >"$after" \
      || ! build_staged_ref_changes "$before" "$after" "$changes"; then
    FETCH_OUTPUT="cannot inspect staged fetch result"
    staged_fetch_scope_finish
    return 1
  fi

  while IFS=$'\t' read -r old_oid new_oid ref; do
    [ "$old_oid" != - ] || old_oid=
    [ "$new_oid" != - ] || new_oid=
    [ -n "$new_oid" ] && fetched_refs+=("$ref")
  done <"$changes"
  if [ "${#fetched_refs[@]}" -gt 0 ]; then
    if ! output=$(git -C "$PROJ" -c protocol.file.allow=always \
        fetch --quiet --no-tags --no-write-fetch-head --refmap= \
        "$stage" "${fetched_refs[@]}" 2>&1); then
      FETCH_OUTPUT=$output
      staged_fetch_scope_finish
      return 1
    fi
  fi

  if publish_staged_ref_changes "$changes"; then
    rc=0
  else
    rc=$?
  fi
  staged_fetch_scope_finish
  return "$rc"
}

# Fetch through an isolated mirror using origin's configured mappings, then
# publish only Git's changed refs through one no-dereference transaction. On a
# packed-refs.lock signature, retry up to FLEET_SYNC_PACKED_REFS_LOCK_RETRIES
# times, then remove only a lock proven stale by fm-lock-lib.sh and retry once.
fetch_with_packed_refs_lock_guard() {
  local rc attempt=0 lock lock_desc
  if fetch_and_publish_configured_refs; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -ne 2 ] || return "$rc"
  is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"

  lock=$(packed_refs_lock_path) || lock=""
  lock_desc=${lock:-packed-refs.lock}
  while [ "$attempt" -lt "$FLEET_SYNC_PACKED_REFS_LOCK_RETRIES" ]; do
    attempt=$(( attempt + 1 ))
    echo "$label: fetch blocked by packed-refs lock ($lock_desc); waiting ${FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES}) (owning process may be exiting)" >&2
    sleep "$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS"
    if fetch_and_publish_configured_refs; then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
      echo "$label: fetch succeeded on retry; packed-refs lock cleared on its own" >&2
      echo "$label: recovered: packed-refs lock cleared on its own during retry"
      return 0
    fi
    [ "$rc" -ne 2 ] || return "$rc"
    is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"
  done

  lock=$(packed_refs_lock_path) || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    if fm_lock_is_provably_stale "$lock" "$PROJ" "$FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS"; then
      if ! rm -f "$lock"; then
        echo "$label: failed to remove provably-stale packed-refs lock $lock; leaving it in place" >&2
        return "$rc"
      fi
      echo "$label: removed provably-stale packed-refs lock $lock (age >= ${FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS}s, no live holder) and retrying fetch" >&2
      if fetch_and_publish_configured_refs; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        echo "$label: fetch succeeded after stale packed-refs lock cleanup" >&2
        echo "$label: recovered: removed a stale packed-refs lock (no live holder)"
        return 0
      fi
      return "$rc"
    fi
    echo "$label: fetch blocked by packed-refs lock $lock that persisted across ${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES} retries and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$rc"
  fi
  echo "$label: fetch packed-refs lock signature persisted across ${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES} retries even after the lock file disappeared" >&2
  return "$rc"
}

prune_gone_branches() {
  # Delete local branches whose upstream tracking branch is gone - the remote
  # branch was deleted, which in this fleet means its PR merged - as long as
  # nothing still needs them. Never the checked-out branch, and never a branch
  # that still has a worktree (a live or not-yet-torn-down task). "Gone" plus
  # "no worktree" already proves the work landed: teardown removes a branch's
  # worktree only after confirming the work reached the remote. We deliberately
  # do NOT also require the branch to be an ancestor of origin/<default> - PRs in
  # this fleet are squash-merged, so a merged branch is never an ancestor and
  # such a check would prune nothing. The no-worktree guard is the real safety
  # net. Set FM_FLEET_PRUNE=0 to skip pruning entirely.
  [ "${FM_FLEET_PRUNE:-1}" != "0" ] || return 0

  local worktree_branches current refline branch track
  worktree_branches=$(git -C "$PROJ" worktree list --porcelain 2>/dev/null \
    | sed -n 's#^branch refs/heads/##p')
  current=$(git -C "$PROJ" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

  while IFS= read -r refline; do
    branch=${refline%% *}
    track=${refline#* }
    [ "$track" = "[gone]" ] || continue
    [ -n "$branch" ] || continue
    [ "$branch" != "$current" ] || continue
    if printf '%s\n' "$worktree_branches" | grep -Fxq -- "$branch"; then
      continue
    fi
    if git -C "$PROJ" branch -D -- "$branch" >/dev/null 2>&1; then
      echo "$label: pruned $branch"
    fi
  done < <(git -C "$PROJ" for-each-ref \
    --format='%(refname:short) %(upstream:track)' refs/heads 2>/dev/null)
}

linked_worktree_rebase_targets_default() {
  local worktree=$1 marker path rebase_ref
  [ -d "$worktree" ] || return 1
  for marker in rebase-merge/head-name rebase-apply/head-name; do
    path=$(git -C "$worktree" rev-parse --git-path "$marker" 2>/dev/null) \
      || return 2
    case "$path" in
      /*) ;;
      *) path="$worktree/$path" ;;
    esac
    [ -e "$path" ] || continue
    [ -f "$path" ] || return 2
    IFS= read -r rebase_ref <"$path" || return 2
    [ "$rebase_ref" != "$LOCAL_REF" ] || return 0
  done
  return 1
}

linked_default_worktree_conflict() {
  local git_dir listing_file field record_path= record_branch= current_ref
  local matches=0 rebase_conflict=no unreadable=no rebase_rc
  git_dir=$(git -C "$PROJ" rev-parse --absolute-git-dir 2>/dev/null) || {
    printf 'cannot inspect linked worktrees\n'
    return 0
  }
  listing_file=$(mktemp "$git_dir/fm-fleet-sync-worktrees.XXXXXX") || {
    printf 'cannot inspect linked worktrees\n'
    return 0
  }
  if ! git -C "$PROJ" worktree list --porcelain -z >"$listing_file" 2>/dev/null; then
    rm -f "$listing_file"
    printf 'cannot inspect linked worktrees\n'
    return 0
  fi
  current_ref=$(git -C "$PROJ" rev-parse --symbolic-full-name HEAD 2>/dev/null || true)
  while IFS= read -r -d '' field; do
    case "$field" in
      worktree\ *) record_path=${field#worktree } ;;
      branch\ *) record_branch=${field#branch } ;;
      '')
        [ "$record_branch" != "$LOCAL_REF" ] || matches=$(( matches + 1 ))
        if [ -n "$record_path" ]; then
          if linked_worktree_rebase_targets_default "$record_path"; then
            rebase_conflict=yes
          else
            rebase_rc=$?
            [ "$rebase_rc" -eq 1 ] || unreadable=yes
          fi
        fi
        record_path=
        record_branch=
        ;;
    esac
  done <"$listing_file"
  rm -f "$listing_file"
  if [ "$unreadable" = yes ]; then
    printf 'cannot inspect linked worktrees\n'
    return 0
  fi
  if [ "$rebase_conflict" = yes ]; then
    printf 'a linked worktree is rebasing %s\n' "$DEFAULT"
    return 0
  fi
  if { [ "$current_ref" = "$LOCAL_REF" ] && [ "$matches" -gt 1 ]; } \
      || { [ "$current_ref" != "$LOCAL_REF" ] && [ "$matches" -gt 0 ]; }; then
    printf 'another worktree has %s checked out\n' "$DEFAULT"
    return 0
  fi
  return 1
}

default_checked_out_elsewhere() {
  linked_default_worktree_conflict >/dev/null
}

local_default_safe_for_recovery() {
  ! git -C "$PROJ" rev-parse --verify --quiet "$DEFAULT^{commit}" >/dev/null \
    || git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BASE" 2>/dev/null
}

# Human-readable name for the unsafe state the clone is in, used in the STUCK
# warning. Reads $cur (current branch, empty when detached), $dirty, and the
# HEAD-vs-$BASE ancestry to pick the most informative description.
stuck_state() {
  local s
  if [ -n "$cur" ]; then
    s="branch $cur"
  elif [ "$dirty" = yes ]; then
    s="detached HEAD"
  elif ! git -C "$PROJ" merge-base --is-ancestor HEAD "$BASE" 2>/dev/null; then
    s="detached HEAD with unique commits"
  elif default_checked_out_elsewhere; then
    s="detached HEAD ($DEFAULT checked out in another worktree)"
  elif ! local_default_safe_for_recovery; then
    s="detached HEAD (local $DEFAULT diverged from $BASE)"
  else
    s="detached HEAD"
  fi
  [ "$dirty" = no ] || s="$s with uncommitted changes"
  printf '%s\n' "$s"
}

# Loud, quantified report for a clone we deliberately leave untouched. Includes
# how far behind origin/<default> it is, so a chronically-stuck clone is visibly
# distinct from a benign one-off skip.
report_stuck() {
  local state=$1 behind
  behind=$(git -C "$PROJ" rev-list --count "HEAD..$BASE" 2>/dev/null) || behind="?"
  echo "$label: STUCK: on $state, $behind commits behind $BASE - needs attention"
}

reconciliation_refusal() {
  report_stuck "diverged $DEFAULT (tree-identical recovery refused: $1)"
}

ref_is_symbolic() {
  git -C "$PROJ" symbolic-ref --quiet "$1" >/dev/null 2>&1
}

direct_ref_oid() {
  ref_is_symbolic "$1" && return 1
  git -C "$PROJ" show-ref --verify --hash "$1" 2>/dev/null
}

git_operation_in_progress() {
  local marker operation path

  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
    case "$marker" in
      MERGE_HEAD) operation=merge ;;
      CHERRY_PICK_HEAD) operation=cherry-pick ;;
      REVERT_HEAD) operation=revert ;;
      rebase-merge|rebase-apply) operation=rebase ;;
      sequencer) operation=sequencer ;;
    esac
    if ! path=$(git -C "$PROJ" rev-parse --git-path "$marker" 2>/dev/null); then
      printf 'unreadable Git operation state\n'
      return 0
    fi
    case "$path" in
      /*) ;;
      *) path="$PROJ/$path" ;;
    esac
    if [ -e "$path" ]; then
      printf '%s\n' "$operation"
      return 0
    fi
  done
  return 1
}

direct_ref_transaction() {
  local commands=$1 git_dir txn_dir input_pipe output_pipe error_file pid response ref rc
  local guard_default_worktree=no worktree_conflict
  shift
  if [ "${1:-}" = "--guard-default-worktree" ]; then
    guard_default_worktree=yes
    shift
  fi
  REF_TRANSACTION_OUTPUT=

  git_dir=$(git -C "$PROJ" rev-parse --absolute-git-dir 2>/dev/null) || {
    REF_TRANSACTION_OUTPUT="cannot resolve Git directory"
    return 1
  }
  txn_dir=$(mktemp -d "$git_dir/fm-fleet-sync-ref-transaction.XXXXXX") || {
    REF_TRANSACTION_OUTPUT="cannot create ref transaction channel"
    return 1
  }
  input_pipe="$txn_dir/input"
  output_pipe="$txn_dir/output"
  error_file="$txn_dir/error"
  if ! mkfifo "$input_pipe" "$output_pipe"; then
    rmdir "$txn_dir" 2>/dev/null || true
    REF_TRANSACTION_OUTPUT="cannot create ref transaction channel"
    return 1
  fi

  git -C "$PROJ" update-ref --stdin <"$input_pipe" >"$output_pipe" 2>"$error_file" &
  pid=$!
  exec 8>"$input_pipe"
  exec 9<"$output_pipe"
  printf '%s\nprepare\n' "$commands" >&8
  if ! IFS= read -r response <&9 || [ "$response" != "prepare: ok" ]; then
    exec 8>&-
    exec 9<&-
    wait "$pid" 2>/dev/null || true
    REF_TRANSACTION_OUTPUT=$(first_line "$(cat "$error_file" 2>/dev/null || true)")
    rm -f "$input_pipe" "$output_pipe" "$error_file"
    rmdir "$txn_dir" 2>/dev/null || true
    [ -n "$REF_TRANSACTION_OUTPUT" ] || REF_TRANSACTION_OUTPUT="ref transaction preparation failed"
    return 1
  fi

  for ref in "$@"; do
    if ref_is_symbolic "$ref"; then
      printf 'abort\n' >&8
      IFS= read -r response <&9 || true
      exec 8>&-
      exec 9<&-
      wait "$pid" 2>/dev/null || true
      REF_TRANSACTION_OUTPUT="symbolic ref at $ref"
      rm -f "$input_pipe" "$output_pipe" "$error_file"
      rmdir "$txn_dir" 2>/dev/null || true
      return 2
    fi
  done

  if [ "$guard_default_worktree" = yes ] \
      && worktree_conflict=$(linked_default_worktree_conflict); then
    printf 'abort\n' >&8
    IFS= read -r response <&9 || true
    exec 8>&-
    exec 9<&-
    wait "$pid" 2>/dev/null || true
    REF_TRANSACTION_OUTPUT=$worktree_conflict
    rm -f "$input_pipe" "$output_pipe" "$error_file"
    rmdir "$txn_dir" 2>/dev/null || true
    return 4
  fi

  response=
  if printf 'commit\n' >&8; then
    IFS= read -r response <&9 || response=
  fi
  exec 8>&-
  exec 9<&-
  if wait "$pid" 2>/dev/null; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ] || [ "$response" != "commit: ok" ]; then
    REF_TRANSACTION_OUTPUT=$(first_line "$(cat "$error_file" 2>/dev/null || true)")
    [ -n "$REF_TRANSACTION_OUTPUT" ] \
      || REF_TRANSACTION_OUTPUT="ref transaction commit acknowledgement lost"
    rm -f "$input_pipe" "$output_pipe" "$error_file"
    rmdir "$txn_dir" 2>/dev/null || true
    return 3
  fi
  rm -f "$input_pipe" "$output_pipe" "$error_file"
  rmdir "$txn_dir" 2>/dev/null || true
  return 0
}

preservation_ref_oid() {
  direct_ref_oid "$PRESERVE_REF"
}

ensure_preservation_ref() {
  local anchor_oid creation_input transaction_rc update_output

  if ref_is_symbolic "$PRESERVE_REF"; then
    reconciliation_refusal "symbolic preservation ref at $PRESERVE_REF"
    return 1
  fi
  if git -C "$PROJ" show-ref --verify --quiet "$PRESERVE_REF"; then
    if ! anchor_oid=$(preservation_ref_oid) || [ "$anchor_oid" != "$local_rev" ]; then
      reconciliation_refusal "preservation ref conflict at $PRESERVE_REF"
      return 1
    fi
  else
    creation_input=$(printf 'option no-deref\ncreate %s %s\n' "$PRESERVE_REF" "$local_rev")
    if direct_ref_transaction "$creation_input" "$PRESERVE_REF"; then
      :
    else
      transaction_rc=$?
      update_output=$REF_TRANSACTION_OUTPUT
      if [ "$transaction_rc" -eq 2 ]; then
        reconciliation_refusal "symbolic preservation ref appeared before creation at $PRESERVE_REF"
        return 1
      fi
      # A concurrent creator of the same exact direct ref is harmless. Any
      # other creation failure or conflicting value is a refusal, never an
      # overwrite.
      if ! anchor_oid=$(preservation_ref_oid) || [ "$anchor_oid" != "$local_rev" ]; then
        reconciliation_refusal "cannot create preservation ref $PRESERVE_REF$(if [ -n "$update_output" ]; then printf ': %s' "$(first_line "$update_output")"; fi)"
        return 1
      fi
    fi
  fi

  if ! anchor_oid=$(preservation_ref_oid) || [ "$anchor_oid" != "$local_rev" ] \
      || ! git -C "$PROJ" cat-file -e "$PRESERVE_REF^{commit}" 2>/dev/null; then
    reconciliation_refusal "preservation ref verification failed at $PRESERVE_REF"
    return 1
  fi
  return 0
}

reconcile_tree_identical_divergence() {
  local anchor_oid branch_ref head_oid local_oid remote_oid local_tree_now operation
  local remote_tree_now common_base_now worktree_status update_input update_output
  local transaction_rc=0 post_branch post_head post_local post_remote post_tree post_status
  local rollback_output rollback_branch rollback_head rollback_local rollback_remote
  local rollback_tree rollback_anchor rollback_status worktree_conflict

  PRESERVE_REF="refs/fm-fleet-sync/squash-preserved/$DEFAULT/$local_rev"
  if ! git check-ref-format "$PRESERVE_REF" >/dev/null 2>&1; then
    reconciliation_refusal "unsafe preservation ref identity"
    return 0
  fi
  if operation=$(git_operation_in_progress); then
    reconciliation_refusal "active $operation operation"
    return 0
  fi
  if worktree_conflict=$(linked_default_worktree_conflict); then
    reconciliation_refusal "$worktree_conflict"
    return 0
  fi
  if ref_is_symbolic "$LOCAL_REF"; then
    reconciliation_refusal "symbolic local ref at $LOCAL_REF"
    return 0
  fi
  if ref_is_symbolic "$REMOTE_REF"; then
    reconciliation_refusal "symbolic remote-tracking ref at $REMOTE_REF"
    return 0
  fi
  if ref_is_symbolic "$PRESERVE_REF"; then
    reconciliation_refusal "symbolic preservation ref at $PRESERVE_REF"
    return 0
  fi
  local_oid=$(direct_ref_oid "$LOCAL_REF" 2>/dev/null || true)
  remote_oid=$(direct_ref_oid "$REMOTE_REF" 2>/dev/null || true)
  if [ "$local_oid" != "$local_rev" ] || [ "$remote_oid" != "$remote_rev" ]; then
    reconciliation_refusal "repository identity changed before preservation"
    return 0
  fi
  if ! ensure_preservation_ref; then
    return 0
  fi

  # Revalidate every predicate after the preservation ref exists. The update-ref
  # transaction below then verifies all three refs under one atomic ref lock, so
  # a race cannot move the checked-out branch from an identity we did not inspect.
  branch_ref=$(git -C "$PROJ" symbolic-ref --quiet --no-recurse HEAD 2>/dev/null || true)
  head_oid=$(git -C "$PROJ" rev-parse --verify "HEAD^{commit}" 2>/dev/null || true)
  local_oid=$(direct_ref_oid "$LOCAL_REF" 2>/dev/null || true)
  remote_oid=$(direct_ref_oid "$REMOTE_REF" 2>/dev/null || true)
  anchor_oid=$(preservation_ref_oid 2>/dev/null || true)
  local_tree_now=$(git -C "$PROJ" rev-parse --verify "$local_rev^{tree}" 2>/dev/null || true)
  remote_tree_now=$(git -C "$PROJ" rev-parse --verify "$remote_rev^{tree}" 2>/dev/null || true)
  common_base_now=$(git -C "$PROJ" merge-base --all "$local_rev" "$remote_rev" 2>/dev/null || true)
  if ! worktree_status=$(git -C "$PROJ" status --porcelain 2>/dev/null); then
    reconciliation_refusal "worktree identity became unreadable before atomic update; preserved $PRESERVE_REF"
    return 0
  fi
  if [ "$branch_ref" != "$LOCAL_REF" ] || [ "$head_oid" != "$local_rev" ] \
      || [ "$local_oid" != "$local_rev" ] || [ "$remote_oid" != "$remote_rev" ] \
      || [ "$anchor_oid" != "$local_rev" ] || [ "$local_tree_now" != "$local_tree" ] \
      || [ "$remote_tree_now" != "$local_tree" ] || [ "$common_base_now" != "$common_base" ] \
      || [ -n "$worktree_status" ] \
      || git -C "$PROJ" merge-base --is-ancestor "$local_rev" "$remote_rev" 2>/dev/null \
      || git -C "$PROJ" merge-base --is-ancestor "$remote_rev" "$local_rev" 2>/dev/null; then
    reconciliation_refusal "repository identity changed before atomic update; preserved $PRESERVE_REF"
    return 0
  fi
  if ref_is_symbolic "$LOCAL_REF"; then
    reconciliation_refusal "symbolic local ref appeared before atomic update; preserved $PRESERVE_REF"
    return 0
  fi
  if ref_is_symbolic "$REMOTE_REF"; then
    reconciliation_refusal "symbolic remote-tracking ref appeared before atomic update; preserved $PRESERVE_REF"
    return 0
  fi
  if ref_is_symbolic "$PRESERVE_REF"; then
    reconciliation_refusal "symbolic preservation ref appeared before atomic update; preserved $PRESERVE_REF"
    return 0
  fi
  if operation=$(git_operation_in_progress); then
    reconciliation_refusal "active $operation operation appeared before atomic update; preserved $PRESERVE_REF"
    return 0
  fi

  update_input=$(printf 'option no-deref\nverify %s %s\noption no-deref\nverify %s %s\noption no-deref\nupdate %s %s %s\n' \
    "$PRESERVE_REF" "$local_rev" "$REMOTE_REF" "$remote_rev" \
    "$LOCAL_REF" "$remote_rev" "$local_rev")
  if direct_ref_transaction "$update_input" --guard-default-worktree \
      "$PRESERVE_REF" "$REMOTE_REF" "$LOCAL_REF"; then
    :
  else
    transaction_rc=$?
    update_output=$REF_TRANSACTION_OUTPUT
    if [ "$transaction_rc" -eq 4 ]; then
      reconciliation_refusal "$update_output; preserved $PRESERVE_REF"
      return 0
    fi
    if [ "$transaction_rc" -ne 3 ]; then
      reconciliation_refusal "atomic update rejected; preserved $PRESERVE_REF$(if [ -n "$update_output" ]; then printf ': %s' "$(first_line "$update_output")"; fi)"
      return 0
    fi
  fi

  post_branch=$(git -C "$PROJ" symbolic-ref --quiet --no-recurse HEAD 2>/dev/null || true)
  post_head=$(git -C "$PROJ" rev-parse --verify "HEAD^{commit}" 2>/dev/null || true)
  post_local=$(direct_ref_oid "$LOCAL_REF" 2>/dev/null || true)
  post_remote=$(direct_ref_oid "$REMOTE_REF" 2>/dev/null || true)
  post_tree=$(git -C "$PROJ" rev-parse --verify "HEAD^{tree}" 2>/dev/null || true)
  anchor_oid=$(preservation_ref_oid 2>/dev/null || true)
  post_status=$(git -C "$PROJ" status --porcelain 2>/dev/null) || post_status=unreadable
  if [ "$post_branch" != "$LOCAL_REF" ] || [ "$post_head" != "$remote_rev" ] \
      || [ "$post_local" != "$remote_rev" ] || [ "$post_remote" != "$remote_rev" ] \
      || [ "$post_tree" != "$local_tree" ] || [ "$anchor_oid" != "$local_rev" ] \
      || [ -n "$post_status" ]; then
    if [ "$transaction_rc" -eq 3 ] && [ "$post_branch" = "$LOCAL_REF" ] \
        && [ "$post_head" = "$local_rev" ] && [ "$post_local" = "$local_rev" ] \
        && [ "$post_remote" = "$remote_rev" ] && [ "$post_tree" = "$local_tree" ] \
        && [ "$anchor_oid" = "$local_rev" ] && [ -z "$post_status" ]; then
      reconciliation_refusal "atomic update did not commit after acknowledgement loss; preserved $PRESERVE_REF"
      return 0
    fi

    rollback_output=$(git -C "$PROJ" update-ref --no-deref \
      "$LOCAL_REF" "$local_rev" "$remote_rev" 2>&1) || true
    rollback_branch=$(git -C "$PROJ" symbolic-ref --quiet --no-recurse HEAD 2>/dev/null || true)
    rollback_head=$(git -C "$PROJ" rev-parse --verify "HEAD^{commit}" 2>/dev/null || true)
    rollback_local=$(direct_ref_oid "$LOCAL_REF" 2>/dev/null || true)
    rollback_remote=$(direct_ref_oid "$REMOTE_REF" 2>/dev/null || true)
    rollback_tree=$(git -C "$PROJ" rev-parse --verify "HEAD^{tree}" 2>/dev/null || true)
    rollback_anchor=$(preservation_ref_oid 2>/dev/null || true)
    rollback_status=$(git -C "$PROJ" status --porcelain 2>/dev/null) \
      || rollback_status=unreadable
    if [ "$rollback_branch" = "$LOCAL_REF" ] && [ "$rollback_head" = "$local_rev" ] \
        && [ "$rollback_local" = "$local_rev" ] && [ "$rollback_remote" = "$remote_rev" ] \
        && [ "$rollback_tree" = "$local_tree" ] && [ "$rollback_anchor" = "$local_rev" ] \
        && [ -z "$rollback_status" ]; then
      reconciliation_refusal "post-update verification failed and the local branch was restored; preserved $PRESERVE_REF"
    else
      reconciliation_refusal "post-update verification failed and atomic restore was refused; preserved $PRESERVE_REF$(if [ -n "$rollback_output" ]; then printf ': %s' "$(first_line "$rollback_output")"; fi)"
    fi
    return 0
  fi

  echo "$label: recovered: reconciled tree-identical squash on $DEFAULT to $BASE; preserved $PRESERVE_REF"
  return 0
}

sync_project() {
  PROJ=$1
  label=$(project_label)

  if [ ! -d "$PROJ" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$PROJ" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi
  mode_line=$("$FM_ROOT/bin/fm-project-mode.sh" "$label" 2>/dev/null || echo "no-mistakes off")
  mode=${mode_line%% *}
  if [ "$mode" = "local-only" ]; then
    echo "$label: skipped: local-only project"
    return 0
  fi
  if ! git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
    echo "$label: skipped: no origin remote"
    return 0
  fi

  fetch_rc=0
  if fetch_with_packed_refs_lock_guard; then
    :
  else
    fetch_rc=$?
  fi
  if [ "$fetch_rc" -ne 0 ]; then
    if [ "$fetch_rc" -eq 2 ]; then
      echo "$label: STUCK: ${FETCH_REFUSAL:-symbolic remote-tracking ref} - needs attention"
      return 0
    fi
    reason="fetch failed"
    if [ -n "$FETCH_OUTPUT" ]; then
      reason="$reason: $(first_line "$FETCH_OUTPUT")"
    fi
    echo "$label: skipped: $reason"
    return 0
  fi

  prune_gone_branches || true

  DEFAULT=$(default_branch) || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }
  BASE="origin/$DEFAULT"
  LOCAL_REF="refs/heads/$DEFAULT"
  REMOTE_REF="refs/remotes/origin/$DEFAULT"
  if ref_is_symbolic "$LOCAL_REF"; then
    report_stuck "symbolic local default ref $LOCAL_REF"
    return 0
  fi
  if ref_is_symbolic "$REMOTE_REF"; then
    report_stuck "symbolic remote-tracking ref $REMOTE_REF"
    return 0
  fi
  if ! git -C "$PROJ" rev-parse --verify --quiet "$REMOTE_REF^{commit}" >/dev/null; then
    echo "$label: skipped: $BASE does not exist"
    return 0
  fi

  cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
  dirty=no
  [ -z "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ] || dirty=yes
  recovered=no

  if [ "$cur" != "$DEFAULT" ]; then
    # Off the default branch. Auto-recover only the one unambiguously safe drift:
    # a clean, detached HEAD that holds no unique commits (it is an ancestor of
    # origin/<default>) and whose <default> branch is free to check out here.
    # Re-attaching to an already-published commit strands nothing, and the
    # fast-forward path below then catches the clone up. Anything else - a
    # non-default named branch, a detached HEAD with unique commits, a dirty tree,
    # or <default> already checked out elsewhere - may hold real work, so it is
    # reported loudly and left untouched.
    if [ -z "$cur" ] && [ "$dirty" = no ] \
        && git -C "$PROJ" merge-base --is-ancestor HEAD "$BASE" 2>/dev/null \
        && ! default_checked_out_elsewhere \
        && local_default_safe_for_recovery; then
      if ! git -C "$PROJ" checkout --quiet "$DEFAULT" 2>/dev/null; then
        report_stuck "$(stuck_state)"
        return 0
      fi
      recovered=yes
      cur=$DEFAULT
    else
      report_stuck "$(stuck_state)"
      return 0
    fi
  elif [ "$dirty" = yes ]; then
    # On the default branch but with uncommitted changes we must not disturb.
    report_stuck "$(stuck_state)"
    return 0
  fi

  if ! git -C "$PROJ" rev-parse --verify --quiet "$LOCAL_REF^{commit}" >/dev/null; then
    echo "$label: skipped: local $DEFAULT does not exist"
    return 0
  fi

  local_rev=$(git -C "$PROJ" rev-parse --verify "$LOCAL_REF^{commit}") || {
    echo "$label: skipped: cannot read local $DEFAULT"
    return 0
  }
  remote_rev=$(git -C "$PROJ" rev-parse --verify "$REMOTE_REF^{commit}") || {
    echo "$label: skipped: cannot read $BASE"
    return 0
  }
  if [ "$local_rev" = "$remote_rev" ]; then
    if [ "$recovered" = yes ]; then
      echo "$label: recovered: re-attached $DEFAULT (already current)"
    else
      echo "$label: already current"
    fi
    return 0
  fi
  if ! git -C "$PROJ" merge-base --is-ancestor "$local_rev" "$remote_rev"; then
    # Preserve ordinary unpublished-ahead history and every unequal divergence.
    # Reconcile only genuine divergence (neither side is an ancestor) with exact,
    # equal root tree identities from the freshly fetched refs.
    if git -C "$PROJ" merge-base --is-ancestor "$remote_rev" "$local_rev" 2>/dev/null; then
      report_stuck "diverged $DEFAULT"
      return 0
    fi
    local_tree=$(git -C "$PROJ" rev-parse --verify "$local_rev^{tree}" 2>/dev/null || true)
    remote_tree=$(git -C "$PROJ" rev-parse --verify "$remote_rev^{tree}" 2>/dev/null || true)
    common_base=$(git -C "$PROJ" merge-base --all "$local_rev" "$remote_rev" 2>/dev/null || true)
    if [ -z "$local_tree" ] || [ -z "$remote_tree" ] || [ "$local_tree" != "$remote_tree" ] \
        || [ -z "$common_base" ] || [ "$(printf '%s\n' "$common_base" | wc -l | tr -d '[:space:]')" != 1 ]; then
      report_stuck "diverged $DEFAULT"
      return 0
    fi
    reconcile_tree_identical_divergence
    return 0
  fi

  before=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    echo "$label: skipped: cannot read local $DEFAULT"
    return 0
  }
  if ! merge_output=$(git -C "$PROJ" merge --ff-only "$BASE" 2>&1); then
    reason="fast-forward failed"
    if [ -n "$merge_output" ]; then
      reason="$reason: $(first_line "$merge_output")"
    fi
    echo "$label: skipped: $reason"
    return 0
  fi
  after=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    echo "$label: skipped: fast-forward completed but cannot read local $DEFAULT"
    return 0
  }
  if [ "$recovered" = yes ]; then
    echo "$label: recovered: re-attached $DEFAULT, synced $before..$after"
  else
    echo "$label: synced $before..$after"
  fi
  return 0
}

if [ $# -eq 1 ]; then
  sync_project "$(resolve_project_arg "$1")"
  exit 0
fi

[ -d "$PROJECTS" ] || exit 0
for proj in "$PROJECTS"/*; do
  [ -e "$proj" ] || continue
  [ -d "$proj" ] || continue
  sync_project "$proj"
done
