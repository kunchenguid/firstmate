#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SIGNAL="$ROOT/bin/fm-captain-reminder.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-reminder)

test_repeated_instruction_appends_one_keyed_signal() {
  local data current out
  data="$TMP_ROOT/data"
  mkdir -p "$data/old-task" "$data/current-task" "$data/unrelated"
  cat > "$data/old-task/brief.md" <<'EOF'
## Captain's intent
Always use the paved path and verify the exact head.

## Firstmate spec
Old task.
EOF
  cat > "$data/current-task/brief.md" <<'EOF'
## Captain's intent
Always use the paved path and verify the exact head.

## Firstmate spec
Current task.
EOF
  cat > "$data/unrelated/brief.md" <<'EOF'
## Captain's intent
Make the dashboard easier to scan.

## Firstmate spec
Unrelated task.
EOF
  "$SIGNAL" current-task "$data/current-task/brief.md" "$data" "$data/state"
  out=$(cat "$data/captain-reminders.jsonl")
  printf '%s\n' "$out" | jq -e '.key | startswith("captain-reminder:current-task:")' >/dev/null \
    || fail "repeated instruction did not get a task-scoped key"
  printf '%s\n' "$out" | jq -e '.class == "mistakes" and .count == 2 and .ladder_level_hint == "automation"' >/dev/null \
    || fail "signal did not record its recurrence and ladder hint"
  "$SIGNAL" current-task "$data/current-task/brief.md" "$data" "$data/state"
  [ "$(wc -l < "$data/captain-reminders.jsonl" | tr -d ' ')" = 1 ] \
    || fail "reprocessing the task appended a duplicate signal"
  pass "captain reminder appends one idempotent keyed signal for a repeated instruction"
}

test_unrelated_instruction_appends_nothing() {
  local data
  data="$TMP_ROOT/unrelated-data"
  mkdir -p "$data/old-task" "$data/current-task"
  printf '%s\n' '## Captain intent authorized for --intent' 'Keep the CLI output concise.' > "$data/old-task/brief.md"
  printf '%s\n' '## Captain intent authorized for --intent' 'Add a compact visual summary.' > "$data/current-task/brief.md"
  "$SIGNAL" current-task "$data/current-task/brief.md" "$data" "$data/state"
  [ ! -e "$data/captain-reminders.jsonl" ] || fail "unrelated instructions produced a reminder signal"
  pass "captain reminder ignores unrelated instructions"
}

test_failed_retry_and_bad_lines_do_not_block() {
  local data
  data="$TMP_ROOT/retry-data"
  mkdir -p "$data/failed-task" "$data/stamped-failed-task" "$data/current-task" "$data/state"
  printf '%s\n' "## Captain's intent" 'Fix the flaky sync.' > "$data/failed-task/brief.md"
  printf '%s\n' "## Captain's intent" 'Fix the flaky sync.' > "$data/stamped-failed-task/brief.md"
  printf '%s\n' "## Captain's intent" 'Fix the flaky sync.' > "$data/current-task/brief.md"
  printf '%s\n' 'working: started' 'failed: gave up' > "$data/state/failed-task.status"
  printf '%s\n' 'working: started' 'failed [at=1790000000]: gave up' 'diagnostic continuation' \
    > "$data/state/stamped-failed-task.status"
  "$SIGNAL" current-task "$data/current-task/brief.md" "$data" "$data/state"
  [ ! -e "$data/captain-reminders.jsonl" ] || fail "a retry of a failed task counted as a captain repeat"
  printf '%s\n' 'working: started' > "$data/state/failed-task.status"
  printf '%s\n' 'working: started' > "$data/state/stamped-failed-task.status"
  printf '%s\n' '' 'not json' > "$data/captain-reminders.jsonl"
  "$SIGNAL" current-task "$data/current-task/brief.md" "$data" "$data/state" \
    || fail "malformed or blank signal lines failed the spawn"
  [ "$(tail -1 "$data/captain-reminders.jsonl" | jq -r '.count')" = 3 ] \
    || fail "repeat was not recorded after failed tasks became active"
  pass "captain reminder ignores failed-task retries and skips bad signal lines"
}

test_repeated_instruction_appends_one_keyed_signal
test_failed_retry_and_bad_lines_do_not_block
test_unrelated_instruction_appends_nothing
