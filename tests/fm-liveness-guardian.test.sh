#!/usr/bin/env bash
# Behavior tests for the session-independent fleet liveness guardian
# (bin/fm-liveness-guardian.sh, docs/liveness-guardian.md).
#
# The guardian runs from a systemd user timer with no session in the loop, so
# every case here exercises it against disposable mock homes and NEVER against a
# live fleet home. The real self-surviving arm (systemd-run) and the real
# secondmate relaunch (fm-spawn) are exercised only through their override seams
# so the tests neither require a user bus nor spawn a real agent; the seams are
# the guardian's own public interface, not private internals. The adversarial
# arm case uses a faithful watcher stand-in (touch the beacon, exactly what a real
# watcher does at the top of every poll) launched through the same seam, so the
# assertion is the real observable outcome - a fresh beacon and no double-arm -
# not a mocked verdict.
# shellcheck disable=SC2016 # single quotes are deliberate in the stub heredocs: $1/$2 expand inside the stub child, not here
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-liveness-guardian.sh"
TMP_ROOT=$(fm_test_tmproot fm-liveness-guardian)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
# A live "harness" process for session-alive cases: a process whose comm is
# `claude` satisfies fm_harness_pid_alive.
ln -s /bin/bash "$FAKEBIN/claude"

# Track background processes started for live-session fixtures so teardown reaps
# them even on a hard failure. The fixture is a bash (comm=claude) that spawns a
# `sleep` child, so teardown must kill the CHILD too (pkill -P) - otherwise the
# orphaned sleep lingers in the test's process group and the runner waits on it.
# pkill -P is portable across Linux and macOS; setsid is not.
FIXTURE_PIDS=()
cleanup() {
  local p
  for p in "${FIXTURE_PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    pkill -P "$p" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# A guardian-scoped scratch state/log dir so no case pollutes another.
GSTATE="$TMP_ROOT/gstate"
GLOG="$TMP_ROOT/guardian.log"

# The faithful arm launcher stub: records the invocation and freshens the beacon
# exactly as a real watcher's first poll iteration does. Records <home> per call.
ARM_STUB="$TMP_ROOT/fake-arm-launcher.sh"
cat > "$ARM_STUB" <<'SH'
#!/usr/bin/env bash
# args: <unit> <home> <arm-script>
set -u
printf '%s\n' "$2" >> "$ARM_INVOCATIONS"
mkdir -p "$2/state"
touch "$2/state/.last-watcher-beat"
SH
chmod +x "$ARM_STUB"

RELAUNCH_STUB="$TMP_ROOT/fake-relaunch.sh"
cat > "$RELAUNCH_STUB" <<'SH'
#!/usr/bin/env bash
# args: <home> <task-id> <main-home>
set -u
printf '%s\t%s\n' "$1" "$2" >> "$RELAUNCH_INVOCATIONS"
SH
chmod +x "$RELAUNCH_STUB"

ESCALATE_STUB="$TMP_ROOT/fake-escalate.sh"
cat > "$ESCALATE_STUB" <<'SH'
#!/usr/bin/env bash
# args: <home> <summary>
set -u
printf '%s\t%s\n' "$1" "$2" >> "$ESCALATE_INVOCATIONS"
SH
chmod +x "$ESCALATE_STUB"

# make_home <dir>: a minimal firstmate home (just a state dir; the guardian falls
# back to the repo's own fm-watch-arm for the real path and uses seams in tests).
make_home() {
  mkdir -p "$1/state"
}

# needs_work <home>: give the home an in-flight task so it needs supervision.
needs_work() {
  : > "$1/state/task-$RANDOM.meta"
}

# stale_beacon <home>: a beacon far past any grace.
stale_beacon() {
  touch -d '2020-01-01' "$1/state/.last-watcher-beat"
}

# fresh_beacon <home>: a beacon at "now".
fresh_beacon() {
  touch "$1/state/.last-watcher-beat"
}

# live_session <home>: write a live claude pid into the session lock. The `; :`
# keeps bash from exec-optimizing a single `sleep` into place (which would leave
# comm=sleep, not claude) so fm_harness_pid_alive recognizes a live harness.
live_session() {
  "$FAKEBIN/claude" -c 'sleep 3000; :' &
  local pid=$!
  FIXTURE_PIDS+=("$pid")
  printf '%s\n' "$pid" > "$1/state/.lock"
}

# new_ledgers <tag>: own a fresh, empty invocation ledger for the three seams IN
# THE PARENT shell (run_guardian runs in a $(...) subshell, so it cannot set
# these for the caller). Each pass that must be counted separately gets its own.
new_ledgers() {
  ARM_INVOCATIONS="$TMP_ROOT/arm.$1.log"
  RELAUNCH_INVOCATIONS="$TMP_ROOT/relaunch.$1.log"
  ESCALATE_INVOCATIONS="$TMP_ROOT/escalate.$1.log"
  : > "$ARM_INVOCATIONS"; : > "$RELAUNCH_INVOCATIONS"; : > "$ESCALATE_INVOCATIONS"
  export ARM_INVOCATIONS RELAUNCH_INVOCATIONS ESCALATE_INVOCATIONS
}

# run_guardian <main-home> [args...]: run one guardian pass with the seams wired.
# Echoes stdout. The caller must have called new_ledgers first.
run_guardian() {
  local main=$1
  shift
  FM_HOME="$main" \
  FM_GUARDIAN_MAIN_HOME="$main" \
  FM_GUARDIAN_STATE_DIR="$GSTATE" \
  FM_GUARDIAN_LOG="$GLOG" \
  FM_GUARDIAN_WEDGE_ESCALATE_SECS="${TEST_WEDGE_SECS:-1800}" \
  FM_GUARDIAN_ARM_LAUNCHER="$ARM_STUB" \
  FM_GUARDIAN_RELAUNCH_CMD="$RELAUNCH_STUB" \
  FM_GUARDIAN_ESCALATE_CMD="$ESCALATE_STUB" \
    bash "$GUARD" "$@"
}

# Count non-empty lines. `grep -c` prints 0 AND exits 1 on no match, so capture
# once and normalize, never `grep -c ... || echo 0` (which double-prints 0).
count_lines() {
  [ -f "$1" ] || { echo 0; return; }
  local n
  n=$(grep -c . "$1" 2>/dev/null) || n=0
  echo "$n"
}

# ---------------------------------------------------------------------------
# Case A: an idle home (no in-flight work) is healthy - no action, ever.
# ---------------------------------------------------------------------------
A="$TMP_ROOT/A/main"; make_home "$A"; stale_beacon "$A"
new_ledgers A
out=$(run_guardian "$A" --list)
assert_contains "$out" "class=idle" "idle home with no work must classify idle"
assert_contains "$out" "action=none" "idle home takes no action"
pass "idle home classifies idle with no action"

# ---------------------------------------------------------------------------
# Case B: a needing home with a FRESH beacon is healthy - no arm, beacon
# untouched (the guardian never re-touches a healthy beacon).
# ---------------------------------------------------------------------------
B="$TMP_ROOT/B/main"; make_home "$B"; needs_work "$B"; fresh_beacon "$B"
before=$(stat -c %Y "$B/state/.last-watcher-beat")
new_ledgers B
out=$(run_guardian "$B")
assert_absent "$B/state/.watch.lock" "healthy home must not be armed"
[ "$(count_lines "$ARM_INVOCATIONS")" -eq 0 ] || fail "healthy home must not invoke the arm launcher"
after=$(stat -c %Y "$B/state/.last-watcher-beat")
[ "$before" = "$after" ] || fail "guardian must not re-touch a healthy home's beacon"
pass "healthy home is a no-op (no arm, no beacon touch)"

# ---------------------------------------------------------------------------
# Case C (adversarial): a lapsed home with NO session in the loop and a stale
# beacon is re-armed to a FRESH beacon; a second pass sees it healthy and does
# NOT double-arm. This is the brief's "re-arm ... with no interactive session in
# the loop" scenario.
# ---------------------------------------------------------------------------
C="$TMP_ROOT/C/main"; make_home "$C"; needs_work "$C"; stale_beacon "$C"   # no .lock => no session
# Confirm the precondition the brief simulates: beacon stale past grace.
age_before=$(( $(date +%s) - $(stat -c %Y "$C/state/.last-watcher-beat") ))
[ "$age_before" -gt 300 ] || fail "precondition: beacon must be stale past grace"
new_ledgers C1
out=$(run_guardian "$C")
[ "$(count_lines "$ARM_INVOCATIONS")" -eq 1 ] || fail "lapsed session-less home must be armed exactly once (got $(count_lines "$ARM_INVOCATIONS"))"
age_after=$(( $(date +%s) - $(stat -c %Y "$C/state/.last-watcher-beat") ))
[ "$age_after" -lt 300 ] || fail "after re-arm the beacon must be fresh (age ${age_after}s)"
# Second pass: now healthy -> no second arm.
new_ledgers C2
out=$(run_guardian "$C")
[ "$(count_lines "$ARM_INVOCATIONS")" -eq 0 ] || fail "healthy home must NOT be re-armed on the next pass (no double-arm)"
pass "lapsed session-less home re-arms to a fresh beacon; healthy home is not double-armed"

# ---------------------------------------------------------------------------
# Case I: a live-but-lapsed session (a long turn, or a wedge) is NEVER re-armed
# (a guardian watcher would mask the wedge and defeat the confirmation clock) and
# is NOT escalated until it has stayed lapsed past the wedge threshold.
# ---------------------------------------------------------------------------
I="$TMP_ROOT/I/main"; make_home "$I"; needs_work "$I"; stale_beacon "$I"; live_session "$I"
TEST_WEDGE_SECS=0   # any persisted lapse counts as a wedge, to drive the second pass
export TEST_WEDGE_SECS
new_ledgers I1
run_guardian "$I" >/dev/null
[ "$(count_lines "$ARM_INVOCATIONS")" -eq 0 ] || fail "a live session must never be re-armed (that masks a wedge)"
[ "$(count_lines "$ESCALATE_INVOCATIONS")" -eq 0 ] || fail "first observation of a lapse must not escalate (long turns recover)"
# Beacon must remain stale (the guardian did not freshen a live session's beacon).
age_i=$(( $(date +%s) - $(stat -c %Y "$I/state/.last-watcher-beat") ))
[ "$age_i" -gt 300 ] || fail "guardian must not freshen a live-but-lapsed session's beacon"
# Second pass: the lapse has now persisted past the (zeroed) threshold -> escalate.
new_ledgers I2
run_guardian "$I" >/dev/null
[ "$(count_lines "$ARM_INVOCATIONS")" -eq 0 ] || fail "a persisted live lapse must still never be re-armed"
[ "$(count_lines "$ESCALATE_INVOCATIONS")" -ge 1 ] || fail "a live session lapsed past the wedge threshold must be escalated"
unset TEST_WEDGE_SECS
pass "live-but-lapsed session is never re-armed; escalated only after the wedge threshold"

# ---------------------------------------------------------------------------
# Case D: a genuinely DEAD local secondmate director is relaunched through the
# sanctioned seam, and the relaunch is rate-limited on an immediate second pass.
# ---------------------------------------------------------------------------
D="$TMP_ROOT/D/main"; make_home "$D"; fresh_beacon "$D"   # main healthy, focus on the secondmate
SM="$TMP_ROOT/D/sm1-home"; make_home "$SM"; needs_work "$SM"; stale_beacon "$SM"
# Register the secondmate in the main home's state as a LOCAL kind=secondmate.
fm_write_secondmate_meta "$D/state/sm1.meta" "$SM" "firstmate:fm-sm1" alpha claude
new_ledgers D1
out=$(run_guardian "$D")
[ "$(count_lines "$RELAUNCH_INVOCATIONS")" -eq 1 ] || fail "dead secondmate must be relaunched once (got $(count_lines "$RELAUNCH_INVOCATIONS"))"
assert_grep "$SM" "$RELAUNCH_INVOCATIONS" "relaunch must target the secondmate home"
# Immediate second pass: rate-limited, no second relaunch.
new_ledgers D2
out=$(run_guardian "$D")
[ "$(count_lines "$RELAUNCH_INVOCATIONS")" -eq 0 ] || fail "relaunch must be rate-limited on an immediate second pass"
pass "dead secondmate director is relaunched once, then rate-limited"

# ---------------------------------------------------------------------------
# Case E: a REMOTE secondmate is reported and skipped (a local timer cannot
# repair another host).
# ---------------------------------------------------------------------------
E="$TMP_ROOT/E/main"; make_home "$E"; fresh_beacon "$E"
RM_HOME="/remote/opt/firstmate-remote"
fm_write_meta "$E/state/rm1.meta" \
  "kind=secondmate" "home=$RM_HOME" "remote_host=box.example.invalid" "harness=claude"
new_ledgers E
out=$(run_guardian "$E" --list)
assert_contains "$out" "class=remote-skip" "remote secondmate must be reported as remote-skip"
pass "remote secondmate is reported and skipped"

# ---------------------------------------------------------------------------
# Case F: the DEFAULT arm transport is a self-surviving systemd-run, never a
# fire-and-forget shell '&' (constraint 1), asserted through the --list plan.
# ---------------------------------------------------------------------------
F="$TMP_ROOT/F/main"; make_home "$F"; needs_work "$F"; stale_beacon "$F"
# --list without the launcher seam so the DEFAULT transport is printed.
out=$(FM_HOME="$F" FM_GUARDIAN_MAIN_HOME="$F" FM_GUARDIAN_STATE_DIR="$GSTATE" \
  FM_GUARDIAN_LOG="$GLOG" bash "$GUARD" --list)
assert_contains "$out" "systemd-run --user" "default arm must use a self-surviving systemd-run unit"
assert_not_contains "$out" "nohup" "default arm must not use nohup"
case "$out" in
  *' &'*) fail "default arm must never use a fire-and-forget shell '&'" ;;
esac
pass "default arm transport is a self-surviving systemd-run, not a shell '&'"

# ---------------------------------------------------------------------------
# Case G: runs cleanly under a bare `env -i` systemd-timer environment.
# ---------------------------------------------------------------------------
G="$TMP_ROOT/G/main"; make_home "$G"; needs_work "$G"; stale_beacon "$G"
out=$(env -i HOME="$HOME" PATH="/usr/bin:/bin" \
  FM_HOME="$G" FM_GUARDIAN_MAIN_HOME="$G" FM_GUARDIAN_STATE_DIR="$GSTATE" \
  FM_GUARDIAN_LOG="$GLOG" \
  bash "$GUARD" --list 2>&1)
rc=$?
expect_code 0 "$rc" "guardian must exit 0 under env -i"
assert_contains "$out" "home=$G" "guardian must classify the home under env -i"
pass "runs cleanly under a bare env -i environment"

# ---------------------------------------------------------------------------
# Case H: a DEAD main home (needs work, stale beacon, no session) is re-armed to
# capture wakes durably AND escalated - it is never relaunched (the guardian
# must not spawn a competing firstmate).
# ---------------------------------------------------------------------------
H="$TMP_ROOT/H/main"; make_home "$H"; needs_work "$H"; stale_beacon "$H"
new_ledgers H
out=$(run_guardian "$H")
[ "$(count_lines "$ARM_INVOCATIONS")" -eq 1 ] || fail "dead main home must be re-armed to capture wakes durably"
[ "$(count_lines "$ESCALATE_INVOCATIONS")" -ge 1 ] || fail "dead main home must be escalated to a human"
[ "$(count_lines "$RELAUNCH_INVOCATIONS")" -eq 0 ] || fail "guardian must never relaunch/spawn the main firstmate"
pass "dead main home is re-armed and escalated, never relaunched"

pass "fm-liveness-guardian: all cases passed"
