#!/usr/bin/env bash
# Refresh project clones: fast-forward the checked-out local default branch to
# its sync base when safe, and prune local branches whose upstream tracking
# branch is gone (the remote branch was deleted, i.e. its PR merged) and that no
# worktree still needs.
# Sync base preference: the local default branch's configured upstream (for
# example fork/main on a controlled-fork checkout) when set; otherwise
# origin/<default>. This avoids false STUCK on delivery forks whose origin still
# fetches a diverged upstream owner.
# Self-heals the one unambiguously safe drift: a clean, detached HEAD that holds
# no unique commits (it is an ancestor of the sync base) and whose <default>
# branch is free to check out is re-attached and then fast-forwarded ("recovered:").
# Every other off-default state - a non-default named branch, a detached HEAD with
# unique commits, a dirty tree, or a diverged default - may hold real work, so it
# is left untouched and reported as a quantified, loud "STUCK: ... N commits behind
# ... - needs attention" warning rather than a quiet drift. Nothing is ever forced,
# stashed, or discarded.
# Still skips (benignly) local-only/no-origin projects, missing remotes/branches,
# and fetch failures.
# Pruning never deletes the checked-out branch or a branch that still has a
# worktree, so it cannot discard unlanded work; set FM_FLEET_PRUNE=0 to disable it.
# When fetch hits an orphaned .git/packed-refs.lock, it uses bounded retries and
# removes the lock only when the shared staleness proof can prove it abandoned.
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
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "fleet sync" || exit 1
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
FM_LOCK_LOG_PREFIX=fleet-sync
"$FM_ROOT/bin/fm-guard.sh"

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

prune_gone_branches() {
  # Delete local branches whose upstream tracking branch is gone - the remote
  # branch was deleted, which in this fleet means its PR merged - as long as
  # nothing still needs them. Never the checked-out branch, and never a branch
  # that still has a worktree (a live or not-yet-torn-down task). "Gone" plus
  # "no worktree" already proves the work landed: teardown removes a branch's
  # worktree only after confirming the work reached the remote. We deliberately
  # do NOT also require the branch to be an ancestor of the sync base - PRs in
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

packed_refs_lock_error() {
  printf '%s\n' "$1" \
    | grep -Eiq "(Unable to create|cannot lock ref).*packed-refs[.]lock['\"]?:[[:space:]]+File exists"
}

git_common_dir_abs() {
  local dir
  dir=$(git -C "$PROJ" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$dir" in
    /*) printf '%s\n' "$dir" ;;
    *) (cd "$PROJ/$dir" 2>/dev/null && pwd -P) ;;
  esac
}

# Globals FETCH_ERROR and FETCH_RECOVERY carry the result without swallowing
# recovery summaries that bootstrap relays on stdout.
# FETCH_REMOTE and FETCH_REFSPEC select the guarded fetch target.
fetch_remote() {
  local remote=$1 refspec=$2
  if [ -n "$refspec" ]; then
    git -C "$PROJ" fetch "$remote" --prune --quiet "$refspec"
  else
    git -C "$PROJ" fetch "$remote" --prune --quiet
  fi
}

fetch_with_packed_refs_lock_guard() {
  local git_common_dir lock output attempt=0 remote=${FETCH_REMOTE:-origin} refspec=${FETCH_REFSPEC:-}
  FETCH_ERROR=
  FETCH_RECOVERY=
  git_common_dir=$(git_common_dir_abs) || {
    FETCH_ERROR='cannot determine git common directory'
    return 1
  }
  lock="$git_common_dir/packed-refs.lock"

  while :; do
    if output=$(fetch_remote "$remote" "$refspec" 2>&1); then
      if [ "$attempt" -gt 0 ]; then
        FETCH_RECOVERY='packed-refs lock cleared on its own'
      fi
      return 0
    fi
    FETCH_ERROR=$output
    if ! packed_refs_lock_error "$output"; then
      return 1
    fi
    if [ "$attempt" -lt "$FLEET_SYNC_PACKED_REFS_LOCK_RETRIES" ]; then
      attempt=$((attempt + 1))
      fm_lock_log "waiting ${FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS}s before retrying packed-refs lock ($attempt/$FLEET_SYNC_PACKED_REFS_LOCK_RETRIES)"
      sleep "$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS"
      continue
    fi
    break
  done

  if fm_lock_is_provably_stale "$lock" "$PROJ" "$FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS"; then
    if fm_lock_remove_if_provably_stale "$lock" "$PROJ" "$FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS"; then
      fm_lock_log "removed provably-stale packed-refs lock $lock (no live holder); retrying fetch"
      if output=$(fetch_remote "$remote" "$refspec" 2>&1); then
        FETCH_RECOVERY='removed a stale packed-refs lock (no live holder)'
        return 0
      fi
      FETCH_ERROR=$output
    else
      fm_lock_log "could not atomically quarantine provably-stale packed-refs lock $lock; leaving it in place"
    fi
  else
    fm_lock_log "packed-refs lock $lock is not provably stale; leaving it in place"
  fi
  return 1
}

# Prefer the local default branch's configured upstream as the sync base so
# controlled-fork checkouts (main tracks fork/main while origin still fetches
# the upstream owner) are not false-STUCK against a diverged origin/main.
# Falls back to origin/<default> when no upstream is configured.
resolve_sync_base() {
  local remote merge
  BASE=
  SYNC_REMOTE=
  SYNC_BRANCH=
  SYNC_MERGE_REF=
  remote=$(git -C "$PROJ" config --get "branch.$DEFAULT.remote" 2>/dev/null || true)
  merge=$(git -C "$PROJ" config --get "branch.$DEFAULT.merge" 2>/dev/null || true)
  case "$merge" in
    refs/heads/*)
      SYNC_BRANCH=${merge#refs/heads/}
      if [ -n "$SYNC_BRANCH" ]; then
        SYNC_MERGE_REF=$merge
        if [ "$remote" = "." ]; then
          BASE=$SYNC_BRANCH
        elif [ -n "$remote" ]; then
          SYNC_REMOTE=$remote
          BASE="$remote/$SYNC_BRANCH"
        fi
      fi
      ;;
  esac
  if [ -z "$BASE" ]; then
    SYNC_REMOTE=origin
    SYNC_BRANCH=$DEFAULT
    SYNC_MERGE_REF="refs/heads/$DEFAULT"
    BASE="origin/$DEFAULT"
  fi
}

# Loud, quantified report for a clone we deliberately leave untouched. Includes
# how far behind the sync base it is, so a chronically-stuck clone is visibly
# distinct from a benign one-off skip.
report_stuck() {
  local state=$1 behind
  behind=$(git -C "$PROJ" rev-list --count "HEAD..$BASE" 2>/dev/null) || behind="?"
  echo "$label: STUCK: on $state, $behind commits behind $BASE - needs attention"
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

  # Always refresh origin first (default remote for clones without a custom
  # upstream). A controlled-fork home may still need a second fetch for the
  # delivery remote (fork) once DEFAULT is known.
  FETCH_REMOTE=origin
  FETCH_REFSPEC=
  if ! fetch_with_packed_refs_lock_guard; then
    reason="fetch failed"
    if [ -n "$FETCH_ERROR" ]; then
      reason="$reason: $(first_line "$FETCH_ERROR")"
    fi
    echo "$label: skipped: $reason"
    return 0
  fi
  [ -n "$FETCH_RECOVERY" ] && echo "$label: recovered: $FETCH_RECOVERY"
  origin_fetch_recovery=$FETCH_RECOVERY

  DEFAULT=$(default_branch) || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }
  resolve_sync_base
  # When main tracks fork/main (etc.), also fetch that delivery remote so the
  # base ref is not a stale local cache while origin was the only fetch target.
  if [ -n "$SYNC_REMOTE" ] && [ "$SYNC_REMOTE" != "origin" ]; then
    if ! git -C "$PROJ" remote get-url "$SYNC_REMOTE" >/dev/null 2>&1; then
      echo "$label: skipped: configured upstream remote $SYNC_REMOTE does not exist"
      return 0
    fi
    FETCH_REMOTE=$SYNC_REMOTE
    FETCH_REFSPEC=
    if ! fetch_with_packed_refs_lock_guard; then
      reason="fetch $SYNC_REMOTE failed"
      if [ -n "$FETCH_ERROR" ]; then
        reason="$reason: $(first_line "$FETCH_ERROR")"
      fi
      echo "$label: skipped: $reason"
      return 0
    fi
    if [ -n "$FETCH_RECOVERY" ]; then
      echo "$label: recovered: $FETCH_RECOVERY"
    fi
    FETCH_REFSPEC="+$SYNC_MERGE_REF:refs/remotes/$SYNC_REMOTE/$SYNC_BRANCH"
    if ! fetch_with_packed_refs_lock_guard; then
      reason="fetch $SYNC_REMOTE/$SYNC_BRANCH failed"
      if [ -n "$FETCH_ERROR" ]; then
        reason="$reason: $(first_line "$FETCH_ERROR")"
      fi
      echo "$label: skipped: $reason"
      return 0
    fi
    if [ -n "$FETCH_RECOVERY" ]; then
      echo "$label: recovered: $FETCH_RECOVERY"
    fi
  fi
  prune_gone_branches || true
  # Prefer the first recovery line if only origin recovered.
  if [ -z "${FETCH_RECOVERY:-}" ] && [ -n "${origin_fetch_recovery:-}" ]; then
    FETCH_RECOVERY=$origin_fetch_recovery
  fi
  if ! git -C "$PROJ" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
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
    # the sync base) and whose <default> branch is free to check out here.
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

  if ! git -C "$PROJ" rev-parse --verify --quiet "$DEFAULT^{commit}" >/dev/null; then
    echo "$label: skipped: local $DEFAULT does not exist"
    return 0
  fi

  local_rev=$(git -C "$PROJ" rev-parse "$DEFAULT") || {
    echo "$label: skipped: cannot read local $DEFAULT"
    return 0
  }
  remote_rev=$(git -C "$PROJ" rev-parse "$BASE") || {
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
  if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BASE"; then
    report_stuck "diverged $DEFAULT"
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
