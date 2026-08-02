#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-step-liveness.sh - the "is this no-mistakes step
# actually doing work?" probe.
#
# The 2026-08-02 incident (docs/postmortems/nm-quiet-test-step.md) was a false
# DEAD reading: a configured-command step reports no agent pid, no round, and no
# streamed log for its whole run, so `axi status` renders a healthy step as
# quiet, and the hand check used to confirm death - a process search by NAME -
# found nothing because the test command's argv carries neither the run id nor
# the worktree path. Two healthy runs were aborted on that reading.
#
# These cases pin the probe over REAL processes in a REAL directory, because the
# whole point is that it observes the operating system rather than a status
# report:
#   (a) no process in the worktree            -> dead
#   (b) a live process in the worktree        -> alive (presence-only, --sample 0)
#   (c) argv-invisible process: the exact regression for the false negative -
#       the process is undiscoverable by name and discoverable by cwd
#   (d) a CPU-burning process                 -> alive, with measured progress
#   (e) a sleeping process                    -> stalled, explicitly NOT dead
#   (f) worktree resolution through the no-mistakes home layout
#   (g) unresolvable worktree                 -> unknown (never dead)
#   (h) usage error                           -> exit 2
#   (i) the named unit of work and its age, which separate slow from hung and
#       which bin/fm-crew-state.sh carries onto every heartbeat read
#   (j) deterministic process-gap and sampled-transition regressions
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROBE="$ROOT/bin/fm-nm-step-liveness.sh"
fm_test_tmproot_into TMP_ROOT fm-nm-step-liveness

RUN_ID=01TESTRUNTESTRUNTESTRUN00
WT="$TMP_ROOT/worktree"
mkdir -p "$WT"

# Track every process this suite starts so a failing assertion never leaks one.
# Descendants are killed too, not just the tracked pid: a leaked grandchild
# inherits this suite's stdout and holds the pipe open until it exits on its
# own, which makes a passing suite look like a hung one to whatever is reading
# it - including the gate's serial test loop.
STARTED_PIDS=""
kill_tree() {  # <pid>
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -9 "$1" 2>/dev/null || true
}
kill_started() {
  local pid
  for pid in $STARTED_PIDS; do
    kill_tree "$pid"
    wait "$pid" 2>/dev/null || true
  done
  STARTED_PIDS=""
}
trap kill_started EXIT

verdict_of() {  # <probe output> -> the verdict word
  printf '%s\n' "$1" | sed -n 's/^liveness:[[:space:]]*\([a-z]*\).*/\1/p'
}

wait_for_barrier() {  # <barrier-dir> <probe-pid>
  local dir=$1 pid=$2 _
  for _ in {1..200}; do
    [ -s "$dir/ready" ] && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

# --- (a) no process in the worktree -> dead ---------------------------------

out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
[ "$(verdict_of "$out")" = dead ] || fail "empty worktree must read dead, got: $out"
assert_contains "$out" "procs: 0" "dead verdict reports zero processes"
pass "no process with its cwd in the worktree reads dead"

# --- (b) a live process in the worktree -> alive ----------------------------

( cd "$WT" && exec sleep 120 ) &
SLEEPER=$!
STARTED_PIDS="$STARTED_PIDS $SLEEPER"
# The probe reads the kernel's view of the process table, so poll briefly rather
# than assuming the fork is observable the instant the shell returns.
out=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
  case "$out" in *"procs: 1"*) break ;; esac
  sleep 0.3
done
# What this case proves is DISCOVERY: the process is found through its working
# directory. It deliberately does NOT assert `alive`, because presence is not
# progress - `sleep 120` accrues no cpu and is correctly not called working (see
# case (e)). Asserting alive here is exactly the conflation that let four field
# hangs read healthy while frozen.
assert_contains "$out" "procs: 1" "the live process is discovered through its cwd"
[ "$(verdict_of "$out")" != dead ] || fail "a discovered live process must not read dead, got: $out"
pass "a live process with its cwd in the worktree is discovered (presence, not health)"

# --- (c) the false-negative regression: invisible to a name search ----------
#
# This is the failure that cost two healthy runs. `sleep 120` names neither the
# run nor the worktree, exactly like the real `sh -c command -v tmux ...` test
# command and its `bash tests/<name>.test.sh` children.
by_name=$(pgrep -f "$WT" 2>/dev/null || true)
[ -z "$by_name" ] || fail "fixture is wrong: the process must be invisible to an argv search"
case "$out" in *"procs: 1"*) ;; *) fail "cwd search must find what an argv search cannot, got: $out" ;; esac
pass "a process invisible to an argv search is still found by working directory"

# --- (e) a sleeping process reads stalled, never dead -----------------------
#
# Ordered before the CPU case so the sleeper is still the only process here.
out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 1)
[ "$(verdict_of "$out")" = stalled ] || fail "an idle process must read stalled, got: $out"
assert_not_contains "$out" "liveness: dead" "a sleeping process is never reported dead"
assert_contains "$out" "blocked on I/O" "stalled explains that it may be legitimately waiting"
pass "a process making no progress reads stalled, explicitly distinct from dead"

# --- (d) a CPU-burning process reports measured progress --------------------

( cd "$WT" && exec bash -c 'while :; do :; done' ) &
BURNER=$!
STARTED_PIDS="$STARTED_PIDS $BURNER"
out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 1)
[ "$(verdict_of "$out")" = alive ] || fail "a CPU-burning process must read alive, got: $out"
assert_contains "$out" "cpu +" "the alive verdict reports the measured CPU delta"
pass "a process consuming CPU reads alive with measured progress"

kill_started

# --- (i) the reported unit of work ------------------------------------------
#
# "alive" alone still leaves hours of runtime unexplained, which is what made a
# healthy multi-hour step indistinguishable from a hang. The probe names the
# step's current unit of work and its age, and bin/fm-crew-state.sh carries that
# onto every heartbeat read, so the field is load-bearing rather than cosmetic.
#
# The shape mirrors the real one: a root shell the daemon owns, running one
# child at a time - the suite's `for t in tests/*.test.sh` loop.
( cd "$WT" && exec bash -c 'sleep 120 & wait' ) &
PARENT=$!
STARTED_PIDS="$STARTED_PIDS $PARENT"
out=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
  case "$out" in *"doing: "*) break ;; esac
  sleep 0.3
done
assert_contains "$out" "doing: sleep 120" "the probe names the child the step is currently running"
# The age is what separates "slow" from "sitting on the same script for hours".
printf '%s\n' "$out" | grep -qE 'doing: sleep 120 \([0-9]+:[0-9]{2}' \
  || fail "the reported unit of work must carry its age, got: $out"
pass "the probe names the current unit of work and how long it has been running"

kill_started

# --- (f) worktree resolution through the no-mistakes home layout ------------

NM_HOME="$TMP_ROOT/nm-home"
mkdir -p "$NM_HOME/worktrees/repoid123/$RUN_ID"
out=$(FM_NM_HOME="$NM_HOME" "$PROBE" "$RUN_ID" --sample 0)
[ "$(verdict_of "$out")" = dead ] || fail "layout resolution must find the worktree, got: $out"
assert_contains "$out" "$RUN_ID" "the resolved worktree path names the run"
pass "the run's worktree resolves through the no-mistakes home layout"

# --- (g) an unresolvable worktree is unknown, never dead --------------------

out=$(FM_NM_HOME="$NM_HOME" "$PROBE" 01NOSUCHRUN0000000000000 --sample 0)
[ "$(verdict_of "$out")" = unknown ] || fail "an unresolvable run must read unknown, got: $out"
pass "an unresolvable run reads unknown rather than dead"

out=$("$PROBE" "$RUN_ID" --worktree "$TMP_ROOT/does-not-exist" --sample 0)
[ "$(verdict_of "$out")" = unknown ] || fail "a missing worktree must read unknown, got: $out"
pass "a missing worktree reads unknown rather than dead"

# --- (h) usage ---------------------------------------------------------------

status=0
"$PROBE" >/dev/null 2>&1 || status=$?
[ "$status" = 2 ] || fail "a missing run id must exit 2, got $status"
pass "a missing run id is a usage error"

# --- (j) REGRESSION: the 2026-08-02 test-start deadlock cannot recur ---------
#
# The deadlock was not that a step died. It was that a step recorded `running`
# was INDISTINGUISHABLE from a slow one, so a healthy multi-hour step and a
# genuinely dead one produced the same reading and three healthy runs were
# aborted on it. These cases pin both directions of that distinction over real
# processes, because a regression in EITHER direction recreates the outage:
# read a live step as dead and work gets destroyed; read a dead step as alive
# and the run wedges forever with nothing reporting it.

# (j1) The exact incident signature: a step whose log is quiet, whose agent_pid
# is empty and whose round reads `starting` - i.e. nothing in `axi status` says
# it is alive - is still reported ALIVE while its processes are working.
( cd "$WT" && exec bash -c 'while :; do :; done' ) &
LIVE=$!
STARTED_PIDS="$STARTED_PIDS $LIVE"
# Progress is established by comparing two observations, so seed a baseline and
# let the process accumulate cpu before the second read. A short window is
# permitted here only to keep the suite fast; the production floor is unchanged.
SNAP_J="$TMP_ROOT/snap-j1"
out=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  FM_NM_SNAP_DIR="$SNAP_J" FM_NM_MIN_WINDOW=1 "$PROBE" "$RUN_ID" --worktree "$WT" --sample 0 >/dev/null
  sleep 1.2
  out=$(FM_NM_SNAP_DIR="$SNAP_J" FM_NM_MIN_WINDOW=1 "$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
  [ "$(verdict_of "$out")" = alive ] && break
done
[ "$(verdict_of "$out")" = alive ] \
  || fail "REGRESSION: a working step with no axi-status liveness signal must read alive, got: $out"
pass "regression: a quiet step with no pid and no round still reads alive while working"

# (j2) A momentary gap between units of work must NOT read dead. The scan barrier
# proves the first scan was empty before the successor is allowed to appear, so
# this cannot pass merely because a load-delayed first scan found the successor.
kill -9 "$LIVE" 2>/dev/null || true
wait "$LIVE" 2>/dev/null || true
GAP_BARRIER="$TMP_ROOT/gap-barrier"
mkdir -p "$GAP_BARRIER"
GAP_OUT="$TMP_ROOT/gap.out"
FM_NM_TEST_BARRIER_DIR="$GAP_BARRIER" \
  FM_NM_TEST_BARRIER_PHASE=after-empty-scan \
  FM_NM_ABSENCE_CONFIRM_DELAY=0 \
  "$PROBE" "$RUN_ID" --worktree "$WT" --sample 0 > "$GAP_OUT" &
GAP_PROBE=$!
STARTED_PIDS="$STARTED_PIDS $GAP_PROBE"
wait_for_barrier "$GAP_BARRIER" "$GAP_PROBE" \
  || fail "the gap probe never proved its first scan was empty"
[ "$(cat "$GAP_BARRIER/ready")" = after-empty-scan ] \
  || fail "the gap probe reached the wrong barrier phase"
( cd "$WT" && exec bash -c 'while :; do :; done' ) &
SUCCESSOR=$!
STARTED_PIDS="$STARTED_PIDS $SUCCESSOR"
out=""
# Confirm the successor is DISCOVERABLE before releasing the barrier. This is a
# presence check on the fixture, not a health claim: presence alone is no longer
# reported as alive, so assert on the process count rather than the verdict.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
  case "$out" in *"procs: 0"*) sleep 0.2 ;; *) break ;; esac
done
case "$out" in
  *"procs: 0"*) fail "the successor was not observable before the confirming rescan" ;;
esac
printf 'after-empty-scan\n' > "$GAP_BARRIER/release"
wait "$GAP_PROBE" || fail "the gap probe failed after its barrier was released"
out=$(cat "$GAP_OUT")
# The invariant is that a gap is never reported DEAD - dead is the only verdict
# that authorizes discarding a run. It is deliberately not asserted to be
# `alive`: with the successor only just observed there is no prior sample to
# establish progress from, and claiming health on that basis would be the same
# unfounded assertion this suite exists to prevent.
[ "$(verdict_of "$out")" != dead ] \
  || fail "REGRESSION: a gap between units of work must not be reported dead, got: $out"
assert_contains "$out" "procs: 1" "the confirming rescan found the successor process"
pass "regression: a momentary gap between units of work is not reported as death"

# (j3) A process set present at the first scan but gone by the second is an
# ambiguous step transition, not evidence that work remains alive.
SAMPLE_BARRIER="$TMP_ROOT/sample-barrier"
mkdir -p "$SAMPLE_BARRIER"
SAMPLE_OUT="$TMP_ROOT/sample.out"
FM_NM_TEST_BARRIER_DIR="$SAMPLE_BARRIER" \
  FM_NM_TEST_BARRIER_PHASE=before-progress-sample \
  "$PROBE" "$RUN_ID" --worktree "$WT" --sample 1 > "$SAMPLE_OUT" &
SAMPLE_PROBE=$!
STARTED_PIDS="$STARTED_PIDS $SAMPLE_PROBE"
wait_for_barrier "$SAMPLE_BARRIER" "$SAMPLE_PROBE" \
  || fail "the sample probe never observed the initial process set"
[ "$(cat "$SAMPLE_BARRIER/ready")" = before-progress-sample ] \
  || fail "the sample probe reached the wrong barrier phase"
kill_tree "$SUCCESSOR"
wait "$SUCCESSOR" 2>/dev/null || true
printf 'before-progress-sample\n' > "$SAMPLE_BARRIER/release"
wait "$SAMPLE_PROBE" || fail "the sample probe failed after its barrier was released"
out=$(cat "$SAMPLE_OUT")
[ "$(verdict_of "$out")" = unknown ] \
  || fail "a process set that vanished during the sample must read unknown, got: $out"
assert_contains "$out" "processes present at the first scan were gone by the second" \
  "the transition verdict explains what changed between scans"
assert_contains "$out" "transition could not be established" \
  "the transition verdict states that the outcome is ambiguous"
pass "regression: a process set that vanished during sampling reads unknown"

kill_started

for delay in '' -1 invalid 1s; do
  out=$(FM_NM_ABSENCE_CONFIRM_DELAY="$delay" "$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
  [ "$(verdict_of "$out")" = unknown ] \
    || fail "an invalid absence-confirmation delay must read unknown, got: $out"
  assert_contains "$out" "invalid absence-confirmation delay" \
    "an invalid absence-confirmation delay explains why it was rejected"
done

out=$(FM_NM_ABSENCE_CONFIRM_DELAY=0 "$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
[ "$(verdict_of "$out")" = unknown ] \
  || fail "zero delay without the empty-scan test barrier must read unknown, got: $out"
assert_contains "$out" "zero requires the explicit empty-scan test barrier" \
  "zero delay names its test-only requirement"

WAIT_FAIL_BIN="$TMP_ROOT/wait-fail-bin"
mkdir -p "$WAIT_FAIL_BIN"
cat > "$WAIT_FAIL_BIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$WAIT_FAIL_BIN/sleep"
out=$(PATH="$WAIT_FAIL_BIN:$PATH" FM_NM_ABSENCE_CONFIRM_DELAY=1 \
  "$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
[ "$(verdict_of "$out")" = unknown ] \
  || fail "a failed absence-confirmation wait must read unknown, got: $out"
assert_contains "$out" "absence-confirmation wait failed: sleep exited 7" \
  "a failed wait explains why absence was not confirmed"

# (j4) A genuinely absent step still reads dead after the confirming rescan, so
# the fix for (j2) did not buy safety by making `dead` unreachable.
out=$(FM_NM_ABSENCE_CONFIRM_DELAY=1 "$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
[ "$(verdict_of "$out")" = dead ] \
  || fail "REGRESSION: a genuinely empty worktree must still read dead, got: $out"
assert_contains "$out" "confirmed by a second scan" "the dead verdict states that absence was confirmed"
pass "regression: confirmed absence still reads dead, so the distinction stays usable"

# --- (k) REGRESSION: present-but-frozen is NOT alive -------------------------
#
# Four confirmed field hangs (two lanes, one of them the keystone that held 18
# close-outs across five homes for five hours) had this shape: test step status
# `running`, processes PRESENT, identical pid set, no new spawns, and zero cpu
# movement across 30-40s. The presence-only path reported every one of them as
# `alive`, so the wake was absorbed and nobody was told.
#
# SIGSTOP reproduces it deterministically - it turns an intermittent field
# failure into something anyone can trigger on demand, which is why this case
# exists rather than a comment describing the shape.
#
# Both directions are pinned here on purpose. A fix tested only against hangs
# ships a false positive that condemns healthy runs (measured: a whole-set cpu
# SUM read a genuinely working suite as hung, because the suite churns children
# and an exited child removes its accumulated cpu from the sum). A fix tested
# only against working steps never detects the hang at all.
SNAP_K="$TMP_ROOT/snap-frozen"
WT_K="$TMP_ROOT/frozen-wt"
mkdir -p "$WT_K"
( cd "$WT_K" && exec bash -c 'while :; do :; done' ) &
FROZEN=$!
STARTED_PIDS="$STARTED_PIDS $FROZEN"
sleep 0.5

# A first observation has nothing to compare against and must say so, never alive.
out=$(FM_NM_SNAP_DIR="$SNAP_K" FM_NM_MIN_WINDOW=1 "$PROBE" "$RUN_ID" --worktree "$WT_K" --sample 0)
[ "$(verdict_of "$out")" = unknown ] \
  || fail "a first observation must read unknown, not a verdict, got: $out"
pass "regression: a first observation reports unknown rather than assuming health"

# Working: the process advances its own cpu, so it is alive.
sleep 2
out=$(FM_NM_SNAP_DIR="$SNAP_K" FM_NM_MIN_WINDOW=1 "$PROBE" "$RUN_ID" --worktree "$WT_K" --sample 0)
[ "$(verdict_of "$out")" = alive ] \
  || fail "a cpu-advancing process must read alive, got: $out"
pass "regression: a genuinely working process reads alive (no false positive)"

# Frozen: present, same pid, no new spawns, no cpu movement - the field shape.
#
# Two reads after the freeze, not one. The first window still straddles the
# freeze boundary and therefore contains real pre-freeze work, so it can legally
# read alive; the verdict is asserted on the first window lying ENTIRELY inside
# the freeze. That one-heartbeat lag is a real property of comparing two
# observations, and it is recorded here rather than hidden - it is irrelevant
# against hangs measured in hours, and the alternative (a lower floor) would
# risk condemning slow-but-working steps, which is the costlier error.
kill -STOP "$FROZEN" 2>/dev/null || true
sleep 2
FM_NM_SNAP_DIR="$SNAP_K" FM_NM_MIN_WINDOW=1 "$PROBE" "$RUN_ID" --worktree "$WT_K" --sample 0 >/dev/null
sleep 2
out=$(FM_NM_SNAP_DIR="$SNAP_K" FM_NM_MIN_WINDOW=1 "$PROBE" "$RUN_ID" --worktree "$WT_K" --sample 0)
kill -CONT "$FROZEN" 2>/dev/null || true
[ "$(verdict_of "$out")" != alive ] \
  || fail "REGRESSION: a present-but-frozen process must NOT read alive, got: $out"
[ "$(verdict_of "$out")" = stalled ] \
  || fail "a present-but-frozen process must read stalled, got: $out"
assert_contains "$out" "PRESENT BUT NOT PROGRESSING" "the stalled detail names the field-hang signature"
pass "regression: a present-but-frozen process reads stalled, never alive"

kill_started

# --- (m) REGRESSION: child turnover is the discriminator ---------------------
#
# Field evidence separating a SLOW step from a STRANDED one, measured outside
# the pipeline as well as inside it:
#   slow-but-alive : parent cpu FLAT, but fm-teardown.sh children turning over
#                    every few seconds (each invocation makes ~955 sequential
#                    helper launches, so it crawls under load)
#   stranded       : the step process has NO children at all and zero cpu across
#                    30s at 49 minutes elapsed
# So neither parent cpu nor the activity clock discriminates - child turnover
# does. This pins that, because an earlier build of this probe dropped exactly
# the pids that prove turnover: a short-lived child can exit between the cwd
# enumeration and the `ps` read, and those unreadable pids were discarded, which
# made a healthy crawling step read `stalled`. A false hang call on a slow step
# is the costly direction - it condemns work that is merely starved.
TURN_WT="$TMP_ROOT/turnover-wt"; mkdir -p "$TURN_WT"
SNAP_M="$TMP_ROOT/snap-turnover"
( cd "$TURN_WT" && exec bash -c 'while :; do ( sleep 1 ); done' ) &
TURNOVER=$!
STARTED_PIDS="$STARTED_PIDS $TURNOVER"
sleep 0.5
FM_NM_SNAP_DIR="$SNAP_M" FM_NM_MIN_WINDOW=1 "$PROBE" "$RUN_ID" --worktree "$TURN_WT" --sample 0 >/dev/null
sleep 2
out=$(FM_NM_SNAP_DIR="$SNAP_M" FM_NM_MIN_WINDOW=1 "$PROBE" "$RUN_ID" --worktree "$TURN_WT" --sample 0)
[ "$(verdict_of "$out")" = alive ] \
  || fail "REGRESSION: child turnover with a flat parent must read alive, got: $out"
pass "regression: a crawling step proved alive by child turnover, not by parent cpu"

kill_started

# The stranded counterpart: one process, no children, no cpu movement.
LONE_WT="$TMP_ROOT/lone-wt"; mkdir -p "$LONE_WT"
SNAP_N="$TMP_ROOT/snap-lone"
( cd "$LONE_WT" && exec sleep 120 ) &
LONE=$!
STARTED_PIDS="$STARTED_PIDS $LONE"
sleep 0.5
FM_NM_SNAP_DIR="$SNAP_N" FM_NM_MIN_WINDOW=1 "$PROBE" "$RUN_ID" --worktree "$LONE_WT" --sample 0 >/dev/null
sleep 2
out=$(FM_NM_SNAP_DIR="$SNAP_N" FM_NM_MIN_WINDOW=1 "$PROBE" "$RUN_ID" --worktree "$LONE_WT" --sample 0)
[ "$(verdict_of "$out")" != alive ] \
  || fail "REGRESSION: a lone childless process with no cpu must not read alive, got: $out"
pass "regression: a stranded step with no children and no cpu is not reported alive"

kill_started
