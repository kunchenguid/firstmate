#!/usr/bin/env bash
# Behavior tests for the primary-session question-picker guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-question-tool-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-question-tool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q
cp "$ROOT/bin/fm-question-tool-pretool-check.sh" "$PRIMARY/bin/fm-question-tool-pretool-check.sh"
cp "$ROOT/bin/fm-primary-scope-lib.sh" "$PRIMARY/bin/fm-primary-scope-lib.sh"
chmod +x "$PRIMARY/bin/fm-question-tool-pretool-check.sh"

run_tool() {
  local tool=$1 rc=0
  shift
  : > "$OUT"
  : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$@" \
    "$CHECK" --tool "$tool" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 tool=$2 rc=0
  shift 2
  run_tool "$tool" "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label ($tool) must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label ($tool) allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label ($tool) allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 tool=$2 rc=0
  : > "$OUT"
  : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" --claude --tool "$tool" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label ($tool) must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label ($tool) Claude deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny omitted Claude's permission decision: $(cat "$ERR")"
  jq -e --arg tool "$tool" '.systemMessage | startswith("[question-picker]") and contains("blocked tool: " + $tool)' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny message lost its code or tool name: $(jq -r '.systemMessage' "$ERR")"
}

test_primary_denies_known_pickers() {
  local tool
  for tool in AskUserQuestion ask_user_question question functions.request_user_input; do
    expect_deny "primary picker" "$tool"
  done
  pass "a primary home denies every known question picker"
}

test_primary_keeps_ordinary_tools() {
  local tool
  for tool in Bash Read Edit Write Task Agent AskQuestion questions askuser mcp__srv__ask_user_question; do
    expect_allow "ordinary tool" "$tool"
  done
  pass "ordinary tools, near-misses, and MCP names stay available"
}

test_grok_stdout_shape_and_claude_stdin() {
  local rc=0
  : > "$OUT"
  : > "$ERR"
  printf '%s' '{"toolName":"ask_user_question"}' \
    | env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Grok-shaped stdin must deny, got exit $rc"
  jq -e '.decision == "deny" and (.reason | startswith("[question-picker]"))' "$OUT" >/dev/null 2>&1 \
    || fail "Grok deny omitted the stdout decision: $(cat "$OUT")"

  rc=0
  : > "$OUT"
  : > "$ERR"
  printf '%s' '{"tool_name":"AskUserQuestion"}' \
    | env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Claude-shaped stdin must deny, got exit $rc"
  [ ! -s "$OUT" ] || fail "Claude deny wrote stdout: $(cat "$OUT")"
  pass "stdin transports keep the Claude and Grok deny shapes"
}

test_malformed_transport_fails_open() {
  local rc=0
  : > "$OUT"
  : > "$ERR"
  printf '%s' '' \
    | env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "empty stdin must allow, got exit $rc"
  rc=0
  printf '%s' 'not-json' \
    | env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "malformed stdin must allow, got exit $rc"
  pass "malformed transport fails open"
}

test_worker_copy_and_secondmate() {
  local child="$TMP_ROOT/child" second="$TMP_ROOT/second" rc=0
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  printf '# fixture\n' > "$child/AGENTS.md"
  : > "$OUT"
  : > "$ERR"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --claude --tool AskUserQuestion > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a worker copy must stay inert, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "worker copy wrote stdout"
  [ ! -s "$ERR" ] || fail "worker copy wrote stderr"

  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/bin" "$second/state"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  rc=0
  FM_ROOT_OVERRIDE="$second" FM_HOME="$second" FM_STATE_OVERRIDE="$second/state" \
    "$CHECK" --claude --tool ask_user_question > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a marked secondmate home must deny the picker, got exit $rc"
  pass "a worker copy stays inert and a secondmate home denies the picker"
}

test_registered_hooks_deny_in_a_primary_fixture() {
  local fix="$TMP_ROOT/wired" cmd rc=0
  mkdir -p "$fix/bin" "$fix/state" "$fix/.codex" "$fix/.grok/hooks" "$fix/.claude"
  git -C "$fix" init -q
  printf '# fixture\n' > "$fix/AGENTS.md"
  cp "$ROOT/bin/fm-question-tool-pretool-check.sh" "$fix/bin/fm-question-tool-pretool-check.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$fix/bin/fm-primary-scope-lib.sh"
  chmod +x "$fix/bin/fm-question-tool-pretool-check.sh"
  cp "$ROOT/.codex/hooks.json" "$fix/.codex/hooks.json"
  cp "$ROOT/.grok/hooks/fm-primary-question-tool.json" "$fix/.grok/hooks/fm-primary-question-tool.json"
  cp "$ROOT/.claude/settings.json" "$fix/.claude/settings.json"

  cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher | test("ask_user_question")) | .hooks[0].command' \
    "$fix/.grok/hooks/fm-primary-question-tool.json")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "Grok question-picker hook command is missing"
  # Grok expands ${VAR:-} in the hook command before bash runs. Reproduce that.
  cmd=$(printf '%s' "$cmd" | sed "s|\${GROK_WORKSPACE_ROOT:-}|$fix|g")
  : > "$OUT"
  : > "$ERR"
  printf '%s' '{"toolName":"ask_user_question"}' \
    | bash -c "$cmd" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Grok hook command must deny in a primary fixture, got exit $rc: $(cat "$ERR") $(cat "$OUT")"
  jq -e '.decision == "deny"' "$OUT" >/dev/null 2>&1 || fail "Grok hook command omitted the deny object: $(cat "$OUT")"

  cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "functions.request_user_input") | .hooks[0].command' \
    "$fix/.codex/hooks.json")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "Codex question-picker hook command is missing"
  rc=0
  : > "$OUT"
  : > "$ERR"
  printf '%s' '{"tool_name":"functions.request_user_input"}' \
    | (cd "$fix" && bash -c "$cmd") > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Codex hook command must deny in a primary fixture, got exit $rc: $(cat "$ERR") $(cat "$OUT")"

  cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == ".*") | .hooks[].command | select(contains("fm-question-tool-pretool-check.sh"))' \
    "$fix/.claude/settings.json")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "Claude question-picker hook command is missing"
  rc=0
  : > "$OUT"
  : > "$ERR"
  printf '%s' '{"tool_name":"AskUserQuestion"}' \
    | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$fix" bash -c "$cmd" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Claude hook command must deny in a primary fixture, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "Claude hook command wrote stdout: $(cat "$OUT")"
  pass "the Grok, Codex, and Claude registrations deny the picker in a primary fixture"
}

test_primary_denies_known_pickers
test_primary_keeps_ordinary_tools
test_grok_stdout_shape_and_claude_stdin
test_malformed_transport_fails_open
test_worker_copy_and_secondmate
test_registered_hooks_deny_in_a_primary_fixture
