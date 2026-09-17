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
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

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

# --- rebind-all refreshes a watch's action hash after a self-update ----------
# A self-update fast-forwards bin/ in place, changing an in-repo action
# executable's bytes with no tampering involved. Without rebind-all the next
# fire is refused as "does not match the registered trust binding" (see the
# mutated-action-bytes case above); rebind-all exists to follow that update
# and republish a trust binding that matches the new bytes, but only for an
# action living under the simulated repo root, never for one outside it.
H="$TMP_ROOT/h-rebind"; new_home "$H"
REPO_ROOT="$TMP_ROOT/rebind-repo"
mkdir -p "$REPO_ROOT/bin"
IN_REPO_ACT="$REPO_ROOT/bin/act.sh"
cat > "$IN_REPO_ACT" <<'SH'
#!/usr/bin/env bash
log=$1
echo v1 >> "$log"
SH
chmod +x "$IN_REPO_ACT"
OUT_OF_REPO_ACT="$TMP_ROOT/rebind-outside-act.sh"
cat > "$OUT_OF_REPO_ACT" <<'SH'
#!/usr/bin/env bash
log=$1
echo v1 >> "$log"
SH
chmod +x "$OUT_OF_REPO_ACT"
when_ro() { FM_HOME="$1" FM_ROOT_OVERRIDE="$REPO_ROOT" "$ROOT/bin/fm-procevent-when.sh" "${@:2}"; }

when_ro "$H" arm rebind-in-repo --interval 0.1 --stable 1 \
  --condition true --action "$IN_REPO_ACT" "$TMP_ROOT/rebind-in-repo.log" >/dev/null
when_ro "$H" arm rebind-out-of-repo --interval 0.1 --stable 1 \
  --condition true --action "$OUT_OF_REPO_ACT" "$TMP_ROOT/rebind-out-of-repo.log" >/dev/null

SPEC_IN="$H/state/when/when-rebind-in-repo.spec"
TRUST_IN="$H/state/when/when-rebind-in-repo.trust"
TRUST_OUT="$H/state/when/when-rebind-out-of-repo.trust"

OUT=$(when_ro "$H" rebind-all) || fail "rebind-all failed with nothing to rebind: $OUT"
assert_contains "$OUT" "0 rebound, 2 unchanged or out of scope, 0 failed" \
  "rebind-all should be a no-op before any action bytes change"

# Simulate the self-update: rewrite both action scripts' bytes in place.
OLD_IN_REPO_SHA=$(fm_pr_sha256 "$IN_REPO_ACT")
cat > "$IN_REPO_ACT" <<'SH'
#!/usr/bin/env bash
log=$1
echo v2 >> "$log"
echo "action ran v2 against $log"
SH
chmod +x "$IN_REPO_ACT"
NEW_HASH=$(fm_pr_sha256 "$IN_REPO_ACT")
[ "$OLD_IN_REPO_SHA" != "$NEW_HASH" ] || fail "test fixture error: mutation did not change the in-repo action's hash"
printf "#!/usr/bin/env bash\necho v2 >> \"\$1\"\n" > "$OUT_OF_REPO_ACT"
chmod +x "$OUT_OF_REPO_ACT"

OLD_TRUST_OUT=$(cat "$TRUST_OUT")
OUT=$(when_ro "$H" rebind-all) || fail "rebind-all reported a failure: $OUT"
assert_contains "$OUT" "rebound: when-rebind-in-repo" "the in-repo watch was rebound"
assert_contains "$OUT" "1 rebound, 1 unchanged or out of scope, 0 failed" \
  "exactly the in-repo watch should rebind; the out-of-repo one stays out of scope"
[ "$(cat "$TRUST_OUT")" = "$OLD_TRUST_OUT" ] \
  || fail "rebind-all must never touch a watch whose action lives outside FM_ROOT"

grep -qx "action_sha256=$NEW_HASH" "$SPEC_IN" \
  || fail "rebind-all did not record the action's current bytes in the spec"
SPEC_HASH=$(fm_pr_sha256 "$SPEC_IN")
TRUST_WANT=$(sed -n '2p' "$TRUST_IN")
[ "$SPEC_HASH" = "$TRUST_WANT" ] \
  || fail "the republished spec must still match its own trust binding"

# The watch actually works again: a fresh run fires cleanly against the new
# bytes instead of being rejected.
pe "$H" reconcile >/dev/null
wait_for_result "$H" "when-rebind-in-repo" || fail "the rebound watch captured no outcome"
RESULT=$(first_result "$H" "when-rebind-in-repo")
assert_grep 'status: fired' "$RESULT" "the rebound watch fires instead of being rejected"
assert_grep 'action ran v2 against' "$RESULT" "the fired action ran the new bytes, not a stale copy"
pass "rebind-all refreshes an in-repo watch's trust binding after a self-update and leaves an out-of-repo one alone"

# --- rebind-all matches an action reached through a symlinked FM_ROOT -------
H="$TMP_ROOT/h-rebind-symlink"; new_home "$H"
REPO_REAL="$TMP_ROOT/rebind-symlink-real"
mkdir -p "$REPO_REAL/bin"
REPO_LINK="$TMP_ROOT/rebind-symlink-link"
ln -s "$REPO_REAL" "$REPO_LINK"
SYMLINK_ACT="$REPO_LINK/bin/act.sh"
cat > "$REPO_REAL/bin/act.sh" <<'SH'
#!/usr/bin/env bash
log=$1
echo v1 >> "$log"
SH
chmod +x "$REPO_REAL/bin/act.sh"
when_symlink_ro() { FM_HOME="$1" FM_ROOT_OVERRIDE="$REPO_LINK" "$ROOT/bin/fm-procevent-when.sh" "${@:2}"; }

when_symlink_ro "$H" arm rebind-symlink --interval 0.1 --stable 1 \
  --condition true --action "$SYMLINK_ACT" "$TMP_ROOT/rebind-symlink.log" >/dev/null

cat > "$REPO_REAL/bin/act.sh" <<'SH'
#!/usr/bin/env bash
log=$1
echo v2 >> "$log"
SH
chmod +x "$REPO_REAL/bin/act.sh"

OUT=$(when_symlink_ro "$H" rebind-all) || fail "rebind-all reported a failure through a symlinked FM_ROOT: $OUT"
assert_contains "$OUT" "rebound: when-rebind-symlink" \
  "rebind-all must rebind an action reached through a symlinked FM_ROOT, not report it out of scope"
pass "rebind-all matches FM_ROOT through a symlinked checkout path"

# --- rebind-all reaches a watch whose poller is already running -------------
# The self-update race the fire-time revalidation targets: `run` calls
# spec_load once before entering its poll loop and caches the action hash in
# memory for the rest of its life. If the self-update (and its rebind-all)
# land while that poll loop is still running, only rewriting the on-disk spec
# and trust is not enough - the fire-time check must re-read the binding from
# disk, or the still-running poller compares against its stale in-memory hash
# and rejects a perfectly legitimate post-update fire.
H="$TMP_ROOT/h-live-rebind"; new_home "$H"
REPO_ROOT="$TMP_ROOT/live-rebind-repo"
mkdir -p "$REPO_ROOT/bin"
LIVE_ACT="$REPO_ROOT/bin/act.sh"
cat > "$LIVE_ACT" <<'SH'
#!/usr/bin/env bash
echo v1 >> "$1"
echo "v1 ran against $1"
SH
chmod +x "$LIVE_ACT"
LIVE_TRIGGER="$TMP_ROOT/live-rebind-trigger"
LIVE_COUNTER="$TMP_ROOT/live-rebind-count"
LIVE_LOG="$TMP_ROOT/live-rebind.log"
when_live_ro() { FM_HOME="$1" FM_ROOT_OVERRIDE="$REPO_ROOT" "$ROOT/bin/fm-procevent-when.sh" "${@:2}"; }

when_live_ro "$H" arm live-rebind --interval 0.1 --stable 1 \
  --condition "$COND" "$LIVE_TRIGGER" "$LIVE_COUNTER" \
  --action "$LIVE_ACT" "$LIVE_LOG" >/dev/null

# Start the poller now, before the simulated self-update, so its one-time
# spec_load caches the pre-update (v1) action hash in memory.
pe "$H" reconcile >/dev/null
wait_for_file "$LIVE_COUNTER" || fail "the live-rebind poller never evaluated its condition"

# Simulate the self-update while that poller is still running: rewrite the
# action's bytes in place, then rebind-all republishes the on-disk trust
# binding to match. The already-running poller's in-memory hash is untouched.
cat > "$LIVE_ACT" <<'SH'
#!/usr/bin/env bash
echo v2 >> "$1"
echo "v2 ran against $1"
SH
chmod +x "$LIVE_ACT"
OUT=$(when_live_ro "$H" rebind-all) || fail "rebind-all reported a failure during a live poll: $OUT"
assert_contains "$OUT" "rebound: when-live-rebind" "the live watch's trust binding was rebound on disk"

# Let the condition go true; the still-running poller must pick up the fresh
# binding at fire time instead of comparing against its stale cached hash.
: > "$LIVE_TRIGGER"
wait_for_result "$H" when-live-rebind || fail "the live poller never captured an outcome after rebind-all"
RESULT=$(first_result "$H" when-live-rebind)
assert_grep 'status: fired' "$RESULT" \
  "a watch whose poller was already running when rebind-all ran must still fire, not be rejected as stale"
assert_grep 'v2 ran against' "$RESULT" "the fired action ran the post-update bytes, not the ones cached at poll start"
pass "rebind-all reaches a watch whose run process was already polling when the self-update landed"

# --- the fire-time reload never observes rebind_one's publish mid-rename ----
# publish_spec is not an atomic swap: it renames the new spec into place, then
# separately renames the new trust into place. A `run` process reloading the
# binding at fire time must serialize against that window instead of reading
# a spec already rebound to v2 next to a trust record still bound to v1 - the
# exact torn combination that would otherwise report the rebind itself as a
# trust violation. This test builds that torn state under a held per-sid lock
# (the same lock rebind_one takes) so the reload's timing is deterministic,
# not a race that only sometimes reproduces.
H="$TMP_ROOT/h-torn-race"; new_home "$H"
TORN_ACT="$TMP_ROOT/torn-act.sh"
cat > "$TORN_ACT" <<'SH'
#!/usr/bin/env bash
echo v1 >> "$1"
echo "v1 ran against $1"
SH
chmod +x "$TORN_ACT"
TORN_TRIGGER="$TMP_ROOT/torn-race-trigger"
TORN_COUNTER="$TMP_ROOT/torn-race-count"
TORN_LOG="$TMP_ROOT/torn-race.log"
when "$H" arm torn-race --interval 0.05 --stable 1 \
  --condition "$COND" "$TORN_TRIGGER" "$TORN_COUNTER" \
  --action "$TORN_ACT" "$TORN_LOG" >/dev/null
SID=$(when "$H" source-id torn-race)
SPEC_TORN="$H/state/when/$SID.spec"
TRUST_TORN="$H/state/when/$SID.trust"

# Start the poller now, with the condition still false, so reconcile's own
# brief use of this same per-sid lock (to claim and launch the source) is
# already done and released well before the holder below ever takes it.
pe "$H" reconcile >/dev/null
wait_for_file "$TORN_COUNTER" || fail "the torn-race poller never evaluated its condition"

# Simulate the self-update, then build the rebound (v2) spec+trust pair ahead
# of time exactly as publish_spec would (same fields, only action_sha256
# differs), so the background holder below only performs the two renames.
cat > "$TORN_ACT" <<'SH'
#!/usr/bin/env bash
echo v2 >> "$1"
echo "v2 ran against $1"
SH
chmod +x "$TORN_ACT"
NEW_HASH=$(fm_pr_sha256 "$TORN_ACT")
NEW_SPEC="$TMP_ROOT/torn-race-new.spec"
sed "s/^action_sha256=.*/action_sha256=$NEW_HASH/" "$SPEC_TORN" > "$NEW_SPEC"
NEW_SPEC_HASH=$(fm_pr_sha256 "$NEW_SPEC")
NEW_TRUST="$TMP_ROOT/torn-race-new.trust"
printf 'fm-when-trust-v1\n%s\n' "$NEW_SPEC_HASH" > "$NEW_TRUST"
chmod 0600 "$NEW_SPEC" "$NEW_TRUST"

TORN_READY="$TMP_ROOT/torn-ready"
TORN_RELEASE="$TMP_ROOT/torn-release"
rm -f "$TORN_READY" "$TORN_RELEASE"
parent=$$
FM_HOME="$TMP_ROOT/torn-race-lock-helper-home" bash -c '
  . "$1/bin/fm-pr-lib.sh"
  . "$1/bin/fm-wake-lib.sh"
  . "$1/bin/fm-procevent-lib.sh"
  fm_procevent_source_lock_acquire "$2" || exit 1
  trap "fm_procevent_source_lock_release \"$2\"" EXIT
  mv -f -- "$3" "$5"
  printf "ready\n" > "$6"
  while [ ! -e "$7" ]; do
    kill -0 "$8" 2>/dev/null || exit 0
    sleep 0.02
  done
  mv -f -- "$4" "$9"
' _ "$ROOT" "$SID" "$NEW_SPEC" "$NEW_TRUST" "$SPEC_TORN" "$TORN_READY" "$TORN_RELEASE" "$parent" "$TRUST_TORN" &
HOLDER_PID=$!

wait_for_file "$TORN_READY" || fail "the torn-write holder never installed the rebound spec"
grep -qx "action_sha256=$NEW_HASH" "$SPEC_TORN" \
  || fail "test fixture error: the torn window did not actually install the rebound spec"
[ "$(sed -n '2p' "$TRUST_TORN")" != "$NEW_SPEC_HASH" ] \
  || fail "test fixture error: the trust file was rebound before the torn window began"

# The still-running poller now sees its condition go true and reaches the
# fire-time reload while the torn state above is live and the lock is held.
: > "$TORN_TRIGGER"
sleep 0.3
if first_result "$H" "$SID" >/dev/null 2>&1; then
  fail "the reload must block on the source lock instead of reading the torn spec/trust pair"
fi

: > "$TORN_RELEASE"
wait "$HOLDER_PID" 2>/dev/null || true
wait_for_result "$H" "$SID" || fail "the watch never captured an outcome after the torn window closed"
RESULT=$(first_result "$H" "$SID")
assert_grep 'status: fired' "$RESULT" \
  "the reload must wait past the torn spec/trust window, not reject a legitimate rebind mid-publish"
assert_grep 'v2 ran against' "$RESULT" "the fired action ran the rebound (v2) bytes, not a rejection from a torn read"
pass "the fire-time reload never observes rebind_one's spec/trust publish mid-rename"

printf 'all fm-procevent-when tests passed\n'
