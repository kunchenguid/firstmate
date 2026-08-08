#!/usr/bin/env bash
# Behavior tests for GitHub Copilot CLI detection and native hook translation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)
HOOK="$ROOT/bin/fm-copilot-hook.sh"

test_live_process_shape_detects_copilot() {
  local fakebin out pid
  fakebin=$(fm_fakebin "$TMP_ROOT/detect")
  ln -s /bin/bash "$fakebin/copilot"
  out=$("$fakebin/copilot" -c "\"$ROOT/bin/fm-harness.sh\"")
  [ "$out" = copilot ] || fail "copilot argv[0] process shape detected as '$out'"
  pid=$("$fakebin/copilot" -c ". \"$ROOT/bin/fm-session-lock-lib.sh\"; fm_harness_ancestry_pid")
  case "$pid" in ''|*[!0-9]*) fail "copilot lock ancestry returned '$pid'" ;; esac
  pass "copilot harness and lock detection recognize the markerless MainThread/argv[0] process shape"
}

make_hook_fixture() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$HOOK" "$dir/bin/fm-copilot-hook.sh"
  chmod +x "$dir/bin/fm-copilot-hook.sh"
}

test_session_start_becomes_additional_context() {
  local dir out value
  dir="$TMP_ROOT/session-start"
  make_hook_fixture "$dir"
  cat > "$dir/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'FIRSTMATE COPILOT START\nsecond line\n'
SH
  chmod +x "$dir/bin/fm-sessionstart-run.sh"
  out=$(printf '{"source":"startup"}' | "$dir/bin/fm-copilot-hook.sh" session-start)
  value=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["additionalContext"])')
  assert_contains "$value" "FIRSTMATE COPILOT START" "session-start digest was not injected"
  assert_contains "$value" "second line" "session-start multiline context was truncated"
  pass "copilot sessionStart translates the complete digest into additionalContext"
}

test_agent_stop_translates_block_decision() {
  local dir out decision reason
  dir="$TMP_ROOT/agent-stop"
  make_hook_fixture "$dir"
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'restore Firstmate supervision\n' >&2
exit 2
SH
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  out=$(printf '{"sessionId":"copilot-test","stop_hook_active":false}' \
    | "$dir/bin/fm-copilot-hook.sh" agent-stop)
  decision=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["decision"])')
  reason=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"])')
  [ "$decision" = block ] || fail "agentStop decision was '$decision', expected block"
  assert_contains "$reason" "restore Firstmate supervision" "agentStop lost the shared guard reason"
  pass "copilot agentStop converts the shared exit-2 guard into a native block decision"
}

test_pretool_payload_reaches_shared_policy() {
  local dir out status=0
  dir="$TMP_ROOT/pretool"
  make_hook_fixture "$dir"
  cat > "$dir/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = --command ] || exit 9
[ "$2" = 'bin/fm-watch-arm.sh &' ] || exit 8
[ "$3" = --claude ] || exit 7
printf 'denied by shared policy\n' >&2
exit 2
SH
  chmod +x "$dir/bin/fm-arm-pretool-check.sh"
  out=$(printf '{"toolName":"bash","toolArgs":{"command":"bin/fm-watch-arm.sh &"}}' \
    | "$dir/bin/fm-copilot-hook.sh" pre-arm 2>&1) || status=$?
  expect_code 2 "$status" "Copilot preToolUse denial"
  assert_contains "$out" "denied by shared policy" "preToolUse lost the shared policy denial"
  pass "copilot preToolUse forwards native tool arguments to the shared command policy"
}

test_live_process_shape_detects_copilot
test_session_start_becomes_additional_context
test_agent_stop_translates_block_decision
test_pretool_payload_reaches_shared_policy

echo "# all fm-copilot-harness tests passed"
