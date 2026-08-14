#!/usr/bin/env bash
# Open one native no-mistakes attach surface beside the current Herdr crewmate.
#
# Usage:
#   fm-no-mistakes-attach.sh attach <run-id> <expected-head>
#
# `attach` is the public operation. Run it from the implementation repository,
# after its headless pipeline driver has started one native run and captured that
# exact run id and the checked-out HEAD it attributes. Outside Herdr it prints
# `not-applicable` and exits 0 without mutation.
#
# Under Herdr, `attach` verifies that the supplied HEAD still exactly matches the
# implementation checkout. It verifies the caller's live pane, tab, workspace,
# named session, and socket through the canonical Herdr launcher-identity
# primitive. It holds the shared named-session presentation lock while splitting
# that exact pane to the right at ratio 0.5 without changing focus, verifies that
# the response-derived sibling shares the caller's current tab and workspace,
# and starts the native attach command there. It prints `attached: pane <id>`
# only after `pane run` accepts that command.
#
# The visible sibling executes exactly:
#
#   <no-mistakes-executable> attach --run <run-id>
#
# The headless driver alone starts, polls, retries, aborts, and otherwise drives
# the run. This helper creates no journal, performs no recovery or retirement,
# and never calls AXI. A failed post-split launch leaves the exact new pane
# visible for manual inspection instead of guessing that it is safe to close.
# Lock tests may override the default 50 attempts and 0.1-second interval with
# positive integer FM_NM_ATTACH_LOCK_ATTEMPTS and non-negative number
# FM_NM_ATTACH_LOCK_SLEEP_SECONDS.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=bin/backends/herdr.sh
. "$SCRIPT_DIR/backends/herdr.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fm_nm_attach_error() {
  printf 'ERROR: %s\n' "$*" >&2
  return 2
}

fm_nm_attach_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_nm_attach_checkout_matches() { # <repo> <expected-head>
  local repo=$1 expected_head=$2 current_head
  current_head=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null) || return 1
  [ "$current_head" = "$expected_head" ]
}

fm_nm_attach_locked() { # <session> <repo> <run-id> <expected-head> <no-mistakes-executable>
  local session=$1 repo=$2 run_id=$3 expected_head=$4 nm_bin=$5 pane parent_tab parent_workspace
  local split_output child child_output child_tab child_workspace command

  fm_nm_attach_checkout_matches "$repo" "$expected_head" || {
    fm_nm_attach_error 'implementation commit changed before native attach'
    return 2
  }

  if ! fm_backend_herdr_launcher_identity "$session"; then
    fm_nm_attach_error 'cannot verify current Herdr identity'
    return 2
  fi
  pane=$FM_BACKEND_HERDR_LAUNCHER_PANE_ID
  parent_tab=$FM_BACKEND_HERDR_LAUNCHER_TAB_ID
  parent_workspace=$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID

  split_output=$(fm_backend_herdr_cli "$session" pane split "$pane" \
    --direction right --ratio 0.5 --cwd "$repo" --no-focus 2>/dev/null) || {
    fm_nm_attach_error "Herdr could not split current pane $pane"
    return 2
  }
  child=$(printf '%s' "$split_output" | jq -r \
    '.result.pane.pane_id // .result.root_pane.pane_id // .result.pane_id // empty')
  [ -n "$child" ] && [ "$child" != "$pane" ] || {
    fm_nm_attach_error 'Herdr split returned no distinct sibling pane id'
    return 2
  }
  child_output=$(fm_backend_herdr_cli "$session" pane get "$child" 2>/dev/null) || {
    fm_nm_attach_error "cannot verify response-derived sibling pane $child"
    return 2
  }
  child_tab=$(printf '%s' "$child_output" | jq -r '.result.pane.tab_id // empty')
  child_workspace=$(printf '%s' "$child_output" | jq -r '.result.pane.workspace_id // empty')
  [ "$(printf '%s' "$child_output" | jq -r '.result.pane.pane_id // empty')" = "$child" ] \
    && [ "$child_tab" = "$parent_tab" ] && [ "$child_workspace" = "$parent_workspace" ] || {
      fm_nm_attach_error "pane $child is not a sibling of current pane $pane"
      return 2
    }

  command="exec $(fm_nm_attach_shell_quote "$nm_bin") attach --run $(fm_nm_attach_shell_quote "$run_id")"
  fm_backend_herdr_cli "$session" pane run "$child" "$command" >/dev/null 2>&1 || {
    fm_nm_attach_error "sibling pane $child exists but native attach did not start"
    return 2
  }
  printf 'attached: pane %s run %s at head %s\n' "$child" "$run_id" "$expected_head"
}

fm_nm_attach() {
  local run_id=$1 expected_head=$2 session pane socket repo nm_bin lock_path attempts sleep_seconds attempt=0 rc

  if [ "${HERDR_ENV:-}" != 1 ]; then
    printf 'not-applicable: runtime is not Herdr\n'
    return 0
  fi

  session=${HERDR_SESSION:-}
  pane=${HERDR_PANE_ID:-}
  socket=${HERDR_SOCKET_PATH:-}
  [ -n "$session" ] && [ -n "$pane" ] && [ -n "$socket" ] || {
    fm_nm_attach_error 'Herdr identity is incomplete (need HERDR_SESSION, HERDR_PANE_ID, and HERDR_SOCKET_PATH)'
    return 2
  }
  command -v jq >/dev/null 2>&1 || { fm_nm_attach_error 'jq is required'; return 2; }
  command -v herdr >/dev/null 2>&1 || { fm_nm_attach_error 'herdr is required'; return 2; }
  nm_bin=$(command -v no-mistakes 2>/dev/null) || nm_bin=
  case "$nm_bin" in /*) ;; *) fm_nm_attach_error 'no-mistakes executable is unavailable'; return 2 ;; esac
  [ -x "$nm_bin" ] || { fm_nm_attach_error "no-mistakes executable is not executable: $nm_bin"; return 2; }
  case "$run_id" in ''|*[!A-Za-z0-9._-]*) fm_nm_attach_error 'attach run id is invalid'; return 2 ;; esac
  case "$expected_head" in ''|*[!0-9a-fA-F]*) fm_nm_attach_error 'attach expected head must be a commit SHA'; return 2 ;; esac

  repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
    fm_nm_attach_error 'attach must run inside the implementation repository'
    return 2
  }
  repo=$(cd "$repo" 2>/dev/null && pwd -P) || return 2
  expected_head=$(git -C "$repo" rev-parse --verify "${expected_head}^{commit}" 2>/dev/null) || {
    fm_nm_attach_error 'attach expected head is unavailable in the implementation repository'
    return 2
  }
  fm_nm_attach_checkout_matches "$repo" "$expected_head" || {
    fm_nm_attach_error 'implementation commit does not match attach expected head'
    return 2
  }

  attempts=${FM_NM_ATTACH_LOCK_ATTEMPTS:-50}
  sleep_seconds=${FM_NM_ATTACH_LOCK_SLEEP_SECONDS:-0.1}
  case "$attempts" in ''|*[!0-9]*|0) fm_nm_attach_error 'FM_NM_ATTACH_LOCK_ATTEMPTS must be a positive integer'; return 2 ;; esac
  case "$sleep_seconds" in
    ''|*[!0-9.]*|.*.*|*.*.*|.)
      fm_nm_attach_error 'FM_NM_ATTACH_LOCK_SLEEP_SECONDS must be a non-negative number'
      return 2
      ;;
  esac
  lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session") || {
    fm_nm_attach_error 'cannot resolve the Herdr session presentation lock'
    return 2
  }
  while [ "$attempt" -lt "$attempts" ]; do
    if fm_lock_try_acquire "$lock_path"; then
      fm_nm_attach_locked "$session" "$repo" "$run_id" "$expected_head" "$nm_bin"
      rc=$?
      fm_lock_release "$lock_path"
      return "$rc"
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$attempts" ] && sleep "$sleep_seconds"
  done
  fm_nm_attach_error 'cannot acquire the Herdr session presentation lock'
  return 2
}

case "${1:-}" in
  attach)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    fm_nm_attach "$2" "$3"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
