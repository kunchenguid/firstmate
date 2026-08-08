#!/usr/bin/env bash
# shellcheck disable=SC2153 # BACKEND/STATE/T are teardown-scope globals resolved from the task meta (see header)
# Cleanup building blocks for a finished task, factored from bin/fm-teardown.sh
# with byte-identical behavior. bin/fm-teardown.sh sources this library and
# keeps its exact main flow; terminal orchestration composes the same units
# under the attempt lock.
#
# Behavior-preserving extraction only: every function body below is byte
# identical to its origin in bin/fm-teardown.sh. Cross-references that still
# live in fm-teardown.sh's scope (canonical_existing_dir, pr_is_merged,
# content_in_default, and the WT/STATE/ID/T/BACKEND globals resolved from the
# task meta) are kept as-is - this library is sourced BY teardown, so those
# names remain in scope when teardown runs. worktree_git_lock_path and the
# treehouse-return patience constants additionally carry lib-local defaults so
# the structured operation's provider-return path (teardown_treehouse_return)
# also works when this library runs standalone via --run; teardown re-defines
# them after sourcing, so its legacy flow is untouched.
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
#
# One structured attempt-bound cleanup operation (fm_cleanup_attempt and its
# lock-held internals) sits on top of those units. It accepts an ALREADY
# CLASSIFIED disposition (landed | preserved_unlanded; anything else refuses
# destructive cleanup) and returns durable per-effect receipts on the attempt
# record. Every non-mutating refusal check (owned-copy identity match, live
# processes in the copy, dirty worktree, immature terminal-quiet interval,
# unknown disposition) runs BEFORE any endpoint stop, branch mutation,
# provider return, or receipt write. The operation executes under the attempt
# lock through lock-held primitives that never reacquire; fm_cleanup_attempt is
# the public entry (acquire once, run, release), and fm_cleanup_effects_present
# is the idempotent replay helper. Run directly as `fm-cleanup-lib.sh --run
# <attempt-id> <disposition>` for a one-shot structured cleanup.
set -u

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-attempt-lib.sh
. "$SCRIPT_DIR/fm-attempt-lib.sh"

# The copy must have been quiet - no launch activity - for this many seconds
# before the structured operation may clean it up. Default 2h; 0 disables the
# quiet gate (tests and explicit forced replay).
FM_TERMINAL_QUIET_SECS="${FM_TERMINAL_QUIET_SECS:-7200}"
case "$FM_TERMINAL_QUIET_SECS" in ''|*[!0-9]*) FM_TERMINAL_QUIET_SECS=7200 ;; esac

# Treehouse-return patience defaults for the standalone (--run) context; the
# legacy teardown flow re-defines these after sourcing, so it is untouched.
STALE_WORKTREE_LOCK_AGE_SECS="${STALE_WORKTREE_LOCK_AGE_SECS:-30}"
TREEHOUSE_RETURN_LOCK_RETRIES="${TREEHOUSE_RETURN_LOCK_RETRIES:-3}"
TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS="${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS:-1}"
TEARDOWN_TREEHOUSE_LOCK_REFUSED="${TEARDOWN_TREEHOUSE_LOCK_REFUSED:-2}"

# Absolute path to the git index lock for a worktree/repo dir, or empty when it
# cannot be resolved (dir missing or not a git worktree at all). Identical to
# fm-teardown.sh's definition; the lib-local copy serves the --run context and
# teardown's own later definition shadows it inside teardown.
worktree_git_lock_path() {
  local dir=$1 lock abs_dir
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      [ -d "$dir" ] || return 1
      abs_dir=$(cd "$dir" && pwd -P) || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

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

# --- structured attempt-bound cleanup operation ----------------------------
#
# One operation, executed under the attempt lock through lock-held primitives
# that never reacquire (fm_cleanup_attempt acquires once, runs
# fm_cleanup_attempt_held, and releases). It accepts an already-classified
# disposition - landed | preserved_unlanded; unknown refuses destructive
# cleanup. Every non-mutating refusal check runs before ANY effect:
#   fm_cleanup_preflight (unknown disposition, owned-copy identity match,
#   live processes with cwd under the copy, dirty worktree, immature
#   terminal-quiet interval).
# Then the effects are observed once each, in order: cleanup.endpoint
# (fm_backend_stop_receipt), cleanup.preservation (preserved_unlanded only),
# cleanup.branch (branch disposition, failure recorded never suppressed),
# cleanup.provider (teardown_treehouse_return), cleanup.runtime (the exact
# volatile state-file removals fm-teardown.sh performs). Idempotent replay is
# fm_cleanup_effects_present: an attempt whose full effect set is already
# observed is a no-op success, and the write-once primitives refuse any
# contradictory second observation.

# Task id whose state meta references the attempt, resolved by scanning the
# state dir (the attempt record itself has no back-pointer to its task).
cleanup_task_id_for_attempt() {  # <attempt_id>
  local attempt=$1 meta id state_dir
  state_dir="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(fm_meta_get "$meta" attempt)" = "$attempt" ] || continue
    id=$(basename "$meta" .meta)
    printf '%s\n' "$id"
    return 0
  done
  return 1
}

# PIDs of processes whose CURRENT WORKING DIRECTORY is exactly <copy> or under
# it, from a bounded /proc/<pid>/cwd readlink walk - the lsof-free equivalent
# of fm-teardown.sh's pids_with_cwd_under scan (this machine and CI have no
# lsof, and teardown's own lsof scan stays untouched for the legacy path).
# Never includes $$ (this script's own pid). Empty output when nothing
# matches; a walk failure means the scan could not establish a safe result.
cleanup_copy_live_pids() {  # <copy>
  local copy=$1 proc_root pid_dir pid cwd
  [ -n "$copy" ] && [ -d "$copy" ] || return 0
  copy=$(cd "$copy" && pwd -P) || return 1
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  for pid_dir in "$proc_root"/*/; do
    pid=${pid_dir%/}
    pid=${pid##*/}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "$$" ] && continue
    [ -r "$pid_dir/cwd" ] || continue
    cwd=$(readlink "$pid_dir/cwd" 2>/dev/null) || continue
    case "$cwd" in
      "$copy"|"$copy"/*) printf '%s\n' "$pid" ;;
    esac
  done
}

# Epoch seconds of the attempt's launch receipt (the quiet clock starts at
# launch; a missing or unparseable launch timestamp yields empty so the quiet
# gate fails safe).
cleanup_launch_epoch() {  # <attempt_id>
  local attempt=$1 ts
  ts=$(jq -r --arg n launch \
    '[.receipts[$n][]? | select(.state == "observed")][0].observed_at // ""' \
    "$(attempt_path "$attempt")" 2>/dev/null) || return 0
  case "$ts" in ''|null) return 0 ;; esac
  date -d "$ts" +%s 2>/dev/null || return 0
}

# Every non-mutating refusal check, in one place: unknown disposition, missing
# owned-copy identity, live processes with cwd under the copy, a dirty copy,
# and an immature terminal-quiet interval. Returns 0 only when ALL pass;
# anything else refuses before any effect may be written.
fm_cleanup_preflight() {  # <attempt_id> <disposition>; 0 only when ALL pass
  local attempt=$1 disposition=$2 copy live now launch age
  fm_attempt_generation_held "$attempt" >/dev/null || return 1
  case "$disposition" in
    landed|preserved_unlanded) ;;
    *)
      echo "cleanup: refused: unknown disposition '$disposition' refuses destructive cleanup" >&2
      return 1
      ;;
  esac
  copy=$(fm_attempt_load "$attempt" | jq -r '.provider.copy // ""')
  [ -n "$copy" ] || { echo "cleanup: refused: no owned copy identity for $attempt" >&2; return 1; }
  # Owned-copy identity match: the attempt owns the exact recorded copy, so a
  # tmux attempt whose copy is already gone cannot be cleaned (nothing to
  # verify, nothing to return).
  if [ "$(fm_attempt_load "$attempt" | jq -r '.provider.provider // ""')" = tmux ] \
     && [ ! -d "$copy" ]; then
    echo "cleanup: refused: owned copy $copy missing for $attempt" >&2
    return 1
  fi
  if ! live=$(cleanup_copy_live_pids "$copy" 2>/dev/null); then
    echo "cleanup: refused: cannot determine live processes under $copy" >&2
    return 1
  fi
  if [ -n "$live" ]; then
    echo "cleanup: refused: live process(es) in copy $copy: $(printf '%s' "$live" | tr '\n' ' ')" >&2
    return 1
  fi
  # Dirty copy: the same uncommitted-changes predicate teardown's
  # validate_worktree_teardown_safety enforces; a non-git copy is never dirty.
  if git -C "$copy" status --porcelain 2>/dev/null | grep -q .; then
    echo "cleanup: refused: dirty copy $copy" >&2
    return 1
  fi
  # Immature terminal-quiet interval: the copy must have been quiet - no
  # launch activity - for the full FM_TERMINAL_QUIET_SECS window.
  now=$(date +%s)
  launch=$(cleanup_launch_epoch "$attempt")
  age=0
  if [ -n "$launch" ]; then
    age=$(( now - launch ))
  fi
  if [ "$age" -lt "$FM_TERMINAL_QUIET_SECS" ]; then
    echo "cleanup: refused: quiet interval immature for $attempt (${age}s since launch < FM_TERMINAL_QUIET_SECS=${FM_TERMINAL_QUIET_SECS}s)" >&2
    return 1
  fi
  return 0
}

# 0 when every cleanup effect the disposition requires is already observed
# (idempotent replay: a fully cleaned attempt is a no-op success).
fm_cleanup_effects_present() {  # <attempt_id> <disposition>
  local attempt=$1 disposition=$2 required
  required="cleanup.endpoint cleanup.branch cleanup.provider cleanup.runtime"
  [ "$disposition" = preserved_unlanded ] && required="$required cleanup.preservation"
  jq -e --argjson required "$(printf '%s' "$required" | jq -R 'split(" ")')" \
    '. as $root |
     [ $required[] as $name | select(([$root.receipts[$name][]? | select(.state == "observed")] | length) == 0) ] | length == 0' \
    "$(attempt_path "$attempt")" >/dev/null 2>&1
}

# Branch disposition for the copy, mirroring fm-teardown.sh's branch-deletion
# block (detach and delete the copy's branch so the shared repo does not
# accumulate refs). Failure is RECORDED, never suppressed: FM_BRANCH_DELETE_FAIL=1
# forces {"failed":true} without touching a real ref.
cleanup_branch_fate() {  # <copy> <attempt_id> -> fate JSON
  local copy=$1 attempt=$2 branch
  if [ "${FM_BRANCH_DELETE_FAIL:-0}" = 1 ]; then
    printf '{"attempt":"%s","failed":true}\n' "$attempt"
    return 0
  fi
  branch=$(git -C "$copy" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if [ "$branch" != HEAD ]; then
    if git -C "$copy" checkout --detach -q 2>/dev/null \
       && git -C "$copy" branch -D "$branch" >/dev/null 2>&1; then
      printf '{"attempt":"%s","branch":"%s","deleted":true}\n' "$attempt" "$branch"
      return 0
    fi
    printf '{"attempt":"%s","branch":"%s","deleted":false,"failed":true}\n' "$attempt" "$branch"
    return 0
  fi
  printf '{"attempt":"%s","deleted":false,"reason":"detached-or-unresolvable"}\n' "$attempt"
  return 0
}

# Return the attempt's owned copy to its provider. tmux copies are treehouse
# pool worktrees returned through teardown_treehouse_return (run from the
# recorded project when the referencing meta names one, else the copy's own
# parent so treehouse can resolve the pool by working directory). A missing
# copy is already returned. Other providers are not yet supported by the
# structured operation and refuse with the copy preserved.
cleanup_provider_return() {  # <backend> <copy> <cd_dir>
  local backend=$1 copy=$2 cd_dir=$3
  case "$backend" in
    tmux)
      [ -d "$copy" ] || return 0
      # Remove our hook file so a reused pool worktree cannot fire signals for
      # a dead task (mirrors fm-teardown.sh's pre-return hook cleanup).
      rm -f "$copy/.claude/settings.local.json" "$copy/.opencode/plugins/fm-turn-end.js" \
        "$copy/.fm-grok-turnend" "$copy/.fm-kimi-turnend"
      teardown_treehouse_return "$copy" "$cd_dir" "worktree" || return 1
      ;;
    *)
      echo "cleanup: provider return for backend '$backend' is not supported by the structured operation" >&2
      return 1
      ;;
  esac
  return 0
}

# Retire the task's volatile runtime records - the exact removals
# fm-teardown.sh performs after a successful destructive cleanup: provider
# hook-turnend tokens, the per-task temp root, PR-check artifacts, busy state,
# and the final state-file block. A task with no meta referencing the attempt
# removes nothing (the attempt record itself stays; retirement is a separate
# effect).
cleanup_runtime_records() {  # <task_id>
  local task_id=$1 state_dir meta busy_gen tasktmp
  state_dir="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  [ -n "$task_id" ] || return 0
  meta="$state_dir/$task_id.meta"
  remove_grok_turnend_auth "$state_dir" "$task_id"
  remove_kimi_turnend_auth "$state_dir" "$task_id"
  tasktmp=$(fm_meta_get "$meta" tasktmp)
  busy_gen=$(fm_meta_get "$meta" busy_gen)
  if [ -z "$busy_gen" ]; then
    busy_gen=$(cat "$state_dir/$task_id.busy-gen" 2>/dev/null || true)
  fi
  # Read before the state-file removal below; empty (tasks without tasktmp=) is
  # a no-op.
  if [ -n "$tasktmp" ]; then
    rm -rf -- "$tasktmp"
  fi
  remove_pr_poll_artifacts "$state_dir" "$task_id" || return 1
  retire_busy_state "$state_dir" "$task_id" "$busy_gen" || return 1
  rm -f "$state_dir/$task_id.status" "$state_dir/$task_id.turn-ended" \
    "$state_dir/$task_id.meta" "$state_dir/$task_id.pi-ext.ts" \
    "$state_dir/$task_id.grok-turnend-token" \
    "$state_dir/$task_id.kimi-turnend-token" \
    "$state_dir/$task_id.muse-session" \
    "$state_dir/$task_id.muse-session-current" \
    "$state_dir/.$task_id.open-decisions-cursor"
  return 0
}

# The structured operation itself; the caller holds the attempt lock, so only
# the lock-held primitives are used here and nothing reacquires.
fm_cleanup_attempt_held() {  # <attempt_id> <disposition>; caller holds the attempt lock
  local attempt=$1 disposition=$2 gen copy backend task_id state_dir project cd_dir
  gen=$(fm_attempt_generation_held "$attempt") || return 1
  fm_cleanup_preflight "$attempt" "$disposition" || return 1
  state_dir="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  task_id=$(cleanup_task_id_for_attempt "$attempt" || true)
  if fm_cleanup_effects_present "$attempt" "$disposition"; then
    echo "cleanup: $attempt already complete (disposition $disposition)"
    return 0
  fi
  copy=$(fm_attempt_load "$attempt" | jq -r '.provider.copy // ""')
  backend=$(fm_attempt_load "$attempt" | jq -r '.provider.provider // ""')
  # 1. endpoint stop evidence (bin/fm-backend.sh's durable stop receipt)
  fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.endpoint \
    "$(fm_backend_stop_receipt "$backend" "$task_id")" || return 1
  # 2. preservation ref for preserved_unlanded only
  if [ "$disposition" = preserved_unlanded ]; then
    if [ -n "$copy" ] && [ -d "$copy/.git" ]; then
      git -C "$copy" update-ref "refs/fm-preserve/$attempt" HEAD 2>/dev/null || true
    fi
    fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.preservation \
      "$(jq -n --arg ref "refs/fm-preserve/$attempt" --arg head "$(git -C "$copy" rev-parse HEAD 2>/dev/null || true)" '{ref:$ref, head:$head}')" || return 1
  fi
  # 3. branch fate: record, never suppress
  fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.branch \
    "$(cleanup_branch_fate "$copy" "$attempt")" || return 1
  # 4. provider return
  project=$(fm_meta_get "$state_dir/$task_id.meta" project 2>/dev/null || true)
  if [ -d "$project" ]; then
    cd_dir=$project
  else
    cd_dir=$(dirname "$copy")
  fi
  if ! cleanup_provider_return "$backend" "$copy" "$cd_dir"; then
    echo "cleanup: provider return failed; copy preserved for $attempt" >&2
    return 1
  fi
  fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.provider \
    "$(jq -n --arg p "$backend" --arg c "$copy" '{provider:$p, returned:true, copy:$c}')" || return 1
  # 5. runtime-record retirement (the exact removals fm-teardown.sh performs)
  if ! cleanup_runtime_records "$task_id"; then
    echo "cleanup: runtime-record retirement failed for $attempt; preserving remaining records" >&2
    return 1
  fi
  fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.runtime \
    "$(jq -n --arg tid "$task_id" '{records_removed:true, task_id:$tid}')" || return 1
  echo "cleanup: $attempt disposition=$disposition complete"
}

# Public entry: acquire the attempt lock once, run the held operation, release.
# Acquiring fails (non-reentrant) when another holder already owns the lock.
fm_cleanup_attempt() {  # <attempt_id> <disposition>
  local attempt=$1 disposition=$2 rc
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_cleanup_attempt_held "$attempt" "$disposition"
  rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

# One-shot structured cleanup entry for direct invocation.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "--run" ]; then
  if [ "$#" -lt 3 ]; then
    echo "usage: fm-cleanup-lib.sh --run <attempt-id> <disposition>" >&2
    exit 2
  fi
  fm_cleanup_attempt "$2" "$3"
  exit $?
fi
