#!/usr/bin/env bash
# Lean detection test for agy (Antigravity CLI) harness.
# Uses a mocked ps to avoid macOS provenance quarantine on copied binaries.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

test_detects_agy_process_ancestor() {
  local dir fakebin out
  dir="$TMP_ROOT/detect"
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<'PS'
#!/usr/bin/env bash
if [[ "$*" == *"comm="* ]]; then
  echo "agy"
  exit 0
fi
exec /bin/ps "$@"
PS
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = agy ] || fail "fm-harness.sh with mocked ps comm=agy reported '$out', expected agy"
  pass "agy is detected through process ancestry comm name agy"
}

test_detection_not_triggered_without_agy_comm() {
  local out
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS "$HARNESS")
  [ "$out" != agy ] || fail "fm-harness.sh misdetected non-agy environment as agy (got '$out')"
  pass "agy detection does not trigger without agy comm"
}

test_harness_file_contains_agy_detection() {
  grep -q "agy) echo agy" "$HARNESS" || fail "fm-harness.sh does not contain 'agy) echo agy' detection case"
  grep -q "Antigravity CLI" "$HARNESS" || fail "fm-harness.sh missing Antigravity comment"
  pass "fm-harness.sh contains agy detection and provenance comment"
}

test_detects_agy_process_ancestor
test_detection_not_triggered_without_agy_comm
test_harness_file_contains_agy_detection
