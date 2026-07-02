#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

test_detects_cursor_via_env_marker() {
  local out
  out=$(CURSOR_AGENT=1 CLAUDECODE='' PI_CODING_AGENT='' GROK_AGENT='' "$HARNESS")
  assert_contains "$out" "cursor" "CURSOR_AGENT=1 should detect the cursor harness"
  pass "detects cursor via CURSOR_AGENT marker"
}

test_claude_still_wins_when_both_set() {
  local out
  out=$(CURSOR_AGENT=1 CLAUDECODE=1 "$HARNESS")
  assert_contains "$out" "claude" "a genuine claude session (CLAUDECODE=1) must resolve to claude, not cursor"
  pass "preference-neutral: claude wins when CLAUDECODE is set"
}

test_fm_lock_recognizes_cursor_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/x/.local/share/cursor-agent/versions/v/cursor-agent'; exit 0 ;;
  *"args="*) printf '%s\n' 'cursor-agent'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize cursor-agent as a live holder"
  pass "fm-lock recognizes cursor-agent harness processes"
}

test_detects_cursor_via_env_marker
test_claude_still_wins_when_both_set
test_fm_lock_recognizes_cursor_holder
