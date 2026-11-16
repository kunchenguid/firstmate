#!/usr/bin/env bash
# tests/fm-outcome-batch-host.test.sh - held routine captain outcomes reach main
# through the real supervision host while it is parked, with no further event
# and no model call (bin/fm-supervision-host.sh outcome_batch_tick,
# bin/fm-outcome-batch-lib.sh).
#
# Pins: an engine question reaches main at once unless the engine marked it
# batchable; one held outcome and then complete silence is handed to main once its
# window passes, including after the host restarts; a batch still inside its
# window keeps the park; removing the setting releases what it held; away, the
# outcomes wait for the return. Uses the shared host fixtures, which run the
# real host and watcher against an isolated home and a stub engine.
set -u

# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

# A held batch exactly as the host leaves one: an unread captain row dated
# <age> seconds ago and its hold record.
seed_held() {  # <home> <age-seconds>
  local epoch=$(($(date +%s) - $2))
  outcome_row 1 "$epoch" demo captain 'progress note' > "$1/state/branch-outcomes.jsonl"
  printf 'first=%s\n' "$epoch" > "$1/state/.outcome-batch"
  append_status "$1" 'on it'
}

test_expired_batch_reaches_main_without_another_event() {
  local home
  home=$(make_home batch-expired attended)
  printf 'window-seconds=60\n' > "$home/config/outcome-batch"
  seed_held "$home" 120
  FM_OUTCOME_BATCH_TICK=1 start_host "$home"
  wait_until 300 host_exited "$home" || fail "an expired batch must end the park without any further event"
  assert_re '^supervision-host: branch-outcome: the supervision session held routine captain outcomes for you until their batching window passed' \
    "$home/host.out" "the release must tell main to drain the held outcomes"
  assert_equals 0 "$(engine_calls "$home")" "the release must not start a model"
  watcher_live "$home" && fail "the release must stop the watcher like any hand-back"
  [ -f "$home/state/.outcome-batch" ] || fail "the release keeps the record until main has drained the outcomes"
  # A restarted host, as after main's turn end, releases again while nothing
  # has drained, and clears the record once the drain presented the rows.
  rm -f "$home/host.rc"
  FM_OUTCOME_BATCH_TICK=1 start_host "$home"
  wait_until 300 host_exited "$home" || fail "a restarted host must release a batch that is still unread"
  # Main drains: its BRANCH OUTCOMES section presents the held row, and it
  # acknowledges what the drain printed.
  main_drain_and_ack "$home"
  rm -f "$home/host.rc"
  FM_OUTCOME_BATCH_TICK=1 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "after the drain the host must park normally"
  sleep 3
  host_exited "$home" && fail "a drained batch must not end the park again: $(cat "$home/host.out") | $(tail -3 "$home/state/.supervision-host.log")"
  [ ! -e "$home/state/.outcome-batch" ] || fail "a drained batch clears its record"
  stop_home_processes "$home"
  pass "host: one held outcome then silence reaches main at its deadline, again after a restart, and never after the drain"
}

test_batch_inside_its_window_keeps_the_park() {
  local home
  home=$(make_home batch-fresh attended)
  printf 'window-seconds=3600\n' > "$home/config/outcome-batch"
  seed_held "$home" 10
  FM_OUTCOME_BATCH_TICK=1 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "the host never parked"
  sleep 4
  host_exited "$home" && fail "a batch inside its window must not end the park: $(cat "$home/host.out")"
  stop_home_processes "$home"
  pass "host: a batch inside its window keeps the park"
}

test_removed_setting_releases_and_away_waits() {
  local home
  home=$(make_home batch-removed attended)
  seed_held "$home" 10
  FM_OUTCOME_BATCH_TICK=1 start_host "$home"
  wait_until 300 host_exited "$home" || fail "a batch whose setting was removed must reach main"
  assert_re 'batching window passed' "$home/host.out" "the removed setting releases through the same hand-back"
  home=$(make_home batch-away away)
  printf 'window-seconds=60\n' > "$home/config/outcome-batch"
  seed_held "$home" 120
  FM_OUTCOME_BATCH_TICK=1 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "the away host never parked"
  sleep 4
  host_exited "$home" && fail "away, held outcomes wait for the return: $(cat "$home/host.out")"
  stop_home_processes "$home"
  pass "host: removing the setting releases the batch, and away it waits for the captain's return"
}

# The re-review's case: the engine discovers a question while the worker's
# durable status still says working, and words it so no keyword matches. It
# reaches main at once, because the engine did not mark it batchable; the same
# turn with a finished result the engine marked batchable is held.
test_engine_question_reaches_main_at_once() {
  local home
  home=$(make_home batch-alpha attended)
  : > "$home/config/outcome-batch"
  echo captain-say > "$home/stub-mode"
  printf 'Please select A or B\n' > "$home/stub-summary"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "question: the host never parked"
  append_status "$home" 'continuing'
  wait_until 300 host_exited "$home" || fail "question: an unmarked captain outcome must end the park at once: $(tail -5 "$home/state/.supervision-host.log")"
  assert_equals 1 "$(engine_calls "$home")" "question: one engine turn handled the wake"
  [ ! -e "$home/state/.outcome-batch" ] || fail "question: an unmarked outcome must not be held"
  assert_no_re 'outcome-batch	hold' "$home/state/.supervision-host.log" "question: the host must not log a hold"
  stop_home_processes "$home"
  home=$(make_home batch-marked attended)
  : > "$home/config/outcome-batch"
  echo captain-say > "$home/stub-mode"
  printf 'Setup finished; the tests run next\n' > "$home/stub-summary"
  printf -- '--batchable\ntrue\n' > "$home/stub-report-flags"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "marked: the host never parked"
  append_status "$home" 'continuing'
  wait_until 300 handled_at_least "$home" 1 || fail "marked: the wake was not handled"
  wait_until 150 watcher_live "$home" || fail "marked: a held outcome must keep the park"
  sleep 3
  host_exited "$home" && fail "marked: a batchable outcome must be held: $(cat "$home/host.out")"
  assert_re 'outcome-batch	hold' "$home/state/.supervision-host.log" "marked: the host logs the hold"
  [ -f "$home/state/.outcome-batch" ] || fail "marked: the hold leaves its release record"
  stop_home_processes "$home"
  pass "host: an engine question reaches main at once whatever its words; only an outcome the engine marked batchable is held"
}

fm_test_run \
  test_engine_question_reaches_main_at_once \
  test_expired_batch_reaches_main_without_another_event \
  test_batch_inside_its_window_keeps_the_park \
  test_removed_setting_releases_and_away_waits
