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
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
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

test_spawn_refuses_orca_secondmate_before_home_mutation() {
  local home subhome data state config id out status
  id="orcasmz1"
  home="$TMP_ROOT/secondmate-refusal-home"
  subhome="$TMP_ROOT/secondmate-refusal-subhome"
  data="$home/data"
  state="$home/state"
  config="$home/config"
  mkdir -p "$data" "$state" "$config" "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  printf 'claude\n' > "$config/crew-harness"
  touch "$state/.last-watcher-beat"
  set +e
  out=$( FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend orca --secondmate 2>&1 )
  status=$?
  set +e
  [ "$status" -ne 0 ] || fail "backend=orca --secondmate should be refused"
  assert_contains "$out" "backend=orca does not support --secondmate spawns yet" \
    "orca secondmate refusal should happen at backend selection"
  assert_absent "$subhome/config/crew-harness" \
    "orca secondmate refusal should not propagate inherited local material into the secondmate home"
  pass "fm-spawn.sh --backend orca --secondmate: refuses before secondmate-home mutation"
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

# --- send-time live-window resolution (task fm-send-orca-window-target) -----
#
# A human restart hands a window a FRESH Orca handle while window= (the Orca
# worktree name) stays stable, so the recorded terminal= goes stale and every
# send on it is rejected (live evidence: android-compare-slice3, recorded
# term_67a6b02e exited, live term_33db5d3e, both under window
# fm-android-compare-slice3). The submit and send-key cores must re-resolve
# window= at send time through Orca's native `--worktree name:<window>`
# selector, write NO meta file, keep a healthy terminal's command sequence
# byte-identical (resolution runs only after an endpoint-identity rejection),
# and fall back to today's recorded-handle failure - the durable doorbell
# notice plus the watcher re-ring - whenever the window cannot be resolved.

write_orca_window_meta() {  # <state-dir> <id> <terminal> <worktree>
  local state=$1 id=$2 terminal=$3 wt=$4
  mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=$terminal" \
    "worktree=$wt" "project=$wt" "harness=claude" "kind=ship" "backend=orca"
}

test_send_text_submit_resolves_live_window_when_terminal_stale() {
  local state out log_text
  orca_case submit-stale-window
  state=$CASE_DIR/state
  write_orca_window_meta "$state" stalewinz1 term-stale "$CASE_DIR/worktree"
  printf '{"ok":false,"error":{"code":"terminal_not_writable","message":"terminal_not_writable"}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"terminals":[{"handle":"term-live-9","writable":true,"connected":true}]}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-live-9","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-live-9","accepted":true}}}\n' > "$RESP/5.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭───╮","│ > │","╰───╯"]}}}\n' > "$RESP/6.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-stale "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "stale-terminal submit should confirm through the live window, got '$out'"
  log_text=$(cat "$LOG")
  assert_contains "$log_text" $'orca\x1fterminal\x1flist\x1f--worktree\x1fname:fm-stalewinz1\x1f--limit\x1f200\x1f--json' \
    "submit did not re-resolve the recorded window through Orca's name: selector"
  assert_contains "$log_text" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-live-9\x1f--text\x1fhello captain\x1f--json' \
    "submit did not deliver the text through the live terminal handle"
  assert_contains "$log_text" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-live-9\x1f--text\x1f\x1f--enter\x1f--json' \
    "submit did not send Enter through the live terminal handle"
  assert_contains "$log_text" $'orca\x1fterminal\x1fread\x1f--terminal\x1fterm-live-9' \
    "submit did not verify the composer on the live terminal handle"
  assert_grep "terminal=term-stale" "$state/stalewinz1.meta" \
    "send-time resolution must leave the producer-owned terminal field untouched"
  [ "$(grep -c '^terminal=' "$state/stalewinz1.meta")" -eq 1 ] \
    || fail "resolution must never write or duplicate meta fields"
  pass "fm_backend_orca_send_text_submit: stale terminal re-resolves window= to the live handle with zero meta writes"
}

test_send_key_resolves_live_window_for_enter_and_interrupt() {
  local state log_text count
  orca_case key-stale-window
  state=$CASE_DIR/state
  write_orca_window_meta "$state" stalekeyz2 term-stale "$CASE_DIR/worktree"
  printf '{"ok":false,"error":{"code":"terminal_not_writable","message":"terminal_not_writable"}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"terminals":[{"handle":"term-live-9","writable":true,"connected":true}]}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-live-9","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal_handle_stale"}}\n' > "$RESP/5.out"
  printf '{"ok":true,"result":{"terminals":[{"handle":"term-live-9","writable":true,"connected":true}]}}\n' > "$RESP/6.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-live-9","accepted":true}}}\n' > "$RESP/7.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-stale Enter; fm_backend_orca_send_key term-stale C-c' "$ROOT"
  expect_code 0 $? "--key Enter and C-c should both deliver through the live window"
  log_text=$(cat "$LOG")
  count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1flist\x1f--worktree\x1fname:fm-stalekeyz2\x1f--limit\x1f200\x1f--json')
  [ "$count" -eq 2 ] || fail "each key should re-resolve the window once, got $count resolutions"
  assert_contains "$log_text" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-live-9\x1f--text\x1f\x1f--enter\x1f--json' \
    "Enter did not land on the live terminal handle"
  assert_contains "$log_text" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-live-9\x1f--interrupt\x1f--json' \
    "C-c did not land on the live terminal handle"
  pass "fm_backend_orca_send_key: Enter and C-c both re-resolve a stale terminal through window="
}

test_healthy_terminal_send_keeps_the_recorded_byte_path() {
  local state log_text out status
  orca_case healthy-no-retarget
  state=$CASE_DIR/state
  write_orca_window_meta "$state" healthyz3 term-healthy "$CASE_DIR/worktree"
  # Success responses in the pre-existing order: 1 Enter, 2 literal, 3 Enter, 4 read.
  printf '{"ok":true,"result":{"send":{"handle":"term-healthy","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-healthy","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-healthy","accepted":true}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭───╮","│ > │","╰───╯"]}}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-healthy Enter; fm_backend_orca_send_text_submit term-healthy "plain steer" 3 0.01 0.01' "$ROOT" )
  expect_code 0 $? "healthy sends should succeed as before"
  log_text=$(cat "$LOG")
  assert_contains "$log_text" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-healthy\x1f--text\x1f\x1f--enter\x1f--json' \
    "healthy Enter left the recorded path"
  assert_contains "$log_text" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-healthy\x1f--text\x1fplain steer\x1f--json' \
    "healthy literal left the recorded path"
  assert_not_contains "$log_text" $'orca\x1fterminal\x1flist' \
    "a healthy terminal must never trigger a window re-resolution - the pre-existing byte path is the regression pin"
  # The non-identity failure class is gated out too: no resolution, original
  # stderr replayed, original exit code preserved.
  orca_case healthy-non-identity
  state=$CASE_DIR/state
  write_orca_window_meta "$state" healthyz3 term-healthy "$CASE_DIR/worktree"
  printf '{"ok":false,"error":{"code":"runtime_busy","message":"runtime_busy"}}\n' > "$RESP/1.out"
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-healthy Enter' "$ROOT" 2>&1 )
  status=$?
  expect_code 2 "$status" "a non-identity rejection keeps today's exit code"
  assert_contains "$out" "runtime_busy" "the original failure stderr must be replayed unchanged"
  assert_not_contains "$(cat "$LOG")" $'orca\x1fterminal\x1flist' \
    "a non-identity failure must not re-resolve the window"
  pass "fm_backend_orca_send_key/submit: a healthy terminal keeps today's exact command sequence and failure bytes"
}

test_send_key_falls_back_when_window_unresolvable() {
  local state out status log_text
  orca_case key-unresolvable-window
  state=$CASE_DIR/state
  write_orca_window_meta "$state" gonewt4 term-stale "$CASE_DIR/worktree"
  # 1: identity rejection on the recorded handle.
  printf '{"ok":false,"error":{"code":"terminal_not_writable","message":"terminal_not_writable"}}\n' > "$RESP/1.out"
  # 2: the window itself is gone from Orca (renamed/removed worktree).
  printf '{"ok":false,"error":{"code":"selector_not_found","message":"selector_not_found"}}\n' > "$RESP/2.out"
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-stale Enter' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "an unresolvable window must keep the recorded-handle failure nonzero"
  expect_code 2 "$status" "an unresolvable window preserves today's exit code"
  assert_contains "$out" "terminal_not_writable" \
    "an unresolvable window must replay the original recorded-handle failure, got '$out'"
  log_text=$(cat "$LOG")
  assert_contains "$log_text" $'orca\x1fterminal\x1flist\x1f--worktree\x1fname:fm-gonewt4\x1f--limit\x1f200\x1f--json' \
    "the window resolution attempt should be visible in the CLI log"
  assert_not_contains "$log_text" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-live' \
    "no send may be retried on a handle the window path never proved"
  pass "fm_backend_orca_send_key: an unresolvable window falls back to the recorded-handle failure unchanged"
}

test_fm_send_doorbell_and_key_reach_live_window_when_terminal_stale() {
  local state id out status neutral record body log_text
  id="oracawinz5"
  state="$TMP_ROOT/winz5-state"
  write_orca_window_meta "$state" "$id" term-stale "$state/worktree"
  touch "$state/.last-watcher-beat"
  orca_case winz5-doorbell
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  printf '{"ok":true,"result":{"terminal":{"tail":[]}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"terminal":{"tail":[]}}}\n' > "$RESP/2.out"
  printf '{"ok":false,"error":{"code":"terminal_not_writable","message":"terminal_not_writable"}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminals":[{"handle":"term-live-9","writable":true,"connected":true}]}}\n' > "$RESP/4.out"
  # Replacement inbox input requires a positively identified empty composer.
  printf '{"ok":true,"result":{"terminal":{"tail":["╭───╮","│ > │","╰───╯"]}}}\n' > "$RESP/5.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-live-9","accepted":true}}}\n' > "$RESP/6.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-live-9","accepted":true}}}\n' > "$RESP/7.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭───╮","│ > │","╰───╯"]}}}\n' > "$RESP/8.out"
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" "steer through the window" 2>&1 )
  status=$?
  expect_code 0 "$status" "a stale terminal with a live window must still deliver its steer"$'\n'"$out"
  assert_not_contains "$out" "doorbell did not reach" \
    "the doorbell reached the live pane; the stale-handle refusal must not fire"
  record="$state/$id.inbox/001.msg"
  [ -f "$record" ] || fail "the steer must still be durably recorded in the task inbox"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$record")
  [ "$body" = "steer through the window" ] || fail "inbox record body corrupted, got '$body'"
  log_text=$(cat "$LOG")
  assert_contains "$log_text" $'orca\x1fterminal\x1flist\x1f--worktree\x1fname:fm-'"$id"$'\x1f--limit\x1f200\x1f--json' \
    "the doorbell path did not resolve the recorded window"
  assert_contains "$log_text" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-live-9\x1f--text\x1f: Firstmate instruction waiting:' \
    "the doorbell did not ring through the live terminal handle"
  assert_grep "terminal=term-stale" "$state/$id.meta" \
    "fm-send must not rewrite the producer-owned terminal field"
  printf '{"ok":false,"error":{"code":"terminal_not_writable","message":"terminal_not_writable"}}\n' > "$RESP/9.out"
  printf '{"ok":true,"result":{"terminals":[{"handle":"term-live-9","writable":true,"connected":true}]}}\n' > "$RESP/10.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/11.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-live-9","accepted":true}}}\n' > "$RESP/12.out"
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-send.sh" "$id" --key Enter 2>&1 )
  status=$?
  expect_code 0 "$status" "--key Enter must deliver through the live window"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-live-9\x1f--text\x1f\x1f--enter\x1f--json' \
    "--key Enter did not land on the live terminal handle"
  assert_grep "terminal=term-stale" "$state/$id.meta" \
    "the --key path must not rewrite the producer-owned terminal field either"
  pass "fm-send.sh: a stale terminal's doorbell, steer record, and --key Enter all reach the live window with zero meta edits"
}

test_fm_send_doorbell_falls_back_when_window_unresolvable() {
  local state id out status neutral record
  id="oracawinz6"
  state="$TMP_ROOT/winz6-state"
  write_orca_window_meta "$state" "$id" term-stale "$state/worktree"
  touch "$state/.last-watcher-beat"
  orca_case winz6-doorbell
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  printf '{"ok":true,"result":{"terminal":{"tail":[]}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"terminal":{"tail":[]}}}\n' > "$RESP/2.out"
  printf '{"ok":false,"error":{"code":"terminal_not_writable","message":"terminal_not_writable"}}\n' > "$RESP/3.out"
  printf '{"ok":false,"error":{"code":"selector_not_found","message":"selector_not_found"}}\n' > "$RESP/4.out"
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" "steer into the void" 2>&1 )
  status=$?
  expect_code 0 "$status" "a failed doorbell never fails a durably recorded steer"$'\n'"$out"
  assert_contains "$out" "doorbell did not reach term-stale" \
    "the unresolvable-window fallback must record today's exact durable refusal"
  assert_contains "$out" "the watcher will re-ring" \
    "the fallback must keep the re-rung doctrine visible"
  record="$state/$id.inbox/001.msg"
  [ -f "$record" ] || fail "the steer must remain durably recorded for the re-ring ladder"
  assert_not_contains "$(cat "$LOG")" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-live' \
    "no send may go out on an unproven handle when the window is unresolvable"
  pass "fm-send.sh: an unresolvable window keeps the exact durable doorbell refusal and the re-ring contract"
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

orca_stale_json() {
  printf '%s\n' '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}'
}

orca_live_list_json() {  # <handle> <title>
  printf '{"ok":true,"result":{"terminals":[{"handle":"%s","title":"%s","connected":true,"writable":true,"orphaned":false}],"truncated":false}}\n' "$1" "$2"
}

test_send_text_submit_healthy_terminal_does_not_list_windows() {
  local state id wt err out before
  id="orcawinhealthy"
  wt="$TMP_ROOT/win-healthy-wt"
  state="$TMP_ROOT/win-healthy-state"
  write_orca_window_meta "$state" "$id" "term-healthy" "$wt"
  before=$(cat "$state/$id.meta")
  orca_case window-healthy
  printf '{"ok":true,"result":{"send":{"handle":"term-healthy","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-healthy","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭───╮","│ > │","╰───╯"]}}}\n' > "$RESP/3.out"
  err="$CASE_DIR/err"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-healthy "hello captain" 3 0.01 0.01' "$ROOT" 2>"$err" )
  [ "$out" = empty ] || fail "healthy terminal should still confirm empty, got '$out'"
  [ ! -s "$err" ] || fail "healthy terminal should not print a resolution error: $(cat "$err")"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-healthy'$'\x1f''--text'$'\x1f''hello captain'$'\x1f''--json' \
    "healthy submit did not type through the recorded terminal"
  assert_not_contains "$(cat "$LOG")" $'terminal'$'\x1f''list' \
    "a live terminal id must not consult the window inventory"
  [ "$(cat "$state/$id.meta")" = "$before" ] || fail "healthy submit rewrote meta"
  pass "fm_backend_orca_send_text_submit: a healthy terminal id is byte-identical and does not list windows"
}

test_send_text_submit_stale_terminal_uses_window_name() {
  local state id wt err out before
  id="orcawinstale"
  wt="$TMP_ROOT/win-stale-wt"
  state="$TMP_ROOT/win-stale-state"
  write_orca_window_meta "$state" "$id" "term-stale-win" "$wt"
  before=$(cat "$state/$id.meta")
  orca_case window-stale-named
  orca_stale_json > "$RESP/1.out"
  orca_live_list_json "term-live-win" "pi - fm-$id" > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-live-win","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-live-win","accepted":true}}}\n' > "$RESP/5.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭───╮","│ > │","╰───╯"]}}}\n' > "$RESP/6.out"
  err="$CASE_DIR/err"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-stale-win "hello captain" 3 0.01 0.01' "$ROOT" 2>"$err" )
  [ "$out" = empty ] || fail "stale terminal with a live window should confirm empty, got '$out' log=$(cat "$LOG" | tr '\037' '|')"
  assert_not_contains "$(cat "$err")" "terminal handle stale" \
    "a recovered window send must not surface the stale-handle refusal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''list'$'\x1f''--worktree'$'\x1f''name:fm-'$id$'\x1f''--limit'$'\x1f''200'$'\x1f''--json' \
    "stale submit did not ask Orca for the window by its native name selector"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-live-win'$'\x1f''--text'$'\x1f''hello captain'$'\x1f''--json' \
    "stale submit did not type through the live window handle"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-live-win'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "stale submit did not send Enter to the live window"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-live-win' \
    "composer read after a window retry must use the live handle"
  [ "$(cat "$state/$id.meta")" = "$before" ] || fail "window resolution rewrote meta"
  pass "fm_backend_orca_send_text_submit: a stale terminal id delivers through the recorded window name"
}

test_send_text_submit_missing_named_window_refuses_other_title() {
  local state id wt out
  id="orcawintitle"
  wt="$TMP_ROOT/win-title-wt"
  state="$TMP_ROOT/win-title-state"
  write_orca_window_meta "$state" "$id" "term-stale-title" "$wt"
  orca_case window-stale-title
  orca_stale_json > "$RESP/1.out"
  printf '{"ok":false,"error":{"code":"selector_not_found","message":"selector_not_found"}}\n' > "$RESP/2.out"
  orca_live_list_json "term-other-home" "Follow worker | fm-$id" > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-stale-title "typed once" 1 0.01 0.01' "$ROOT" 2>"$CASE_DIR/err" )
  [ "$out" = send-failed ] || fail "a missing named window must refuse, got '$out'"
  [ "$(cat "$RESP/.count")" -eq 2 ] || fail "a missing named window must stop after its selector fails"
  assert_not_contains "$(cat "$LOG")" $'--terminal\x1fterm-other-home' \
    "a title in another home must not receive input"
  pass "fm_backend_orca_send_text_submit: a missing named window never scans other homes"
}

test_send_key_stale_terminal_uses_window_for_enter_and_interrupt() {
  local state id wt
  id="orcawinkey"
  wt="$TMP_ROOT/win-key-wt"
  state="$TMP_ROOT/win-key-state"
  write_orca_window_meta "$state" "$id" "term-stale-key" "$wt"
  orca_case window-stale-key
  orca_stale_json > "$RESP/1.out"
  orca_live_list_json "term-live-key" "fm-$id" > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/4.out"
  orca_stale_json > "$RESP/5.out"
  orca_live_list_json "term-live-key" "fm-$id" > "$RESP/6.out"
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/7.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-stale-key Enter; fm_backend_orca_send_key term-stale-key C-c' "$ROOT" \
    || fail "Enter and C-c should succeed once the window resolves"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-live-key'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "Enter did not follow the live window handle"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-live-key'$'\x1f''--interrupt'$'\x1f''--json' \
    "C-c did not follow the live window handle"
  pass "fm_backend_orca_send_key: Enter and C-c resolve a stale terminal through the same window"
}

test_send_refuses_when_window_is_also_missing() {
  local state id wt out err status
  id="orcawinmiss"
  wt="$TMP_ROOT/win-miss-wt"
  state="$TMP_ROOT/win-miss-state"
  write_orca_window_meta "$state" "$id" "term-stale-miss" "$wt"
  orca_case window-missing
  orca_stale_json > "$RESP/1.out"
  printf '{"ok":false,"error":{"code":"selector_not_found","message":"selector_not_found"}}\n' > "$RESP/2.out"
  err="$CASE_DIR/err"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-stale-miss "hello" 1 0.01 0.01' "$ROOT" 2>"$err" )
  [ "$out" = send-failed ] || fail "a missing window should keep today's send-failed verdict, got '$out'"
  assert_contains "$(cat "$err")" "terminal handle stale" \
    "a missing window should replay the original stale-handle refusal"
  if grep -q $'terminal\x1fsend\x1f--terminal\x1fterm-live' "$LOG"; then
    fail "a missing window must not send to a guessed terminal"
  fi
  orca_stale_json > "$RESP/3.out"
  printf '{"ok":false,"error":{"code":"selector_not_found"}}\n' > "$RESP/4.out"
  set +e
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-stale-miss Enter' "$ROOT" >"$CASE_DIR/key.out" 2>"$CASE_DIR/key.err"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a missing window should keep today's nonzero --key failure"
  assert_contains "$(cat "$CASE_DIR/key.err")" "terminal handle stale" \
    "a missing window key should replay the stale-handle refusal"
  pass "Orca send: a stale terminal whose window is also missing keeps today's refusal"
}

test_send_does_not_retarget_on_a_non_stale_failure() {
  local state id wt out
  id="orcawinother"
  wt="$TMP_ROOT/win-other-wt"
  state="$TMP_ROOT/win-other-state"
  write_orca_window_meta "$state" "$id" "term-other-fail" "$wt"
  orca_case window-other-fail
  printf '1\n' > "$RESP/1.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-other-fail "hello" 1 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "a non-stale send failure should stay send-failed, got '$out'"
  assert_not_contains "$(cat "$LOG")" $'terminal'$'\x1f''list' \
    "only a stale handle may consult the window inventory"
  pass "fm_backend_orca_send_text_submit: a non-stale failure is not retargeted"
}

test_ambiguous_window_does_not_guess_a_terminal() {
  local state id wt out err
  id="orcawinambig"
  wt="$TMP_ROOT/win-ambig-wt"
  state="$TMP_ROOT/win-ambig-state"
  write_orca_window_meta "$state" "$id" "term-stale-ambig" "$wt"
  orca_case window-ambiguous
  orca_stale_json > "$RESP/1.out"
  printf '{"ok":true,"result":{"terminals":[{"handle":"term-a","title":"fm-orcawinambig","connected":true,"writable":true},{"handle":"term-b","title":"other-b","connected":true,"writable":true}],"truncated":false}}\n' > "$RESP/2.out"
  err="$CASE_DIR/err"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-stale-ambig "hello" 1 0.01 0.01' "$ROOT" 2>"$err" )
  [ "$out" = send-failed ] || fail "an ambiguous window must not guess, got '$out'"
  assert_contains "$(cat "$err")" "terminal handle stale" "ambiguous window should keep the original refusal"
  assert_not_contains "$(cat "$LOG")" $'--terminal'$'\x1f''term-a' "ambiguous window sent to term-a"
  assert_not_contains "$(cat "$LOG")" $'--terminal'$'\x1f''term-b' "ambiguous window sent to term-b"
  assert_not_contains "$(cat "$LOG")" $'terminal'$'\x1f''list'$'\x1f''--limit' \
    "an ambiguous named workspace must not fall through to a global title scan"
  pass "fm_backend_orca_send_text_submit: an ambiguous named window is not guessed"
}

test_fm_send_doorbell_reaches_live_window_and_missing_window_rering() {
  local state id wt neutral err rc record body
  id="orcawinring"
  wt="$TMP_ROOT/win-ring-wt"
  state="$TMP_ROOT/win-ring-state"
  write_orca_window_meta "$state" "$id" "term-stale-ring" "$wt"
  touch "$state/.last-watcher-beat"
  orca_case window-ring
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  # Two composer pre-reads see the stale id, then the typed doorbell does too,
  # then the native name selector returns the live pane.
  orca_stale_json > "$RESP/1.out"
  orca_stale_json > "$RESP/2.out"
  orca_stale_json > "$RESP/3.out"
  orca_live_list_json "term-live-ring" "fm-$id" > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭───╮","│ > │","╰───╯"]}}}\n' > "$RESP/5.out"
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/6.out"
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/7.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/8.out"
  err="$CASE_DIR/send.err"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "fm-$id" "hello window" >"$CASE_DIR/send.out" 2>"$err"
  rc=$?
  [ "$rc" -eq 0 ] || fail "a doorbell that reaches the live window should still be a sent steer, rc=$rc err=$(cat "$err") log=$(tr '\037' '|' < "$LOG")"
  assert_not_contains "$(cat "$err")" "doorbell did not reach" \
    "a resolved window must not record a missed doorbell"
  record="$state/$id.inbox/001.msg"
  [ -f "$record" ] || fail "window delivery did not keep the durable inbox record"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$record")
  [ "$body" = "hello window" ] || fail "inbox body changed, got '$body'"
  assert_contains "$(cat "$LOG")" $'--terminal'$'\x1f''term-live-ring'$'\x1f''--text'$'\x1f'': Firstmate instruction waiting:' \
    "the doorbell was not typed into the live window"
  assert_grep "terminal=term-stale-ring" "$state/$id.meta" "doorbell delivery rewrote the recorded terminal"

  # Same record shape, but the window cannot be found: today's refusal, and the watcher re-rings.
  id="orcawinmissring"
  write_orca_window_meta "$state" "$id" "term-stale-missring" "$wt"
  : > "$LOG"
  rm -f "$RESP"/.count "$RESP"/*.out "$RESP"/*.exit
  orca_stale_json > "$RESP/1.out"
  orca_stale_json > "$RESP/2.out"
  orca_stale_json > "$RESP/3.out"
  printf '{"ok":false,"error":{"code":"selector_not_found","message":"selector_not_found"}}\n' > "$RESP/4.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "fm-$id" "hello missing" >"$CASE_DIR/miss.out" 2>"$err"
  rc=$?
  [ "$rc" -eq 0 ] || fail "a missed doorbell is still a durably sent steer, rc=$rc err=$(cat "$err")"
  assert_contains "$(cat "$err")" "doorbell did not reach term-stale-missring" \
    "the refusal must name the recorded terminal, not a guessed handle"
  assert_contains "$(cat "$err")" "the watcher will re-ring" \
    "a missed window must keep the re-ring contract"
  [ -f "$state/$id.inbox/001.msg" ] || fail "the missed doorbell dropped the durable steer"
  if grep -q $'terminal\x1fsend\x1f--terminal\x1fterm-live' "$LOG"; then
    fail "a missing window doorbell guessed a terminal: $(tr '\037' '|' < "$LOG")"
  fi
  pass "fm-send: a stale Orca window receives the doorbell, and a missing window keeps the re-ring refusal"
}

test_send_stale_exit_status_still_resolves_window() {
  local state id wt out fb code channel
  id="orcawinexit"
  wt="$TMP_ROOT/win-exit-wt"
  state="$TMP_ROOT/win-exit-state"
  write_orca_window_meta "$state" "$id" "term-stale-exit" "$wt"
  for code in terminal_handle_stale terminal_not_writable runtime_busy; do
    for channel in stdout stderr; do
      orca_case "window-stale-exit-$code-$channel"
      fb="$FB"
      cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = terminal ] && [ "${2:-}" = send ] && [ "${4:-}" = term-stale-exit ]; then
  if [ "$FM_ORCA_RESTART_CHANNEL" = stderr ]; then
    printf '%s\n' "$FM_ORCA_RESTART_ERROR" >&2
  else
    printf '{"ok":false,"error":{"code":"%s","message":"%s"}}\n' "$FM_ORCA_RESTART_ERROR" "$FM_ORCA_RESTART_ERROR"
  fi
  exit 1
fi
if [ "${1:-}" = terminal ] && [ "${2:-}" = list ]; then
  printf '%s\n' '{"ok":true,"result":{"terminals":[{"handle":"term-live-exit","title":"fm-orcawinexit","connected":true,"writable":true}],"truncated":false}}'
  exit 0
fi
if [ "${1:-}" = terminal ] && [ "${2:-}" = send ]; then
  printf '%s\n' '{"ok":true,"result":{"send":{"accepted":true}}}'
  exit 0
fi
if [ "${1:-}" = terminal ] && [ "${2:-}" = read ]; then
  printf '%s\n' '{"ok":true,"result":{"terminal":{"tail":["╭───╮","│ > │","╰───╯"]}}}'
  exit 0
fi
exit 1
SH
      chmod +x "$fb/orca"
      out=$( FM_ORCA_RESTART_ERROR="$code" FM_ORCA_RESTART_CHANNEL="$channel" PATH="$fb:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
        FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$state" \
        bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-stale-exit "hello captain" 1 0.01 0.01' "$ROOT" 2>"$CASE_DIR/err" )
      if [ "$code" = runtime_busy ]; then
        [ "$out" = send-failed ] || fail "unrelated $channel error must refuse, got '$out'"
        if [ "$channel" = stderr ]; then
          assert_contains "$(cat "$CASE_DIR/err")" runtime_busy "unrelated stderr errors must be replayed"
        else
          [ ! -s "$CASE_DIR/err" ] || fail "unrelated stdout errors must preserve the original empty stderr"
        fi
        assert_not_contains "$(cat "$LOG")" $'terminal\x1flist' "unrelated errors must not retarget"
      else
        [ "$out" = empty ] || fail "exit-1 $code on $channel should deliver, got '$out' err=$(cat "$CASE_DIR/err")"
        assert_contains "$(cat "$LOG")" $'--terminal\x1fterm-live-exit\x1f--text\x1fhello captain' \
          "exit-1 $code on $channel did not retry through the live window"
      fi
    done
  done
  pass "Orca submit: nonzero restart errors resolve from stdout or stderr, unrelated errors refuse"
}

test_fm_send_key_uses_live_window() {
  local state id wt neutral err rc
  id="orcawinsendkey"
  wt="$TMP_ROOT/win-sendkey-wt"
  state="$TMP_ROOT/win-sendkey-state"
  write_orca_window_meta "$state" "$id" "term-stale-sendkey" "$wt"
  touch "$state/.last-watcher-beat"
  orca_case window-send-key
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  orca_stale_json > "$RESP/1.out"
  orca_live_list_json "term-live-sendkey" "fm-$id" > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/4.out"
  err="$CASE_DIR/err"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-send.sh" "fm-$id" --key Enter >"$CASE_DIR/out" 2>"$err"
  rc=$?
  [ "$rc" -eq 0 ] || fail "fm-send --key Enter should reach the live window, rc=$rc err=$(cat "$err") log=$(tr '\037' '|' < "$LOG")"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-live-sendkey'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "fm-send --key Enter did not use the live window handle"
  : > "$LOG"
  orca_stale_json > "$RESP/5.out"
  orca_live_list_json "term-live-sendkey" "fm-$id" > "$RESP/6.out"
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/7.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-send.sh" "fm-$id" --key C-c >"$CASE_DIR/out" 2>"$err"
  rc=$?
  [ "$rc" -eq 0 ] || fail "fm-send --key C-c should reach the live window, rc=$rc err=$(cat "$err") log=$(tr '\037' '|' < "$LOG")"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-live-sendkey'$'\x1f''--interrupt'$'\x1f''--json' \
    "fm-send --key C-c did not use the live window handle"
  pass "fm-send --key: Enter and C-c reach the live window without editing meta"
}

test_retargeted_dialog_blocks_text_and_enter_but_allows_interrupt() {
  local code mode state id before out status neutral n
  for code in terminal_handle_stale terminal_not_writable; do
    for mode in literal submit doorbell enter interrupt; do
      orca_case "window-dialog-$mode-$code"
      state="$CASE_DIR/state"
      id="orcawindialog"
      write_orca_window_meta "$state" "$id" term-stale "$CASE_DIR/worktree"
      before=$(cat "$state/$id.meta")
      n=1
      case "$mode" in
        submit|doorbell)
          printf '{"ok":true,"result":{"terminal":{"tail":[]}}}\n' > "$RESP/$n.out"
          n=$((n + 1))
          ;;
      esac
      if [ "$mode" = doorbell ]; then
        printf '{"ok":true,"result":{"terminal":{"tail":[]}}}\n' > "$RESP/$n.out"
        n=$((n + 1))
      fi
      printf '{"ok":false,"error":{"code":"%s","message":"%s"}}\n' "$code" "$code" > "$RESP/$n.out"
      n=$((n + 1))
      orca_live_list_json term-live-dialog "fm-$id" > "$RESP/$n.out"
      n=$((n + 1))
      if [ "$mode" = interrupt ]; then
        printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/$n.out"
      else
        printf '{"ok":true,"result":{"terminal":{"tail":["Background work is running","❯ 1. Exit and stop tasks","Enter to confirm · Esc to cancel"]}}}\n' > "$RESP/$n.out"
      fi
      if [ "$mode" = doorbell ]; then
        touch "$state/.last-watcher-beat"
        neutral=$(neutral_fm_root "$CASE_DIR/neutral")
        if out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
          FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
          "$ROOT/bin/fm-send.sh" "$id" "keep this steer" 2>&1 ); then status=0; else status=$?; fi
        expect_code 0 "$status" "a blocked doorbell must keep the durable steer"
        assert_contains "$out" "doorbell did not reach term-stale" "a blocked doorbell must report non-delivery"
        [ -f "$state/$id.inbox/001.msg" ] || fail "a blocked doorbell lost the steer"
      else
        if out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
          FM_HOME="$CASE_DIR" FM_STATE_OVERRIDE="$state" \
          bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/backends/orca.sh";
            case "$1" in
              literal) fm_backend_orca_send_literal term-stale hello ;;
              submit) fm_backend_send_text_submit orca term-stale hello 1 0 0 ;;
              enter) fm_backend_send_key orca term-stale Enter ;;
              interrupt) fm_backend_send_key orca term-stale C-c ;;
            esac' "$ROOT" "$mode" 2>"$CASE_DIR/err" ); then status=0; else status=$?; fi
        case "$mode" in
          submit) [ "$out" = send-failed ] || fail "blocked submit must report send-failed, got '$out'" ;;
          interrupt) expect_code 0 "$status" "C-c must remain available" ;;
          *) [ "$status" -ne 0 ] || fail "$mode must refuse the replacement dialog" ;;
        esac
        if [ "$mode" != interrupt ]; then
          assert_contains "$(cat "$CASE_DIR/err")" "blocked on a prompt" "$mode must report the blocking dialog"
        fi
      fi
      if [ "$mode" = interrupt ]; then
        assert_contains "$(cat "$LOG")" $'--terminal\x1fterm-live-dialog\x1f--interrupt' "C-c must reach the live pane"
        assert_not_contains "$(cat "$LOG")" $'terminal\x1fread\x1f--terminal\x1fterm-live-dialog' "C-c must remain independent of dialog checks"
      else
        assert_not_contains "$(cat "$LOG")" $'terminal\x1fsend\x1f--terminal\x1fterm-live-dialog' "$mode must never type or confirm the dialog"
      fi
      [ "$(cat "$state/$id.meta")" = "$before" ] || fail "$mode rewrote metadata"
    done
  done
  pass "Orca retargeting: blocking dialogs refuse text and Enter while C-c stays available"
}

test_inbox_retarget_preserves_pending_content_and_explicit_input() {
  local code mode state id rec bell before out expected events held drops busy
  for code in terminal_handle_stale terminal_not_writable; do
    for mode in cursor-draft cursor-own cursor-busy unreadable initial-draft initial-own initial-busy initial-empty initial-empty-busy retry-draft retry-own retry-busy second-draft second-own second-busy rering-draft typed Enter C-c scope; do
      orca_case "inbox-retarget-$code-$mode"
      state="$CASE_DIR/state"
      id=orcainboxdraft
      write_orca_window_meta "$state" "$id" term-stale "$CASE_DIR/worktree"
      before=$(cat "$state/$id.meta")
      rec=$(FM_STATE_OVERRIDE="$state" bash -c '. "$0/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$1" "$2" "durable steer" fire-and-forget' "$ROOT" "$state" "$id")
      bell=$(bash -c '. "$0/bin/fm-task-inbox-lib.sh"; fm_task_inbox_doorbell_line "$1"' "$ROOT" "$rec")
      expected=0
      drops=0
      busy=unknown
      held='human unfinished draft'
      case "$mode" in
        *-own) held=$bell ;;
        *-busy) held=$bell; busy=busy; expected=1 ;;
        initial-empty) held= ;;
        *-draft) expected=1 ;;
      esac
      case "$mode" in
        cursor-*|unreadable) expected=1 ;;
        initial-empty-busy) held=; busy=unknown ;;
      esac
      case "$mode" in initial-own|retry-own) drops=1 ;; esac
      printf '%s' "$held" > "$CASE_DIR/composer"
      printf '%s' "$bell" > "$CASE_DIR/old-composer"
      printf '%s' "$drops" > "$CASE_DIR/drops"
      : > "$CASE_DIR/inputs"
      : > "$CASE_DIR/submitted"
      cat > "$FB/orca" <<'JS'
#!/usr/bin/env node
const fs = require('fs');
const args = process.argv.slice(2);
const dir = process.env.FM_ORCA_TEST_DIR;
const mode = process.env.FM_ORCA_TEST_MODE;
const terminal = args[args.indexOf('--terminal') + 1];
const enter = args.includes('--enter');
fs.appendFileSync(process.env.FM_ORCA_LOG, ['orca', ...args].join('\x1f') + '\n');
function reply(data) { process.stdout.write(JSON.stringify(data) + '\n'); }
function stale() {
  reply({ok:false, error:{code:process.env.FM_ORCA_TEST_CODE, message:process.env.FM_ORCA_TEST_CODE}});
  process.exitCode = 1;
}
function accepted() { reply({ok:true, result:{send:{accepted:true}}}); }
if (args[1] === 'list') {
  reply({ok:true, result:{terminals:[{handle:'term-live', writable:true, connected:true}]}});
} else if (args[1] === 'read') {
  if (terminal === 'term-live' && mode === 'unreadable') {
    process.exitCode = 1;
  } else if (terminal === 'term-stale' && !/^(retry|second)-/.test(mode)) {
    stale();
  } else {
    const body = fs.readFileSync(dir + (terminal === 'term-stale' ? '/old-composer' : '/composer'), 'utf8');
    const rule = '─'.repeat(body.length + 4);
    // Cursor's captured plain-text screen has no composer border, and its
    // footer includes the worktree path. Preserve this real shape rather
    // than replacing it with the boxed composer the classifier understands.
    const tail = mode.startsWith('cursor-')
      ? ['  → ' + body, '  Ask (shift+tab to cycle)', '  Auto · 11.6%',
         '  ' + dir + '/worktree', '  · fm-orcainboxdraft']
      : ['╭' + rule + '╮', '│ > ' + body + ' │', '╰' + rule + '╯'];
    if (mode === 'cursor-busy') tail.unshift(' ⠠⠛ Working');
    if (mode === 'initial-empty-busy') tail.unshift('ctrl+c to stop');
    reply({ok:true, result:{terminal:{tail}}});
  }
} else if (args[1] === 'send') {
  if (terminal === 'term-stale') {
    if (mode.startsWith('second-') && enter && !fs.existsSync(dir + '/old-enter')) {
      fs.writeFileSync(dir + '/old-enter', '1');
      fs.appendFileSync(dir + '/inputs', 'old Enter\n');
      accepted();
    } else {
      stale();
    }
  } else {
    if (args.includes('--interrupt')) {
      fs.appendFileSync(dir + '/inputs', 'live C-c\n');
    } else if (enter) {
      fs.appendFileSync(dir + '/inputs', 'live Enter\n');
      const drops = Number(fs.readFileSync(dir + '/drops', 'utf8'));
      if (drops > 0) {
        fs.writeFileSync(dir + '/drops', String(drops - 1));
      } else {
        fs.writeFileSync(dir + '/submitted', fs.readFileSync(dir + '/composer', 'utf8'));
        fs.writeFileSync(dir + '/composer', '');
      }
    } else {
      const text = args[args.indexOf('--text') + 1];
      fs.appendFileSync(dir + '/inputs', 'live text\n');
      fs.appendFileSync(dir + '/composer', text);
    }
    accepted();
  }
} else {
  process.exitCode = 1;
}
JS
      chmod +x "$FB/orca"
      out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_TEST_DIR="$CASE_DIR" \
        FM_ORCA_TEST_MODE="$mode" FM_ORCA_TEST_CODE="$code" FM_ORCA_TEST_BUSY="$busy" \
        FM_STATE_OVERRIDE="$state" FM_HOME="$CASE_DIR" \
        bash -c '. "$0/bin/fm-task-inbox-lib.sh";
          fm_backend_busy_state() {
            if [ "$2" = term-live ]; then printf "%s" "$FM_ORCA_TEST_BUSY"; else printf unknown; fi
          }
          case "$1" in
            cursor-*)
              [ "$(fm_backend_composer_state orca term-live)" = unknown ] || exit 1 ;;
            initial-empty-busy)
              [ "$(fm_backend_composer_state orca term-live)" = empty ] || exit 1
              [ "$(fm_backend_busy_state orca term-live)" = unknown ] || exit 1 ;;
          esac
          rc=0
          case "$1" in
            typed)
              verdict=$(fm_backend_send_text_submit orca term-stale "explicit steer" 2 0 0)
              [ "$verdict" = empty ] || exit 1 ;;
            Enter|C-c) fm_backend_send_key orca term-stale "$1" || rc=$? ;;
            *)
              fm_task_inbox_ring orca term-stale "$2" || rc=$?
              case "$1" in
                rering-draft)
                  [ "$rc" -eq 1 ] || exit 1
                  rc=0
                  fm_task_inbox_ring orca term-stale "$2" || rc=$? ;;
                scope)
                  [ "$rc" -eq 1 ] || exit 1
                  rc=0
                  fm_backend_send_key orca term-stale Enter || rc=$? ;;
              esac ;;
          esac
          printf "%s" "$rc"' "$ROOT" "$mode" "$rec" 2>"$CASE_DIR/err" ) \
        || fail "$mode failed: $(cat "$CASE_DIR/err")"
      [ "$out" = "$expected" ] || fail "$code $mode: expected ring status $expected, got '$out'"
      events=$(cat "$CASE_DIR/inputs")
      if [ "$expected" -eq 1 ]; then
        assert_not_contains "$events" live "$mode sent replacement input despite pending content"
        [ "$(cat "$CASE_DIR/composer")" = "$held" ] || fail "$mode changed the protected composer"
        [ ! -s "$CASE_DIR/submitted" ] || fail "$mode submitted pending content"
      else
        case "$mode" in
          typed) [ "$(cat "$CASE_DIR/submitted")" = "${held}explicit steer" ] || fail "explicit typed semantics changed" ;;
          Enter|scope) [ "$(cat "$CASE_DIR/submitted")" = "$held" ] || fail "explicit Enter semantics changed" ;;
          C-c) [ "$events" = 'live C-c' ] || fail "explicit C-c did not reach the live pane" ;;
          *)
            [ "$(cat "$CASE_DIR/submitted")" = "$bell" ] || fail "$mode did not submit exactly its own doorbell"
            if [ "$mode" = initial-empty ]; then
              assert_contains "$events" 'live text' "an empty live composer must receive the doorbell"
            else
              assert_not_contains "$events" 'live text' "$mode duplicated a pending own doorbell"
            fi
            [ ! -s "$CASE_DIR/composer" ] || fail "$mode left its doorbell pending"
            ;;
        esac
      fi
      [ -f "$rec" ] || fail "$mode removed the durable steer"
      [ "$(cat "$state/$id.meta")" = "$before" ] || fail "$mode rewrote metadata"
    done
  done
  pass "Orca inbox: replacement panes preserve drafts, busy deferrals, own-doorbell retries, and explicit input"
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
test_send_text_submit_resolves_live_window_when_terminal_stale
test_send_key_resolves_live_window_for_enter_and_interrupt
test_healthy_terminal_send_keeps_the_recorded_byte_path
test_send_key_falls_back_when_window_unresolvable
test_fm_send_doorbell_and_key_reach_live_window_when_terminal_stale
test_fm_send_doorbell_falls_back_when_window_unresolvable
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
test_spawn_refuses_orca_secondmate_before_home_mutation
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
test_send_text_submit_healthy_terminal_does_not_list_windows
test_send_text_submit_stale_terminal_uses_window_name
test_send_text_submit_missing_named_window_refuses_other_title
test_send_key_stale_terminal_uses_window_for_enter_and_interrupt
test_send_refuses_when_window_is_also_missing
test_send_does_not_retarget_on_a_non_stale_failure
test_ambiguous_window_does_not_guess_a_terminal
test_fm_send_doorbell_reaches_live_window_and_missing_window_rering
test_fm_send_key_uses_live_window
test_send_stale_exit_status_still_resolves_window
test_retargeted_dialog_blocks_text_and_enter_but_allows_interrupt
test_inbox_retarget_preserves_pending_content_and_explicit_input
