#!/usr/bin/env bash
# Behavior tests for the condition->action adapter of the process-to-event
# runner (bin/fm-procevent-when.sh).
#
# Every scenario is exercised through the adapter's public commands plus the
# generic runner, against real condition and action processes; nothing here
# asserts implementation-source bytes. The suite proves the load-bearing
# guarantees: the action fires exactly once on a stable true, never on a flap,
# never twice across a restart, never from a mutated spec, and every failure
# path ends in a captured terminal outcome that reaches the durable wake queue
# instead of a silent retry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-when-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

pe()   { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
when() { FM_HOME="$1" "$ROOT/bin/fm-procevent-when.sh" "${@:2}"; }

# Every home this suite arms is registered with tests/lib.sh, which sweeps it
# from every cleanup path so a runner still blocked on a condition that never
# fires cannot survive the run.
new_home() { mkdir -p "$1/state"; fm_test_track_procevent_home "$1"; }

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

first_result() {  # <home> <source-id>
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

wait_for_result() {  # <home> <source-id> [tries]
  local n=${3:-150}
  for _ in $(seq 1 "$n"); do
    first_result "$1" "$2" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

wait_for_file() {  # <file> [tries]
  local n=${2:-150}
  for _ in $(seq 1 "$n"); do [ -e "$1" ] && return 0; sleep 0.1; done
  return 1
}

# A condition that is true exactly when its trigger file exists, and counts
# every evaluation so flap tests can wait on real poll activity.
COND="$TMP_ROOT/cond.sh"
cat > "$COND" <<'SH'
#!/usr/bin/env bash
trigger=$1
counter=$2
echo x >> "$counter"
[ -e "$trigger" ]
SH
chmod +x "$COND"

# An action that records every invocation, so exactly-once is observable.
ACT="$TMP_ROOT/act.sh"
cat > "$ACT" <<'SH'
#!/usr/bin/env bash
log=$1
exit_code=${2:-0}
echo invoked >> "$log"
echo "action ran against $log"
exit "$exit_code"
SH
chmod +x "$ACT"

count_lines() { [ -e "$1" ] && grep -c . "$1" || echo 0; }

# Run the real watcher against <home> for at most <tenths> deciseconds, then stop
# it. An out path of "-" gives the watcher a stdout reader that is already gone,
# which is how an actionable wake fails to reach firstmate.
# Queue a process-event wake so a run that must NOT report the insecure state
# root still ends in an observable wake. procevent_surface_queued sits directly
# after the insecure check, so seeing its reason proves the cycle got past it.
queue_procevent_anchor() {  # <home> <key>
  FM_STATE_OVERRIDE="$1/state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_append check "procevent:$2" "check: process-event result captured: $2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$2"
}

run_watcher() {  # <home> <out|-> <tenths>
  local home=$1 out=$2 tenths=$3 pid='' wrapper i pidfile
  pidfile="$home/.run-watcher.pid"
  rm -f -- "$pidfile"
  if [ "$out" = - ]; then
    ( FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
        FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" 2>/dev/null &
      echo $! > "$pidfile"
      wait ) | true &
  else
    ( FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
        FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>/dev/null &
      echo $! > "$pidfile"
      wait ) &
  fi
  wrapper=$!
  i=0
  while [ "$i" -lt 50 ] && [ -z "$pid" ]; do
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -n "$pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -n "$pid" ] || fail "run_watcher could not observe the watcher pid"
  i=0
  while [ "$i" -lt "$tenths" ]; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; i=$((i + 1)); done
  kill "$pid" 2>/dev/null || true
  wait "$wrapper" 2>/dev/null || true
  rm -f -- "$pidfile"
}

# --- arm binds the pair and refuses a duplicate ------------------------------
H="$TMP_ROOT/h-arm"; new_home "$H"
out=$(when "$H" arm arm-test --interval 0.1 \
  --condition "$COND" "$TMP_ROOT/never" "$TMP_ROOT/arm-count" \
  --action "$ACT" "$TMP_ROOT/arm-act")
assert_contains "$out" "armed: when-arm-test" "arm reports the canonical source id"
assert_present "$H/state/when/when-arm-test.spec" "arm writes the private spec"
assert_present "$H/state/when/when-arm-test.trust" "arm writes the trust binding"
assert_present "$H/state/procevent/when-arm-test.source" "arm registers the process-event source"
mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$H/state/when/when-arm-test.spec")
assert_contains "$mode" 600 "the spec is private"
if when "$H" arm arm-test --condition true --action true 2>"$TMP_ROOT/dup.err"; then
  fail "re-arming an existing watch must be refused"
fi
assert_grep "already exists" "$TMP_ROOT/dup.err" "the duplicate refusal names the leftover state"
sid=$(when "$H" source-id arm-test)
assert_contains "$sid" "when-arm-test" "source-id prints the canonical id"
out=$(when "$H" retire arm-test)
assert_contains "$out" "retired: when-arm-test" "retire reports the source"
assert_absent "$H/state/when/when-arm-test.spec" "retire removes the spec"
assert_absent "$H/state/when/when-arm-test.trust" "retire removes the trust binding"
assert_absent "$H/state/procevent/when-arm-test.source" "retire drops the registration"
out=$(when "$H" retire arm-test)
assert_contains "$out" "retired: when-arm-test" "retire is idempotent"
pass "arm binds, refuses duplicates, and retire cleans up"

# --- concurrent arms publish exactly one complete registration ---------------
H="$TMP_ROOT/h-concurrent-arm"; new_home "$H"
(
  when "$H" arm race --stable 1 --condition true --action "$ACT" "$TMP_ROOT/race-a" \
    >"$TMP_ROOT/race-a.out" 2>"$TMP_ROOT/race-a.err"
  printf '%s\n' "$?" > "$TMP_ROOT/race-a.rc"
) &
pid_a=$!
(
  when "$H" arm race --stable 1 --condition true --action "$ACT" "$TMP_ROOT/race-b" \
    >"$TMP_ROOT/race-b.out" 2>"$TMP_ROOT/race-b.err"
  printf '%s\n' "$?" > "$TMP_ROOT/race-b.rc"
) &
pid_b=$!
wait "$pid_a" "$pid_b"
rc_a=$(cat "$TMP_ROOT/race-a.rc")
rc_b=$(cat "$TMP_ROOT/race-b.rc")
[ $((rc_a + rc_b)) -eq 1 ] || fail "exactly one concurrent arm must succeed"
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-race || fail "the winning concurrent arm did not produce an outcome"
assert_contains "$(( $(count_lines "$TMP_ROOT/race-a") + $(count_lines "$TMP_ROOT/race-b") ))" 1 \
  "only the winning concurrent registration fires"
pass "concurrent arms publish exactly one complete watch"

# --- the happy path: stable true fires the action exactly once ---------------
H="$TMP_ROOT/h-fire"; new_home "$H"
TRIG="$TMP_ROOT/fire-trigger"
ACTLOG="$TMP_ROOT/fire-act"
when "$H" arm fire --interval 0.1 --stable 2 \
  --condition "$COND" "$TRIG" "$TMP_ROOT/fire-count" \
  --action "$ACT" "$ACTLOG" >/dev/null
pe "$H" reconcile >/dev/null
# Let the runner observe some clean falses before the condition turns true.
wait_for_file "$TMP_ROOT/fire-count" || fail "the condition was never polled"
: > "$TRIG"
wait_for_result "$H" when-fire || fail "no outcome was captured after the condition held"
RESULT=$(first_result "$H" when-fire)
assert_grep 'status: fired' "$RESULT" "the outcome records a fired action"
assert_grep 'action_exit: 0' "$RESULT" "the outcome records the action exit"
assert_grep 'action ran against' "$RESULT" "the outcome carries the action output"
assert_contains "$(when "$H" classify "$RESULT")" fired "classify reads the outcome"
when "$H" terminal "$RESULT" || fail "a fired outcome must be terminal"
# The generic runner retires a terminal source: no restart, no second fire.
for _ in $(seq 1 100); do
  [ ! -e "$H/state/procevent/when-fire.source" ] && break
  sleep 0.1
done
assert_absent "$H/state/procevent/when-fire.source" "a fired watch retires its registration"
pe "$H" reconcile >/dev/null
sleep 0.5
assert_contains "$(count_lines "$ACTLOG")" 1 "the action ran exactly once"
payload=$(wake_payloads "$H")
assert_contains "$payload" "procevent when when-fire 1" "the outcome wake reached the durable queue"
assert_not_contains "$payload" "action ran" "action output never reaches the event line"
out=$(pe "$H" handled when-fire 1)
assert_contains "$out" "handled: when-fire 1" "the outcome acknowledges through the generic channel"
pass "a stable true fires the action exactly once and wakes with the outcome"

# --- a flapping condition never fires ----------------------------------------
H="$TMP_ROOT/h-flap"; new_home "$H"
FLAPLOG="$TMP_ROOT/flap-act"
# True on the first poll only, then false forever: with --stable 2 this must
# never fire.
FLAP="$TMP_ROOT/flap.sh"
cat > "$FLAP" <<'SH'
#!/usr/bin/env bash
counter=$1
echo x >> "$counter"
[ "$(grep -c . "$counter")" -eq 1 ]
SH
chmod +x "$FLAP"
when "$H" arm flap --interval 0.1 --stable 2 \
  --condition "$FLAP" "$TMP_ROOT/flap-count" \
  --action "$ACT" "$FLAPLOG" >/dev/null
pe "$H" reconcile >/dev/null
for _ in $(seq 1 150); do
  [ "$(count_lines "$TMP_ROOT/flap-count")" -ge 5 ] && break
  sleep 0.1
done
[ "$(count_lines "$TMP_ROOT/flap-count")" -ge 5 ] || fail "the flapping condition was not polled enough to judge"
assert_absent "$FLAPLOG" "a one-shot true below the stable count never fires the action"
assert_absent "$H/state/when/when-flap.fired" "no fire was claimed"
when "$H" retire flap >/dev/null
pass "a flapping condition never reaches the action"

# --- an action failure is captured and surfaced, never swallowed -------------
H="$TMP_ROOT/h-actfail"; new_home "$H"
FAILLOG="$TMP_ROOT/actfail-act"
when "$H" arm actfail --interval 0.1 --stable 1 \
  --condition true \
  --action "$ACT" "$FAILLOG" 7 >/dev/null
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-actfail || fail "no outcome was captured for the failing action"
RESULT=$(first_result "$H" when-actfail)
assert_grep 'status: action-failed' "$RESULT" "the outcome records the failure"
assert_grep 'action_exit: 7' "$RESULT" "the outcome records the exact exit code"
assert_contains "$(when "$H" classify "$RESULT")" action-failed "classify distinguishes the failure"
when "$H" terminal "$RESULT" || fail "a failed action outcome must be terminal"
assert_contains "$(count_lines "$FAILLOG")" 1 "the failing action still ran exactly once"
pass "an action failure wakes with the captured error"

# --- a condition that errors past its budget wakes instead of retrying -------
H="$TMP_ROOT/h-conderr"; new_home "$H"
CONDERRLOG="$TMP_ROOT/conderr-act"
BROKEN="$TMP_ROOT/broken.sh"
cat > "$BROKEN" <<'SH'
#!/usr/bin/env bash
echo "cannot reach the service" >&2
exit 3
SH
chmod +x "$BROKEN"
when "$H" arm conderr --interval 0.1 --error-budget 2 \
  --condition "$BROKEN" \
  --action "$ACT" "$CONDERRLOG" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-conderr || fail "no outcome was captured for the erroring condition"
RESULT=$(first_result "$H" when-conderr)
assert_grep 'status: condition-error' "$RESULT" "the outcome records the condition error"
assert_grep 'cannot reach the service' "$RESULT" "the outcome carries the condition diagnostics"
assert_absent "$CONDERRLOG" "an erroring condition never reaches the action"
assert_absent "$H/state/when/when-conderr.fired" "no fire was claimed on an ambiguous condition"
pass "a repeatedly erroring condition wakes firstmate instead of firing"

# --- a deadline that passes wakes with never-true -----------------------------
H="$TMP_ROOT/h-deadline"; new_home "$H"
DEADLOG="$TMP_ROOT/deadline-act"
when "$H" arm deadline --interval 0.1 --deadline 1 \
  --condition false \
  --action "$ACT" "$DEADLOG" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-deadline || fail "no outcome was captured after the deadline"
RESULT=$(first_result "$H" when-deadline)
assert_grep 'status: never-true' "$RESULT" "the outcome records the expired deadline"
assert_absent "$DEADLOG" "the action never ran"
pass "an expired deadline wakes with never-true"

# --- a poll completing true after its deadline cannot fire -------------------
H="$TMP_ROOT/h-late-true"; new_home "$H"
LATELOG="$TMP_ROOT/late-true-act"
LATE="$TMP_ROOT/late-true.sh"
cat > "$LATE" <<'SH'
#!/usr/bin/env bash
sleep 2
exit 0
SH
chmod +x "$LATE"
when "$H" arm late-true --stable 1 --deadline 1 --condition-timeout 3 \
  --condition "$LATE" --action "$ACT" "$LATELOG" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-late-true || fail "no outcome was captured for a condition completing after deadline"
RESULT=$(first_result "$H" when-late-true)
assert_grep 'status: never-true' "$RESULT" "a late true is rejected after the deadline"
assert_absent "$LATELOG" "a condition completing true after deadline never fires"
pass "a late true poll cannot fire after its deadline"

# --- a timed-out action cannot leave descendants running ---------------------
H="$TMP_ROOT/h-timeout"; new_home "$H"
DESCENDANT_EFFECT="$TMP_ROOT/descendant-effect"
DESCENDANT_PID="$TMP_ROOT/descendant-pid"
SPAWNER="$TMP_ROOT/spawner.sh"
cat > "$SPAWNER" <<'SH'
#!/usr/bin/env bash
(
  trap '' TERM
  sleep 10
  printf 'late effect\n' > "$1"
) &
printf '%s\n' "$!" > "$2"
wait
SH
chmod +x "$SPAWNER"
when "$H" arm timeout --stable 1 --action-timeout 1 \
  --condition true --action "$SPAWNER" "$DESCENDANT_EFFECT" "$DESCENDANT_PID" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-timeout || fail "no outcome was captured for the timed-out action"
RESULT=$(first_result "$H" when-timeout)
assert_grep 'status: action-failed' "$RESULT" "the action timeout is captured as a failure"
assert_grep 'action_exit: 124' "$RESULT" "the action timeout uses the shared timeout status"
wait_for_file "$DESCENDANT_PID" || fail "the timeout fixture did not record its descendant"
descendant_pid=$(cat "$DESCENDANT_PID")
for _ in $(seq 1 20); do
  descendant_state=$(ps -o stat= -p "$descendant_pid" 2>/dev/null | tr -d ' ' || true)
  case "$descendant_state" in ''|Z*) break ;; esac
  sleep 0.1
done
descendant_state=$(ps -o stat= -p "$descendant_pid" 2>/dev/null | tr -d ' ' || true)
case "$descendant_state" in
  ''|Z*) ;;
  *)
    kill -KILL "$descendant_pid" 2>/dev/null || true
    fail "a timed-out action left descendant $descendant_pid alive ($descendant_state)"
    ;;
esac
assert_absent "$DESCENDANT_EFFECT" "a timed-out action leaves no descendant effect"
pass "action timeouts terminate the complete process group"

# --- command output staging remains bounded while the command runs -----------
H="$TMP_ROOT/h-bounded-output"; new_home "$H"
NOISY_READY="$TMP_ROOT/noisy-ready"
NOISY="$TMP_ROOT/noisy.sh"
cat > "$NOISY" <<'SH'
#!/usr/bin/env bash
printf 'ready\n' > "$1"
i=0
while [ "$i" -lt 20000 ]; do
  printf '0123456789012345678901234567890123456789\n'
  i=$((i + 1))
done
sleep 1
SH
chmod +x "$NOISY"
FM_WHEN_OUTPUT_TAIL_BYTES=128 when "$H" arm bounded-output --stable 1 \
  --condition true --action "$NOISY" "$NOISY_READY" >/dev/null
FM_WHEN_OUTPUT_TAIL_BYTES=128 pe "$H" reconcile >/dev/null
wait_for_file "$NOISY_READY" || fail "the noisy action did not start"
for staged in "$H/state/when"/.run-out.*; do
  [ -e "$staged" ] || continue
  staged_size=$(wc -c < "$staged" | tr -d ' ')
  [ "$staged_size" -le 128 ] || fail "command output staging exceeded its configured bound"
done
wait_for_result "$H" when-bounded-output || fail "no outcome was captured for the noisy action"
pass "command output staging stays within its byte bound"

# --- a restart after a claimed fire never runs the action twice ---------------
H="$TMP_ROOT/h-crash"; new_home "$H"
CRASHLOG="$TMP_ROOT/crash-act"
when "$H" arm crash --interval 0.1 --stable 1 \
  --condition true \
  --action "$ACT" "$CRASHLOG" >/dev/null
# Simulate a runner that claimed the fire and died before capturing an outcome.
date +%s > "$H/state/when/when-crash.fired"
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-crash || fail "no outcome was captured after the simulated crash"
RESULT=$(first_result "$H" when-crash)
assert_grep 'status: ambiguous' "$RESULT" "the outcome reports the uncaptured earlier fire"
assert_absent "$CRASHLOG" "the action was not fired a second time"
assert_contains "$(when "$H" classify "$RESULT")" ambiguous "classify reads the ambiguity"
when "$H" terminal "$RESULT" || fail "an ambiguous outcome must be terminal"
pass "a restart after a claimed fire reports ambiguity instead of double-firing"

# --- a mutated spec is refused without executing anything ---------------------
H="$TMP_ROOT/h-tamper"; new_home "$H"
TAMPERLOG="$TMP_ROOT/tamper-act"
when "$H" arm tamper --interval 0.1 --stable 1 \
  --condition "$COND" "$TMP_ROOT/tamper-trigger" "$TMP_ROOT/tamper-count" \
  --action "$ACT" "$TAMPERLOG" >/dev/null
# Mutate the registered spec after arming: swap the action for a different one.
perl -pi -e "s/\Qtamper-act\E/tamper-EVIL/" "$H/state/when/when-tamper.spec"
: > "$TMP_ROOT/tamper-trigger"
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-tamper || fail "no outcome was captured for the mutated spec"
RESULT=$(first_result "$H" when-tamper)
assert_grep 'status: rejected' "$RESULT" "the outcome reports the trust refusal"
assert_grep 'trust' "$RESULT" "the refusal names the trust binding"
assert_absent "$TAMPERLOG" "nothing from the original spec was executed"
assert_absent "$TMP_ROOT/tamper-count" "nothing from the mutated spec was executed either"
assert_contains "$(when "$H" classify "$RESULT")" rejected "classify reads the refusal"
pass "a mutated spec is refused without executing anything"

# --- mutated action bytes are refused before the fire is claimed -------------
H="$TMP_ROOT/h-action-tamper"; new_home "$H"
ACTION_TAMPER_LOG="$TMP_ROOT/action-tamper-act"
MUTABLE_ACT="$TMP_ROOT/mutable-act.sh"
cat > "$MUTABLE_ACT" <<'SH'
#!/usr/bin/env bash
printf 'original action ran\n' >> "$1"
SH
chmod +x "$MUTABLE_ACT"
when "$H" arm action-tamper --stable 1 \
  --condition true --action "$MUTABLE_ACT" "$ACTION_TAMPER_LOG" >/dev/null
cat > "$MUTABLE_ACT" <<'SH'
#!/usr/bin/env bash
printf 'mutated action ran\n' >> "$1"
SH
chmod +x "$MUTABLE_ACT"
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-action-tamper || fail "no outcome was captured for the mutated action"
RESULT=$(first_result "$H" when-action-tamper)
assert_grep 'status: rejected' "$RESULT" "the outcome reports the action trust refusal"
assert_grep 'trust binding' "$RESULT" "the refusal names the action trust binding"
assert_absent "$ACTION_TAMPER_LOG" "the mutated action was not executed"
assert_absent "$H/state/when/when-action-tamper.fired" "no fire was claimed for mutated action bytes"
pass "mutated action bytes are refused before claiming the fire"

# --- a state root that is group-writable is refused ----------------------------------
H="$TMP_ROOT/h-group-writable"; new_home "$H"
chmod 775 "$H/state" || fail "could not set group-writable permissions on state directory"
if when "$H" arm group-writable-test --condition true --action true 2>"$TMP_ROOT/group-writable.err"; then
  fail "arming against a group-writable state directory must be refused"
fi
assert_grep "process-event state root is not a private directory" "$TMP_ROOT/group-writable.err" "the refusal names the private-directory failure"
assert_absent "$H/state/when/when-group-writable-test.spec" "no spec file was written"
assert_absent "$H/state/when/when-group-writable-test.trust" "no trust file was written"
assert_absent "$H/state/procevent/when-group-writable-test.source" "no registry file was written"
chmod 700 "$H/state"
pass "a group-writable state root is refused before any files are written"


# --- a state root that turns insecure after arming is no longer swallowed silently ---
H="$TMP_ROOT/h-insecure-after-arm"; new_home "$H"
when "$H" arm survives-relax --interval 0.1 --stable 1 --condition true --action true >/dev/null \
  || fail "could not arm against a private state root"
assert_absent "$H/.procevent-state-insecure" "no insecure marker before the root is relaxed"
chmod 775 "$H/state" || fail "could not relax the state directory to group-writable"
pe "$H" reconcile >/dev/null 2>&1
detected_first=$(awk -F= '$1=="detected"{print $2}' "$H/.procevent-state-insecure" 2>/dev/null)
[ -n "$detected_first" ] || fail "reconcile against an insecure root left no durable record where the caller swallows the failure"
assert_grep "state=$H/state" "$H/.procevent-state-insecure" "the durable record names the offending state root"
printf 'sentinel=first-write\n' >> "$H/.procevent-state-insecure"
pe "$H" reconcile >/dev/null 2>&1
assert_grep "sentinel=first-write" "$H/.procevent-state-insecure" \
  "a repeat failure replaced the durable record instead of keeping the first detection"
detected_second=$(awk -F= '$1=="detected"{print $2}' "$H/.procevent-state-insecure" 2>/dev/null)
[ "$detected_first" = "$detected_second" ] || fail "a repeat failure rewrote the first detection timestamp"
chmod 700 "$H/state" || fail "could not restore private permissions"
pe "$H" reconcile >/dev/null 2>&1 || fail "reconcile against a restored private root should succeed"
assert_absent "$H/.procevent-state-insecure" "the durable record was not cleared once the root is private again"
pass "a state root that turns insecure after arming leaves a durable record instead of vanishing"

# --- the watcher turns the swallowed failure into one delivered wake ----------------
H="$TMP_ROOT/h-watch-insecure"; new_home "$H"
when "$H" arm watch-surfaces --interval 0.1 \
  --condition "$COND" "$TMP_ROOT/never" "$TMP_ROOT/watch-surfaces-count" \
  --action "$ACT" "$TMP_ROOT/watch-surfaces-act" >/dev/null \
  || fail "could not arm against a private state root"
chmod 775 "$H/state" || fail "could not relax the state directory to group-writable"
run_watcher "$H" - 100
assert_present "$H/.procevent-state-insecure" "the watcher's own swallowed reconcile left the durable record"
assert_absent "$H/.procevent-state-insecure-surfaced" \
  "a wake that never reached firstmate latched the one-shot suppressor anyway"

run_watcher "$H" "$TMP_ROOT/watch-insecure.out" 100
assert_grep "check: procevent-state-insecure" "$TMP_ROOT/watch-insecure.out" \
  "the watcher surfaced the state root that stopped being private"
assert_present "$H/.procevent-state-insecure-surfaced" "the delivered wake latched the one-shot suppressor"

queue_procevent_anchor "$H" anchor-again
run_watcher "$H" "$TMP_ROOT/watch-insecure-again.out" 100
assert_grep "process-event result captured" "$TMP_ROOT/watch-insecure-again.out" \
  "the run that must not re-report never completed a cycle past the insecure check"
if grep -Fq "check: procevent-state-insecure" "$TMP_ROOT/watch-insecure-again.out"; then
  fail "the watcher re-reported the same insecure state root on a later cycle"
fi
chmod 700 "$H/state" || fail "could not restore private permissions"
pass "the watcher reports a state root that stopped being private once, only once delivered"

# --- neither marker path can be redirected through a planted symlink ----------------
# A symlink to a DIRECTORY is the sharp case: `mv file link` renames into the
# target directory and leaves the link intact, so the marker never lands where
# its readers look and the suppressor can never commit.
H="$TMP_ROOT/h-marker-symlink-dir"; new_home "$H"
mkdir -p "$H/record-target-dir"
ln -s record-target-dir "$H/.procevent-state-insecure"
chmod 775 "$H/state" || fail "could not relax the state directory to group-writable"
pe "$H" reconcile >/dev/null 2>&1
[ -z "$(ls -A "$H/record-target-dir")" ] || fail "the durable record was written into its symlinked directory"
[ ! -L "$H/.procevent-state-insecure" ] || fail "the durable record stayed a symlink to a directory"
assert_grep "state=$H/state" "$H/.procevent-state-insecure" \
  "the record replacing a symlinked directory names the offending state root"

mkdir -p "$H/surfaced-target-dir"
ln -s surfaced-target-dir "$H/.procevent-state-insecure-surfaced"
run_watcher "$H" "$TMP_ROOT/watch-symlink-dir.out" 100
assert_grep "check: procevent-state-insecure" "$TMP_ROOT/watch-symlink-dir.out" \
  "a symlinked directory at the suppressor path silenced the wake"
[ -z "$(ls -A "$H/surfaced-target-dir")" ] || fail "the suppressor was written into its symlinked directory"
[ ! -L "$H/.procevent-state-insecure-surfaced" ] || fail "the suppressor stayed a symlink to a directory"
queue_procevent_anchor "$H" anchor-symlink-dir
run_watcher "$H" "$TMP_ROOT/watch-symlink-dir-again.out" 100
assert_grep "process-event result captured" "$TMP_ROOT/watch-symlink-dir-again.out" \
  "the run that must not re-report never completed a cycle past the insecure check"
if grep -Fq "check: procevent-state-insecure" "$TMP_ROOT/watch-symlink-dir-again.out"; then
  fail "the suppressor never committed, so the watcher woke again every cycle"
fi
chmod 700 "$H/state" || fail "could not restore private permissions"
pass "a symlinked directory at either marker path is replaced, not written into"

H="$TMP_ROOT/h-marker-symlink"; new_home "$H"
ln -s marker-target "$H/.procevent-state-insecure"
chmod 775 "$H/state" || fail "could not relax the state directory to group-writable"
pe "$H" reconcile >/dev/null 2>&1
[ ! -e "$H/marker-target" ] || fail "the durable record wrote through its dangling symlink target"
[ ! -L "$H/.procevent-state-insecure" ] || fail "the durable record stayed a symlink"
assert_grep "state=$H/state" "$H/.procevent-state-insecure" "the replacing record names the offending state root"

printf 'preserve me too\n' > "$H/surfaced-target"
ln -s surfaced-target "$H/.procevent-state-insecure-surfaced"
run_watcher "$H" "$TMP_ROOT/watch-symlink.out" 100
assert_grep "check: procevent-state-insecure" "$TMP_ROOT/watch-symlink.out" \
  "a symlink planted at the suppressor path silenced the wake"
[ "$(cat "$H/surfaced-target")" = 'preserve me too' ] || fail "the suppressor wrote through its symlink target"
[ ! -L "$H/.procevent-state-insecure-surfaced" ] || fail "the suppressor stayed a symlink"
chmod 700 "$H/state" || fail "could not restore private permissions"
pass "a planted symlink cannot redirect or silence either marker"

# --- a plain directory at either marker path cannot silence the mechanism -----------
H="$TMP_ROOT/h-marker-dir"; new_home "$H"
mkdir "$H/.procevent-state-insecure"
chmod 775 "$H/state" || fail "could not relax the state directory to group-writable"
pe "$H" reconcile >/dev/null 2>&1
[ ! -d "$H/.procevent-state-insecure" ] || fail "a directory at the record path was read as a valid record"
assert_grep "state=$H/state" "$H/.procevent-state-insecure" \
  "the record replacing a directory names the offending state root"

mkdir "$H/.procevent-state-insecure-surfaced"
run_watcher "$H" "$TMP_ROOT/watch-marker-dir.out" 100
assert_grep "check: procevent-state-insecure" "$TMP_ROOT/watch-marker-dir.out" \
  "a directory at the suppressor path silenced the wake"
[ ! -d "$H/.procevent-state-insecure-surfaced" ] || fail "the suppressor stayed a directory"
queue_procevent_anchor "$H" anchor-marker-dir
run_watcher "$H" "$TMP_ROOT/watch-marker-dir-again.out" 100
assert_grep "process-event result captured" "$TMP_ROOT/watch-marker-dir-again.out" \
  "the run that must not re-report never completed a cycle past the insecure check"
if grep -Fq "check: procevent-state-insecure" "$TMP_ROOT/watch-marker-dir-again.out"; then
  fail "the suppressor never committed, so the watcher woke again every cycle"
fi
chmod 700 "$H/state" || fail "could not restore private permissions"
pe "$H" reconcile >/dev/null 2>&1 || fail "reconcile against a restored private root should succeed"
assert_absent "$H/.procevent-state-insecure" "the record replacing a directory was never cleared"
pass "a directory at either marker path is replaced, not treated as a valid marker"

# --- a non-empty directory at either marker path cannot silence the mechanism -------
# Its contents are not this code's to delete, so the path is freed by moving the
# directory aside; nothing it held may be lost.
H="$TMP_ROOT/h-marker-dir-nonempty"; new_home "$H"
mkdir -p "$H/.procevent-state-insecure/kept"
printf 'do not lose me\n' > "$H/.procevent-state-insecure/kept/payload"
chmod 775 "$H/state" || fail "could not relax the state directory to group-writable"
pe "$H" reconcile >/dev/null 2>&1
[ ! -d "$H/.procevent-state-insecure" ] \
  || fail "a non-empty directory at the record path was read as a valid record"
assert_grep "state=$H/state" "$H/.procevent-state-insecure" \
  "the record replacing a non-empty directory names the offending state root"
displaced=$(printf '%s\n' "$H"/.procevent-state-insecure.displaced-* | head -1)
[ "$(cat "$displaced/kept/payload" 2>/dev/null)" = 'do not lose me' ] \
  || fail "the displaced directory's contents were destroyed instead of moved aside"

mkdir -p "$H/.procevent-state-insecure-surfaced/kept"
run_watcher "$H" "$TMP_ROOT/watch-dir-nonempty.out" 100
assert_grep "check: procevent-state-insecure" "$TMP_ROOT/watch-dir-nonempty.out" \
  "a non-empty directory at the suppressor path silenced the wake"
[ ! -d "$H/.procevent-state-insecure-surfaced" ] || fail "the suppressor stayed a directory"
queue_procevent_anchor "$H" anchor-dir-nonempty
run_watcher "$H" "$TMP_ROOT/watch-dir-nonempty-again.out" 100
assert_grep "process-event result captured" "$TMP_ROOT/watch-dir-nonempty-again.out" \
  "the run that must not re-report never completed a cycle past the insecure check"
if grep -Fq "check: procevent-state-insecure" "$TMP_ROOT/watch-dir-nonempty-again.out"; then
  fail "the suppressor never committed, so the watcher woke again every cycle"
fi
chmod 700 "$H/state" || fail "could not restore private permissions"
pe "$H" reconcile >/dev/null 2>&1 || fail "reconcile against a restored private root should succeed"
assert_absent "$H/.procevent-state-insecure" "the record was never cleared once the root was private"
pass "a non-empty directory at either marker path is moved aside, not treated as a marker"

# --- a non-empty directory at the record path never invents a wake -----------------
H="$TMP_ROOT/h-marker-dir-noalarm"; new_home "$H"
mkdir -p "$H/.procevent-state-insecure/kept"
pe "$H" reconcile >/dev/null 2>&1 || fail "reconcile against a private root should succeed"
queue_procevent_anchor "$H" anchor-noalarm
run_watcher "$H" "$TMP_ROOT/watch-dir-noalarm.out" 100
assert_grep "process-event result captured" "$TMP_ROOT/watch-dir-noalarm.out" \
  "the run never completed a cycle past the insecure check"
if grep -Fq "check: procevent-state-insecure" "$TMP_ROOT/watch-dir-noalarm.out"; then
  fail "a directory at the record path made the watcher report a private root as insecure"
fi
pass "a directory at the record path cannot claim a private state root stopped being private"

# --- a stale success never erases a record a concurrent command just wrote --------
# The retire path runs after its own successful observation of the root, so a
# record that appeared or was replaced since that observation describes a root
# that stopped being private afterwards. Retiring on the record's identity
# rather than its mere presence is what keeps that newer record standing.
in_lib() {  # <argv...>
  FM_HOME="$TMP_ROOT" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fn=$2; shift 2; "$fn" "$@"
  ' _ "$ROOT" "$@"
}

H="$TMP_ROOT/h-retire-race"; new_home "$H"
M="$H/.procevent-state-insecure"
printf 'fm-procevent-state-insecure-v1\ndetected=1\nstate=%s\n' "$H/state" > "$M"
printf 'fm-procevent-state-insecure-surfaced-v1\n' > "$M-surfaced"
seen=$(in_lib fm_procevent_insecure_marker_identity "$M")
[ "$seen" != absent ] || fail "the snapshot did not identify the record it saw"
printf 'fm-procevent-state-insecure-v1\ndetected=2\nstate=%s\n' "$H/state" > "$M.newer"
mv -f "$M.newer" "$M"
in_lib fm_procevent_insecure_marker_retire "$M" "$seen"
assert_present "$M" "a record written after the observation was erased by a stale success"
assert_grep "detected=2" "$M" "the surviving record is the newer detection"
assert_present "$M-surfaced" "the suppressor was retired against a record the run never saw"
pass "a stale success leaves a newer insecure-root record standing"

# --- the record a run did see is still retired once the root is private again -----
seen=$(in_lib fm_procevent_insecure_marker_identity "$M")
in_lib fm_procevent_insecure_marker_retire "$M" "$seen"
assert_absent "$M" "the record the run saw before observing a private root was not retired"
assert_absent "$M-surfaced" "the one-shot suppressor outlived the record it suppressed"
pass "the record a run saw before a private observation is retired with its suppressor"

# --- a record written while the retire is deciding still stands -------------------
# The stub stands in for a concurrent failing command that records at exactly the
# instant the retire inspects the record it claimed; the retire must not erase it.
H="$TMP_ROOT/h-retire-race-window"; new_home "$H"
M="$H/.procevent-state-insecure"
printf 'fm-procevent-state-insecure-v1\ndetected=1\nstate=%s\n' "$H/state" > "$M"
seen=$(in_lib fm_procevent_insecure_marker_identity "$M")
FM_HOME="$TMP_ROOT" bash -c '
  . "$1/bin/fm-pr-lib.sh"
  . "$1/bin/fm-wake-lib.sh"
  . "$1/bin/fm-procevent-lib.sh"
  marker=$2
  eval "$(declare -f fm_pr_file_identity | sed "1s/^fm_pr_file_identity/fm_pr_file_identity_real/")"
  fm_pr_file_identity() {
    local rc out
    out=$(fm_pr_file_identity_real "$1"); rc=$?
    if [ ! -e "$marker.raced" ]; then
      : > "$marker.raced"
      printf "fm-procevent-state-insecure-v1\ndetected=2\nstate=concurrent\n" > "$marker.newer"
      mv -f "$marker.newer" "$marker"
    fi
    printf "%s\n" "$out"
    return "$rc"
  }
  fm_procevent_insecure_marker_retire "$marker" "$3"
' _ "$ROOT" "$M" "$seen"
assert_present "$M" "the record written during the retire's own decision was erased"
assert_grep "state=concurrent" "$M" "the surviving record is the one written during the decision"
pass "a record written while a retire decides is not erased by that retire"

# --- a record that appears while a run with no record of its own retires ----------
# The snapshot was `absent`, so nothing of this run's is at the path; a concurrent
# failing command lands its record there while the retire is still running. The
# stub installs it on the retire's first fm_marker_clear, which is the exact
# instant the previous code unlinked the path.
H="$TMP_ROOT/h-retire-race-absent"; new_home "$H"
M="$H/.procevent-state-insecure"
printf 'fm-procevent-state-insecure-surfaced-v1\n' > "$M-surfaced"
seen=$(in_lib fm_procevent_insecure_marker_identity "$M")
[ "$seen" = absent ] || fail "the snapshot claimed a record where none exists"
FM_HOME="$TMP_ROOT" bash -c '
  . "$1/bin/fm-pr-lib.sh"
  . "$1/bin/fm-wake-lib.sh"
  . "$1/bin/fm-procevent-lib.sh"
  marker=$2
  eval "$(declare -f fm_marker_clear | sed "1s/^fm_marker_clear/fm_marker_clear_real/")"
  fm_marker_clear() {
    if [ ! -e "$marker.raced" ]; then
      : > "$marker.raced"
      printf "fm-procevent-state-insecure-v1\ndetected=2\nstate=concurrent\n" > "$marker.newer"
      mv -f "$marker.newer" "$marker"
    fi
    fm_marker_clear_real "$@"
  }
  fm_procevent_insecure_marker_retire "$marker" "$3"
' _ "$ROOT" "$M" "$seen"
assert_present "$M" "a record that appeared during a no-record retire was erased"
assert_grep "state=concurrent" "$M" "the surviving record is the one written during the retire"
assert_absent "$M-surfaced" "the stale suppressor outlived the record it suppressed"
pass "a retire that saw no record cannot erase one that appears while it runs"

printf 'all fm-procevent-when tests passed\n'
