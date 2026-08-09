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
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

# The copy must have been quiet - no launch activity - for this many seconds
# before the structured operation may clean it up. Default 2h; 0 disables the
# quiet gate (tests and explicit forced replay). Operator-requested cleanup
# through fm-teardown.sh sets FM_CLEANUP_OPERATOR=1, which bypasses the
# interval; automatic terminal reconciliation always retains it.
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

if ! declare -F canonical_existing_dir >/dev/null 2>&1; then
  canonical_existing_dir() {
    [ -n "$1" ] && [ -d "$1" ] || return 1
    (cd "$1" && pwd -P)
  }
fi

# --- provider hook-token retirement ----------------------------------------
# Where a harness's firstmate-owned global turn-end registry entry lives is
# owned by bin/fm-control-lib.sh, so cleanup and the control plane's relaunch
# retire the same artifact rather than each carrying its own copy of the path.
remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token_path token='' path
  token_path=$(fm_control_harness_turnend_token_path grok "$state_dir" "$id") || return 1
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  path=$(fm_control_harness_turnend_auth_path grok "$token") || return 1
  [ -n "$path" ] || return 0
  rm -f -- "$path"
}

remove_kimi_turnend_auth() {
  local state_dir=$1 id=$2 token_path token='' path
  token_path=$(fm_control_harness_turnend_token_path kimi "$state_dir" "$id") || return 1
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  path=$(fm_control_harness_turnend_auth_path kimi "$token") || return 1
  [ -n "$path" ] || return 0
  rm -f -- "$path"
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
    "$STATE/.$ID.open-decisions-cursor" \
    "$STATE/$ID.control-relaunch" "$STATE/$ID.control-relaunch.meta-prior" \
    "$STATE/$ID.control-relaunch.brief-prior" "$STATE/$ID.control-relaunch.note"
}

# --- structured attempt-bound cleanup operation ----------------------------
#
# One operation, executed under the attempt lock through lock-held primitives
# that never reacquire (fm_cleanup_attempt acquires once, runs
# fm_cleanup_attempt_held, and releases). It accepts an already-classified
# disposition - landed | preserved_unlanded; unknown refuses destructive
# cleanup. Idempotent replay (fm_cleanup_effects_present) runs FIRST: an
# attempt whose full effect set is already observed is a no-op success, so a
# duplicate completion, startup recovery, or cleanup retry converges on the
# same receipts even after the provider return removed the owned copy. Only
# then do the non-mutating refusal checks run, before ANY effect:
#   fm_cleanup_preflight (unknown disposition, owned-copy identity match,
#   live processes with cwd under the copy, dirty worktree, immature
#   terminal-quiet interval).
# Then the effects are observed once each, in order: cleanup.endpoint,
# cleanup.preservation (preserved_unlanded only), cleanup.branch,
# cleanup.provider, and cleanup.runtime (the exact
# volatile state-file removals fm-teardown.sh performs). The write-once
# primitives refuse any contradictory second observation.

# Task id whose state meta references the attempt, resolved by scanning the
# state dir (the attempt record itself has no back-pointer to its task).
cleanup_task_id_for_attempt() {  # <attempt_id>
  local attempt=$1 meta id state_dir found=
  state_dir="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(fm_backend_meta_exact_value "$meta" attempt 2>/dev/null || true)" = "$attempt" ] || continue
    id=$(basename "$meta" .meta)
    [ -z "$found" ] || {
      echo "cleanup: refused: multiple task endpoints claim attempt $attempt" >&2
      return 1
    }
    found=$id
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

cleanup_observed_evidence() {  # <attempt_id> <effect>
  jq -c --arg name "$2" '[.receipts[$name][]? | select(.state == "observed")][0].evidence // empty' \
    "$(attempt_path "$1")" 2>/dev/null
}

cleanup_effect_observed() {  # <attempt_id> <effect>
  [ -n "$(cleanup_observed_evidence "$1" "$2")" ]
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

cleanup_orca_missing() {  # <terminal|worktree> <id>
  local kind=$1 id=$2 out
  fm_backend_source orca || return 2
  case "$kind" in
    terminal) out=$(orca terminal read --terminal "$id" --limit 1 --json 2>&1);;
    worktree) out=$(orca worktree show --worktree "id:$id" --json 2>&1);;
    *) return 2 ;;
  esac
  if printf '%s' "$out" | jq -e '.ok != false' >/dev/null 2>&1; then
    return 1
  fi
  if printf '%s' "$out" | jq -e '
    (.error.code // "" | ascii_downcase) as $c
    | ($c == "not_found" or $c == "terminal_not_found" or $c == "worktree_not_found")
  ' >/dev/null 2>&1; then
    return 0
  fi
  return 2
}

cleanup_endpoint_absence_state() {  # <backend> <target> <task_id>
  local backend=$1 target=$2 state out session pane workspace surface
  case "$backend" in
    tmux|herdr)
      state=$(fm_backend_agent_state "$backend" "$target")
      [ "$state" = missing ] && { printf 'missing'; return 0; }
      case "$state" in alive|dead|ambiguous) printf 'present' ;; *) printf 'unknown' ;; esac
      ;;
    zellij)
      fm_backend_source zellij || { printf 'unknown'; return 0; }
      fm_backend_zellij_parse_target "$target" || { printf 'unknown'; return 0; }
      session=$FM_BACKEND_ZELLIJ_SESSION
      pane=$FM_BACKEND_ZELLIJ_PANE
      out=$(zellij list-sessions --short --no-formatting 2>&1) || { printf 'unknown'; return 0; }
      if ! printf '%s\n' "$out" | grep -qxF "$session"; then printf 'missing'; return 0; fi
      out=$(fm_backend_zellij_cli "$session" action list-panes --json 2>&1) || { printf 'unknown'; return 0; }
      if printf '%s' "$out" | jq -e --argjson p "$pane" 'type == "array" and any(.[]?; .id == $p and .is_plugin == false)' >/dev/null 2>&1; then
        printf 'present'
      elif printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
        printf 'missing'
      else
        printf 'unknown'
      fi
      ;;
    cmux)
      fm_backend_source cmux || { printf 'unknown'; return 0; }
      [ "$(fm_backend_cmux_ping_state)" = ok ] || { printf 'unknown'; return 0; }
      fm_backend_cmux_parse_target "$target" || { printf 'unknown'; return 0; }
      workspace=$FM_BACKEND_CMUX_WORKSPACE
      surface=$FM_BACKEND_CMUX_SURFACE
      out=$(fm_backend_cmux_cli workspace list --json --id-format uuids 2>&1) || { printf 'unknown'; return 0; }
      if ! printf '%s' "$out" | jq -e --arg w "$workspace" '(.workspaces | type) == "array" and any(.workspaces[]?; .id == $w)' >/dev/null 2>&1; then
        printf '%s' "$out" | jq -e '(.workspaces | type) == "array"' >/dev/null 2>&1 && printf 'missing' || printf 'unknown'
        return 0
      fi
      out=$(fm_backend_cmux_cli list-panes --workspace "$workspace" --json --id-format uuids 2>&1) || { printf 'unknown'; return 0; }
      if printf '%s' "$out" | jq -e --arg s "$surface" '(.panes | type) == "array" and any(.panes[]?; (.surface_ids // []) | index($s))' >/dev/null 2>&1; then
        printf 'present'
      elif printf '%s' "$out" | jq -e '(.panes | type) == "array"' >/dev/null 2>&1; then
        printf 'missing'
      else
        printf 'unknown'
      fi
      ;;
    orca)
      if cleanup_orca_missing terminal "$target"; then printf 'missing'; else
        case $? in 1) printf 'present' ;; *) printf 'unknown' ;; esac
      fi
      ;;
    *) printf 'unknown' ;;
  esac
}

cleanup_provider_absence_state() {  # <backend> <copy> <orca-worktree-id>
  case "$1" in
    tmux|herdr|zellij|cmux)
      if [ ! -e "$2" ]; then printf 'missing'; else printf 'present'; fi
      ;;
    orca)
      if cleanup_orca_missing worktree "$3"; then printf 'missing'; else
        case $? in 1) printf 'present' ;; *) printf 'unknown' ;; esac
      fi
      ;;
    *) printf 'unknown' ;;
  esac
}

cleanup_runtime_absent() {  # <state-dir> <task_id> [tasktmp]
  local state_dir=$1 task_id=$2 tasktmp=${3:-} f
  for f in "$state_dir/$task_id.status" "$state_dir/$task_id.turn-ended" "$state_dir/$task_id.meta" \
    "$state_dir/$task_id.pi-ext.ts" "$state_dir/$task_id.grok-turnend-token" \
    "$state_dir/$task_id.kimi-turnend-token" "$state_dir/$task_id.muse-session" \
    "$state_dir/$task_id.muse-session-current" "$state_dir/.$task_id.open-decisions-cursor" \
    "$state_dir/$task_id.check.sh" "$state_dir/$task_id.pr-poll" \
    "$state_dir/$task_id.pr-poll-registration" "$state_dir/$task_id.pr-poll-retirement" \
    "$state_dir/$task_id.check-trust" "$state_dir/$task_id.busy" "$state_dir/$task_id.busy-gen"; do
    [ ! -e "$f" ] && [ ! -L "$f" ] || return 1
  done
  [ -z "$tasktmp" ] || [ ! -e "$tasktmp" ]
}

# Every non-mutating refusal check, in one place.
fm_cleanup_preflight() {  # <attempt_id> <disposition>; 0 only when ALL pass
  local attempt=$1 disposition=$2 record meta endpoint_evidence live now launch age status
  local recorded_backend recorded_copy recorded_attempt
  fm_attempt_generation_held "$attempt" >/dev/null || return 1
  case "$disposition" in
    landed|preserved_unlanded) ;;
    *) echo "cleanup: refused: unknown disposition '$disposition' refuses destructive cleanup" >&2; return 1 ;;
  esac
  record=$(fm_attempt_load "$attempt") || return 1
  FM_CLEANUP_BACKEND=$(printf '%s' "$record" | jq -r '.provider.provider // ""')
  FM_CLEANUP_COPY=$(printf '%s' "$record" | jq -r '.provider.copy // ""')
  case "$FM_CLEANUP_BACKEND" in tmux|herdr|zellij|cmux|orca) ;; *)
    echo "cleanup: refused: unsupported provider '$FM_CLEANUP_BACKEND'" >&2; return 1 ;; esac
  [ -n "$FM_CLEANUP_COPY" ] || { echo "cleanup: refused: no owned copy identity for $attempt" >&2; return 1; }
  FM_CLEANUP_STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  FM_CLEANUP_TASK_ID=$(cleanup_task_id_for_attempt "$attempt" || true)
  FM_CLEANUP_TARGET=
  FM_CLEANUP_ORCA_WORKTREE_ID=
  FM_CLEANUP_TASKTMP=
  if [ -n "$FM_CLEANUP_TASK_ID" ]; then
    meta="$FM_CLEANUP_STATE_DIR/$FM_CLEANUP_TASK_ID.meta"
    fm_backend_validate_task_endpoint "$meta" "$FM_CLEANUP_TASK_ID" || return 1
    recorded_backend=$FM_BACKEND_VALIDATED_BACKEND
    FM_CLEANUP_TARGET=$FM_BACKEND_VALIDATED_TARGET
    recorded_copy=$(fm_backend_meta_exact_value "$meta" worktree 2>/dev/null || true)
    recorded_attempt=$(fm_backend_meta_exact_value "$meta" attempt 2>/dev/null || true)
    [ "$recorded_backend" = "$FM_CLEANUP_BACKEND" ] \
      && [ "$recorded_copy" = "$FM_CLEANUP_COPY" ] \
      && [ "$recorded_attempt" = "$attempt" ] || {
        echo "cleanup: refused: provider, copy, task, or attempt endpoint identity mismatch" >&2
        return 1
      }
    FM_CLEANUP_TASKTMP=$(fm_meta_get "$meta" tasktmp)
    if [ "$FM_CLEANUP_BACKEND" = orca ]; then
      FM_CLEANUP_ORCA_WORKTREE_ID=$(fm_backend_meta_exact_value "$meta" orca_worktree_id 2>/dev/null || true)
      [ -n "$FM_CLEANUP_ORCA_WORKTREE_ID" ] || { echo "cleanup: refused: missing exact Orca worktree identity" >&2; return 1; }
      if [ -e "$FM_CLEANUP_COPY" ]; then
        require_orca_worktree_path_match "$FM_CLEANUP_ORCA_WORKTREE_ID" "$FM_CLEANUP_COPY" || return 1
      fi
    fi
  else
    endpoint_evidence=$(cleanup_observed_evidence "$attempt" cleanup.endpoint)
    printf '%s' "$endpoint_evidence" | jq -e --arg b "$FM_CLEANUP_BACKEND" --arg c "$FM_CLEANUP_COPY" '
      .backend == $b and .copy == $c and .confirmed_gone == true
      and (.endpoint | type == "string" and length > 0)
      and (.task_id | type == "string" and length > 0)
    ' >/dev/null 2>&1 || {
      echo "cleanup: refused: task endpoint identity unavailable before cleanup completion" >&2
      return 1
    }
    FM_CLEANUP_TASK_ID=$(printf '%s' "$endpoint_evidence" | jq -r '.task_id')
    FM_CLEANUP_TARGET=$(printf '%s' "$endpoint_evidence" | jq -r '.endpoint')
    FM_CLEANUP_ORCA_WORKTREE_ID=$(printf '%s' "$endpoint_evidence" | jq -r '.orca_worktree_id // ""')
    FM_CLEANUP_TASKTMP=$(printf '%s' "$endpoint_evidence" | jq -r '.tasktmp // ""')
  fi
  endpoint_evidence=$(cleanup_observed_evidence "$attempt" cleanup.endpoint)
  if [ -n "$endpoint_evidence" ]; then
    printf '%s' "$endpoint_evidence" | jq -e --arg b "$FM_CLEANUP_BACKEND" --arg c "$FM_CLEANUP_COPY" \
      --arg t "$FM_CLEANUP_TARGET" --arg id "$FM_CLEANUP_TASK_ID" \
      '.backend == $b and .copy == $c and .endpoint == $t and .task_id == $id and .confirmed_gone == true' \
      >/dev/null 2>&1 || { echo "cleanup: refused: differing endpoint receipt" >&2; return 1; }
  fi
  if [ -e "$FM_CLEANUP_COPY" ]; then
    git -C "$FM_CLEANUP_COPY" rev-parse --is-inside-work-tree 2>/dev/null | grep -qx true || {
      echo "cleanup: refused: owned copy is not the recorded git worktree" >&2; return 1; }
    live=$(cleanup_copy_live_pids "$FM_CLEANUP_COPY" 2>/dev/null) || {
      echo "cleanup: refused: cannot determine live processes under $FM_CLEANUP_COPY" >&2; return 1; }
    [ -z "$live" ] || { echo "cleanup: refused: live process(es) in copy $FM_CLEANUP_COPY: $(printf '%s' "$live" | tr '\n' ' ')" >&2; return 1; }
    status=$(git -C "$FM_CLEANUP_COPY" status --porcelain 2>/dev/null) || {
      echo "cleanup: refused: cannot read copy status" >&2; return 1; }
    [ -z "$status" ] || { echo "cleanup: refused: dirty copy $FM_CLEANUP_COPY" >&2; return 1; }
    now=$(date +%s)
    launch=$(cleanup_launch_epoch "$attempt")
    age=0
    [ -z "$launch" ] || age=$(( now - launch ))
    if [ "${FM_CLEANUP_OPERATOR:-0}" != 1 ]; then
      [ "$age" -ge "$FM_TERMINAL_QUIET_SECS" ] || {
        echo "cleanup: refused: quiet interval immature for $attempt (${age}s since launch < FM_TERMINAL_QUIET_SECS=${FM_TERMINAL_QUIET_SECS}s)" >&2
        return 1
      }
    fi
  else
    [ "$(cleanup_provider_absence_state "$FM_CLEANUP_BACKEND" "$FM_CLEANUP_COPY" "$FM_CLEANUP_ORCA_WORKTREE_ID")" = missing ] || {
      echo "cleanup: refused: provider copy absence is not authoritative" >&2; return 1; }
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

# Return the attempt's owned copy through Treehouse for session-only backends
# or through Orca's recorded worktree id for the Orca-owned provider.
cleanup_provider_return() {  # <backend> <copy> <cd_dir> [orca-worktree-id]
  local backend=$1 copy=$2 cd_dir=$3 orca_worktree_id=${4:-}
  case "$backend" in
    tmux|herdr|zellij|cmux)
      [ -e "$copy" ] || return 0
      rm -f "$copy/.claude/settings.local.json" "$copy/.opencode/plugins/fm-turn-end.js" \
        "$copy/.opencode/plugins/fm-busy-state.js" "$copy/.fm-grok-turnend" "$copy/.fm-kimi-turnend"
      teardown_treehouse_return "$copy" "$cd_dir" "worktree" || return 1
      ;;
    orca)
      [ -n "$orca_worktree_id" ] || return 1
      if [ -e "$copy" ]; then
        require_orca_worktree_path_match "$orca_worktree_id" "$copy" || return 1
      fi
      fm_backend_remove_worktree orca "$orca_worktree_id" || return 1
      ;;
    *) return 1 ;;
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
  local attempt=$1 disposition=$2 gen project cd_dir endpoint_state endpoint_evidence
  local preservation_evidence branch_evidence provider_evidence runtime_evidence ref head ref_head tab_id
  gen=$(fm_attempt_generation_held "$attempt") || return 1
  if fm_cleanup_effects_present "$attempt" "$disposition"; then
    echo "cleanup: $attempt already complete (disposition $disposition)"
    return 0
  fi
  fm_cleanup_preflight "$attempt" "$disposition" || return 1

  if cleanup_effect_observed "$attempt" cleanup.endpoint; then
    endpoint_state=$(cleanup_endpoint_absence_state "$FM_CLEANUP_BACKEND" "$FM_CLEANUP_TARGET" "$FM_CLEANUP_TASK_ID")
    [ "$endpoint_state" = missing ] || {
      echo "cleanup: endpoint receipt exists but exact endpoint absence is $endpoint_state" >&2
      return 1
    }
  else
    endpoint_state=$(cleanup_endpoint_absence_state "$FM_CLEANUP_BACKEND" "$FM_CLEANUP_TARGET" "$FM_CLEANUP_TASK_ID")
    case "$endpoint_state" in
      missing) ;;
      present)
        tab_id=$(fm_meta_get "$FM_CLEANUP_STATE_DIR/$FM_CLEANUP_TASK_ID.meta" zellij_tab_id)
        fm_backend_kill "$FM_CLEANUP_BACKEND" "$FM_CLEANUP_TARGET" "$tab_id" "fm-$FM_CLEANUP_TASK_ID" || {
          echo "cleanup: exact endpoint stop failed" >&2
          return 1
        }
        endpoint_state=$(cleanup_endpoint_absence_state "$FM_CLEANUP_BACKEND" "$FM_CLEANUP_TARGET" "$FM_CLEANUP_TASK_ID")
        [ "$endpoint_state" = missing ] || {
          echo "cleanup: exact endpoint absence is $endpoint_state after stop; refusing endpoint receipt" >&2
          return 1
        }
        ;;
      *)
        echo "cleanup: exact endpoint absence is $endpoint_state before stop; refusing endpoint action" >&2
        return 1
        ;;
    esac
    [ "${FM_CLEANUP_CRASH_AFTER_ENDPOINT_STOP:-0}" != 1 ] || return 42
    endpoint_evidence=$(jq -nc --arg backend "$FM_CLEANUP_BACKEND" --arg endpoint "$FM_CLEANUP_TARGET" \
      --arg task_id "$FM_CLEANUP_TASK_ID" --arg copy "$FM_CLEANUP_COPY" \
      --arg orca_worktree_id "$FM_CLEANUP_ORCA_WORKTREE_ID" --arg tasktmp "$FM_CLEANUP_TASKTMP" \
      '{backend:$backend,endpoint:$endpoint,task_id:$task_id,copy:$copy,confirmed_gone:true}
       + (if $orca_worktree_id == "" then {} else {orca_worktree_id:$orca_worktree_id} end)
       + (if $tasktmp == "" then {} else {tasktmp:$tasktmp} end)')
    fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.endpoint "$endpoint_evidence" || return 1
  fi
  [ "${FM_CLEANUP_CRASH_AFTER_RECEIPT:-}" != endpoint ] || return 42

  if [ "$disposition" = preserved_unlanded ]; then
    ref="refs/fm-preserve/$attempt"
    preservation_evidence=$(cleanup_observed_evidence "$attempt" cleanup.preservation)
    if [ -n "$preservation_evidence" ]; then
      printf '%s' "$preservation_evidence" | jq -e --arg ref "$ref" \
        '.ref == $ref and (.head | type == "string" and length > 0) and .verified == true' >/dev/null 2>&1 || {
          echo "cleanup: differing preservation receipt" >&2; return 1; }
      if [ -e "$FM_CLEANUP_COPY" ]; then
        head=$(printf '%s' "$preservation_evidence" | jq -r '.head')
        ref_head=$(git -C "$FM_CLEANUP_COPY" rev-parse "$ref" 2>/dev/null) || return 1
        [ "$ref_head" = "$head" ] || { echo "cleanup: preservation ref no longer matches its receipt" >&2; return 1; }
      fi
    else
      [ -e "$FM_CLEANUP_COPY" ] || { echo "cleanup: preservation copy is absent" >&2; return 1; }
      head=$(git -C "$FM_CLEANUP_COPY" rev-parse HEAD 2>/dev/null) || return 1
      git -C "$FM_CLEANUP_COPY" update-ref "$ref" "$head" || {
        echo "cleanup: preservation ref update failed" >&2
        return 1
      }
      ref_head=$(git -C "$FM_CLEANUP_COPY" rev-parse "$ref" 2>/dev/null) || return 1
      [ "$ref_head" = "$head" ] || { echo "cleanup: preservation ref verification failed" >&2; return 1; }
      preservation_evidence=$(jq -nc --arg ref "$ref" --arg head "$head" '{ref:$ref,head:$head,verified:true}')
      fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.preservation "$preservation_evidence" || return 1
    fi
  fi
  [ "${FM_CLEANUP_CRASH_AFTER_RECEIPT:-}" != preservation ] || return 42

  branch_evidence=$(cleanup_observed_evidence "$attempt" cleanup.branch)
  if [ -n "$branch_evidence" ]; then
    if printf '%s' "$branch_evidence" | jq -e '.failed == true' >/dev/null 2>&1; then
      echo "cleanup: observed branch receipt records failure; provider and runtime effects remain pending" >&2
      return 1
    fi
  else
    branch_evidence=$(cleanup_branch_fate "$FM_CLEANUP_COPY" "$attempt") || return 1
    if printf '%s' "$branch_evidence" | jq -e '.failed == true' >/dev/null 2>&1; then
      fm_attempt_effect_pending_held "$attempt" "$gen" cleanup.branch "$branch_evidence" || return 1
      echo "cleanup: branch disposition failed; provider and runtime effects remain pending" >&2
      return 1
    fi
    fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.branch "$branch_evidence" || return 1
  fi
  [ "${FM_CLEANUP_CRASH_AFTER_RECEIPT:-}" != branch ] || return 42

  provider_evidence=$(cleanup_observed_evidence "$attempt" cleanup.provider)
  if [ -n "$provider_evidence" ]; then
    printf '%s' "$provider_evidence" | jq -e --arg p "$FM_CLEANUP_BACKEND" --arg c "$FM_CLEANUP_COPY" \
      '.provider == $p and .copy == $c and .returned == true' >/dev/null 2>&1 || {
        echo "cleanup: differing provider receipt" >&2; return 1; }
    [ "$(cleanup_provider_absence_state "$FM_CLEANUP_BACKEND" "$FM_CLEANUP_COPY" "$FM_CLEANUP_ORCA_WORKTREE_ID")" = missing ] || {
      echo "cleanup: provider receipt exists but exact provider resource is not confirmed absent" >&2
      return 1
    }
  else
    project=$(fm_meta_get "$FM_CLEANUP_STATE_DIR/$FM_CLEANUP_TASK_ID.meta" project 2>/dev/null || true)
    if [ -d "$project" ]; then cd_dir=$project; else cd_dir=$(dirname "$FM_CLEANUP_COPY"); fi
    if [ "$(cleanup_provider_absence_state "$FM_CLEANUP_BACKEND" "$FM_CLEANUP_COPY" "$FM_CLEANUP_ORCA_WORKTREE_ID")" != missing ]; then
      cleanup_provider_return "$FM_CLEANUP_BACKEND" "$FM_CLEANUP_COPY" "$cd_dir" "$FM_CLEANUP_ORCA_WORKTREE_ID" || {
        echo "cleanup: provider return failed; copy preserved for $attempt" >&2
        return 1
      }
    fi
    [ "${FM_CLEANUP_CRASH_AFTER_PROVIDER_RETURN:-0}" != 1 ] || return 42
    [ "$(cleanup_provider_absence_state "$FM_CLEANUP_BACKEND" "$FM_CLEANUP_COPY" "$FM_CLEANUP_ORCA_WORKTREE_ID")" = missing ] || {
      echo "cleanup: provider return absence is not authoritative" >&2
      return 1
    }
    provider_evidence=$(jq -nc --arg p "$FM_CLEANUP_BACKEND" --arg c "$FM_CLEANUP_COPY" \
      --arg worktree_id "$FM_CLEANUP_ORCA_WORKTREE_ID" \
      '{provider:$p,returned:true,copy:$c} + (if $worktree_id == "" then {} else {worktree_id:$worktree_id} end)')
    fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.provider "$provider_evidence" || return 1
  fi
  [ "${FM_CLEANUP_CRASH_AFTER_RECEIPT:-}" != provider ] || return 42

  if ! cleanup_effect_observed "$attempt" cleanup.runtime; then
    if ! cleanup_runtime_absent "$FM_CLEANUP_STATE_DIR" "$FM_CLEANUP_TASK_ID" "$FM_CLEANUP_TASKTMP"; then
      cleanup_runtime_records "$FM_CLEANUP_TASK_ID" || {
        echo "cleanup: runtime-record retirement failed for $attempt; preserving remaining records" >&2
        return 1
      }
    fi
    [ "${FM_CLEANUP_CRASH_AFTER_RUNTIME_REMOVE:-0}" != 1 ] || return 42
    cleanup_runtime_absent "$FM_CLEANUP_STATE_DIR" "$FM_CLEANUP_TASK_ID" "$FM_CLEANUP_TASKTMP" || {
      echo "cleanup: runtime-record absence is not confirmed" >&2
      return 1
    }
    runtime_evidence=$(jq -nc --arg tid "$FM_CLEANUP_TASK_ID" '{records_removed:true,task_id:$tid,confirmed_absent:true}')
    fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.runtime "$runtime_evidence" || return 1
  fi
  [ "${FM_CLEANUP_CRASH_AFTER_RECEIPT:-}" != runtime ] || return 42
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
