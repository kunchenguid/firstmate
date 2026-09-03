#!/usr/bin/env bash
# Behavior tests for the display-only progress phase and remaining-time guess
# (bin/fm-progress-lib.sh through bin/fm-progress.sh), the watcher's label
# refresh rule, and the Herdr label grammar in bin/backends/herdr.sh.
#
# The crew's current state is served by a canned fm-crew-state.sh
# (FM_CREW_STATE_BIN, exactly the line the real helper prints), the captain
# hold by a canned fm-captain-hold.sh (FM_CAPTAIN_HOLD_BIN), and Herdr by a
# stateful fake `herdr` that answers `workspace get` from a label file and
# logs every `workspace rename`. Time is fixed through FM_PROGRESS_NOW.
#   (a) phase derivation: every phase in the model from its exact sources,
#       including the lifecycle rule that a provably working crew outranks a
#       backlog hold or an old keyed decision, and unknown for an unreadable
#       state
#   (b) observation record: seeding from the spawn instant, per-phase
#       accumulators across transitions, fix-round counting, and the run's own
#       round winning; a record left by an older incarnation of the same id is
#       discarded, and a read in flight while teardown retires the task never
#       recreates its record
#   (c) fallback bands: the documented defaults summed over the phases ahead
#       per delivery sequence, always as a range, and "running long" past a band
#   (d) history and median: fewer than three samples keep the bands; three
#       samples switch a phase to its "~N min" median; teardown's record hook
#       appends one JSONL line and drops the record, --discard drops only
#   (e) label refresh rule: rename only when the suffix changes, at most once
#       per tick, through the version 2 presentation journal only; silent on
#       tmux and on a Herdr task without a bound projection; a failed rename
#       warns and retries on the cadence, a hand-changed label is left alone
#   (f) tick throttle: one phase re-read per cadence window per task, keyed on
#       the tick's own stamp so a snapshot read between ticks never postpones
#       it; the real watcher launches the tick as a detached single-flight
#       child that never holds its poll loop, and its state/.progress-tick.pid
#       marker keeps that single flight across processes (a live real tick
#       child suppresses the launch; a dead pid, a recycled pid owned by an
#       unrelated process, or a marker older than FM_PROGRESS_TICK_MAX_SECS is
#       reclaimed); the watcher's own child past that bound is terminated and
#       relaunched with one warning, while a young one is left alone
#   (g) label grammar: the base is recovered from a decorated label and the
#       token stays the last segment
#   (h) an unreadable (unknown) observation never resets the last known
#       phase's clock or counts a fix round
#   (i) history: the reported sample count is the number of matching finished
#       tasks, and running long starts past their 75th percentile, not the
#       median
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROGRESS="$ROOT/bin/fm-progress.sh"
TMP_ROOT=$(fm_test_tmproot fm-progress)
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

NOW=1788400000
TOKEN=AbCdEfGhIjKlMnOpQrStUv

make_case() {  # <name> -> echoes case dir
  local d="$TMP_ROOT/$1" fb
  mkdir -p "$d/state" "$d/data" "$d/fakebin"
  fb="$d/fakebin"
  # The captain-hold predicate is consulted only for a home that keeps a
  # backlog; the canned fm-captain-hold.sh below answers FM_FAKE_HELD.
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$d/data/backlog.md"
  cat > "$fb/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_CREW_STATE_LOG:-}" ] || printf '%s\n' "$1" >> "$FM_FAKE_CREW_STATE_LOG"
[ -z "${FM_FAKE_CREW_STATE_SLEEP:-}" ] || sleep "$FM_FAKE_CREW_STATE_SLEEP"
[ -z "${FM_FAKE_CREW_STATE_RM:-}" ] || rm -f -- "$FM_FAKE_CREW_STATE_RM"
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake default}"
exit 0
SH
  fm_fake_exit0 "$fb" tmux
  cat > "$fb/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = open ] || exit 2
[ "${FM_FAKE_HELD:-0}" = 1 ]
SH
  # A stateful herdr: `workspace get` answers from $FM_FAKE_HERDR_LABEL_FILE,
  # `workspace rename` logs and rewrites it unless FM_FAKE_HERDR_RENAME_FAIL=1.
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace get")
    [ "${FM_FAKE_HERDR_GET_FAIL:-0}" = 1 ] && exit 1
    printf '{"result":{"workspace":{"workspace_id":"%s","label":%s,"tab_count":1,"pane_count":1}}}\n' \
      "$3" "$(jq -Rn --rawfile l "${FM_FAKE_HERDR_LABEL_FILE:?}" '$l | rtrimstr("\n")')"
    ;;
  "workspace rename")
    [ "${FM_FAKE_HERDR_RENAME_FAIL:-0}" = 1 ] && exit 1
    printf '%s\n' "$4" > "${FM_FAKE_HERDR_LABEL_FILE:?}"
    ;;
  "status --json")
    printf '{"client":{"version":"0.8.2","protocol":19},"server":{"running":true}}\n'
    ;;
esac
exit 0
SH
  chmod +x "$fb/fm-crew-state.sh" "$fb/fm-captain-hold.sh" "$fb/herdr"
  printf '%s\n' "$d"
}

write_task() {  # <case> <id> <kind> <mode> [extra key=val ...]
  local d=$1 id=$2 kind=$3 mode=$4
  shift 4
  fm_write_meta "$d/state/$id.meta" \
    "window=fm:fm-$id" "endpoint_task_id=$id" "worktree=$d/wt-$id" \
    "kind=$kind" "mode=$mode" "spawn_gen=s$((NOW - 1200)).11.22" "$@"
}

# progress <case> <now> <crew-state-line> <held 0|1> <args...>
progress() {
  local d=$1 now=$2 line=$3 held=$4
  shift 4
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_DATA_OVERRIDE="$d/data" \
    FM_CREW_STATE_BIN="$d/fakebin/fm-crew-state.sh" FM_CAPTAIN_HOLD_BIN="$d/fakebin/fm-captain-hold.sh" \
    FM_PROGRESS_NOW="$now" FM_FAKE_CREW_STATE="$line" FM_FAKE_HELD="$held" \
    FM_FAKE_HERDR_LOG="$d/herdr.log" FM_FAKE_HERDR_LABEL_FILE="$d/label" \
    "$PROGRESS" "$@"
}

phase_of() {  # <show-output>
  local out=$1
  out=${out#phase: }
  printf '%s' "${out%% · *}"
}

# ---------------------------------------------------------------------------
# (a) phase derivation

test_phase_matrix() {
  local d out
  d=$(make_case phases)
  write_task "$d" t1 ship no-mistakes
  printf 'working: started\n' > "$d/state/t1.status"

  out=$(progress "$d" "$NOW" 'state: working · source: pane · harness busy (record)' 0 show t1)
  [ "$(phase_of "$out")" = implementing ] || fail "busy pane before any run must be implementing: $out"
  out=$(progress "$d" "$NOW" 'state: working · source: run-step · validating (running) · step: review' 0 show t1)
  [ "$(phase_of "$out")" = validating ] || fail "a running step must be validating: $out"
  assert_contains "$out" "step: review" "the run step rides beside the phase"
  out=$(progress "$d" "$NOW" 'state: working · source: run-step · validating (fixing) · step: review · fix round: 2' 0 show t1)
  [ "$(phase_of "$out")" = fixing ] || fail "a fix step must be fixing: $out"
  out=$(progress "$d" "$NOW" 'state: working · source: run-step · ci running · step: ci' 0 show t1)
  [ "$(phase_of "$out")" = ci ] || fail "the ci step must be ci: $out"
  out=$(progress "$d" "$NOW" 'state: working · source: run-step · validating (running) · step: push' 0 show t1)
  [ "$(phase_of "$out")" = ci ] || fail "the push step must read as ci: $out"
  out=$(progress "$d" "$NOW" 'state: parked · source: run-step · parked at review: 2 finding(s) (ask-user: authority decision)' 0 show t1)
  [ "$(phase_of "$out")" = 'waiting on captain' ] || fail "an ask-user gate waits on the captain: $out"
  out=$(progress "$d" "$NOW" 'state: parked · source: run-step · parked at review: 1 finding(s)' 0 show t1)
  [ "$(phase_of "$out")" = validating ] || fail "a worker-answered gate stays validating: $out"
  assert_contains "$out" "step: review" "the gate names the validating step"
  out=$(progress "$d" "$NOW" 'state: done · source: run-step · checks green: PR ready for review' 0 show t1)
  [ "$(phase_of "$out")" = ready ] || fail "a reported done is ready: $out"
  assert_contains "$out" "ready, awaiting merge" "ready carries no time guess"
  out=$(progress "$d" "$NOW" 'state: blocked · source: status-log · need creds' 0 show t1)
  [ "$(phase_of "$out")" = blocked ] || fail "blocked stays blocked: $out"
  out=$(progress "$d" "$NOW" 'state: paused · source: status-log · waiting on upstream' 0 show t1)
  [ "$(phase_of "$out")" = paused ] || fail "paused stays paused: $out"
  out=$(progress "$d" "$NOW" 'state: failed · source: run-step · run failed' 0 show t1)
  [ "$(phase_of "$out")" = failed ] || fail "failed stays failed: $out"
  out=$(progress "$d" "$NOW" 'garbage that is not a state line' 0 show t1)
  [ "$(phase_of "$out")" = unknown ] || fail "an unreadable state is unknown: $out"
  assert_contains "$out" "guess: unknown" "unknown never carries a stale estimate"
  pass "phase derivation covers implementing, validating, fixing, ci, waiting, ready, blocked, paused, failed, and unknown"
}

test_phase_pr_recorded_without_run_is_ci() {
  local d out
  d=$(make_case pr-ci)
  write_task "$d" t2 ship direct-PR "pr=https://github.com/o/r/pull/5"
  out=$(progress "$d" "$NOW" 'state: working · source: pane · harness busy' 0 show t2)
  [ "$(phase_of "$out")" = ci ] || fail "a recorded PR with a still-working worker is ci: $out"
  pass "a recorded PR moves a working direct-PR worker to ci"
}

test_phase_open_decision_and_hold() {
  local d out
  d=$(make_case decisions)
  write_task "$d" t3 ship no-mistakes
  printf 'needs-decision [key=api]: pick the API shape\nworking: idling\n' > "$d/state/t3.status"
  out=$(progress "$d" "$NOW" 'state: working · source: status-log · idling' 0 show t3)
  [ "$(phase_of "$out")" = 'waiting on captain' ] || fail "an open keyed decision behind a later working line still waits: $out"
  printf 'resolved [key=api]: shape chosen\n' >> "$d/state/t3.status"
  out=$(progress "$d" "$NOW" 'state: working · source: status-log · idling' 0 show t3)
  [ "$(phase_of "$out")" = implementing ] || fail "a resolved decision no longer waits: $out"
  printf 'needs-decision [key=b]: another\n' >> "$d/state/t3.status"
  out=$(progress "$d" "$NOW" 'state: working · source: run-step · validating (running) · step: test' 0 show t3)
  [ "$(phase_of "$out")" = validating ] || fail "a provably working run outranks an old keyed decision: $out"
  out=$(progress "$d" "$NOW" 'state: parked · source: status-log · another' 0 show t3)
  [ "$(phase_of "$out")" = 'waiting on captain' ] || fail "an idle needs-decision waits on the captain: $out"
  # The captain hold predicate: held and idle waits; held but provably working
  # keeps the working phase.
  write_task "$d" t4 ship no-mistakes
  printf 'working: started\n' > "$d/state/t4.status"
  out=$(progress "$d" "$NOW" 'state: unknown · source: pane · harness state unavailable' 1 show t4)
  [ "$(phase_of "$out")" = 'waiting on captain' ] || fail "a captain-held idle task waits on the captain: $out"
  out=$(progress "$d" "$NOW" 'state: working · source: pane · harness busy' 1 show t4)
  [ "$(phase_of "$out")" = implementing ] || fail "a captain hold never masks a provably working crew: $out"
  pass "keyed decisions and captain holds resolve to waiting on captain only while the crew is not provably working"
}

test_secondmate_and_remote_are_skipped() {
  local d out
  d=$(make_case skip)
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "kind=secondmate" "home=$d/home" "spawn_gen=s1.1.1"
  out=$(progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show mate)
  assert_contains "$out" "no local task record" "a secondmate has no phase"
  [ ! -e "$d/state/.progress-mate" ] || fail "a secondmate must not get an observation record"
  write_task "$d" rem ship no-mistakes "remote_host=box"
  out=$(progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show rem)
  assert_contains "$out" "no local task record" "a remote task has no local phase"
  pass "secondmates and remote tasks are skipped without a record"
}

# ---------------------------------------------------------------------------
# (b) observation record

test_record_accumulates_phases() {
  local d rec
  d=$(make_case record)
  write_task "$d" r1 ship no-mistakes
  progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show r1 >/dev/null
  rec="$d/state/.progress-r1"
  [ -f "$rec" ] || fail "the first read must publish the observation record"
  grep -q "^secs_implementing=1200$" "$rec" || fail "time since the spawn instant counts as implementing: $(cat "$rec")"
  grep -q "^since=$((NOW - 1200))$" "$rec" || fail "the first phase starts at the spawn instant: $(cat "$rec")"
  progress "$d" $((NOW + 600)) 'state: working · source: run-step · validating (running) · step: review' 0 show r1 >/dev/null
  grep -q "^secs_implementing=1800$" "$rec" || fail "the interval up to the transition is charged to implementing: $(cat "$rec")"
  grep -q "^since=$((NOW + 600))$" "$rec" || fail "a transition resets since: $(cat "$rec")"
  progress "$d" $((NOW + 900)) 'state: working · source: run-step · validating (fixing) · step: review' 0 show r1 >/dev/null
  grep -q "^secs_validating=300$" "$rec" || fail "validating time accumulates: $(cat "$rec")"
  grep -q "^fix_rounds=1$" "$rec" || fail "entering fixing counts one round: $(cat "$rec")"
  progress "$d" $((NOW + 1000)) 'state: working · source: run-step · validating (fixing) · step: review · fix round: 3' 0 show r1 >/dev/null
  grep -q "^fix_rounds=3$" "$rec" || fail "the run's own round count wins when reported: $(cat "$rec")"
  progress "$d" $((NOW + 1300)) 'state: working · source: run-step · ci running · step: ci' 0 show r1 >/dev/null
  grep -q "^secs_fixing=400$" "$rec" || fail "fixing time accumulates: $(cat "$rec")"
  progress "$d" $((NOW + 1400)) 'state: working · source: run-step · ci running · step: ci' 0 show r1 >/dev/null
  grep -q "^secs_ci=100$" "$rec" || fail "ci time accumulates: $(cat "$rec")"
  grep -q "^phase=ci$" "$rec" || fail "the record carries the current phase: $(cat "$rec")"
  pass "the observation record seeds from the spawn instant and charges each interval to the phase seen at its start"
}

test_unknown_observation_keeps_the_phase_clock() {
  local d rec out
  d=$(make_case unknown-blip)
  write_task "$d" ub ship no-mistakes "spawn_gen=s$((NOW - 3000)).1.1"
  progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show ub >/dev/null
  rec="$d/state/.progress-ub"
  out=$(progress "$d" $((NOW + 10)) 'state: unknown · source: none · current state not read' 0 show ub)
  [ "$(phase_of "$out")" = unknown ] || fail "an unreadable state displays unknown: $out"
  assert_contains "$out" "guess: unknown" "an unreadable state carries no estimate"
  grep -q "^phase=implementing$" "$rec" || fail "an unknown observation must not switch the record's phase: $(cat "$rec")"
  grep -q "^since=$((NOW - 3000))$" "$rec" || fail "an unknown observation must not reset since: $(cat "$rec")"
  grep -q "^secs_other=10$" "$rec" || fail "the unknown interval is charged to other: $(cat "$rec")"
  out=$(progress "$d" $((NOW + 70)) 'state: working · source: pane · busy' 0 show ub)
  [ "$(phase_of "$out")" = implementing ] || fail "the real phase returns: $out"
  assert_contains "$out" "elapsed: 51 min" "the clock continues from the original since across the blip"
  # A blip inside fixing must not count a second round.
  progress "$d" $((NOW + 100)) 'state: working · source: run-step · validating (fixing) · step: review' 0 show ub >/dev/null
  progress "$d" $((NOW + 130)) 'state: unknown · source: pane · harness state unavailable' 0 show ub >/dev/null
  progress "$d" $((NOW + 160)) 'state: working · source: run-step · validating (fixing) · step: review' 0 show ub >/dev/null
  grep -q "^fix_rounds=1$" "$rec" || fail "fixing -> unknown -> fixing must stay one round: $(cat "$rec")"
  pass "an unreadable observation is displayed as unknown but never resets the phase clock or inflates fix rounds"
}

test_stale_record_of_an_older_incarnation_is_discarded() {
  local d rec out
  d=$(make_case reincarnation)
  write_task "$d" ri ship no-mistakes "spawn_gen=s$NOW.7.7"
  rec="$d/state/.progress-ri"
  printf 'v=1\nspawn_gen=s%s.1.1\nobserved=%s\nphase=implementing\nstep=\nsince=%s\nfix_rounds=2\nsecs_implementing=86400\n' \
    $((NOW - 90000)) $((NOW - 3600)) $((NOW - 90000)) > "$rec"
  out=$(progress "$d" $((NOW + 600)) 'state: working · source: pane · busy' 0 show ri)
  assert_contains "$out" "elapsed: 10 min" "a re-dispatched id starts its clock at its own spawn instant"
  grep -q "^spawn_gen=s$NOW.7.7$" "$rec" || fail "the record is bound to the current incarnation: $(cat "$rec")"
  grep -q "^secs_implementing=600$" "$rec" || fail "the older incarnation's accumulators are discarded: $(cat "$rec")"
  grep -q "^fix_rounds=0$" "$rec" || fail "the older incarnation's rounds are discarded: $(cat "$rec")"
  printf 'v=1\nobserved=%s\nphase=ci\nstep=ci\nsince=%s\nfix_rounds=4\nsecs_implementing=86400\n' \
    $((NOW - 3600)) $((NOW - 90000)) > "$rec"
  out=$(progress "$d" $((NOW + 1200)) 'state: working · source: pane · busy' 0 show ri)
  assert_contains "$out" "elapsed: 20 min" "a record without a spawn_gen while the meta has one is discarded"
  grep -q "^secs_implementing=1200$" "$rec" || fail "the unbound record's accumulators are discarded: $(cat "$rec")"
  pass "a record left by an older incarnation of the same id is discarded and the task reseeds from its own spawn instant"
}

test_read_during_teardown_leaves_no_record() {
  local d
  d=$(make_case teardown-race)
  write_task "$d" tr1 ship no-mistakes
  FM_FAKE_CREW_STATE_RM="$d/state/tr1.meta" progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show tr1 >/dev/null \
    || fail "a show whose task vanished underneath it still succeeds"
  [ ! -e "$d/state/.progress-tr1" ] || fail "a snapshot read in flight while teardown retired the task must not recreate its record: $(cat "$d/state/.progress-tr1")"
  write_task "$d" tr2 ship no-mistakes
  FM_FAKE_CREW_STATE_RM="$d/state/tr2.meta" progress "$d" "$NOW" 'state: unknown · source: none · pane gone' 0 tick \
    || fail "a tick whose task vanished underneath it still succeeds"
  [ ! -e "$d/state/.progress-tr2" ] || fail "a tick in flight while teardown retired the task must not recreate its record: $(cat "$d/state/.progress-tr2")"
  pass "a read that was in flight while teardown retired the task leaves no observation record behind"
}

test_record_without_spawn_epoch_uses_mtime() {
  local d rec mtime
  d=$(make_case mtime)
  fm_write_meta "$d/state/m1.meta" "window=fm:fm-m1" "worktree=$d/wt" "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-m1"
  mtime=$(stat -c %Y "$d/state/m1.meta" 2>/dev/null || stat -f %m "$d/state/m1.meta")
  progress "$d" $((mtime + 60)) 'state: working · source: pane · busy' 0 show m1 >/dev/null
  rec="$d/state/.progress-m1"
  grep -q "^secs_implementing=60$" "$rec" || fail "a non-epoch spawn_gen falls back to the record mtime: $(cat "$rec")"
  pass "a spawn instant that cannot be parsed falls back to the record's mtime"
}

# ---------------------------------------------------------------------------
# (c) fallback bands

test_default_bands_by_sequence() {
  local d out
  d=$(make_case bands)
  write_task "$d" nm ship no-mistakes "spawn_gen=s$NOW.1.1"
  write_task "$d" dp ship direct-PR "spawn_gen=s$NOW.1.1"
  write_task "$d" lo ship local-only "spawn_gen=s$NOW.1.1"
  write_task "$d" sc scout scout "spawn_gen=s$NOW.1.1"
  out=$(progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show nm)
  assert_contains "$out" "guess: 35 to 130 min guess (default bands" "no-mistakes at spawn sums implementing, validating plus one fix round, and ci"
  assert_contains "$out" "label: · implementing · 35 to 130 min" "the label carries the phase and the range"
  out=$(progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show dp)
  assert_contains "$out" "guess: 15 to 75 min guess" "direct-PR sums implementing and ci only"
  out=$(progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show lo)
  assert_contains "$out" "guess: 10 to 60 min guess" "local-only is implementing only"
  out=$(progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show sc)
  assert_contains "$out" "guess: 10 to 60 min guess" "a scout is implementing only"
  out=$(progress "$d" "$NOW" 'state: working · source: run-step · validating (running) · step: test' 0 show nm)
  assert_contains "$out" "guess: 25 to 70 min guess" "validating sums the remaining block and ci"
  out=$(progress "$d" "$NOW" 'state: working · source: run-step · ci running · step: ci' 0 show nm)
  assert_contains "$out" "guess: 5 to 15 min guess" "ci is the last band"
  out=$(progress "$d" "$NOW" 'state: parked · source: run-step · parked at review (ask-user: authority decision)' 0 show nm)
  assert_contains "$out" "guess: no estimate while waiting on the captain" "waiting on the captain has no estimate"
  assert_contains "$out" "label: · waiting on captain" "the waiting label carries no number"
  pass "default bands sum over the phases still ahead for each delivery sequence"
}

test_running_long_past_the_band() {
  local d out
  d=$(make_case overrun)
  write_task "$d" ov ship no-mistakes "spawn_gen=s$((NOW - 4000)).1.1"
  out=$(progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show ov)
  assert_contains "$out" "guess: running long: past the 10 to 60 min guess for implementing, then 25 to 70 min more" "an overrun names the band it passed and what is still ahead"
  assert_contains "$out" "label: · implementing · running long" "the label says running long instead of a stale number"
  pass "a phase past its band reads as running long rather than a bare zero"
}

# ---------------------------------------------------------------------------
# (d) history and medians

test_history_medians_replace_bands_at_three_samples() {
  local d out i
  d=$(make_case history)
  write_task "$d" h1 ship no-mistakes "spawn_gen=s$NOW.1.1"
  for i in 1 2; do
    printf '{"v":1,"id":"old%s","kind":"ship","mode":"no-mistakes","finished":1,"secs":{"implementing":1800,"validating":600,"fixing":300,"ci":300,"waiting":0},"fix_rounds":1}\n' "$i" \
      >> "$d/data/phase-history.jsonl"
  done
  out=$(progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show h1)
  assert_contains "$out" "35 to 130 min guess (default bands, fewer than 3 finished tasks)" "two samples keep the default bands"
  printf '{"v":1,"id":"old3","kind":"ship","mode":"no-mistakes","finished":1,"secs":{"implementing":2400,"validating":900,"fixing":600,"ci":600,"waiting":0},"fix_rounds":2}\n' \
    >> "$d/data/phase-history.jsonl"
  printf '{"v":1,"id":"other","kind":"scout","mode":"scout","finished":1,"secs":{"implementing":36000,"validating":0,"fixing":0,"ci":0,"waiting":0},"fix_rounds":0}\n' \
    >> "$d/data/phase-history.jsonl"
  out=$(progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show h1)
  # medians: implementing 30 min, validating 10 min, fix round 5 min x 1 round, ci 5 min -> 50 -> "~50 min"
  assert_contains "$out" "guess: ~50 min guess (from 3 finished tasks)" "three matching samples switch every phase to its median and the count is the number of tasks, not a sum"
  assert_contains "$out" "label: · implementing · ~50 min" "the label carries the point guess with a ~"
  out=$(progress "$d" "$NOW" x 0 history)
  assert_contains "$out" "tasks         3 matching finished task(s)" "history reports the matching task count"
  assert_contains "$out" "implementing  median 30 min, 75th percentile 40 min, over 3 task(s)" "history reports the median, the 75th percentile, and the sample count"
  assert_contains "$out" "fix_rounds    median 1 round(s), 75th percentile 2, over 3 task(s)" "history reports the fix-round median"
  pass "history medians replace the default bands once three matching finished tasks exist, per kind and mode"
}

test_running_long_starts_past_the_75th_percentile() {
  local d out secs
  d=$(make_case p75)
  for secs in 1200 1800 1800 2400 3000; do
    printf '{"v":1,"id":"h%s","kind":"ship","mode":"no-mistakes","finished":1,"secs":{"implementing":%s,"validating":600,"fixing":300,"ci":300,"waiting":0},"fix_rounds":1}\n' "$secs" "$secs" \
      >> "$d/data/phase-history.jsonl"
  done
  # implementing: median 30 min, 75th percentile 40 min (nearest rank over five samples)
  write_task "$d" past-median ship no-mistakes "spawn_gen=s$((NOW - 2100)).1.1"
  out=$(progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show past-median)
  case "$out" in *"running long"*) fail "a task past the median but under the 75th percentile is not running long: $out" ;; esac
  assert_contains "$out" "guess: ~20 min guess (from 5 finished tasks)" "past the median the current phase contributes nothing and the rest still carries the point guess"
  write_task "$d" past-p75 ship no-mistakes "spawn_gen=s$((NOW - 2700)).1.1"
  out=$(progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show past-p75)
  assert_contains "$out" "guess: running long: past the 75th percentile of finished tasks for implementing (guess was ~30 min), then ~20 min more" "past the 75th percentile the task reads as running long"
  assert_contains "$out" "label: · implementing · running long" "the label says running long past the percentile"
  pass "with history, running long starts past the 75th percentile of matching samples rather than the median"
}

test_record_hook_appends_history_and_drops_record() {
  local d out line
  d=$(make_case record-hook)
  write_task "$d" done1 ship no-mistakes
  progress "$d" "$NOW" 'state: working · source: run-step · validating (running) · step: review' 0 show done1 >/dev/null
  out=$(progress "$d" $((NOW + 300)) x 0 record done1)
  assert_contains "$out" "progress: recorded done1 (ship, no-mistakes)" "record names the task, kind, and mode"
  [ ! -e "$d/state/.progress-done1" ] || fail "record must remove the observation record"
  line=$(cat "$d/data/phase-history.jsonl")
  printf '%s' "$line" | jq -e '.v == 1 and .id == "done1" and .kind == "ship" and .mode == "no-mistakes"
    and .secs.implementing == 1200 and .secs.validating == 300 and .fix_rounds == 0 and .finished == 1788400300' >/dev/null \
    || fail "history line is wrong: $line"
  write_task "$d" done2 ship no-mistakes
  progress "$d" "$NOW" 'state: working · source: pane · busy' 0 show done2 >/dev/null
  out=$(progress "$d" $((NOW + 300)) x 0 record done2 --discard)
  assert_contains "$out" "removed without recording history" "--discard drops the record silently"
  [ "$(wc -l < "$d/data/phase-history.jsonl" | tr -d ' ')" = 1 ] || fail "--discard must not append history"
  out=$(progress "$d" $((NOW + 300)) x 0 record nothing)
  assert_contains "$out" "no observation record" "a task never observed records nothing"
  pass "the teardown hook appends one history line and drops the record, and --discard drops only"
}

# ---------------------------------------------------------------------------
# (e) label refresh rule (Herdr through the version 2 presentation journal)

write_v2_journal() {  # <case> <id> <base-label>
  local d=$1 id=$2 base=$3
  {
    printf 'version=2\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$TOKEN"
    printf 'home=%s\n' "$d"
    printf 'session=fmtest\nworkspace_id=w2\ntab_id=w2:t2\npane_id=w2:p2\n'
    printf 'parent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=%s\ntask_label=fm-%s\n' "$base" "$id"
  } > "$d/state/$id.herdr-presentation"
}

rename_count() {  # <case>
  grep -c '^workspace rename ' "$1/herdr.log" 2>/dev/null || true
}

test_label_refresh_on_change_only() {
  local d base
  d=$(make_case label)
  base="└ lab1 · p:$TOKEN"
  write_task "$d" lab1 ship no-mistakes "backend=herdr" "herdr_session=fmtest" "herdr_workspace_id=w2" "herdr_tab_id=w2:t2" "herdr_pane_id=w2:p2" "spawn_gen=s$NOW.1.1"
  write_v2_journal "$d" lab1 "$base"
  printf '%s\n' "$base" > "$d/label"
  : > "$d/herdr.log"
  progress "$d" "$NOW" 'state: working · source: pane · busy' 0 tick
  [ "$(rename_count "$d")" = 1 ] || fail "the first tick must rename once: $(cat "$d/herdr.log")"
  [ "$(cat "$d/label")" = "└ lab1 · implementing · 35 to 130 min · p:$TOKEN" ] \
    || fail "the decorated label keeps the token last: $(cat "$d/label")"
  grep -q "^label= · implementing · 35 to 130 min$" "$d/state/.progress-lab1" || fail "the applied suffix is recorded"
  progress "$d" $((NOW + 60)) 'state: working · source: pane · busy' 0 tick
  [ "$(rename_count "$d")" = 1 ] || fail "an unchanged suffix must not rename again: $(cat "$d/herdr.log")"
  progress "$d" $((NOW + 240)) 'state: working · source: run-step · validating (running) · step: review' 0 tick
  [ "$(rename_count "$d")" = 2 ] || fail "a phase change renames once: $(cat "$d/herdr.log")"
  [ "$(cat "$d/label")" = "└ lab1 · validating · 25 to 70 min · p:$TOKEN" ] || fail "label after the phase change: $(cat "$d/label")"
  # The estimate ticking down inside a five-minute bucket is not a change.
  progress "$d" $((NOW + 300)) 'state: working · source: run-step · validating (running) · step: review' 0 tick
  [ "$(rename_count "$d")" = 2 ] || fail "a sub-bucket estimate change must not rename: $(cat "$d/herdr.log")"
  # Crossing a bucket boundary is a change, and still only one rename.
  progress "$d" $((NOW + 480)) 'state: working · source: run-step · validating (running) · step: review' 0 tick
  [ "$(rename_count "$d")" = 3 ] || fail "a bucket change renames exactly once: $(cat "$d/herdr.log")"
  [ "$(cat "$d/label")" = "└ lab1 · validating · 20 to 65 min · p:$TOKEN" ] || fail "label after the bucket change: $(cat "$d/label")"
  pass "the label is renamed only when the phase or the rounded estimate changes, at most once per tick"
}

test_label_refresh_skips_without_projection_or_on_tmux() {
  local d
  d=$(make_case label-skip)
  write_task "$d" flat ship no-mistakes "backend=herdr" "spawn_gen=s$NOW.1.1"
  write_task "$d" tm ship no-mistakes "spawn_gen=s$NOW.1.1"
  printf '└ x · p:%s\n' "$TOKEN" > "$d/label"
  : > "$d/herdr.log"
  progress "$d" "$NOW" 'state: working · source: pane · busy' 0 tick 2> "$d/err"
  [ ! -s "$d/herdr.log" ] || fail "a Herdr task without a version 2 journal must not touch Herdr: $(cat "$d/herdr.log")"
  [ ! -s "$d/err" ] || fail "skipping must be silent: $(cat "$d/err")"
  [ -f "$d/state/.progress-flat" ] && [ -f "$d/state/.progress-tm" ] || fail "phases are still observed for skipped labels"
  pass "no Herdr call is made for a flat Herdr task or a tmux task, silently"
}

test_label_refresh_failure_warns_once_per_reason() {
  local d base
  d=$(make_case label-fail)
  base="└ lab2 · p:$TOKEN"
  write_task "$d" lab2 ship no-mistakes "backend=herdr" "spawn_gen=s$NOW.1.1"
  write_v2_journal "$d" lab2 "$base"
  printf '%s\n' "$base" > "$d/label"
  : > "$d/herdr.log"
  # The same failure across two cadence windows warns exactly once.
  FM_FAKE_HERDR_RENAME_FAIL=1 progress "$d" "$NOW" 'state: working · source: pane · busy' 0 tick 2> "$d/err"
  grep -q "warning: herdr progress label for lab2: rename failed on workspace w2" "$d/err" || fail "a failed rename must warn: $(cat "$d/err")"
  [ "$(grep -c warning "$d/err")" = 1 ] || fail "one failure warns once: $(cat "$d/err")"
  [ "$(cat "$d/label")" = "$base" ] || fail "a failed rename leaves the label alone"
  grep -q "^label_attempt=$NOW$" "$d/state/.progress-lab2" || fail "the failed attempt is recorded"
  grep -q "^label_warned=rename-failed$" "$d/state/.progress-lab2" || fail "the warned reason is recorded: $(cat "$d/state/.progress-lab2")"
  grep -q '^worktree=' "$d/state/lab2.meta" || fail "task records stay untouched"
  : > "$d/herdr.log"
  FM_FAKE_HERDR_RENAME_FAIL=1 progress "$d" $((NOW + 30)) 'state: working · source: pane · busy' 0 tick 2> "$d/err"
  [ ! -s "$d/herdr.log" ] || fail "a failed rename must not retry inside the cadence: $(cat "$d/herdr.log")"
  [ ! -s "$d/err" ] || fail "no warning inside the cadence: $(cat "$d/err")"
  FM_FAKE_HERDR_RENAME_FAIL=1 progress "$d" $((NOW + 90)) 'state: working · source: pane · busy' 0 tick 2> "$d/err"
  [ "$(rename_count "$d")" = 1 ] || fail "the rename retries after the cadence: $(cat "$d/herdr.log")"
  [ ! -s "$d/err" ] || fail "the same persisting reason must not warn again: $(cat "$d/err")"
  # A changed reason warns again, once.
  FM_FAKE_HERDR_GET_FAIL=1 progress "$d" $((NOW + 180)) 'state: working · source: pane · busy' 0 tick 2> "$d/err"
  grep -q "warning: herdr progress label for lab2: could not read workspace w2" "$d/err" || fail "a changed reason warns again: $(cat "$d/err")"
  FM_FAKE_HERDR_GET_FAIL=1 progress "$d" $((NOW + 270)) 'state: working · source: pane · busy' 0 tick 2> "$d/err"
  [ ! -s "$d/err" ] || fail "an unreadable server keeps retrying silently: $(cat "$d/err")"
  # A success clears the warned reason, so a later new failure warns again.
  progress "$d" $((NOW + 360)) 'state: working · source: pane · busy' 0 tick 2> "$d/err"
  [ "$(cat "$d/label")" = "└ lab2 · implementing · 30 to 125 min · p:$TOKEN" ] || fail "the retry applies the label once the server answers: $(cat "$d/label")"
  [ ! -s "$d/err" ] || fail "a success is silent: $(cat "$d/err")"
  grep -q "^label_warned=$" "$d/state/.progress-lab2" || fail "a success clears the warned reason: $(cat "$d/state/.progress-lab2")"
  FM_FAKE_HERDR_RENAME_FAIL=1 progress "$d" $((NOW + 450)) 'state: working · source: run-step · validating (running) · step: review' 0 tick 2> "$d/err"
  grep -q "rename failed on workspace w2" "$d/err" || fail "a failure after a success warns again: $(cat "$d/err")"
  # A label changed by hand: one warning, no rename attempts, decoration
  # resumes once the base label is back.
  progress "$d" $((NOW + 540)) 'state: working · source: run-step · validating (running) · step: review' 0 tick 2>/dev/null
  printf 'my own name\n' > "$d/label"
  : > "$d/herdr.log"
  progress "$d" $((NOW + 640)) 'state: working · source: run-step · ci running · step: ci' 0 tick 2> "$d/err"
  [ "$(rename_count "$d")" = 0 ] || fail "a hand-changed label must not be renamed: $(cat "$d/herdr.log")"
  grep -q "leaving the hand-changed label alone until it returns" "$d/err" || fail "a hand-changed label warns once: $(cat "$d/err")"
  [ "$(grep -c warning "$d/err")" = 1 ] || fail "exactly one hand-changed warning: $(cat "$d/err")"
  : > "$d/herdr.log"
  progress "$d" $((NOW + 740)) 'state: working · source: run-step · ci running · step: ci' 0 tick 2> "$d/err"
  [ "$(rename_count "$d")" = 0 ] || fail "no later rename attempt while the label stays hand-changed: $(cat "$d/herdr.log")"
  grep -q '^workspace get ' "$d/herdr.log" || fail "the live label is still re-read on the cadence to notice a restoration"
  [ ! -s "$d/err" ] || fail "a persisting hand-changed label does not warn again: $(cat "$d/err")"
  [ "$(cat "$d/label")" = "my own name" ] || fail "the hand-changed label survives"
  printf '%s\n' "$base" > "$d/label"
  progress "$d" $((NOW + 840)) 'state: working · source: run-step · ci running · step: ci' 0 tick 2> "$d/err"
  [ "$(cat "$d/label")" = "└ lab2 · ci · 5 to 10 min · p:$TOKEN" ] || fail "decoration resumes once the base label returns: $(cat "$d/label")"
  pass "a failed rename warns once per distinct reason, retries on the cadence, and a hand-changed label is left alone until its base returns"
}

# ---------------------------------------------------------------------------
# (f) tick throttle

test_tick_reads_phase_once_per_cadence() {
  local d
  d=$(make_case throttle)
  write_task "$d" th1 ship no-mistakes "spawn_gen=s$NOW.1.1"
  write_task "$d" th2 ship no-mistakes "spawn_gen=s$NOW.1.1"
  : > "$d/crew.log"
  FM_FAKE_CREW_STATE_LOG="$d/crew.log" progress "$d" "$NOW" 'state: working · source: pane · busy' 0 tick
  FM_FAKE_CREW_STATE_LOG="$d/crew.log" progress "$d" $((NOW + 10)) 'state: working · source: pane · busy' 0 tick
  FM_FAKE_CREW_STATE_LOG="$d/crew.log" progress "$d" $((NOW + 59)) 'state: working · source: pane · busy' 0 tick
  [ "$(wc -l < "$d/crew.log" | tr -d ' ')" = 2 ] || fail "each task is read once inside the cadence: $(cat "$d/crew.log")"
  FM_FAKE_CREW_STATE_LOG="$d/crew.log" progress "$d" $((NOW + 60)) 'state: working · source: pane · busy' 0 tick
  [ "$(wc -l < "$d/crew.log" | tr -d ' ')" = 4 ] || fail "the cadence boundary re-reads every task: $(cat "$d/crew.log")"
  # A fleet-snapshot read (the `show` path) between two ticks advances the
  # record's accumulators but is not a tick, so it never postpones the re-read.
  FM_FAKE_CREW_STATE_LOG="$d/crew.log" progress "$d" $((NOW + 110)) 'state: working · source: pane · busy' 0 show th1 >/dev/null
  [ "$(wc -l < "$d/crew.log" | tr -d ' ')" = 5 ] || fail "show reads the task once: $(cat "$d/crew.log")"
  FM_FAKE_CREW_STATE_LOG="$d/crew.log" progress "$d" $((NOW + 120)) 'state: working · source: pane · busy' 0 tick
  [ "$(wc -l < "$d/crew.log" | tr -d ' ')" = 7 ] || fail "a snapshot read between ticks must not delay the cadence re-read: $(cat "$d/crew.log")"
  : > "$d/crew.log"
  FM_PROGRESS_REFRESH_SECS=0 FM_FAKE_CREW_STATE_LOG="$d/crew.log" progress "$d" $((NOW + 600)) 'state: working · source: pane · busy' 0 tick
  [ ! -s "$d/crew.log" ] || fail "FM_PROGRESS_REFRESH_SECS=0 disables the tick"
  pass "the tick re-reads each task's phase once per cadence window and can be disabled"
}

# The real watcher launches the tick as a detached single-flight child: the
# poll loop keeps beating while a slow current-state read is in flight, the
# record still appears, and a second cycle never doubles a running tick.
test_watcher_launches_tick_detached_with_single_flight() {
  local d pid beat1 beat2 i
  d=$(make_case watcher-tick)
  write_task "$d" wt1 ship no-mistakes "spawn_gen=s$NOW.1.1"
  : > "$d/crew.log"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_DATA_OVERRIDE="$d/data" \
    FM_CREW_STATE_BIN="$d/fakebin/fm-crew-state.sh" FM_CAPTAIN_HOLD_BIN="$d/fakebin/fm-captain-hold.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · busy' FM_FAKE_CREW_STATE_LOG="$d/crew.log" \
    FM_FAKE_CREW_STATE_SLEEP=3 FM_PROGRESS_REFRESH_SECS=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$d/watch.out" 2> "$d/watch.err" &
  pid=$!
  i=0
  while [ "$i" -lt 60 ] && [ ! -s "$d/crew.log" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$d/crew.log" ] || { kill "$pid" 2>/dev/null; fail "the watcher never launched the tick: $(cat "$d/watch.err")"; }
  beat1=$(stat -c %Y "$d/state/.last-watcher-beat" 2>/dev/null || stat -f %m "$d/state/.last-watcher-beat")
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "the watcher must stay alive while the tick child sleeps: $(cat "$d/watch.err")"
  beat2=$(stat -c %Y "$d/state/.last-watcher-beat" 2>/dev/null || stat -f %m "$d/state/.last-watcher-beat")
  [ "$beat2" -gt "$beat1" ] || { kill "$pid" 2>/dev/null; fail "the poll loop must keep beating while a slow read is in flight"; }
  [ "$(wc -l < "$d/crew.log" | tr -d ' ')" = 1 ] || { kill "$pid" 2>/dev/null; fail "a running tick is never doubled by later cycles: $(cat "$d/crew.log")"; }
  i=0
  while [ "$i" -lt 80 ] && [ ! -f "$d/state/.progress-wt1" ]; do sleep 0.1; i=$((i + 1)); done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  [ -f "$d/state/.progress-wt1" ] || fail "the detached tick must still publish the observation record: $(cat "$d/watch.err")"
  grep -q "^phase=implementing$" "$d/state/.progress-wt1" || fail "the detached tick records the phase: $(cat "$d/state/.progress-wt1")"
  pass "the watcher launches the progress tick detached with a single-flight guard and keeps polling while it runs"
}

# watch_start <case>: run the real watcher over the case with a quick poll and
# an instant fake current state; sets WATCH_PID. The watcher's own triage may
# read that state too and its summary refresh advances the observation record
# through the fleet snapshot, so the tick's evidence is the record's tick_at=,
# which only the tick writes.
WATCH_PID=
watch_start() {
  local d=$1
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_DATA_OVERRIDE="$d/data" \
    FM_CREW_STATE_BIN="$d/fakebin/fm-crew-state.sh" FM_CAPTAIN_HOLD_BIN="$d/fakebin/fm-captain-hold.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · busy' FM_PROGRESS_REFRESH_SECS=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$d/watch.out" 2> "$d/watch.err" &
  WATCH_PID=$!
}

beat_of() {  # <case> -> the beacon's mtime
  stat -c %Y "$1/state/.last-watcher-beat" 2>/dev/null || stat -f %m "$1/state/.last-watcher-beat"
}

wait_for() {  # <tenths> <command...>: poll a command for up to that many tenths
  local i=0 limit=$1
  shift
  while [ "$i" -lt "$limit" ] && ! "$@"; do sleep 0.1; i=$((i + 1)); done
  "$@"
}

ticked() {  # <record>: the tick has re-read this task at least once
  grep -q '^tick_at=[1-9]' "$1" 2>/dev/null
}

marker_of() {  # <case> -> the tick marker's pid
  cat "$1/state/.progress-tick.pid" 2>/dev/null
}

marker_moved_from() {  # <case> <pid>: the watcher has rewritten the marker
  [ "$(marker_of "$1")" != "$2" ]
}

gone() {  # <pid>: the process no longer exists
  ! kill -0 "$1" 2>/dev/null
}

# tick_start <case>: run one real `fm-progress.sh tick` in the background whose
# current-state read sleeps, so it stays alive as a genuine tick child; sets
# TICK_PID.
TICK_PID=
tick_start() {
  local d=$1
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_DATA_OVERRIDE="$d/data" \
    FM_CREW_STATE_BIN="$d/fakebin/fm-crew-state.sh" FM_CAPTAIN_HOLD_BIN="$d/fakebin/fm-captain-hold.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · busy' FM_FAKE_CREW_STATE_SLEEP=6 \
    FM_PROGRESS_REFRESH_SECS=1 "$PROGRESS" tick >/dev/null 2>&1 &
  TICK_PID=$!
}

# The single flight also holds across processes through state/.progress-tick.pid:
# a marker naming a live real tick child suppresses the launch while the
# watcher keeps polling, and once that child exits the marker is reclaimed.
test_watcher_tick_marker_of_live_tick_child_suppresses_launch() {
  local d holder beat1 beat2 marker
  d=$(make_case watcher-marker-tick)
  write_task "$d" wm1 ship no-mistakes "spawn_gen=s$NOW.1.1"
  tick_start "$d"
  holder=$TICK_PID
  printf '%s\n' "$holder" > "$d/state/.progress-tick.pid"
  watch_start "$d"
  wait_for 60 test -f "$d/state/.last-watcher-beat" || { kill "$WATCH_PID" "$holder" 2>/dev/null; fail "the watcher never started polling: $(cat "$d/watch.err")"; }
  beat1=$(beat_of "$d")
  sleep 2.5
  beat2=$(beat_of "$d")
  [ "$beat2" -gt "$beat1" ] || { kill "$WATCH_PID" "$holder" 2>/dev/null; fail "the watcher must keep polling while a tick child holds the marker"; }
  [ "$(marker_of "$d")" = "$holder" ] || { kill "$WATCH_PID" "$holder" 2>/dev/null; fail "a marker naming a live tick child must suppress the launch: marker $(marker_of "$d"), tick $holder"; }
  wait "$holder" 2>/dev/null || true
  wait_for 80 marker_moved_from "$d" "$holder" || { kill "$WATCH_PID" 2>/dev/null; fail "once the tick child exits the marker is reclaimed and the tick launches: $(cat "$d/watch.err")"; }
  kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null || true
  marker=$(marker_of "$d")
  case "$marker" in ''|*[!0-9]*) fail "the reclaimed marker must name the new tick child: '$marker'" ;; esac
  pass "a marker naming a live tick child suppresses the launch and is reclaimed once that child exits"
}

# A recycled pid now owned by an unrelated process is not a running tick: the
# launch goes ahead while that process is still alive.
test_watcher_tick_marker_of_unrelated_process_is_reclaimed() {
  local d holder marker
  d=$(make_case watcher-marker-unrelated)
  write_task "$d" wm2 ship no-mistakes "spawn_gen=s$NOW.1.1"
  sleep 60 &
  holder=$!
  printf '%s\n' "$holder" > "$d/state/.progress-tick.pid"
  watch_start "$d"
  wait_for 80 ticked "$d/state/.progress-wm2" || { kill "$WATCH_PID" "$holder" 2>/dev/null; fail "a marker naming an unrelated live process must not suppress the launch: $(cat "$d/watch.err")"; }
  kill -0 "$holder" 2>/dev/null || { kill "$WATCH_PID" 2>/dev/null; fail "the unrelated process must still be alive for this case to mean anything"; }
  kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null || true
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  marker=$(marker_of "$d")
  case "$marker" in ''|*[!0-9]*) fail "the reclaimed marker must name the new tick child: '$marker'" ;; esac
  [ "$marker" != "$holder" ] || fail "the reclaimed marker must name the new tick child, not the unrelated process"
  pass "a marker naming a live unrelated process is reclaimed and the tick launches"
}

# A marker older than FM_PROGRESS_TICK_MAX_SECS is stale even while its tick
# child is alive: it is reclaimed with one warning on the watcher's stderr.
test_watcher_tick_marker_older_than_max_is_reclaimed_with_a_warning() {
  local d holder marker
  d=$(make_case watcher-marker-old)
  write_task "$d" wm3 ship no-mistakes "spawn_gen=s$NOW.1.1"
  tick_start "$d"
  holder=$TICK_PID
  printf '%s\n' "$holder" > "$d/state/.progress-tick.pid"
  sleep 2.5
  FM_PROGRESS_TICK_MAX_SECS=1 watch_start "$d"
  wait_for 80 marker_moved_from "$d" "$holder" || { kill "$WATCH_PID" "$holder" 2>/dev/null; fail "a marker past the age bound must be reclaimed while its tick child lives: $(cat "$d/watch.err")"; }
  kill -0 "$holder" 2>/dev/null || { kill "$WATCH_PID" 2>/dev/null; fail "the overlong tick child must still be alive for this case to mean anything"; }
  kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  marker=$(marker_of "$d")
  case "$marker" in ''|*[!0-9]*) fail "the reclaimed marker must name the new tick child: '$marker'" ;; esac
  [ "$(grep -c "reclaiming the marker" "$d/watch.err")" = 1 ] || fail "the age bound expiring warns exactly once: $(cat "$d/watch.err")"
  pass "a marker older than FM_PROGRESS_TICK_MAX_SECS is reclaimed with one warning even while its tick child lives"
}

# A watcher that starts over a marker left by a dead tick child (a restart
# after a crash) reclaims it at once and launches.
test_watcher_tick_reclaims_marker_of_dead_process() {
  local d dead marker
  d=$(make_case watcher-marker-dead)
  write_task "$d" wm2 ship no-mistakes "spawn_gen=s$NOW.1.1"
  true &
  dead=$!
  wait "$dead" 2>/dev/null || true
  printf '%s\n' "$dead" > "$d/state/.progress-tick.pid"
  watch_start "$d"
  wait_for 80 ticked "$d/state/.progress-wm2" || { kill "$WATCH_PID" 2>/dev/null; fail "a marker naming a dead process must be reclaimed and the tick launched: $(cat "$d/watch.err")"; }
  kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null || true
  marker=$(cat "$d/state/.progress-tick.pid")
  case "$marker" in ''|*[!0-9]*) fail "the reclaimed marker must name the new tick child: '$marker'" ;; esac
  [ "$marker" != "$dead" ] || fail "the reclaimed marker must name the new tick child, not the dead pid"
  pass "a marker naming a dead process is reclaimed and the tick launches"
}

# The age bound also governs the child the watcher launched itself: a tick
# wedged past FM_PROGRESS_TICK_MAX_SECS is terminated with one warning and a
# fresh tick launched, without the marker being pre-written by the test.
test_watcher_own_wedged_tick_child_past_max_is_terminated_and_relaunched() {
  local d first
  d=$(make_case watcher-own-wedged)
  write_task "$d" wm4 ship no-mistakes "spawn_gen=s$NOW.1.1"
  FM_FAKE_CREW_STATE_SLEEP=30 FM_PROGRESS_TICK_MAX_SECS=1 watch_start "$d"
  wait_for 80 test -s "$d/state/.progress-tick.pid" || { kill "$WATCH_PID" 2>/dev/null; fail "the watcher never launched the tick: $(cat "$d/watch.err")"; }
  first=$(marker_of "$d")
  wait_for 80 marker_moved_from "$d" "$first" || { kill "$WATCH_PID" 2>/dev/null; fail "an own tick child past the age bound must be reclaimed and a fresh tick launched: $(cat "$d/watch.err")"; }
  wait_for 30 gone "$first" || { kill "$WATCH_PID" "$first" 2>/dev/null; fail "the wedged own child must have been terminated: $(ps -o pid=,args= -p "$first")"; }
  [ "$(marker_of "$d")" != "$first" ] || { kill "$WATCH_PID" 2>/dev/null; fail "the marker must name the fresh tick child"; }
  kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null || true
  grep -q "progress tick $first launched by this watcher has run longer than 1s" "$d/watch.err" \
    || fail "terminating an own wedged child warns on the watcher's stderr: $(cat "$d/watch.err")"
  pass "an own tick child wedged past FM_PROGRESS_TICK_MAX_SECS is terminated with a warning and a fresh tick launched"
}

# Control: a slow but young own child is left alone, without a warning.
test_watcher_own_young_tick_child_is_left_alone() {
  local d first
  d=$(make_case watcher-own-young)
  write_task "$d" wm5 ship no-mistakes "spawn_gen=s$NOW.1.1"
  FM_FAKE_CREW_STATE_SLEEP=30 FM_PROGRESS_TICK_MAX_SECS=600 watch_start "$d"
  wait_for 80 test -s "$d/state/.progress-tick.pid" || { kill "$WATCH_PID" 2>/dev/null; fail "the watcher never launched the tick: $(cat "$d/watch.err")"; }
  first=$(marker_of "$d")
  sleep 3
  [ "$(marker_of "$d")" = "$first" ] || { kill "$WATCH_PID" 2>/dev/null; fail "a young own tick child must not be replaced: marker $(marker_of "$d"), child $first"; }
  kill -0 "$first" 2>/dev/null || { kill "$WATCH_PID" 2>/dev/null; fail "a young own tick child must be left running"; }
  kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null || true
  kill "$first" 2>/dev/null || true
  ! grep -q "launched by this watcher" "$d/watch.err" || fail "a young own tick child never warns: $(cat "$d/watch.err")"
  pass "a young own tick child is left alone without a warning"
}

# ---------------------------------------------------------------------------
# (g) label grammar in the Herdr adapter

test_label_grammar() {
  local out
  out=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    base=$(fm_backend_herdr_projection_workspace_label fm-task-1 "$1")
    dec=$(fm_backend_herdr_projection_progress_label "$base" " · validating · ~25 min")
    printf "%s\n%s\n%s\n%s\n" "$base" "$dec" \
      "$(fm_backend_herdr_projection_label_base "$dec")" \
      "$(fm_backend_herdr_projection_progress_label "$base" " · bad p:x")"
  ' "$ROOT" "$TOKEN")
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = "└ task-1 · p:$TOKEN" ] || fail "base label: $out"
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = "└ task-1 · validating · ~25 min · p:$TOKEN" ] || fail "decorated label keeps the token last: $out"
  [ "$(printf '%s\n' "$out" | sed -n 3p)" = "└ task-1 · p:$TOKEN" ] || fail "the base is recovered from a decorated label: $out"
  [ "$(printf '%s\n' "$out" | sed -n 4p)" = "└ task-1 · p:$TOKEN" ] || fail "a suffix carrying a token marker is refused: $out"
  printf '%s\n' "$(printf '%s\n' "$out" | sed -n 2p)" | grep -Eq '^└ .+ · p:[A-Za-z0-9_-]{22}$' \
    || fail "a decorated label must still match the projected child grammar"
  pass "the progress segment sits before the token and strips back to the journaled base"
}

test_phase_matrix
test_phase_pr_recorded_without_run_is_ci
test_phase_open_decision_and_hold
test_secondmate_and_remote_are_skipped
test_record_accumulates_phases
test_stale_record_of_an_older_incarnation_is_discarded
test_read_during_teardown_leaves_no_record
test_record_without_spawn_epoch_uses_mtime
test_default_bands_by_sequence
test_running_long_past_the_band
test_history_medians_replace_bands_at_three_samples
test_record_hook_appends_history_and_drops_record
test_label_refresh_on_change_only
test_label_refresh_skips_without_projection_or_on_tmux
test_label_refresh_failure_warns_once_per_reason
test_tick_reads_phase_once_per_cadence
test_watcher_launches_tick_detached_with_single_flight
test_watcher_tick_marker_of_live_tick_child_suppresses_launch
test_watcher_tick_marker_of_unrelated_process_is_reclaimed
test_watcher_tick_marker_older_than_max_is_reclaimed_with_a_warning
test_watcher_tick_reclaims_marker_of_dead_process
test_watcher_own_wedged_tick_child_past_max_is_terminated_and_relaunched
test_watcher_own_young_tick_child_is_left_alone
test_label_grammar
test_unknown_observation_keeps_the_phase_clock
test_running_long_starts_past_the_75th_percentile

echo "all fm-progress tests passed"
