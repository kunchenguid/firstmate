#!/usr/bin/env bash
# Behavior tests for the watcher-arm PreToolUse seatbelt (docs/arm-pretool-check.md).
#
# bin/fm-arm-pretool-check.sh is the single owner of the anti-pattern
# detection; this suite drives it through its CLI (--command) and stdin JSON
# modes and asserts the per-harness wiring files invoke it, without spawning
# any real harness (that empirical evidence lives in docs/arm-pretool-check.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-arm-pretool-check.sh"

# --- CLI mode: table-driven allow/deny -------------------------------------

assert_allow() {
  local desc=$1 cmd=$2 out rc
  out=$("$CHECK" --command "$cmd" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected allow (exit 0) for [$cmd] ($desc), got exit $rc: $out"
  pass "allow: $desc"
}

assert_deny() {
  local desc=$1 cmd=$2 out rc
  out=$("$CHECK" --command "$cmd" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "expected deny (exit 2) for [$cmd] ($desc), got exit $rc: $out"
  pass "deny: $desc"
}

# DENY acceptance cases (task spec)
assert_deny "trailing shell background operator" 'bin/fm-watch-arm.sh &'
assert_deny "piped into head, then backgrounded" 'bin/fm-watch-arm.sh 2>&1 | head -2 &'
assert_deny "bundled after another command, then backgrounded" 'tasks-axi done x --pr y; bin/fm-watch-arm.sh &'
assert_deny "broad pkill against the watcher" 'pkill -f bin/fm-watch.sh'
assert_deny "mid-command shell background before wait" 'bin/fm-watch-arm.sh & wait'
assert_deny "mid-command shell background before follow-up work" 'bin/fm-watch-arm.sh & echo done'
assert_deny "checkpoint && follow-up work is bundling" 'bin/fm-watch-checkpoint.sh --seconds 180 && echo done'
assert_deny "checkpoint bare background before follow-up work" 'bin/fm-watch-checkpoint.sh --seconds 180 & echo done'
assert_deny "export leading statement cannot hide bundled work" 'export FM_HOME=/tmp && tasks-axi done x; exec bin/fm-watch-arm.sh'
assert_deny "arm output redirection hides status lines" 'exec bin/fm-watch-arm.sh >/dev/null'
assert_deny "checkpoint output redirection hides status lines" 'bin/fm-watch-checkpoint.sh --seconds 180 >/tmp/out'
assert_deny "export command substitution cannot hide bundled work" "export X=\$(tasks-axi done x); exec bin/fm-watch-arm.sh"
assert_deny "checkpoint command substitution cannot hide bundled work" "bin/fm-watch-checkpoint.sh --seconds \$(tasks-axi done x)"
assert_deny "nested bash payload cannot background the arm" "bash -lc 'bin/fm-watch-arm.sh &'"
assert_deny "absolute nested shell payload cannot background the arm" "/bin/sh -c 'bin/fm-watch-arm.sh &'"
assert_deny "nested sh payload cannot redirect checkpoint output" "sh -c 'bin/fm-watch-checkpoint.sh --seconds 180 >/tmp/out'"
assert_deny "nested zsh payload cannot run checkpoint substitution" "zsh -c 'bin/fm-watch-checkpoint.sh --seconds \$(tasks-axi done x)'"
assert_deny "eval payload cannot background the arm" "eval 'bin/fm-watch-arm.sh &'"

# ALLOW acceptance cases (task spec)
assert_allow "bare blessed exec of the arm" 'exec bin/fm-watch-arm.sh'
assert_allow "guarded x-mode source then exec arm" '[ -f config/x-mode.env ] && . config/x-mode.env; exec bin/fm-watch-arm.sh'
assert_allow "codex foreground checkpoint, no background" 'bin/fm-watch-checkpoint.sh --seconds 180'
assert_allow "unrelated read of the lock file" 'ls state/.watch.lock'
assert_allow "pure status check, no arm" 'bin/fm-guard.sh'

# Additional coverage beyond the required table
assert_deny "nohup on the arm" 'nohup bin/fm-watch-arm.sh'
assert_deny "disown after the arm" 'bin/fm-watch-arm.sh; disown'
assert_deny "piped into tail" 'bin/fm-watch-arm.sh | tail -f'
assert_deny "arm && another command bundled" 'exec bin/fm-watch-arm.sh && echo done'
assert_deny "checkpoint backgrounded" 'bin/fm-watch-checkpoint.sh --seconds 60 &'
assert_deny "broad pkill without -f" 'pkill fm-watch.sh'
assert_deny "arm stderr redirection is still redirection" 'exec bin/fm-watch-arm.sh 2>/tmp/err'
assert_deny "checkpoint stderr/stdout merge is still redirection" 'bin/fm-watch-checkpoint.sh --seconds 180 2>&1'
assert_deny "export backtick substitution cannot hide bundled work" "export X=\`tasks-axi done x\`; exec bin/fm-watch-arm.sh"
assert_deny "export process substitution cannot hide bundled work" 'export X=<(tasks-axi done x); exec bin/fm-watch-arm.sh'
assert_deny "checkpoint process substitution cannot hide bundled work" 'bin/fm-watch-checkpoint.sh --file <(echo x)'
assert_allow "arm with --restart, blessed" 'exec bin/fm-watch-arm.sh --restart'
# The blessed leading-statement separator is ';' (matching the documented
# x-mode-guard recipe), not '&&' - a bare 'cd X && exec arm' is bundling by
# design, covered by the deny case below.
assert_allow "cd then exec arm, blessed leading statement" 'cd /home/fm; exec bin/fm-watch-arm.sh'
assert_allow "export then exec arm, blessed leading statement" 'export FM_HOME=/home/fm; exec bin/fm-watch-arm.sh'
assert_deny "cd && exec arm is bundling, not the blessed ';' shape" 'cd /home/fm && exec bin/fm-watch-arm.sh'
assert_allow "totally unrelated command" 'git status'
assert_allow "empty command" ''

# --- CLI parsing -------------------------------------------------------------

test_command_equals_form() {
  "$CHECK" --command='bin/fm-watch-arm.sh &' >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "--command=<val> form must parse the same as --command <val>"
  pass "--command=<val> equals-form parses correctly"
}

test_background_flag_accepted_and_non_gating() {
  local rc_bg rc_nobg
  "$CHECK" --command 'exec bin/fm-watch-arm.sh' --background true >/dev/null 2>&1
  rc_bg=$?
  "$CHECK" --command 'exec bin/fm-watch-arm.sh' >/dev/null 2>&1
  rc_nobg=$?
  [ "$rc_bg" -eq 0 ] || fail "--background true must not change the allow decision on its own, got exit $rc_bg"
  [ "$rc_bg" -eq "$rc_nobg" ] || fail "--background flag must be accepted without altering the decision"
  pass "--background is accepted for interface parity and is never itself a deny signal"
}

test_unknown_flag_errors() {
  "$CHECK" --bogus-flag >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "an unrecognized flag must exit non-zero, not silently allow"
  pass "unknown CLI flag is rejected"
}

# --- stdin JSON mode ----------------------------------------------------------

test_stdin_grok_schema_deny() {
  local out rc
  out=$(printf '%s' '{"toolInput":{"command":"bin/fm-watch-arm.sh &","background":false},"toolName":"run_terminal_command"}' | "$CHECK" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "grok toolInput.command schema must be read and denied, got exit $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 || fail "stdout must carry Grok's {\"decision\":\"deny\",...} shape: $out"
  pass "stdin grok schema (toolInput.command): denied with Grok-shaped stdout JSON"
}

test_stdin_claude_codex_schema_allow() {
  local rc
  printf '%s' '{"tool_input":{"command":"exec bin/fm-watch-arm.sh"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "claude/codex tool_input.command schema must be read and allowed for the blessed shape, got exit $rc"
  pass "stdin claude/codex schema (tool_input.command): blessed shape allowed"
}

test_stdin_claude_codex_schema_deny() {
  local rc
  printf '%s' '{"tool_input":{"command":"bin/fm-watch-arm.sh &"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "claude/codex tool_input.command schema must be denied for the backgrounded shape, got exit $rc"
  pass "stdin claude/codex schema (tool_input.command): backgrounded shape denied"
}

test_stdin_unrelated_command_allowed() {
  local rc
  printf '%s' '{"tool_input":{"command":"ls -la"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "an unrelated command must pass through allowed, got exit $rc"
  pass "stdin: unrelated command is a fast allow"
}

# --- fail-open ----------------------------------------------------------------

test_failopen_empty_stdin() {
  local rc
  printf '' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "empty stdin must fail open (exit 0), got exit $rc"
  pass "fail-open: empty stdin"
}

test_failopen_garbage_stdin() {
  local rc
  printf 'not json at all {{{' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "unparseable stdin must fail open (exit 0), got exit $rc"
  pass "fail-open: unparseable JSON on stdin"
}

test_failopen_missing_jq() {
  local dir fakebin rc
  dir=$(fm_test_tmproot fm-arm-pretool-check)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  local tool
  for tool in bash grep sed tr; do
    real=$(command -v "$tool")
    ln -sf "$real" "$fakebin/$tool"
  done
  PATH="$fakebin" bash -c "printf '%s' '{\"tool_input\":{\"command\":\"bin/fm-watch-arm.sh &\"}}' | '$CHECK'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq must fail open (exit 0) rather than crash-deny, got exit $rc"
  pass "fail-open: missing jq on stdin path"
}

# --- --claude output shaping ---------------------------------------------------

test_claude_mode_stdout_empty_on_deny() {
  local out err rc
  out=$("$CHECK" --claude --command 'bin/fm-watch-arm.sh &' 2>/tmp/fm-arm-pretool-check-claude-stderr.$$)
  rc=$?
  err=$(cat "/tmp/fm-arm-pretool-check-claude-stderr.$$" 2>/dev/null)
  rm -f "/tmp/fm-arm-pretool-check-claude-stderr.$$"
  [ "$rc" -eq 2 ] || fail "--claude deny must still exit 2, got $rc"
  [ -z "$out" ] || fail "--claude deny must leave stdout EMPTY (Claude Code only honors a stderr-only deny), got: $out"
  printf '%s' "$err" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || fail "--claude deny must put hookSpecificOutput.permissionDecision=deny on stderr: $err"
  pass "--claude: stdout empty, stderr carries hookSpecificOutput deny JSON"
}

test_default_mode_stdout_has_grok_json_on_deny() {
  local out rc
  out=$("$CHECK" --command 'bin/fm-watch-arm.sh &' 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "default deny must exit 2, got $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 \
    || fail "default (non-claude) deny must put Grok's decision JSON on stdout: $out"
  pass "default mode: stdout carries Grok-shaped decision JSON on deny"
}

test_allow_is_silent_both_modes() {
  local out1 out2
  out1=$("$CHECK" --command 'exec bin/fm-watch-arm.sh' 2>&1)
  out2=$("$CHECK" --claude --command 'exec bin/fm-watch-arm.sh' 2>&1)
  [ -z "$out1" ] || fail "default allow must be silent, got: $out1"
  [ -z "$out2" ] || fail "--claude allow must be silent, got: $out2"
  pass "allow is silent on both stdout and stderr in default and --claude mode"
}

# --- harness wiring: each adapter invokes the shared checker -----------------

test_grok_pretool_hook_wired() {
  local settings command
  settings="$ROOT/.grok/hooks/fm-primary-pretool-check.json"
  [ -f "$settings" ] || fail "tracked grok primary PreToolUse hook config is missing"
  command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "PreToolUse hook command is missing from grok primary hook config"
  assert_contains "$command" 'GROK_WORKSPACE_ROOT' "grok pretool hook must anchor from GROK_WORKSPACE_ROOT"
  assert_contains "$command" 'fm-arm-pretool-check.sh' "grok pretool hook must invoke the shared checker"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  assert_not_contains "$command" 'root=${GROK_WORKSPACE_ROOT' "grok pretool hook must not assign a bare \$root var (breaks grok's own \${VAR} pre-substitution; see docs/arm-pretool-check.md)"
  local matcher
  matcher=$(jq -r '.hooks.PreToolUse[0].matcher // empty' "$settings")
  [ "$matcher" = "Bash" ] || fail "grok pretool hook must matcher-scope to Bash, got: $matcher"
  pass ".grok primary hook: PreToolUse hook invokes the shared checker"
}

test_grok_turnend_hook_uses_safe_var_pattern() {
  local settings command
  settings="$ROOT/.grok/hooks/fm-primary-turnend-guard.json"
  [ -f "$settings" ] || fail "tracked grok primary Stop hook config is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  # shellcheck disable=SC2016  # single quotes are deliberate: literal needle strings, not expansions
  assert_not_contains "$command" 'root=${GROK_WORKSPACE_ROOT' "grok Stop hook must not assign a bare \$root var either (regression fixed 2026-07-09, docs/arm-pretool-check.md)"
  # shellcheck disable=SC2016
  assert_contains "$command" '${GROK_WORKSPACE_ROOT:-}' "grok Stop hook must reference GROK_WORKSPACE_ROOT with an inline default every time"
  pass ".grok primary hook: Stop hook uses the \${VAR:-} pattern throughout (no bare \$root)"
}

test_claude_settings_pretool_hook_wired() {
  local settings command
  settings="$ROOT/.claude/settings.json"
  [ -f "$settings" ] || fail "tracked claude primary settings are missing"
  command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "PreToolUse hook command is missing from claude primary settings"
  assert_contains "$command" 'CLAUDE_PROJECT_DIR' "claude pretool hook must anchor via CLAUDE_PROJECT_DIR"
  assert_contains "$command" 'fm-arm-pretool-check.sh' "claude pretool hook must invoke the shared checker"
  assert_contains "$command" '--claude' "claude pretool hook must pass --claude so stdout stays empty on deny"
  local matcher
  matcher=$(jq -r '.hooks.PreToolUse[0].matcher // empty' "$settings")
  [ "$matcher" = "Bash" ] || fail "claude pretool hook must matcher-scope to Bash, got: $matcher"
  pass ".claude/settings.json: PreToolUse hook invokes the shared checker with --claude"
}

test_codex_hooks_pretool_wired() {
  local settings command
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked codex primary hooks are missing"
  command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "PreToolUse hook command is missing from codex primary hooks"
  assert_contains "$command" 'fm-arm-pretool-check.sh' "codex pretool hook must invoke the shared checker"
  assert_contains "$command" 'pwd -P' "codex pretool hook must anchor to the hook process root like the Stop hook does"
  local matcher
  matcher=$(jq -r '.hooks.PreToolUse[0].matcher // empty' "$settings")
  [ "$matcher" = "Bash" ] || fail "codex pretool hook must matcher-scope to Bash, got: $matcher"
  pass ".codex/hooks.json: PreToolUse hook invokes the shared checker"
}

test_opencode_pretool_plugin_wired() {
  local plugin content
  plugin="$ROOT/.opencode/plugins/fm-primary-pretool-check.js"
  [ -f "$plugin" ] || fail "tracked opencode primary pretool plugin is missing"
  content=$(cat "$plugin")
  assert_contains "$content" 'tool.execute.before' "opencode pretool plugin must hook tool.execute.before"
  assert_contains "$content" 'fm-arm-pretool-check.sh' "opencode pretool plugin must invoke the shared checker"
  assert_contains "$content" 'throw new Error' "opencode pretool plugin must throw to block the tool call"
  pass ".opencode primary plugin: tool.execute.before invokes the shared checker and blocks by throwing"
}

test_pi_extension_carries_pretool_check() {
  local ext content
  ext="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  [ -f "$ext" ] || fail "tracked pi primary extension is missing"
  content=$(cat "$ext")
  assert_contains "$content" 'tool_call' "pi extension must hook tool_call for the pretool seatbelt"
  assert_contains "$content" 'fm-arm-pretool-check.sh' "pi extension must invoke the shared checker"
  assert_contains "$content" 'block: true' "pi extension must return block:true to deny"
  pass ".pi primary extension: tool_call handler invokes the shared checker and can block"
}

# --- shellcheck (belt-and-suspenders; CI/CONTRIBUTING.md also runs this) -----

test_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  shellcheck "$CHECK" >/dev/null 2>&1 || fail "bin/fm-arm-pretool-check.sh is not shellcheck-clean"
  pass "bin/fm-arm-pretool-check.sh is shellcheck-clean"
}

test_command_equals_form
test_background_flag_accepted_and_non_gating
test_unknown_flag_errors
test_stdin_grok_schema_deny
test_stdin_claude_codex_schema_allow
test_stdin_claude_codex_schema_deny
test_stdin_unrelated_command_allowed
test_failopen_empty_stdin
test_failopen_garbage_stdin
test_failopen_missing_jq
test_claude_mode_stdout_empty_on_deny
test_default_mode_stdout_has_grok_json_on_deny
test_allow_is_silent_both_modes
test_grok_pretool_hook_wired
test_grok_turnend_hook_uses_safe_var_pattern
test_claude_settings_pretool_hook_wired
test_codex_hooks_pretool_wired
test_opencode_pretool_plugin_wired
test_pi_extension_carries_pretool_check
test_shellcheck_clean
