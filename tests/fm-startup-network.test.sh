#!/usr/bin/env bash
# tests/fm-startup-network.test.sh - behavior tests for bin/fm-startup-network.sh,
# the deferred startup stage a session start launches instead of running its
# network work or inactive-outcome scan on the blocking path.
#
# bin/fm-startup-network.sh's header owns the stage's contract and delivery limits.
# This suite covers detached stdout, inline acknowledgement, mutation leases,
# phase-aware single-flight, abandoned runs, bounded checks and lock contention,
# retained-report recovery, generation ownership, and matching report timings.
# tests/fm-session-start.test.sh covers integration with the digest.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-startup-network-tests)
DRAIN="$ROOT/bin/fm-wake-drain.sh"
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
# The real sweeps record their elapsed times through fm-timing-lib.sh, which
# reaches them as an exported FM_TIMING_LOG. Recording the same way here proves
# the stage actually hands that channel to its child and publishes what the child
# wrote - the part of the contract this suite owns. What the real sweeps measure
# is owned by tests/fm-bootstrap.test.sh.
if [ -n "${FM_TIMING_LOG:-}" ]; then
  . "$(dirname "$0")/fm-timing-lib.sh"
  fm_timing_record phase "${FM_FAKE_TIMING_PHASE:-gh-auth}" \
    "$(( $(fm_timing_now_ms) - 1500 ))" "${FM_FAKE_TIMING_DETAIL:-}"
fi
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

# hold_publish_lock <home>: take the stage's publish lock from a separate live
# process, the way a harvest wedged on a stalled stdout holds it, and print that
# holder's pid. The holder keeps the pid the lock records, so the lock's
# stale-owner recovery never reclaims it while the test runs.
hold_publish_lock() {  # <home>
  hold_named_lock "$1" "$1/state/.startup-network.lock"
}

# hold_named_lock <home> <lockdir>: same live holder, for the fleet lease and
# the recovery-marker lock as well as publication.
hold_named_lock() {  # <home> <lockdir>
  local home=$1 lock=$2 holder waited=0
  FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    . "$1/fm-wake-lib.sh"
    fm_lock_try_acquire "$2" || exit 1
    exec sleep 120' _ "$ROOT/bin" "$lock" >/dev/null 2>&1 </dev/null &
  holder=$!
  while [ "$(cat "$lock/pid" 2>/dev/null || true)" != "$holder" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$holder" ] \
    || fail "could not hold $lock from a second process"
  printf '%s' "$holder"
}

# await_pid_exit <pid> <tenths>: true when the process exits inside the bound.
await_pid_exit() {  # <pid> <tenths>
  local waited=0
  while kill -0 "$1" 2>/dev/null && [ "$waited" -lt "$2" ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  ! kill -0 "$1" 2>/dev/null
}

# --- tests -------------------------------------------------------------------

# `start` is called from inside a session-open hook whose stdout the harness
# reads to EOF. A worker that inherited that pipe would hold the session open for
# exactly as long as the network work it was supposed to get off the critical
# path, so this asserts both halves: start returns fast, AND the pipe closes
# while the worker is still running.
test_start_returns_without_holding_the_callers_stdout() {
  local rec home root log started elapsed pending
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
  pending=$(run_stage "$home" "$root" report)
  [ "$(printf '%s\n' "$pending" | head -1)" = "IN PROGRESS - the deferred network checks have not finished yet." ] \
    || fail "the worker was not actually still running: $pending"
  assert_contains "$pending" "Only a FAILED or otherwise actionable result arrives as a \`check: startup-network\` wake; a clean success stays silent." \
    "the pending guidance still promised a wake for clean success"
  assert_contains "$pending" "$root/bin/fm-startup-network.sh report" \
    "the pending guidance omitted the durable on-demand report path"
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

  sleep 30 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=15 FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='acknowledged result' \
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
  # An actionable result (not a clean success) is used here so the assertion
  # stays about the claim mechanism; test_a_successful_result_never_queues_a_wake
  # below owns the separate "a clean success never wakes" contract.
  assert_absent "$home/state/.startup-network.claim" "harvest did not release its own claim"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" run --locked 0
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "an unclaimed actionable result never reached the wake queue"

  : > "$home/state/.wake-queue"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the dead-claim worker never published"
  wait_for_startup_network_wake "$home" || fail "the dead-claim worker never settled delivery"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a dead session's stale claim swallowed the result"
  assert_absent "$home/state/.startup-network.claim" "a dead claim was not reaped"
  pass "fm-startup-network: exactly one of the digest and the wake reports each actionable result"
}

test_a_claimant_crash_after_publish_still_queues_the_wake() {
  local rec home root log claimant
  rec=$(new_world claimant-crash)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 10 &
  claimant=$!
  # Actionable output: a clean success in this same crash window must stay
  # silent (test_a_successful_result_never_queues_a_wake owns that case).
  FM_SESSION_START_TIMEOUT=4 FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
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

test_a_report_publication_failure_retains_findings_without_waking() {
  local rec home root log claimant output state worker generation wakes
  rec=$(new_world report-publication-failure)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  mkdir "$home/state/.startup-network.report"
  sleep 30 &
  claimant=$!

  FM_SESSION_START_TIMEOUT=2 FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='unpublishable result' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  await_worker_record "$home"
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  generation=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  await_pid_exit "$worker" 80 || fail "the publication failure kept the worker alive"
  state=$(sed -n 's/^state=//p' "$home/state/.startup-network.status")
  [ "$state" = failed ] || fail "a report-publication failure was published as $state"

  output=$(run_stage "$home" "$root" report)
  assert_contains "$output" 'unpublishable result' "the retained findings were unreadable: $output"
  output=$(run_stage "$home" "$root" harvest --pid "$claimant")
  assert_contains "$output" "NETWORK_CHECKS: could not publish the deferred check report" \
    "harvest did not surface the report-publication failure: $output"
  assert_not_contains "$output" 'unpublishable result' "harvest previewed unpublished findings"
  assert_absent "$home/state/.startup-network.delivered" "harvest acknowledged unpublished findings"
  assert_absent "$home/state/.wake-queue" "unpublished findings produced a wake"
  if FM_SESSION_START_TIMEOUT=2 run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999; then
    fail "a fresh start superseded an unpublishable retained report"
  fi
  [ "$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")" = "$generation" ] \
    || fail "the failed fresh start changed the retained generation"
  [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ] || fail "a failed fresh start ran new checks"
  assert_absent "$home/state/.wake-queue" "failed recovery woke unpublished findings"
  assert_grep 'unpublishable result' "$home/state/.startup-network.pending/report" "recovery lost the retained report"

  rmdir "$home/state/.startup-network.report"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=2 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999 \
    || fail "recovery could not publish the retained report"
  assert_grep 'unpublishable result' "$home/state/.startup-network.report" "recovery did not publish the retained findings"
  assert_absent "$home/state/.startup-network.pending" "successful recovery did not settle the pending report"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the fresh run did not finish"
  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" run --locked 0 \
    || fail "the later manual run failed"
  wakes=$(grep -Fc $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null || true)
  [ "$wakes" -eq 1 ] || fail "successful recovery queued $wakes wakes, want 1"

  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  pass "fm-startup-network: failed publication retains findings and wakes only after recovery"
}

# A clean success is not captain-facing progress (AGENTS.md section 8): it must
# never become a main-blocking wake row, whether or not a session was there to
# claim and harvest it inline. The result stays durable and readable through
# `report` either way.
test_a_successful_result_never_queues_a_wake() {
  local rec home root log claimant report
  rec=$(new_world successful-result-silent)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 10 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=4 FM_FAKE_BOOTSTRAP_LOG="$log" \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the unclaimed successful worker never published"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true

  # Give the same settling window the crash-window test uses, then confirm no
  # wake ever lands - not a race that just hasn't finished yet.
  sleep 1
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "a clean successful network-checks result queued a main-blocking wake: $(cat "$home/state/.wake-queue")"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "(silent - no problems found)" \
    "a successful result was not durably readable through report: $report"

  # Bootstrap itself explicitly types completed benign work as BOOTSTRAP_INFO.
  # That producer-owned no-action record is durable but must remain just as
  # quiet as a fully silent success.
  FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='BOOTSTRAP_INFO: fixture completed benign work' \
    run_stage "$home" "$root" run --locked 0
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "a BOOTSTRAP_INFO-only success queued a main-blocking wake: $(cat "$home/state/.wake-queue")"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "BOOTSTRAP_INFO: fixture completed benign work" \
    "the completed no-action fact was not retained in the durable report"

  pass "fm-startup-network: silent and explicitly informational successes never queue a main-blocking wake"
}

# The FAILED/actionable half of the same contract, paired with the success
# test above: an actionable report (here, a MISSING: line bootstrap-diagnostics
# would load a skill for) still reaches the wake queue even when unclaimed.
test_an_actionable_successful_result_still_queues_a_wake() {
  local rec home root log claimant
  rec=$(new_world actionable-result-wakes)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 10 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=4 FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the unclaimed actionable worker never published"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true

  wait_for_startup_network_wake "$home" \
    || fail "an actionable successful (state=done) result never queued a wake"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "an actionable result did not reach the wake queue"

  pass "fm-startup-network: an actionable state=done report still queues a wake"
}

test_deferred_invalid_secondmate_markers_queue_durable_findings() {
  local kind rec home root log target report err seq generation
  for kind in malformed symlink; do
    rec=$(new_world "deferred-invalid-marker-$kind")
    IFS='|' read -r home root log <<EOF
$rec
EOF
    printf '%s\n' $$ > "$home/state/.lock"
    if [ "$kind" = malformed ]; then
      printf '../other-home\n' > "$home/.fm-secondmate-home"
    else
      target="$TMP_ROOT/deferred-invalid-marker-$kind/marker-target"
      printf 'mate\n' > "$target"
      ln -s "$target" "$home/.fm-secondmate-home"
    fi

    FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" run --locked 1
    assert_grep $'check\tinactive-reconcile-diagnostic:invalid-secondmate-home\t' "$home/state/.wake-queue" \
      "$kind marker finding was swallowed by the deferred startup stage"
    report=$(run_stage "$home" "$root" report)
    assert_contains "$report" "(silent - no problems found)" \
      "$kind marker fixture unexpectedly depended on the network report"

    err="$home/drain.err"
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" >/dev/null 2> "$err"
    seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
    generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
    [ -n "$seq" ] && [ -n "$generation" ] \
      || fail "$kind marker wake did not issue a durable acknowledgement"
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" \
      --ack-through "$seq" --recovery-generation "$generation" >/dev/null
    assert_no_grep 'inactive-reconcile-diagnostic:invalid-secondmate-home' "$home/state/.wake-queue" \
      "$kind marker wake could not be acknowledged"
  done
  pass "fm-startup-network: deferred invalid secondmate markers produce durable wakes"
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

test_locked_start_is_not_satisfied_by_an_inflight_probe() {
  local rec home root log waited=0
  rec=$(new_world probe-then-locked)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"
  printf '../other-home\n' > "$home/.fm-secondmate-home"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid $$
  while ! grep -Fq 'detect_only=1' "$log" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  assert_grep 'network=only detect_only=1' "$log" \
    "the probe-only worker was not in flight before the locked request"

  FM_FAKE_BOOTSTRAP_LOG="$log" \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  run_stage "$home" "$root" wait 30 >/dev/null \
    || fail "the locked request never published"
  assert_grep 'network=only detect_only=0' "$log" \
    "the in-flight probe-only worker suppressed the locked sweeps"
  assert_grep $'check\tinactive-reconcile-diagnostic:invalid-secondmate-home\t' "$home/state/.wake-queue" \
    "the in-flight probe-only worker suppressed the locked inactive scan"
  pass "fm-startup-network: locked requests supersede in-flight probe-only workers"
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

# Every record carries a start offset from ONE origin, so the artifact reads as a
# timeline and not just a bag of durations. The origin is normally exported by the
# stage, but a process that starts recording without one has to adopt an origin
# and KEEP it: recomputing it per record would silently flatten every offset to
# zero and lose the ordering the artifact exists to show. Driven with explicit
# start stamps so the assertion does not depend on the host clock's resolution.
test_records_share_one_origin_so_offsets_form_a_timeline() {
  local dir log offsets count second third
  dir="$TMP_ROOT/timing-origin"
  mkdir -p "$dir"
  log="$dir/timings.tsv"

  (
    # shellcheck source=bin/fm-timing-lib.sh
    . "$ROOT/bin/fm-timing-lib.sh"
    unset FM_TIMING_EPOCH_MS
    FM_TIMING_LOG=$log
    export FM_TIMING_LOG
    base=$(fm_timing_now_ms)
    fm_timing_record phase first "$base"
    fm_timing_record phase second "$(( base + 5000 ))"
    fm_timing_record phase third "$(( base + 9000 ))"
  )

  # The origin lands within the first record, so that record's own offset rounds
  # to zero; what proves the origin was KEPT is that the later records are spaced
  # by exactly the interval they were given. Recomputing the origin per record
  # would report every one of them as zero.
  offsets=$(awk -F'\t' '$1 == "v1" { print $4 }' "$log")
  count=$(printf '%s\n' "$offsets" | grep -c .)
  second=$(printf '%s\n' "$offsets" | sed -n 2p)
  third=$(printf '%s\n' "$offsets" | sed -n 3p)
  [ "$count" -eq 3 ] || fail "expected three records, got: $offsets"
  [ "$second" -gt 0 ] && [ "$third" -gt "$second" ] \
    || fail "records did not share one origin - offsets were: $offsets"
  [ "$(( third - second ))" -eq 4000 ] \
    || fail "offsets did not preserve the interval between records: $offsets"
  pass "fm-startup-network: timing records share one origin so their offsets form a timeline"
}

# The whole point of the artifact is that it is FREE until someone asks for it.
# `harvest` is what composes a session start's NETWORK CHECKS section, so a
# timing line leaking into it would be a change to every startup's output; only
# the on-demand `report` may print them.
test_timings_are_published_and_only_the_on_demand_report_prints_them() {
  local rec home root log report_out harvest_out
  rec=$(new_world timings-published)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='sweep finding' \
    FM_FAKE_TIMING_PHASE=fleet-sync FM_FAKE_TIMING_DETAIL=dotfiles-private \
    run_stage "$home" "$root" run --locked 1

  assert_present "$home/state/.startup-network.timings" \
    "a finished run published no timing record"
  assert_grep 'fleet-sync' "$home/state/.startup-network.timings" \
    "the stage did not publish what the sweep recorded"
  assert_grep 'stage	network-checks' "$home/state/.startup-network.timings" \
    "the stage did not record its own bounded total"

  report_out=$(run_stage "$home" "$root" report)
  assert_contains "$report_out" "sweep finding" "report stopped printing the sweep result"
  assert_contains "$report_out" "TIMINGS" "report did not print the per-step timings"
  assert_contains "$report_out" "fleet-sync dotfiles-private" \
    "report did not attribute the elapsed time to the clone that spent it"
  assert_contains "$report_out" "slowest:" "report did not surface the slowest steps"

  harvest_out=$(run_stage "$home" "$root" harvest --pid $$)
  assert_contains "$harvest_out" "sweep finding" "harvest stopped printing the sweep result"
  assert_not_contains "$harvest_out" "TIMINGS" \
    "the timings leaked into the session-start digest section"
  assert_not_contains "$harvest_out" "slowest:" \
    "the timings leaked into the session-start digest section"
  pass "fm-startup-network: timings are durable and printed only on demand"
}

# A run that hit the bound is exactly the run worth attributing, so whatever the
# killed sweeps managed to record must survive rather than being discarded with
# them.
test_a_bounded_run_still_publishes_the_timings_it_managed_to_record() {
  local rec home root log report_out
  rec=$(new_world timings-partial)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  # Isolate the timed probe: a preceding inactive scan can consume the entire
  # bound before bootstrap records anything, which would not test retention.
  FM_STARTUP_NETWORK_TIMEOUT=2 FM_SESSION_START_TIMEOUT=2 \
    FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=20 \
    FM_FAKE_TIMING_PHASE=secondmate-liveness FM_FAKE_TIMING_DETAIL='mate-a@host-one' \
    run_stage "$home" "$root" run --locked 0

  [ "$(sed -n 's/^state=//p' "$home/state/.startup-network.status")" = timeout ] \
    || fail "the bounded run did not record itself as timed out"
  report_out=$(run_stage "$home" "$root" report)
  assert_contains "$report_out" "hit the 2s bound" "the bound stopped being reported"
  assert_contains "$report_out" "secondmate-liveness mate-a@host-one" \
    "a timed-out run discarded the partial timings its sweeps had already recorded"
  pass "fm-startup-network: a timed-out run still publishes the partial timings it recorded"
}

# The artifact is read by a human looking at a slow startup, so it must be
# incapable of carrying an argv or a credential out of a sweep, and incapable of
# being broken by one either: a detail with tabs or newlines would otherwise
# forge extra records.
test_the_timing_artifact_cannot_carry_a_command_line_or_forge_records() {
  local rec home root log lines report_out
  rec=$(new_world timings-sanitized)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_TIMING_PHASE=secondmate-sync \
    FM_FAKE_TIMING_DETAIL="ssh -i /key host	v1	forged	0	9999
GITHUB_TOKEN=ghp_supersecretvalue" \
    run_stage "$home" "$root" run --locked 1

  assert_no_grep 'ghp_supersecretvalue' "$home/state/.startup-network.timings" \
    "the timing artifact carried a credential-shaped value through"
  assert_no_grep 'forged' "$home/state/.startup-network.timings" \
    "a detail containing tabs forged an extra timing record"
  assert_no_grep 'ssh' "$home/state/.startup-network.timings" \
    "the timing artifact carried a command line through"
  assert_grep 'unrecordable' "$home/state/.startup-network.timings" \
    "free text was silently dropped instead of being marked unrecordable"
  lines=$(grep -c . "$home/state/.startup-network.timings")
  [ "$lines" -eq 2 ] \
    || fail "one sweep record plus the stage total should be 2 lines, got $lines"

  # The step itself is still measured - only its untrustworthy label is refused,
  # so a sweep that mislabels itself still shows up as time spent.
  assert_grep 'secondmate-sync' "$home/state/.startup-network.timings" \
    "refusing the label also discarded the measurement"

  report_out=$(run_stage "$home" "$root" report)
  assert_not_contains "$report_out" "ghp_supersecretvalue" \
    "the rendered report printed a credential-shaped value"
  pass "fm-startup-network: the timing artifact cannot carry a command line or forge records"
}

# A live holder of the publish lock used to keep the worker spinning for as long
# as the lock stayed held - hours, when a harvest wedged on a stalled stdout -
# with every result discarded at the end. Both the wait before the sweeps and
# the publication wait after them must give up inside the worker's own budget,
# record the failure the way `report` already reads a failed stage, and wake.
test_a_held_publish_lock_cannot_keep_the_worker_alive_past_its_budget() {
  local rec home root log holder began took rc report worker waited
  rec=$(new_world held-lock)
  IFS='|' read -r home root log <<EOF
$rec
EOF

  # Before the sweeps: the lock is held before the worker even registers.
  holder=$(hold_publish_lock "$home")
  began=$(date +%s)
  rc=0
  fm_run_timed 15 env PATH="$root/bin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_STARTUP_NETWORK_TIMEOUT=2 FM_SESSION_START_TIMEOUT=2 FM_FAKE_BOOTSTRAP_LOG="$log" \
    "$root/bin/fm-startup-network.sh" run --locked 0 >/dev/null 2>&1 || rc=$?
  took=$(( $(date +%s) - began ))
  [ "$rc" -ne 124 ] || fail "the worker was still waiting on the held publish lock 15s past a 2s budget"
  [ "$rc" -ne 0 ] || fail "the worker reported success without ever taking the publish lock"
  [ "$took" -le 6 ] || fail "the worker took ${took}s to give up on a 2s budget"
  [ ! -f "$log" ] || fail "the sweeps ran even though the worker could not register itself"
  assert_grep 'state=failed' "$home/state/.startup-network.pending/status" \
    "a worker that gave up on the lock did not retain its failed stage"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "still held by pid $holder" \
    "the failed record did not name the process holding the lock: $report"
  assert_contains "$report" "fm-startup-network.sh run --locked 0" \
    "the failed record did not say how to rerun the stage"
  assert_absent "$home/state/.wake-queue" "an unpublished lock timeout produced a wake"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the first lock holder"
  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" run --locked 0 \
    || fail "manual recovery did not settle the retained lock timeout"
  assert_grep $'check\tstartup-network' "$home/state/.wake-queue" "manual recovery did not wake the retained timeout"
  assert_absent "$home/state/.startup-network.pending" "manual recovery left the pending report behind"

  # After the sweeps: the worker registers and sweeps freely, then finds the
  # lock held when it comes to publish. What the sweeps produced must survive.
  rm -f "$home/state/.wake-queue" "$log"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=2 FM_FAKE_BOOTSTRAP_OUT='PROBE_RAN' \
    FM_STARTUP_NETWORK_TIMEOUT=10 FM_SESSION_START_TIMEOUT=2 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  await_worker_record "$home"
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  waited=0
  while [ ! -f "$log" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$log" ] || fail "the detached worker never started its sweep"
  holder=$(hold_publish_lock "$home")
  await_pid_exit "$worker" 100 \
    || fail "the worker was still alive 10s after its sweep finished against a held publish lock (2s delivery budget)"
  assert_grep 'state=failed' "$home/state/.startup-network.pending/status" \
    "a worker that could not publish did not retain a failed stage"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "PROBE_RAN" \
    "the sweep output was discarded when publication found the lock held: $report"
  assert_contains "$report" "still held by pid $holder" \
    "the unpublished result did not name the process holding the lock"
  assert_absent "$home/state/.wake-queue" "unpublished sweep findings produced a wake"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the second lock holder"
  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999 \
    || fail "startup recovery did not settle the retained sweep findings"
  assert_grep 'PROBE_RAN' "$home/state/.startup-network.report" "recovery did not publish the completed findings"
  assert_grep $'check\tstartup-network' "$home/state/.wake-queue" "startup recovery did not wake the completed findings"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the fresh checks did not settle"
  pass "fm-startup-network: a held publish lock bounds the worker and retains findings for recovery"
}

# A live fleet-lease holder used to sit in an unbounded acquire before the
# sweeps, so the stage budget never started. The worker must give up, leave a
# failed record naming that holder, and not run the sweeps.
test_a_live_lease_holder_cannot_extend_the_stage() {
  local rec home root log holder began took worker report wakes
  rec=$(new_world live-lease-holder)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"
  holder=$(hold_named_lock "$home" "$home/state/.lock.acquire")

  began=$(date +%s)
  FM_STARTUP_NETWORK_TIMEOUT=2 FM_SESSION_START_TIMEOUT=2 FM_FAKE_BOOTSTRAP_LOG="$log" \
    run_stage "$home" "$root" start --locked 1 --harvest-pid 999999999 \
    || fail "the contended-lease worker did not start"
  await_worker_record "$home"
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  await_pid_exit "$worker" 80 \
    || fail "a live lease holder kept the worker alive past a 2s stage budget"
  took=$(( $(date +%s) - began ))
  [ "$took" -le 8 ] || fail "the lease holder held the worker for ${took}s on a 2s budget"
  [ ! -f "$log" ] || fail "bootstrap ran without the fleet lease"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "still held by pid $holder" \
    "the lease timeout did not name the holder: $report"
  assert_contains "$report" "once that lease is released" \
    "the lease timeout did not say how to rerun"
  wakes=$(grep -Fc $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null || true)
  [ "$wakes" -eq 1 ] || fail "the lease timeout queued $wakes wakes, want 1"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the lease holder"
  pass "fm-startup-network: a live lease holder cannot extend the stage bound"
}

# The reported runaway stayed in the delivery poll while its claimant, a live
# session, never exited. The worker must leave that poll inside the delivery
# budget, keep the report, and queue the result once.
test_a_live_claimant_cannot_extend_delivery() {
  local rec home root log claimant began took worker report wakes
  rec=$(new_world live-claimant)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 30 &
  claimant=$!
  began=$(date +%s)
  FM_SESSION_START_TIMEOUT=2 FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant" \
    || fail "the live-claimant worker did not start"
  await_worker_record "$home"
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  await_pid_exit "$worker" 80 \
    || fail "a live claimant kept the worker in delivery past a 2s budget"
  took=$(( $(date +%s) - began ))
  [ "$took" -le 8 ] || fail "delivery against a live claimant took ${took}s on a 2s budget"
  kill -0 "$claimant" 2>/dev/null || fail "the claimant died before the deadline"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" 'MISSING: some-tool' "the live claim lost the report: $report"
  wakes=$(grep -Fc $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null || true)
  [ "$wakes" -eq 1 ] || fail "a live claimant produced $wakes deadline wakes, want 1"
  assert_absent "$home/state/.startup-network.delivered" \
    "an unharvested live claim was marked delivered"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  pass "fm-startup-network: a live claimant cannot extend delivery or duplicate its wake"
}

# Once the report is published, a later holder of the publication lock is the
# party that can acknowledge delivery. The worker must exit without a second
# wake and leave that report for harvest.
test_a_late_publication_lock_cannot_strand_delivery() {
  local rec home root log claimant holder worker report wakes
  rec=$(new_world live-publication-holder)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 30 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=8 FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant" \
    || fail "the claimed worker did not start"
  run_stage "$home" "$root" wait 8 >/dev/null || fail "the claimed worker did not publish"
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  kill -0 "$worker" 2>/dev/null \
    || fail "the worker finished delivery before the publication lock could be taken"
  holder=$(hold_publish_lock "$home")
  await_pid_exit "$worker" 120 \
    || fail "a live publication-lock holder kept the worker alive past its delivery budget"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" 'MISSING: some-tool' "the published report was lost: $report"
  assert_absent "$home/state/.wake-queue" "delivery queued a wake without the publication lock"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the publication-lock holder"
  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999 \
    || fail "the later startup did not retry delivery"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the fresh run did not settle"
  assert_absent "$home/state/.startup-network.pending" "recovery did not settle delivery"
  wakes=$(grep -Fc $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null || true)
  [ "$wakes" -eq 1 ] || fail "late-lock recovery queued $wakes wakes, want 1"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  pass "fm-startup-network: a live publication-lock holder cannot strand delivery"
}

# The wake append takes the recovery-marker lock with no deadline of its own.
# A live holder must not keep the worker running after the report is durable.
test_a_nested_wake_lock_cannot_strand_delivery() {
  local rec home root log holder began elapsed report generation wakes
  rec=$(new_world live-wake-holder)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  holder=$(hold_named_lock "$home" "$home/state/.watcher-down.lock")
  began=$(date +%s)
  FM_SESSION_START_TIMEOUT=2 FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool' \
    run_stage "$home" "$root" run --locked 0 \
    || fail "the wake-lock run failed before publishing"
  elapsed=$(( $(date +%s) - began ))
  [ "$elapsed" -le 6 ] || fail "the nested wake lock held delivery for ${elapsed}s"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" 'MISSING: some-tool' "the contended wake lost the durable report: $report"
  assert_absent "$home/state/.wake-queue" "a wake was queued through a held recovery lock"
  generation=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  if FM_SESSION_START_TIMEOUT=2 FM_FAKE_BOOTSTRAP_LOG="$log" \
    run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999; then
    fail "a new startup superseded the pending delivery through a held wake lock"
  fi
  [ "$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")" = "$generation" ] \
    || fail "failed recovery replaced the pending generation"
  [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ] || fail "failed recovery silently ran new sweeps"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the recovery-lock holder"
  printf 'queued\n' > "$home/state/.startup-network.pending/queued"
  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999 \
    || fail "startup did not recover delivery after the wake lock cleared"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the fresh run never settled"
  assert_absent "$home/state/.startup-network.pending" "a leftover queued marker blocked settlement"
  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" run --locked 0
  wakes=$(grep -Fc $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null || true)
  [ "$wakes" -eq 1 ] || fail "nested-lock recovery queued $wakes wakes, want 1"
  pass "fm-startup-network: a nested wake lock cannot strand delivery"
}

test_pending_delivery_harvest_and_superseded_generations() {
  local rec home root log holder generation report
  rec=$(new_world pending-harvest)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  holder=$(hold_named_lock "$home" "$home/state/.watcher-down.lock")
  FM_SESSION_START_TIMEOUT=1 FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='RETAINED_FINDING' \
    run_stage "$home" "$root" run --locked 0
  report=$(run_stage "$home" "$root" harvest)
  assert_contains "$report" 'RETAINED_FINDING' "harvest did not print the published pending report"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the harvest fixture lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the acknowledged fresh run did not finish"
  assert_absent "$home/state/.wake-queue" "recovery woke findings already acknowledged by harvest"
  assert_absent "$home/state/.startup-network.pending" "acknowledgement did not settle the retained report"

  holder=$(hold_named_lock "$home" "$home/state/.watcher-down.lock")
  FM_SESSION_START_TIMEOUT=1 FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='SUPERSEDED_FINDING' \
    run_stage "$home" "$root" run --locked 0
  generation=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  printf 'queued\n' > "$home/state/.startup-network.pending/queued"
  printf 'state=done\ngeneration=replacement\nreport_published=1\n' > "$home/state/.startup-network.status"
  printf 'CURRENT_FINDING\n' > "$home/state/.startup-network.report"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" 'CURRENT_FINDING' "report did not select the current generation"
  assert_not_contains "$report" 'SUPERSEDED_FINDING' "report exposed a denied pending generation"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the stale fixture lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  run_stage "$home" "$root" wait 30 >/dev/null || fail "a denied pending report blocked fresh checks"
  [ "$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")" != "$generation" ] \
    || fail "a denied pending report replaced the current generation"
  assert_absent "$home/state/.wake-queue" "a denied pending generation produced a wake"
  assert_absent "$home/state/.startup-network.pending" "a denied pending report was not discarded"
  pass "fm-startup-network: acknowledged and superseded pending generations cannot wake"
}

test_start_rechecks_pending_after_waiting_for_publication() {
  local rec home root log holder worker next_start waited=0 wakes
  rec=$(new_world pending-during-start)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=2 FM_FAKE_BOOTSTRAP_OUT='RACING_FINDING' \
    FM_SESSION_START_TIMEOUT=2 run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  while [ ! -f "$log" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$log" ] || fail "the racing worker never started"
  holder=$(hold_publish_lock "$home")
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=2 FM_SESSION_START_TIMEOUT=12 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999 &
  next_start=$!
  await_pid_exit "$worker" 100 || fail "the racing worker exceeded its publication budget"
  assert_grep 'RACING_FINDING' "$home/state/.startup-network.pending/report" "the racing worker did not retain its findings"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the racing lock holder"
  wait "$next_start" || fail "the waiting startup could not recover the pending report"
  assert_grep 'RACING_FINDING' "$home/state/.startup-network.report" "the waiting startup superseded unpublished findings"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the waiting startup never finished its fresh checks"
  wakes=$(grep -Fc $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null || true)
  [ "$wakes" -eq 1 ] || fail "the racing pending generation produced $wakes wakes, want 1"
  pass "fm-startup-network: startup recovers reports saved during its publication-lock wait"
}

test_reserved_worker_retains_a_precheck_lock_timeout() {
  local rec home root log holder worker report
  rec=$(new_world reserved-timeout)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  holder=$(hold_publish_lock "$home")
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STARTUP_NETWORK_TIMEOUT=2 \
    FM_FAKE_BOOTSTRAP_LOG="$log" bash -c '
      printf "state=running\npid=%s\nstarted=%s\nlocked=1\nphases=probe,sweeps\ngeneration=reserved\n" \
        "$$" "$(date +%s)" > "$FM_HOME/state/.startup-network.status"
      exec "$FM_ROOT_OVERRIDE/bin/fm-startup-network.sh" run --locked 1 --lock-pid 999999999 --generation reserved
    ' >/dev/null 2>&1 &
  worker=$!
  wait "$worker" && fail "a precheck publication-lock timeout reported success"
  assert_absent "$log" "a reserved worker ran checks without taking the publication lock"
  assert_absent "$home/state/.wake-queue" "a reserved worker woke unpublished timeout findings"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "still held by pid $holder" "the reserved timeout was not retained"
  assert_contains "$report" 'dead-secondmate relaunch' "the timeout omitted the reserved mutating phases"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the precheck lock holder"
  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the recovered fresh checks did not finish"
  assert_grep $'check\tstartup-network' "$home/state/.wake-queue" "the reserved timeout did not wake after recovery"
  assert_absent "$home/state/.startup-network.pending" "the recovered reserved timeout remained pending"
  pass "fm-startup-network: a reserved worker retains its precheck timeout for startup recovery"
}

test_digest_reports_a_refused_fresh_sweep() {
  local rec home root log output generation
  rec=$(new_world refused-fresh-digest)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  mkdir "$home/state/.startup-network.report" "$home/data" "$home/config"
  printf 'manual\n' > "$home/config/task-backend"
  printf '%s\n' "$$" > "$home/state/.lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='UNPUBLISHED_FINDING' \
    run_stage "$home" "$root" run --locked 0 >/dev/null && fail "unpublished findings reported success"
  generation=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  output=$(fm_run_timed 20 env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    PATH="$root/bin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_FAKE_HARNESS_PID="$$" FM_FAKE_BOOTSTRAP_LOG="$log" FM_SESSION_START_TIMEOUT=10 \
    bash "$root/bin/fm-session-start.sh" --reemit 2>&1) \
    || fail "the refused-fresh-sweep digest did not complete: $output"
  assert_contains "$output" 'NETWORK_CHECKS: fresh startup network checks could not start' \
    "the digest silently skipped fresh checks: $output"
  assert_not_contains "$output" 'UNPUBLISHED_FINDING' "the digest previewed unpublished findings"
  [ "$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")" = "$generation" ] \
    || fail "the digest replaced retained findings with a fresh generation"
  assert_no_grep $'check\tstartup-network' "$home/state/.wake-queue" "the digest woke unpublished findings"
  assert_grep 'UNPUBLISHED_FINDING' "$home/state/.startup-network.pending/report" "the digest discarded retained findings"
  pass "fm-startup-network: the digest discloses a refused fresh sweep without previewing findings"
}

test_pending_commit_and_reservation_share_ownership() {
  local mode rec home root log worker starter generation waited rc wakes real_sed real_mv staged_status prepared
  local FM_RACE_REAL_SED FM_RACE_REAL_MV
  real_sed=$(command -v sed)
  real_mv=$(command -v mv)
  FM_RACE_REAL_SED=$real_sed
  FM_RACE_REAL_MV=$real_mv
  export FM_RACE_REAL_SED FM_RACE_REAL_MV
  for mode in phases reservation delayed-reservation interrupted-reservation; do
    rec=$(new_world "reservation-ownership-$mode")
    IFS='|' read -r home root log <<EOF
$rec
EOF
    printf '%s\n' "$$" > "$home/state/.lock"
    cat > "$root/bin/sed" <<'SH'
#!/usr/bin/env bash
if [ "${FM_RACE_BOUNDARY:-}" = phases ] && [ "${2:-}" = 's/^phases=//p' ] \
  && [ "${3:-}" = "$FM_HOME/state/.startup-network.status" ] \
  && [ "$(cat "$FM_HOME/state/.startup-network.lock/pid" 2>/dev/null)" = "$FM_RACE_START_PID" ] \
  && [ ! -f "$FM_HOME/state/race-ready" ]; then
  : > "$FM_HOME/state/race-ready"
  waited=0
  while [ ! -f "$FM_HOME/state/race-release" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$FM_HOME/state/race-release" ] || exit 1
fi
exec "$FM_RACE_REAL_SED" "$@"
SH
    cat > "$root/bin/mv" <<'SH'
#!/usr/bin/env bash
if [ "${FM_RACE_BOUNDARY:-}" = reservation ] && [ "${3:-}" = "$FM_HOME/state/.startup-network.status" ] \
  && [ ! -f "$FM_HOME/state/race-ready" ]; then
  printf '%s\n' "$$" > "$FM_HOME/state/race-mv-pid"
  : > "$FM_HOME/state/race-ready"
  waited=0
  while [ ! -f "$FM_HOME/state/race-release" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$FM_HOME/state/race-release" ] || exit 1
fi
exec "$FM_RACE_REAL_MV" "$@"
SH
    chmod +x "$root/bin/sed" "$root/bin/mv"
    FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=2 FM_FAKE_BOOTSTRAP_OUT='FINDING_A' \
      FM_SESSION_START_TIMEOUT=2 run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
    worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
    generation=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
    waited=0
    while [ ! -s "$log" ] && [ "$waited" -lt 50 ]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    [ -s "$log" ] || fail "worker A never started before the reservation race"
    # shellcheck disable=SC2016 # The child bash expands its own PID and environment.
    fm_run_timed "$([ "$mode" = interrupted-reservation ] && printf 8 || printf 20)" \
      env PATH="$root/bin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_FAKE_HARNESS_PID="$$" \
      FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='FINDING_B' FM_SESSION_START_TIMEOUT=12 \
      FM_RACE_BOUNDARY="$([ "$mode" = phases ] && printf phases || printf reservation)" \
      FM_RACE_REAL_SED="$real_sed" FM_RACE_REAL_MV="$real_mv" \
      bash -c 'export FM_RACE_START_PID=$$; exec "$FM_ROOT_OVERRIDE/bin/fm-startup-network.sh" start --locked 1 --harvest-pid 999999999' &
    starter=$!
    waited=0
    while [ ! -f "$home/state/race-ready" ] && [ "$waited" -lt 50 ]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    [ -f "$home/state/race-ready" ] || fail "startup B did not reach the reservation race boundary"
    if [ "$mode" = phases ]; then
      await_pid_exit "$worker" 80 || fail "worker A exceeded its bounded exit during reservation"
      assert_grep 'FINDING_A' "$home/state/.startup-network.pending/report" "the allowed pending commit lost worker A's report"
    elif [ "$mode" = reservation ]; then
      waited=0
      prepared=0
      while [ "$prepared" -eq 0 ] && [ "$waited" -lt 80 ]; do
        [ ! -d "$home/state/.startup-network.pending" ] || prepared=1
        for staged_status in "$home/state"/.startup-network-pending.*/status; do
          [ ! -f "$staged_status" ] || prepared=1
        done
        [ "$prepared" -eq 1 ] && break
        sleep 0.1
        waited=$((waited + 1))
      done
      [ "$prepared" -eq 1 ] || fail "worker A never prepared its completed report during reservation"
    else
      await_pid_exit "$worker" 80 || fail "worker A exceeded its bounded exit behind a stalled reservation"
      prepared=0
      for staged_status in "$home/state"/.startup-network-pending.*/status; do
        [ -f "$staged_status" ] || continue
        assert_grep 'FINDING_A' "${staged_status%/status}/report" "reservation contention deleted the completed findings"
        assert_grep 'gh-auth' "${staged_status%/status}/timings" "reservation contention deleted the matching timings"
        prepared=1
      done
      [ "$prepared" -eq 1 ] || fail "reservation timeout discarded the recoverable staged report"
      [ "$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")" = "$generation" ] \
        || fail "the stalled reservation committed before the retention assertion"
      assert_absent "$home/state/.wake-queue" "unpublished staged findings produced a wake"
    fi
    [ "$mode" = interrupted-reservation ] || : > "$home/state/race-release"
    rc=0
    wait "$starter" || rc=$?
    if [ "$mode" = phases ]; then
      [ "$rc" -ne 0 ] || fail "startup B superseded a report committed after its recovery check"
      [ "$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")" = "$generation" ] \
        || fail "startup B replaced the retained generation"
      [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ] || fail "startup B ran fresh checks over a retained report"
      FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" run --locked 0 \
        || fail "manual recovery could not settle the allowed pending commit"
    elif [ "$mode" = interrupted-reservation ]; then
      fm_timed_out "$rc" || fail "startup B did not terminate at its reservation bound"
      await_pid_exit "$(cat "$home/state/race-mv-pid")" 10 \
        || fail "the interrupted startup left its stalled reservation child alive"
      [ "$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")" = "$generation" ] \
        || fail "the interrupted startup replaced the retained generation"
      FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=2 \
        run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999 \
        || fail "later startup could not recover the interrupted reservation"
      assert_grep 'FINDING_A' "$home/state/.startup-network.report" "later startup did not publish the completed staged findings"
      assert_grep 'gh-auth' "$home/state/.startup-network.timings" "later startup did not publish the staged timings"
      wait_for_startup_network_wake "$home" || fail "later startup did not wake for the recovered findings"
      run_stage "$home" "$root" wait 30 >/dev/null || fail "recovery blocked fresh checks"
      await_pid_exit "$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")" 80 \
        || fail "the fresh worker did not settle after recovery"
      [ "$(wc -l < "$log" | tr -d ' ')" -eq 2 ] || fail "interrupted reservation skipped or duplicated the fresh checks"
    else
      [ "$rc" -eq 0 ] || fail "startup B could not complete its owned reservation"
      await_pid_exit "$worker" 80 || fail "worker A exceeded its bounded exit after losing reservation ownership"
      run_stage "$home" "$root" wait 30 >/dev/null || fail "startup B could not publish after denying worker A's commit"
      wait_for_startup_network_wake "$home" || fail "startup B did not deliver its own findings"
      await_pid_exit "$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")" 80 \
        || fail "startup B did not settle its delivery"
      assert_grep 'FINDING_B' "$home/state/.startup-network.report" "worker A blocked startup B's publication"
      assert_no_grep 'FINDING_A' "$home/state/.startup-network.report" "the denied generation overwrote startup B's findings"
    fi
    assert_absent "$home/state/.startup-network.pending" "the reservation race left a blocking pending directory"
    for staged_status in "$home/state"/.startup-network-pending.*/status; do
      assert_absent "$staged_status" "the settled reservation left an uncommitted completed report"
    done
    wakes=$(grep -Fc $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null || true)
    [ "$wakes" -eq 1 ] || fail "the $mode reservation race queued $wakes wakes, want 1"
  done
  pass "fm-startup-network: pending commit and successor reservation have one ownership boundary"
}

test_report_selects_timings_from_the_selected_result() {
  local rec home root log holder worker waited output real_mktemp
  rec=$(new_world selected-result-timings)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_TIMING_PHASE=old-step \
    run_stage "$home" "$root" run --locked 0
  output=$(run_stage "$home" "$root" report)
  assert_contains "$output" 'old-step' "the published timing fixture was not recorded"
  : > "$log"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=2 FM_FAKE_BOOTSTRAP_OUT='PENDING_RESULT' \
    FM_FAKE_TIMING_PHASE=pending-step FM_SESSION_START_TIMEOUT=2 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  waited=0
  while [ ! -s "$log" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$log" ] || fail "the pending timing fixture never ran"
  holder=$(hold_publish_lock "$home")
  await_pid_exit "$worker" 80 || fail "the pending timing worker exceeded its bound"
  output=$(run_stage "$home" "$root" report)
  assert_contains "$output" 'PENDING_RESULT' "report omitted the selected pending findings"
  assert_contains "$output" 'pending-step' "report omitted the selected pending timings"
  assert_not_contains "$output" 'old-step' "report paired pending findings with published timings"
  rm "$home/state/.startup-network.pending/timings"
  output=$(run_stage "$home" "$root" report)
  assert_contains "$output" 'PENDING_RESULT' "missing timings hid the selected findings"
  assert_not_contains "$output" 'TIMINGS' "missing pending timings fell back to another run"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the selected timing fixture lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=2 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  assert_absent "$home/state/.startup-network.timings" "recovery published stale timings for a result without them"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the fresh timing fixture did not finish"
  output=$(run_stage "$home" "$root" report)
  assert_contains "$output" 'gh-auth' "ordinary publication stopped rendering its timings"
  real_mktemp=$(command -v mktemp)
  cat > "$root/bin/mktemp" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-startup-network-timings.*) exit 1 ;; esac
exec "$FM_REAL_MKTEMP" "$@"
SH
  chmod +x "$root/bin/mktemp"
  FM_REAL_MKTEMP="$real_mktemp" FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='UNTIMED_RESULT' \
    run_stage "$home" "$root" run --locked 0
  output=$(run_stage "$home" "$root" report)
  assert_contains "$output" 'UNTIMED_RESULT' "a missing timing artifact prevented ordinary publication"
  assert_not_contains "$output" 'TIMINGS' "untimed publication retained another run's timings"
  pass "fm-startup-network: report findings and timings always select the same result"
}

test_wait_fails_without_a_published_stage
test_start_returns_without_holding_the_callers_stdout
test_harvest_acknowledgement_suppresses_the_wake_and_no_claim_produces_it
test_a_claimant_crash_after_publish_still_queues_the_wake
test_a_report_publication_failure_retains_findings_without_waking
test_a_successful_result_never_queues_a_wake
test_an_actionable_successful_result_still_queues_a_wake
test_deferred_invalid_secondmate_markers_queue_durable_findings
test_mutating_sweeps_are_refused_when_the_lock_changed_hands
test_the_stage_bound_is_reported_not_swallowed
test_an_abandoned_run_reads_as_needing_a_rerun
test_locked_start_is_not_satisfied_by_an_inflight_probe
test_start_is_single_flight
test_start_reserves_its_generation_before_returning
test_new_lock_owner_does_not_reuse_the_previous_owners_worker
test_lock_takeover_stays_read_only_while_a_sweep_holds_the_lease
test_records_share_one_origin_so_offsets_form_a_timeline
test_timings_are_published_and_only_the_on_demand_report_prints_them
test_a_bounded_run_still_publishes_the_timings_it_managed_to_record
test_the_timing_artifact_cannot_carry_a_command_line_or_forge_records
test_a_held_publish_lock_cannot_keep_the_worker_alive_past_its_budget
test_a_live_lease_holder_cannot_extend_the_stage
test_a_live_claimant_cannot_extend_delivery
test_a_late_publication_lock_cannot_strand_delivery
test_a_nested_wake_lock_cannot_strand_delivery
test_pending_delivery_harvest_and_superseded_generations
test_start_rechecks_pending_after_waiting_for_publication
test_reserved_worker_retains_a_precheck_lock_timeout
test_digest_reports_a_refused_fresh_sweep
test_pending_commit_and_reservation_share_ownership
test_report_selects_timings_from_the_selected_result
echo "# fm-startup-network.test.sh: all assertions passed"
