#!/usr/bin/env bash
# Portable behavior tests for Copilot CLI identity and primary hook translation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
LOCK_LIB="$ROOT/bin/fm-session-lock-lib.sh"
HOOK="$ROOT/bin/fm-copilot-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)

make_ps() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FM_FAKE_PS_COMM:-MainThread}" ;;
  *"args="*) printf '%s\n' "${FM_FAKE_PS_ARGS:-copilot}" ;;
  *"ppid="*) printf '%s\n' 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
}

test_environment_marker_wins() {
  local fakebin out
  fakebin="$TMP_ROOT/env-marker"
  make_ps "$fakebin"
  out=$(env -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT PATH="$fakebin:$PATH" \
    FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' COPILOT_CLI=1 CLAUDECODE=1 "$HARNESS")
  [ "$out" = copilot ] || fail "COPILOT_CLI marker detected as '$out'"
  out=$(env -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT PATH="$fakebin:$PATH" \
    FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' COPILOT_CLI=1 CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent "$HARNESS")
  [ "$out" = copilot ] || fail "COPILOT_CLI marker lost to inherited Cursor markers: '$out'"
  pass "Copilot's verified environment marker identifies the current harness"
}

test_process_shapes_are_anchored() {
  local fakebin out
  fakebin="$TMP_ROOT/process-shapes"
  make_ps "$fakebin"

  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='/opt/copilot/bin/copilot --allow-all' "$HARNESS")
  [ "$out" = copilot ] || fail "MainThread with Copilot argv zero detected as '$out'"

  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=node FM_FAKE_PS_ARGS='node runner.js copilot' "$HARNESS")
  [ "$out" = unknown ] || fail "an unrelated later copilot argument detected as '$out'"
  pass "Copilot process detection accepts argv zero and rejects later-argument false positives"
}

test_actual_host_overrides_inherited_markers() {
  local fakebin out versioned_claude
  fakebin="$TMP_ROOT/ancestry-over-marker"
  make_ps "$fakebin"

  out=$(COPILOT_CLI=1 PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=claude FM_FAKE_PS_ARGS='claude --dangerously-skip-permissions' "$HARNESS")
  [ "$out" = claude ] || fail "real Claude ancestry lost to inherited Copilot markers: '$out'"

  versioned_claude='/home/test/.local/share/claude/versions/2.1.220/2.1.220'
  out=$(COPILOT_CLI=1 PATH="$fakebin:$PATH" FM_FAKE_PS_COMM="$versioned_claude" \
    FM_FAKE_PS_ARGS="$versioned_claude --dangerously-skip-permissions" "$HARNESS")
  [ "$out" = claude ] || fail "version-named Claude ancestry lost to inherited Copilot markers: '$out'"

  out=$(CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent CLAUDECODE=1 PATH="$fakebin:$PATH" \
    FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='/opt/copilot/bin/copilot --allow-all' "$HARNESS")
  [ "$out" = copilot ] || fail "real Copilot ancestry lost to inherited foreign markers: '$out'"
  pass "Actual Claude and Copilot ancestry outrank inherited foreign markers"
}

test_session_lock_identity_matches_copilot() {
  local fakebin out
  fakebin="$TMP_ROOT/lock-shape"
  make_ps "$fakebin"
  # shellcheck disable=SC2016 # Child shell intentionally expands its positional parameter.
  out=$(env -u COPILOT_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    bash -c '. "$1"; fm_harness_ancestry_pid' -- "$LOCK_LIB")
  case "$out" in
    ''|*[!0-9]*) fail "Copilot lock identity returned '$out'" ;;
  esac
  pass "session-lock ancestry recognizes Copilot's MainThread process shape"
}

make_hook_fixture() {
  local dir=$1 guard_status=${2:-0}
  mkdir -p "$dir/bin"
  cp "$HOOK" "$ROOT/bin/fm-hook-host-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-copilot-hook.sh"
  cat > "$dir/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
cat > "$FM_TEST_PAYLOAD"
[ -z "${FM_TEST_ARGS:-}" ] || printf '%s\n' "$*" > "$FM_TEST_ARGS"
printf 'digest line one\ndigest line two\n'
SH
  cat > "$dir/bin/fm-turnend-guard.sh" <<SH
#!/usr/bin/env bash
cat > "\$FM_TEST_PAYLOAD"
[ -z "\${FM_TEST_ARGS:-}" ] || printf '%s\n' "\$*" > "\$FM_TEST_ARGS"
printf '%s\n' 'restore Firstmate supervision' >&2
exit $guard_status
SH
  cat > "$dir/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
cat > "$FM_TEST_PAYLOAD"
[ -z "${FM_TEST_ARGS:-}" ] || printf '%s\n' "$*" > "$FM_TEST_ARGS"
jq -cn '{permissionDecision:"deny",permissionDecisionReason:"arm denied"}'
SH
  cat > "$dir/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
cat > "$FM_TEST_PAYLOAD"
[ -z "${FM_TEST_ARGS:-}" ] || printf '%s\n' "$*" > "$FM_TEST_ARGS"
jq -cn '{permissionDecision:"deny",permissionDecisionReason:"cd denied"}'
SH
  cat > "$dir/bin/fm-subagent-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
cat > "$FM_TEST_PAYLOAD"
[ -z "${FM_TEST_ARGS:-}" ] || printf '%s\n' "$*" > "$FM_TEST_ARGS"
jq -cn '{permissionDecision:"deny",permissionDecisionReason:"subagent denied"}'
SH
  chmod +x "$dir/bin/fm-sessionstart-run.sh" "$dir/bin/fm-turnend-guard.sh" \
    "$dir/bin/fm-arm-pretool-check.sh" "$dir/bin/fm-cd-pretool-check.sh" \
    "$dir/bin/fm-subagent-pretool-check.sh"
}

run_copilot_hook_fixture() {  # <fakebin> <dir> <mode> <payload-file> [extra env...]
  local fakebin=$1 dir=$2 mode=$3 payload_file=$4
  shift 4
  PATH="$fakebin:$PATH" "$@" "$dir/bin/fm-copilot-hook.sh" "$mode" < "$payload_file"
}

make_claude_compat_fixture() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/.claude"
  git -C "$dir" init -q
  : > "$dir/AGENTS.md"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" "$ROOT/bin/fm-claude-compat-hook.sh" "$dir/bin/"
  cp "$ROOT/.claude/settings.json" "$dir/.claude/settings.json"
  cat > "$dir/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
printf 'sessionstart\n'
SH
  cat > "$dir/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
printf 'arm\n'
SH
  cat > "$dir/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
printf 'cd\n'
SH
  cat > "$dir/bin/fm-subagent-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
printf 'subagent\n'
SH
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
printf 'turnend\n'
SH
  cat > "$dir/bin/fm-claude-stop-autoarm.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
printf 'autoarm\n'
SH
  chmod +x "$dir/bin/"*
}

test_session_start_translates_context() {
  local dir payload out fakebin
  dir="$TMP_ROOT/session-start"
  payload="$dir/payload.json"
  fakebin="$dir/fakebin"
  make_hook_fixture "$dir"
  make_ps "$fakebin"
  printf '%s' '{"source":"startup"}' > "$dir/in.json"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$payload" FM_TEST_ARGS="$dir/args.txt" "$dir/bin/fm-copilot-hook.sh" session-start < "$dir/in.json")
  printf '%s' "$out" | jq -e '.additionalContext == "digest line one\ndigest line two\n"' >/dev/null \
    || fail "sessionStart adapter returned invalid context: $out"
  [ "$(cat "$payload")" = '{"source":"startup"}' ] || fail "sessionStart payload was not forwarded"
  [ "$(cat "$dir/args.txt")" = --copilot ] || fail "Copilot sessionStart did not use the native invocation mode"
  pass "Copilot sessionStart returns the full digest as additionalContext"
}

test_agent_stop_translates_block() {
  local dir payload out fakebin
  dir="$TMP_ROOT/agent-stop"
  payload="$dir/payload.json"
  fakebin="$dir/fakebin"
  make_hook_fixture "$dir" 2
  make_ps "$fakebin"
  printf '%s' '{"sessionId":"s1","stop_hook_active":false}' > "$dir/in.json"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$payload" "$dir/bin/fm-copilot-hook.sh" agent-stop < "$dir/in.json")
  printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("restore Firstmate supervision"))' >/dev/null \
    || fail "agentStop adapter returned invalid block decision: $out"
  [ "$(cat "$payload")" = '{"sessionId":"s1","stop_hook_active":false}' ] \
    || fail "agentStop payload was not forwarded"
  pass "Copilot agentStop translates the shared guard refusal into a native block"
}

test_copilot_native_policies_bypass_compatibility_stand_down() {
  local dir fakebin payload out rc args
  dir="$TMP_ROOT/native-copilot-policies"
  fakebin="$dir/fakebin"
  payload="$dir/payload.json"
  make_hook_fixture "$dir" 2
  make_ps "$fakebin"

  printf '%s' '{"toolArgs":{"command":"bin/fm-watch-arm.sh &"}}' > "$dir/arm.json"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$payload" FM_TEST_ARGS="$dir/args.txt" "$dir/bin/fm-copilot-hook.sh" pretool-arm < "$dir/arm.json" 2> "$dir/arm.err")
  rc=$?
  [ "$rc" -eq 0 ] || fail "Copilot pretool-arm should return Copilot's native deny object with exit 0, got $rc: $out"
  [ ! -s "$dir/arm.err" ] || fail "Copilot pretool-arm wrote stderr: $(cat "$dir/arm.err")"
  printf '%s' "$out" | jq -e '.permissionDecision == "deny" and .permissionDecisionReason == "arm denied"' >/dev/null \
    || fail "Copilot pretool-arm lost the native deny payload: $out"
  [ "$(cat "$payload")" = '{"toolArgs":{"command":"bin/fm-watch-arm.sh &"}}' ] || fail "Copilot pretool-arm did not forward the payload"
  args=$(cat "$dir/args.txt")
  [ "$args" = --copilot ] || fail "Copilot pretool-arm did not use the native invocation mode: $args"

  printf '%s' '{"toolArgs":{"command":"cd projects/demo"}}' > "$dir/cd.json"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$payload" FM_TEST_ARGS="$dir/args.txt" "$dir/bin/fm-copilot-hook.sh" pretool-cd < "$dir/cd.json" 2> "$dir/cd.err")
  rc=$?
  [ "$rc" -eq 0 ] || fail "Copilot pretool-cd should return Copilot's native deny object with exit 0, got $rc: $out"
  [ ! -s "$dir/cd.err" ] || fail "Copilot pretool-cd wrote stderr: $(cat "$dir/cd.err")"
  printf '%s' "$out" | jq -e '.permissionDecision == "deny" and .permissionDecisionReason == "cd denied"' >/dev/null \
    || fail "Copilot pretool-cd lost the native deny payload: $out"
  args=$(cat "$dir/args.txt")
  [ "$args" = --copilot ] || fail "Copilot pretool-cd did not use the native invocation mode: $args"

  printf '%s' '{"toolName":"task"}' > "$dir/subagent.json"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$payload" FM_TEST_ARGS="$dir/args.txt" "$dir/bin/fm-copilot-hook.sh" pretool-subagent < "$dir/subagent.json" 2> "$dir/subagent.err")
  rc=$?
  [ "$rc" -eq 0 ] || fail "Copilot pretool-subagent should return Copilot's native deny object with exit 0, got $rc: $out"
  [ ! -s "$dir/subagent.err" ] || fail "Copilot pretool-subagent wrote stderr: $(cat "$dir/subagent.err")"
  printf '%s' "$out" | jq -e '.permissionDecision == "deny" and .permissionDecisionReason == "subagent denied"' >/dev/null \
    || fail "Copilot pretool-subagent lost the native deny payload: $out"
  args=$(cat "$dir/args.txt")
  [ "$args" = --copilot ] || fail "Copilot pretool-subagent did not use the native invocation mode: $args"

  printf '%s' '{"sessionId":"s1","stop_hook_active":false}' > "$dir/stop.json"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$payload" FM_TEST_ARGS="$dir/args.txt" "$dir/bin/fm-copilot-hook.sh" agent-stop < "$dir/stop.json")
  printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null || fail "Copilot agent-stop lost block translation: $out"
  args=$(cat "$dir/args.txt")
  [ "$args" = --copilot ] || fail "Copilot agent-stop did not use the native invocation mode: $args"
  pass "Copilot native hooks bypass only the compatibility stand-down"
}

test_agent_stop_allows_clean_stop() {
  local dir out fakebin
  dir="$TMP_ROOT/agent-stop-allow"
  fakebin="$dir/fakebin"
  make_hook_fixture "$dir" 0
  make_ps "$fakebin"
  printf '%s' '{"sessionId":"s1","stop_hook_active":false}' > "$dir/in.json"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
    FM_TEST_PAYLOAD="$dir/payload.json" "$dir/bin/fm-copilot-hook.sh" agent-stop < "$dir/in.json")
  [ -z "$out" ] || fail "healthy agentStop must be silent, got: $out"
  pass "Copilot agentStop leaves a healthy turn end unchanged"
}

test_primary_hook_registration() {
  local hooks="$ROOT/.github/hooks/fm-primary.json"
  jq -e '
    .version == 1
    and (.hooks.sessionStart | length) == 1
    and (.hooks.agentStop | length) == 1
    and ([.hooks.preToolUse[].matcher] | sort) == [".*","bash","bash"]
  ' "$hooks" >/dev/null || fail "tracked Copilot hook registration is incomplete"
  pass "tracked Copilot hooks register startup, safety policies, and turn-end continuation"
}

test_non_cli_hook_surface_stands_down() {
  local dir out fakebin
  dir="$TMP_ROOT/non-cli"
  fakebin="$dir/fakebin"
  make_hook_fixture "$dir" 2
  make_ps "$fakebin"
  printf '%s' '{"source":"startup"}' > "$dir/in.json"
  out=$(env -u COPILOT_CLI PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' FM_TEST_PAYLOAD="$dir/payload.json" \
      "$dir/bin/fm-copilot-hook.sh" session-start < "$dir/in.json")
  [ -z "$out" ] || fail "non-CLI sessionStart hook printed output: $out"
  assert_absent "$dir/payload.json" "non-CLI hook invoked the Firstmate session-start owner"
  printf '%s' '{"sessionId":"cloud","stop_hook_active":false}' > "$dir/in-stop.json"
  out=$(env -u COPILOT_CLI PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=bash FM_FAKE_PS_ARGS='bash' FM_TEST_PAYLOAD="$dir/payload.json" \
      "$dir/bin/fm-copilot-hook.sh" agent-stop < "$dir/in-stop.json")
  [ -z "$out" ] || fail "non-CLI agentStop hook printed output: $out"
  assert_absent "$dir/payload.json" "non-CLI hook invoked the Firstmate turn-end owner"
  pass "Copilot repository hooks stay inert outside local Copilot CLI"
}

test_claude_compatibility_hooks_stand_down() {
  local dir fakebin command out rc count=0
  dir="$TMP_ROOT/claude-compat-copilot"
  fakebin="$dir/fakebin"
  make_ps "$fakebin"
  make_claude_compat_fixture "$dir"
  while IFS= read -r command; do
    count=$((count + 1))
    out=$(cd "$dir" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=MainThread FM_FAKE_PS_ARGS='copilot --allow-all' \
      sh -c "$command" <<'EOF' 2>&1
{"source":"startup","tool_input":{"command":"echo hi"},"tool_name":"task"}
EOF
)
    rc=$?
    [ "$rc" -eq 0 ] || fail "Claude compatibility hook $count failed under native Copilot: $out"
    [ -z "$out" ] || fail "Claude compatibility hook $count printed under native Copilot: $out"
  done < <(jq -r '.hooks[][].hooks[].command' "$ROOT/.claude/settings.json")
  [ "$count" -gt 0 ] || fail "no Claude compatibility hooks were exercised"
  pass "Claude compatibility hooks stay inert under native Copilot hooks"
}

test_claude_compatibility_hooks_run_under_actual_claude_with_inherited_copilot_markers() {
  local dir fakebin command out rc count=0 versioned_claude
  dir="$TMP_ROOT/claude-compat-claude"
  fakebin="$dir/fakebin"
  make_ps "$fakebin"
  make_claude_compat_fixture "$dir"
  versioned_claude='/home/test/.local/share/claude/versions/2.1.220/2.1.220'
  while IFS= read -r command; do
    count=$((count + 1))
    out=$(COPILOT_CLI=1 PATH="$fakebin:$PATH" FM_FAKE_PS_COMM="$versioned_claude" \
      FM_FAKE_PS_ARGS="$versioned_claude --dangerously-skip-permissions" \
      CLAUDE_PROJECT_DIR="$dir" sh -c "$command" <<'EOF' 2>&1
{"source":"startup","tool_input":{"command":"echo hi"},"tool_name":"task"}
EOF
)
    rc=$?
    [ "$rc" -eq 0 ] || fail "Claude compatibility hook $count failed under real Claude ancestry: $out"
    [ -n "$out" ] || fail "Claude compatibility hook $count was suppressed by inherited Copilot markers"
  done < <(jq -r '.hooks[][].hooks[].command' "$ROOT/.claude/settings.json")
  [ "$count" -gt 0 ] || fail "no Claude compatibility hooks were exercised"
  pass "Claude compatibility hooks still run under actual Claude with inherited Copilot markers"
}

test_claude_compatibility_hooks_find_worktree_root_from_subdir() {
  local dir fakebin command out rc count=0
  dir="$TMP_ROOT/claude-compat-subdir"
  fakebin="$dir/fakebin"
  make_ps "$fakebin"
  make_claude_compat_fixture "$dir"
  mkdir -p "$dir/subdir/nested"
  while IFS= read -r command; do
    count=$((count + 1))
    out=$(cd "$dir/subdir/nested" && PATH="$fakebin:$PATH" FM_FAKE_PS_COMM=claude FM_FAKE_PS_ARGS='claude --dangerously-skip-permissions' \
      sh -c "$command" <<'EOF' 2>&1
{"source":"startup","tool_input":{"command":"echo hi"},"tool_name":"task"}
EOF
)
    rc=$?
    [ "$rc" -eq 0 ] || fail "Claude compatibility hook $count failed from a repository subdirectory: $out"
    [ -n "$out" ] || fail "Claude compatibility hook $count did not resolve the worktree root from a repository subdirectory"
  done < <(jq -r '.hooks[][].hooks[].command' "$ROOT/.claude/settings.json")
  [ "$count" -gt 0 ] || fail "no Claude compatibility hooks were exercised"
  pass "Claude compatibility hooks resolve their worktree root from repository subdirectories"
}

test_environment_marker_wins
test_process_shapes_are_anchored
test_actual_host_overrides_inherited_markers
test_session_lock_identity_matches_copilot
test_session_start_translates_context
test_agent_stop_translates_block
test_copilot_native_policies_bypass_compatibility_stand_down
test_agent_stop_allows_clean_stop
test_primary_hook_registration
test_non_cli_hook_surface_stands_down
test_claude_compatibility_hooks_stand_down
test_claude_compatibility_hooks_run_under_actual_claude_with_inherited_copilot_markers
test_claude_compatibility_hooks_find_worktree_root_from_subdir

echo "# all fm-copilot-harness tests passed"
