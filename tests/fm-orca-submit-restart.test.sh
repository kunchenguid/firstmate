#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-orca-submit-restart)

for order in before-text before-enter pending second-enter; do
  for mode in empty draft busy unreadable failure success unknown-after pending-after; do
    evidence="$TMP_ROOT/$order-$mode"
    mkdir -p "$evidence"
    case "$mode" in
      draft) printf 'protected draft' > "$evidence/composer" ;;
      empty|unreadable) : > "$evidence/composer" ;;
      *) printf doorbell > "$evidence/composer" ;;
    esac
    out=$(bash -c '
      . "$1/bin/backends/orca.sh"
      . "$1/bin/fm-task-inbox-lib.sh"
      order=$2 mode=$3 evidence=$4
      fm_backend_orca_tool_check() { return 0; }
      stale() {
        FM_ORCA_LAST_STDERR=terminal_handle_stale
        FM_ORCA_LAST_STDOUT=
        FM_ORCA_LAST_RC=1
        return 1
      }
      fm_backend_orca_attempt() {
        local terminal=$5 text=$7
        printf "%s text\n" "$terminal" >> "$evidence/inputs"
        if [ "$terminal" = old ] && [ "$order" = before-text ]; then stale; return 1; fi
        if [ "$terminal" = live ]; then printf "%s" "$text" >> "$evidence/composer"; fi
        printf "%s\n" "$terminal" >> "$evidence/typed"
      }
      fm_backend_orca_send_key_once() {
        printf "%s Enter\n" "$1" >> "$evidence/inputs"
        if [ "$1" = old ]; then
          if [ "$order" = second-enter ] && [ ! -f "$evidence/first-enter" ]; then
            touch "$evidence/first-enter"
            return 0
          fi
          stale
          return 1
        fi
        if [ "$mode" = failure ]; then FM_ORCA_LAST_RC=1; return 1; fi
        cat "$evidence/composer" >> "$evidence/submitted"
        [ "$mode" = pending-after ] || : > "$evidence/composer"
      }
      fm_backend_orca_resolve_live_terminal() { printf live; }
      fm_backend_orca_composer_capture() {
        local body rule
        printf "%s\n" "$1" >> "$evidence/reads"
        if [ "$1" = old ]; then
          body=doorbell
        else
          [ "$mode" != unreadable ] || return 1
          if [ "$mode" = unknown-after ] && [ -f "$evidence/submitted" ]; then return 1; fi
          body=$(cat "$evidence/composer")
        fi
        printf -v rule "%*s" "$((${#body} + 4))" ""
        rule=${rule// /─}
        printf "╭%s╮\n│ > %s │\n╰%s╯\n" "$rule" "$body" "$rule"
      }
      fm_backend_agent_state() { printf idle; }
      fm_backend_busy_state() {
        if [ "$mode" = busy ] && [ "$2" = live ]; then printf busy; else printf idle; fi
      }
      fm_busy_lines_match() { return 1; }
      fm_backend_composer_state() {
        if [ "$2" = old ] && { [ "$order" = before-text ] || [ "$order" = before-enter ]; }; then
          printf empty
        else
          fm_backend_orca_composer_state "$2"
        fi
      }
      fm_backend_capture() { fm_backend_orca_composer_capture "$2"; }
      fm_backend_source() { return 0; }
      fm_task_inbox_doorbell_line() { printf doorbell; }
      fm_backend_send_key() { shift; fm_backend_orca_send_key "$@"; }
      fm_backend_send_text_submit() { shift; fm_backend_orca_send_text_submit "$@"; }
      rc=0
      fm_task_inbox_ring orca old record || rc=$?
      printf "%s" "$rc"
    ' bash "$ROOT" "$order" "$mode" "$evidence")
    expected=1
    case "$mode" in
      failure) expected=2 ;;
      success) expected=0 ;;
      empty) [ "$order" != before-text ] || expected=0 ;;
    esac
    [ "$out" = "$expected" ] || fail "$order/$mode: expected status $expected, got $out"
    if [ "$expected" = 0 ]; then
      [ "$(cat "$evidence/submitted")" = doorbell ] || fail "$order/$mode: own doorbell was not submitted exactly once"
      [ ! -s "$evidence/composer" ] || fail "$order/$mode: composer did not clear"
      [ "$(tail -n 1 "$evidence/reads")" = live ] || fail "$order/$mode: verification missed the replacement"
    fi
    case "$mode" in
      empty|draft|busy|unreadable)
        if [ "$mode" != empty ] || [ "$order" != before-text ]; then
          [ ! -f "$evidence/submitted" ] || fail "$order/$mode: protected replacement was submitted"
          assert_not_contains "$(cat "$evidence/inputs")" "live Enter" "$order/$mode: replacement received bare Enter"
        fi
        ;;
    esac
  done
done
pass "Orca restart orders require own doorbell submission or defer"
