#!/usr/bin/env bash
# tests/fm-startup-network.test.sh - behavior tests for bin/fm-startup-network.sh,
# the deferred network stage a session start launches instead of running its
# network work on the blocking path.
#
# The session-start suite proves the digest no longer waits and that the deferred
# sweeps still land. This suite pins the stage's own contract, whose whole job is
# to make deferral safe:
#   - `start` returns immediately and does not hold the caller's stdout open,
#     which is what would strand a session-open hook behind the worker
#   - a durable acknowledgement after harvest prints a finished result suppresses
#     the wake, while an unacknowledged result always produces one
#   - mutating sweeps are refused when the fleet lock no longer names the session
#     that requested them, and the refusal is reported rather than silent
#   - the aggregate bound turns a wedged sweep into an actionable line
#   - an abandoned `running` record is reported as needing a rerun rather than
#     staying "in progress" forever
#   - single-flight: a second `start` never launches a competing worker
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-startup-network-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

# new_world <name>: an FM_HOME plus a fake code root whose bin/ is a real
# firstmate bin/ except for fm-bootstrap.sh, which is replaced by a scriptable
# stand-in. The stage's contract is about WHEN and WHETHER the network half runs
# and how its result is published; bin/fm-bootstrap.sh's own behavior is owned by
# tests/fm-bootstrap.test.sh, so pinning it here would duplicate that owner and
# make these assertions depend on unrelated tool detection.
new_world() {
  local name=$1 w home root
  w="$TMP_ROOT/$name"
  home="$w/home"
  root="$w/root"
  mkdir -p "$home/state" "$root/bin"
  for f in "$ROOT"/bin/*.sh; do
    ln -s "$f" "$root/bin/$(basename "$f")"
  done
  rm -f "$root/bin/fm-bootstrap.sh"
  cat > "$root/bin/fm-bootstrap.sh" <<'SH'
#!/usr/bin/env bash
# Scriptable stand-in: records how it was invoked, then behaves as the test asks.
set -u
printf 'network=%s detect_only=%s\n' \
  "${FM_BOOTSTRAP_NETWORK:-all}" "${FM_BOOTSTRAP_DETECT_ONLY:-0}" \
  >> "${FM_FAKE_BOOTSTRAP_LOG:?}"
[ -z "${FM_FAKE_BOOTSTRAP_SLEEP:-}" ] || sleep "$FM_FAKE_BOOTSTRAP_SLEEP"
[ -z "${FM_FAKE_BOOTSTRAP_OUT:-}" ] || printf '%s\n' "$FM_FAKE_BOOTSTRAP_OUT"
exit "${FM_FAKE_BOOTSTRAP_RC:-0}"
SH
  chmod +x "$root/bin/fm-bootstrap.sh"
  cat > "$root/bin/ps" <<'SH'
#!/usr/bin/env bash
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
if [ "$pid" = "${FM_FAKE_HARNESS_PID:-}" ]; then
  case "$*" in
    *comm=*) printf '/usr/local/bin/claude\n' ;;
    *args=*) printf 'claude\n' ;;
    *ppid=*) /bin/ps -o ppid= -p "$pid" ;;
  esac
else
  /bin/ps "$@"
fi
SH
  chmod +x "$root/bin/ps"
  printf '%s|%s|%s\n' "$home" "$root" "$w/bootstrap.log"
}

# The detached worker records itself a moment after `start` returns - that gap is
# the whole point of not blocking - so a test that wants to observe the worker
# waits for its record rather than assuming instant publication.
await_worker_record() {  # <home>
  local home=$1 waited=0
  while [ ! -s "$home/state/.startup-network.status" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$home/state/.startup-network.status" ] || fail "the detached worker never recorded itself"
}

test_wait_fails_without_a_published_stage() {
  local rec home root log
  rec=$(new_world wait-without-stage)
  IFS='|' read -r home root log <<EOF
$rec
EOF

  if run_stage "$home" "$root" wait 1 >/dev/null; then
    fail "wait reported success even though no deferred stage had published"
  fi

  pass "fm-startup-network: wait fails when no deferred stage publishes before its deadline"
}

run_stage() {  # <home> <root> <args...>
  local home=$1 root=$2
  shift 2
  PATH="$root/bin:$PATH" FM_FAKE_HARNESS_PID="${FM_FAKE_HARNESS_PID_OVERRIDE:-$$}" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-startup-network.sh" "$@"
}

wait_for_startup_network_wake() {  # <home> [tenths]
  local home=$1 limit=${2:-50} waited=0
  while ! grep -Fq $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null \
    && [ "$waited" -lt "$limit" ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  grep -Fq $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null
}

# --- tests -------------------------------------------------------------------

# `start` is called from inside a session-open hook whose stdout the harness
# reads to EOF. A worker that inherited that pipe would hold the session open for
# exactly as long as the network work it was supposed to get off the critical
# path, so this asserts both halves: start returns fast, AND the pipe closes
# while the worker is still running.
test_start_returns_without_holding_the_callers_stdout() {
  local rec home root log started elapsed
  rec=$(new_world start-nonblocking)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  started=$(date +%s)
  # Command substitution reads to EOF, exactly like a hook harvesting hook output.
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=10 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$ >/dev/null
  elapsed=$(( $(date +%s) - started ))

  [ "$elapsed" -lt 4 ] || fail "start blocked for ${elapsed}s behind a 10s worker"
  await_worker_record "$home"
  [ "$(run_stage "$home" "$root" report | head -1)" = "IN PROGRESS - the deferred network checks have not finished yet." ] \
    || fail "the worker was not actually still running: $(run_stage "$home" "$root" report)"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the worker never published"
  assert_grep 'network=only' "$log" "the worker did not run bootstrap's network-only phase"
  pass "fm-startup-network: start returns immediately and never holds the caller's stdout open"
}

test_harvest_acknowledgement_suppresses_the_wake_and_no_claim_produces_it() {
  local rec home root log claimant output waited=0 worker_pid
  rec=$(new_world claim-handshake)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  sleep 10 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=3 FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='acknowledged result' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the claimed worker never published"
  worker_pid=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  output=$(run_stage "$home" "$root" harvest --pid "$claimant")
  assert_contains "$output" "acknowledged result" \
    "harvest did not print the finished result it acknowledged"
  [ -s "$home/state/.startup-network.delivered" ] \
    || fail "harvest did not durably acknowledge the result it printed"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  while kill -0 "$worker_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  ! kill -0 "$worker_pid" 2>/dev/null \
    || fail "the worker did not settle after harvest acknowledged its result"
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "a result harvest acknowledged also queued a wake: $(cat "$home/state/.wake-queue")"

  # Harvest releases that claim, so the NEXT publication has nobody to print it.
  assert_absent "$home/state/.startup-network.claim" "harvest did not release its own claim"
  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" run --locked 0
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "an unclaimed result never reached the wake queue"

  : > "$home/state/.wake-queue"
  FM_FAKE_BOOTSTRAP_LOG="$log" \
    run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the dead-claim worker never published"
  wait_for_startup_network_wake "$home" || fail "the dead-claim worker never settled delivery"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a dead session's stale claim swallowed the result"
  assert_absent "$home/state/.startup-network.claim" "a dead claim was not reaped"
  pass "fm-startup-network: exactly one of the digest and the wake reports each result"
}

test_a_claimant_crash_after_publish_still_queues_the_wake() {
  local rec home root log claimant
  rec=$(new_world claimant-crash)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 10 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=4 FM_FAKE_BOOTSTRAP_LOG="$log" \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the crash-window worker never published"
  kill -0 "$claimant" 2>/dev/null \
    || fail "the claimant died before the worker published"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  wait_for_startup_network_wake "$home" || fail "the crash-window worker never settled delivery"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a claimant crash after publication silently lost the result"
  assert_absent "$home/state/.startup-network.delivered" \
    "an unharvested result was recorded as delivered"
  pass "fm-startup-network: a claimant crash after publication still surfaces the result"
}

# The worker outlives the command that launched it. If another session took the
# lock meanwhile, running the mutating sweeps would sweep underneath that
# session, so they are refused - and the refusal is reported, not silent.
test_mutating_sweeps_are_refused_when_the_lock_changed_hands() {
  local rec home root log report
  rec=$(new_world lock-changed)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '222222\n' > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" run --locked 1 --lock-pid 111111
  assert_grep 'network=only detect_only=1' "$log" \
    "the worker ran mutating sweeps for a lock it no longer held"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "NETWORK_CHECKS: the fleet lock was no longer held" \
    "the downgrade to a read-only probe was not reported"

  # A detached start captures the lock itself and may run the mutating phase.
  : > "$log"
  printf '%s\n' $$ > "$home/state/.lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the lock-authorized worker never published"
  assert_grep 'network=only detect_only=0' "$log" \
    "the worker refused sweeps for the very session that still holds the lock"
  pass "fm-startup-network: manual callers cannot forge mutation authority"
}

# The unbounded per-call network work is exactly what could wedge a startup. The
# stage carries one aggregate bound, and hitting it is an actionable line.
test_the_stage_bound_is_reported_not_swallowed() {
  local rec home root log report
  rec=$(new_world stage-bound)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=20 FM_STARTUP_NETWORK_TIMEOUT=2 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  run_stage "$home" "$root" harvest --pid $$ >/dev/null
  FM_STARTUP_NETWORK_TIMEOUT=2 run_stage "$home" "$root" wait 10 >/dev/null \
    || fail "the bounded worker never settled"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "NETWORK_CHECKS: hit the 2s bound before finishing" \
    "a wedged deferred stage was not reported: $report"
  assert_contains "$report" "fm-startup-network.sh run --locked 1" \
    "the timeout line did not say how to rerun the stage"
  wait_for_startup_network_wake "$home" || fail "the timed-out worker never settled delivery"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a timed-out stage did not surface to the agent"
  pass "fm-startup-network: an aggregate bound turns a wedged sweep into an actionable line"
}

# A worker killed before publication leaves a `running` record behind.
# That record must read as work to redo, not as work still in flight.
test_an_abandoned_run_reads_as_needing_a_rerun() {
  local rec home root log report
  rec=$(new_world abandoned)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  cat > "$home/state/.startup-network.status" <<EOF
state=running
pid=999999999
started=$(date +%s)
locked=1
phases=probe,sweeps
EOF

  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "NETWORK_CHECKS: the deferred check worker stopped before publishing" \
    "an abandoned run still read as in progress: $report"
  assert_contains "$report" "dead-secondmate relaunch" \
    "the abandoned run did not name the checks that never completed"

  # A record older than the whole aggregate bound is abandoned even when its pid
  # happens to be alive again, so "in progress" can never become permanent.
  cat > "$home/state/.startup-network.status" <<EOF
state=running
pid=$$
started=$(( $(date +%s) - 400 ))
locked=1
phases=probe,sweeps
EOF
  assert_contains "$(FM_STARTUP_NETWORK_TIMEOUT=10 run_stage "$home" "$root" report)" \
    "NETWORK_CHECKS: the deferred check worker stopped before publishing" \
    "a record that outlived the stage bound still read as in progress"
  pass "fm-startup-network: an abandoned run reports as needing a rerun, never as in progress forever"
}

# Two session opens in quick succession must not run the same mutating sweeps
# concurrently against each other.
test_start_is_single_flight() {
  local rec home root log runs
  rec=$(new_world single-flight)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  await_worker_record "$home"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  run_stage "$home" "$root" wait 40 >/dev/null || fail "the worker never published"

  runs=$(grep -c 'network=only' "$log" || true)
  [ "$runs" -eq 1 ] || fail "a second start launched a competing worker ($runs runs): $(cat "$log")"
  pass "fm-startup-network: a second start never launches a competing worker"
}

test_start_reserves_its_generation_before_returning() {
  local rec home root log report
  rec=$(new_world generation-reservation)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  cat > "$home/state/.startup-network.status" <<EOF
state=done
pid=999999999
started=1
finished=2
rc=0
locked=0
phases=probe
generation=old
lock_pid=
EOF
  printf 'old result\n' > "$home/state/.startup-network.report"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=5 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid $$
  report=$(run_stage "$home" "$root" harvest --pid $$)
  assert_contains "$report" "IN PROGRESS" \
    "harvest exposed the previous generation after a new start returned: $report"
  assert_not_contains "$report" "old result" \
    "harvest printed a stale generation's report"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the reserved generation never published"
  pass "fm-startup-network: start atomically reserves the generation harvest observes"
}

test_new_lock_owner_does_not_reuse_the_previous_owners_worker() {
  local rec home root log generation_one generation_two next_owner
  rec=$(new_world owner-handoff)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  generation_one=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")

  next_owner=$(/bin/ps -o ppid= -p $$ | tr -d ' ')
  printf '%s\n' "$next_owner" > "$home/state/.lock"
  FM_FAKE_HARNESS_PID_OVERRIDE="$next_owner" FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=1 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  generation_two=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  [ "$generation_one" != "$generation_two" ] \
    || fail "the new lock owner reused the previous owner's generation"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the new owner's generation never published"
  pass "fm-startup-network: a new lock owner gets a distinct worker generation"
}

test_lock_takeover_stays_read_only_while_a_sweep_holds_the_lease() {
  local rec home root log next_owner new_owner out rc started elapsed waited=0
  rec=$(new_world sweep-lease)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  while [ ! -s "$log" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$log" ] || fail "the mutating sweep never started"

  next_owner=$(/bin/ps -o ppid= -p $$ | tr -d ' ')
  started=$(date +%s)
  rc=0
  out=$(PATH="$root/bin:$PATH" FM_FAKE_HARNESS_PID="$next_owner" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-lock.sh" 2>&1) || rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -ne 0 ] || fail "lock takeover succeeded while the prior sweep was mutating"
  [ "$elapsed" -lt 4 ] || fail "lock takeover blocked ${elapsed}s behind deferred network work"
  assert_contains "$out" "operate read-only" \
    "a lease-blocked takeover did not fail closed to read-only: $out"
  [ "$(cat "$home/state/.lock")" = "$$" ] \
    || fail "the lease-blocked takeover replaced the prior owner"

  run_stage "$home" "$root" wait 30 >/dev/null || fail "the leased sweep never settled"
  out=$(PATH="$root/bin:$PATH" FM_FAKE_HARNESS_PID="$next_owner" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-lock.sh" 2>&1) \
    || fail "lock takeover still failed after the sweep released its lease"
  new_owner=$(cat "$home/state/.lock")
  assert_contains "$out" "lock acquired: harness pid $new_owner" \
    "the fleet lock did not record the harness owner reported by acquisition"
  [ "$new_owner" != "$$" ] || fail "the prior harness still owned the lock after takeover"
  pass "fm-startup-network: fleet-lock takeover cannot overlap a mutating sweep"
}

test_wait_fails_without_a_published_stage
test_start_returns_without_holding_the_callers_stdout
test_harvest_acknowledgement_suppresses_the_wake_and_no_claim_produces_it
test_a_claimant_crash_after_publish_still_queues_the_wake
test_mutating_sweeps_are_refused_when_the_lock_changed_hands
test_the_stage_bound_is_reported_not_swallowed
test_an_abandoned_run_reads_as_needing_a_rerun
test_start_is_single_flight
test_start_reserves_its_generation_before_returning
test_new_lock_owner_does_not_reuse_the_previous_owners_worker
test_lock_takeover_stays_read_only_while_a_sweep_holds_the_lease

echo "# fm-startup-network.test.sh: all assertions passed"
