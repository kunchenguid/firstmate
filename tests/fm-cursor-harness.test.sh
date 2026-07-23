#!/usr/bin/env bash
# Behavior tests for Cursor-harness session-lock holder detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

test_fm_lock_recognizes_cursor_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/me/.local/bin/cursor-agent'; exit 0 ;;
  *"args="*) printf '%s\n' '/Users/me/.local/bin/cursor-agent --use-system-ca /path/index.js agent'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize cursor-agent as a live holder"
  pass "fm-lock recognizes cursor-agent harness processes"
}

test_fm_lock_comm_basename_strips_leading_dash() {
  local home fakebin out
  home="$TMP_ROOT/dash-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/dash-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '-zsh'; exit 0 ;;
  *"args="*) printf '%s\n' '-zsh'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: stale" "fm-lock must not crash on a -zsh comm field"
  pass "fm-lock handles macOS -zsh comm without basename errors"
}

test_fm_lock_recognizes_cursor_holder
test_fm_lock_comm_basename_strips_leading_dash
