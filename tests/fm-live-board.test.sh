#!/usr/bin/env bash
# Behavior tests for bin/fm-live-board.sh: the read-only sampler's truthful
# classification of a supervised run (alive/progressing/stalled/finished), the
# error scan that must not mistake the federation's own "errors" store for a
# failure, the injected page, and the self-terminating watch that leaves a
# page saying the watch ENDED rather than looking like a dead monitor.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-live-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-board)
STANDIN_PIDS=()

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

teardown() {
  # The stand-in is a shell wrapper around a sleep, so killing the recorded pid
  # leaves the sleep alive holding the test's stdout. The run directory is a
  # unique path, so matching on it reaps the whole stand-in tree and nothing else.
  pkill -f "$TMP_ROOT/" 2>/dev/null || true
  local pid
  for pid in "${STANDIN_PIDS[@]+"${STANDIN_PIDS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap teardown EXIT INT TERM

# make_run <name>: a run directory shaped exactly like the one the watcher is
# pointed at in production - logs/ with the runner's timestamped phase logs, a
# memory trace, and its exit files - so the sampler is exercised through the
# real file layout rather than a stub.
make_run() {  # <name>
  local run="$TMP_ROOT/$1"
  mkdir -p "$run/logs" "$run/scratch/unified" "$run/bin"
  printf '=== build started 2026-10-06T00:00:00Z ===\n' >"$run/logs/run.log"
  cat >"$run/logs/build.log" <<EOF
[   12.0s] brain unify plan
[   12.0s] participating sources: 3
[   12.0s] errors                   errors               yes               5  errors
[   12.0s] BUILD BLOCKED: 2 id collision(s) whose copies disagree on content
[   12.0s] --- building ---
[  111.0s] [   98.8s] isolated dolt server on 127.0.0.1:60954, data dir $run/scratch/unified
[  200.0s] [  187.0s] importing alpha                    from database alpha      beads=10
[  300.0s] [  287.0s] importing beta                     from database beta       beads=20
[  310.0s] [  297.0s]   beta                     3 bead(s) skipped as collision losers
[  410.0s] [  397.0s] importing errors                   from database errors     beads=5
EOF
  cat >"$run/logs/mem.csv" <<'EOF'
epoch,swap_used_mb,dolt_sqlserver_rss_mb,dolt_sqlserver_procs
1791270000,100,2000,2
1791270005,110,2100,2
EOF
  printf '%s\n' "$run"
}

# start_standin <run>: a live process whose command line names the run, taking
# the place of the real build so liveness, the CPU sum, and process discovery
# are exercised against a real process table entry rather than a fixture. The
# stdout redirect keeps the stand-in from holding the test's own output pipe.
start_standin() {  # <run>
  local run=$1
  cat >"$run/bin/bd" <<'SH'
#!/usr/bin/env bash
while :; do sleep 1; done
SH
  chmod +x "$run/bin/bd"
  "$run/bin/bd" brain unify build --data-dir "$run/scratch/unified" >/dev/null 2>&1 &
  STANDIN_PIDS+=("$!")
  sleep 0.4
}

start_dolt_standin() {  # <run>
  local run=$1
  cat >"$run/bin/dolt" <<'SH'
#!/usr/bin/env bash
while :; do sleep 1; done
SH
  chmod +x "$run/bin/dolt"
  "$run/bin/dolt" dolt sql-server -H 127.0.0.1 -P 60954 --data-dir "$run/scratch/unified" >/dev/null 2>&1 &
  STANDIN_PIDS+=("$!")
  sleep 0.3
}

sample_of() {  # <run> <out>
  bash "$BOARD" sample --run-dir "$1" --out "$2" --label "test run" || fail "sample failed for $1"
  jq -e . "$2" >/dev/null || fail "sample did not write valid JSON: $(cat "$2")"
}

test_a_live_importing_run_is_reported_alive_and_progressing() {
  local run out
  run=$(make_run live)
  start_standin "$run"
  start_dolt_standin "$run"
  out="$TMP_ROOT/live.json"
  sample_of "$run" "$out"
  jq -e '
    .schema == "fm-live-board.v1" and
    .process.alive == true and
    .process.pid > 0 and
    .process.count == 2 and
    .process.cpu_s >= 0 and
    .process.window_s > 0 and
    .health.work_dolt_rss_mb > 0 and
    .progress.phase == "build" and
    .progress.sources_total == 3 and
    .progress.sources_done == 2 and
    .progress.current_source == "errors" and
    .progress.cadence_known == true and
    .progress.max_gap_s == 100 and
    .verdict == "progressing"
  ' "$out" >/dev/null || fail "live run was not classified alive and progressing: $(cat "$out")"
  pass "a live importing run is reported alive and progressing"
}

test_the_error_scan_does_not_call_the_errors_store_a_failure() {
  local run out
  run=$(make_run store-named-errors)
  start_standin "$run"
  out="$TMP_ROOT/errors-store.json"
  sample_of "$run" "$out"
  jq -e '.errors.count == 0 and .verdict != "errors"' "$out" >/dev/null ||
    fail "the store named errors was reported as a failure: $(jq -c '.errors' "$out")"
  pass "a store literally named errors is not reported as a failure"
}

test_a_genuine_failure_line_is_surfaced_as_an_error() {
  local run out
  run=$(make_run failing)
  start_standin "$run"
  printf '[  500.0s] [  487.1s] failed to write row 3 into issues\n' >>"$run/logs/build.log"
  out="$TMP_ROOT/failing.json"
  sample_of "$run" "$out"
  jq -e '
    .errors.count == 1 and .verdict == "errors" and
    (.errors.lines[0] | test("failed to write row 3"))
  ' "$out" >/dev/null || fail "a genuine failure line was not surfaced: $(cat "$out")"
  pass "a genuine failure line is surfaced as an error"
}

test_accepted_collisions_are_reported_rather_than_hidden() {
  local run out
  run=$(make_run collisions)
  start_standin "$run"
  out="$TMP_ROOT/collisions.json"
  sample_of "$run" "$out"
  jq -e '
    .collisions.accepted_content_disagreements == 2 and
    .collisions.skipped_losing_rows == 3
  ' "$out" >/dev/null || fail "accepted collisions were not reported: $(jq -c .collisions "$out")"
  pass "content-disagreeing collisions the build accepted are reported"
}

test_a_disappeared_process_is_reported_as_gone_and_not_another_runs() {
  local run other out
  run=$(make_run gone)
  # A second run of the same command is alive at the same time, which the fleet
  # does during a retry. The dead run must read as dead, not adopt the live
  # run's process as its own - the one number a liveness page must never fake.
  other=$(make_run other-still-running)
  start_standin "$other"
  out="$TMP_ROOT/gone.json"
  sample_of "$run" "$out"
  jq -e '
    .process.alive == false and .process.pid == 0 and .process.count == 0 and
    .verdict == "gone" and .finished == false
  ' "$out" >/dev/null || fail "a vanished process was not reported as gone: $(cat "$out")"
  pass "a dead run reads as dead rather than adopting a live run of the same command"
}

test_the_command_match_is_an_explicit_opt_in_fallback() {
  local run loose out
  run=$(make_run match-fallback)
  loose="$TMP_ROOT/loose-bin"
  mkdir -p "$loose"
  cat >"$loose/marker-unique-runner" <<'SH'
#!/usr/bin/env bash
while :; do sleep 1; done
SH
  chmod +x "$loose/marker-unique-runner"
  # This process never names the run directory, so only an explicit --match can
  # find it; without one the run honestly reads as having no process.
  "$loose/marker-unique-runner" --data-dir "$TMP_ROOT/elsewhere" >/dev/null 2>&1 &
  STANDIN_PIDS+=("$!")
  sleep 0.4
  out="$TMP_ROOT/fallback.json"
  bash "$BOARD" sample --run-dir "$run" --out "$out" --label probe >/dev/null || fail "sample failed"
  jq -e '.process.alive == false and .verdict == "gone"' "$out" >/dev/null ||
    fail "a run with no process naming it should read as gone without --match: $(jq -c .process "$out")"
  bash "$BOARD" sample --run-dir "$run" --out "$out" --label probe \
    --match 'marker-unique-runner' >/dev/null || fail "sample with --match failed"
  jq -e '.process.alive == true and .process.pid > 0 and .verdict == "progressing"' "$out" >/dev/null ||
    fail "--match did not find a process that never names the run directory: $(jq -c .process "$out")"
  pass "the command match is an explicit opt-in fallback, never the default"
}

test_a_finished_build_reports_its_result_and_stops() {
  local run out
  run=$(make_run verified)
  printf 'EXIT=0\n' >"$run/logs/build.exit"
  out="$TMP_ROOT/verified.json"
  sample_of "$run" "$out"
  jq -e '.outcome.state == "build-ok" and .finished == false' "$out" >/dev/null ||
    fail "a clean build did not report build-ok with verification still to run: $(cat "$out")"
  printf 'EXIT=0\n' >"$run/logs/verify.exit"
  printf 'verification complete: 0 failures\n' >"$run/logs/verify.log"
  printf '=== verify finished elapsed=10s status=EXIT=0 ===\n=== all phases done ===\n' >>"$run/logs/run.log"
  sample_of "$run" "$out"
  jq -e '
    .finished == true and .outcome.state == "verified" and .outcome.ok == true and
    .verdict == "finished-ok"
  ' "$out" >/dev/null || fail "a verified run did not report a clean final result: $(cat "$out")"
  pass "a finished run reports its final result instead of going blank"
}

test_a_failed_build_names_the_signal_and_that_nothing_was_verified() {
  local run out
  run=$(make_run killed)
  printf 'EXIT=137\n' >"$run/logs/build.exit"
  out="$TMP_ROOT/killed.json"
  sample_of "$run" "$out"
  jq -e '
    .finished == true and .outcome.ok == false and .outcome.state == "build-failed" and
    (.outcome.title | test("killed outright")) and
    (.exit.build_note | test("SIGKILL")) and
    (.outcome.detail | test("verification never ran")) and
    (.outcome.detail | test("2 of 3 sources"))
  ' "$out" >/dev/null || fail "a killed build was not reported in plain terms: $(cat "$out")"
  pass "a failed build names the signal and that nothing was verified"
}

test_a_failed_verification_names_its_defects() {
  local run out
  run=$(make_run verify-failed)
  printf 'EXIT=0\n' >"$run/logs/build.exit"
  printf 'EXIT=1\n' >"$run/logs/verify.exit"
  printf 'collision agent-0bq present 0 times, want 1\n' >"$run/logs/verify.log"
  out="$TMP_ROOT/verify-failed.json"
  sample_of "$run" "$out"
  jq -e '
    .finished == true and .outcome.state == "verify-failed" and .outcome.ok == false and
    .verdict == "finished-failed" and
    (.outcome.defects | length) == 1 and
    (.outcome.defects[0] | test("present 0 times, want 1"))
  ' "$out" >/dev/null || fail "a failed verification did not name its defects: $(cat "$out")"
  pass "a failed verification names the defects it found"
}

test_a_starved_run_with_no_cpu_and_no_progress_is_called_stalled() {
  local run out
  run=$(make_run starved)
  out="$TMP_ROOT/starved.json"
  # Age the log well past the 180s absolute fallback and keep no process alive
  # for the CPU window, which is the shape a starved run has from outside.
  touch -t 202001010000 "$run/logs/build.log"
  sample_of "$run" "$out"
  jq -e '.verdict == "gone"' "$out" >/dev/null ||
    fail "a starved run with no process should read as gone: $(cat "$out")"
  pass "a run whose process is gone is not quietly called progressing"
}

test_the_sampler_never_writes_into_the_run_it_watches() {
  local run out before after
  run=$(make_run read-only)
  start_standin "$run"
  before=$(cd "$run" && find . -type f -exec shasum {} + | sort)
  out="$TMP_ROOT/read-only.json"
  sample_of "$run" "$out"
  after=$(cd "$run" && find . -type f -exec shasum {} + | sort)
  assert_equals "$before" "$after" "the sampler modified the run directory it reads"
  assert_absent "$run/logs/state.rows" "the sampler wrote its state into the run directory"
  pass "the sampler reads the run and writes only its own output"
}

test_the_page_injects_its_config_and_leaves_no_placeholder() {
  local out line
  out="$TMP_ROOT/page.html"
  bash "$BOARD" page --out "$out" --label "a <b> label" >/dev/null || fail "page failed"
  assert_no_grep '__FM_LIVE_CONFIG__' "$out" "the page left the placeholder behind"
  line=$(grep -F 'window.FM_LIVE = ' "$out" | head -1)
  [ -n "$line" ] || fail "the page did not inject a live config"
  # The injected label must survive as data rather than as markup, so the
  # injected block is parsed back and compared to the label that went in.
  printf '%s' "${line#window.FM_LIVE = }" | sed 's/;$//' | jq -e '(.data == "page.json") and (.label == "a <b> label")' >/dev/null ||
    fail "the injected config did not round-trip: $line"
  assert_no_grep 'a <b> label' "$out" "the label was injected as raw markup rather than escaped data"
  pass "the page injects its config with the placeholder consumed and markup escaped"
}

test_watch_terminates_and_marks_why_it_stopped() {
  local run start elapsed out
  run=$(make_run watch-stop)
  start_standin "$run"
  out="$TMP_ROOT/watch.html"
  start=$(date +%s)
  bash "$BOARD" watch --run-dir "$run" --out "$out" --interval 1 --max-seconds 2 >/dev/null ||
    fail "watch exited non-zero"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 20 ] || fail "watch did not stop at its own limit (took ${elapsed}s)"
  jq -e '
    .monitor.stopped == true and
    (.monitor.reason | test("time limit")) and
    .monitor.pid > 0
  ' "$TMP_ROOT/watch.json" >/dev/null ||
    fail "watch did not record why it stopped: $(cat "$TMP_ROOT/watch.json")"
  assert_present "$TMP_ROOT/watch.json" "watch did not write the page's data file"
  pass "watch stops at its limit and leaves a page that says why"
}

test_watch_stops_at_once_on_a_finished_run() {
  local run out
  run=$(make_run watch-finished)
  printf 'EXIT=0\n' >"$run/logs/build.exit"
  printf 'EXIT=0\n' >"$run/logs/verify.exit"
  printf '=== all phases done ===\n' >>"$run/logs/run.log"
  out="$TMP_ROOT/watch-finished.html"
  bash "$BOARD" watch --run-dir "$run" --out "$out" --interval 1 --max-seconds 30 >/dev/null ||
    fail "watch exited non-zero on a finished run"
  jq -e '
    .finished == true and .monitor.stopped == true and
    (.monitor.reason | test("final result"))
  ' "$TMP_ROOT/watch-finished.json" >/dev/null ||
    fail "watch did not stop on the final result: $(cat "$TMP_ROOT/watch-finished.json")"
  pass "watch stops immediately once the run reaches its final result"
}

test_usage_errors_fail_rather_than_guessing() {
  expect_code 1 "$(bash "$BOARD" sample --out "$TMP_ROOT/x.json" >/dev/null 2>&1; echo $?)" \
    "sample without --run-dir"
  expect_code 1 "$(bash "$BOARD" sample --run-dir "$TMP_ROOT/nope" --out "$TMP_ROOT/x.json" >/dev/null 2>&1; echo $?)" \
    "sample against a missing run directory"
  expect_code 1 "$(bash "$BOARD" nonsense >/dev/null 2>&1; echo $?)" "an unknown subcommand"
  expect_code 1 "$(bash "$BOARD" watch --out "$TMP_ROOT/y.html" >/dev/null 2>&1; echo $?)" \
    "watch without --run-dir"
  pass "usage errors fail rather than guessing"
}

test_a_live_importing_run_is_reported_alive_and_progressing
test_the_error_scan_does_not_call_the_errors_store_a_failure
test_a_genuine_failure_line_is_surfaced_as_an_error
test_accepted_collisions_are_reported_rather_than_hidden
test_a_disappeared_process_is_reported_as_gone_and_not_another_runs
test_the_command_match_is_an_explicit_opt_in_fallback
test_a_finished_build_reports_its_result_and_stops
test_a_failed_build_names_the_signal_and_that_nothing_was_verified
test_a_failed_verification_names_its_defects
test_a_starved_run_with_no_cpu_and_no_progress_is_called_stalled
test_the_sampler_never_writes_into_the_run_it_watches
test_the_page_injects_its_config_and_leaves_no_placeholder
test_watch_terminates_and_marks_why_it_stopped
test_watch_stops_at_once_on_a_finished_run
test_usage_errors_fail_rather_than_guessing
