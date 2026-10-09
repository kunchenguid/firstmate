#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-orca-submit-restart)

for order in before-text before-text-fresh before-enter pending second-enter original-pending original-typed; do
  for mode in empty draft busy unreadable failure success unknown-after pending-after settle-empty settle-draft settle-dialog settle-busy settle-unreadable; do
    case "$order/$mode" in
      before-text-fresh/settle-*) ;;
      before-text-fresh/*|before-enter/settle-*|pending/settle-*|second-enter/settle-*) continue ;;
    esac
    case "$order/$mode" in original-*/success) ;; original-*/*) continue ;; esac
    evidence="$TMP_ROOT/$order-$mode"
    mkdir -p "$evidence"
    case "$mode" in
      draft) printf 'protected draft' > "$evidence/composer" ;;
      empty|unreadable) : > "$evidence/composer" ;;
      *) printf doorbell > "$evidence/composer" ;;
    esac
    case "$order" in original-typed|before-text-fresh) : > "$evidence/composer" ;; esac
    out=$(bash -c '
      order=$2 mode=$3 evidence=$4
      export FM_HOME="$evidence" FM_STATE_OVERRIDE="$evidence/state" FM_CONFIG_OVERRIDE="$evidence/config"
      mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
      . "$1/bin/fm-watch.sh"
      . "$1/bin/backends/orca.sh"
      fm_backend_orca_tool_check() { return 0; }
      sleep() {
        if [ "$1" = 0.3 ] && [[ "$mode" = settle-* ]]; then
          touch "$evidence/settled"
          case "$mode" in
            settle-empty) : > "$evidence/composer" ;;
            settle-draft) printf "new user draft" > "$evidence/composer" ;;
          esac
        fi
      }
      stale() {
        FM_ORCA_LAST_STDERR=terminal_handle_stale
        FM_ORCA_LAST_STDOUT=
        FM_ORCA_LAST_RC=1
        return 1
      }
      fm_backend_orca_attempt() {
        local terminal=$5 text=$7
        printf "%s text\n" "$terminal" >> "$evidence/inputs"
        if [ "$terminal" = old ] && [[ "$order" = before-text* ]]; then stale; return 1; fi
        if [ "$terminal" = live ] || [ "$order" = original-typed ]; then printf "%s" "$text" >> "$evidence/composer"; fi
        printf "%s\n" "$terminal" >> "$evidence/typed"
      }
      fm_backend_orca_send_key_once() {
        printf "%s Enter\n" "$1" >> "$evidence/inputs"
        case "$order" in
          original-*)
            if [ ! -f "$evidence/first-enter" ]; then touch "$evidence/first-enter"; return 0; fi
            cat "$evidence/composer" > "$evidence/submitted"
            : > "$evidence/composer"
            return 0 ;;
        esac
        if [ "$1" = old ]; then
          if [ "$order" = second-enter ] && [ ! -f "$evidence/first-enter" ]; then
            touch "$evidence/first-enter"
            return 0
          fi
          stale
          return 1
        fi
        if [ "$mode" = failure ]; then FM_ORCA_LAST_RC=1; return 1; fi
        [ "$mode" != pending-after ] || return 0
        cat "$evidence/composer" >> "$evidence/submitted"
        : > "$evidence/composer"
      }
      fm_backend_orca_resolve_live_terminal() { printf live; }
      fm_backend_orca_composer_capture() {
        local body rule
        printf "%s\n" "$1" >> "$evidence/reads"
        if [ "$1" = old ] && [[ "$order" != original-* ]]; then
          body=doorbell
        else
          [ "$mode" != unreadable ] || return 1
          if [ -f "$evidence/settled" ]; then
            case "$mode" in
              settle-unreadable) return 1 ;;
              settle-dialog)
                printf "Background work is running\n❯ 1. Exit and stop tasks\nEnter to confirm · Esc to cancel\n"
                return 0 ;;
            esac
          fi
          if [ "$mode" = unknown-after ] && [ -f "$evidence/submitted" ]; then return 1; fi
          body=$(cat "$evidence/composer")
        fi
        printf -v rule "%*s" "$((${#body} + 4))" ""
        rule=${rule// /─}
        printf "╭%s╮\n│ > %s │\n╰%s╯\n" "$rule" "$body" "$rule"
      }
      fm_backend_agent_state() { printf idle; }
      fm_backend_busy_state() {
        if { [ "$mode" = busy ] || { [ "$mode" = settle-busy ] && [ -f "$evidence/settled" ]; }; } && [ "$2" = live ]; then printf busy; else printf idle; fi
      }
      fm_busy_lines_match() { return 1; }
      fm_backend_composer_state() {
        if [ "$2" = old ] && { [[ "$order" = before-text* ]] || [ "$order" = before-enter ]; }; then
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
      if [ "$mode" = pending-after ] || [[ "$mode" = settle-* ]]; then
        : > "$FM_CONFIG_OVERRIDE/wait-no-turns"
        rec=$(fm_task_inbox_write "$STATE" t1 "durable steer" fire-and-forget)
        fm_task_inbox_mark_retry "$STATE" t1 "$rec"
        touch -t 202001010000 "$STATE/t1.inbox/.retry-ring"
        window_backend() { printf orca; }
        window_label() { printf label; }
        watcher_capture() { WATCHER_CAPTURE=; }
        window_is_busy() { return 1; }
        status_own_open_decisions() { return 0; }
        triage_log() { return 0; }
        held_before=$(cat "$evidence/composer")
        inbox_steer_check old t1
        [ "$(cat "$STATE/t1.inbox/.retry-ring")" = "${rec##*/}" ] || exit 1
        [ -f "$rec" ] || exit 1
        [ "$(cat "$evidence/composer")" = "$held_before" ] || exit 1
      fi
      printf "%s" "$rc"
    ' bash "$ROOT" "$order" "$mode" "$evidence")
    expected=1
    case "$order/$mode" in
      original-*/success) expected=0 ;;
      before-text/failure) ;;
      */failure) expected=2 ;;
    esac
    [ "$out" = "$expected" ] || fail "$order/$mode: expected status $expected, got $out"
    if [ "$expected" = 0 ]; then
      [ "$(cat "$evidence/submitted")" = doorbell ] || fail "$order/$mode: own doorbell was not submitted exactly once"
      [ ! -s "$evidence/composer" ] || fail "$order/$mode: composer did not clear"
      [ "$(rg -c '^old Enter$' "$evidence/inputs")" = 2 ] || fail "$order/$mode: original two-Enter budget changed"
    else
      enters=$(rg -c '^live Enter$' "$evidence/inputs" || true)
      limit=1
      [ "$mode" != pending-after ] || limit=2
      [ "${enters:-0}" -le "$limit" ] || fail "$order/$mode: retried Enter on replacement in the same send"
    fi
    case "$mode" in
      settle-*|empty|draft|busy|unreadable)
        if [ "$mode" != empty ] || [ "$order" != before-text ]; then
          [ ! -f "$evidence/submitted" ] || fail "$order/$mode: protected replacement was submitted"
          assert_not_contains "$(cat "$evidence/inputs")" "live Enter" "$order/$mode: replacement received bare Enter"
        fi
        ;;
    esac
  done
done
pass "Orca gates settled replacement input, retains retry marks and original Enter budget"
