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

# --- an action environment reaches the action, and its NAME is validated ------
H="$TMP_ROOT/h-action-env"; new_home "$H"
ENVLOG="$TMP_ROOT/action-env-act"
# An action that records the one variable the assignment carries, so "the
# environment reached the action" is observable rather than inferred.
ENVACT="$TMP_ROOT/env-act.sh"
cat > "$ENVACT" <<'SH'
#!/usr/bin/env bash
printf 'FM_TEST_HOME=%s\n' "${FM_TEST_HOME:-unset}" >> "$1"
SH
chmod +x "$ENVACT"
if when "$H" arm bad-env --action-env 'not a name=x' \
  --condition true --action "$ENVACT" "$ENVLOG" 2>"$TMP_ROOT/bad-env.err"; then
  fail "an assignment with an invalid NAME must be refused"
fi
assert_grep 'action-env' "$TMP_ROOT/bad-env.err" "the refusal names the offending option"
# A shell-safe NAME is not enough: an interpreter/loader-hijacking name must be
# refused too, or the argv[0] trust binding is worthless for any action that is
# itself a `#!/usr/bin/env`-shebang script.
if when "$H" arm hijack-env --action-env 'LD_PRELOAD=/tmp/evil.so' \
  --condition true --action "$ENVACT" "$ENVLOG" 2>"$TMP_ROOT/hijack-env.err"; then
  fail "an interpreter/loader-hijacking NAME must be refused"
fi
assert_grep 'action-env' "$TMP_ROOT/hijack-env.err" "the LD_PRELOAD refusal names the offending option"
assert_absent "$H/state/when/when-hijack-env.spec" "a refused LD_PRELOAD assignment is never armed"
if when "$H" arm hijack-path --action-env 'PATH=/tmp/evil-bin' \
  --condition true --action "$ENVACT" "$ENVLOG" 2>"$TMP_ROOT/hijack-path.err"; then
  fail "a PATH action-env assignment must be refused"
fi
assert_grep 'action-env' "$TMP_ROOT/hijack-path.err" "the PATH refusal names the offending option"
when "$H" arm action-env --interval 0.1 --stable 1 \
  --action-env "FM_TEST_HOME=$H" \
  --condition true --action "$ENVACT" "$ENVLOG" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-action-env || fail "the action-env watch produced no outcome"
assert_grep "FM_TEST_HOME=$H" "$ENVLOG" "the action ran under the registered assignment"
RESULT=$(first_result "$H" when-action-env)
assert_grep 'status: fired' "$RESULT" "an action with an environment still fires normally"
pass "an action environment reaches the action and an invalid NAME is refused"

# --- a repeat watch rings again after each fire, silently --------------------
# The condition is true exactly while a trigger file exists, so the test drives
# the watch through two independent "changes" and can prove the second ring is
# a real re-arm rather than a leftover from the first.
H="$TMP_ROOT/h-repeat"; new_home "$H"
REPEAT_TRIG="$TMP_ROOT/repeat-trigger"
REPEATLOG="$TMP_ROOT/repeat-act"
when "$H" arm repeat --interval 0.1 --stable 1 --repeat \
  --condition "$COND" "$REPEAT_TRIG" "$TMP_ROOT/repeat-count" \
  --action "$ACT" "$REPEATLOG" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_file "$TMP_ROOT/repeat-count" || fail "the repeat condition was never polled"
: > "$REPEAT_TRIG"
wait_for_result "$H" when-repeat || fail "the repeat watch captured no first outcome"
RESULT=$(first_result "$H" when-repeat)
assert_grep 'status: fired' "$RESULT" "the first repeat fire is recorded as fired"
assert_grep 'repeat: continues' "$RESULT" "the first repeat fire declares that the watch continues"
assert_contains "$(when "$H" classify "$RESULT")" fired "classify still reads a repeat fire as fired"
if when "$H" terminal "$RESULT"; then
  fail "a repeat watch's successful fire must not be terminal"
fi
when "$H" silent "$RESULT" || fail "a repeat watch's successful fire must be silent"
assert_present "$H/state/when/when-repeat.fires" "the fire journal records the fire"
# The registration survives, because only a terminal outcome retires a source.
assert_present "$H/state/procevent/when-repeat.source" "a repeat fire keeps the watch registered"
# Nothing woke firstmate, and the runner acknowledged the outcome itself, so a
# later reconcile cannot re-announce it either.
assert_not_contains "$(wake_payloads "$H")" "procevent when when-repeat" \
  "a successful repeat fire never reaches the durable wake queue"
SEQ=$(basename "$RESULT" | sed 's/^when-repeat\.//; s/\.result$//')
assert_contains "$(pe "$H" handled when-repeat "$SEQ")" "already-handled" \
  "the runner recorded the silent repeat fire as handled itself"
# A second change must ring again, which only a re-armed watch can do.
rm -f -- "$REPEAT_TRIG"
for _ in $(seq 1 150); do
  [ "$(count_lines "$REPEATLOG")" -ge 1 ] && break
  sleep 0.1
done
: > "$REPEAT_TRIG"
for _ in $(seq 1 150); do
  [ "$(count_lines "$REPEATLOG")" -ge 2 ] && break
  pe "$H" reconcile >/dev/null 2>&1
  sleep 0.1
done
[ "$(count_lines "$REPEATLOG")" -ge 2 ] || fail "the repeat watch never rang a second time"
assert_not_contains "$(wake_payloads "$H")" "procevent when when-repeat" \
  "no repeat fire wakes firstmate"
pass "a repeat watch rings again after each fire without waking firstmate"

# --- retire stops a repeat watch ---------------------------------------------
STOPPED=$(count_lines "$REPEATLOG")
when "$H" retire repeat >/dev/null
assert_absent "$H/state/procevent/when-repeat.source" "retire drops the repeat registration"
assert_absent "$H/state/when/when-repeat.fires" "retire removes the fire journal"
pe "$H" reconcile >/dev/null
sleep 0.6
assert_contains "$(count_lines "$REPEATLOG")" "$STOPPED" "a retired repeat watch never rings again"
pass "retire stops a repeat watch"

# --- a failing action still ends a repeat watch and wakes firstmate ----------
H="$TMP_ROOT/h-repeat-fail"; new_home "$H"
REPEATFAILLOG="$TMP_ROOT/repeat-fail-act"
when "$H" arm repeat-fail --interval 0.1 --stable 1 --repeat \
  --condition true --action "$ACT" "$REPEATFAILLOG" 9 >/dev/null
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-repeat-fail || fail "the failing repeat action captured no outcome"
RESULT=$(first_result "$H" when-repeat-fail)
assert_grep 'status: action-failed' "$RESULT" "the failure is captured under repeat too"
assert_grep 'action_exit: 9' "$RESULT" "the exact exit code survives"
when "$H" terminal "$RESULT" || fail "a failed action must stay terminal under repeat"
if when "$H" silent "$RESULT"; then
  fail "a failed action must never be silenced"
fi
for _ in $(seq 1 100); do
  [ ! -e "$H/state/procevent/when-repeat-fail.source" ] && break
  sleep 0.1
done
assert_absent "$H/state/procevent/when-repeat-fail.source" "a failed repeat watch retires itself"
assert_contains "$(wake_payloads "$H")" "procevent when when-repeat-fail" \
  "the failure reaches the durable wake queue"
pass "a failing action ends a repeat watch and wakes firstmate"

# --- the shape fm-spawn arms: a repeat watch whose action rings a task -------
# fm-spawn arms this watch for every no-mistakes ship, and fm-send refuses to
# resolve a target without an explicit FM_HOME, so the assignment is what makes
# the ring land at all. This exercises that exact shape end to end rather than
# reading fm-spawn's source.
H="$TMP_ROOT/h-spawn-shape"; new_home "$H"
RING_TASK=ring-task
printf 'window=none\nbackend=tmux\n' > "$H/state/$RING_TASK.meta"
when "$H" arm "nm-state-$RING_TASK" --interval 0.1 --stable 1 --repeat \
  --action-env "FM_HOME=$H" \
  --condition true \
  --action "$ROOT/bin/fm-send.sh" "$RING_TASK" 'no-mistakes state changed' >/dev/null
pe "$H" reconcile >/dev/null
wait_for_result "$H" "when-nm-state-$RING_TASK" || fail "the spawn-shaped watch captured no outcome"
RESULT=$(first_result "$H" "when-nm-state-$RING_TASK")
assert_grep 'status: fired' "$RESULT" "the ring succeeded, so FM_HOME reached fm-send"
assert_grep 'repeat: continues' "$RESULT" "the spawn-shaped watch keeps watching"
assert_present "$H/state/$RING_TASK.inbox" "the ring landed in the task's steering inbox"
when "$H" retire "nm-state-$RING_TASK" >/dev/null
pass "the watch shape fm-spawn arms rings a task and keeps watching"

printf 'all fm-procevent-when tests passed\n'
