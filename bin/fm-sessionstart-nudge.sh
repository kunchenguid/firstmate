#!/usr/bin/env bash
# Print the one-line session-start instruction only for a genuine firstmate
# primary whose current harness session has not already acquired the home lock.
# With --profile-refresh, an already-owning session renders a configured
# profile through fm-profile.sh; no-profile continuations stay silent.
# This read-only mode is used by the run wrapper for resume/reload/fork.
# Every silence and error path exits 0 because Claude SessionStart exit 2 blocks
# session initialization.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

lock_is_in_ancestry() {
  local lock_pid pid=$$ _
  [ -f "$STATE/.lock" ] || return 1
  IFS= read -r lock_pid < "$STATE/.lock" 2>/dev/null || return 1
  # A Windows-tagged holder is not in this process table at all, so a local
  # ancestry comparison cannot answer for it. Defer to the owner of harness
  # identity, which is the only thing that can read across that boundary.
  if fm_win_untag_pid "$lock_pid" >/dev/null; then
    fm_session_lock_owned_by_self "$STATE"
    return
  fi
  case "$lock_pid" in
    # PID 1 can own the session inside a PID namespace; compare it below.
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(fm_ps_ppid "$pid")
    # Compare the top of the chain before stopping, as in the owning library.
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    [ "$pid" -ge 1 ] || return 1
  done
  return 1
}

if lock_is_in_ancestry; then
  # A restored conversation may carry an older professional selection.
  # No-profile resumes retain their historical silence and private preferences.
  profile_config="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  if [ "${1:-}" = --profile-refresh ] && { [ -L "$profile_config" ] || [ -e "$profile_config/profile.json" ] || [ -L "$profile_config/profile.json" ]; }; then
    bash "$SCRIPT_DIR/fm-profile.sh" refresh 2>&1 || true
  fi
  exit 0
fi
nudge=
fm_operational_input_encode session-start \
  "Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions." \
  nudge || exit 0
printf '%s\n' "$nudge"
exit 0
