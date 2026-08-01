#!/usr/bin/env bash
# Pure behavior tests for the exact-identity captain decision gate.
# No test launches, signals, or inspects an agent or terminal lifecycle.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CHECK="$ROOT/bin/fm-decision-pretool-check.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-decision-pretool-check.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

run_stdin() {
  local payload=$1 adapter=${2:-} rc
  : > "$TMP_ROOT/stdout"
  : > "$TMP_ROOT/stderr"
  set +e
  if [ -n "$adapter" ]; then
    printf '%s' "$payload" | "$CHECK" "$adapter" > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr"
  else
    printf '%s' "$payload" | "$CHECK" > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr"
  fi
  rc=$?
  set -e
  printf '%s\n' "$rc"
}

assert_silent_allow() {
  local payload=$1 label=$2 rc
  rc=$(run_stdin "$payload" --claude)
  [ "$rc" -eq 0 ] || fail "$label returned $rc instead of failing open"
  [ ! -s "$TMP_ROOT/stdout" ] || fail "$label wrote stdout"
  [ ! -s "$TMP_ROOT/stderr" ] || fail "$label wrote stderr"
  pass "$label allows silently"
}

assert_teaching_message() {
  local message=$1
  case "$message" in
    *'lavish-axi create --id <lowercase-slug> --title'*'--request <request.md> --questions <questions.json> --destination data/<id>/captain-answer.toon'*) ;;
    *) fail "deny message does not teach the complete lavish-axi create shape" ;;
  esac
  case "$message" in
    *'"key":"lowercase-slug"'*'"value":"option-a"'*'"label":"Option A"'*) ;;
    *) fail "deny message does not teach the question JSON schema" ;;
  esac
  case "$message" in
    *'For a yes/no, ask in plain chat instead.'*) ;;
    *) fail "deny message does not teach the plain-chat yes/no route" ;;
  esac
  case "$message" in
    *'Run: lavish answer <id>'*) ;;
    *) fail "deny message does not teach the captain-facing Lavish surface" ;;
  esac
}

test_claude_deny_contract() {
  local payload rc decision message
  payload='{"session_id":"session-1","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which route?","header":"Route","options":[{"label":"A","description":"First"},{"label":"B","description":"Second"}],"multiSelect":false}]}}'
  rc=$(run_stdin "$payload" --claude)
  [ "$rc" -eq 2 ] || fail "Claude deny returned $rc instead of 2"
  [ ! -s "$TMP_ROOT/stdout" ] || fail "Claude deny must keep stdout empty"
  [ -s "$TMP_ROOT/stderr" ] || fail "Claude deny must write stderr"
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$TMP_ROOT/stderr")
  [ "$decision" = deny ] || fail "Claude stderr is not a PreToolUse deny object"
  message=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "$TMP_ROOT/stderr")
  assert_teaching_message "$message"
  pass "Claude AskUserQuestion denies with empty stdout and teaching JSON on stderr"
}

test_codex_deny_contract() {
  local payload rc decision
  payload='{"session_id":"session-2","turn_id":"turn-1","hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_input":{"questions":[{"header":"Route","id":"route","question":"Which route?","options":[{"label":"A","description":"First"},{"label":"B","description":"Second"}]}]}}'
  rc=$(run_stdin "$payload")
  [ "$rc" -eq 2 ] || fail "Codex deny returned $rc instead of 2"
  [ ! -s "$TMP_ROOT/stdout" ] || fail "Codex deny must keep stdout empty"
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$TMP_ROOT/stderr")
  [ "$decision" = deny ] || fail "Codex stderr is not a PreToolUse deny object"
  pass "Codex request_user_input denies by exit 2 plus stderr"
}

test_grok_deny_contract() {
  local payload rc decision message
  payload='{"hookEventName":"PreToolUse","sessionId":"session-3","toolName":"ask_user_question","toolInput":{"questions":[{"question":"Which route?","options":[{"label":"A"},{"label":"B"}]}]}}'
  rc=$(run_stdin "$payload" --grok)
  [ "$rc" -eq 2 ] || fail "Grok deny returned $rc instead of 2"
  [ ! -s "$TMP_ROOT/stderr" ] || fail "Grok deny must keep stderr empty"
  decision=$(jq -r '.decision // empty' "$TMP_ROOT/stdout")
  [ "$decision" = deny ] || fail "Grok stdout is not a deny object"
  message=$(jq -r '.reason // empty' "$TMP_ROOT/stdout")
  assert_teaching_message "$message"
  pass "Grok ask_user_question denies with native stdout JSON"
}

test_opencode_cli_deny_contract() {
  local rc decision
  : > "$TMP_ROOT/stdout"
  : > "$TMP_ROOT/stderr"
  set +e
  "$CHECK" --tool-name question > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "OpenCode question deny returned $rc instead of 2"
  [ ! -s "$TMP_ROOT/stdout" ] || fail "OpenCode deny must keep stdout empty"
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$TMP_ROOT/stderr")
  [ "$decision" = deny ] || fail "OpenCode stderr is not a deny object"
  pass "OpenCode question denies through exact CLI tool identity"
}

test_exact_identity_only() {
  assert_silent_allow '{"tool_name":"Bash","tool_input":{"command":"printf AskUserQuestion request_user_input ask_user_question question"}}' "unrelated Bash tool with protected names only in command text"
  assert_silent_allow '{"tool_name":"Write","tool_input":{"content":"AskUserQuestion"}}' "unrelated Write tool with protected name only in prose"
  assert_silent_allow '{"tool_name":"AskUserQuestionExtra","tool_input":{}}' "near-match tool name"
  assert_silent_allow '{"tool_name":"askuserquestion","tool_input":{}}' "case-changed tool name"
}

test_malformed_transport_fails_open() {
  assert_silent_allow '' "empty stdin"
  assert_silent_allow '{not json' "malformed JSON"
  assert_silent_allow '{"tool_name":42}' "non-string tool identity"
  assert_silent_allow '{"tool_input":{"questions":[]}}' "missing tool identity"
}

test_missing_dependency_fails_open() {
  local rc
  : > "$TMP_ROOT/stdout"
  : > "$TMP_ROOT/stderr"
  set +e
  PATH='' /bin/bash "$CHECK" --tool-name AskUserQuestion > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "missing jq returned $rc instead of failing open"
  [ ! -s "$TMP_ROOT/stdout" ] || fail "missing jq wrote stdout"
  [ ! -s "$TMP_ROOT/stderr" ] || fail "missing jq wrote stderr"
  pass "missing jq fails open silently"
}

test_tracked_registration() {
  local command
  jq -e '[.hooks.PreToolUse[] | select(.matcher == "^AskUserQuestion$") | .hooks[] | select(.command == "\"$CLAUDE_PROJECT_DIR\"/bin/fm-decision-pretool-check.sh --claude")] | length == 1' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude tracked settings do not register the exact AskUserQuestion gate"

  command=$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "^request_user_input$") | .hooks[].command][0] // empty' "$ROOT/.codex/hooks.json")
  # shellcheck disable=SC2016  # The hook command must contain the literal payload variable reference.
  case "$command" in
    *'fm-decision-pretool-check.sh'*'printf "%s" "$payload"'*) ;;
    *) fail "Codex tracked hooks do not forward request_user_input payloads to the gate" ;;
  esac

  jq -e '.hooks.PreToolUse == [{matcher:"ask_user_question",hooks:[{type:"command",command:"bash -lc '\''[ -n \"${GROK_WORKSPACE_ROOT:-}\" ] || exit 0; exec \"${GROK_WORKSPACE_ROOT:-}/bin/fm-decision-pretool-check.sh\" --grok'\''",timeout:10}]}]' "$ROOT/.grok/hooks/fm-primary-decision-check.json" >/dev/null \
    || fail "Grok tracked hook is not the exact safe-variable decision registration"

  grep -F 'input?.tool !== "question"' "$ROOT/.opencode/plugins/fm-primary-decision-check.js" >/dev/null \
    || fail "OpenCode plugin does not exact-match the question tool"
  grep -F '["--tool-name", input.tool]' "$ROOT/.opencode/plugins/fm-primary-decision-check.js" >/dev/null \
    || fail "OpenCode plugin does not forward the separated exact tool identity"
  grep -F 'throw new Error' "$ROOT/.opencode/plugins/fm-primary-decision-check.js" >/dev/null \
    || fail "OpenCode plugin does not block by throwing"
  pass "all four tracked harness registrations are present and exact-name scoped"
}

test_claude_deny_contract
test_codex_deny_contract
test_grok_deny_contract
test_opencode_cli_deny_contract
test_exact_identity_only
test_malformed_transport_fails_open
test_missing_dependency_fails_open
test_tracked_registration
