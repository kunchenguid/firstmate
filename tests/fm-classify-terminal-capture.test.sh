#!/usr/bin/env bash
# tests/fm-classify-terminal-capture.test.sh - durable terminal-observation
# capture in bin/fm-classify-lib.sh. Nothing else in the fleet records WHEN a
# task finished: status lines carry no timestamp, and both the metadata and the
# status log are destroyed by cleanup. status_terminal_capture writes that one
# missing fact - the time supervision first observed a task's done/failed report
# - so per-task wall clock can be derived from durable records rather than from a
# file mtime or a conversation timestamp (docs/task-metrics.md).
#
# These tests drive the real capture functions over crafted status files. They
# assert the recorded observation, that a first observation is never rewritten by
# later polls, that the recorded scan cursor keeps an observed task off the
# per-poll re-count, and that a SECOND terminal report (a relaunched task that
# finishes again) is observed as its own event.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-terminal-capture-tests)

case_state() {  # <name>
  local d="$TMP_ROOT/$1/state"
  mkdir -p "$d"
  printf '%s' "$d"
}

record_field() {  # <record> <key>
  sed -n "s/^$2=//p" "$1"
}

# The observation itself, without the scan cursor: what a later poll must never
# move. The cursor is separate durable bookkeeping and does advance.
observation_of() {  # <record>
  printf '%s|%s|%s' "$(record_field "$1" observed_at)" "$(record_field "$1" verb)" \
    "$(record_field "$1" events)"
}

status_size_of() {  # <file>
  LC_ALL=C wc -c < "$1" | tr -d '[:space:]'
}

test_a_terminal_report_is_observed_once() {
  local state record
  state=$(case_state observed-once)
  printf '%s\n' 'working: started' 'done: PR ready' > "$state/alpha.status"
  record="$state/alpha.terminal-at"

  status_terminal_capture "$state" alpha || fail "capture failed"
  assert_present "$record" "no terminal observation was recorded"
  [ "$(record_field "$record" verb)" = "done" ] \
    || fail "the observation did not record the terminal verb"
  [ "$(record_field "$record" source)" = supervision-observation ] \
    || fail "the observation did not name its own provenance"
  case "$(record_field "$record" observed_at)" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) fail "the observation timestamp is not a complete UTC second-resolution stamp" ;;
  esac
  pass "terminal capture: a task's done report is recorded with its verb, time, and provenance"
}

test_a_later_poll_never_rewrites_the_first_observation() {
  local state record before
  state=$(case_state stable-first)
  printf 'done: PR ready\n' > "$state/alpha.status"
  record="$state/alpha.terminal-at"

  status_terminal_capture "$state" alpha || fail "capture failed"
  before=$(observation_of "$record")
  # Every later poll re-reads the same file, and an unrelated append must not be
  # mistaken for a second completion.
  status_terminal_capture "$state" alpha || fail "repeat capture failed"
  printf 'working: cleaning up\n' >> "$state/alpha.status"
  status_terminal_capture "$state" alpha || fail "capture after an append failed"
  [ "$(observation_of "$record")" = "$before" ] \
    || fail "a later poll moved the recorded completion time"
  [ "$(record_field "$record" status_size)" = "$(status_size_of "$state/alpha.status")" ] \
    || fail "the scan cursor did not follow the grown log"
  pass "terminal capture: the first observation is the recorded completion time and later polls leave it alone"
}

# The cursor is what keeps an already-observed task off the per-poll rescan: an
# append-only log whose byte size is unchanged since the last look cannot have
# gained a terminal event, so it must not be counted again. A cursor left behind
# at the size the completion was observed at re-counts that task on every poll
# for the rest of its life.
test_an_unchanged_size_log_is_not_recounted() {
  local state record size_before size_after
  state=$(case_state cursor-short-circuit)
  printf 'done: PR ready\n' > "$state/alpha.status"
  record="$state/alpha.terminal-at"

  status_terminal_capture "$state" alpha || fail "capture failed"
  printf 'working: cleaning up\n' >> "$state/alpha.status"
  status_terminal_capture "$state" alpha || fail "capture after an append failed"

  # Rewrite the log to the SAME byte size with a second terminal event in it.
  # Only a re-count could see that event, and the size bound says there is
  # nothing to re-count - so the observation must stand.
  size_before=$(status_size_of "$state/alpha.status")
  printf 'done: PR ready\nfailed: aaaaaaaaaaaa\n' > "$state/alpha.status"
  size_after=$(status_size_of "$state/alpha.status")
  [ "$size_before" = "$size_after" ] \
    || fail "the fixture rewrite changed the log size, so the size bound is not what is under test"

  status_terminal_capture "$state" alpha || fail "capture after the same-size rewrite failed"
  [ "$(record_field "$record" events)" = 1 ] \
    || fail "a status log of unchanged size was counted again"
  [ "$(record_field "$record" verb)" = "done" ] \
    || fail "a status log of unchanged size restamped the observation"
  pass "terminal capture: an observed task whose log has not grown is never re-counted"
}

test_a_second_terminal_report_is_its_own_observation() {
  local state record first second
  state=$(case_state second-report)
  printf 'failed: pipeline red\n' > "$state/alpha.status"
  record="$state/alpha.terminal-at"

  status_terminal_capture "$state" alpha || fail "capture failed"
  first=$(record_field "$record" events)
  [ "$first" = 1 ] || fail "the first observation did not count one terminal event"
  # A relaunched task that finishes again is a new completion, not a replay.
  sleep 1
  printf 'done: ready in branch\n' >> "$state/alpha.status"
  status_terminal_capture "$state" alpha || fail "second capture failed"
  second=$(record_field "$record" events)
  [ "$second" = 2 ] || fail "a second terminal report was not observed as its own event"
  [ "$(record_field "$record" verb)" = "done" ] \
    || fail "the second observation did not record the newer terminal verb"
  pass "terminal capture: a relaunched task's second completion is observed as its own event"
}

test_a_task_that_has_not_finished_records_nothing() {
  local state
  state=$(case_state unfinished)
  printf '%s\n' 'working: implementing' 'needs-decision: pick one' \
    > "$state/alpha.status"

  status_terminal_capture "$state" alpha || fail "capture failed"
  assert_absent "$state/alpha.terminal-at" \
    "an unfinished task was given a completion time"
  pass "terminal capture: a task with no terminal report has no recorded completion time"
}

test_the_scan_covers_every_task_in_a_home() {
  local state
  state=$(case_state scan)
  printf 'done: PR ready\n' > "$state/alpha.status"
  printf 'working: still going\n' > "$state/beta.status"
  printf 'failed: gave up\n' > "$state/gamma.status"

  status_terminal_capture_scan "$state" || fail "scan failed"
  assert_present "$state/alpha.terminal-at" "the scan skipped a finished task"
  assert_absent "$state/beta.terminal-at" "the scan timed an unfinished task"
  assert_present "$state/gamma.terminal-at" "the scan skipped a failed task"
  pass "terminal capture: one supervision pass records every finished task in the home and no unfinished one"
}

test_an_unsafe_status_record_is_left_alone() {
  local state
  state=$(case_state unsafe)
  printf 'done: PR ready\n' > "$state/real.status"
  ln -s "$state/real.status" "$state/alpha.status"

  status_terminal_capture "$state" alpha || fail "capture failed"
  assert_absent "$state/alpha.terminal-at" \
    "a symlinked status record was read and timed"
  pass "terminal capture: a status record that is not a plain file is left unread"
}

test_a_terminal_report_is_observed_once
test_a_later_poll_never_rewrites_the_first_observation
test_an_unchanged_size_log_is_not_recounted
test_a_second_terminal_report_is_its_own_observation
test_a_task_that_has_not_finished_records_nothing
test_the_scan_covers_every_task_in_a_home
test_an_unsafe_status_record_is_left_alone
