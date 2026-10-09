#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-orca-submit-restart)

for mode in draft busy unreadable failure success; do
  mkdir -p "$TMP_ROOT/$mode"
  out=$(bash -c '
    . "$1/bin/backends/orca.sh"
    . "$1/bin/fm-task-inbox-lib.sh"
    mode=$2
    evidence=$3
    fm_backend_orca_tool_check() { return 0; }
    fm_backend_orca_send_literal() {
      FM_ORCA_RESOLVED_TERMINAL=
      printf "%s" "$2" > "$evidence/typed"
    }
    fm_backend_orca_send_key_once() {
      printf "%s\n" "$1" >> "$evidence/enters"
      if [ "$1" = old ]; then
        FM_ORCA_LAST_STDERR=terminal_handle_stale
        FM_ORCA_LAST_STDOUT=
        FM_ORCA_LAST_RC=1
        return 1
      fi
      if [ "$mode" = failure ]; then
        FM_ORCA_LAST_RC=1
        return 1
      fi
    }
    fm_backend_orca_resolve_live_terminal() { printf live; }
    fm_backend_orca_composer_capture() {
      printf "%s\n" "$1" >> "$evidence/reads"
      [ "$1" = live ] || return 1
      [ "$mode" != unreadable ] || return 1
      if [ "$mode" = draft ]; then
        printf "❯ protected draft\n"
      else
        printf "❯\n"
      fi
    }
    fm_backend_agent_state() { printf idle; }
    fm_backend_busy_state() {
      if [ "$mode" = busy ]; then printf busy; else printf idle; fi
    }
    fm_busy_lines_match() { return 1; }
    fm_backend_composer_state() { printf empty; }
    fm_task_inbox_doorbell_line() { printf doorbell; }
    fm_task_inbox_composer_holds() { return 1; }
    fm_backend_send_text_submit() {
      shift
      fm_backend_orca_send_text_submit "$@"
    }
    rc=0
    fm_task_inbox_ring orca old record || rc=$?
    printf "%s" "$rc"
  ' bash "$ROOT" "$mode" "$TMP_ROOT/$mode")
  case "$mode" in
    draft|busy|unreadable) expected=1 ;;
    failure) expected=2 ;;
    success) expected=0 ;;
  esac
  [ "$out" = "$expected" ] || fail "$mode: expected ring status $expected, got $out"
  [ "$(cat "$TMP_ROOT/$mode/typed")" = doorbell ] || fail "$mode: text was not accepted once"
  if [ "$mode" = success ]; then
    [ "$(cat "$TMP_ROOT/$mode/enters")" = $'old\nlive' ] || fail "replacement Enter was not sent"
    [ "$(cat "$TMP_ROOT/$mode/reads")" = $'live\nlive' ] || fail "verification did not read the replacement"
  elif [ "$mode" != failure ]; then
    [ "$(cat "$TMP_ROOT/$mode/enters")" = old ] || fail "$mode: protected replacement received Enter"
  fi
done
pass "Orca submit restart preserves deferral, failure, and replacement verification"
