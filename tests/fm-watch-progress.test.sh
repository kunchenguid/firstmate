#!/usr/bin/env bash
# tests/fm-watch-progress.test.sh - supervision's wedge decision once it is made
# from a MEASUREMENT of the worker's process subtree (bin/fm-progress-lib.sh)
# instead of from the absence of rendered change.
#
# Both directions of the 2026-08-20 inversion are pinned here:
#
#   (a) A healthy worker that renders nothing - a long model turn, a build, a
#       `sleep`-and-poll CI wait - is NOT wedge-escalated, because its subtree is
#       measurably accumulating CPU. This is the false positive that escalated
#       four times on one healthy pane, training the reader to stop inspecting.
#   (b) A worker stopped mid-turn, sitting at an empty prompt while its harness
#       still reports a turn in flight, IS surfaced, because its subtree has done
#       nothing measurable. This is the fleet-wide stall the rendered-tail
#       detector could not see at all: a busy pane was exempt from stale
#       detection entirely until FM_BUSY_TURN_MAX_SECS, an hour later.
#   (c) A backend that cannot report a pane pid measures nothing and behaves
#       exactly as it did before, in both directions - no new alarm, no new
#       silence - and says so in the wake it raises.
#   (d) The wedge timer and the progress baseline start in the SAME poll, so a
#       host slow enough to spend a whole wedge window inside one poll cycle
#       cannot escalate a working pane on the absence of a reading. This is (a)
#       again with the measurement never taken rather than ignored, and it is the
#       hole that made this file intermittent on contended runners.
#
# The pane surface is the same hermetic tmux fake the rest of the watcher tests
# use, because the rendered tail is NOT the subject here. The subject is the
# measurement, so the processes are real and they run on a real pty: the pid
# resolution under test reads the tty's foreground process group (pgid == tpgid),
# which only a real controlling terminal can produce. A CPU burner is the honest
# fixture for (a) - it renders nothing at all, so every rendered-tail proxy calls
# it idle while it is provably working - and `sleep` is the honest fixture for
# (b) for the same reason in reverse.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"

command -v script >/dev/null 2>&1 || { echo "skip: script(1) not found, so no pty fixture is available"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-watch-progress-tests)

# Fixture registration goes through a FILE, never an array.
#
# Every fixture here is started as `tty=$(pty_run ...)`, and a command
# substitution forks a subshell: an array append inside pty_run dies with that
# subshell and never reaches this shell, so a teardown reading in-process state
# reads an empty list and kills nothing. That is not a hypothetical - it is why
# this suite leaked every fixture it ever started. tests/lib.sh hit the same wall
# with fm_test_tmproot and solved it the same way; see its comment above
# FM_TEST_CLEANUP_REGISTRY.
FIXTURE_REGISTRY="$TMP_ROOT/.fixtures"
: > "$FIXTURE_REGISTRY"

# A fixture here is a CPU burner, so leaking one is not litter - it pegs a core
# for everything that runs afterwards, and the thing that runs afterwards is a
# suite whose whole subject is whether a pane is accumulating CPU. A leaked
# burner therefore corrupts exactly the measurement this file exists to pin, and
# it does it to every later test on the machine too. Two independent guarantees,
# because they fail for different reasons:
#
#   1. Teardown kills the pty's whole FOREGROUND PROCESS GROUP, not the `script`
#      wrapper's pid. `script` runs the fixture inside a pty in its own session,
#      so killing the wrapper leaves the spinning bash behind with nothing left
#      to reap it. The pgid == tpgid anchor used here is the same kernel fact
#      bin/fm-backend.sh resolves a pane's pids from, so teardown reaches
#      precisely the processes the subject measures.
#   2. Every burner carries its own deadline and exits unaided. A run killed hard
#      enough to skip its traps - a CI step timeout, a SIGKILL, a developer's
#      ctrl-C at the wrong moment - still cannot leave a core pegged.
#
# BURNER is that bounded spin: hot enough to be measurable, self-limiting, and it
# forks NOTHING. A fixture that spawned children would change its own subtree
# composition and hand the probe its second positive signal, which is not the one
# case (a) pins - the CPU rate is.
FIXTURE_MAX_SECS=${FIXTURE_MAX_SECS:-120}
# shellcheck disable=SC2016 # deliberately unexpanded: $SECONDS and $end are the
# fixture bash's own, evaluated inside the pty, not this shell's.
BURNER='end=$((SECONDS + '"$FIXTURE_MAX_SECS"')); while [ "$SECONDS" -lt "$end" ]; do :; done'

# cleanup_fixtures: end every pty fixture started so far, completely. Called at
# the END OF EVERY CASE as well as on exit, so no case ever runs while the
# previous case's burner is still pegging a core.
cleanup_fixtures() {
  local p tty victim
  [ -f "$FIXTURE_REGISTRY" ] || return 0
  while IFS='	' read -r p tty; do
    if [ -n "${tty:-}" ]; then
      for victim in $(LC_ALL=C ps -t "$tty" -o pid= 2>/dev/null); do
        [ -n "$victim" ] || continue
        kill -9 "$victim" 2>/dev/null || true
      done
    fi
    [ -n "${p:-}" ] || continue
    kill -9 "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done < "$FIXTURE_REGISTRY"
  : > "$FIXTURE_REGISTRY"
}

# Chained, never replaced: tests/lib.sh arms fm_test_cleanup on these same
# signals to remove the registered fixture directories. A bare `trap ... EXIT`
# here silently drops that, which is why this suite used to leave its fixture
# roots behind as well as its processes.
trap 'cleanup_fixtures; fm_test_cleanup' EXIT
trap 'cleanup_fixtures; fm_test_cleanup; exit 130' INT
trap 'cleanup_fixtures; fm_test_cleanup; exit 143' TERM

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# wait_for_log <file> <pattern> <pid> [limit-ticks] - wait until <pattern> lands
# in <file>, failing if <pid> exits first. The watcher does bounded startup work
# before its first stale scan, so a fixed sleep can reap a run before the poll
# under test ever happened - and then every "nothing was raised" assertion
# passes for the wrong reason.
wait_for_log() {
  local file=$1 pattern=$2 pid=$3 limit=${4:-300} i=0
  while [ "$i" -lt "$limit" ]; do
    grep -q "$pattern" "$file" 2>/dev/null && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# pty_foreground_pids <tty> - the pids in <tty>'s foreground process group.
# Returns 1 when the pty has none, which is what a dead or never-started fixture
# looks like. Deliberately the same pgid == tpgid kernel anchor the subject
# resolves a pane's pids from, so "this fixture is measurable" means measurable
# BY THE THING UNDER TEST, not merely alive by some other definition.
pty_foreground_pids() {  # <tty>
  local tty=$1 out
  [ -n "$tty" ] || return 1
  out=$(LC_ALL=C ps -t "$tty" -o pid=,pgid=,tpgid= 2>/dev/null) || return 1
  out=$(printf '%s\n' "$out" | awk '$2 == $3 && $1 != "" { print $1 }')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# pty_run <name> <command> - run <command> on its own pty and echo that pty's
# device path. The command reports its own tty from inside, which is the only
# way to learn the device `script` allocated.
#
# <command> is delivered as a FILE, never as an interpolated command string.
# macOS `script` takes the fixture as argv and passes it through untouched, but
# Linux `script -c` takes a STRING and hands it to a shell that re-parses it, so
# a fixture containing a quote or a `$` means two different things on the two
# platforms - and the platform that mangles it is the one CI runs. That is not
# hypothetical: a fixture whose loop guard re-split there became `[ 0 -lt ]`,
# which is false, so the burner exited the instant it started and the pane the
# suite believed was working had no foreground process group at all. A file has
# no second parse on either platform.
pty_run() {
  local name=$1 command=$2 ttyfile fixture pid tty i=0
  ttyfile="$TMP_ROOT/$name.tty"
  fixture="$TMP_ROOT/$name.fixture.sh"
  rm -f "$ttyfile"
  cat > "$fixture" <<EOF
tty > '$ttyfile'
$command
EOF
  if [ "$(uname)" = Darwin ]; then
    script -q /dev/null bash "$fixture" >/dev/null 2>&1 &
  else
    script -q -c "bash $fixture" /dev/null >/dev/null 2>&1 &
  fi
  pid=$!
  # Registered BEFORE the tty is known, so a fixture that never reports one is
  # still reachable by pid; the tty is appended as a second record the moment it
  # resolves, and teardown tolerates either shape.
  printf '%s\t\n' "$pid" >> "$FIXTURE_REGISTRY"
  while [ "$i" -lt 150 ]; do
    if [ -s "$ttyfile" ]; then
      tty=$(tr -d '[:space:]' < "$ttyfile")
      printf '%s\t%s\n' "$pid" "$tty" >> "$FIXTURE_REGISTRY"
      # Measurable now AND still measurable a moment later. One reading cannot
      # tell a running fixture from one that is about to exit, and a fixture that
      # dies on the second reading is exactly the failure this file must never
      # again report as "the watcher escalated a working pane": a dead fixture is
      # a broken test, not a broken detector, and it has to say so in those words.
      pty_foreground_pids "$tty" >/dev/null || return 1
      sleep 0.5
      pty_foreground_pids "$tty" >/dev/null || return 1
      printf '%s' "$tty"
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# make_case <name> <id> <window> <tty> <status-line> - a task whose pane the
# watcher already considers stale: hash primed, status already seen, so the case
# under test is the stale DECISION and nothing upstream of it. The fake tmux
# answers the pane surface AND the pane_tty the pid resolution reads, so the
# measurement lands on the real processes running on that pty.
make_case() {
  local name=$1 id=$2 window=$3 tty=$4 status=$5 dir state fakebin key hash
  dir="$TMP_ROOT/$name"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$state" "$fakebin"
  make_fake_crew_state "$fakebin" >/dev/null
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  list-windows) printf '%s\n' "${window#*:}"; exit 0 ;;
  capture-pane) printf 'no output at all\n'; exit 0 ;;
  display-message)
    case "\$*" in
      *pane_tty*) printf '%s\n' "\${FM_TEST_PANE_TTY:-$tty}"; exit \${FM_TEST_PANE_TTY_FAIL:-0} ;;
      *pane_id*) printf '%%1\n'; exit 0 ;;
      *pane_current_command*) printf 'bash\n'; exit 0 ;;
    esac
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$window" > "$state/$id.meta"
  printf '%s\n' "$status" > "$state/$id.status"
  prime_status_seen "$state" "$state/$id.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  hash=$(hash_text 'no output at all
')
  printf '%s' "$hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

# run_watch <state> <fakebin> <out> [env...] - the real watcher, tight cadences,
# with only the progress spans shortened so a test does not wait out production
# minutes. The decision under test is the shipped one.
run_watch() {
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_PROGRESS_MIN_SPAN_SECS=2 FM_PROGRESS_STALL_SPAN_SECS=2 \
    env "$@" "$WATCH" > "$out" &
}

# --- (a) the false positive: a silent pane that is measurably working --------

test_measured_progress_declines_the_wedge_escalation() {
  local dir state fakebin out window key tty pid
  window="test:fm-burner"
  tty=$(pty_run burner "$BURNER") || fail "could not start the working pty fixture"
  dir=$(make_case working-pane burner "$window" "$tty" 'working: running the suite')
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # An actively-running pipeline on a static pane: absorbed, wedge timer started.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · suite running'
  # A threshold this short escalates on the very next poll under the old
  # rendered-tail rule - the pane never changes a byte for the whole test.
  run_watch "$state" "$fakebin" "$out" FM_STALE_ESCALATE_SECS=3
  pid=$!
  # Every poll past the escalation threshold is another chance to get this
  # wrong, so wait for several of them rather than for the first.
  wait_for_log "$state/.watch-triage.log" 'measured progress' "$pid" 400 \
    || { reap "$pid"; fail "the watcher escalated a pane that was measurably working: $(cat "$out")"; }
  sleep 5
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "the watcher escalated a pane that was measurably working: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -s "$out" ] || fail "a measurably working pane printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "a measurably working pane enqueued a wedge wake"
  [ -s "$state/.progress-$key" ] || fail "no measurement was taken, so the absorb proves nothing"
  grep -q 'cpu +' "$state/.watch-triage.log" \
    || fail "the absorb did not record the reading it was made from: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  cleanup_fixtures
  pass "a silent pane whose process subtree is accumulating CPU is not wedge-escalated"
}

# The wedge timer and the progress baseline have to be taken in the same poll.
# When only the timer started, the first probe on the next poll had no baseline to
# compare against, so the earliest verdict that could exist was "unknown
# baseline-recorded" - the absence of a measurement - and a pane whose next poll
# landed after the timer had already expired was escalated on a reading nobody
# took. At FM_POLL=15 inside a 240s timer that gap never decided anything, which
# is why it shipped; on a contended runner with a tight cadence it decided
# everything, and this file went intermittent.
#
# So the cadence here is deliberately SLOWER than the whole wedge window: one poll
# cycle outlives the timer, which is exactly what contention does to case (a).
# That makes the previously-racy window the default condition of this test instead
# of something a slow host has to stumble into, and the verdict still has to come
# from a real reading - the same 'cpu +' evidence (a) demands - not from silence.
test_a_poll_slower_than_the_wedge_window_measures_before_it_escalates() {
  local dir state fakebin out window key tty pid
  window="test:fm-slowpoll"
  tty=$(pty_run slowpoll "$BURNER") || fail "could not start the working pty fixture"
  dir=$(make_case slow-poll slowpoll "$window" "$tty" 'working: running the suite')
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  export FM_FAKE_CREW_STATE='state: working · source: run-step · suite running'
  # 4s between polls against a 3s wedge window: the timer is always already
  # expired by the time the poll after it runs.
  run_watch "$state" "$fakebin" "$out" FM_STALE_ESCALATE_SECS=3 FM_POLL=4
  pid=$!
  wait_for_log "$state/.watch-triage.log" 'measured progress' "$pid" 400 \
    || { reap "$pid"; fail "a poll cycle longer than the wedge window escalated a working pane: $(cat "$out")"; }
  # One more full poll past the absorb, so this is not a single lucky cycle.
  sleep 6
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "a poll cycle longer than the wedge window escalated a working pane: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -s "$out" ] || fail "a measurably working pane printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "a measurably working pane enqueued a wedge wake"
  [ -s "$state/.progress-$key" ] || fail "no measurement was taken, so the absorb proves nothing"
  grep -q 'cpu +' "$state/.watch-triage.log" \
    || fail "the absorb did not record the reading it was made from: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  cleanup_fixtures
  pass "a wedge window that expires inside one poll cycle still measures before it escalates"
}

# --- (b) the missed stall: busy on paper, doing nothing in fact --------------

test_busy_pane_doing_nothing_is_surfaced() {
  local dir state fakebin out drain_out window tty pid
  window="test:fm-stopped"
  tty=$(pty_run stopped 'sleep 100000') || fail "could not start the stopped pty fixture"
  dir=$(make_case stopped-pane stopped "$window" "$tty" 'working: implementing the fix')
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; drain_out="$dir/drain.out"
  # The session-limit condition exactly: a turn was opened and never closed,
  # because the harness stopped without firing its turn-end hook. The pane
  # therefore classifies BUSY and, before this change, was exempt from stale
  # detection until FM_BUSY_TURN_MAX_SECS an hour later.
  "$BUSY_EVENT" arm "$state" stopped >/dev/null || fail "could not arm the busy record"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · claimed in flight'
  run_watch "$state" "$fakebin" "$out" FM_STALE_ESCALATE_SECS=999999 FM_BUSY_TURN_MAX_SECS=999999
  pid=$!
  wait_for_exit "$pid" 400 \
    || { reap "$pid"; fail "a busy pane that did nothing measurable for its whole span was never surfaced"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "the stall did not print a stale wake: $(cat "$out")"
  grep -F "reports a turn in flight but is not working" "$out" >/dev/null \
    || fail "the wake did not name the stall for what it is: $(cat "$out")"
  grep -F "stalled" "$out" >/dev/null || fail "the wake did not carry the reading that justified it: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the stall wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the stall wake was not queued"
  cleanup_fixtures
  pass "a worker whose harness still claims a turn in flight, while its subtree does nothing, is surfaced"
}

test_busy_pane_that_is_working_raises_no_stall() {
  local dir state fakebin out window tty pid
  window="test:fm-busywork"
  tty=$(pty_run busywork "$BURNER") || fail "could not start the busy working pty fixture"
  dir=$(make_case busy-working busywork "$window" "$tty" 'working: long turn under way')
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  "$BUSY_EVENT" arm "$state" busywork >/dev/null || fail "could not arm the busy record"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · long turn'
  run_watch "$state" "$fakebin" "$out" FM_STALE_ESCALATE_SECS=999999 FM_BUSY_TURN_MAX_SECS=999999
  pid=$!
  # Long enough that the stall span (2s here) has matured several times over.
  sleep 15
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "a busy pane that was really working raised the stall alarm: $(cat "$out")"
  fi
  reap "$pid"
  [ -s "$state/.progress-$(printf '%s' "$window" | tr ':/.' '___')" ] \
    || fail "no measurement was taken, so the silence proves nothing"
  [ ! -s "$state/.wake-queue" ] || fail "a busy, measurably working pane enqueued a stall wake"
  cleanup_fixtures
  pass "the new stall alarm needs measured non-progress, so a busy pane that is really working never raises it"
}

# --- (c) no measurement, no change in behavior ------------------------------

test_unmeasurable_pane_keeps_the_previous_behavior() {
  local dir state fakebin out window key tty pid
  window="test:fm-nopid"
  tty=$(pty_run nopid "$BURNER") || fail "could not start the unmeasurable pty fixture"
  dir=$(make_case no-pid-source nopid "$window" "$tty" 'working: no measurement available')
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  export FM_FAKE_CREW_STATE='state: working · source: run-step · suite running'
  # A backend with no per-pane pid source, which is what zellij, Orca, and cmux
  # actually are: everything else about the pane reads exactly as before, and
  # only the tty behind the pid resolution is unavailable. The pane really is
  # working, so a silent absorb here would be the measurement inventing a verdict
  # it never took.
  run_watch "$state" "$fakebin" "$out" FM_STALE_ESCALATE_SECS=3 FM_BUSY_TURN_MAX_SECS=999999 \
    FM_TEST_PANE_TTY_FAIL=1
  pid=$!
  wait_for_exit "$pid" 400 \
    || { reap "$pid"; fail "an unmeasurable pane must still wedge-escalate exactly as it did before"; }
  grep -F "possible wedge" "$out" >/dev/null || fail "the unmeasurable pane did not escalate: $(cat "$out")"
  grep -F "no-pid-source" "$out" >/dev/null \
    || fail "the escalation did not disclose that nothing could be measured: $(cat "$out")"
  [ ! -e "$state/.progress-$key" ] || fail "a backend with no pid source must record no baseline"
  cleanup_fixtures
  pass "a pane with no pid source measures nothing and keeps the pre-existing escalation, disclosing why"
}

test_measured_progress_declines_the_wedge_escalation
test_a_poll_slower_than_the_wedge_window_measures_before_it_escalates
test_busy_pane_doing_nothing_is_surfaced
test_busy_pane_that_is_working_raises_no_stall
test_unmeasurable_pane_keeps_the_previous_behavior
