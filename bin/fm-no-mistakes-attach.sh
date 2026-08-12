#!/usr/bin/env bash
# Prepare one native no-mistakes attach dashboard beside the current Herdr
# crewmate, or wait inside that sibling for the exact active run.
#
# Usage:
#   fm-no-mistakes-attach.sh prepare
#   fm-no-mistakes-attach.sh wait <repo-root> <branch> <no-mistakes-executable>
#
# `prepare` is the public operation. Run it from the implementation repository,
# in the Herdr crewmate that will drive no-mistakes, immediately before invoking
# the installed no-mistakes skill. Outside Herdr it prints `not-applicable` and
# exits 0 without mutation.
#
# Under Herdr, `prepare` verifies the caller's live pane, tab, workspace, named
# session, and socket through the canonical Herdr launcher-identity primitive.
# It holds the shared named-session presentation lock while splitting that exact
# pane to the right at ratio 0.5 without changing focus, verifying that the
# response-derived sibling shares the caller's current tab and workspace, and
# starting the internal `wait` operation there. It prints `prepared: pane <id>`
# only after `pane run` accepts the waiter command.
#
# `wait` is internal but documented for auditability. It polls only
# `no-mistakes axi status` from <repo-root>. It ignores terminal or wrong-branch
# runs and, on the first nonterminal exact-branch run, executes exactly:
#
#   <no-mistakes-executable> attach --run <run-id>
#
# The default wait is 900 one-second polls. Tests may override it with the
# positive integer FM_NM_ATTACH_MAX_POLLS and non-negative integer
# FM_NM_ATTACH_POLL_SECONDS environment variables. Lock tests may override the
# default 50 attempts and 0.1-second interval with positive integer
# FM_NM_ATTACH_LOCK_ATTEMPTS and non-negative number
# FM_NM_ATTACH_LOCK_SLEEP_SECONDS. Timeout exits visibly and never starts AXI.
# This helper creates no journal, performs no recovery or
# retirement, sends no dashboard input, and never calls axi run/respond, sync,
# abort, rerun, push, PR, CI, or merge operations. A failed post-split launch
# leaves the exact new pane visible for manual inspection instead of guessing
# that it is safe to close.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"

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

fm_nm_attach_toon_field() { # <TOON> <field>
  printf '%s\n' "$1" | awk -v field="$2" '
    $0 ~ "^[[:space:]]*" field ":[[:space:]]" {
      sub("^[[:space:]]*" field ":[[:space:]]*", "")
      if ($0 ~ /^".*"$/) { sub(/^"/, ""); sub(/"$/, "") }
      print
      exit
    }
  '
}

fm_nm_attach_terminal() { # <status-output>
  local output=$1 status outcome
  status=$(fm_nm_attach_toon_field "$output" status)
  outcome=$(fm_nm_attach_toon_field "$output" outcome)
  case "$status" in completed|failed|cancelled) return 0 ;; esac
  case "$outcome" in checks-passed|passed|failed|cancelled) return 0 ;; esac
  return 1
}

fm_nm_attach_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_nm_attach_prepare_locked() { # <session> <repo> <branch> <no-mistakes-executable>
  local session=$1 repo=$2 branch=$3 nm_bin=$4 pane parent_tab parent_workspace
  local split_output child child_output child_tab child_workspace command

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

  command="exec $(fm_nm_attach_shell_quote "$SCRIPT_PATH") wait $(fm_nm_attach_shell_quote "$repo") $(fm_nm_attach_shell_quote "$branch") $(fm_nm_attach_shell_quote "$nm_bin")"
  fm_backend_herdr_cli "$session" pane run "$child" "$command" >/dev/null 2>&1 || {
    fm_nm_attach_error "sibling pane $child exists but the dashboard waiter did not start"
    return 2
  }
  printf 'prepared: pane %s waiting for no-mistakes on branch %s\n' "$child" "$branch"
}

fm_nm_attach_prepare() {
  local session pane socket repo branch nm_bin lock_path attempts sleep_seconds attempt=0 rc

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

  repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
    fm_nm_attach_error 'prepare must run inside the implementation repository'
    return 2
  }
  repo=$(cd "$repo" 2>/dev/null && pwd -P) || return 2
  branch=$(git -C "$repo" branch --show-current 2>/dev/null) || branch=
  [ -n "$branch" ] || { fm_nm_attach_error 'implementation repository is detached'; return 2; }

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
      fm_nm_attach_prepare_locked "$session" "$repo" "$branch" "$nm_bin"
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

fm_nm_attach_wait() { # <repo-root> <branch> <no-mistakes-executable>
  local repo=$1 branch=$2 nm_bin=$3 max_polls poll_seconds poll=0 output run run_branch current_branch actual_repo
  max_polls=${FM_NM_ATTACH_MAX_POLLS:-900}
  poll_seconds=${FM_NM_ATTACH_POLL_SECONDS:-1}
  case "$max_polls" in ''|*[!0-9]*|0) fm_nm_attach_error 'FM_NM_ATTACH_MAX_POLLS must be a positive integer'; return 2 ;; esac
  case "$poll_seconds" in ''|*[!0-9]*) fm_nm_attach_error 'FM_NM_ATTACH_POLL_SECONDS must be a non-negative integer'; return 2 ;; esac
  case "$repo" in /*) ;; *) fm_nm_attach_error 'wait repo root must be absolute'; return 2 ;; esac
  case "$nm_bin" in /*) ;; *) fm_nm_attach_error 'wait executable must be absolute'; return 2 ;; esac
  [ -d "$repo" ] && [ -x "$nm_bin" ] || { fm_nm_attach_error 'wait repository or executable is unavailable'; return 2; }
  cd "$repo" || return 2
  actual_repo=$(git rev-parse --show-toplevel 2>/dev/null) || actual_repo=
  actual_repo=$(cd "$actual_repo" 2>/dev/null && pwd -P) || actual_repo=
  [ "$actual_repo" = "$repo" ] || {
    fm_nm_attach_error 'wait repository identity changed'
    return 2
  }

  while [ "$poll" -lt "$max_polls" ]; do
    current_branch=$(git branch --show-current 2>/dev/null) || current_branch=
    [ "$current_branch" = "$branch" ] || {
      fm_nm_attach_error "branch changed while waiting (expected $branch, found ${current_branch:-detached})"
      return 2
    }
    output=$("$nm_bin" axi status 2>/dev/null) || true
    run=$(fm_nm_attach_toon_field "$output" id)
    run_branch=$(fm_nm_attach_toon_field "$output" branch)
    if [ -n "$run" ] && [ "$run_branch" = "$branch" ] && ! fm_nm_attach_terminal "$output"; then
      case "$run" in *[!A-Za-z0-9._-]*) fm_nm_attach_error 'AXI returned an invalid run id'; return 2 ;; esac
      exec "$nm_bin" attach --run "$run"
    fi
    poll=$((poll + 1))
    [ "$poll" -lt "$max_polls" ] && sleep "$poll_seconds"
  done
  printf 'ERROR: no active no-mistakes run appeared for branch %s after %s polls\n' "$branch" "$max_polls" >&2
  return 1
}

case "${1:-}" in
  prepare)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    fm_nm_attach_prepare
    ;;
  wait)
    [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    fm_nm_attach_wait "$2" "$3" "$4"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
