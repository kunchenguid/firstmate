#!/usr/bin/env bash
# Regression coverage for home-local memory capture and due reminders.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MEMORY="$ROOT/bin/fm-memory.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' "$home"
}

run_capture() {
  local home=$1 now=$2 out=$3
  shift 3
  local status=0
  FM_HOME="$home" FM_MEMORY_NOW="$now" "$MEMORY" "$@" >"$out" 2>&1 || status=$?
  printf '%s\n' "$status"
}

record_id_from() {
  grep -oE 'm-[0-9]+-[0-9]+-[0-9]+' "$1" | head -n 1
}

test_capture_list_and_literal_search() {
  local home out id status list
  home=$(make_home capture)
  out="$home/out"

  status=$(run_capture "$home" 1000 "$out" remember 'Project Atlas uses [blue] labels')
  expect_code 0 "$status" "remember exit"
  id=$(record_id_from "$out")
  [ -n "$id" ] || fail "remember did not return a record id: $(cat "$out")"
  assert_present "$home/data/memory/records/$id" "remember did not create the private record"
  [ "$(stat -c %a "$home/data/memory/records/$id" 2>/dev/null || stat -f %Lp "$home/data/memory/records/$id")" = 600 ] \
    || fail "memory record is not mode 600"

  status=$(run_capture "$home" 1000 "$out" list)
  expect_code 0 "$status" "list exit"
  list=$(cat "$out")
  assert_contains "$list" "$id" "list omitted the memory id"
  assert_contains "$list" $'memory\topen\t-\tProject Atlas uses [blue] labels' "list omitted the memory fields"

  status=$(run_capture "$home" 1000 "$out" search '[BLUE]')
  expect_code 0 "$status" "literal search exit"
  assert_contains "$(cat "$out")" "$id" "case-insensitive literal search did not find bracketed text"
  status=$(run_capture "$home" 1000 "$out" search '[notes]')
  expect_code 0 "$status" "nonmatching bracket search exit"
  [ ! -s "$out" ] || fail "a bracketed query was interpreted as a glob: $(cat "$out")"
  status=$(run_capture "$home" 1000 "$out" search 'not present')
  expect_code 0 "$status" "empty search exit"
  [ ! -s "$out" ] || fail "search returned a nonmatching record: $(cat "$out")"

  status=$(run_capture "$home" 1000 "$out" list --kind reminder)
  expect_code 0 "$status" "reminder-only list exit"
  [ ! -s "$out" ] || fail "a memory appeared in the reminder list: $(cat "$out")"
  status=$(run_capture "$home" 1000 "$out" "done" "$id")
  expect_code 1 "$status" "done on a memory exit"
  assert_contains "$(cat "$out")" "$id is a memory, not a reminder" "a memory was accepted as a reminder"
  status=$(run_capture "$home" 1000 "$out" list --kind memory)
  expect_code 0 "$status" "memory list after refused done exit"
  assert_contains "$(cat "$out")" "$id" "refusing done removed the memory"
  pass "memories are created privately, listed, and searched literally"
}

test_due_delivery_is_once_and_done_is_acknowledgement() {
  local home out id status first
  home=$(make_home due)
  out="$home/out"

  status=$(run_capture "$home" 2000 "$out" remind --in 5m 'Review the Atlas draft')
  expect_code 0 "$status" "remind exit"
  id=$(record_id_from "$out")
  assert_present "$home/state/memory-reminders.check.sh" "remind did not arm the watcher check"
  assert_present "$home/state/memory-reminders.check-trust" "remind did not authenticate the watcher check"

  status=$(run_capture "$home" 2299 "$out" check)
  expect_code 0 "$status" "pre-due check exit"
  [ ! -s "$out" ] || fail "a reminder surfaced before it was due: $(cat "$out")"
  status=$(run_capture "$home" 2300 "$out" check)
  expect_code 0 "$status" "due check exit"
  first=$(cat "$out")
  assert_contains "$first" "memory reminder due: $id Review the Atlas draft" "the due check omitted the reminder"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the watcher check emitted more than one line"

  status=$(run_capture "$home" 2301 "$out" check)
  expect_code 0 "$status" "repeat due check exit"
  [ ! -s "$out" ] || fail "an already delivered reminder surfaced twice: $(cat "$out")"

  status=$(run_capture "$home" 2400 "$out" "done" "$id")
  expect_code 0 "$status" "done exit"
  assert_absent "$home/state/memory-reminders.check.sh" "the last completed reminder left supervision armed"
  assert_absent "$home/state/memory-reminders.check-trust" "the last completed reminder left check trust behind"
  status=$(run_capture "$home" 2400 "$out" list)
  expect_code 0 "$status" "open list after done exit"
  [ ! -s "$out" ] || fail "the completed reminder remained in the open list: $(cat "$out")"
  status=$(run_capture "$home" 2400 "$out" list --all)
  expect_code 0 "$status" "all list after done exit"
  assert_contains "$(cat "$out")" $'reminder\tdone\t' "--all omitted the completed reminder"
  status=$(run_capture "$home" 2401 "$out" "done" "$id")
  expect_code 0 "$status" "idempotent done exit"
  assert_contains "$(cat "$out")" "already done: $id" "repeated acknowledgement was not idempotent"
  status=$(run_capture "$home" 2401 "$out" search 'Atlas')
  expect_code 0 "$status" "open search after done exit"
  [ ! -s "$out" ] || fail "an open search returned a completed reminder: $(cat "$out")"
  status=$(run_capture "$home" 2401 "$out" search --all 'atlas')
  expect_code 0 "$status" "completed search exit"
  assert_contains "$(cat "$out")" "$id" "search --all omitted the completed reminder"
  pass "due delivery and reminder acknowledgement are idempotent"
}

test_due_reminder_reaches_the_real_watcher() {
  local home out err id status
  home=$(make_home watcher)
  out="$home/out"
  err="$home/err"
  status=$(run_capture "$home" 3000 "$out" remind --at 3001 'Call the repair shop')
  expect_code 0 "$status" "watcher reminder creation exit"
  id=$(record_id_from "$out")

  status=0
  env FM_HOME="$home" FM_MEMORY_NOW=3001 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 10 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "the authenticated reminder check did not reach the watcher"
  assert_contains "$(cat "$out")" "memory reminder due: $id Call the repair shop" "the watcher wake omitted the due reminder"

  status=$(run_capture "$home" 3002 "$out" check)
  expect_code 0 "$status" "post-watcher check exit"
  [ ! -s "$out" ] || fail "the watcher delivery was not durably deduplicated: $(cat "$out")"
  pass "an authenticated due reminder reaches the existing watcher flow once"
}

test_malformed_inputs_and_records_are_refused() {
  local home out status long id
  home=$(make_home malformed)
  out="$home/out"

  status=$(run_capture "$home" 4000 "$out" remind --in soon 'No guessed time')
  expect_code 2 "$status" "invalid relative time exit"
  assert_absent "$home/data/memory/records" "invalid time created a record store"
  status=$(run_capture "$home" 4000 "$out" remind --at 2026-02-30T10:00:00Z 'Impossible date')
  expect_code 2 "$status" "invalid UTC date exit"
  status=$(run_capture "$home" 4000 "$out" remember $'two\tcolumns')
  expect_code 2 "$status" "control character exit"
  long=$(printf 'x%.0s' {1..501})
  status=$(run_capture "$home" 4000 "$out" remember "$long")
  expect_code 2 "$status" "overlong text exit"
  status=$(run_capture "$home" 4000 "$out" "done" '../../other')
  expect_code 2 "$status" "unsafe id exit"

  status=$(run_capture "$home" 4000 "$out" remember 'A durable note')
  expect_code 0 "$status" "valid memory exit"
  id=$(record_id_from "$out")
  printf 'not-a-record\n' > "$home/data/memory/records/$id"
  status=$(run_capture "$home" 4000 "$out" list)
  expect_code 1 "$status" "malformed record list exit"
  assert_contains "$(cat "$out")" "malformed record: $id" "malformed stored data was silently skipped"
  status=$(run_capture "$home" 4000 "$out" check)
  expect_code 0 "$status" "malformed record check exit"
  assert_contains "$(cat "$out")" "memory reminders: malformed record $id" "record corruption did not surface through the check"
  pass "malformed input and stored records are refused without guessing"
}

test_manual_check_controls_are_not_public() {
  local home out status id cmd
  home=$(make_home controls)
  out="$home/out"
  for cmd in arm disarm; do
    status=$(run_capture "$home" 5000 "$out" "$cmd")
    expect_code 2 "$status" "$cmd without an open reminder exit"
    assert_absent "$home/state/memory-reminders.check.sh" "$cmd left a standing check with no open reminder"
    assert_absent "$home/state/memory-reminders.check-trust" "$cmd left check trust with no open reminder"
  done
  status=$(run_capture "$home" 5000 "$out" remind --in 1h 'Keep this armed')
  expect_code 0 "$status" "remind before disarm exit"
  id=$(record_id_from "$out")
  status=$(run_capture "$home" 5000 "$out" disarm)
  expect_code 2 "$status" "disarm with an open reminder exit"
  assert_present "$home/state/memory-reminders.check.sh" "disarm removed the live check"
  status=$(run_capture "$home" 5000 "$out" "done" "$id")
  expect_code 0 "$status" "done of the only reminder exit"
  assert_absent "$home/state/memory-reminders.check.sh" "done of the only reminder left the check armed"
  pass "only remind and done control the standing check"
}

test_last_open_reminder_keeps_the_check_armed() {
  local home out first second status
  home=$(make_home last)
  out="$home/out"
  status=$(run_capture "$home" 6000 "$out" remind --in 1m 'First open reminder')
  expect_code 0 "$status" "first reminder exit"
  first=$(record_id_from "$out")
  status=$(run_capture "$home" 6000 "$out" remind --in 2m 'Second open reminder')
  expect_code 0 "$status" "second reminder exit"
  second=$(record_id_from "$out")
  status=$(run_capture "$home" 6000 "$out" "done" "$first")
  expect_code 0 "$status" "done of one open reminder exit"
  assert_present "$home/state/memory-reminders.check.sh" "one remaining reminder retired the check"
  assert_present "$home/state/memory-reminders.check-trust" "one remaining reminder retired check trust"
  status=$(run_capture "$home" 6000 "$out" "done" "$second")
  expect_code 0 "$status" "done of the last reminder exit"
  assert_absent "$home/state/memory-reminders.check.sh" "the last reminder left the check armed"
  assert_absent "$home/state/memory-reminders.check-trust" "the last reminder left check trust behind"
  pass "the standing check stays armed until the last open reminder is done"
}

test_malformed_record_does_not_hide_a_due_reminder() {
  local home out id status line
  home=$(make_home beside)
  out="$home/out"
  status=$(run_capture "$home" 7000 "$out" remind --at 7000 'Still due beside corruption')
  expect_code 0 "$status" "reminder beside corruption exit"
  id=$(record_id_from "$out")
  printf 'not-a-record\n' > "$home/data/memory/records/m-1-1-1"
  status=$(run_capture "$home" 7000 "$out" check)
  expect_code 0 "$status" "check beside corruption exit"
  line=$(cat "$out")
  [ "$(printf '%s\n' "$line" | wc -l | tr -d '[:space:]')" = 1 ] || fail "corruption check emitted more than one line: $line"
  assert_contains "$line" "memory reminder due: $id Still due beside corruption" "corruption hid the due reminder"
  assert_contains "$line" "malformed record m-1-1-1" "corruption beside a due reminder was not reported"
  pass "a malformed record is reported without hiding a due reminder"
}

test_due_announcements_are_bounded_and_resume() {
  local home out status first second n i
  home=$(make_home batch)
  out="$home/out"
  for i in 1 2 3 4 5 6; do
    status=$(run_capture "$home" 8000 "$out" remind --at 8000 "Batch item $i")
    expect_code 0 "$status" "batch reminder $i exit"
  done
  status=$(run_capture "$home" 8000 "$out" check)
  expect_code 0 "$status" "first batch check exit"
  first=$(cat "$out")
  [ "$(printf '%s\n' "$first" | wc -l | tr -d '[:space:]')" = 1 ] || fail "the batch check emitted more than one line"
  n=$(printf '%s\n' "$first" | grep -oE 'm-[0-9]+-[0-9]+-[0-9]+' | wc -l | tr -d '[:space:]')
  [ "$n" = 5 ] || fail "the first due check announced $n reminders, want 5: $first"
  status=$(run_capture "$home" 8001 "$out" check)
  expect_code 0 "$status" "second batch check exit"
  second=$(cat "$out")
  n=$(printf '%s\n' "$second" | grep -oE 'm-[0-9]+-[0-9]+-[0-9]+' | wc -l | tr -d '[:space:]')
  [ "$n" = 1 ] || fail "the resumed due check announced $n reminders, want 1: $second"
  assert_not_contains "$first" "$(printf '%s\n' "$second" | grep -oE 'm-[0-9]+-[0-9]+-[0-9]+')" \
    "the resumed check repeated a reminder already announced"
  status=$(run_capture "$home" 8002 "$out" check)
  expect_code 0 "$status" "third batch check exit"
  [ ! -s "$out" ] || fail "a fully announced batch surfaced again: $(cat "$out")"
  pass "due announcements stay bounded and resume without repetition"
}

test_capture_list_and_literal_search
test_due_delivery_is_once_and_done_is_acknowledgement
test_due_reminder_reaches_the_real_watcher
test_malformed_inputs_and_records_are_refused
test_manual_check_controls_are_not_public
test_last_open_reminder_keeps_the_check_armed
test_malformed_record_does_not_hide_a_due_reminder
test_due_announcements_are_bounded_and_resume
