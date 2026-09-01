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

test_hooks_json_registrations() {
  local hooks="$ROOT/.agents/hooks.json"
  [ -f "$hooks" ] || fail ".agents/hooks.json is missing"
  # Hard Rule 1 PreToolUse routes to the unified selfdo guard.
  grep -q 'fm-selfdo-pretool-check.sh' "$hooks" || fail "hooks.json firstmate-hardrule1 must invoke fm-selfdo-pretool-check.sh"
  grep -q 'fm-hardrule1-pretool-check.sh' "$hooks" && fail "hooks.json still references deleted fm-hardrule1-pretool-check.sh"
  pass "hooks.json routes firstmate-hardrule1 to fm-selfdo-pretool-check.sh"
  # Session-start PreInvocation nudge is registered.
  grep -q 'fm-sessionstart-agy-nudge.sh' "$hooks" || fail "hooks.json must register fm-sessionstart-agy-nudge.sh under firstmate-sessionstart"
  pass "hooks.json registers the AGY session-start nudge"
  # No turn-end Stop hook by design: the Stop hook blocked chat.
  grep -q 'fm-turnend-guard-agy' "$hooks" && fail "hooks.json must not register an AGY Stop hook (removed by design)"
  pass "hooks.json registers no AGY Stop hook (by design)"
}

test_deleted_guards_absent() {
  [ ! -f "$ROOT/bin/fm-turnend-guard-agy.sh" ] || fail "bin/fm-turnend-guard-agy.sh must stay deleted"
  [ ! -f "$ROOT/bin/fm-hardrule1-pretool-check.sh" ] || fail "bin/fm-hardrule1-pretool-check.sh must stay deleted (unified into fm-selfdo-pretool-check.sh)"
  pass "deleted AGY guard scripts stay absent"
}

test_agy_md_has_no_stale_phase_claims() {
  local doc="$ROOT/.agents/skills/harness-adapters/references/harness/agy.md"
  [ -f "$doc" ] || fail "agy.md is missing"
  grep -q "SHIPPED Phase 1" "$doc" && fail "agy.md still claims SHIPPED Phase 1"
  grep -q "fm-turnend-guard-agy" "$doc" && fail "agy.md still references the deleted turn-end guard"
  grep -q "fm-hardrule1-pretool-check" "$doc" && fail "agy.md still references the deleted hardrule1 script"
  grep -q "external background watcher" "$doc" || fail "agy.md must state turn-end supervision is the external background watcher"
  grep -qi "do not re-add" "$doc" || fail "agy.md must state the Stop hook stays removed (do not re-add)"
  pass "agy.md is lean: no stale phases, no deleted-script references"
}

test_detects_agy_process_ancestor
test_detection_not_triggered_without_agy_comm
test_harness_file_contains_agy_detection
test_hooks_json_registrations
test_deleted_guards_absent
test_agy_md_has_no_stale_phase_claims
