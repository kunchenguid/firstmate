#!/usr/bin/env bash
# Behavior tests for Claude Code context-window status-line telemetry.
#
# These use the verified statusLine payload shape as fixtures and cover display,
# the exact 70%-used trigger, complete task snapshots, malformed-input cleanup,
# and the tracked primary/secondmate settings entry point.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATUSLINE="$ROOT/bin/fm-context-statusline.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-statusline)

payload() {
  local used=$1 remaining=$2 total=${3:-200000}
  printf '{"context_window":{"remaining_percentage":%s,"used_percentage":%s,"total_tokens":%s,"current_usage":{"input_tokens":1234,"output_tokens":56,"cache_read_input_tokens":789}}}\n' \
    "$remaining" "$used" "$total"
}

test_below_threshold_displays_real_pressure_and_records_complete_payload() {
  local record out
  record="$TMP_ROOT/below/context-pressure.json"
  mkdir -p "${record%/*}"
  out=$(payload 69.5 30.5 | "$STATUSLINE" --record "$record")
  [ "$out" = 'CTX 69.5% used / 30.5% left (200k)' ] \
    || fail "below-threshold display did not preserve host percentages: $out"
  assert_present "$record" "below-threshold reading was not recorded"
  node - "$record" <<'NODE' || fail "recorded snapshot did not preserve the complete telemetry contract"
const snapshot = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
if (snapshot.context_window.used_percentage !== 69.5) process.exit(1);
if (snapshot.context_window.remaining_percentage !== 30.5) process.exit(1);
if (snapshot.context_window.total_tokens !== 200000) process.exit(1);
if (snapshot.context_window.current_usage.input_tokens !== 1234) process.exit(1);
if (snapshot.compact_at_used_percentage !== 70) process.exit(1);
if (snapshot.compact_recommended !== false) process.exit(1);
NODE
  pass "context status line displays and records the host-computed reading below 70%"
}

test_threshold_is_exact_and_fireable() {
  local record out
  record="$TMP_ROOT/threshold/context-pressure.json"
  mkdir -p "${record%/*}"

  out=$(payload 69.9 30.1 | "$STATUSLINE" --record "$record")
  assert_no_grep 'COMPACT NOW' <(printf '%s\n' "$out") \
    "69.9% incorrectly fired the 70% compaction trigger"

  out=$(payload 70 30 | "$STATUSLINE" --record "$record")
  [ "$out" = 'CTX 70% used / 30% left (200k) | COMPACT NOW: /compact' ] \
    || fail "70% did not emit a directly fireable /compact advisory: $out"
  node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if(s.compact_recommended!==true) process.exit(1)' "$record" \
    || fail "70% snapshot did not set compact_recommended=true"
  pass "context status line fires /compact at exactly 70% used"
}

test_invalid_payload_is_silent_and_clears_stale_snapshot() {
  local record out status
  record="$TMP_ROOT/invalid/context-pressure.json"
  mkdir -p "${record%/*}"
  printf '{"compact_recommended":true}\n' > "$record"

  out=$(printf '%s\n' '{"context_window":{"used_percentage":"estimated"}}' | "$STATUSLINE" --record "$record")
  status=$?
  expect_code 0 "$status" "invalid statusLine input must not disrupt Claude"
  [ -z "$out" ] || fail "invalid statusLine input emitted a misleading reading: $out"
  assert_absent "$record" "invalid statusLine input left a stale compaction advisory"
  pass "invalid context telemetry stays silent and removes stale snapshots"
}

test_tracked_claude_settings_use_the_telemetry_command() {
  local command out
  command=$(node -e 'const s=require(process.argv[1]); if(s.statusLine.type!=="command") process.exit(1); process.stdout.write(s.statusLine.command)' "$ROOT/.claude/settings.json") \
    || fail "tracked Claude settings do not define a command statusLine"
  assert_contains "$command" 'fm-context-statusline.sh' \
    "tracked Claude settings do not invoke the context telemetry renderer"
  out=$(payload 71 29 | CLAUDE_PROJECT_DIR="$ROOT" sh -c "$command")
  assert_contains "$out" 'CTX 71% used / 29% left (200k)' \
    "tracked Claude settings command did not render the host payload"
  assert_contains "$out" 'COMPACT NOW: /compact' \
    "tracked Claude settings command did not expose the compaction trigger"
  pass "tracked Claude settings wire primary and secondmate context telemetry"
}

test_record_requires_absolute_path() {
  local out status
  out=$(payload 50 50 | "$STATUSLINE" --record relative.json 2>&1)
  status=$?
  expect_code 2 "$status" "relative snapshot paths must be rejected"
  assert_contains "$out" 'error: --record requires an absolute path' \
    "relative snapshot refusal did not explain the requirement"
  pass "context snapshots require an absolute task-scoped path"
}

test_below_threshold_displays_real_pressure_and_records_complete_payload
test_threshold_is_exact_and_fireable
test_invalid_payload_is_silent_and_clears_stale_snapshot
test_tracked_claude_settings_use_the_telemetry_command
test_record_requires_absolute_path
