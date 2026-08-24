#!/usr/bin/env bash
# Refresh project clones: fast-forward the checked-out local default branch to
# origin/<default> when safe, and prune local branches whose upstream tracking
# branch is gone (the remote branch was deleted, i.e. its PR merged) and that no
# worktree still needs.
# Self-heals the one unambiguously safe drift: a clean, detached HEAD that holds
# no unique commits (it is an ancestor of origin/<default>) and whose <default>
# branch is free to check out is re-attached and then fast-forwarded ("recovered:").
# A diverged default branch may converge after a fetched history rewrite only when
# the local-only and freshly-fetched-remote-only commits form equal-length,
# topologically oldest-first sequences whose trees match one-to-one by position
# (a differing count, or any positional tree mismatch, refuses), the clone is
# clean, and every linked worktree is inspectable and holds no unlanded content.
# Every other off-default or diverged state may hold real work, so it is left
# untouched and reported as a loud, actionable "STUCK" warning. Nothing is ever
# forced, stashed, or discarded.
# Still skips (benignly) local-only/no-origin projects, missing remotes/branches,
# and fetch failures.
# A candidate under projects/ must be the root of its own work tree: git discovery
# walks up, so a plain nested directory would otherwise resolve to the enclosing
# repository (the firstmate checkout) and be synced under that directory's label.
# Anything else is reported as "skipped: not a clone root" naming the repository
# that would have been touched.
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
# Inert unless FM_TIMING_LOG names a file; only the deferred network stage sets it.
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
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

report_convergence_refusal() {
  local condition=$1 commit=$2 detail=${3:-} behind
  behind=$(git -C "$PROJ" rev-list --count "$DEFAULT..$BASE" 2>/dev/null) || behind="?"
  if [ -n "$detail" ]; then
    echo "$label: STUCK: diverged $DEFAULT; rewrite convergence refused: $condition at commit $commit ($detail); $behind commits behind $BASE - needs attention"
  else
    echo "$label: STUCK: diverged $DEFAULT; rewrite convergence refused: $condition at commit $commit; $behind commits behind $BASE - needs attention"
  fi
}

remote_tree_contains() {
  grep -Fxq -- "$1" <<EOF
$REMOTE_TREES
EOF
}

# Refresh the exact default branch through an explicit heads-to-remote-tracking
# refspec. A successful return proves BASE names a real branch on origin and that
# the remote-tracking ref used by the convergence proof was fetched just now.
refresh_remote_default_for_convergence() {
  local output
  if ! output=$(git -C "$PROJ" fetch origin --quiet --no-tags \
      "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" 2>&1); then
    report_convergence_refusal "remote branch $BASE was not freshly fetched as a real remote-tracking branch" \
      "$local_rev" "$(first_line "$output")"
    return 1
  fi
  if ! git -C "$PROJ" show-ref --verify --quiet "refs/remotes/origin/$DEFAULT"; then
    report_convergence_refusal "fresh fetch did not produce remote-tracking branch $BASE" "$local_rev"
    return 1
  fi
}

# Refuse when a linked worktree cannot be proved clean and landed. A commit not
# reachable from a remote is still content-landed when its exact tree is present
# on the freshly fetched default branch, which covers linked worktrees based on
# the same deliberate history rewrite.
linked_worktrees_are_landed() {
  local project_abs listed wt_path wt_head wt_abs status unlanded commit tree
  project_abs=$(cd "$PROJ" && pwd -P) || {
    report_convergence_refusal "clone path cannot be inspected" "$local_rev"
    return 1
  }
  listed=$(git -C "$PROJ" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || {
    report_convergence_refusal "linked worktrees cannot be listed" "$local_rev"
    return 1
  }
  wt_path=
  wt_head=
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) wt_path=${line#worktree }; wt_head= ;;
      HEAD\ *) wt_head=${line#HEAD } ;;
      '')
        [ -n "$wt_path" ] || continue
        wt_abs=$(cd "$wt_path" 2>/dev/null && pwd -P) || {
          report_convergence_refusal "linked worktree cannot be inspected" "${wt_head:-unknown}" "$wt_path"
          return 1
        }
        if [ "$wt_abs" != "$project_abs" ]; then
          if ! status=$(git -C "$wt_path" status --porcelain 2>/dev/null); then
            report_convergence_refusal "linked worktree status cannot be inspected" "${wt_head:-unknown}" "$wt_path"
            return 1
          fi
          if [ -n "$status" ]; then
            report_convergence_refusal "linked worktree has uncommitted changes" "${wt_head:-unknown}" "$wt_path"
            return 1
          fi
          if ! unlanded=$(git -C "$wt_path" rev-list HEAD --not --remotes 2>/dev/null); then
            report_convergence_refusal "linked worktree commits cannot be inspected" "${wt_head:-unknown}" "$wt_path"
            return 1
          fi
          while IFS= read -r commit; do
            [ -n "$commit" ] || continue
            tree=$(git -C "$PROJ" rev-parse "$commit^{tree}" 2>/dev/null) || {
              report_convergence_refusal "linked worktree commit tree cannot be inspected" "$commit" "$wt_path"
              return 1
            }
            if ! remote_tree_contains "$tree"; then
              report_convergence_refusal "linked worktree has unlanded content" "$commit" "$wt_path; tree $tree is absent from $BASE"
              return 1
            fi
          done <<EOF
$unlanded
EOF
        fi
        wt_path=
        wt_head=
        ;;
    esac
  done <<EOF
$listed

EOF
}

converge_proven_history_rewrite() {
  local commit tree local_count=0 before after status
  local local_only remote_only remote_count remote_commit remote_tree i
  local -a local_commits=() remote_commits=()

  refresh_remote_default_for_convergence || return 1
  remote_rev=$(git -C "$PROJ" rev-parse "$BASE") || {
    report_convergence_refusal "freshly fetched $BASE cannot be read" "$local_rev"
    return 1
  }
  REMOTE_TREES=$(git -C "$PROJ" log --format=%T "$BASE" 2>/dev/null) || {
    report_convergence_refusal "$BASE tree history cannot be inspected" "$local_rev"
    return 1
  }

  # A rewritten counterpart is proved by position, not by mere membership: the
  # local-only and remote-only commits must form equal-length, oldest-first
  # sequences whose trees match one-to-one. Membership alone would accept a local
  # commit (e.g. a revert) that merely recreates an older remote tree and then
  # discard it in the reset below.
  local_only=$(git -C "$PROJ" rev-list --topo-order --reverse "$DEFAULT" --not "$BASE" 2>&1) || {
    report_convergence_refusal "local-only commits cannot be enumerated" "$local_rev" "$(first_line "$local_only")"
    return 1
  }
  remote_only=$(git -C "$PROJ" rev-list --topo-order --reverse "$BASE" --not "$DEFAULT" 2>&1) || {
    report_convergence_refusal "commits unique to $BASE cannot be enumerated" "$local_rev" "$(first_line "$remote_only")"
    return 1
  }
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    local_commits+=("$commit")
  done <<EOF
$local_only
EOF
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    remote_commits+=("$commit")
  done <<EOF
$remote_only
EOF
  local_count=${#local_commits[@]}
  remote_count=${#remote_commits[@]}
  if [ "$local_count" -gt 0 ] && [ "$local_count" -ne "$remote_count" ]; then
    report_convergence_refusal "local-only and $BASE-only commit counts differ" "$local_rev" \
      "$local_count local-only commits vs $remote_count commits unique to $BASE"
    return 1
  fi
  i=0
  while [ "$i" -lt "$local_count" ]; do
    commit=${local_commits[$i]}
    remote_commit=${remote_commits[$i]}
    i=$(( i + 1 ))
    tree=$(git -C "$PROJ" rev-parse "$commit^{tree}" 2>/dev/null) || {
      report_convergence_refusal "local-only commit tree cannot be inspected" "$commit"
      return 1
    }
    remote_tree=$(git -C "$PROJ" rev-parse "$remote_commit^{tree}" 2>/dev/null) || {
      report_convergence_refusal "$BASE commit tree cannot be inspected" "$remote_commit"
      return 1
    }
    if [ "$tree" != "$remote_tree" ]; then
      report_convergence_refusal "local-only commit has no identical tree on $BASE" "$commit" \
        "tree $tree; $BASE commit $remote_commit has tree $remote_tree"
      return 1
    fi
  done

  if ! status=$(git -C "$PROJ" status --porcelain 2>/dev/null); then
    report_convergence_refusal "working tree cleanliness cannot be inspected" "$local_rev"
    return 1
  fi
  if [ -n "$status" ]; then
    report_convergence_refusal "working tree is not clean" "$local_rev" "$(first_line "$status")"
    return 1
  fi
  linked_worktrees_are_landed || return 1

  before=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    report_convergence_refusal "local $DEFAULT cannot be read" "$local_rev"
    return 1
  }
  if ! git -C "$PROJ" reset --hard --quiet "$BASE"; then
    report_convergence_refusal "reset onto proven $BASE failed" "$local_rev"
    return 1
  fi
  after=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    echo "$label: converged rewritten $DEFAULT but cannot read the new revision"
    return 0
  }
  echo "$label: converged rewritten $DEFAULT $before..$after ($local_count local-only commit trees matched $BASE)"
}

sync_project() {
  PROJ=$1
  label=$(project_label)

  if [ ! -d "$PROJ" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  # Git repository discovery walks UP from $PROJ, so a plain directory merely
  # nested inside a repository - a worktree container left under projects/, say -
  # resolves to the ENCLOSING repository, which in a firstmate home is the
  # firstmate checkout itself. Every later `git -C "$PROJ"` would then read, prune
  # and fast-forward that repository under this project's label, turning a routine
  # refresh into an unrequested self-update reported as a project sync. Require
  # $PROJ to be the root of its own work tree before any other git command runs.
  proj_top=$(git -C "$PROJ" rev-parse --show-toplevel 2>/dev/null) || proj_top=""
  if [ -z "$proj_top" ]; then
    echo "$label: skipped: not a git repo"
    return 0
  fi
  # Both sides are physical paths (git resolves --show-toplevel through symlinks),
  # so a symlinked clone dir still compares equal to its own root.
  proj_abs=$(cd "$PROJ" && pwd -P) || proj_abs=""
  if [ "$proj_top" != "$proj_abs" ]; then
    echo "$label: skipped: not a clone root (git would act on $proj_top)"
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
  if [ "$dirty" = yes ]; then
    if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BASE" 2>/dev/null \
        && ! git -C "$PROJ" merge-base --is-ancestor "$BASE" "$DEFAULT" 2>/dev/null; then
      report_convergence_refusal "working tree is not clean" "$local_rev" \
        "$(first_line "$(git -C "$PROJ" status --porcelain 2>/dev/null || true)")"
    else
      report_stuck "$(stuck_state)"
    fi
    return 0
  fi
  if [ "$local_rev" = "$remote_rev" ]; then
    if [ "$recovered" = yes ]; then
      echo "$label: recovered: re-attached $DEFAULT (already current)"
    else
      echo "$label: already current"
    fi
    return 0
  fi
  if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BASE"; then
    if git -C "$PROJ" merge-base --is-ancestor "$BASE" "$DEFAULT" 2>/dev/null; then
      report_stuck "diverged $DEFAULT"
    else
      converge_proven_history_rewrite || true
    fi
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
  # Per-clone elapsed, so a fleet refresh that runs long names WHICH clone cost
  # the time instead of only its total. Recording is a no-op unless the deferred
  # network stage asked for it.
  __fm_timing_stamp=$(fm_timing_now_ms)
  sync_project "$proj"
  fm_timing_record clone sync "$__fm_timing_stamp" "$(basename "$proj")"
done
