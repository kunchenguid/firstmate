#!/usr/bin/env bash
# Refresh project clones: fast-forward the checked-out local default branch to
# origin/<default> when safe, and prune local branches whose upstream tracking
# branch is gone (the remote branch was deleted, i.e. its PR merged) and that no
# worktree still needs.
# Self-heals the one unambiguously safe drift: a clean, detached HEAD that holds
# no unique commits (it is an ancestor of origin/<default>) and whose <default>
# branch is free to check out is re-attached and then fast-forwarded ("recovered:").
# Every other off-default state - a non-default named branch, a detached HEAD with
# unique commits, a dirty tree, or a diverged default - may hold real work, so it
# is left untouched and reported as a quantified, loud "STUCK: ... N commits behind
# ... - needs attention" warning rather than a quiet drift. Nothing is ever forced,
# stashed, or discarded.
# Dirty warnings quantify untracked files and call out those under repository
# skill directories, so local skill drafts cannot accumulate invisibly until
# they collide with paths that later become tracked upstream.
# Still skips (benignly) local-only/no-origin projects, missing remotes/branches,
# and fetch failures.
# Pruning never deletes the checked-out branch or a branch that still has a
# worktree, so it cannot discard unlanded work; set FM_FLEET_PRUNE=0 to disable it.
# Every origin-backed invocation probes `ls-remote --symref origin HEAD` after
# fetching and proves the fetched ref matches that live tip before any local
# branch or worktree mutation, so cached refs/remotes/origin/HEAD is never an
# authority.
# The common mutation path owns a cooperative lock keyed by the canonical Git
# common directory, so scheduler, preflight, teardown, and merge-wake callers
# serialize every fetch, prune, checkout, and fast-forward of the same clone.
# Each checkout mutation entrypoint is process-tree bounded by
# FM_CHECKOUT_REFRESH_SYNC_TIMEOUT, including direct teardown and merge-wake calls.
# When the fetch fails on an orphaned .git/packed-refs.lock (left by a ref rewrite
# killed mid-write - e.g. a timed-out bootstrap sync or a teardown process kill),
# it is retried with a bounded wait and removed only when provably stale; see
# fetch_with_packed_refs_lock_guard and the FM_FLEET_SYNC_PACKED_REFS_LOCK_* knobs.
# Usage: fm-fleet-sync.sh [<project-dir-or-name>]
# The single-project form accepts an exact Git repository root (absolute, or
# relative to the caller's cwd) or a bare "<name>"/"projects/<name>" form,
# resolved against this home's projects dir ($FM_HOME/projects, or
# $FM_PROJECTS_OVERRIDE).
# Delivery mode lookup always uses the checkout directory's basename, so a
# discovered parallel clone still honors the registry entry for that project.
# Bare names and "projects/<name>" forms prefer this home's projects dir before
# falling back to an explicit path. Example: from anywhere,
# `fm-fleet-sync.sh dotfiles-private` syncs just that one clone, same as
# passing its full projects/dotfiles-private path.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-checkout-lock-lib.sh
. "$SCRIPT_DIR/fm-checkout-lock-lib.sh"
PROJECTS=$(fm_checkout_lexical_path "$PROJECTS" 1) || {
  echo "error: projects root contains an unsafe or uninspectable path component: $PROJECTS" >&2
  exit 1
}
if [ -e "$PROJECTS" ]; then
  PROJECTS=$(fm_checkout_trusted_dir "$PROJECTS") || {
    echo "error: projects root must be an exact real directory: $PROJECTS" >&2
    exit 1
  }
fi
CHECKOUT_STATE_BASE="${FM_CHECKOUT_REFRESH_STATE_BASE:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/checkout-refresh}"
CHECKOUT_LOCK_ROOT=$(fm_checkout_lock_root "$CHECKOUT_STATE_BASE")
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-process-tree-lib.sh
. "$SCRIPT_DIR/fm-process-tree-lib.sh"
FM_LOCK_LOG_PREFIX=fleet-sync
"$FM_ROOT/bin/fm-guard.sh" || true

FLEET_SYNC_TIMEOUT=${FM_CHECKOUT_REFRESH_SYNC_TIMEOUT:-60}
EXPECTED_ORIGIN_KIND=${FM_FLEET_SYNC_EXPECTED_ORIGIN_KIND:-}
EXPECTED_ORIGIN_VALUE=${FM_FLEET_SYNC_EXPECTED_ORIGIN_VALUE:-}
EXPECTED_PHYSICAL_IDENTITY=${FM_FLEET_SYNC_EXPECTED_PHYSICAL_IDENTITY:-}
case "$FLEET_SYNC_TIMEOUT" in
  ''|*[!0-9]*|0)
    echo "error: FM_CHECKOUT_REFRESH_SYNC_TIMEOUT must be a positive integer" >&2
    exit 2
    ;;
esac
case "$EXPECTED_ORIGIN_KIND" in
  ''|origin|no-origin) ;;
  *) echo "error: invalid expected checkout origin kind" >&2; exit 2 ;;
esac
[ "$EXPECTED_ORIGIN_KIND" != origin ] || [ -n "$EXPECTED_ORIGIN_VALUE" ] || {
  echo "error: expected origin URL is missing" >&2
  exit 2
}
case "$EXPECTED_PHYSICAL_IDENTITY" in
  '') ;;
  *[!A-Za-z0-9:._-]*)
    echo "error: invalid expected checkout physical identity" >&2
    exit 2
    ;;
esac

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

canonical_dir() {
  fm_checkout_trusted_dir "$1"
}

exact_git_root() {
  local candidate=$1 canonical top canonical_top
  canonical=$(canonical_dir "$candidate") || return 1
  top=$(git -C "$canonical" rev-parse --show-toplevel 2>/dev/null) || return 1
  canonical_top=$(canonical_dir "$top") || return 1
  [ "$canonical" = "$canonical_top" ] || return 1
  fm_checkout_validate_git_metadata "$canonical" >/dev/null || return 1
  printf '%s\n' "$canonical"
}

inspect_mutation_origin() {
  local remotes
  remotes=$(git -C "$PROJ" remote 2>/dev/null) || return 1
  if printf '%s\n' "$remotes" | grep -Fxq origin; then
    MUTATION_ORIGIN_VALUE=$(git -C "$PROJ" remote get-url origin 2>/dev/null) || return 1
    [ -n "$MUTATION_ORIGIN_VALUE" ] || return 1
    MUTATION_ORIGIN_KIND=origin
  else
    MUTATION_ORIGIN_KIND=no-origin
    MUTATION_ORIGIN_VALUE=
  fi
}

verify_mutation_identity() {
  local root physical
  if [ "${FM_FLEET_SYNC_TEST:-0}" = 1 ] \
    && [ -n "${FM_FLEET_SYNC_TEST_DRIFT_ORIGIN_TO:-}" ] \
    && [ "${FM_FLEET_SYNC_TEST_DRIFTED:-0}" != 1 ]; then
    git -C "$PROJ" remote set-url origin "$FM_FLEET_SYNC_TEST_DRIFT_ORIGIN_TO" || return 1
    FM_FLEET_SYNC_TEST_DRIFTED=1
  fi
  root=$(exact_git_root "$PROJ") || return 1
  [ "$root" = "$PROJ" ] || return 1
  physical=$(fm_checkout_physical_path_identity "$PROJ" directory) || return 1
  if [ -z "$EXPECTED_PHYSICAL_IDENTITY" ]; then
    EXPECTED_PHYSICAL_IDENTITY=$physical
  fi
  [ "$physical" = "$EXPECTED_PHYSICAL_IDENTITY" ] || return 1
  inspect_mutation_origin || return 1
  if [ -z "$EXPECTED_ORIGIN_KIND" ]; then
    EXPECTED_ORIGIN_KIND=$MUTATION_ORIGIN_KIND
    EXPECTED_ORIGIN_VALUE=$MUTATION_ORIGIN_VALUE
  fi
  [ "$MUTATION_ORIGIN_KIND" = "$EXPECTED_ORIGIN_KIND" ] \
    && [ "$MUTATION_ORIGIN_VALUE" = "$EXPECTED_ORIGIN_VALUE" ]
}

LIVE_DEFAULT_BRANCH=
LIVE_DEFAULT_TIP=
LIVE_PROBE_OUTPUT=
probe_live_default() {
  local line ref
  LIVE_DEFAULT_BRANCH=
  LIVE_DEFAULT_TIP=
  LIVE_PROBE_OUTPUT=$(git -C "$PROJ" ls-remote --symref origin HEAD 2>&1) || return 1
  while IFS= read -r line; do
    case "$line" in
      "ref: refs/heads/"*$'\t'"HEAD")
        ref=${line#ref: refs/heads/}
        LIVE_DEFAULT_BRANCH=${ref%$'\t'HEAD}
        ;;
      *$'\t'"HEAD")
        LIVE_DEFAULT_TIP=${line%$'\t'HEAD}
        ;;
    esac
  done <<EOF
$LIVE_PROBE_OUTPUT
EOF
  [ -n "$LIVE_DEFAULT_BRANCH" ] \
    && [ -n "$LIVE_DEFAULT_TIP" ] \
    && git check-ref-format --branch "$LIVE_DEFAULT_BRANCH" >/dev/null 2>&1
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

fetch_expected_origin() {
  if ! verify_mutation_identity; then
    FETCH_OUTPUT="checkout repository or origin identity drifted before fetch"
    return 1
  fi
  FETCH_OUTPUT=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1)
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
  if fetch_expected_origin; then rc=0; else rc=$?; fi
  [ "$rc" -eq 0 ] && return 0
  is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"

  lock=$(packed_refs_lock_path) || lock=""
  lock_desc=${lock:-packed-refs.lock}
  while [ "$attempt" -lt "$FLEET_SYNC_PACKED_REFS_LOCK_RETRIES" ]; do
    attempt=$(( attempt + 1 ))
    echo "$label: fetch blocked by packed-refs lock ($lock_desc); waiting ${FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES}) (owning process may be exiting)" >&2
    sleep "$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS"
    if fetch_expected_origin; then rc=0; else rc=$?; fi
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
      if fetch_expected_origin; then rc=0; else rc=$?; fi
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
  [ "${FM_FLEET_PRUNE:-1}" != "0" ] || return 0

  local worktree_output worktree_branches current refs_output refline branch track
  local remote_refs remote_ref base_tree merged_tree landed
  worktree_output=$(git -C "$PROJ" worktree list --porcelain 2>/dev/null) || {
    echo "$label: skipped: cannot inspect worktree ownership before branch pruning"
    return 1
  }
  worktree_branches=$(printf '%s\n' "$worktree_output" | sed -n 's#^branch refs/heads/##p')
  current=$(git -C "$PROJ" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  refs_output=$(git -C "$PROJ" for-each-ref \
    --format='%(refname:short) %(upstream:track)' refs/heads 2>/dev/null) || {
    echo "$label: skipped: cannot inspect local branches before pruning"
    return 1
  }
  remote_refs=$(git -C "$PROJ" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null) || {
    echo "$label: skipped: cannot inspect remote refs before branch pruning"
    return 1
  }
  base_tree=$(git -C "$PROJ" rev-parse "$BASE^{tree}" 2>/dev/null) || {
    echo "$label: skipped: cannot inspect default-branch content before branch pruning"
    return 1
  }

  while IFS= read -r refline; do
    branch=${refline%% *}
    track=${refline#* }
    [ "$track" = "[gone]" ] || continue
    [ -n "$branch" ] || continue
    [ "$branch" != "$current" ] || continue
    if printf '%s\n' "$worktree_branches" | grep -Fxq -- "$branch"; then
      continue
    fi
    landed=0
    while IFS= read -r remote_ref; do
      [ -n "$remote_ref" ] || continue
      if git -C "$PROJ" merge-base --is-ancestor "$branch" "$remote_ref" 2>/dev/null; then
        landed=1
        break
      fi
    done <<EOF
$remote_refs
EOF
    if [ "$landed" -eq 0 ]; then
      merged_tree=$(git -C "$PROJ" merge-tree --write-tree "$BASE" "$branch" 2>/dev/null || true)
      [ -n "$merged_tree" ] && [ "$merged_tree" = "$base_tree" ] && landed=1
    fi
    if [ "$landed" -eq 0 ]; then
      echo "$label: STUCK: retained gone branch $branch because landed work cannot be proved"
      continue
    fi
    if git -C "$PROJ" branch -D -- "$branch" >/dev/null 2>&1; then
      echo "$label: pruned $branch"
    fi
  done <<EOF
$refs_output
EOF
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
  if [ "$dirty" = yes ]; then
    s="$s with uncommitted changes"
    if [ "$untracked_count" -gt 0 ]; then
      s="$s ($untracked_count untracked"
      if [ "$skill_draft_count" -gt 0 ]; then
        s="$s, $skill_draft_count under repository skill directories"
      fi
      s="$s)"
    fi
  fi
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

sync_project() (
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
  canonical=$(exact_git_root "$PROJ") || {
    echo "$label: skipped: target must be an exact canonical Git repository root"
    return 1
  }
  PROJ=$canonical
  label=$(project_label)
  registry_name=$(basename "$PROJ")
  mode_line=$("$FM_ROOT/bin/fm-project-mode.sh" "$registry_name" 2>/dev/null || echo "no-mistakes off")
  mode=${mode_line%% *}
  if [ "$mode" = "local-only" ]; then
    echo "$label: skipped: local-only project"
    return 0
  fi
  if ! fm_checkout_lock_prepare "$CHECKOUT_LOCK_ROOT"; then
    echo "$PROJ: skipped: refresh lock setup failed"
    return 0
  fi
  checkout_lock=$(fm_checkout_lock_path "$PROJ" "$CHECKOUT_LOCK_ROOT") || {
    echo "$PROJ: skipped: repository lock identity cannot be resolved"
    return 0
  }
  FM_CHECKOUT_LOCK_ACTIVE_PATH=${FM_FLEET_SYNC_LOCK_PATH:-}
  FM_CHECKOUT_LOCK_ACTIVE_OWNER_DIR=${FM_FLEET_SYNC_LOCK_OWNER_DIR:-}
  FM_CHECKOUT_LOCK_ACTIVE_OWNER_PID=${FM_FLEET_SYNC_LOCK_OWNER_PID:-}
  if [ "${FM_FLEET_SYNC_BOUNDED_CHILD:-0}" != 1 ] \
    || [ "$FM_CHECKOUT_LOCK_ACTIVE_PATH" != "$checkout_lock" ] \
    || ! fm_checkout_lock_active_scope_owns "$checkout_lock"; then
    echo "$label: skipped: bounded refresh does not own the shared checkout mutation lock"
    return "$FM_CHECKOUT_LOCK_FAILURE_STATUS"
  fi

  if ! verify_mutation_identity; then
    echo "$label: skipped: checkout repository or origin identity drifted before mutation"
    return 0
  fi
  if [ "$EXPECTED_ORIGIN_KIND" != origin ]; then
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

  if ! verify_mutation_identity; then
    echo "$label: skipped: checkout repository or origin identity drifted after fetch"
    return 0
  fi
  if ! probe_live_default; then
    reason="cannot probe live upstream default branch"
    if [ -n "$LIVE_PROBE_OUTPUT" ]; then
      reason="$reason: $(first_line "$LIVE_PROBE_OUTPUT")"
    fi
    echo "$label: skipped: $reason"
    return 0
  fi
  DEFAULT=$LIVE_DEFAULT_BRANCH
  BASE="origin/$DEFAULT"
  if ! git -C "$PROJ" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
    echo "$label: skipped: $BASE does not exist"
    return 0
  fi
  remote_rev=$(git -C "$PROJ" rev-parse "$BASE^{commit}") || {
    echo "$label: skipped: cannot read $BASE"
    return 0
  }
  if [ "$remote_rev" != "$LIVE_DEFAULT_TIP" ]; then
    echo "$label: skipped: fetched $BASE does not match live upstream HEAD - retry later"
    return 0
  fi

  cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
  dirty=no
  if ! status_raw=$(GIT_OPTIONAL_LOCKS=0 git -C "$PROJ" status --porcelain=v1 --untracked-files=all 2>/dev/null); then
    echo "$label: skipped: working tree cleanliness cannot be inspected"
    return 0
  fi
  [ -z "$status_raw" ] || dirty=yes
  if ! verify_mutation_identity; then
    echo "$label: skipped: checkout repository or origin identity drifted before branch pruning"
    return 0
  fi
  prune_gone_branches || return 0
  untracked_count=0
  skill_draft_count=0
  if [ "$dirty" = yes ]; then
    untracked_count=$(git -C "$PROJ" ls-files --others --exclude-standard -- 2>/dev/null \
      | awk 'END { print NR + 0 }')
    skill_draft_count=$(git -C "$PROJ" ls-files --others --exclude-standard -- \
      .agents/skills .claude/skills .codex/skills skills 2>/dev/null \
      | awk 'END { print NR + 0 }')
  fi
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
      if ! verify_mutation_identity; then
        echo "$label: skipped: checkout repository or origin identity drifted before checkout"
        return 0
      fi
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
  if ! verify_mutation_identity; then
    echo "$label: skipped: checkout repository or origin identity drifted before fast-forward"
    return 0
  fi
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
)

run_sync_project_bounded() (
  local project=$1 status label checkout_lock lock_owner_dir lock_owner_pid cleanup_status canonical
  local FM_PROCESS_TREE_GUARD_FILE
  if [ ! -d "$project" ] \
    || ! git -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    sync_project "$project"
    return
  fi
  canonical=$(exact_git_root "$project") || {
    printf '%s: skipped: target must be an exact canonical Git repository root\n' "$project"
    return 1
  }
  project=$canonical
  PROJ=$project
  label=$(project_label)
  if ! fm_checkout_lock_prepare "$CHECKOUT_LOCK_ROOT"; then
    echo "$project: skipped: refresh lock setup failed"
    return 0
  fi
  checkout_lock=$(fm_checkout_lock_path "$project" "$CHECKOUT_LOCK_ROOT") || {
    echo "$project: skipped: repository lock identity cannot be resolved"
    return 0
  }
  if ! fm_lock_try_acquire "$checkout_lock"; then
    echo "$project: skipped: refresh already running (pid ${FM_LOCK_HELD_PID:-unknown})"
    return 0
  fi
  lock_owner_dir=${FM_LOCK_OWNER_DIR:?}
  lock_owner_pid=$(cat "$lock_owner_dir/pid" 2>/dev/null) || {
    fm_lock_release "$checkout_lock"
    echo "$project: skipped: refresh lock ownership cannot be proved"
    return 0
  }
  FM_PROCESS_TREE_GUARD_FILE="$lock_owner_dir/process-group"
  export FM_PROCESS_TREE_GUARD_FILE
  trap 'fm_lock_release "$checkout_lock"' EXIT
  if fm_run_bounded "$FLEET_SYNC_TIMEOUT" \
      env FM_FLEET_SYNC_BOUNDED_CHILD=1 \
      FM_FLEET_SYNC_LOCK_PATH="$checkout_lock" \
      FM_FLEET_SYNC_LOCK_OWNER_DIR="$lock_owner_dir" \
      FM_FLEET_SYNC_LOCK_OWNER_PID="$lock_owner_pid" \
      "$SCRIPT_DIR/fm-fleet-sync.sh" "$project"; then
    status=0
  else
    status=$?
  fi
  cleanup_status=$FM_PROCESS_TREE_CLEANUP_STATUS
  if [ "$cleanup_status" != verified ]; then
    printf '%s: skipped: refresh process cleanup is unverified; the guarded checkout lock is retained for inspection\n' "$label"
    return "$FM_CHECKOUT_PROCESS_CLEANUP_FAILURE_STATUS"
  fi
  [ "$status" -ne 0 ] || return 0
  if [ "$status" -eq 124 ]; then
    printf '%s: skipped: refresh timed out after %ss\n' "$label" "$FLEET_SYNC_TIMEOUT"
    return 0
  fi
  return "$status"
)

if [ $# -eq 1 ]; then
  project=$(resolve_project_arg "$1")
  if [ "${FM_FLEET_SYNC_BOUNDED_CHILD:-0}" = 1 ]; then
    sync_project "$project"
    exit $?
  else
    run_sync_project_bounded "$project"
    exit $?
  fi
fi

[ -d "$PROJECTS" ] || exit 0
for proj in "$PROJECTS"/*; do
  [ -e "$proj" ] || continue
  if [ -L "$proj" ]; then
    printf '%s: skipped: target must be an exact canonical Git repository root\n' "$proj"
    false
    continue
  fi
  [ -d "$proj" ] || continue
  run_sync_project_bounded "$proj"
done
