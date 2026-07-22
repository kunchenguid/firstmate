#!/usr/bin/env bash
# Behavior tests for Hermes-as-primary detection, supervision snippet, and
# shell-hook bridge. Does not claim crew-spawn verification.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-hermes-primary)

test_detect_env_marker() {
  local out
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    HERMES_SESSION_ID='20260723_test' \
    "$ROOT/bin/fm-harness.sh")
  assert_contains "$out" "hermes" "HERMES_SESSION_ID should classify own harness as hermes"
  pass "fm-harness detects HERMES_SESSION_ID"
}

test_detect_process_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-fake")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'hermes'; exit 0 ;;
  *"args="*) printf '%s\n' '/home/iqbal/.hermes/hermes-agent/venv/bin/hermes'; exit 0 ;;
  *"ppid="*) printf '%s\n' '1'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u HERMES_SESSION_ID \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-harness.sh")
  assert_contains "$out" "hermes" "process name hermes should classify own harness"
  pass "fm-harness detects hermes process ancestry"
}

test_supervision_snippet() {
  local out
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness hermes --read-only 1)
  assert_contains "$out" "Hermes background-notify supervision" \
    "supervision instructions did not select hermes.md"
  assert_contains "$out" "notify_on_complete" \
    "hermes protocol must name Hermes notify_on_complete"
  pass "supervision instructions render hermes protocol"
}

test_hook_bridge_blocks_bg_arm() {
  local out home
  home="$TMP_ROOT/primary-home"
  mkdir -p "$home/bin" "$home/state"
  cp "$ROOT/AGENTS.md" "$home/AGENTS.md"
  ln -s "$ROOT/bin/fm-session-start.sh" "$home/bin/fm-session-start.sh"
  ln -s "$ROOT/bin/fm-arm-pretool-check.sh" "$home/bin/fm-arm-pretool-check.sh"
  ln -s "$ROOT/bin/fm-continuity-pretool-check.sh" "$home/bin/fm-continuity-pretool-check.sh"
  out=$(
    printf '%s' "{\"hook_event_name\":\"pre_tool_call\",\"tool_name\":\"terminal\",\"tool_input\":{\"command\":\"bin/fm-watch-arm.sh &\"},\"cwd\":\"$home\",\"session_id\":\"t\"}" \
      | "$ROOT/bin/fm-hermes-primary-hook.sh" pre_tool_call
  )
  assert_contains "$out" '"decision":"block"' "bg arm should be blocked by hermes bridge"
  pass "hermes primary hook blocks shell-background watcher arm"
}

test_hook_bridge_fail_open_foreign_cwd() {
  local out foreign
  foreign="$TMP_ROOT/not-firstmate"
  mkdir -p "$foreign"
  out=$(
    printf '%s' "{\"hook_event_name\":\"pre_tool_call\",\"tool_name\":\"terminal\",\"tool_input\":{\"command\":\"bin/fm-watch-arm.sh &\"},\"cwd\":\"$foreign\",\"session_id\":\"t\"}" \
      | "$ROOT/bin/fm-hermes-primary-hook.sh" pre_tool_call
  )
  [ -z "$out" ] || fail "foreign cwd must fail open with empty stdout, got: $out"
  pass "hermes primary hook fails open outside firstmate homes"
}

test_installer_status_roundtrip() {
  local cfg out status
  cfg="$TMP_ROOT/hermes-config/config.yaml"
  mkdir -p "$(dirname "$cfg")"
  printf 'model:\n  default: test\n' > "$cfg"
  FM_HERMES_CONFIG="$cfg" "$ROOT/bin/fm-hermes-install-primary-hooks.sh" >/dev/null
  out=$(FM_HERMES_CONFIG="$cfg" "$ROOT/bin/fm-hermes-install-primary-hooks.sh" --status)
  status=$?
  assert_contains "$out" "installed" "installer status should report installed"
  expect_code 0 "$status" "installer --status exit 0 when installed"
  FM_HERMES_CONFIG="$cfg" "$ROOT/bin/fm-hermes-install-primary-hooks.sh" --remove >/dev/null
  set +e
  out=$(FM_HERMES_CONFIG="$cfg" "$ROOT/bin/fm-hermes-install-primary-hooks.sh" --status 2>&1)
  status=$?
  set -e
  assert_contains "$out" "missing" "installer --remove should clear firstmate hooks"
  expect_code 1 "$status" "installer --status exit 1 when missing"
  pass "hermes hook installer install/status/remove roundtrip"
}

test_detect_env_marker
test_detect_process_name
test_supervision_snippet
test_hook_bridge_blocks_bg_arm
test_hook_bridge_fail_open_foreign_cwd
test_installer_status_roundtrip
