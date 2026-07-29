#!/usr/bin/env bash
# Refresh project clones: fast-forward the checked-out local default branch to
# origin/<default> when safe, and prune local branches whose upstream tracking
# branch is gone (the remote branch was deleted, i.e. its PR merged) and that no
# worktree still needs.
# Self-heals a clean, detached HEAD that holds no unique commits (it is an
# ancestor of origin/<default>) and whose <default> branch is free to check out by
# re-attaching it before the normal fast-forward ("recovered:"). One additional
# narrow recovery handles a clean, checked-out default branch after a successful
# fetch when the local and remote commits genuinely diverged but resolve to the
# same root tree: preserve the full old local identity at
# refs/fm-fleet-sync/squash-preserved/<default>/<old-oid>, verify that direct ref,
# then atomically move the local branch to the observed remote commit with
# no-dereference expected-old checks on the preservation, remote-tracking, and
# local refs. Active Git operations and symbolic forms of those refs refuse the
# recovery before preservation and are rechecked immediately before the move.
# Every other off-default or diverged state may hold real work, so it is left
# untouched and reported as a quantified, loud "STUCK: ... N commits behind ...
# - needs attention" warning rather than quiet drift. Nothing is ever forced,
# stashed, or discarded.
# Still skips (benignly) local-only/no-origin projects, missing remotes/branches,
# and fetch failures.
# Pruning never deletes the checked-out branch or a branch that still has a
# worktree, so it cannot discard unlanded work; set FM_FLEET_PRUNE=0 to disable it.
# When the fetch fails on an orphaned .git/packed-refs.lock (left by a ref rewrite
# killed mid-write - e.g. a timed-out bootstrap sync or a teardown process kill),
# it is retried with a bounded wait and removed only when provably stale; see
# fetch_with_packed_refs_lock_guard and the FM_FLEET_SYNC_PACKED_REFS_LOCK_* knobs.
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

# Run `git -C "$PROJ" fetch origin --prune --quiet`, tolerating an orphaned
# packed-refs.lock left by a killed ref rewrite. Sets FETCH_OUTPUT to the git
# command's combined output and returns its exit status. On the packed-refs.lock
# signature ONLY: retry up to FLEET_SYNC_PACKED_REFS_LOCK_RETRIES times (a
# transient lock self-clears as the owning process exits), then - only if the lock
# is provably stale per fm-lock-lib.sh (still present, mtime age past the
# threshold, no lsof holder of the lock or the clone worktree $PROJ) - remove it
# and retry once more. A live lock, an unprovable one, or any other failure keeps
# today's behavior. Every wait, retry, and removal prints to stderr, and a
# successful recovery also prints one "$label: recovered: ..." summary to stdout so
# a session-start refresh (which discards fleet-sync stderr) still surfaces it.
fetch_with_packed_refs_lock_guard() {
  local rc attempt=0 lock lock_desc
  FETCH_OUTPUT=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); rc=$?
  [ "$rc" -eq 0 ] && return 0
  is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"

  lock=$(packed_refs_lock_path) || lock=""
  lock_desc=${lock:-packed-refs.lock}
  while [ "$attempt" -lt "$FLEET_SYNC_PACKED_REFS_LOCK_RETRIES" ]; do
    attempt=$(( attempt + 1 ))
    echo "$label: fetch blocked by packed-refs lock ($lock_desc); waiting ${FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES}) (owning process may be exiting)" >&2
    sleep "$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS"
    FETCH_OUTPUT=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "$label: fetch succeeded on retry; packed-refs lock cleared on its own" >&2
      # One stdout summary so a session-start refresh (which discards fleet-sync
      # stderr and relays only stdout) still surfaces the recovery.
      echo "$label: recovered: packed-refs lock cleared on its own during retry"
      return 0
    fi
    is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"
  done

  # Retries exhausted and still the lock signature. Clear ONLY if provably stale.
  # The companion liveness dir is $PROJ (the clone worktree): a live `git -C "$PROJ"`
  # keeps its cwd there even in the narrow window after it closes packed-refs.lock
  # and before it exits, so lsof on $PROJ still catches a holder the lock-file check
  # alone would miss.
  lock=$(packed_refs_lock_path) || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    if fm_lock_is_provably_stale "$lock" "$PROJ" "$FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS"; then
      if ! rm -f "$lock"; then
        echo "$label: failed to remove provably-stale packed-refs lock $lock; leaving it in place" >&2
        return "$rc"
      fi
      echo "$label: removed provably-stale packed-refs lock $lock (age >= ${FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS}s, no live holder) and retrying fetch" >&2
      FETCH_OUTPUT=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); rc=$?
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

# True when some worktree of $PROJ has $DEFAULT checked out (so we cannot attach
# to it here). The current worktree is detached when this is consulted, so any
# match is necessarily another worktree.
default_checked_out_elsewhere() {
  git -C "$PROJ" worktree list --porcelain 2>/dev/null \
    | sed -n 's#^branch refs/heads/##p' \
    | grep -Fxq -- "$DEFAULT"
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
  shift
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

  printf 'commit\n' >&8
  IFS= read -r response <&9 || response=
  exec 8>&-
  exec 9<&-
  wait "$pid" 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ] || [ "$response" != "commit: ok" ]; then
    REF_TRANSACTION_OUTPUT=$(first_line "$(cat "$error_file" 2>/dev/null || true)")
    [ -n "$REF_TRANSACTION_OUTPUT" ] || REF_TRANSACTION_OUTPUT="ref transaction commit failed"
    rm -f "$input_pipe" "$output_pipe" "$error_file"
    rmdir "$txn_dir" 2>/dev/null || true
    return 1
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
  local post_branch post_head post_local post_remote post_tree post_status rollback_output

  PRESERVE_REF="refs/fm-fleet-sync/squash-preserved/$DEFAULT/$local_rev"
  if ! git check-ref-format "$PRESERVE_REF" >/dev/null 2>&1; then
    reconciliation_refusal "unsafe preservation ref identity"
    return 0
  fi
  if operation=$(git_operation_in_progress); then
    reconciliation_refusal "active $operation operation"
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
  if direct_ref_transaction "$update_input" "$PRESERVE_REF" "$REMOTE_REF" "$LOCAL_REF"; then
    :
  else
    update_output=$REF_TRANSACTION_OUTPUT
    reconciliation_refusal "atomic update rejected; preserved $PRESERVE_REF$(if [ -n "$update_output" ]; then printf ': %s' "$(first_line "$update_output")"; fi)"
    return 0
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
    if rollback_output=$(git -C "$PROJ" update-ref --no-deref "$LOCAL_REF" "$local_rev" "$remote_rev" 2>&1); then
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

  if ! fetch_with_packed_refs_lock_guard; then
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
