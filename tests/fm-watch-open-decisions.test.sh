#!/usr/bin/env bash
# Opt-in record-age reminders through the watcher's real queue interface.
# No endpoint, harness process, model call, or remote host is needed.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-open-decisions)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

FM_OPEN_DECISION_OVERDUE_SECS=100
FM_OPEN_DECISION_BACKOFF_MAX_SECS=400

reset_case() {
  rm -f -- "$STATE"/* "$STATE"/.[!.]* "$CONFIG"/*
  OPEN_DECISION_REMINDER=
}

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

test_disabled() {
  reset_case
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "disabled flag queued a reminder"
  [ ! -e "$STATE/.worker.open-decisions-cursor.timed" ] || fail "disabled flag folded status"
  pass "absent flag emits nothing and does not fold status"
}

test_oldest_and_backoff() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=older]: choose\nworking: continuing\n' > "$STATE/z-worker.status"
  printf 'blocked [at=1050] [key=newer]: help\n' > "$STATE/a-worker.status"
  open_decision_reminder_tick 1099
  [ "$(count_wakes)" = 0 ] || fail "not-yet-overdue key queued a reminder"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 1 ] || fail "oldest overdue key did not queue exactly one wake"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: z-worker key=older age=200s' ] \
    || fail "reminder did not select the oldest durable record: $OPEN_DECISION_REMINDER"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 2 ] || fail "another overdue key inherited the oldest key's backoff"
  open_decision_reminder_tick 1299
  [ "$(count_wakes)" = 2 ] || fail "same key repeated before its first backoff"
  open_decision_reminder_tick 1300
  [ "$(count_wakes)" = 3 ] || fail "first repeat did not become due"
  open_decision_reminder_tick 1300
  [ "$(count_wakes)" = 4 ] || fail "second key did not repeat independently"
  open_decision_reminder_tick 1499
  [ "$(count_wakes)" = 4 ] || fail "repeat interval did not double"
  open_decision_reminder_tick 1500
  open_decision_reminder_tick 1500
  [ "$(count_wakes)" = 6 ] || fail "doubled backoff did not expire"
  open_decision_reminder_tick 1899
  [ "$(count_wakes)" = 6 ] || fail "capped interval fired early"
  open_decision_reminder_tick 1900
  open_decision_reminder_tick 1900
  open_decision_reminder_tick 2300
  open_decision_reminder_tick 2300
  [ "$(count_wakes)" = 10 ] || fail "backoff did not stay bounded at the cap"
  pass "oldest key surfaces once, and independent per-key backoff doubles up to its cap"
}

assert_distinct_reminder_identities() {  # <older-task> <older-key> <newer-task> <newer-key>
  local older_task=$1 older_key=$2 newer_task=$3 newer_key=$4 now count=0
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=%s]: choose\n' "$older_key" > "$STATE/$older_task.status"
  printf 'blocked [at=1050] [key=%s]: help\n' "$newer_key" >> "$STATE/$newer_task.status"
  for now in 1200 1300 1500 1900 2300; do
    if [ "$count" -gt 0 ]; then
      open_decision_reminder_tick "$((now - 1))"
      [ "$(count_wakes)" = "$count" ] || fail "numeric-looking identity repeated before its backoff"
    fi
    open_decision_reminder_tick "$now"
    count=$((count + 1))
    [ "$(count_wakes)" = "$count" ] || fail "older numeric-looking identity did not become due"
    [ "$OPEN_DECISION_REMINDER" = "check: open decision overdue: $older_task key=$older_key age=$((now - 1000))s" ] \
      || fail "older numeric-looking identity was not selected: $OPEN_DECISION_REMINDER"
    open_decision_reminder_tick "$((now + 1))"
    count=$((count + 1))
    [ "$(count_wakes)" = "$count" ] || fail "distinct numeric-looking identity inherited another identity's backoff"
    [ "$OPEN_DECISION_REMINDER" = "check: open decision overdue: $newer_task key=$newer_key age=$((now + 1 - 1050))s" ] \
      || fail "newer numeric-looking identity was not selected: $OPEN_DECISION_REMINDER"
    open_decision_reminder_tick "$((now + 1))"
    [ "$(count_wakes)" = "$count" ] || fail "numeric-looking identity repeated without waiting"
  done
}

test_numeric_keys_are_distinct() {
  assert_distinct_reminder_identities worker 1 worker 01
  pass "keys 1 and 01 receive separate reminders and retain independent bounded backoff"
}

test_numeric_tasks_are_distinct() {
  assert_distinct_reminder_identities 1 api 01 api
  pass "tasks 1 and 01 receive separate reminders and retain independent bounded backoff"
}

test_resolution_and_reopen() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  printf 'resolved [at=1201] [key=api]: answered\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "resolved key kept generating reminders"
  printf 'blocked [at=1600] [key=api]: new episode\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1700
  [ "$(count_wakes)" = 2 ] || fail "reopened key inherited the resolved episode's backoff"
  pass "resolution stops reminders immediately and a later episode starts fresh"
}

test_wait_exemptions() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\npaused [at=1050]: validation in flight\n' > "$STATE/paused.status"
  printf 'needs-decision [at=1000] [key=api]: choose\ncaptain-held [at=1050] [key=api]: transferred\n' > "$STATE/transferred.status"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/backlog-held.status"
  # The watcher already delegates backlog ownership to this predicate.
  task_captain_call_open() { [ "$1" = backlog-held ]; }
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "a declared wait or captain hold queued a reminder"
  printf 'working [at=1201]: resumed\n' >> "$STATE/paused.status"
  open_decision_reminder_tick 1201
  [ "$(count_wakes)" = 1 ] || fail "ending a pause hid the still-open key"
  pass "paused waits, verified transfers, and backlog captain holds are exempt"
}

test_unknown_times_and_keyless() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [key=missing]: choose\nblocked [at=bad] [key=bad]: help\nblocked [at=1000]: legacy\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "unknown emission time or keyless record was inferred overdue"
  pass "only explicitly keyed records with valid source timestamps are aged"
}

test_timed_fold_is_incremental() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  export FM_OPEN_DECISIONS_READ_PROBE="$TMP_ROOT/fold.reads"
  : > "$FM_OPEN_DECISIONS_READ_PROBE"
  open_decision_reminder_tick 1200
  open_decision_reminder_tick 1201
  [ "$(wc -l < "$FM_OPEN_DECISIONS_READ_PROBE" | tr -d ' ')" = 1 ] \
    || fail "unchanged poll reread the task's history"
  printf 'resolved [key=api]: answered\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1202
  [ "$(tail -1 "$FM_OPEN_DECISIONS_READ_PROBE" | cut -f2)" = 29 ] \
    || fail "resolution poll folded more than newly appended bytes"
  [ "$(count_wakes)" = 1 ] || fail "incremental resolution left a reminder live"
  unset FM_OPEN_DECISIONS_READ_PROBE
  pass "quiet polls reuse the timed fold and only new status bytes are folded"
}

test_invalid_settings() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  if FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_tick 1200; then
    fail "zero threshold enabled an unbounded reminder loop"
  fi
  if FM_OPEN_DECISION_BACKOFF_MAX_SECS=99 open_decision_reminder_tick 1200; then
    fail "cap below the threshold was accepted"
  fi
  [ "$(count_wakes)" = 0 ] || fail "invalid settings queued a reminder"
  pass "invalid settings refuse the tick without queueing reminders"
}

test_timed_cursor_retirement() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  status_retire_presentation_task "$STATE" worker
  [ ! -e "$STATE/.worker.open-decisions-cursor.timed" ] || fail "task retirement left its timed cursor"
  open_decision_reminder_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "retired task kept generating reminders"
  pass "task retirement removes the timed cursor and ends reminders"
}

test_watcher_loop() {
  local dir="$TMP_ROOT/watcher-loop" pid i=0
  mkdir -p "$dir/state" "$dir/config"
  fm_test_track_watcher_state "$dir/state"
  touch "$dir/config/open-decision-reminders" "$dir/state/home-summary.json"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$dir/state/worker.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_OPEN_DECISION_OVERDUE_SECS=100 FM_OPEN_DECISION_BACKOFF_MAX_SECS=400 \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" &
  pid=$!
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "real watcher failed to wake on an overdue record"
  fi
  wait "$pid" || fail "real watcher exited unsuccessfully: $(cat "$dir/err")"
  grep -F 'check: open decision overdue: worker key=api age=' "$dir/out" >/dev/null \
    || fail "real watcher did not print the reminder wake"
  [ "$(wc -l < "$dir/state/.wake-queue" | tr -d ' ')" = 1 ] \
    || fail "real watcher did not durably queue exactly one reminder"
  pass "the actual watcher wakes and exits on an overdue key without any recorded pane"
}

fm_test_run test_disabled test_oldest_and_backoff test_numeric_keys_are_distinct \
  test_numeric_tasks_are_distinct test_resolution_and_reopen \
  test_wait_exemptions test_unknown_times_and_keyless test_timed_fold_is_incremental \
  test_invalid_settings test_timed_cursor_retirement test_watcher_loop
