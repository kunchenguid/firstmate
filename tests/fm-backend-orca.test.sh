#!/usr/bin/env bash
# tests/fm-backend-orca.test.sh - fake-Orca-CLI unit tests for the Orca
# terminal adapter primitives in bin/backends/orca.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-orca-tests)
# A claude spawn writes workspace trust into the launching user's own store,
# and the script resolves it as ${CLAUDE_CONFIG_DIR:-${HOME:-}}, so the value
# is pinned EMPTY beside the throwaway HOME: an inherited one would beat that
# HOME and reach the developer's real store, while empty falls through to it
# and adds no launch prefix, since fm-spawn only prefixes a non-empty value.
SPAWN_HOME="$TMP_ROOT/user-home"
mkdir -p "$SPAWN_HOME"

write_spawn_brief() {  # <data-dir> <id>
  local data=$1 id=$2
  cat > "$data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Orca dispatch.

## Firstmate spec
Verify the Orca lifecycle behavior under test.
EOF
}

make_orca_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
RESP="${FM_ORCA_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${FM_ORCA_STATUS_RESPONSE:-ready}" != sequence ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
if [ "${1:-}:${2:-}" = project:setups ]; then
  cat "$RESP/setups.json"
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
[ ! -f "$RESP/$n.out" ] || cat "$RESP/$n.out"
[ ! -f "$RESP/$n.hook" ] || bash "$RESP/$n.hook"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

orca_case() {  # <name> -> sets CASE_DIR LOG RESP FB
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/responses"
  LOG="$CASE_DIR/log"
  RESP="$CASE_DIR/responses"
  : > "$LOG"
  FB=$(make_orca_fakebin "$CASE_DIR")
}

neutral_fm_root() {  # <dir> -> echoes a minimal root with a quiet guard
  local root="$1/root"
  mkdir -p "$root/bin"
  cat > "$root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/bin/fm-guard.sh"
  printf '%s\n' "$root"
}

add_tmux_fake() {
  local fb=$1
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
{
  printf 'tmux'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
exit 0
SH
  chmod +x "$fb/tmux"
}

test_capture_reads_terminal_tail_json() {
  local out
  orca_case capture-tail
  printf '{"result":{"terminal":{"tail":["line one","line two"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-123 40' "$ROOT" )
  [ "$out" = $'line one\nline two' ] || fail "capture should print result.terminal.tail joined by newlines, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--limit'$'\x1f''40'$'\x1f''--json' \
    "capture did not call orca terminal read with terminal/limit/json"
  pass "fm_backend_orca_capture: parses result.terminal.tail and calls terminal read"
}

test_capture_falls_back_to_text_fields() {
  local out
  orca_case capture-text
  printf '{"result":{"text":"plain text output"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-abc 5' "$ROOT" )
  [ "$out" = "plain text output" ] || fail "capture should fall back to result.text, got '$out'"
  pass "fm_backend_orca_capture: falls back to result text fields"
}

test_capture_fails_on_orca_error_json() {
  local out status
  orca_case capture-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-stale 5' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail on Orca ok:false read JSON"
  assert_contains "$out" "terminal handle stale" "capture should surface the Orca read error message"
  pass "fm_backend_orca_capture: fails closed on Orca read error JSON"
}

test_runtime_check_accepts_ready_orca_status() {
  local out
  orca_case runtime-ready
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check' "$ROOT" )
  [ -z "$out" ] || fail "runtime_check should be quiet on ready status, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''status'$'\x1f''--json' \
    "runtime_check did not call orca status --json"
  pass "fm_backend_orca_runtime_check: accepts reachable ready runtime"
}

test_runtime_check_refuses_unready_orca_status() {
  local out status
  orca_case runtime-unready
  printf '{"ok":true,"result":{"runtime":{"reachable":false,"state":"starting"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check should fail when Orca runtime is not ready"
  assert_contains "$out" "requires a ready Orca runtime" "runtime_check should explain the readiness requirement"
  pass "fm_backend_orca_runtime_check: fails closed when runtime is not ready"
}

test_send_text_submit_verifies_empty_composer_after_enter() {
  local out
  orca_case send-submit
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭───╮","│ > │","╰───╯"]}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty on successful Orca send, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f''hello captain'$'\x1f''--json' \
    "send_text_submit did not type the text literally before Enter"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send_text_submit did not send Enter after typing"
  # The composer read is ONE bounded tail read: the old backward paging
  # (--cursor follow-ups on a limited page) is deleted, because paging into
  # scrollback is what let a stale startup banner compete with the live
  # composer (audit fm-composer-consolidation-audit-s1, section 3.3).
  assert_not_contains "$(cat "$LOG")" $'\x1f''--cursor'$'\x1f' \
    "the composer read must never page backward into scrollback"
  pass "fm_backend_orca_send_text_submit: verifies empty composer after Enter with one bounded read"
}

test_send_text_submit_borderless_claude_confirms() {
  # The #2029 analogue this adapter never received: a borderless claude
  # composer (bare `❯` row between horizontal rules) must confirm a submit.
  # Before consolidation orca knew only the bordered shape, so every steer to
  # a borderless harness exited unconfirmed and --resolve-key never closed.
  local out
  orca_case send-submit-borderless
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["────────────────","❯","────────────────"]}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "a borderless claude composer should confirm the submit, got '$out'"
  pass "fm_backend_orca_send_text_submit: a borderless claude composer confirms delivery (the missing #2029 shape)"
}

test_composer_state_stale_banner_never_wins() {
  # The audit's confidently-wrong case (section 3.3): codex's startup banner
  # (`│ permissions: YOLO mode │` inside a rounded box) classified as the
  # composer, reading `pending` for a row that is not a composer at all. With
  # the full shape catalogue the live bare row below the banner wins; with a
  # plain capture its trailing hint text is unreadable, so the verdict is
  # `unknown` (defer) - never the banner's false `pending`.
  local out
  orca_case composer-stale-banner
  printf '{"ok":true,"result":{"terminal":{"tail":["╭────────────────────────╮","│ permissions: YOLO mode │","╰────────────────────────╯","› Use /skills to list available skills"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" != pending ] || fail "a stale startup banner must never classify as pending composer text"
  [ "$out" = unknown ] || fail "the plain-capture codex hint should defer as unknown, got '$out'"
  pass "fm_backend_orca_composer_state: a stale startup banner cannot outrank the live composer row"
}

test_send_text_submit_retries_when_composer_stays_pending() {
  local out log_text enter_count
  orca_case send-submit-pending
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭─────────────────╮","│ > hello captain │","╰─────────────────╯"]}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭─────────────────╮","│ >               │","╰─────────────────╯"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should retry Enter until the composer clears, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 2 ] || fail "send_text_submit should send Enter twice when the first read is pending, got $enter_count"
  pass "fm_backend_orca_send_text_submit: retries Enter while composer remains pending"
}

test_composer_state_popup_placeholder_fill_is_pending() {
  local out
  orca_case composer-popup-placeholder
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭──────────────────────────────────────╮","  │ ❯ /compact compaction instructions   │","  ╰──────────────── Composer ────────────╯","","  Enter:send"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" = pending ] || fail "a popup-close-with-placeholder-fill must still read as pending (not yet submitted), got '$out'"
  pass "fm_backend_orca_composer_state: a slash-command popup's argument-hint placeholder still reads pending"
}

# Dead-shell injection safety (task fm-composer-shellglyph-safety): a pane whose
# agent has exited to a bare login shell has no bordered composer row, so the
# classifier finds nothing and reports `unknown` - NOT a safe (empty) injection
# target. Covers the same guarantee herdr/cmux/tmux tests pin for their backends.
test_composer_state_bare_shell_prompt_is_unknown() {
  local out
  orca_case composer-bare-shell
  printf '{"ok":true,"result":{"terminal":{"tail":["some earlier output","kunchen@mac firstmate $ "]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" = unknown ] || fail "a bare dead-shell prompt (no bordered composer row) must read unknown, got '$out'"
  pass "fm_backend_orca_composer_state: a bare dead-shell prompt reads unknown (unsafe-for-injection), never empty"
}

test_send_text_submit_popup_autocomplete_requires_second_enter() {
  local out log_text enter_count
  orca_case send-submit-popup-autocomplete
  # 1: literal send "/compact"
  # 2: Enter #1 closes the popup and fills the placeholder
  # 3: read - composer still holds real pending text
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭──────────────────────────────────────╮","  │ ❯ /compact compaction instructions   │","  ╰──────────────── Composer ────────────╯","","  Enter:send"]}}}\n' > "$RESP/3.out"
  # 4: Enter #2 actually submits
  # 5: read - composer is empty
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭────────────────────────╮","  │ ❯                      │","  ╰──────── Composer ──────╯","","  Shift+Tab:mode"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "/compact" 3 0.01 1.2' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should eventually report empty once the SECOND Enter actually clears the composer, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 2 ] || fail "send_text_submit must send a SECOND Enter after the popup-placeholder fill still reads pending, got $enter_count Enter(s)"
  pass "fm_backend_orca_send_text_submit: a slash-command popup's placeholder fill on Enter #1 does not short-circuit as submitted; Enter #2 is retried and lands it"
}

test_send_literal_constructs_non_enter_send() {
  orca_case send-literal
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-123 "typed only"' "$ROOT"
  expect_code 0 $? "send_literal should succeed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f''typed only'$'\x1f''--json' \
    "send_literal did not send text without --enter"
  assert_not_contains "$(cat "$LOG")" $'\x1f''--enter' "send_literal should not submit Enter"
  pass "fm_backend_orca_send_literal: sends text without submitting"
}

test_send_text_submit_reports_send_failed() {
  local out
  orca_case send-fail
  printf '1\n' > "$RESP/1.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello" 1 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "failed Orca send should report send-failed, got '$out'"
  pass "fm_backend_orca_send_text_submit: reports send-failed when Orca send fails"
}

test_send_helpers_reject_orca_error_json() {
  local out status
  orca_case send-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_line term-stale "hello"' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_text_line should fail on Orca ok:false JSON"
  assert_contains "$out" "terminal handle stale" "send_text_line should surface the Orca send error"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/2.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-stale "typed"' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_literal should fail on Orca ok:false JSON"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-stale Enter' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should fail on Orca ok:false JSON"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-stale "hello" 1 0.01 0.01' "$ROOT" 2>/dev/null )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed on Orca ok:false JSON, got '$out'"
  pass "Orca send helpers: fail closed on ok:false JSON"
}

test_send_key_enter_and_interrupt() {
  orca_case send-key
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 Enter; fm_backend_orca_send_key term-123 C-c' "$ROOT"
  expect_code 0 $? "send_key Enter and C-c should succeed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send_key Enter did not send empty text with --enter"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--interrupt'$'\x1f''--json' \
    "send_key C-c did not send --interrupt"
  pass "fm_backend_orca_send_key: Enter maps to empty enter, C-c maps to interrupt"
}

test_send_key_refuses_unknown_key() {
  local out status
  orca_case send-key-unknown
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 F12' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse unsupported Orca keys"
  assert_contains "$out" "unsupported Orca key 'F12'" "send_key did not name the unsupported key"
  pass "fm_backend_orca_send_key: refuses unsupported keys loudly"
}

test_send_key_refuses_escape_until_supported() {
  local out status
  orca_case send-key-escape
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 Escape' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse Escape until Orca exposes a real Escape primitive"
  assert_contains "$out" "unsupported Orca key 'Escape'" "send_key did not name Escape as unsupported"
  [ ! -s "$LOG" ] || fail "unsupported Escape should not call orca terminal send"
  pass "fm_backend_orca_send_key: refuses Escape instead of mapping it to interrupt"
}

test_kill_is_best_effort_close() {
  orca_case kill
  printf '1\n' > "$RESP/1.exit"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_kill term-123' "$ROOT"
  expect_code 0 $? "kill should stay best-effort when Orca close fails"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--json' \
    "kill did not call orca terminal close"
  pass "fm_backend_orca_kill: calls terminal close and stays best-effort"
}

# The paired direction - an `orca` stub present, a close command that exits
# nonzero, still 0 - is test_kill_is_best_effort_close above. This case is the
# distinction that arm exists to make, so the two are read together.
test_kill_refuses_when_the_orca_cli_is_absent() {
  local out status orca_free
  orca_case kill-no-cli
  orca_free=$(fm_test_base_path_sans "$PATH" orca)
  ! PATH="$orca_free" command -v orca >/dev/null 2>&1 \
    || fail "the orca-free search path still resolved orca"
  PATH="$orca_free" command -v bash >/dev/null 2>&1 \
    || fail "the orca-free search path lost bash, so this case would pass vacuously"
  out=$( PATH="$orca_free" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_kill term-123' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "kill reported success for a close its missing CLI never attempted"
  assert_contains "$out" "backend=orca selected but the 'orca' CLI is not installed" \
    "kill did not name the missing CLI as the reason the close never happened"
  [ ! -s "$LOG" ] || fail "kill invoked orca despite the CLI being absent"
  pass "fm_backend_orca_kill: a close its missing CLI never attempted reports the failure instead of a success"
}

test_remove_worktree_refuses_empty_id() {
  local out status
  orca_case remove-empty
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree ""' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree should fail when the Orca worktree id is empty"
  assert_contains "$out" "missing Orca worktree id" "remove_worktree did not explain the missing id"
  [ ! -s "$LOG" ] || fail "remove_worktree should not call Orca with an empty id"
  pass "fm_backend_orca_remove_worktree: refuses empty worktree ids"
}

test_remove_worktree_rejects_orca_error_json() {
  local out status
  orca_case remove-error-json
  printf '{"ok":false,"error":{"code":"worktree_not_found","message":"worktree not found"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree wt-gone::/orca/wt-gone' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree should fail on Orca ok:false JSON"
  assert_contains "$out" "worktree not found" "remove_worktree should surface the Orca removal error"
  pass "fm_backend_orca_remove_worktree: fails closed on ok:false JSON"
}

test_worktree_path_resolves_id() {
  local out
  orca_case path-resolve
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123::/orca/wt-123","path":"/tmp/orca-wt"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_path wt-123::/orca/wt-123' "$ROOT" )
  [ "$out" = /tmp/orca-wt ] || fail "worktree path helper should print the resolved path, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-123::/orca/wt-123'$'\x1f''--json' \
    "worktree path helper did not call orca worktree show"
  pass "fm_backend_orca_worktree_path: resolves an Orca worktree id to its path"
}

test_json_get_ignores_undocumented_terminal_id_shapes() {
  local out status wt_id wt_path term
  orca_case parser-pruned-terminal-shapes

  set +e
  out=$( printf '{"ok":true,"result":{"id":"term-root-id"}}\n' | \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_json_get terminal-handle' "$ROOT" )
  status=$?
  set +e
  [ "$status" -ne 0 ] || fail "terminal-handle should not treat undocumented result.id as a terminal handle, got '$out'"

  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-123"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123::/orca/wt-123","path":"/tmp/orca-wt","terminal":{"handle":"term-nested"}}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" )
  wt_id=${out%%$'\t'*}
  wt_path=${out#*$'\t'}
  term=${wt_path#*$'\t'}
  wt_path=${wt_path%%$'\t'*}
  [ "$wt_id" = wt-123::/orca/wt-123 ] || fail "worktree helper should still print worktree id, got '$wt_id'"
  [ "$wt_path" = /tmp/orca-wt ] || fail "worktree helper should still print worktree path, got '$wt_path'"
  [ "$term" = "$wt_path" ] || fail "worktree helper should ignore undocumented result.worktree.terminal and omit an implicit terminal, got '$out'"
  pass "fm_backend_orca_json_get: ignores undocumented terminal id shapes"
}

test_worktree_and_terminal_helpers_parse_json() {
  local out wt_id wt_path term
  orca_case lifecycle-helpers
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-123"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123::/orca/wt-123","path":"/tmp/orca-wt"}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-123"}}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" )
  wt_id=${out%%$'\t'*}
  wt_path=${out#*$'\t'}
  [ "$wt_id" = wt-123::/orca/wt-123 ] || fail "worktree helper should print worktree id, got '$wt_id'"
  [ "$wt_path" = /tmp/orca-wt ] || fail "worktree helper should print worktree path, got '$wt_path'"
  term=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_terminal_create wt-123::/orca/wt-123 fm-task' "$ROOT" )
  [ "$term" = term-123 ] || fail "terminal helper should print terminal handle, got '$term'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''show'$'\x1f''--repo'$'\x1f''path:/repo/path'$'\x1f''--json' \
    "worktree helper should first check repo registration"
  assert_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''add'$'\x1f''--path'$'\x1f''/repo/path'$'\x1f''--json' \
    "worktree helper should register an absent repo"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''create'$'\x1f''--repo'$'\x1f''id:repo-123'$'\x1f''--name'$'\x1f''fm-task'$'\x1f''--no-parent'$'\x1f''--setup'$'\x1f''skip'$'\x1f''--json' \
    "worktree helper did not create an independent no-hook worktree"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f''id:wt-123::/orca/wt-123'$'\x1f''--title'$'\x1f''fm-task'$'\x1f''--json' \
    "terminal helper did not create a titled terminal for the worktree"
  pass "Orca lifecycle helpers: register repo, create worktree, create terminal, parse stable ids"
}

test_worktree_create_removes_worktree_when_path_missing() {
  local out status
  orca_case lifecycle-missing-path
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-no-path"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-no-path::/orca/wt-no-path"},"terminal":{"handle":"term-no-path"}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "worktree helper should fail when Orca omits the worktree path"
  assert_contains "$out" "orca worktree create did not return a path for fm-task" \
    "worktree helper did not explain the missing path"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-no-path'$'\x1f''--json' \
    "worktree helper did not close the implicit terminal when path parsing failed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-no-path::/orca/wt-no-path'$'\x1f''--force'$'\x1f''--json' \
    "worktree helper did not remove the pathless Orca worktree"
  pass "fm_backend_orca_worktree_create: removes created worktree when path is missing"
}

test_spawn_preserves_orca_metadata_when_pathless_worktree_cleanup_fails() {
  local proj data state config id out status
  id="orcapathlessz6"
  proj="$TMP_ROOT/pathless-cleanup-project"
  data="$TMP_ROOT/pathless-cleanup-data"
  state="$TMP_ROOT/pathless-cleanup-state"
  config="$TMP_ROOT/pathless-cleanup-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case pathless-cleanup-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-pathless-cleanup"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-pathless-cleanup::/orca/wt-pathless-cleanup"}}}\n' > "$RESP/3.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/4.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/5.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when path parsing and cleanup fail"
  assert_contains "$out" "orca worktree create did not return a path" \
    "pathless worktree failure should explain the missing path"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-pathless-cleanup::/orca/wt-pathless-cleanup'$'\x1f''--force'$'\x1f''--json' \
    "pathless cleanup should attempt helper-backed worktree removal"
  assert_present "$state/$id.meta" "failed pathless cleanup should preserve metadata"
  assert_grep "window=fm-$id" "$state/$id.meta" "preserved pathless metadata missing stable window alias"
  assert_grep "backend=orca" "$state/$id.meta" "preserved pathless metadata missing backend=orca"
  assert_grep "orca_worktree_id=wt-pathless-cleanup::/orca/wt-pathless-cleanup" "$state/$id.meta" "preserved pathless metadata missing Orca worktree id"
  assert_no_grep "terminal=" "$state/$id.meta" "preserved pathless metadata should not invent a terminal handle"
  pass "fm-spawn.sh --backend orca: preserves metadata when pathless cleanup fails"
}

test_spawn_writes_orca_metadata_and_launches_harness() {
  local proj wt data state config id out log staged launch
  id="orcaspawnz1"
  proj="$TMP_ROOT/spawn-project"
  wt="$TMP_ROOT/spawn-wt"
  data="$TMP_ROOT/spawn-data"
  state="$TMP_ROOT/spawn-state"
  config="$TMP_ROOT/spawn-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case spawn
  log="$LOG"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-spawn"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-spawn::/orca/wt-spawn","path":"%s"},"terminal":{"handle":"term-spawn"}}}\n' "$wt" > "$RESP/3.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  expect_code 0 $? "fm-spawn.sh --backend orca should succeed with fake Orca"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude kind=ship mode=no-mistakes yolo=off window=fm-$id worktree=$wt" \
    "spawn output missing Orca window/worktree summary"
  assert_grep "backend=orca" "$state/$id.meta" "meta missing backend=orca"
  assert_grep "window=fm-$id" "$state/$id.meta" "meta missing stable Orca window alias"
  assert_grep "terminal=term-spawn" "$state/$id.meta" "meta missing terminal handle"
  assert_grep "orca_worktree_id=wt-spawn::/orca/wt-spawn" "$state/$id.meta" "meta missing Orca worktree id"
  assert_grep "worktree=$wt" "$state/$id.meta" "meta missing Orca worktree path"
  assert_not_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''create' \
    "spawn should reuse the implicit terminal returned by Orca worktree creation"
  assert_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-spawn'$'\x1f''--text'$'\x1f''export GOTMPDIR=/tmp/fm-orcaspawnz1/gotmp'$'\x1f''--enter'$'\x1f''--json' \
    "spawn did not export GOTMPDIR through the Orca terminal"
  staged=$(tr '\037' '\n' < "$log" | sed -n "s/^\. '\([^']*\)'$/\1/p" | tail -1)
  [ -n "$staged" ] && [ -f "$staged" ] \
    || fail "spawn did not send Orca a readable staged launch command"
  launch=$(cat "$staged")
  add_dirs="--add-dir '$(cd "$state" && pwd -P)/operational-inbox' --add-dir '$(cd "$state" && pwd -P)/$id.inbox' --add-dir '$(cd "$data" && pwd -P)/$id' --add-dir '$(cd "$ROOT" && pwd -P)/.agents/skills'"
  assert_contains "$launch" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions $add_dirs --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}'" \
    "the staged launch sent through Orca did not select the Claude harness"
  rm -rf "/tmp/fm-$id" "$(dirname "$staged")"
  pass "fm-spawn.sh --backend orca: reuses implicit terminal, records metadata, launches harness"
}

test_spawn_orca_secondmate_reuses_seeded_home() {
  local home subhome id out staged
  id=orcasmz1
  home="$TMP_ROOT/secondmate-primary"
  subhome="$TMP_ROOT/secondmate-home"
  fm_git_init_commit "$subhome"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects" \
    "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  printf 'Idle test charter.\n' > "$subhome/data/charter.md"
  printf 'manual\n' > "$home/config/backlog-backend"
  touch "$home/state/.last-watcher-beat"
  orca_case secondmate-spawn
  printf '{"ok":false,"error":{"code":"repo_not_found"}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"repo":{"id":"repo-sm"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"repo-sm::%s","path":"%s","repoId":"repo-sm","isMainWorktree":true}}}\n' "$subhome" "$subhome" > "$RESP/3.out"
  home_setup_response "$subhome" repo-sm
  cp "$RESP/3.out" "$RESP/4.out"
  printf '{"ok":true,"result":{"terminals":[{"handle":"term-sm","worktreeId":"repo-sm::%s"}],"totalCount":1,"truncated":false,"hostScope":{"omittedHostIds":[]}}}\n' "$subhome" > "$RESP/6.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-sm"}}}\n' > "$RESP/5.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend orca --secondmate 2>&1 )
  expect_code 0 $? "Orca secondmate spawn failed: $out"
  assert_grep "worktree=$subhome" "$home/state/$id.meta" "secondmate must use its existing home"
  assert_grep "terminal=term-sm" "$home/state/$id.meta" "secondmate terminal identity missing"
  assert_not_contains "$(cat "$LOG")" $'worktree\x1fcreate' "persistent home must never allocate a worker checkout"
  assert_contains "$(cat "$LOG")" '2ndmate-orcasmz1' "secondmate terminal title missing"
  staged=$(tr '\037' '\n' < "$LOG" | sed -n "s/^\. '\([^']*\)'$/\1/p" | tail -1)
  [ -n "$staged" ] && [ -f "$staged" ] || fail "secondmate staged launch missing"
  assert_contains "$(cat "$staged")" "FM_HOME='$subhome'" "secondmate launch must select its own home"
  cat > "$FB/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD" "$FM_HOME" "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME" > "$FM_ORCA_ENV_RESULT"
SH
  chmod +x "$FB/claude"
  ( cd "$subhome" && FM_ORCA_ENV_RESULT="$CASE_DIR/launch-env" PATH="$FB:$PATH" bash "$staged" ) || fail 'staged secondmate launch failed'
  [ "$(cat "$CASE_DIR/launch-env")" = "$(printf '%s\n' "$subhome" "$subhome" "$home")" ] || fail 'secondmate cwd/home/parent environment drifted'
  if out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend orca --secondmate 2>&1 ); then
    fail "duplicate Orca secondmate spawn succeeded"
  fi
  assert_contains "$out" 'refusing duplicate launch' "duplicate must fail closed"
  rm -f "$RESP"/*.out "$RESP/.count"
  : > "$LOG"
  printf 'kind=scout\n' > "$subhome/state/live-child.meta"
  if out=$( HOME="$SPAWN_HOME" PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_TEARDOWN_GUARD_DONE=1 \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 ); then fail 'retired home with live child'; fi
  assert_contains "$out" 'still has in-flight work' 'child-work retirement gate lost'
  [ ! -s "$LOG" ] || fail 'child-work gate ran Orca before refusal'
  rm "$subhome/state/live-child.meta"
  printf '{"ok":true,"result":{"worktree":{"id":"repo-sm::%s","path":"%s","repoId":"repo-sm","isMainWorktree":true}}}\n' "$subhome" "$subhome" > "$RESP/1.out"
  printf '{"ok":true,"result":{"terminals":[],"totalCount":0,"truncated":true,"hostScope":{"omittedHostIds":[]}}}\n' > "$RESP/2.out"
  if out=$( HOME="$SPAWN_HOME" PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_TEARDOWN_GUARD_DONE=1 \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 ); then fail 'retired home after uncertain close'; fi
  assert_contains "$out" 'incomplete Orca terminal inventory' 'strict close refusal missing'
  assert_present "$home/state/$id.meta" 'uncertain close removed metadata'
  assert_present "$subhome/.fm-secondmate-home" 'uncertain close removed home'
  rm -f "$RESP/.count"
  : > "$LOG"
  printf '{"ok":true,"result":{"terminals":[{"handle":"term-sm","worktreeId":"repo-sm::%s"}],"totalCount":1,"truncated":false,"hostScope":{"omittedHostIds":[]}}}\n' "$subhome" > "$RESP/2.out"
  printf '{"ok":true}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminals":[],"totalCount":0,"truncated":false,"hostScope":{"omittedHostIds":[]}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"repo":{"id":"repo-sm"}}}\n' > "$RESP/5.out"
  cp "$RESP/1.out" "$RESP/6.out"
  printf '{"ok":true,"result":{"worktrees":[{"id":"repo-sm::%s","isMainWorktree":true}],"totalCount":1,"truncated":false}}\n' "$subhome" > "$RESP/7.out"
  cp "$RESP/4.out" "$RESP/8.out"
  cp "$RESP/3.out" "$RESP/9.out"
  printf '{"ok":false,"error":{"code":"repo_not_found"}}\n' > "$RESP/10.out"
  printf 'mkdir -p %q\n' "$home/state/pending-replies" > "$RESP/4.hook"
  if out=$( HOME="$SPAWN_HOME" PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_TEARDOWN_GUARD_DONE=1 \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 ); then fail 'retired home after late pending-reply change'; fi
  assert_contains "$out" 'pending-reply recovery paths changed' 'late pending-reply recheck refusal missing'
  assert_not_contains "$(cat "$LOG")" $'setup-delete' 'late recheck failure released owned Orca registrations'
  assert_present "$home/state/$id.meta" 'late recheck failure removed metadata'
  assert_present "$subhome/.fm-secondmate-home" 'late recheck failure removed home'
  rm -f "$RESP/4.hook"
  out=$( HOME="$SPAWN_HOME" PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_TEARDOWN_GUARD_DONE=1 \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  expect_code 0 $? "secondmate retirement failed: $out"
  assert_absent "$subhome" 'retirement retained home'
  assert_absent "$home/state/$id.meta" 'retirement retained metadata'
  assert_contains "$(cat "$LOG")" $'terminal\x1fclose' 'retirement skipped terminal close'
  assert_not_contains "$(cat "$LOG")" $'worktree\x1frm' 'retirement treated home as disposable worker'
  assert_contains "$(cat "$LOG")" $'setup-delete' 'retry after late refusal did not release owned Orca registrations'
  rm -rf "/tmp/fm-$id" "$(dirname "$staged")"
  pass "Orca secondmate launches once, preserves child/close guards, and retires its persistent home safely"
}

test_spawn_orca_secondmate_unbound_terminal_retains_receipt() {
  local home subhome id out rc
  id=orcasmub
  home="$TMP_ROOT/secondmate-unbound-primary"
  subhome="$TMP_ROOT/secondmate-unbound-home"
  fm_git_init_commit "$subhome"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects" \
    "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  printf 'Idle test charter.\n' > "$subhome/data/charter.md"
  printf 'manual\n' > "$home/config/backlog-backend"
  touch "$home/state/.last-watcher-beat"
  orca_case secondmate-unbound-spawn
  printf '{"ok":false,"error":{"code":"repo_not_found"}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"repo":{"id":"repo-smub"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"repo-smub::%s","path":"%s","repoId":"repo-smub","isMainWorktree":true}}}\n' "$subhome" "$subhome" > "$RESP/3.out"
  home_setup_response "$subhome" repo-smub
  cp "$RESP/3.out" "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-elsewhere"}}}\n' > "$RESP/5.out"
  printf '{"ok":true,"result":{"terminals":[],"totalCount":0,"truncated":false,"hostScope":{"omittedHostIds":[]}}}\n' > "$RESP/6.out"
  cp "$RESP/6.out" "$RESP/7.out"
  cp "$RESP/6.out" "$RESP/8.out"
  if out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend orca --secondmate 2>&1 ); then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "secondmate spawn accepted a terminal absent from its home workspace"
  assert_contains "$out" 'not bound to its home workspace' 'unbound terminal refusal missing'
  assert_grep 'terminal=term-elsewhere' "$subhome/state/orca-secondmate-launch" 'unbound terminal dropped its launch receipt'
  assert_not_contains "$(cat "$LOG")" $'terminal\x1fclose' 'unbound terminal was treated as a closable home endpoint'
  assert_absent "$home/state/$id.meta" 'unbound terminal published metadata'
  assert_present "$subhome/.fm-secondmate-home" 'unbound terminal removed home'
  : > "$LOG"
  if out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend orca --secondmate 2>&1 ); then
    fail "duplicate Orca secondmate spawn succeeded after unbound terminal"
  fi
  assert_contains "$out" 'unfinished Orca secondmate launch' 'retained receipt did not refuse duplicate launch'
  assert_not_contains "$(cat "$LOG")" $'terminal\x1fcreate' 'duplicate launch created another terminal'
  pass "Orca secondmate spawn retains its receipt when the returned terminal is not bound to its home"
}

test_spawn_refuses_orca_when_runtime_not_ready() {
  local proj data state config id out status
  id="orcaruntimez6"
  proj="$TMP_ROOT/runtime-down-project"
  data="$TMP_ROOT/runtime-down-data"
  state="$TMP_ROOT/runtime-down-state"
  config="$TMP_ROOT/runtime-down-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case runtime-down-spawn
  printf '{"ok":true,"result":{"runtime":{"reachable":false,"state":"starting"}}}\n' > "$RESP/1.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh --backend orca should refuse when Orca runtime is not ready"
  assert_contains "$out" "requires a ready Orca runtime" \
    "runtime readiness refusal should explain the Orca requirement"
  assert_absent "$state/$id.meta" "runtime refusal must not record metadata"
  assert_contains "$(cat "$LOG")" $'orca\x1f''status'$'\x1f''--json' \
    "spawn did not probe Orca runtime readiness"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''repo' \
    "spawn should fail before repo/worktree creation when runtime is not ready"
  pass "fm-spawn.sh --backend orca: refuses before mutation when Orca runtime is not ready"
}

test_spawn_refuses_orca_nonisolated_worktree() {
  local proj data state config id out status
  id="orcabadwtz4"
  proj="$TMP_ROOT/bad-spawn-project"
  data="$TMP_ROOT/bad-spawn-data"
  state="$TMP_ROOT/bad-spawn-state"
  config="$TMP_ROOT/bad-spawn-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case bad-spawn
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-bad"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-bad::/orca/wt-bad","path":"%s"},"terminal":{"handle":"term-bad"}}}\n' "$proj" > "$RESP/3.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  expect_code 1 "$status" "fm-spawn.sh --backend orca should refuse a primary checkout worktree"
  assert_contains "$out" "orca worktree create did not yield an isolated worktree" \
    "Orca spawn should reuse the isolated-worktree guard"
  assert_absent "$state/$id.meta" "aborted Orca spawn must not record meta"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create' \
    "Orca spawn should validate the worktree before creating a terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-bad'$'\x1f''--json' \
    "Orca spawn should close the implicit terminal after validation aborts"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-bad::/orca/wt-bad'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the worktree after validation aborts"
  pass "fm-spawn.sh --backend orca: refuses non-isolated worktrees and closes implicit terminals"
}

test_spawn_removes_orca_worktree_when_terminal_create_fails() {
  local proj wt data state config id out status
  id="orcatermfailz8"
  proj="$TMP_ROOT/terminal-fail-project"
  wt="$TMP_ROOT/terminal-fail-wt"
  data="$TMP_ROOT/terminal-fail-data"
  state="$TMP_ROOT/terminal-fail-state"
  config="$TMP_ROOT/terminal-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case terminal-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-terminal-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-terminal-fail::/orca/wt-terminal-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '1\n' > "$RESP/4.exit"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when terminal creation fails"
  assert_absent "$state/$id.meta" "terminal-create abort should not record metadata after successful cleanup"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f''id:wt-terminal-fail::/orca/wt-terminal-fail'$'\x1f''--title'$'\x1f'"fm-$id"$'\x1f''--json' \
    "Orca spawn should attempt terminal creation before abort cleanup"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-terminal-fail::/orca/wt-terminal-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the worktree when terminal creation fails"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "Orca spawn should not close a terminal when no handle was recorded"
  pass "fm-spawn.sh --backend orca: removes worktree when terminal creation fails"
}

test_spawn_preserves_orca_metadata_when_abort_cleanup_fails() {
  local proj wt data state config id out status
  id="orcacleanupleakz0"
  proj="$TMP_ROOT/cleanup-fail-project"
  wt="$TMP_ROOT/cleanup-fail-wt"
  data="$TMP_ROOT/cleanup-fail-data"
  state="$TMP_ROOT/cleanup-fail-state"
  config="$TMP_ROOT/cleanup-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case cleanup-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-cleanup-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-cleanup-fail::/orca/wt-cleanup-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '1\n' > "$RESP/4.exit"
  printf '1\n' > "$RESP/5.exit"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when terminal creation and abort cleanup fail"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-cleanup-fail::/orca/wt-cleanup-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should attempt helper cleanup before preserving metadata"
  assert_present "$state/$id.meta" "failed Orca abort cleanup should preserve metadata"
  assert_grep "window=fm-$id" "$state/$id.meta" "preserved metadata missing stable window alias"
  assert_grep "backend=orca" "$state/$id.meta" "preserved metadata missing backend=orca"
  assert_grep "orca_worktree_id=wt-cleanup-fail::/orca/wt-cleanup-fail" "$state/$id.meta" "preserved metadata missing Orca worktree id"
  assert_no_grep "terminal=" "$state/$id.meta" "preserved metadata should not invent a terminal handle"
  pass "fm-spawn.sh --backend orca: preserves metadata when abort cleanup fails"
}

test_spawn_releases_orca_resources_when_metadata_write_fails() {
  local proj wt data state config id out status
  id="orcametafailz9"
  proj="$TMP_ROOT/meta-fail-project"
  wt="$TMP_ROOT/meta-fail-wt"
  data="$TMP_ROOT/meta-fail-data"
  state="$TMP_ROOT/meta-fail-state"
  config="$TMP_ROOT/meta-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state/$id.meta" "$config"
  write_spawn_brief "$data" "$id"
  orca_case meta-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-meta-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-meta-fail::/orca/wt-meta-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-meta-fail"}}}\n' > "$RESP/4.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when metadata cannot be written"
  assert_contains "$out" "task record for $id could not be published" \
    "spawn should report metadata publication failure without relying on platform-specific mv output"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-meta-fail'$'\x1f''--json' \
    "Orca spawn should close the recorded terminal when a later abort occurs"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-meta-fail::/orca/wt-meta-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the recorded worktree when a later abort occurs"
  [ ! -f "$state/$id.meta" ] || fail "metadata-write abort should not publish a regular metadata file"
  pass "fm-spawn.sh --backend orca: releases terminal and worktree on later aborts"
}

test_peek_send_and_crew_state_route_through_orca_meta() {
  local wt state id out neutral record body
  id="orcaiopathz2"
  wt="$TMP_ROOT/io-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/io-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-io" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
  touch "$state/.last-watcher-beat"
  orca_case io-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  printf '{"ok":true,"result":{"terminal":{"tail":["ready"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-peek.sh" "fm-$id" 10 )
  [ "$out" = ready ] || fail "fm-peek should read through Orca metadata, got '$out'"
  printf '{"ok":true,"result":{"send":{"handle":"term-io","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-io","accepted":true}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/4.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "fm-$id" "hello orca"
  printf '{"ok":true,"result":{"terminal":{"tail":["idle prompt"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
  assert_contains "$out" "state: unknown" "crew-state should fall back cleanly for an idle Orca scout"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-io' \
    "peek/crew-state did not read the recorded Orca terminal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f'"fm-$id" \
    "crew-state should not read the stable Orca alias as a terminal handle"
  record="$state/$id.inbox/001.msg"
  [ -f "$record" ] || fail "send did not enqueue through the task inbox"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$record")
  [ "$body" = "hello orca" ] || fail "Orca task inbox did not preserve the send body, got '$body'"
  assert_not_contains "$(cat "$LOG")" $'--text\x1fhello orca\x1f' \
    "send typed the payload instead of recording it"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-io'$'\x1f''--text'$'\x1f'': Firstmate instruction waiting:' \
    "send did not ring the inbox doorbell through the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-io'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send did not submit the doorbell through the recorded Orca terminal"
  pass "fm-peek/fm-send/fm-crew-state route through backend=orca metadata and its durable inbox"
}

test_peek_and_crew_state_fail_closed_on_orca_error_json() {
  local wt state id out status neutral
  id="orcareaderrz7"
  wt="$TMP_ROOT/read-error-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/read-error-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-stale" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
  touch "$state/.last-watcher-beat"
  orca_case read-error-json
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-peek.sh" "fm-$id" 10 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-peek should fail when Orca reports a stale terminal"
  assert_contains "$out" "terminal handle stale" "fm-peek should surface the Orca read error message"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/2.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
  assert_contains "$out" "state: unknown" "crew-state should not treat an Orca read error as a live endpoint"
  assert_contains "$out" "backend target gone: term-stale" "crew-state should report the stale Orca terminal as gone"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-stale' \
    "fm-peek/fm-crew-state did not read the recorded Orca terminal"
  pass "fm-peek/fm-crew-state: Orca read error JSON fails closed"
}

test_target_exists_rejects_orca_error_json() {
  local status
  orca_case target-exists-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  set +e
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_exists orca term-stale fm-task' "$ROOT"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "fm_backend_target_exists should reject Orca ok:false read JSON"
  pass "fm_backend_target_exists: Orca ok:false read JSON is not live"
}

test_scout_teardown_removes_orca_worktree_via_helper() {
  local proj wt data state config id out rc neutral
  id="orcateardownz3"
  proj="$TMP_ROOT/teardown-project"
  wt="$TMP_ROOT/teardown-wt"
  data="$TMP_ROOT/teardown-data"
  state="$TMP_ROOT/teardown-state"
  config="$TMP_ROOT/teardown-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-teardown" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-teardown::/orca/wt-teardown" \
    "decisions_reviewed=1" "decision_keys="
  orca_case teardown
  printf '{"ok":true,"result":{"worktree":{"id":"wt-teardown::/orca/wt-teardown","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca scout teardown should succeed once report exists"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-teardown'$'\x1f''--json' \
    "teardown did not close the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-teardown::/orca/wt-teardown'$'\x1f''--force'$'\x1f''--json' \
    "teardown did not remove the Orca worktree through orca worktree rm"
  assert_absent "$state/$id.meta" "teardown should remove task metadata"
  pass "fm-teardown.sh backend=orca: scout report gate then helper-backed worktree removal"
}

test_scout_teardown_refuses_orca_id_path_mismatch() {
  local proj wt other_wt data state config id out rc neutral
  id="orcascoutmismatchz5"
  proj="$TMP_ROOT/scout-mismatch-project"
  wt="$TMP_ROOT/scout-mismatch-wt"
  other_wt="$TMP_ROOT/scout-mismatch-other-wt"
  data="$TMP_ROOT/scout-mismatch-data"
  state="$TMP_ROOT/scout-mismatch-state"
  config="$TMP_ROOT/scout-mismatch-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$proj" worktree add --quiet -b "fm/$id-other" "$other_wt"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-scout-mismatch" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-scout-mismatch::/orca/wt-scout-mismatch" \
    "decisions_reviewed=1" "decision_keys="
  orca_case scout-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-scout-mismatch::/orca/wt-scout-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca scout teardown should refuse when id path differs from worktree="
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca scout worktree path refusal should name the mismatch"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca scout teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca scout teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused mismatched scout teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: scout teardown refuses id/path mismatches"
}

test_teardown_removes_orca_worktree_when_path_missing() {
  local proj wt data state config id out rc neutral
  id="orcamissingpathz7"
  proj="$TMP_ROOT/missing-path-project"
  wt="$TMP_ROOT/missing-path-wt"
  data="$TMP_ROOT/missing-path-data"
  state="$TMP_ROOT/missing-path-state"
  config="$TMP_ROOT/missing-path-config"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-path" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-path::/orca/wt-missing-path" \
    "decisions_reviewed=1" "decision_keys="
  orca_case missing-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca teardown should release helpers even when the path is absent"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-missing-path'$'\x1f''--json' \
    "teardown did not close the recorded Orca terminal when the path was absent"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-missing-path::/orca/wt-missing-path'$'\x1f''--force'$'\x1f''--json' \
    "teardown did not remove the recorded Orca worktree when the path was absent"
  assert_absent "$state/$id.meta" "successful helper cleanup should remove task metadata"
  pass "fm-teardown.sh backend=orca: releases terminal/worktree when path is absent"
}

test_teardown_preserves_metadata_when_orca_remove_error_json() {
  local proj wt data state config id out rc neutral
  id="orcaremoveerrz2"
  proj="$TMP_ROOT/remove-error-project"
  wt="$TMP_ROOT/remove-error-wt"
  data="$TMP_ROOT/remove-error-data"
  state="$TMP_ROOT/remove-error-state"
  config="$TMP_ROOT/remove-error-config"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-remove-error" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-remove-error::/orca/wt-remove-error" \
    "decisions_reviewed=1" "decision_keys="
  orca_case remove-error-teardown
  printf '{"ok":true,"result":{}}\n' > "$RESP/1.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/2.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown should fail when worktree removal returns ok:false JSON"
  assert_contains "$out" "worktree not removed" "teardown should surface the Orca removal error"
  assert_present "$state/$id.meta" "failed Orca removal should preserve task metadata"
  pass "fm-teardown.sh backend=orca: preserves metadata on remove ok:false JSON"
}

test_scout_teardown_refuses_orca_missing_report_when_path_missing() {
  local proj wt data state config id out rc neutral
  id="orcanoreportz4"
  proj="$TMP_ROOT/missing-report-project"
  wt="$TMP_ROOT/missing-report-wt"
  data="$TMP_ROOT/missing-report-data"
  state="$TMP_ROOT/missing-report-state"
  config="$TMP_ROOT/missing-report-config"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-report" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-report::/orca/wt-missing-report"
  orca_case missing-report
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca scout teardown should refuse without a report even when the path is absent"
  assert_contains "$out" "has no report" "Orca scout teardown should explain the missing report"
  [ ! -s "$LOG" ] || fail "refused Orca scout teardown should not close terminals or remove worktrees"
  assert_present "$state/$id.meta" "refused Orca scout teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: scout report gate precedes pathless helper cleanup"
}

test_ship_teardown_refuses_orca_missing_worktree_path() {
  local proj wt data state config id out rc neutral
  id="orcashipmissingz8"
  proj="$TMP_ROOT/missing-ship-project"
  wt="$TMP_ROOT/missing-ship-wt"
  data="$TMP_ROOT/missing-ship-data"
  state="$TMP_ROOT/missing-ship-state"
  config="$TMP_ROOT/missing-ship-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-ship" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-ship::/orca/wt-missing-ship"
  orca_case missing-ship-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse a missing worktree path"
  assert_contains "$out" "no inspectable git worktree" \
    "Orca ship teardown should explain the fail-closed worktree requirement"
  [ ! -s "$LOG" ] || fail "refused Orca ship teardown should not close terminals or remove worktrees"
  assert_present "$state/$id.meta" "refused Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown fails closed when worktree path is missing"
}

test_ship_teardown_removes_orca_worktree_when_id_path_matches() {
  local proj wt data state config id out rc neutral
  id="orcashipmatchz2"
  proj="$TMP_ROOT/ship-match-project"
  wt="$TMP_ROOT/ship-match-wt"
  data="$TMP_ROOT/ship-match-data"
  state="$TMP_ROOT/ship-match-state"
  config="$TMP_ROOT/ship-match-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-match" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-match::/orca/wt-ship-match"
  orca_case ship-match
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-match::/orca/wt-ship-match","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca ship teardown should succeed when the id path matches the inspected worktree"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-match::/orca/wt-ship-match'$'\x1f''--json' \
    "teardown did not resolve the Orca worktree id before removal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-ship-match'$'\x1f''--json' \
    "teardown did not close the matched Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-ship-match::/orca/wt-ship-match'$'\x1f''--force'$'\x1f''--json' \
    "teardown did not remove the matched Orca worktree"
  assert_absent "$state/$id.meta" "successful matched teardown should remove task metadata"
  pass "fm-teardown.sh backend=orca: ship teardown requires a matching Orca id path"
}

test_ship_teardown_refuses_orca_unresolvable_worktree_id() {
  local proj wt data state config id out rc neutral
  id="orcashipunresolvedz1"
  proj="$TMP_ROOT/ship-unresolved-project"
  wt="$TMP_ROOT/ship-unresolved-wt"
  data="$TMP_ROOT/ship-unresolved-data"
  state="$TMP_ROOT/ship-unresolved-state"
  config="$TMP_ROOT/ship-unresolved-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-unresolved" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-unresolved::/orca/wt-ship-unresolved"
  orca_case ship-unresolved
  printf '1\n' > "$RESP/1.exit"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse when the worktree id cannot be resolved"
  assert_contains "$out" "cannot resolve Orca worktree id wt-ship-unresolved::/orca/wt-ship-unresolved" \
    "unresolvable Orca worktree id refusal should explain the fail-closed check"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-unresolved::/orca/wt-ship-unresolved'$'\x1f''--json' \
    "teardown did not attempt to resolve the Orca worktree id"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused unresolved Orca ship teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused unresolved Orca ship teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused unresolved Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown fails closed when id resolution fails"
}

test_ship_teardown_refuses_orca_id_path_mismatch() {
  local proj wt other_wt data state config id out rc neutral
  id="orcashipmismatchz9"
  proj="$TMP_ROOT/ship-mismatch-project"
  wt="$TMP_ROOT/ship-mismatch-wt"
  other_wt="$TMP_ROOT/ship-mismatch-other-wt"
  data="$TMP_ROOT/ship-mismatch-data"
  state="$TMP_ROOT/ship-mismatch-state"
  config="$TMP_ROOT/ship-mismatch-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$proj" worktree add --quiet -b "fm/$id-other" "$other_wt"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-mismatch" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-mismatch::/orca/wt-ship-mismatch"
  orca_case ship-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-mismatch::/orca/wt-ship-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse when the id path differs from worktree="
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca worktree path refusal should name the mismatch"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-mismatch::/orca/wt-ship-mismatch'$'\x1f''--json' \
    "teardown did not resolve the mismatched Orca worktree id"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca ship teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca ship teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused mismatched Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown refuses id/path mismatches"
}

test_teardown_refuses_orca_missing_worktree_id() {
  local proj wt data state config id out rc neutral
  id="orcamissingidz5"
  proj="$TMP_ROOT/missing-id-project"
  wt="$TMP_ROOT/missing-id-wt"
  data="$TMP_ROOT/missing-id-data"
  state="$TMP_ROOT/missing-id-state"
  config="$TMP_ROOT/missing-id-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" "backend=orca" \
    "decisions_reviewed=1" "decision_keys="
  orca_case missing-id
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown should refuse missing orca_worktree_id"
  assert_contains "$out" "missing orca_worktree_id" "teardown did not explain the missing Orca worktree id"
  assert_present "$state/$id.meta" "failed teardown must preserve task metadata"
  [ ! -s "$LOG" ] || fail "teardown should fail before closing terminals or removing worktrees without an Orca worktree id"
  pass "fm-teardown.sh backend=orca: refuses missing worktree ids before cleanup"
}

test_teardown_refuses_orca_worktree_without_terminal_handle() {
  local proj wt data state config id out rc neutral
  id="orcanotermz0"
  proj="$TMP_ROOT/no-terminal-project"
  wt="$TMP_ROOT/no-terminal-wt"
  data="$TMP_ROOT/no-terminal-data"
  state="$TMP_ROOT/no-terminal-state"
  config="$TMP_ROOT/no-terminal-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-no-terminal::/orca/wt-no-terminal" \
    "decisions_reviewed=1" "decision_keys="
  orca_case no-terminal
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown accepted metadata without a terminal handle"
  assert_contains "$out" "missing terminal" "teardown did not explain the incomplete Orca endpoint"
  [ ! -s "$LOG" ] || fail "teardown dispatched to Orca before rejecting the incomplete endpoint"
  assert_present "$state/$id.meta" "missing-terminal refusal removed task metadata"
  pass "fm-teardown.sh backend=orca: refuses incomplete worktree-only endpoint metadata before runtime dispatch"
}

test_secondmate_force_teardown_removes_orca_child_via_orca() {
  local home subhome childproj childwt child_id neutral out rc
  home="$TMP_ROOT/orca-child-parent"
  subhome="$TMP_ROOT/orca-child-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-child-worktree"
  child_id="orcachildz6"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "terminal=term-child-cleanup" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-child-cleanup::/orca/wt-child-cleanup"
  orca_case secondmate-child-cleanup
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-cleanup::/orca/wt-child-cleanup","path":"%s"}}}\n' "$childwt" > "$RESP/1.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-cleanup::/orca/wt-child-cleanup","path":"%s"}}}\n' "$childwt" > "$RESP/2.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/4.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "forced secondmate teardown should remove Orca child work through Orca"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-child-cleanup'$'\x1f''--json' \
    "child cleanup did not close the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-child-cleanup::/orca/wt-child-cleanup'$'\x1f''--force'$'\x1f''--json' \
    "child cleanup did not remove the Orca worktree through orca worktree rm"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f'"fm-$child_id" \
    "child cleanup closed the stable alias instead of the Orca terminal"
  assert_absent "$home/state/domain.meta" "parent metadata should be removed after forced teardown"
  pass "fm-teardown.sh --force: removes Orca secondmate children through Orca"
}

test_secondmate_force_teardown_refuses_orca_child_id_path_mismatch() {
  local home subhome childproj childwt other_wt child_id neutral out rc
  home="$TMP_ROOT/orca-child-mismatch-parent"
  subhome="$TMP_ROOT/orca-child-mismatch-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-child-mismatch-worktree"
  other_wt="$TMP_ROOT/orca-child-mismatch-other-worktree"
  child_id="orcachildmismatchz1"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  git -C "$childproj" worktree add --quiet -b "fm/$child_id-other" "$other_wt"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "terminal=term-child-mismatch" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-child-mismatch::/orca/wt-child-mismatch"
  orca_case secondmate-child-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-mismatch::/orca/wt-child-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forced secondmate teardown should refuse mismatched Orca child id/path"
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca child worktree path refusal should name the mismatch"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca child cleanup should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca child cleanup should not remove worktrees"
  assert_present "$home/state/domain.meta" "refused forced secondmate teardown should preserve parent metadata"
  pass "fm-teardown.sh --force: refuses Orca child id/path mismatches"
}

test_secondmate_force_teardown_refuses_partial_orca_child() {
  local home subhome childproj childwt child_id neutral out rc
  home="$TMP_ROOT/orca-partial-child-parent"
  subhome="$TMP_ROOT/orca-partial-child-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-partial-child-worktree"
  child_id="orcapartialz9"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca partial child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-partial-child::/orca/wt-partial-child"
  orca_case secondmate-partial-child-cleanup
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forced secondmate teardown accepted a child with no terminal identity"
  assert_contains "$out" "missing terminal" "partial child refusal did not explain the incomplete endpoint"
  [ ! -s "$LOG" ] || fail "partial child refusal dispatched to Orca or tmux"
  assert_present "$home/state/domain.meta" "partial child refusal removed parent metadata"
  assert_present "$subhome/state/$child_id.meta" "partial child refusal removed child metadata"
  pass "fm-teardown.sh --force: refuses partial Orca secondmate children before runtime dispatch"
}

test_dispatcher_sources_orca_and_routes_primitives() {
  local out
  orca_case dispatch
  printf '{"result":{"terminal":{"tail":["via dispatch"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_validate orca; fm_backend_capture orca term-123 9' "$ROOT" )
  [ "$out" = "via dispatch" ] || fail "dispatcher should route capture to the Orca adapter, got '$out'"
  pass "fm-backend dispatcher: accepts orca and routes capture through bin/backends/orca.sh"
}


# These fixture responses model the complete scoped inventory observed on
# Orca 1.4.224. Negative cases deliberately separate PTY presence, task state,
# registration ownership, and receipt completeness.
run_orca_home() {
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; "$@"' "$ROOT" "$@"
}

home_setup_response() { # <path> <repo>
  python3 - "$RESP/setups.json" "$1" "$2" <<'PYSETUP'
import json, sys
from pathlib import Path
file, path, repo = sys.argv[1:]
p = Path(file)
d = json.loads(p.read_text()) if p.exists() else {"ok": True, "result": {"setups": []}}
d['result']['setups'] = [s for s in d['result']['setups'] if s['path'] != path]
d['result']['setups'].append({"id": repo, "repoId": repo, "hostId": "local", "path": path, "setupState": "ready"})
p.write_text(json.dumps(d))
PYSETUP
}

home_root_response() { # <home> <file>
  home_setup_response "$1" repo-home
  printf '{"ok":true,"result":{"worktree":{"id":"repo-home::%s","path":"%s","repoId":"repo-home","isMainWorktree":true}}}\n' "$1" "$1" > "$2"
}

home_inventory_response() { # <home> <present|absent> <file>
  local items='[]' total=0
  if [ "$2" = present ]; then
    items="[{\"handle\":\"term-home\",\"worktreeId\":\"repo-home::$1\"}]"
    total=1
  fi
  printf '{"ok":true,"result":{"terminals":%s,"totalCount":%s,"truncated":false,"hostScope":{"omittedHostIds":[]}}}\n' "$items" "$total" > "$3"
}

make_registered_home() { # <case> <owned|reused>
  orca_case "$1"
  TEST_HOME="$CASE_DIR/home"
  mkdir -p "$TEST_HOME/state" "$TEST_HOME/projects"
  printf 'home-test\n' > "$TEST_HOME/.fm-secondmate-home"
  if [ "$2" = owned ]; then
    printf '{"ok":false,"error":{"code":"repo_not_found"}}\n' > "$RESP/1.out"
    printf '{"ok":true,"result":{"repo":{"id":"repo-home"}}}\n' > "$RESP/2.out"
    home_root_response "$TEST_HOME" "$RESP/3.out"
  else
    printf '{"ok":true,"result":{"repo":{"id":"repo-home"}}}\n' > "$RESP/1.out"
    home_root_response "$TEST_HOME" "$RESP/2.out"
  fi
  run_orca_home fm_backend_orca_home_repo "$TEST_HOME" "$TEST_HOME" >/dev/null || fail 'home registration failed'
  : > "$LOG"
  rm -f "$RESP"/*.out "$RESP/.count"
}

test_home_registration_uncertainty_and_binding() {
  local out
  make_registered_home home-owned owned
  home_root_response "$TEST_HOME" "$RESP/1.out"
  out=$(run_orca_home fm_backend_orca_home_workspace "$TEST_HOME" read) || fail 'recorded home did not resolve'
  [ "$out" = "repo-home::$TEST_HOME" ] || fail 'wrong home workspace'
  home_root_response "$CASE_DIR/foreign" "$RESP/2.out"
  if run_orca_home fm_backend_orca_home_workspace "$TEST_HOME" read >/dev/null 2>&1; then
    fail 'mismatched root path accepted'
  fi
  orca_case home-uncertain
  TEST_HOME="$CASE_DIR/home"
  mkdir -p "$TEST_HOME/state"
  touch "$TEST_HOME/.fm-secondmate-home"
  printf '{"ok":false,"error":{"code":"permission_denied"}}\n' > "$RESP/1.out"
  if run_orca_home fm_backend_orca_home_repo "$TEST_HOME" "$TEST_HOME" >/dev/null 2>&1; then fail 'uncertain lookup accepted'; fi
  assert_not_contains "$(cat "$LOG")" $'repo\x1fadd' 'uncertain read must not register'
  printf '{"ok":false,"error":{"code":"repo_not_found"}}\n' > "$RESP/2.out"
  printf '1\n' > "$RESP/3.exit"
  if run_orca_home fm_backend_orca_home_repo "$TEST_HOME" "$TEST_HOME" >/dev/null 2>&1; then fail 'failed add accepted'; fi
  out=$(cat "$LOG")
  if run_orca_home fm_backend_orca_home_repo "$TEST_HOME" "$TEST_HOME" >/dev/null 2>&1; then fail 'pending add retried blindly'; fi
  [ "$(cat "$LOG")" = "$out" ] || fail 'pending registration should refuse before another runtime call'
  pass 'Orca homes preserve uncertain registrations and reject root identity drift'
}

test_concurrent_first_registrations_keep_ownership() {
  local dir fb home rc_b rc_a
  dir="$TMP_ROOT/home-registration-race"
  fb="$dir/fakebin"
  mkdir -p "$fb" "$dir/home/state"
  home=$(cd "$dir/home" && pwd -P)
  printf 'race\n' > "$home/.fm-secondmate-home"
  printf '{"ok":true,"result":{"setups":[{"id":"repo-race","repoId":"repo-race","hostId":"local","path":"%s","setupState":"ready"}]}}\n' "$home" > "$dir/setups.json"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
S=$FM_RACE_DIR
case "$1:$2" in
  repo:show)
    if [ "${FM_RACE_ROLE:-}" = B ] && [ ! -e "$S/a.started" ]; then
      : > "$S/a.started"
      FM_RACE_ROLE=A PATH="$PATH" bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_home_repo "$1" "$1"; echo $? > "$2/a.rc"' \
        "$FM_RACE_ROOT" "$FM_RACE_HOME" "$S" >"$S/a.log" 2>&1 &
      for _ in $(seq 1 30); do [ -e "$S/a.rc" ] && break; sleep 0.1; done
    fi
    if [ -e "$S/registered" ]; then
      printf '{"ok":true,"result":{"repo":{"id":"repo-race"}}}\n'
    else
      printf '{"ok":false,"error":{"code":"repo_not_found"}}\n'
    fi
    ;;
  repo:add) : > "$S/registered"; printf '{"ok":true,"result":{"repo":{"id":"repo-race"}}}\n' ;;
  project:setups) cat "$S/setups.json" ;;
  worktree:show)
    printf '{"ok":true,"result":{"worktree":{"id":"repo-race::%s","path":"%s","repoId":"repo-race","isMainWorktree":true}}}\n' "$FM_RACE_HOME" "$FM_RACE_HOME" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/orca"
  PATH="$fb:$PATH" FM_RACE_DIR="$dir" FM_RACE_ROOT="$ROOT" FM_RACE_HOME="$home" FM_RACE_ROLE=B \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_home_repo "$1" "$1"' "$ROOT" "$home" >/dev/null 2>"$dir/b.log"
  rc_b=$?
  for _ in $(seq 1 100); do [ -e "$dir/a.rc" ] && break; sleep 0.1; done
  rc_a=$(cat "$dir/a.rc" 2>/dev/null || echo missing)
  expect_code 0 "$rc_b" "second concurrent registration failed: $(cat "$dir/b.log")"
  [ "$rc_a" = 0 ] || fail "first concurrent registration failed ($rc_a): $(cat "$dir/a.log")"
  node -e '
const fs = require("fs"), path = require("path");
const dir = path.join(process.argv[1], "state", "orca-registrations");
const files = fs.readdirSync(dir);
if (files.length !== 1) process.exit(1);
const r = JSON.parse(fs.readFileSync(path.join(dir, files[0]), "utf8"));
process.exit(r.state === "ready" && r.owned === true ? 0 : 1);
' "$home" || fail 'concurrent first registration overwrote owned receipt as reused'
  pass 'Orca home registration serializes concurrent first workers and keeps the created registration owned'
}

test_home_setup_identity_refuses_mismatch() {
  local bad out
  for bad in missing duplicate repo host state changed; do
    make_registered_home "setup-$bad" owned
    home_root_response "$TEST_HOME" "$RESP/1.out"
    python3 - "$RESP/setups.json" "$bad" <<'PYSETUP'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
s = d['result']['setups'][0]
kind = sys.argv[2]
if kind == 'missing': d['result']['setups'] = []
elif kind == 'duplicate': d['result']['setups'].append(dict(s))
else: s[{'repo': 'repoId', 'host': 'hostId', 'state': 'setupState', 'changed': 'id'}[kind]] = 'different'
p.write_text(json.dumps(d))
PYSETUP
    if out=$(run_orca_home fm_backend_orca_home_workspace "$TEST_HOME" read 2>&1); then
      fail "accepted mismatched setup: $bad"
    fi
    assert_contains "$out" 'Orca' "missing setup refusal: $bad"
    assert_not_contains "$(cat "$LOG")" $'project\x1fsetup-delete' 'lookup must not delete registrations'
  done
  pass 'Orca roots bind the separate project setup inventory and refuse missing, ambiguous, or changed identities'
}

test_home_close_requires_complete_scoped_inventory() {
  local shape
  for shape in '{}' '{"ok":true,"result":{}}' '{"ok":false,"error":{"code":"terminal_handle_stale"}}' \
    '{"ok":true,"result":{"terminals":[],"totalCount":0,"truncated":true,"hostScope":{"omittedHostIds":[]}}}' \
    '{"ok":true,"result":{"terminals":[],"totalCount":1,"truncated":false,"hostScope":{"omittedHostIds":[]}}}'; do
    orca_case "close-bad-$RANDOM"
    printf '%s\n' "$shape" > "$RESP/1.out"
    if run_orca_home fm_backend_orca_close_confirmed 'repo-home::/home' term-home >/dev/null 2>&1; then fail 'uncertain close accepted'; fi
    assert_not_contains "$(cat "$LOG")" $'terminal\x1fclose' 'uncertain inventory must refuse before close'
  done
  orca_case close-confirmed
  home_inventory_response /home present "$RESP/1.out"
  printf '{"ok":true}\n' > "$RESP/2.out"
  home_inventory_response /home absent "$RESP/3.out"
  run_orca_home fm_backend_orca_close_confirmed 'repo-home::/home' term-home || fail 'confirmed close refused'
  assert_contains "$(cat "$LOG")" $'terminal\x1fclose' 'confirmed close did not close terminal'
  orca_case close-retained
  home_inventory_response /home present "$RESP/1.out"
  printf '{"ok":true}\n' > "$RESP/2.out"
  for shape in 3 4 5 6 7; do home_inventory_response /home present "$RESP/$shape.out"; done
  if run_orca_home fm_backend_orca_close_confirmed 'repo-home::/home' term-home >/dev/null 2>&1; then fail 'accepted close without disappearance'; fi
  pass 'Orca home close refuses incomplete inventories and requires positive disappearance'
}

test_home_retirement_ownership_and_retry() {
  local ownership
  for ownership in owned reused; do
    make_registered_home "retire-$ownership" "$ownership"
    printf '{"ok":true,"result":{"repo":{"id":"repo-home"}}}\n' > "$RESP/1.out"
    home_root_response "$TEST_HOME" "$RESP/2.out"
    printf '{"ok":true,"result":{"worktrees":[{"id":"repo-home::%s","isMainWorktree":true}],"totalCount":1,"truncated":false}}\n' "$TEST_HOME" > "$RESP/3.out"
    home_inventory_response "$TEST_HOME" absent "$RESP/4.out"
    printf '{"ok":true}\n' > "$RESP/5.out"
    printf '{"ok":false,"error":{"code":"repo_not_found"}}\n' > "$RESP/6.out"
    run_orca_home fm_backend_orca_home_retire "$TEST_HOME" || fail "retirement failed: $ownership"
    if [ "$ownership" = owned ]; then
      assert_contains "$(cat "$LOG")" $'project\x1fsetup-delete' 'owned registration was retained'
      : > "$LOG"
      run_orca_home fm_backend_orca_home_retire "$TEST_HOME" || fail 'retirement retry failed'
      [ ! -s "$LOG" ] || fail 'released registration was deleted twice'
    else
      assert_not_contains "$(cat "$LOG")" $'project\x1fsetup-delete' 'pre-existing registration was deleted'
    fi
    assert_not_contains "$(cat "$LOG")" $'worktree\x1frm' 'persistent home must never use worktree rm'
    [ -d "$TEST_HOME" ] || fail 'adapter deleted persistent home itself'
  done
  make_registered_home retire-foreign-terminal owned
  printf '{"ok":true,"result":{"repo":{"id":"repo-home"}}}\n' > "$RESP/1.out"
  home_root_response "$TEST_HOME" "$RESP/2.out"
  printf '{"ok":true,"result":{"worktrees":[{"id":"repo-home::%s","isMainWorktree":true}],"totalCount":1,"truncated":false}}\n' "$TEST_HOME" > "$RESP/3.out"
  home_inventory_response "$TEST_HOME" present "$RESP/4.out"
  if run_orca_home fm_backend_orca_home_retire "$TEST_HOME" >/dev/null 2>&1; then fail 'home with remaining terminal retired'; fi
  assert_not_contains "$(cat "$LOG")" $'project\x1fsetup-delete' 'remaining terminal must preserve registration'
  pass 'Orca retirement removes only owned empty registrations and retries idempotently'
}

test_home_worker_stays_independent() {
  local out project
  make_registered_home worker-independent owned
  project="$TEST_HOME/projects/sample"
  mkdir -p "$project"
  home_root_response "$TEST_HOME" "$RESP/1.out"
  printf '{"ok":false,"error":{"code":"repo_not_found"}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"repo":{"id":"repo-child"}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"worktree":{"id":"repo-child::%s","path":"%s","repoId":"repo-child","isMainWorktree":true}}}\n' "$project" "$project" > "$RESP/4.out"
  home_setup_response "$project" repo-child
  printf '{"ok":true,"result":{"worktree":{"id":"repo-child::/worker","path":"/worker"}}}\n' > "$RESP/5.out"
  out=$(run_orca_home fm_backend_orca_worktree_create "$project" child "$TEST_HOME") || fail 'independent worker failed'
  [ "$out" = $'repo-child::/worker\t/worker' ] || fail 'worker result changed'
  assert_contains "$(cat "$LOG")" --no-parent 'secondmate worker must be independent'
  assert_not_contains "$(cat "$LOG")" --parent-worktree 'secondmate worker must not claim cross-repository lineage'
  pass 'secondmate workers stay independent in their registered project repository'
}


test_spawn_secondmate_worker_labels() {
  local project wt id out label staged
  id=orcalabelworkerz1
  make_registered_home worker-label-spawn owned
  project="$TEST_HOME/projects/sample"
  wt="$CASE_DIR/worker"
  fm_git_worktree "$project" "$wt" "fm/$id"
  mkdir -p "$TEST_HOME/data/$id" "$TEST_HOME/config"
  printf 'manual\n' > "$TEST_HOME/config/backlog-backend"
  printf 'worktree=repo-home::%s\nterminal=term-home\n' "$TEST_HOME" > "$TEST_HOME/state/orca-secondmate-launch"
  write_spawn_brief "$TEST_HOME/data" "$id"
  touch "$TEST_HOME/state/.last-watcher-beat"
  label="2ndmate-home-test · fm-$id"
  home_root_response "$TEST_HOME" "$RESP/1.out"
  printf '{"ok":false,"error":{"code":"repo_not_found"}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"repo":{"id":"repo-child"}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"worktree":{"id":"repo-child::%s","path":"%s","repoId":"repo-child","isMainWorktree":true}}}\n' "$project" "$project" > "$RESP/4.out"
  home_setup_response "$project" repo-child
  printf '{"ok":true,"result":{"worktree":{"id":"repo-child::%s","path":"%s"},"terminal":{"handle":"term-child"}}}\n' "$wt" "$wt" > "$RESP/5.out"
  printf '{"ok":true}\n' > "$RESP/6.out"
  cp "$RESP/6.out" "$RESP/7.out"
  printf '{"ok":true,"result":{"worktree":{"id":"repo-child::%s","displayName":"%s","parentWorktreeId":null,"lineage":null}}}\n' "$wt" "$label" > "$RESP/8.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-child","worktreeId":"repo-child::%s","title":"%s"}}}\n' "$wt" "$label" > "$RESP/9.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TEST_HOME" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" claude --scout --backend orca 2>&1 )
  expect_code 0 $? "labelled secondmate worker spawn failed: $out"
  assert_grep 'terminal=term-child' "$TEST_HOME/state/$id.meta" 'labelled worker metadata lost its terminal'
  assert_contains "$(cat "$LOG")" $'--display-name\x1f'"$label" 'worker worktree label missing'
  assert_contains "$(cat "$LOG")" $'terminal\x1frename\x1f--terminal\x1fterm-child\x1f--title\x1f'"$label" 'worker custom terminal label missing'
  assert_contains "$(cat "$LOG")" --no-parent 'worker did not request independent placement'
  assert_not_contains "$(cat "$LOG")" --parent-worktree 'worker claimed a parent relationship'
  staged=$(tr '\037' '\n' < "$LOG" | sed -n "s/^\. '\([^']*\)'$/\1/p" | tail -1)
  rm -rf "/tmp/fm-$id"
  [ -z "$staged" ] || rm -rf "$(dirname "$staged")"
  pass 'fm-spawn labels both secondmate worker surfaces and confirms no false parent'
}

test_worker_label_postconditions_fail_closed() {
  local bad
  for bad in parent lineage missing-parent worktree-label terminal-label terminal-binding; do
    orca_case "worker-label-$bad"
    python3 - "$RESP" "$bad" <<'PYLABEL'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); bad=sys.argv[2]
w={'id':'repo-child::/worker','displayName':'2ndmate-proof · fm-test','parentWorktreeId':None,'lineage':None}
t={'handle':'term-child','worktreeId':w['id'],'title':w['displayName']}
if bad=='parent': w['parentWorktreeId']='repo-other::/home'
elif bad=='lineage': w['lineage']={'parentWorktreeId':'repo-other::/home'}
elif bad=='missing-parent': del w['parentWorktreeId']
elif bad=='worktree-label': w['displayName']='wrong'
elif bad=='terminal-label': t['title']='wrong'
elif bad=='terminal-binding': t['worktreeId']='repo-other::/worker'
for n,d in enumerate([{'ok':True},{'ok':True},{'ok':True,'result':{'worktree':w}},{'ok':True,'result':{'terminal':t}}],1):
 (p/f'{n}.out').write_text(json.dumps(d))
PYLABEL
    if run_orca_home fm_backend_orca_label_worker 'repo-child::/worker' term-child '2ndmate-proof · fm-test' >/dev/null 2>&1; then
      fail "accepted unconfirmed worker placement or label: $bad"
    fi
  done
  pass 'Orca worker labels refuse false or missing parent postconditions and mismatched visible identities'
}


test_partial_home_terminal_create_retains_identity() {
  local out rc receipt
  orca_case partial-home-terminal
  receipt="$CASE_DIR/attempt"
  printf 'terminal=pending\n' > "$receipt"
  printf '{"ok":false,"result":{"terminal":{"handle":"term-partial"}},"error":{"code":"outcome_unknown"}}\n' > "$RESP/1.out"
  printf '1\n' > "$RESP/1.exit"
  if out=$(run_orca_home fm_backend_orca_terminal_create 'repo-home::/home' secondmate "$receipt"); then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail 'failed terminal creation was accepted'
  [ "$out" = term-partial ] || fail 'partial creation lost terminal identity'
  assert_grep 'terminal=term-partial' "$receipt" 'partial terminal identity was not durable'
  assert_grep 'worktree=repo-home::/home' "$receipt" 'partial receipt lost workspace'
  pass 'failed secondmate terminal creation retains its returned identity for exact cleanup'
}

test_capture_reads_terminal_tail_json
test_capture_falls_back_to_text_fields
test_capture_fails_on_orca_error_json
test_runtime_check_accepts_ready_orca_status
test_runtime_check_refuses_unready_orca_status
test_send_text_submit_verifies_empty_composer_after_enter
test_send_text_submit_borderless_claude_confirms
test_composer_state_stale_banner_never_wins
test_send_text_submit_retries_when_composer_stays_pending
test_composer_state_popup_placeholder_fill_is_pending
test_composer_state_bare_shell_prompt_is_unknown
test_send_text_submit_popup_autocomplete_requires_second_enter
test_send_literal_constructs_non_enter_send
test_send_text_submit_reports_send_failed
test_send_helpers_reject_orca_error_json
test_send_key_enter_and_interrupt
test_send_key_refuses_unknown_key
test_send_key_refuses_escape_until_supported
test_kill_is_best_effort_close
test_kill_refuses_when_the_orca_cli_is_absent
test_remove_worktree_refuses_empty_id
test_remove_worktree_rejects_orca_error_json
test_worktree_path_resolves_id
test_dispatcher_sources_orca_and_routes_primitives
test_json_get_ignores_undocumented_terminal_id_shapes
test_worktree_and_terminal_helpers_parse_json
test_worktree_create_removes_worktree_when_path_missing
test_spawn_preserves_orca_metadata_when_pathless_worktree_cleanup_fails
test_spawn_writes_orca_metadata_and_launches_harness
test_spawn_orca_secondmate_reuses_seeded_home
test_spawn_orca_secondmate_unbound_terminal_retains_receipt
test_spawn_refuses_orca_when_runtime_not_ready
test_spawn_refuses_orca_nonisolated_worktree
test_spawn_removes_orca_worktree_when_terminal_create_fails
test_spawn_preserves_orca_metadata_when_abort_cleanup_fails
test_spawn_releases_orca_resources_when_metadata_write_fails
test_peek_send_and_crew_state_route_through_orca_meta
test_peek_and_crew_state_fail_closed_on_orca_error_json
test_target_exists_rejects_orca_error_json
test_scout_teardown_removes_orca_worktree_via_helper
test_scout_teardown_refuses_orca_id_path_mismatch
test_teardown_removes_orca_worktree_when_path_missing
test_teardown_preserves_metadata_when_orca_remove_error_json
test_scout_teardown_refuses_orca_missing_report_when_path_missing
test_ship_teardown_refuses_orca_missing_worktree_path
test_ship_teardown_removes_orca_worktree_when_id_path_matches
test_ship_teardown_refuses_orca_unresolvable_worktree_id
test_ship_teardown_refuses_orca_id_path_mismatch
test_teardown_refuses_orca_missing_worktree_id
test_teardown_refuses_orca_worktree_without_terminal_handle
test_secondmate_force_teardown_removes_orca_child_via_orca
test_secondmate_force_teardown_refuses_orca_child_id_path_mismatch
test_secondmate_force_teardown_refuses_partial_orca_child

test_home_registration_uncertainty_and_binding
test_concurrent_first_registrations_keep_ownership
test_home_setup_identity_refuses_mismatch
test_home_close_requires_complete_scoped_inventory
test_home_retirement_ownership_and_retry
test_home_worker_stays_independent
test_spawn_secondmate_worker_labels
test_worker_label_postconditions_fail_closed

test_partial_home_terminal_create_retains_identity
