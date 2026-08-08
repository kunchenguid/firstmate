#!/usr/bin/env bash
# shellcheck disable=SC2153 # BACKEND/STATE/T are teardown-scope globals resolved from the task meta (see header)
# Cleanup building blocks for a finished task, factored from bin/fm-teardown.sh
# with byte-identical behavior. bin/fm-teardown.sh sources this library and
# keeps its exact main flow; terminal orchestration composes the same units
# under the attempt lock.
#
# Behavior-preserving extraction only: every function body below is byte
# identical to its origin in bin/fm-teardown.sh. Cross-references that still
# live in fm-teardown.sh's scope (worktree_git_lock_path, canonical_existing_dir,
# pr_is_merged, content_in_default, and the WT/STATE/ID/T/BACKEND globals
# resolved from the task meta) are kept as-is - this library is sourced BY
# teardown, so those names remain in scope when teardown runs.
#
# The units here are the pieces a structured cleanup operation composes under
# an attempt lock: the treehouse return with transient and stale-lock recovery
# (teardown_treehouse_return), the landed-work predicate (work_is_landed) and
# its PR-number lookup (pr_number_from_branch), the busy-state and hook-token
# retirement (retire_busy_state, remove_grok/kimi_turnend_auth), the PR-check
# artifact validation and removal (validate_pr_poll_cleanup,
# remove_pr_poll_artifacts), the Orca worktree path-match gates
# (require_orca_worktree_path_match[_if_present]), the herdr
# endpoint-confirmed-gone gate (require_herdr_endpoint_confirmed_gone), and
# the final volatile state-file removal (remove_task_state_files).
set -u

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# shellcheck disable=SC2034
FM_CLEANUP_LIB_SOURCED=1

# --- provider hook-token retirement ----------------------------------------
remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.grok-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

remove_kimi_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.kimi-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="$HOME/.kimi-code/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

# --- busy-state retirement ------------------------------------------------
retire_busy_state() {
  local state_dir=$1 id=$2 gen=${3:-}
  if [ -n "$gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$state_dir" "$id" --gen "$gen"
  elif [ -f "$state_dir/$id.busy-gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$state_dir" "$id" --current-gen
  fi
}

# --- PR-check artifact validation and removal ------------------------------
validate_pr_poll_cleanup() {
  local state_dir=$1 id=$2 quarantine state_device artifact has_artifact=0
  fm_task_id_path_safe "$id" || return 0
  quarantine="$state_dir/.pr-check-quarantine"
  if [ "$id" = _noncanonical ] \
    && { [ -e "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -e "$quarantine/_noncanonical.diagnostic.noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.noncanonical" ]; }; then
    echo "REFUSED: legacy PR-check quarantine migration is incomplete; preserving task state." >&2
    return 1
  fi
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  if [ -e "$quarantine" ] || [ -L "$quarantine" ]; then
    has_artifact=1
  fi
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ]; then
      echo "REFUSED: unsafe task PR-check artifact; preserving task state." >&2
      return 1
    fi
  done
  if [ -e "$state_dir/$id.pr-poll-retirement" ] \
    || [ -L "$state_dir/$id.pr-poll-retirement" ]; then
    fm_pr_poll_retirement_state_valid "$state_dir" "$id" || {
      echo "REFUSED: invalid PR-poll retirement receipt; preserving task state." >&2
      return 1
    }
  fi
  [ -e "$quarantine" ] || [ -L "$quarantine" ] || return 0
  if [ ! -d "$state_dir" ] || [ -L "$state_dir" ] \
    || [ ! -d "$quarantine" ] || [ -L "$quarantine" ]; then
    echo "REFUSED: unsafe PR-check quarantine path $quarantine; preserving task state." >&2
    return 1
  fi
  if [ "$(fm_pr_file_device "$quarantine")" != "$state_device" ] \
    || [ "$(fm_pr_file_mode "$quarantine")" != 700 ]; then
    echo "REFUSED: PR-check quarantine is not on the task state device; preserving task state." >&2
    return 1
  fi
  for artifact in "$quarantine/$id."*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if ! fm_pr_private_file_valid "$artifact" 600 "$state_device"; then
      echo "REFUSED: unsafe task quarantine entry; preserving task state." >&2
      return 1
    fi
  done
}

remove_pr_poll_artifacts() {
  local state_dir=$1 id=$2 quarantine artifact
  validate_pr_poll_cleanup "$state_dir" "$id" || return 1
  fm_pr_poll_retirement_recover_one "$state_dir" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" || return 1
  rm -f "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust" || return 1
  if fm_task_id_path_safe "$id"; then
    quarantine="$state_dir/.pr-check-quarantine"
    if [ -d "$quarantine" ] && [ ! -L "$quarantine" ]; then
      for artifact in "$quarantine/$id."*; do
        [ -e "$artifact" ] || [ -L "$artifact" ] || continue
        rm -f -- "$artifact" || return 1
      done
      rmdir "$quarantine" 2>/dev/null || true
    fi
  fi
}

# --- landed-work predicate and PR-number lookup ----------------------------
# Resolve the PR number for a worktree branch via gh-axi. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup failure,
# so the caller treats it as "no PR found" (fail-safe).
pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$WT" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# Has the worktree's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current local work is contained in the PR head, OR the content is already in the
# default branch (fallback, which also covers the no-PR and gh-error paths). False
# only for genuinely unlanded work.
work_is_landed() {
  local branch=$1
  pr_is_merged "$branch" && return 0
  content_in_default
}

# --- treehouse return with transient and stale-lock recovery ---------------

# True when treehouse/git stderr shows the transient index.lock "File exists" race.
# Other return failures must not enter the retry path.
treehouse_return_is_index_lock_error() {
  local text=$1
  printf '%s\n' "$text" | grep -Eq "Unable to create ['\"].*index\\.lock['\"]: File exists"
}

# Return a worktree/home via `treehouse return --force`, tolerating a transient or
# stale git index.lock left by a killed crew process. See the script header.
teardown_treehouse_return() {
  local dir=$1 cd_dir=$2 label=$3 post_cleanup_check=${4:-}
  local out lock attempt=0 max_retries lock_desc

  # Capture stdout+stderr so non-lock failures stay visible and lock failures can
  # be matched by signature even when the lock file is already gone mid-check.
  if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  [ -n "$out" ] && printf '%s\n' "$out" >&2

  if ! treehouse_return_is_index_lock_error "$out"; then
    return 1
  fi

  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ]; then
    lock_desc=$lock
  else
    lock_desc="index.lock"
  fi

  max_retries=$TREEHOUSE_RETURN_LOCK_RETRIES
  case "$max_retries" in ''|*[!0-9]*) max_retries=3 ;; esac

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$(( attempt + 1 ))
    echo "teardown: $label return failed with transient git lock ($lock_desc); waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${max_retries})" >&2
    sleep "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"

    if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
      [ -n "$out" ] && printf '%s\n' "$out"
      echo "teardown: $label return succeeded on retry; lock cleared on its own" >&2
      return 0
    fi
    [ -n "$out" ] && printf '%s\n' "$out" >&2

    if ! treehouse_return_is_index_lock_error "$out"; then
      echo "teardown: $label return failed with a non-lock error after retry; aborting" >&2
      return 1
    fi
  done

  # Refresh lock path after the patience window; it may have appeared, moved, or
  # cleared while we waited.
  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    lock_desc=$lock
    if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
      rm -f "$lock"
      echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying $label return" >&2
      if [ -n "$post_cleanup_check" ]; then
        if ! "$post_cleanup_check"; then
          echo "teardown: $label return aborted after stale-lock cleanup because safety checks failed" >&2
          return 1
        fi
      fi
      if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
        [ -n "$out" ] && printf '%s\n' "$out"
        echo "teardown: $label return succeeded after stale-lock cleanup" >&2
        return 0
      fi
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      echo "teardown: $label return still failing after stale-lock cleanup" >&2
      return 1
    fi

    echo "teardown: $label return failed: git lock $lock_desc persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
  fi

  echo "teardown: $label return failed: git index.lock signature persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) even after the lock file disappeared" >&2
  return 1
}

# --- orca worktree path-match gates ---------------------------------------
require_orca_worktree_path_match() {
  local worktree_id=$1 inspected=$2 resolved inspected_abs resolved_abs
  resolved=$(fm_backend_worktree_path orca "$worktree_id") || {
    echo "REFUSED: cannot resolve Orca worktree id $worktree_id to a path; preserving metadata." >&2
    return 1
  }
  inspected_abs=$(canonical_existing_dir "$inspected") || {
    echo "REFUSED: cannot canonicalize inspected worktree ${inspected:-<missing>}; preserving metadata." >&2
    return 1
  }
  resolved_abs=$(canonical_existing_dir "$resolved") || {
    echo "REFUSED: Orca worktree id $worktree_id resolved to uninspectable path ${resolved:-<missing>}; preserving metadata." >&2
    return 1
  }
  if [ "$resolved_abs" != "$inspected_abs" ]; then
    echo "REFUSED: Orca worktree id $worktree_id resolves to $resolved_abs, not inspected worktree $inspected_abs." >&2
    echo "Cannot verify dirty or unlanded work for the worktree Orca would remove; preserving metadata." >&2
    return 1
  fi
}

require_orca_worktree_path_match_if_present() {
  local worktree_id=$1 inspected=$2
  [ -n "$inspected" ] && [ -e "$inspected" ] || return 0
  require_orca_worktree_path_match "$worktree_id" "$inspected"
}

# --- herdr endpoint-confirmed-gone gate ------------------------------------

require_herdr_endpoint_confirmed_gone() {
  # A refused, skipped, or failed Herdr close must never erase a live task's
  # durable endpoint identity: unless the exact pane is confirmed gone, retain
  # every record and stop before any removal below so a later rerun can retry
  # the locked close. Only a structured not-found proves the pane gone; unknown
  # presence, missing or malformed endpoint identity, and missing confirmation
  # machinery all refuse.
  if [ "$BACKEND" = herdr ]; then
    fm_backend_source herdr || true
    if ! declare -F fm_backend_herdr_endpoint_confirmed_gone >/dev/null 2>&1; then
      echo "error: herdr endpoint confirmation is unavailable for $ID; retaining every durable task record" >&2
      exit 1
    fi
    if ! fm_backend_herdr_endpoint_confirmed_gone "$T"; then
      echo "error: herdr pane $T for $ID is not confirmed gone after its close was refused, skipped, or failed; retaining every durable task record - rerun teardown once the close can run under the session lock" >&2
      exit 1
    fi
  fi
}

# --- final volatile state-file removal ------------------------------------

remove_task_state_files() {
  rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.meta" \
    "$STATE/$ID.pi-ext.ts" "$STATE/$ID.grok-turnend-token" \
    "$STATE/$ID.kimi-turnend-token" "$STATE/$ID.muse-session" \
    "$STATE/$ID.muse-session-current" \
    "$STATE/.$ID.open-decisions-cursor"
}
