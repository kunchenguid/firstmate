#!/usr/bin/env bash
# fm-dispatch-breaker-lib.sh - dispatch circuit breaker, reachability checks,
# worker startup verification, and worktree hygiene guards for Firstmate.
#
# CONTRACT.
#   - Durable record: $STATE/<id>.dispatch-breaker.
#     Stores breaker state (closed|open|half-open), attempt counts, last
#     outcome, last reason, preserved worktree path, generation, and bounded
#     attempt history (max 10 entries). Atomic updates via lock + tmp + mv.
#   - States:
#     closed    - normal state; spawns and dispatches proceed.
#     open      - tripped after unrecovered failure or exhausted retries;
#                 dispatches are refused immediately until explicit reset.
#     half-open - explicit recovery state; allows 1 probe dispatch attempt.
#   - Automatic retry:
#     At most 1 automatic retry is permitted for retriable failures (worker-crashed,
#     worker-not-started, transport-cancel, empty-result). If that retry fails,
#     the breaker opens and requires explicit captain-directed recovery.
#   - Worktree hygiene:
#     When a worker exits or fails before starting, its isolated worktree path
#     and unlanded changes are preserved in the dispatch record. Subsequent
#     retries and recoveries reuse the recorded worktree rather than allocating
#     a duplicate or losing prior work.
#   - Pre-spawn reachability:
#     Verifies backend runtime and harness executable reachability before
#     creating session endpoints or worktree slots.
#   - Worker startup proof:
#     Requires concrete proof that the worker is alive and actively processing
#     instructions, not merely that a pane/process was created.
#
# Sourced by bin/fm-spawn.sh and bin/fm-dispatch-breaker.sh.
# set -u / set -e safe.

# shellcheck disable=SC2034 # Exported library version
FM_DISPATCH_BREAKER_LIB_VERSION=v1
FM_DISPATCH_BREAKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
if ! command -v fm_lock_acquire_wait >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$FM_DISPATCH_BREAKER_LIB_DIR/fm-wake-lib.sh"
fi

fm_dispatch_breaker_path() {  # <state-dir> <task-id>
  printf '%s/%s.dispatch-breaker\n' "$1" "$2"
}

fm_dispatch_breaker_lock_path() {  # <state-dir> <task-id>
  printf '%s/.%s.dispatch-breaker.lock\n' "$1" "$2"
}

# fm_dispatch_breaker_read <state-dir> <task-id>
# Sets FM_BREAKER_STATE, FM_BREAKER_ATTEMPTS, FM_BREAKER_LAST_OUTCOME,
# FM_BREAKER_LAST_REASON, FM_BREAKER_WORKTREE, FM_BREAKER_GEN, FM_BREAKER_TS.
fm_dispatch_breaker_read() {
  local state=$1 id=$2 file line k v
  file=$(fm_dispatch_breaker_path "$state" "$id")
  FM_BREAKER_STATE="closed"
  FM_BREAKER_ATTEMPTS=0
  FM_BREAKER_LAST_OUTCOME="none"
  FM_BREAKER_LAST_REASON="none"
  FM_BREAKER_WORKTREE=""
  FM_BREAKER_GEN=""
  FM_BREAKER_TS=""

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '#'* | '' | 'attempt:'*) continue ;;
      *=*)
        k=${line%%=*}
        v=${line#*=}
        case "$k" in
          breaker_state)
            case "$v" in
              closed|open|half-open) FM_BREAKER_STATE=$v ;;
              *) FM_BREAKER_STATE="closed" ;;
            esac
            ;;
          attempts_count)
            case "$v" in
              ''|*[!0-9]*) FM_BREAKER_ATTEMPTS=0 ;;
              *) FM_BREAKER_ATTEMPTS=$v ;;
            esac
            ;;
          last_outcome) FM_BREAKER_LAST_OUTCOME=$v ;;
          last_reason) FM_BREAKER_LAST_REASON=$v ;;
          worktree) FM_BREAKER_WORKTREE=$v ;;
          generation) FM_BREAKER_GEN=$v ;;
          last_attempt_ts) FM_BREAKER_TS=$v ;;
        esac
        ;;
    esac
  done < "$file"
  return 0
}

# fm_dispatch_breaker_check <state-dir> <task-id>
# Returns 0 if dispatch is permitted (closed or half-open).
# Returns 1 and prints an actionable diagnostic if the breaker is open.
fm_dispatch_breaker_check() {
  local state=$1 id=$2
  fm_dispatch_breaker_read "$state" "$id"
  if [ "$FM_BREAKER_STATE" = "open" ]; then
    echo "error: dispatch circuit breaker is open for task '$id' after repeated failures (last reason: ${FM_BREAKER_LAST_REASON:-unknown}; worktree: ${FM_BREAKER_WORKTREE:-none}); explicit captain recovery required (run: bin/fm-dispatch-breaker.sh reset $id)" >&2
    return 1
  fi
  return 0
}

# fm_dispatch_breaker_record_attempt <state-dir> <task-id> <gen> <worktree> <backend> <harness>
fm_dispatch_breaker_record_attempt() {
  local state=$1 id=$2 gen=$3 wt=$4 backend=$5 harness=$6
  local lock file tmp now attempts history=() line count=0
  file=$(fm_dispatch_breaker_path "$state" "$id")
  lock=$(fm_dispatch_breaker_lock_path "$state" "$id")
  now=$(date +%s)

  fm_lock_acquire_wait "$lock" || return 1
  fm_dispatch_breaker_read "$state" "$id"
  attempts=$((FM_BREAKER_ATTEMPTS + 1))

  # Read existing history lines (bounded to 9 prior lines)
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        'attempt:'*)
          history+=("$line")
          ;;
      esac
    done < "$file"
  fi

  tmp=$(mktemp "${file}.tmp.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  {
    printf 'breaker_state=%s\n' "$FM_BREAKER_STATE"
    printf 'attempts_count=%s\n' "$attempts"
    printf 'last_attempt_ts=%s\n' "$now"
    printf 'last_outcome=in-flight\n'
    printf 'last_reason=in-flight\n'
    printf 'worktree=%s\n' "$wt"
    printf 'generation=%s\n' "$gen"
    printf 'backend=%s\n' "$backend"
    printf 'harness=%s\n' "$harness"
    # Keep last 9 history entries
    count=${#history[@]}
    if [ "$count" -gt 9 ]; then
      history=("${history[@]:$((count - 9))}")
    fi
    for line in "${history[@]:-}"; do
      [ -n "$line" ] && printf '%s\n' "$line"
    done
    printf 'attempt: num=%s ts=%s gen=%s outcome=in-flight reason=in-flight worktree=%s backend=%s harness=%s\n' \
      "$attempts" "$now" "$gen" "$wt" "$backend" "$harness"
  } > "$tmp" || { rm -f "$tmp"; fm_lock_release "$lock"; return 1; }

  mv -f "$tmp" "$file"
  fm_lock_release "$lock"
  return 0
}

# fm_dispatch_breaker_record_outcome <state-dir> <task-id> <gen> <outcome> <reason> <worktree> [force-open]
fm_dispatch_breaker_record_outcome() {
  local state=$1 id=$2 gen=$3 outcome=$4 reason=$5 wt=$6 force_open=${7:-0}
  local lock file tmp now new_state history=() line count=0
  file=$(fm_dispatch_breaker_path "$state" "$id")
  lock=$(fm_dispatch_breaker_lock_path "$state" "$id")
  now=$(date +%s)

  fm_lock_acquire_wait "$lock" || return 1
  fm_dispatch_breaker_read "$state" "$id"

  if [ "$outcome" = "success" ]; then
    new_state="closed"
    FM_BREAKER_ATTEMPTS=0
  elif [ "$outcome" = "failure" ]; then
    if [ "$force_open" -eq 1 ] || [ "$FM_BREAKER_ATTEMPTS" -ge 2 ]; then
      new_state="open"
    else
      new_state="$FM_BREAKER_STATE"
    fi
  else
    new_state="$FM_BREAKER_STATE"
  fi

  # Read existing history lines (bounded to 9 prior lines)
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        'attempt:'*)
          history+=("$line")
          ;;
      esac
    done < "$file"
  fi

  tmp=$(mktemp "${file}.tmp.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  {
    printf 'breaker_state=%s\n' "$new_state"
    printf 'attempts_count=%s\n' "$FM_BREAKER_ATTEMPTS"
    printf 'last_attempt_ts=%s\n' "$now"
    printf 'last_outcome=%s\n' "$outcome"
    printf 'last_reason=%s\n' "$reason"
    printf 'worktree=%s\n' "${wt:-$FM_BREAKER_WORKTREE}"
    printf 'generation=%s\n' "$gen"
    count=${#history[@]}
    if [ "$count" -gt 9 ]; then
      history=("${history[@]:$((count - 9))}")
    fi
    for line in "${history[@]:-}"; do
      [ -n "$line" ] && printf '%s\n' "$line"
    done
    printf 'attempt: num=%s ts=%s gen=%s outcome=%s reason=%s worktree=%s\n' \
      "$FM_BREAKER_ATTEMPTS" "$now" "$gen" "$outcome" "$reason" "${wt:-$FM_BREAKER_WORKTREE}"
  } > "$tmp" || { rm -f "$tmp"; fm_lock_release "$lock"; return 1; }

  mv -f "$tmp" "$file"
  fm_lock_release "$lock"
  return 0
}

# fm_dispatch_breaker_reset <state-dir> <task-id> [target-state]
# target-state: half-open (default) or closed
fm_dispatch_breaker_reset() {
  local state=$1 id=$2 target_state=${3:-half-open}
  local lock file tmp now history=() line count=0
  case "$target_state" in
    closed|half-open) ;;
    *) target_state="half-open" ;;
  esac

  file=$(fm_dispatch_breaker_path "$state" "$id")
  lock=$(fm_dispatch_breaker_lock_path "$state" "$id")
  now=$(date +%s)

  fm_lock_acquire_wait "$lock" || return 1
  fm_dispatch_breaker_read "$state" "$id"

  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        'attempt:'*)
          history+=("$line")
          ;;
      esac
    done < "$file"
  fi

  tmp=$(mktemp "${file}.tmp.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  {
    printf 'breaker_state=%s\n' "$target_state"
    printf 'attempts_count=0\n'
    printf 'last_attempt_ts=%s\n' "$now"
    printf 'last_outcome=recovered\n'
    printf 'last_reason=captain-reset\n'
    printf 'worktree=%s\n' "$FM_BREAKER_WORKTREE"
    printf 'generation=%s\n' "$FM_BREAKER_GEN"
    count=${#history[@]}
    if [ "$count" -gt 9 ]; then
      history=("${history[@]:$((count - 9))}")
    fi
    for line in "${history[@]:-}"; do
      [ -n "$line" ] && printf '%s\n' "$line"
    done
    printf 'attempt: num=0 ts=%s gen=%s outcome=recovered reason=captain-reset worktree=%s\n' \
      "$now" "$FM_BREAKER_GEN" "$FM_BREAKER_WORKTREE"
  } > "$tmp" || { rm -f "$tmp"; fm_lock_release "$lock"; return 1; }

  mv -f "$tmp" "$file"
  fm_lock_release "$lock"
  return 0
}

# fm_dispatch_breaker_status <state-dir> <task-id>
# Prints human-readable and script-parseable diagnostic status.
fm_dispatch_breaker_status() {
  local state=$1 id=$2 next_action=""
  fm_dispatch_breaker_read "$state" "$id"

  case "$FM_BREAKER_STATE" in
    open)
      next_action="Circuit breaker is open. Inspect failure reason ('$FM_BREAKER_LAST_REASON') and preserved worktree ('${FM_BREAKER_WORKTREE:-none}'). Run 'bin/fm-dispatch-breaker.sh reset $id' to clear breaker and allow retry."
      ;;
    half-open)
      next_action="Circuit breaker is half-open (recovery mode). Ready for 1 probe dispatch attempt."
      ;;
    closed)
      next_action="Circuit breaker is closed. Ready for dispatch."
      ;;
  esac

  printf 'task: %s\n' "$id"
  printf 'breaker: %s\n' "$FM_BREAKER_STATE"
  printf 'attempts: %s\n' "$FM_BREAKER_ATTEMPTS"
  printf 'last_outcome: %s\n' "$FM_BREAKER_LAST_OUTCOME"
  printf 'last_reason: %s\n' "$FM_BREAKER_LAST_REASON"
  printf 'worktree: %s\n' "${FM_BREAKER_WORKTREE:-none}"
  printf 'last_attempt_ts: %s\n' "${FM_BREAKER_TS:-none}"
  printf 'next_action: %s\n' "$next_action"
}

# fm_backend_check_reachable <backend> [home/session]
# Verifies that the selected worker runtime/backend is reachable and
# spawn-capable before any endpoint or worktree is created.
# Returns 0 on success; returns 1 and prints an actionable diagnostic on failure.
fm_backend_check_reachable() {
  local backend=$1 session_target=${2:-}
  if ! fm_backend_validate_spawn "$backend"; then
    echo "error: runtime backend '$backend' is not in the spawn-capable set ($FM_BACKEND_SPAWN)" >&2
    return 1
  fi

  case "$backend" in
    tmux)
      if ! command -v tmux >/dev/null 2>&1; then
        echo "error: backend 'tmux' is not available; install tmux or specify an available backend" >&2
        return 1
      fi
      if ! tmux -V >/dev/null 2>&1; then
        echo "error: backend 'tmux' failed binary check; verify tmux installation" >&2
        return 1
      fi
      if ! tmux start-server 2>/dev/null; then
        echo "error: backend 'tmux' server cannot start or socket is inaccessible" >&2
        return 1
      fi
      ;;
    herdr)
      fm_backend_source herdr || return 1
      if ! fm_backend_herdr_version_check >/dev/null 2>&1; then
        echo "error: backend 'herdr' version check failed; ensure herdr CLI is installed and meets the version floor" >&2
        return 1
      fi
      local herdr_ses
      herdr_ses=$(fm_backend_herdr_session 2>/dev/null || true)
      if [ -n "$session_target" ]; then
        herdr_ses=$session_target
      fi
      if [ -n "$herdr_ses" ] && ! fm_backend_herdr_server_ensure "$herdr_ses" >/dev/null 2>&1; then
        echo "error: backend 'herdr' daemon is unreachable for session '$herdr_ses'" >&2
        return 1
      fi
      ;;
    zellij)
      fm_backend_source zellij || return 1
      if ! fm_backend_zellij_version_check >/dev/null 2>&1; then
        echo "error: backend 'zellij' version check failed; ensure zellij and jq are installed" >&2
        return 1
      fi
      ;;
    cmux)
      fm_backend_source cmux || return 1
      if ! fm_backend_cmux_version_check >/dev/null 2>&1; then
        echo "error: backend 'cmux' version check failed; ensure cmux CLI is installed" >&2
        return 1
      fi
      if ! fm_backend_cmux_ensure_running >/dev/null 2>&1; then
        echo "error: backend 'cmux' app is not running or control socket is unreachable" >&2
        return 1
      fi
      ;;
    orca)
      fm_backend_source orca || return 1
      if ! fm_backend_orca_runtime_check >/dev/null 2>&1; then
        echo "error: backend 'orca' runtime check failed; ensure orca daemon is operational" >&2
        return 1
      fi
      ;;
    *)
      echo "error: unknown backend '$backend'" >&2
      return 1
      ;;
  esac
  return 0
}

# fm_spawn_verify_worker_started <backend> <target> <task-id> <harness> <state-dir> <worktree> [timeout_secs]
# Confirms proof that the worker actually started processing instructions,
# not merely that a pane was created.
# Returns 0 on confirmed start.
# Returns 1 with FM_SPAWN_START_FAILURE_REASON set on failure.
# shellcheck disable=SC2034 # Consumed by caller
FM_SPAWN_START_FAILURE_REASON=""

fm_spawn_verify_worker_started() {
  local backend=$1 target=$2 id=$3 harness=$4 state=$5 wt=$6
  local timeout=${7:-${FM_SPAWN_START_WAIT:-15}}
  local i=0 max_polls poll_interval=0.5
  local agent_state busy_class busy_st busy_src pane_out turnend_path progress_path

  FM_SPAWN_START_FAILURE_REASON=""
  # Calculate max polls from timeout (e.g. 15s / 0.5s = 30)
  max_polls=$(awk -v t="$timeout" -v p="$poll_interval" 'BEGIN { m = int(t / p); if (m < 2) m = 2; print m }')
  turnend_path="$state/$id.turn-ended"
  progress_path="$state/$id.progress"

  while [ "$i" -lt "$max_polls" ]; do
    # 1. Target presence check
    if ! fm_backend_target_exists "$backend" "$target" 2>/dev/null; then
      FM_SPAWN_START_FAILURE_REASON="endpoint-gone"
      return 1
    fi

    # 2. Agent process check. Only `alive` is start-proof and only `dead` is
    # a conclusive failure. `missing` from the recovery-grade probe is not
    # enough to refuse on its own: many spawn-test tmux stubs answer the cheap
    # existence check but omit window inventory, and a transient inventory
    # miss must not trip the breaker while the pane is still there. Keep
    # polling the other signals until timeout.
    agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unknown')
    case "$agent_state" in
      dead)
        FM_SPAWN_START_FAILURE_REASON="worker-not-started"
        return 1
        ;;
      alive)
        # Agent process is actively running in the pane
        FM_SPAWN_START_FAILURE_REASON=""
        return 0
        ;;
    esac

    # 3. Turn-end or progress notification check
    if [ -f "$turnend_path" ] || [ -f "$progress_path" ]; then
      FM_SPAWN_START_FAILURE_REASON=""
      return 0
    fi

    # 4. Semantic busy state from adapter hooks (source != fm-spawn).
    # fm_busy_classify requires backend/target/harness; a 3-arg call is not
    # a classified worker and must never count as start-proof.
    busy_class=$(fm_busy_classify "$backend" "$target" "$harness" "$id" "$state" 2>/dev/null || printf 'unknown missing')
    busy_st=${busy_class%% *}
    busy_src=${busy_class#* }
    case "$busy_st:$busy_src" in
      busy:pi-ext|busy:omp-ext|busy:opencode-plugin|busy:claude-hook|busy:gemini-hook|busy:herdr-native)
        FM_SPAWN_START_FAILURE_REASON=""
        return 0
        ;;
    esac

    # 5. Harness-specific positive signals
    case "$harness" in
      cursor*)
        local cur_proj
        cur_proj=$(fm_busy_cursor_project_dir "${CURSOR_PROJECTS_ROOT_OVERRIDE:-$HOME/.cursor/projects}" "$wt" 2>/dev/null || true)
        if [ -n "$cur_proj" ] && [ -d "$cur_proj" ]; then
          FM_SPAWN_START_FAILURE_REASON=""
          return 0
        fi
        ;;
      muse*)
        local muse_root muse_logs
        muse_root="${MUSE_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}/muse/sessions"
        muse_logs=$(fm_busy_muse_matching_logs "$muse_root" "$wt" 2>/dev/null || true)
        if [ -n "$muse_logs" ]; then
          FM_SPAWN_START_FAILURE_REASON=""
          return 0
        fi
        ;;
      kimi*)
        if kimi_delivery_is_confirmed "$(kimi_capture 2>/dev/null || true)" 2>/dev/null; then
          FM_SPAWN_START_FAILURE_REASON=""
          return 0
        fi
        ;;
      rovo*)
        if rovo_delivery_is_confirmed "$(rovo_capture 2>/dev/null || true)" 2>/dev/null; then
          FM_SPAWN_START_FAILURE_REASON=""
          return 0
        fi
        ;;
    esac

    # 6. Capture pane output to detect agent activity
    pane_out=$(fm_backend_capture "$backend" "$target" 20 "fm-$id" 2>/dev/null || true)
    if [ -n "$pane_out" ]; then
      if printf '%s\n' "$pane_out" | grep -qiE '(reading brief|thinking|processing|running|executing|\bcontext:\b|\bmodel:\b|welcome to|claude|codex|opencode|pi|omp|gemini|kimi|rovo|muse|cursor)'; then
        FM_SPAWN_START_FAILURE_REASON=""
        return 0
      fi
    fi

    i=$((i + 1))
    [ "$i" -ge "$max_polls" ] || sleep "$poll_interval"
  done

  # Timed out without positive start proof
  pane_out=$(fm_backend_capture "$backend" "$target" 20 "fm-$id" 2>/dev/null || true)
  if [ -z "$pane_out" ] || [ "$pane_out" = "" ]; then
    FM_SPAWN_START_FAILURE_REASON="empty-result"
  else
    FM_SPAWN_START_FAILURE_REASON="worker-not-started"
  fi
  return 1
}
