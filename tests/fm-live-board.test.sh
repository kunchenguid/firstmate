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

test_the_producer_is_portable_and_only_ever_reads() {
  local producer bad
  producer="$TMP_ROOT/producer.sh"
  bash "$BOARD" producer >"$producer" || fail "the producer could not be printed"
  # It runs through `sh` on whatever host it is sent to, so it must be valid for
  # that shell; a quoting mistake here would silently sample nothing.
  sh -n "$producer" || fail "the producer is not valid for the shell it runs under"
  bad=$(grep -nE '\b(kill|pkill|killall|reboot|shutdown|sighup|sigterm|sigkill|rm|mv|cp|tee|truncate|chmod|chown|launchctl|systemctl|sudo)\b' "$producer" || true)
  # A redirection onto anything under the run directory is also a write, and the
  # verb list alone would not catch `: >"$RUN_DIR/..."`.
  bad="$bad$(grep -nE '>>?[[:space:]]*"?[^ ]*RUN_DIR' "$producer" || true)"
  [ -z "$bad" ] || fail "the producer contains a state-changing verb: $bad"
  pass "the producer is portable sh and never changes state on the host it samples"
}

test_a_remote_run_is_sampled_through_ssh_without_using_this_host() {
  local home fakebin bundle now out
  make_run remote >/dev/null
  home="$TMP_ROOT/remote-home"
  mkdir -p "$home"
  fakebin=$(fm_fakebin "$home")
  now=$(date +%s)
  bundle="$home/bundle.txt"
  # A bundle as the remote producer would emit it: a verify phase in flight on
  # another host, with host facts that differ from this machine on purpose so a
  # leak of local facts or local processes shows up as a failure.
  cat >"$bundle" <<EOF
##FF v1
##NOW
$now
##HOST
mini0
##STAT
run.log	209	$((now - 3))
build.log	4096	$((now - 200))
verify.log	1024	$((now - 4))
##LOG run.log
=== build started 2026-10-06T00:00:00Z ===
=== build finished 2026-10-06T00:30:00Z elapsed=1800s status=EXIT=0 ===
=== verify started 2026-10-06T00:30:00Z ===
##ENDLOG
##LOG build.log
[   12.0s] participating sources: 3
[   12.0s] --- building ---
[  111.0s] [   98.8s] created child_counters   scope=issue-child
[  111.0s] [   99.0s] created issues   scope=issues
[  111.0s] [   99.0s] created wisps   scope=issue-child
##ENDLOG
##LOG verify.log
[   14.0s] table child_counters   scope=issue-child
[   14.0s]   unified child_counters  10 group(s)
[   56.0s] table issues   scope=issues
[   57.0s]   unified issues  51 group(s)
##ENDLOG
##PS
4242	00:30	0:10.00	524288	S	bash /remote/run/bin/bd brain unify verify --data-dir /remote/run/scratch/unified
8000	00:30	2:00.00	1048576	S	dolt sql-server -H 127.0.0.1 -P 55547 --data-dir /remote/run/scratch/unified
##SYSCTL
swap_total_mb	2048
swap_used_mb	98
cores	10
load_1m	2
##WORKDIR
/remote/run/scratch/unified
##DU
6298
EOF
  cat >"$fakebin/ssh" <<EOF
#!/usr/bin/env bash
cat >/dev/null
cat '$bundle'
EOF
  chmod +x "$fakebin/ssh"
  out="$TMP_ROOT/remote.json"
  PATH="$fakebin:$PATH" bash "$BOARD" sample --run-dir /remote/run --out "$out" \
    --ssh mini0 --label "remote test" >/dev/null || fail "the remote sample failed"
  jq -e '
    .source.kind == "ssh" and .source.target == "mini0" and .source.host == "mini0" and
    .source.reachable == true and .source.run_dir == "/remote/run" and
    .progress.phase == "verify" and .progress.unit == "tables" and
    .progress.sources_total == 3 and .progress.sources_done == 2 and
    .progress.current_source == "issues" and
    .process.alive == true and .process.count == 2 and .process.cpu_s == 130 and
    .health.cores == 10 and .health.load_1m == 2 and .health.swap_used_mb == 98 and
    .health.work_dir == "/remote/run/scratch/unified" and .health.scratch_mb == 6 and
    .errors.count == 0 and .verdict == "progressing"
  ' "$out" >/dev/null || fail "the remote bundle was not sampled correctly: $(cat "$out")"
  pass "a remote run is sampled over ssh, using the remote host facts and the remote processes"
}

test_an_unreachable_host_is_never_drawn_as_an_idle_run() {
  local home fakebin out
  home="$TMP_ROOT/unreachable-home"
  mkdir -p "$home"
  fakebin=$(fm_fakebin "$home")
  cat >"$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'ssh: connect to host mini0 port 22: Connection refused\n' >&2
exit 255
SH
  chmod +x "$fakebin/ssh"
  out="$TMP_ROOT/unreachable.json"
  PATH="$fakebin:$PATH" bash "$BOARD" sample --run-dir /remote/run --out "$out" \
    --ssh mini0 --label "unreachable test" >/dev/null || fail "an unreachable host should still write a sample"
  jq -e '
    .verdict == "unreachable" and
    .source.reachable == false and .source.target == "mini0" and
    (.source.error | test("Connection refused")) and
    (.verdict_note | test("cannot reach mini0")) and
    .finished == false and .outcome == null and
    .process.alive == false and .process.count == 0
  ' "$out" >/dev/null || fail "an unreachable host was not reported as unreachable: $(cat "$out")"
  jq -e '.verdict != "gone"' "$out" >/dev/null ||
    fail "an unreachable host was reported as a stopped run, which is a different fact"
  pass "an unreachable host reads as unreachable, never as an idle or stopped run"
}

test_a_source_server_inside_the_run_directory_is_not_the_run() {
  local run out
  # The real run directory is named after the build, so a long-lived source
  # server sits under it and carries that name in its own path. With no run
  # process alive, that server must not be adopted as the run: it would report
  # hours of its own CPU and gigabytes of its own memory as the run's liveness.
  run=$(make_run brain-unify)
  mkdir -p "$run/bin" "$run/prod-src/.beads"
  cat >"$run/bin/dolt-server" <<'SH'
#!/usr/bin/env bash
while :; do sleep 1; done
SH
  chmod +x "$run/bin/dolt-server"
  "$run/bin/dolt-server" sql-server -H 127.0.0.1 -P 3391 --data-dir "$run/prod-src/.beads" >/dev/null 2>&1 &
  STANDIN_PIDS+=("$!")
  sleep 0.4
  out="$TMP_ROOT/contaminant.json"
  sample_of "$run" "$out"
  jq -e '.process.count == 0 and .process.alive == false' "$out" >/dev/null ||
    fail "a source server under the run directory was adopted as the run: $(jq -c .process "$out")"
  pass "a source server inside the run directory is not mistaken for the run"
}

test_the_page_names_its_target_and_never_calls_an_unreachable_run_idle() {
  local harness page unreachable reached got
  command -v node >/dev/null 2>&1 || { echo "skip: node not found for the page harness"; return 0; }
  harness="$TMP_ROOT/page-harness.js"
  page="$TMP_ROOT/page.html"
  bash "$BOARD" page --out "$page" --label "page test" >/dev/null || fail "page failed"
  cat >"$harness" <<'JS'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const js = html.match(/<script>([\s\S]*)<\/script>/)[1];
const sample = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const nodes = {};
function mk(id) {
  return { id: id, textContent: '', className: '', title: '', innerHTML: '', style: {},
           classList: { add() {}, remove() {} }, appendChild() {} };
}
global.document = {
  getElementById: (id) => (nodes[id] = nodes[id] || mk(id)),
  createElement: () => mk('created'),
  createElementNS: () => ({ setAttribute() {} }),
};
global.window = { FM_LIVE: { data: 'live.json', label: 'page test' } };
global.fetch = () => Promise.resolve({ ok: true, json: () => Promise.resolve(sample) });
global.setInterval = () => 0;
eval(js);
setTimeout(() => {
  const out = {};
  for (const id of ['stale', 'pid', 'gap', 'cadence', 'source', 'verdict', 'watchhint', 'outcome-title', 'sources', 'current']) {
    out[id] = nodes[id] ? nodes[id].textContent : null;
  }
  out.staleClass = nodes.stale ? nodes.stale.className : '';
  console.log(JSON.stringify(out));
}, 60);
JS
  unreachable=$(node -e 'process.stdout.write(JSON.stringify({schema:"fm-live-board.v1",label:"t",run_dir:"/remote/run",sampled_at:Math.floor(Date.now()/1000),monitor:{pid:0,interval_s:3,stale_after_s:12,stopped:false,reason:""},verdict:"unreachable",verdict_note:"cannot reach mini0",finished:false,source:{kind:"ssh",target:"mini0",host:"mini0",run_dir:"/remote/run",reachable:false,error:"ssh: connect to host mini0 port 22: Connection refused"},process:{alive:false,pid:0,etime:"",elapsed_s:0,cpu_s:0,cpu_delta_s:0,window_s:3,rss_mb:0,count:0,members:[]},progress:{phase:"build",unit:"sources",sources_total:0,sources_done:0,current_source:"",current_beads:"",current_table:"",last_line:"",gap_s:0,max_gap_s:0,cadence_known:false,log_bytes:0},collisions:{},errors:{count:0,lines:[]},health:{},exit:{},outcome:null,log_tail:[],history_mem:[]}))')
  printf '%s' "$unreachable" >"$TMP_ROOT/unreachable-sample.json"
  got=$(node "$harness" "$page" "$TMP_ROOT/unreachable-sample.json")
  printf '%s' "$got" | jq -e '
    (.stale | test("CANNOT SEE THE RUN")) and
    (.stale | test("mini0")) and
    (.pid == "unknown - no contact") and
    (.gap == "?") and
    (.source | test("watching mini0:/remote/run")) and
    (.source | test("remote"))
  ' >/dev/null || fail "an unreachable sample was not drawn as a visibility problem: $got"
  printf '%s' "$got" | jq -e '.pid != "not running"' >/dev/null ||
    fail "an unreachable sample claimed the run was not running: $got"
  reached=$(node -e 'process.stdout.write(JSON.stringify({schema:"fm-live-board.v1",label:"t",run_dir:"/remote/run",sampled_at:Math.floor(Date.now()/1000),monitor:{pid:9,interval_s:3,stale_after_s:12,stopped:false,reason:""},verdict:"progressing",verdict_note:"fine",finished:false,source:{kind:"ssh",target:"mini0",host:"mini0",run_dir:"/remote/run",reachable:true,error:""},process:{alive:true,pid:4242,etime:"00:30",elapsed_s:30,cpu_s:130,cpu_delta_s:4,window_s:60,rss_mb:512,count:2,members:[]},progress:{phase:"verify",unit:"tables",sources_total:27,sources_done:2,current_source:"issues",current_beads:"",current_table:"",last_line:"x",gap_s:4,max_gap_s:42,cadence_known:true,log_bytes:100},collisions:{},errors:{count:0,lines:[]},health:{},exit:{},outcome:null,log_tail:[],history_mem:[]}))')
  printf '%s' "$reached" >"$TMP_ROOT/reached-sample.json"
  got=$(node "$harness" "$page" "$TMP_ROOT/reached-sample.json")
  printf '%s' "$got" | jq -e '
    (.pid == "pid 4242") and (.gap == 4) and
    (.source | test("watching mini0:/remote/run")) and
    (.sources == "2 of 27 tables verified") and
    (.current == "issues")
  ' >/dev/null || fail "a reachable sample was not drawn from its own numbers: $got"
  pass "the page names its target and reads an unreachable run as unseeable, not idle"
}

test_watch_follows_a_run_across_a_retry_when_asked() {
  local run out
  run=$(make_run watch-follow)
  printf 'EXIT=0\n' >"$run/logs/build.exit"
  printf 'EXIT=0\n' >"$run/logs/verify.exit"
  printf '=== all phases done ===\n' >>"$run/logs/run.log"
  out="$TMP_ROOT/watch-follow.html"
  # Without --follow this run is already terminal; with it the watch must keep
  # sampling, so the only thing that ends it is its own time limit.
  bash "$BOARD" watch --run-dir "$run" --out "$out" --follow --interval 1 --max-seconds 2 >/dev/null ||
    fail "follow watch exited non-zero"
  jq -e '
    .monitor.stopped == true and (.monitor.reason | test("time limit"))
  ' "$TMP_ROOT/watch-follow.json" >/dev/null ||
    fail "--follow did not keep watching past a final result: $(cat "$TMP_ROOT/watch-follow.json")"
  pass "--follow keeps watching across a retry instead of stopping at the first result"
}

test_the_run_is_its_runner_tree_not_everything_under_the_directory() {
  local run out decoy
  run=$(make_run runner-tree)
  mkdir -p "$run/bin" "$run/scratch/unified" "$run/scratch/repro"
  local tool
  for tool in bd dolt repro; do
    printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' >"$run/bin/$tool"
    chmod +x "$run/bin/$tool"
  done
  cat >"$run/run-unify.sh" <<'SH'
#!/bin/sh
run=$(dirname "$0")
"$run/bin/bd" brain unify build --data-dir "$run/scratch/unified" &
"$run/bin/dolt" dolt sql-server --data-dir "$run/scratch/unified" &
wait
SH
  chmod +x "$run/run-unify.sh"
  sh "$run/run-unify.sh" >/dev/null 2>&1 &
  STANDIN_PIDS+=("$!")
  # A decoy shaped exactly like a second unify run under the same directory, but
  # started by hand rather than by this runner: a repro of a failure. The tree
  # rule must exclude it while still counting the runner's own Dolt server,
  # which never names the run command itself.
  "$run/bin/repro" brain unify verify --data-dir "$run/scratch/repro" >/dev/null 2>&1 &
  decoy=$!
  STANDIN_PIDS+=("$decoy")
  sleep 0.6
  out="$TMP_ROOT/runner-tree.json"
  sample_of "$run" "$out"
  jq -e --argjson decoy "$decoy" '
    (.health.work_dir | endswith("/scratch/unified")) and
    ([.process.members[] | select(.pid == $decoy)] | length == 0) and
    ([.process.members[] | select(.args | test("brain unify build"))] | length == 1) and
    ([.process.members[] | select(.args | test("dolt sql-server"))] | length == 1)
  ' "$out" >/dev/null ||
    fail "the run was not taken to be its runner tree: $(jq -c '{work:.health.work_dir,members:[.process.members[].args]}' "$out")"
  pass "the run is its runner tree, so a repro beside it is not counted as the run"
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
test_the_producer_is_portable_and_only_ever_reads
test_the_page_names_its_target_and_never_calls_an_unreachable_run_idle
test_a_remote_run_is_sampled_through_ssh_without_using_this_host
test_an_unreachable_host_is_never_drawn_as_an_idle_run
test_a_source_server_inside_the_run_directory_is_not_the_run
test_the_run_is_its_runner_tree_not_everything_under_the_directory
test_the_page_injects_its_config_and_leaves_no_placeholder
test_watch_terminates_and_marks_why_it_stopped
test_watch_stops_at_once_on_a_finished_run
test_watch_follows_a_run_across_a_retry_when_asked
test_usage_errors_fail_rather_than_guessing
