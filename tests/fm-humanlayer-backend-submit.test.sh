#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-task-inbox-lib.sh"

TEST_TMP=$(fm_test_tmproot fm-humanlayer-backend-submit)
fm_backend_source() {
  if [ "$1" = herdr ]; then
    fm_backend_herdr_send_literal() { literal_fixture "$@"; }
    fm_backend_herdr_send_key() { key_fixture "$@"; }
  fi
}
capture_fixture() {
  [ "$1" = endpoint ] && [ "$3" = worker-label ] || return 1
  [ "$capture_ok" = yes ] || return 1
  if [ -f "$TEST_TMP/response" ]; then
    if [ "${bounded_capture:-0}" = 1 ]; then
      tail -n 200 "$TEST_TMP/response"
    else
      cat "$TEST_TMP/response"
    fi
    rm -f "$TEST_TMP/response"
  else
    printf '%s' "$fixture_screen"
  fi
}
submit_fixture() {
  [ "$1" = endpoint ] && [ "$6" = worker-label ] && [ "$7" = humanlayer ] || return 1
  submissions=$((submissions + 1))
  : > "$TEST_TMP/submitted"
  printf empty
}
literal_fixture() {
  [ "$1" = endpoint ] && [ "$3" = worker-label ] || return 1
  submissions=$((submissions + 1))
  : > "$TEST_TMP/submitted"
  printf '%s' "$2" > "$TEST_TMP/text"
}
key_fixture() {
  [ "$1" = endpoint ] && [ "$2" = Enter ] && [ "$3" = worker-label ] || return 1
  printf 'Enter\n' >> "$TEST_TMP/keys"
  local plain
  plain=$(printf '%s' "$fixture_screen" | fm_composer_strip_ansi | tr -d '\r')
  {
    printf '%s> %s\n' "${plain%>*}" "$(cat "$TEST_TMP/text")"
    case "${delivery:-working}" in
      working) printf '[Tool] bash command=work\n' ;;
      complete) printf '[Assistant] done\n[Done] complete\n>\n' ;;
    esac
  } > "$TEST_TMP/response"
  if [ "${delivery:-working}" = no-overlap ]; then
    printf '> instruction\n[Tool] bash command=old\n' > "$TEST_TMP/response"
  fi
}
fm_backend_cmux_send_literal() { literal_fixture "$@"; }
fm_backend_orca_send_literal() { literal_fixture "$@"; }
fm_backend_cmux_send_key() { key_fixture "$@"; }
fm_backend_orca_send_key() { key_fixture "$@"; }
tmux() {
  [ "$1" = capture-pane ] || return 1
  while [ "$#" -gt 0 ] && [ "$1" != -t ]; do shift; done
  [ "$#" -ge 2 ] || return 1
  capture_fixture "$2" 200 worker-label
}
fm_backend_herdr_capture_ansi() { capture_fixture "$@"; }
fm_backend_zellij_composer_capture() { capture_fixture "$1" 200 "$2"; }
fm_backend_tmux_capture() { capture_fixture "$@"; }
fm_backend_herdr_capture() { capture_fixture "$@"; }
fm_backend_cmux_capture() { capture_fixture "$@"; }
fm_backend_orca_capture() { capture_fixture "$@"; }
fm_backend_zellij_capture() { capture_fixture "$@"; }
fm_backend_tmux_send_text_submit() { submit_fixture "$@"; }
fm_backend_herdr_send_text_submit() { submit_fixture "$@"; }
fm_backend_cmux_send_text_submit() { submit_fixture "$@"; }
fm_backend_orca_send_text_submit() { submit_fixture "$@"; }
fm_backend_zellij_send_text_submit() { submit_fixture "$@"; }
fm_backend_agent_state() { printf alive; }
fm_backend_composer_state() { printf unknown; }
fm_task_inbox_doorbell_line() { printf doorbell; }

for backend in tmux herdr; do
  for fixture_screen in $'>\n[Done] complete\n>' $'> Investigate this log:\n[Done] complete\n>' '> draft' $'> Investigate this log:\n[Done] complete\n\n' $'>\n[Assistant] draft' ''; do
    capture_ok=yes
    submissions=0
    rm -f "$TEST_TMP/submitted"
    if fm_backend_send_text_submit "$backend" endpoint instruction 1 0 0 worker-label humanlayer >/dev/null; then
      fail "$backend must defer unsafe input"
    fi
    [ "$submissions" = 0 ] || fail "$backend must not call submit on unsafe input"
    if fm_task_inbox_ring "$backend" endpoint record worker-label humanlayer; then
      fail "$backend inbox must defer unsafe input"
    fi
    [ ! -e "$TEST_TMP/submitted" ] || fail "$backend inbox must not call submit on unsafe input"
  done
  fixture_screen=$'> previous prompt\n\033[38;2;34;197;94m[Done]\033[39m complete\n>\n'
  capture_ok=no
  if fm_backend_send_text_submit "$backend" endpoint instruction 1 0 0 worker-label humanlayer >/dev/null; then
    fail "$backend must defer failed capture"
  fi
  capture_ok=yes
  submissions=0
  fm_backend_send_text_submit "$backend" endpoint instruction 1 0 0 worker-label humanlayer >/dev/null
  [ "$submissions" = 1 ] || fail "$backend must submit once when affirmatively idle"
  fm_task_inbox_ring "$backend" endpoint record worker-label humanlayer || fail "$backend must ring an idle worker"
  pass "$backend HumanLayer submission requires an affirmatively empty composer"
done


banner=$'[codex-provider] using sse transport http://localhost/session\ncodelayer - provider: codex, model: gpt-6-astra'
for backend in tmux herdr; do
  capture_ok=yes
  for fixture_screen in "$banner"$'\n>\n' "$banner"$'\n\n>\n'; do
    submissions=0
    rm -f "$TEST_TMP/submitted"
    fm_backend_send_text_submit "$backend" endpoint instruction 1 0 0 worker-label humanlayer >/dev/null \
      || fail "$backend must accept the verified fresh-launch composer"
    [ "$submissions" = 1 ] || fail "$backend must deliver the fresh-launch instruction once"
    fm_task_inbox_ring "$backend" endpoint record worker-label humanlayer \
      || fail "$backend must ring the verified fresh-launch composer"
  done
  for fixture_screen in "$banner"$'\nretained log\n>' $'retained log\n'"$banner"$'\n>' "$banner"$'\n> draft\n>' "$banner"$'\n>\n>' $'codelayer - provider: codex, model: gpt-6-astra\n>'; do
    submissions=0
    rm -f "$TEST_TMP/submitted"
    if fm_backend_send_text_submit "$backend" endpoint instruction 1 0 0 worker-label humanlayer >/dev/null; then
      fail "$backend must reject incomplete or displaced startup provenance"
    fi
    [ "$submissions" = 0 ] || fail "$backend must preserve ambiguous startup content"
    if fm_task_inbox_ring "$backend" endpoint record worker-label humanlayer; then
      fail "$backend inbox must reject ambiguous startup content"
    fi
    [ ! -e "$TEST_TMP/submitted" ] || fail "$backend inbox must preserve ambiguous startup content"
  done
  pass "$backend accepts only the top-anchored fresh-launch banner and empty composer"
done


footer=$'  Model            Input   Output     Cost             Context\n  gpt-6-astra      5,534        13   ~$0.06  5,542/258,400 (2%)'
for completion in $'\033[38;2;34;197;94m[Done]\033[39m complete' $'\033[0m\033[38;2;34;197;94m[Done]\033[0m complete\r'; do
  for backend in tmux herdr; do
    capture_ok=yes
    settled_screen=$'> previous prompt\n'"$completion"$'\n'"$footer"
    fixture_screen="$settled_screen"$'\n>\n'
    submissions=0
    fm_backend_send_text_submit "$backend" endpoint instruction 1 0 0 worker-label humanlayer >/dev/null \
      || fail "$backend must accept a completed turn with its usage footer"
    [ "$submissions" = 1 ] || fail "$backend must submit once after the usage footer"
    fm_task_inbox_ring "$backend" endpoint record worker-label humanlayer \
      || fail "$backend inbox must accept a settled usage footer"
    for fixture_screen in "$settled_screen" "$settled_screen"$'\n> draft\n>' "$settled_screen"$'\n>\n>' "$settled_screen"$'\n>\n'"$footer"$'\n>' $'> draft\n[Done] complete\n'"$footer"$'\n>' "$footer"$'\n>'; do
      submissions=0
      rm -f "$TEST_TMP/submitted"
      if fm_backend_send_text_submit "$backend" endpoint instruction 1 0 0 worker-label humanlayer >/dev/null; then
        fail "$backend must not accept usage-shaped draft content or missing composer"
      fi
      [ "$submissions" = 0 ] || fail "$backend must preserve usage-shaped draft content"
      if fm_task_inbox_ring "$backend" endpoint record worker-label humanlayer; then
        fail "$backend inbox must defer usage-shaped draft content"
      fi
      [ ! -e "$TEST_TMP/submitted" ] || fail "$backend inbox must not submit usage-shaped draft content"
    done
    pass "$backend preserves completion through usage furniture and rejects new drafts"
  done
done


backend=herdr
for delivery in working complete swallowed; do
  fixture_screen=$'> instruction\n[Assistant] old result\n\033[38;2;34;197;94m[Done]\033[39m complete\n>\n'
  : > "$TEST_TMP/keys"
  verdict=$(fm_backend_send_text_submit "$backend" endpoint instruction 1 0 0 worker-label humanlayer)
  if [ "$delivery" = swallowed ]; then
    [ "$verdict" = unknown ] || fail "$backend must not borrow historical confirmation"
  else
    [ "$verdict" = empty ] || fail "$backend must confirm current $delivery output"
  fi
  [ "$(wc -l < "$TEST_TMP/keys" | tr -d ' ')" = 1 ] || fail "$backend must send Enter once"
done
pass "$backend confirms current HumanLayer responses without generic composer state"


bounded_capture=1
backend=herdr
for delivery in working complete swallowed no-overlap; do
  fixture_screen=$(for ((row=1; row<=196; row++)); do printf 'history %s\n' "$row"; done
    printf '> instruction\n[Assistant] old result\n\033[38;2;34;197;94m[Done]\033[39m complete\n>\n')
  [ "$(printf '%s\n' "$fixture_screen" | wc -l | tr -d ' ')" = 200 ] || fail "baseline must fill the bounded capture"
  : > "$TEST_TMP/keys"
  verdict=$(fm_backend_send_text_submit "$backend" endpoint instruction 1 0 0 worker-label humanlayer)
  case "$delivery" in
    working|complete) [ "$verdict" = empty ] || fail "$backend must confirm after bounded scroll: $delivery" ;;
    *) [ "$verdict" = unknown ] || fail "$backend must reject unproven bounded delivery: $delivery" ;;
  esac
  [ "$(wc -l < "$TEST_TMP/keys" | tr -d ' ')" = 1 ] || fail "$backend must not resubmit after scrolling"
done
pass "$backend confirms overlapping captures without borrowing historical responses"

for backend in cmux orca zellij; do
  for fixture_screen in '>' $'> previous prompt\n[Done] complete\n>' $'> previous prompt\n\033[38;2;34;197;94m[Done]\033[39m complete\n>'; do
    rm -f "$TEST_TMP/submitted" "$TEST_TMP/keys"
    if fm_backend_send_text_submit "$backend" endpoint instruction 1 0 0 worker-label humanlayer >"$TEST_TMP/verdict" 2>"$TEST_TMP/error"; then
      fail "$backend must refuse HumanLayer dispatch"
    fi
    assert_contains "$(cat "$TEST_TMP/error")" 'unsupported backend for HumanLayer dispatch' "$backend must explain refusal"
    [ ! -e "$TEST_TMP/submitted" ] && [ ! -e "$TEST_TMP/keys" ] || fail "$backend refusal must not type or submit"
    if fm_task_inbox_ring "$backend" endpoint record worker-label humanlayer; then
      fail "$backend must refuse HumanLayer inbox delivery"
    fi
    [ ! -e "$TEST_TMP/submitted" ] || fail "$backend inbox refusal must not type"
  done
  pass "$backend refuses HumanLayer dispatch regardless of screen content"
done
