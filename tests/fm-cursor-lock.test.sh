#!/usr/bin/env bash
# Behavior tests for Cursor Agent CLI session-lock holder detection,
# harness self-detection, and the provisional launch template.
# Full adapter verification remains open (docs/cursor-harness.md).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cursor-lock)

# Fake ps that reports the queried pid as Cursor's observed shape:
# comm=MainThread, args=.../agent .../cursor-agent/.../index.js
make_fake_ps_cursor_mainthread() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"comm="*) printf '%s\n' 'MainThread'; exit 0 ;;
  *"args="*)
    printf '%s\n' \
      '/home/dylan/.local/bin/agent --use-system-ca /home/dylan/.local/share/cursor-agent/versions/2026.07.16-899851b/index.js'
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

make_fake_ps_cursor_basename() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"comm="*) printf '%s\n' '/home/dylan/.local/bin/agent'; exit 0 ;;
  *"args="*) printf '%s\n' 'agent --yolo'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

test_fm_lock_recognizes_cursor_mainthread_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-mainthread"
  fakebin=$(fm_fakebin "$TMP_ROOT/fake-mainthread")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  make_fake_ps_cursor_mainthread "$fakebin"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" \
    "fm-lock did not recognize Cursor MainThread+agent argv as a live holder"
  pass "fm-lock recognizes Cursor MainThread harness processes"
}

test_fm_lock_acquires_with_cursor_basename() {
  local home fakebin out
  home="$TMP_ROOT/lock-basename"
  fakebin=$(fm_fakebin "$TMP_ROOT/fake-basename")
  mkdir -p "$home/state"
  make_fake_ps_cursor_basename "$fakebin"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1)
  assert_contains "$out" "lock acquired: harness pid" \
    "fm-lock did not acquire when ancestry reports basename agent"
  pass "fm-lock acquires when Cursor reports basename agent"
}

test_fm_harness_detects_cursor_mainthread() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-mainthread")
  make_fake_ps_cursor_mainthread "$fakebin"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "fm-harness.sh should detect cursor from MainThread+agent argv, got '$out'"
  pass "fm-harness.sh detects cursor from MainThread+agent argv"
}

test_fm_harness_detects_cursor_basename() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-basename")
  make_fake_ps_cursor_basename "$fakebin"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "fm-harness.sh should detect cursor from basename agent, got '$out'"
  pass "fm-harness.sh detects cursor from basename agent"
}

test_fm_spawn_cursor_launch_template() {
  local line
  line=$(grep -E 'cursor\) printf' "$ROOT/bin/fm-spawn.sh")
  assert_contains "$line" 'agent __MODELFLAG__--yolo --trust' \
    "fm-spawn.sh missing provisional cursor launch template with --yolo --trust"
  assert_contains "$line" '__BRIEF__' \
    "fm-spawn.sh cursor launch template must feed the brief"
  pass "fm-spawn provisional cursor launch template includes --yolo --trust and brief"
}

test_fm_lock_recognizes_cursor_mainthread_holder
test_fm_lock_acquires_with_cursor_basename
test_fm_harness_detects_cursor_mainthread
test_fm_harness_detects_cursor_basename
test_fm_spawn_cursor_launch_template
