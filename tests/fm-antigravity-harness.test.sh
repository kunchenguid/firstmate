#!/usr/bin/env bash
# Portable behavior tests for the Google Antigravity CLI (`agy`) adapter.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-antigravity-harness)

clear_identity_env() {
  env -u ANTIGRAVITY_AGENT -u AI_AGENT -u CLAUDECODE -u GEMINI_CLI \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u FM_PI_HARNESS \
    -u GROK_AGENT "$@"
}

test_marker_precedence_and_ai_agent_rejection() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/marker-ps")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf 'bash\n' ;;
  *"args="*) printf 'bash\n' ;;
  *"ppid="*) printf '1\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(ANTIGRAVITY_AGENT=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi AI_AGENT=pi PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = antigravity ] || fail "Antigravity's own marker must outrank inherited Pi identity, got '$out'"
  out=$(clear_identity_env AI_AGENT=antigravity PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != antigravity ] || fail "AI_AGENT must never claim Antigravity identity"
  out=$(clear_identity_env ANTIGRAVITY_AGENT=0 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != antigravity ] || fail "only ANTIGRAVITY_AGENT=1 is the verified marker"
  pass "fm-harness.sh: Antigravity marker precedence rejects inherited AI_AGENT"
}

test_exact_agy_ancestry_only() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/ancestry")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}" ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:-}" ;;
  *"ppid="*) printf '1\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(clear_identity_env FAKE_PS_COMM=/Users/u/.local/bin/agy FAKE_PS_ARGS='agy' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = antigravity ] || fail "exact agy ancestry must identify Antigravity, got '$out'"
  out=$(clear_identity_env FAKE_PS_COMM=agy-helper FAKE_PS_ARGS='agy-helper' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != antigravity ] || fail "agy-helper must not claim Antigravity identity"
  out=$(clear_identity_env FAKE_PS_COMM=node FAKE_PS_ARGS='node app.js --model agy' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != antigravity ] || fail "an unrelated argument mentioning agy must not claim identity"
  pass "fm-harness.sh: only exact agy ancestry claims Antigravity"
}

make_primary_fixture() {
  local fixture=$1
  mkdir -p "$fixture/state"
  printf '# Firstmate\n' > "$fixture/AGENTS.md"
  ln -s "$ROOT/bin" "$fixture/bin"
  git -C "$fixture" init -q
}

test_native_pretool_deny_transport() {
  local fixture payload out status
  fixture="$TMP_ROOT/primary"
  make_primary_fixture "$fixture"
  payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"bin/fm-watch-arm.sh && echo bundled"}}}'
  out=$(printf '%s\n' "$payload" | FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" \
    "$ROOT/bin/fm-arm-pretool-check.sh" --antigravity)
  status=$?
  [ "$status" -eq 0 ] || fail "Antigravity deny transport must exit zero for the hook host"
  [ "$(printf '%s' "$out" | jq -r .decision)" = deny ] || fail "watcher-arm seatbelt did not emit native deny"

  payload='{"toolCall":{"name":"run_command","args":{"CommandLine":"cd projects/example"}}}'
  out=$(printf '%s\n' "$payload" | FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" \
    "$ROOT/bin/fm-cd-pretool-check.sh" --antigravity)
  [ "$(printf '%s' "$out" | jq -r .decision)" = deny ] || fail "cd seatbelt did not emit native deny"

  # invoke_subagent and send_message are the exact Antigravity 1.1.26 tool
  # names observed in a live Gemini delegation turn.
  payload='{"toolCall":{"name":"invoke_subagent","args":{}}}'
  out=$(printf '%s\n' "$payload" | FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" \
    "$ROOT/bin/fm-subagent-pretool-check.sh" --antigravity)
  [ "$(printf '%s' "$out" | jq -r .decision)" = deny ] || fail "delegation seatbelt did not emit native deny"
  pass "Antigravity PreToolUse payloads receive native deny responses"
}

test_sessionstart_hook_transport() {
  local fixture out fakebin msg command
  fixture="$TMP_ROOT/sessionstart-hook"
  make_primary_fixture "$fixture"
  mkdir -p "$fixture/.agents"
  # The registered hook command is a machine-consumed configuration contract.
  # Execute it from the native hooks directory, rather than only testing its target.
  command=$(jq -er '."firstmate-sessionstart".PreInvocation[] | select(.type == "command") | .command' "$ROOT/.agents/hooks.json")
  fakebin=$(fm_fakebin "$fixture/fakebin")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf 'bash\n' ;;
  *"args="*) printf 'bash\n' ;;
  *"ppid="*) printf '1\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(cd "$fixture/.agents" && printf '{}\n' | clear_identity_env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" \
    bash -c "$command")
  msg=$(printf '%s' "$out" | jq -r '.injectSteps[0].ephemeralMessage // empty')
  assert_contains "$msg" "FIRSTMATE_OP: v1 session-start" "sessionstart hook did not inject marked sessionstart nudge"
  assert_contains "$msg" "bin/fm-session-start.sh" "sessionstart hook did not name session-start script"

  out=$(cd "$fixture/.agents" && printf '{}\n' | clear_identity_env FM_GATE_REFUSE_BYPASS=0 NO_MISTAKES_GATE=1 PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fixture" FM_HOME="$fixture" \
    bash -c "$command")
  [ "$out" = '{}' ] || fail "sessionstart hook must return empty object under gate: '$out'"

  pass "Antigravity sessionstart hook delivers ephemeralMessage nudge"
}

test_marker_precedence_and_ai_agent_rejection
test_exact_agy_ancestry_only
test_native_pretool_deny_transport
test_sessionstart_hook_transport
