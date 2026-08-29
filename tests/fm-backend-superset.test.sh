#!/usr/bin/env bash
# tests/fm-backend-superset.test.sh - fake-Superset-CLI unit tests for the
# Superset workspace/terminal adapter primitives in bin/backends/superset.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-superset-tests)
# Normalized through cd+pwd once: fm_test_tmproot's raw path can carry a
# double slash when $TMPDIR itself ends in one (verified on macOS), and
# fm-spawn.sh's own PROJ_ABS is resolved with plain `pwd`, which collapses
# that double slash. Every project-path fixture below must match PROJ_ABS
# byte for byte, so TMP_ROOT is normalized here once rather than at every
# call site.
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

make_superset_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/superset" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_SUPERSET_LOG:?}"
RESP="${FM_SUPERSET_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'superset'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${FM_SUPERSET_STATUS_RESPONSE:-ready}" != sequence ]; then
  printf '{"running":true,"healthy":true}\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  [ -f "$RESP/$n.err" ] && cat "$RESP/$n.err" >&2
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/superset"
  printf '%s\n' "$fb"
}

superset_case() {  # <name> -> sets CASE_DIR LOG RESP FB
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/responses"
  LOG="$CASE_DIR/log"
  RESP="$CASE_DIR/responses"
  : > "$LOG"
  FB=$(make_superset_fakebin "$CASE_DIR")
}

test_capture_reads_terminal_text() {
  local out
  superset_case capture-text
  printf '{"terminalId":"term-123","cols":120,"rows":32,"text":"line one\\nline two"}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_capture ws-123:term-123 40' "$ROOT" )
  [ "$out" = $'line one\nline two' ] || fail "capture should print the terminal text field, got '$out'"
  assert_contains "$(cat "$LOG")" $'superset\x1f''terminals'$'\x1f''read'$'\x1f''--workspace'$'\x1f''ws-123'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--max-lines'$'\x1f''40'$'\x1f''--json' \
    "capture did not call terminals read with workspace/terminal/max-lines/json"
  pass "fm_backend_superset_capture: parses the flat text field and calls terminals read"
}

test_capture_fails_on_cli_error() {
  local out status
  superset_case capture-error
  printf 'Error: Terminal session "term-gone" is not active; create it before connecting.\n' > "$RESP/1.err"
  printf '1\n' > "$RESP/1.exit"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_capture ws-123:term-gone 5' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when the CLI exits non-zero"
  assert_contains "$out" "not active" "capture should surface the Superset CLI's stderr error"
  pass "fm_backend_superset_capture: fails closed on a CLI error"
}

test_capture_rejects_malformed_target() {
  local out status
  superset_case capture-bad-target
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_capture no-colon-here 5' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "capture should refuse a target with no workspace:terminal colon"
  [ ! -s "$LOG" ] || fail "capture should not call the CLI for a malformed target"
  pass "fm_backend_superset_capture: refuses a malformed composite target before calling the CLI"
}

test_runtime_check_accepts_healthy_status() {
  local out
  superset_case runtime-ready
  printf '{"running":true,"healthy":true,"pid":1,"port":1}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" FM_SUPERSET_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_runtime_check' "$ROOT" )
  [ -z "$out" ] || fail "runtime_check should be quiet on a running, healthy status, got '$out'"
  assert_contains "$(cat "$LOG")" $'superset\x1f''status'$'\x1f''--json' \
    "runtime_check did not call superset status --json"
  pass "fm_backend_superset_runtime_check: accepts a running, healthy host service"
}

test_runtime_check_refuses_unhealthy_status() {
  local out status
  superset_case runtime-unhealthy
  printf '{"running":true,"healthy":false}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" FM_SUPERSET_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_runtime_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check should fail when the host service is not healthy"
  assert_contains "$out" "requires a running, healthy host service" "runtime_check should explain the readiness requirement"
  pass "fm_backend_superset_runtime_check: fails closed when the host service is unhealthy"
}

test_send_literal_stages_without_submitting() {
  superset_case send-literal
  printf '{"terminalId":"term-1","submitted":false}\n' > "$RESP/1.out"
  PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_send_literal ws-1:term-1 "typed only"' "$ROOT"
  expect_code 0 $? "send_literal should succeed"
  assert_contains "$(cat "$LOG")" $'superset\x1f''terminals'$'\x1f''send'$'\x1f''--workspace'$'\x1f''ws-1'$'\x1f''--terminal'$'\x1f''term-1'$'\x1f''--text'$'\x1f''typed only'$'\x1f''--no-submit'$'\x1f''--json' \
    "send_literal did not send text with --no-submit"
  pass "fm_backend_superset_send_literal: sends text without submitting"
}

test_send_key_enter_sends_single_space() {
  superset_case send-key-enter
  printf '{"terminalId":"term-1","submitted":true}\n' > "$RESP/1.out"
  PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_send_key ws-1:term-1 Enter' "$ROOT"
  expect_code 0 $? "send_key Enter should succeed"
  assert_contains "$(cat "$LOG")" $'superset\x1f''terminals'$'\x1f''send'$'\x1f''--workspace'$'\x1f''ws-1'$'\x1f''--terminal'$'\x1f''term-1'$'\x1f''--text'$'\x1f'' '$'\x1f''--json' \
    "send_key Enter did not send a single-space --text (the CLI rejects an empty --text)"
  pass "fm_backend_superset_send_key: Enter sends a single space, not an empty string"
}

test_send_key_ctrl_c_sends_raw_interrupt_byte() {
  superset_case send-key-ctrlc
  printf '{"terminalId":"term-1","submitted":true}\n' > "$RESP/1.out"
  PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_send_key ws-1:term-1 C-c' "$ROOT"
  expect_code 0 $? "send_key C-c should succeed"
  assert_contains "$(cat "$LOG")" $'superset\x1fterminals\x1fsend\x1f--workspace\x1fws-1\x1f--terminal\x1fterm-1\x1f--text\x1f\x03\x1f--json' \
    "send_key C-c did not send the raw \\x03 interrupt byte"
  pass "fm_backend_superset_send_key: C-c sends the raw Ctrl-C byte, verified live to deliver a real interrupt"
}

test_send_key_refuses_unsupported_key() {
  local out status
  superset_case send-key-unsupported
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_send_key ws-1:term-1 Escape' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse Escape - Ctrl-U was verified live to not map to a line-kill, so Escape is not claimed either"
  assert_contains "$out" "unsupported Superset key 'Escape'" "send_key did not name the unsupported key"
  [ ! -s "$LOG" ] || fail "an unsupported key should not call the CLI"
  pass "fm_backend_superset_send_key: refuses Escape and Ctrl-U instead of guessing at unverified primitives"
}

test_send_text_submit_verifies_empty_composer_after_enter() {
  local out
  superset_case send-submit-empty
  printf '{"terminalId":"term-1","submitted":false}\n' > "$RESP/1.out"
  printf '{"terminalId":"term-1","submitted":true}\n' > "$RESP/2.out"
  printf '{"terminalId":"term-1","cols":80,"rows":24,"text":"╭───╮\\n│ > │\\n╰───╯"}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_send_text_submit ws-1:term-1 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty on a successful submit, got '$out'"
  assert_contains "$(cat "$LOG")" $'superset\x1f''terminals'$'\x1f''send'$'\x1f''--workspace'$'\x1f''ws-1'$'\x1f''--terminal'$'\x1f''term-1'$'\x1f''--text'$'\x1f''hello captain'$'\x1f''--no-submit'$'\x1f''--json' \
    "send_text_submit did not type the text unsubmitted before Enter"
  assert_contains "$(cat "$LOG")" $'superset\x1f''terminals'$'\x1f''send'$'\x1f''--workspace'$'\x1f''ws-1'$'\x1f''--terminal'$'\x1f''term-1'$'\x1f''--text'$'\x1f'' '$'\x1f''--json' \
    "send_text_submit did not send Enter after typing"
  pass "fm_backend_superset_send_text_submit: verifies an empty composer after Enter"
}

test_send_text_submit_retries_when_composer_stays_pending() {
  local out log_text enter_count
  superset_case send-submit-pending
  printf '{"terminalId":"term-1","submitted":false}\n' > "$RESP/1.out"
  printf '{"terminalId":"term-1","submitted":true}\n' > "$RESP/2.out"
  printf '{"terminalId":"term-1","cols":80,"rows":24,"text":"╭─────────────────╮\\n│ > hello captain │\\n╰─────────────────╯"}\n' > "$RESP/3.out"
  printf '{"terminalId":"term-1","submitted":true}\n' > "$RESP/4.out"
  printf '{"terminalId":"term-1","cols":80,"rows":24,"text":"╭─────────────────╮\\n│ >               │\\n╰─────────────────╯"}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_send_text_submit ws-1:term-1 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should retry Enter until the composer clears, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'superset\x1fterminals\x1fsend\x1f--workspace\x1fws-1\x1f--terminal\x1fterm-1\x1f--text\x1f \x1f--json')
  [ "$enter_count" -eq 2 ] || fail "send_text_submit should send Enter twice when the first read is pending, got $enter_count"
  pass "fm_backend_superset_send_text_submit: retries Enter while the composer remains pending"
}

test_send_text_submit_reports_send_failed() {
  local out
  superset_case send-fail
  printf 'Error: text: Too small: expected string to have >=1 characters\n' > "$RESP/1.err"
  printf '1\n' > "$RESP/1.exit"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_send_text_submit ws-1:term-1 "hello" 1 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "failed Superset send should report send-failed, got '$out'"
  pass "fm_backend_superset_send_text_submit: reports send-failed when the CLI send fails"
}

test_composer_state_bare_shell_prompt_is_unknown() {
  local out
  superset_case composer-bare-shell
  printf '{"terminalId":"term-1","cols":80,"rows":24,"text":"(main) %% "}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_composer_state ws-1:term-1' "$ROOT" )
  [ "$out" = unknown ] || fail "a bare shell prompt (no bordered composer row) must read unknown, got '$out'"
  pass "fm_backend_superset_composer_state: a bare shell prompt reads unknown (unsafe-for-injection), never empty"
}

test_composer_state_reads_pending_input() {
  local out
  superset_case composer-pending
  printf '{"terminalId":"term-1","cols":80,"rows":24,"text":"╭─────────────────╮\\n│ > hello captain │\\n╰─────────────────╯"}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_composer_state ws-1:term-1' "$ROOT" )
  [ "$out" = pending ] || fail "unsubmitted composer text should read pending, got '$out'"
  pass "fm_backend_superset_composer_state: unsubmitted composer text reads pending"
}

test_kill_is_best_effort_close() {
  superset_case kill
  printf '1\n' > "$RESP/1.exit"
  PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_kill ws-1:term-1' "$ROOT"
  expect_code 0 $? "kill should stay best-effort when terminals close fails"
  assert_contains "$(cat "$LOG")" $'superset\x1f''terminals'$'\x1f''close'$'\x1f''--workspace'$'\x1f''ws-1'$'\x1f''--terminal'$'\x1f''term-1'$'\x1f''--json' \
    "kill did not call terminals close"
  pass "fm_backend_superset_kill: calls terminals close and stays best-effort"
}

test_remove_worktree_refuses_empty_id() {
  local out status
  superset_case remove-empty
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_remove_worktree ""' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree should fail when the workspace id is empty"
  assert_contains "$out" "missing Superset workspace id" "remove_worktree did not explain the missing id"
  [ ! -s "$LOG" ] || fail "remove_worktree should not call the CLI with an empty id"
  pass "fm_backend_superset_remove_worktree: refuses empty workspace ids"
}

test_remove_worktree_deletes_workspace() {
  superset_case remove
  printf '{"deleted":["ws-1"],"warnings":[]}\n' > "$RESP/1.out"
  PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_remove_worktree ws-1' "$ROOT"
  expect_code 0 $? "remove_worktree should succeed on a normal delete"
  assert_contains "$(cat "$LOG")" $'superset\x1f''ws'$'\x1f''delete'$'\x1f''ws-1'$'\x1f''--local'$'\x1f''--json' \
    "remove_worktree did not call ws delete --local"
  pass "fm_backend_superset_remove_worktree: calls ws delete --local for the recorded workspace id"
}

test_worktree_path_resolves_id() {
  local out
  superset_case path-resolve
  printf '{"id":"ws-1","worktreePath":"/tmp/superset-wt","worktreeExists":true}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_worktree_path ws-1' "$ROOT" )
  [ "$out" = /tmp/superset-wt ] || fail "worktree_path should print the resolved path, got '$out'"
  assert_contains "$(cat "$LOG")" $'superset\x1f''ws'$'\x1f''get'$'\x1f''ws-1'$'\x1f''--json' \
    "worktree_path did not call ws get"
  pass "fm_backend_superset_worktree_path: resolves a Superset workspace id to its path"
}

test_parse_target_splits_on_first_colon() {
  PATH="$FB:$PATH" bash -c '. "'"$ROOT"'/bin/backends/superset.sh"; fm_backend_superset_parse_target ws-1:term-1 && printf "%s|%s" "$FM_BACKEND_SUPERSET_WORKSPACE" "$FM_BACKEND_SUPERSET_TERMINAL"' \
    > "$TMP_ROOT/parse-out" 2>&1
  [ "$(cat "$TMP_ROOT/parse-out")" = "ws-1|term-1" ] || fail "parse_target should split workspace/terminal on the first colon, got '$(cat "$TMP_ROOT/parse-out")'"
  pass "fm_backend_superset_parse_target: splits a composite target on the first colon"
}

test_project_id_for_path_matches_registered_project() {
  local out proj canon
  superset_case project-match
  proj="$TMP_ROOT/project-match-proj"
  mkdir -p "$proj"
  canon=$(cd "$proj" && pwd)
  printf '[{"name":"demo","repo":"-","path":"%s","id":"proj-1"}]\n' "$canon" > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_project_id_for_path "'"$proj"'"' "$ROOT" )
  [ "$out" = proj-1 ] || fail "project_id_for_path should resolve the registered project id, got '$out'"
  pass "fm_backend_superset_project_id_for_path: matches a registered project by canonical path"
}

test_project_ensure_refuses_unregistered_project() {
  local out status proj
  superset_case project-unregistered
  proj="$TMP_ROOT/project-unregistered-proj"
  mkdir -p "$proj"
  printf '[]\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/superset.sh"; fm_backend_superset_project_ensure "'"$proj"'"' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "project_ensure should refuse an unregistered project rather than auto-registering it"
  assert_contains "$out" "no Superset project is registered for $proj" "project_ensure did not name the missing registration"
  assert_contains "$out" "superset projects create" "project_ensure did not name the exact registration command"
  pass "fm_backend_superset_project_ensure: refuses loudly instead of auto-registering an unverified shape"
}

test_spawn_writes_superset_metadata_and_launches_harness() {
  local proj wt data state config id out log
  id="ssspawnz1"
  proj="$TMP_ROOT/spawn-project"
  wt="$TMP_ROOT/spawn-wt"
  data="$TMP_ROOT/spawn-data"
  state="$TMP_ROOT/spawn-state"
  config="$TMP_ROOT/spawn-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  superset_case spawn
  log="$LOG"
  printf '[{"name":"demo","repo":"-","path":"%s","id":"proj-spawn"}]\n' "$proj" > "$RESP/1.out"
  printf '{"workspace":{"id":"ws-spawn","name":"fm-%s","branch":"fm-%s","type":"worktree"},"terminals":[{"terminalId":"setup-1","label":"Workspace Setup"}],"agents":[]}\n' "$id" "$id" > "$RESP/2.out"
  printf '{"id":"ws-spawn","worktreePath":"%s","worktreeExists":true}\n' "$wt" > "$RESP/3.out"
  printf '{"terminalId":"term-spawn","status":"active"}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend superset 2>&1 )
  expect_code 0 $? "fm-spawn.sh --backend superset should succeed with a fake CLI"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude kind=ship mode=no-mistakes yolo=off window=fm-$id worktree=$wt" \
    "spawn output missing the Superset window/worktree summary"
  assert_grep "backend=superset" "$state/$id.meta" "meta missing backend=superset"
  assert_grep "window=fm-$id" "$state/$id.meta" "meta missing the stable Superset window alias"
  assert_grep "superset_workspace_id=ws-spawn" "$state/$id.meta" "meta missing the Superset workspace id"
  assert_grep "superset_terminal_id=term-spawn" "$state/$id.meta" "meta missing the Superset terminal id"
  assert_grep "worktree=$wt" "$state/$id.meta" "meta missing the Superset worktree path"
  assert_not_contains "$(cat "$log")" $'superset\x1f''terminals'$'\x1f''send'$'\x1f''--workspace'$'\x1f''ws-spawn'$'\x1f''--terminal'$'\x1f''setup-1' \
    "spawn should never reuse the implicit Workspace Setup terminal"
  assert_contains "$(cat "$log")" $'superset\x1f''terminals'$'\x1f''send'$'\x1f''--workspace'$'\x1f''ws-spawn'$'\x1f''--terminal'$'\x1f''term-spawn'$'\x1f''--text'$'\x1f''export GOTMPDIR=/tmp/fm-ssspawnz1/gotmp'$'\x1f''--json' \
    "spawn did not export GOTMPDIR through the Superset terminal"
  assert_contains "$(cat "$log")" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions" \
    "spawn did not send the selected harness launch command through Superset"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend superset: creates its own terminal, records metadata, launches harness"
}

test_spawn_refuses_superset_secondmate_before_home_mutation() {
  local home subhome data state config id out status
  id="sssmz1"
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
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend superset --secondmate 2>&1 )
  status=$?
  set +e
  [ "$status" -ne 0 ] || fail "backend=superset --secondmate should be refused"
  assert_contains "$out" "backend=superset does not support --secondmate spawns yet" \
    "superset secondmate refusal should happen at backend selection"
  assert_absent "$subhome/config/crew-harness" \
    "superset secondmate refusal should not propagate inherited local material into the secondmate home"
  pass "fm-spawn.sh --backend superset --secondmate: refuses before secondmate-home mutation"
}

test_spawn_refuses_superset_when_runtime_not_ready() {
  local proj data state config id out status
  id="ssruntimez6"
  proj="$TMP_ROOT/runtime-down-project"
  data="$TMP_ROOT/runtime-down-data"
  state="$TMP_ROOT/runtime-down-state"
  config="$TMP_ROOT/runtime-down-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  superset_case runtime-down-spawn
  printf '{"running":true,"healthy":false}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" FM_SUPERSET_STATUS_RESPONSE=sequence \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend superset 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh --backend superset should refuse when the host service is unhealthy"
  assert_contains "$out" "requires a running, healthy host service" \
    "runtime readiness refusal should explain the Superset requirement"
  assert_absent "$state/$id.meta" "runtime refusal must not record metadata"
  assert_contains "$(cat "$LOG")" $'superset\x1f''status'$'\x1f''--json' \
    "spawn did not probe Superset runtime readiness"
  assert_not_contains "$(cat "$LOG")" $'superset\x1f''projects' \
    "spawn should fail before project lookup when the host service is not ready"
  pass "fm-spawn.sh --backend superset: refuses before mutation when the host service is not ready"
}

test_spawn_removes_superset_workspace_when_terminal_create_fails() {
  local proj wt data state config id out status
  id="sstermfailz8"
  proj="$TMP_ROOT/terminal-fail-project"
  wt="$TMP_ROOT/terminal-fail-wt"
  data="$TMP_ROOT/terminal-fail-data"
  state="$TMP_ROOT/terminal-fail-state"
  config="$TMP_ROOT/terminal-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  superset_case terminal-fail
  printf '[{"name":"demo","repo":"-","path":"%s","id":"proj-tf"}]\n' "$proj" > "$RESP/1.out"
  printf '{"workspace":{"id":"ws-terminal-fail"},"terminals":[],"agents":[]}\n' > "$RESP/2.out"
  printf '{"id":"ws-terminal-fail","worktreePath":"%s"}\n' "$wt" > "$RESP/3.out"
  printf 'Error: internal_error\n' > "$RESP/4.err"
  printf '1\n' > "$RESP/4.exit"
  printf '{"deleted":["ws-terminal-fail"],"warnings":[]}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend superset 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Superset spawn should fail when terminal creation fails"
  assert_absent "$state/$id.meta" "terminal-create abort should not record metadata after successful cleanup"
  assert_contains "$(cat "$LOG")" $'superset\x1f''terminals'$'\x1f''create'$'\x1f''--workspace'$'\x1f''ws-terminal-fail'$'\x1f''--json' \
    "Superset spawn should attempt terminal creation before abort cleanup"
  assert_contains "$(cat "$LOG")" $'superset\x1f''ws'$'\x1f''delete'$'\x1f''ws-terminal-fail'$'\x1f''--local'$'\x1f''--json' \
    "Superset spawn should remove the workspace when terminal creation fails"
  pass "fm-spawn.sh --backend superset: removes the workspace when terminal creation fails"
}

test_spawn_preserves_superset_metadata_when_abort_cleanup_fails() {
  local proj wt data state config id out status
  id="sscleanupleakz0"
  proj="$TMP_ROOT/cleanup-fail-project"
  wt="$TMP_ROOT/cleanup-fail-wt"
  data="$TMP_ROOT/cleanup-fail-data"
  state="$TMP_ROOT/cleanup-fail-state"
  config="$TMP_ROOT/cleanup-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  superset_case cleanup-fail
  printf '[{"name":"demo","repo":"-","path":"%s","id":"proj-cf"}]\n' "$proj" > "$RESP/1.out"
  printf '{"workspace":{"id":"ws-cleanup-fail"},"terminals":[],"agents":[]}\n' > "$RESP/2.out"
  printf '{"id":"ws-cleanup-fail","worktreePath":"%s"}\n' "$wt" > "$RESP/3.out"
  printf 'Error: internal_error\n' > "$RESP/4.err"
  printf '1\n' > "$RESP/4.exit"
  printf 'Error: internal_error\n' > "$RESP/5.err"
  printf '1\n' > "$RESP/5.exit"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend superset 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Superset spawn should fail when terminal creation and abort cleanup both fail"
  assert_contains "$(cat "$LOG")" $'superset\x1f''ws'$'\x1f''delete'$'\x1f''ws-cleanup-fail'$'\x1f''--local'$'\x1f''--json' \
    "Superset spawn should attempt cleanup before preserving metadata"
  assert_present "$state/$id.meta" "failed Superset abort cleanup should preserve metadata"
  assert_grep "window=fm-$id" "$state/$id.meta" "preserved metadata missing the stable window alias"
  assert_grep "backend=superset" "$state/$id.meta" "preserved metadata missing backend=superset"
  assert_grep "superset_workspace_id=ws-cleanup-fail" "$state/$id.meta" "preserved metadata missing the Superset workspace id"
  assert_no_grep "superset_terminal_id=" "$state/$id.meta" "preserved metadata should not invent a terminal id"
  pass "fm-spawn.sh --backend superset: preserves metadata when abort cleanup fails"
}

test_spawn_refuses_superset_nonisolated_worktree() {
  local proj data state config id out status
  id="ssbadwtz4"
  proj="$TMP_ROOT/bad-spawn-project"
  data="$TMP_ROOT/bad-spawn-data"
  state="$TMP_ROOT/bad-spawn-state"
  config="$TMP_ROOT/bad-spawn-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  superset_case bad-spawn
  printf '[{"name":"demo","repo":"-","path":"%s","id":"proj-bad"}]\n' "$proj" > "$RESP/1.out"
  printf '{"workspace":{"id":"ws-bad"},"terminals":[],"agents":[]}\n' > "$RESP/2.out"
  printf '{"id":"ws-bad","worktreePath":"%s"}\n' "$proj" > "$RESP/3.out"
  printf '{"deleted":["ws-bad"],"warnings":[]}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_SUPERSET_LOG="$LOG" FM_SUPERSET_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend superset 2>&1 )
  status=$?
  expect_code 1 "$status" "fm-spawn.sh --backend superset should refuse a primary checkout worktree"
  assert_contains "$out" "superset ws create did not yield an isolated worktree" \
    "Superset spawn should reuse the isolated-worktree guard"
  assert_absent "$state/$id.meta" "aborted Superset spawn must not record meta"
  assert_not_contains "$(cat "$LOG")" $'superset\x1f''terminals'$'\x1f''create' \
    "Superset spawn should validate the worktree before creating a terminal"
  assert_contains "$(cat "$LOG")" $'superset\x1f''ws'$'\x1f''delete'$'\x1f''ws-bad'$'\x1f''--local'$'\x1f''--json' \
    "Superset spawn should remove the workspace after validation aborts"
  pass "fm-spawn.sh --backend superset: refuses non-isolated worktrees before creating a terminal"
}
test_capture_reads_terminal_text
test_capture_fails_on_cli_error
test_capture_rejects_malformed_target
test_runtime_check_accepts_healthy_status
test_runtime_check_refuses_unhealthy_status
test_send_literal_stages_without_submitting
test_send_key_enter_sends_single_space
test_send_key_ctrl_c_sends_raw_interrupt_byte
test_send_key_refuses_unsupported_key
test_send_text_submit_verifies_empty_composer_after_enter
test_send_text_submit_retries_when_composer_stays_pending
test_send_text_submit_reports_send_failed
test_composer_state_bare_shell_prompt_is_unknown
test_composer_state_reads_pending_input
test_kill_is_best_effort_close
test_remove_worktree_refuses_empty_id
test_remove_worktree_deletes_workspace
test_worktree_path_resolves_id
test_parse_target_splits_on_first_colon
test_project_id_for_path_matches_registered_project
test_project_ensure_refuses_unregistered_project
test_spawn_writes_superset_metadata_and_launches_harness
test_spawn_refuses_superset_secondmate_before_home_mutation
test_spawn_refuses_superset_when_runtime_not_ready
test_spawn_removes_superset_workspace_when_terminal_create_fails
test_spawn_preserves_superset_metadata_when_abort_cleanup_fails
test_spawn_refuses_superset_nonisolated_worktree
