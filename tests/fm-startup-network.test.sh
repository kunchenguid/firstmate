#!/usr/bin/env bash
# tests/fm-startup-network.test.sh - behavior tests for bin/fm-startup-network.sh,
# the deferred startup stage a session start launches instead of running its
# network work or inactive-outcome scan on the blocking path.
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
#   - phase-aware single-flight: a covering worker is reused, while a later
#     locked request supersedes an in-flight probe-only worker
#   - a publish lock a live process holds past the budget ends the worker with a
#     failed-rerun record instead of an unbounded wait
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

FM_TEST_REAL_PS=$(command -v ps)
export FM_TEST_REAL_PS
TMP_ROOT=$(fm_test_tmproot fm-startup-network-tests)
DRAIN="$ROOT/bin/fm-wake-drain.sh"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
STARTUP_FIXTURE_PROCESSES="$TMP_ROOT/fixture-processes"
: > "$STARTUP_FIXTURE_PROCESSES"

track_startup_fixture_process() {
  printf '%s\t%s\n' "$1" "$("$FM_TEST_REAL_PS" -p "$1" -o lstart=)" >> "$STARTUP_FIXTURE_PROCESSES"
}

cleanup_startup_fixtures() {
  local pid identity child
  while IFS=$'\t' read -r pid identity; do
    [ -n "$identity" ] && [ "$("$FM_TEST_REAL_PS" -p "$pid" -o lstart=)" = "$identity" ] || continue
    # Only this fixture's recorded process and descendants, including a paused
    # disposable watcher. Never use process names to discover another home.
    while IFS= read -r child; do
      kill -CONT "$child" 2>/dev/null || true
      kill -TERM "$child" 2>/dev/null || true
    done < <("$FM_TEST_REAL_PS" -eo pid=,ppid= | awk -v root="$pid" '
      { parent[$1]=$2 }
      END { for (pid in parent) { p=pid; for (i=0;i<100 && p>1;i++) {
        if (p==root) { print pid; break } p=parent[p]
      } } }
    ')
  done < "$STARTUP_FIXTURE_PROCESSES"
  fm_test_cleanup
}
trap cleanup_startup_fixtures EXIT

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
    *ppid=*) "$FM_TEST_REAL_PS" -o ppid= -p "$pid" ;;
  esac
else
  "$FM_TEST_REAL_PS" "$@"
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
  local lock="$1/state/.startup-network.lock" holder waited=0
  FM_STATE_OVERRIDE="$1/state" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    . "$1/fm-wake-lib.sh"
    fm_lock_try_acquire "$2" || exit 1
    exec sleep 120' _ "$ROOT/bin" "$lock" >/dev/null 2>&1 </dev/null &
  holder=$!
  while [ "$(cat "$lock/pid" 2>/dev/null || true)" != "$holder" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$holder" ] \
    || fail "could not hold the publish lock from a second process"
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
  printf 'another-generation\n' > "$home/state/.startup-network.delivered"
  startup_supervision_needed "$home" || fail "another generation's acknowledgement settled current work"
  output=$(run_stage "$home" "$root" harvest --pid "$claimant")
  assert_contains "$output" "acknowledged result" \
    "harvest did not print the finished result it acknowledged"
  [ -s "$home/state/.startup-network.delivered" ] \
    || fail "harvest did not durably acknowledge the result it printed"
  if startup_supervision_needed "$home"; then
    fail "a durably harvested result retained a producer supervision obligation"
  fi
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

test_a_report_publication_failure_retains_findings_until_recovery() {
  local rec home root log claimant output state
  rec=$(new_world report-publication-failure)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  mkdir "$home/state/.startup-network.report"
  chmod 500 "$home/state/.startup-network.report"
  sleep 10 &
  claimant=$!

  FM_SESSION_START_TIMEOUT=4 FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='unpublishable result' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the report-publication failure never settled"
  state=$(sed -n 's/^state=//p' "$home/state/.startup-network.status")
  [ "$state" = failed ] || fail "a report-publication failure was published as $state"

  output=$(run_stage "$home" "$root" report)
  assert_contains "$output" "completed findings retained" \
    "report did not surface the retained publication failure: $output"
  assert_contains "$output" "unpublishable result" "report lost the completed findings"
  output=$(run_stage "$home" "$root" harvest --pid "$claimant")
  assert_contains "$output" "NETWORK_CHECKS: could not publish the deferred check report" \
    "harvest did not surface the report-publication failure: $output"
  assert_absent "$home/state/.startup-network.delivered" \
    "harvest acknowledged a result whose report was not published"
  [ ! -s "$home/state/.wake-queue" ] || fail "an unpublished report queued a wake"

  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  chmod 700 "$home/state/.startup-network.report"
  rmdir "$home/state/.startup-network.report"
  run_stage "$home" "$root" recover || fail "retained findings did not recover"
  assert_grep $'check\tstartup-network' "$home/state/.wake-queue" "recovered report did not wake"
  pass "fm-startup-network: publication failure retains findings and wakes only after recovery"
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
  if startup_supervision_needed "$home"; then
    fail "clean completion retained a startup supervision obligation"
  fi
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
  assert_contains "$report" "NETWORK_CHECKS: the recorded fleet lock holder changed after these were requested" \
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

  next_owner=$("$FM_TEST_REAL_PS" -o ppid= -p $$ | tr -d ' ')
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

  next_owner=$("$FM_TEST_REAL_PS" -o ppid= -p $$ | tr -d ' ')
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
  printf '%s\n' $$ > "$home/state/.lock"

  FM_STARTUP_NETWORK_TIMEOUT=1 FM_SESSION_START_TIMEOUT=2 \
    FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=20 \
    FM_FAKE_TIMING_PHASE=secondmate-liveness FM_FAKE_TIMING_DETAIL='mate-a@host-one' \
    run_stage "$home" "$root" run --locked 1

  [ "$(sed -n 's/^state=//p' "$home/state/.startup-network.status")" = timeout ] \
    || fail "the bounded run did not record itself as timed out"
  report_out=$(run_stage "$home" "$root" report)
  assert_contains "$report_out" "hit the 1s bound" "the bound stopped being reported"
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
  assert_absent "$home/state/.startup-network.status" "an unreserved caller wrote shared results without ownership"
  assert_no_grep $'check\tstartup-network' "$home/state/.wake-queue" "an unreserved caller queued findings"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the first lock holder"

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
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "PROBE_RAN" "publication contention discarded the completed report"
  assert_contains "$report" "completed findings retained" "retention was not disclosed"
  assert_no_grep $'check\tstartup-network' "$home/state/.wake-queue" "publication contention produced an unowned wake"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the publication lock"
  run_stage "$home" "$root" recover || fail "the completed report did not recover after contention"
  assert_grep $'check\tstartup-network' "$home/state/.wake-queue" "retained result did not wake after recovery"
  pass "fm-startup-network: a held publish lock ends the worker inside its budget with a failed-rerun record"
}

test_failed_publication_keeps_a_recoverable_completed_result() {
  local rec home root log rc generation report
  rec=$(new_world retained-publication-failure)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  mkdir "$home/state/.startup-network.report"
  rc=0
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='RETAINED_RESULT' \
    run_stage "$home" "$root" run --locked 0 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a directory publication target reported success"
  generation=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  report=$(run_stage "$home" "$root" report --generation "$generation")
  assert_contains "$report" RETAINED_RESULT "publication failure discarded the completed findings"
  assert_no_grep $'check\tstartup-network' "$home/state/.wake-queue" "unpublished findings queued a wake"
  rmdir "$home/state/.startup-network.report"
  run_stage "$home" "$root" recover || fail "completed findings could not be recovered"
  assert_grep RETAINED_RESULT "$home/state/.startup-network.report" "recovery did not publish retained findings"
  assert_grep $'check\tstartup-network' "$home/state/.wake-queue" "published retained findings did not wake"
  run_stage "$home" "$root" recover || fail "settled recovery was not idempotent"
  [ "$(awk -F '\t' '$3 == "check" && $4 ~ /^startup-network/ { n++ } END { print n+0 }' "$home/state/.wake-queue")" -eq 1 ] \
    || fail "recovery appended the same completed generation twice"
  pass "fm-startup-network: failed publication retains completed findings for idempotent recovery"
}

# Each holder is a real process using the production lock interface, confined
# to this disposable home. It stays live beyond the detached delivery bound.
hold_startup_lock() { # <home> <lock-basename>
  local lock="$1/state/$2" holder waited=0
  FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 1
    exec sleep 120
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" >/dev/null 2>&1 </dev/null &
  holder=$!
  while [ "$(cat "$lock/pid" 2>/dev/null || true)" != "$holder" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1; waited=$((waited + 1))
  done
  [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$holder" ] || fail "fixture lock was not acquired: $lock"
  track_startup_fixture_process "$holder"
  [ -z "${FM_STARTUP_TEST_PROCESS_LOG:-}" ] || printf 'holder %s\n' "$holder" >> "$FM_STARTUP_TEST_PROCESS_LOG"
  printf '%s\n' "$holder"
}

test_existing_watcher_recovers_after_worker_deadline() {
  local lock rec home root log worker holder watcher generation result report count waited pid cycles publication_holder
  for lock in .startup-network.lock .wake-queue.lock .watcher-down.lock; do
    rec=$(new_world "existing-watch-${lock#.}")
    IFS='|' read -r home root log <<< "$rec"
    fm_test_track_watcher_state "$home/state"
    cat > "$root/bin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    chmod +x "$root/bin/tmux"
    export FM_TEST_REAL_BASH FM_TEST_REAL_TOUCH
    FM_TEST_REAL_BASH=$(command -v bash)
    FM_TEST_REAL_TOUCH=$(command -v touch)
    : > "$home/recovery.trace"
    # Observe the real recovery command's start/end and process tree. Only the
    # shell executable boundary is wrapped; timers, locks and recovery are real.
    printf '#!%s\n' "$FM_TEST_REAL_BASH" > "$root/bin/bash"
    cat >> "$root/bin/bash" <<'SH'
if [ "${2:-}" = recover ] && [ -n "${FM_STARTUP_RECOVERY_TRACE:-}" ]; then
  began=$(date +%s)
  "$FM_TEST_REAL_BASH" "$@" &
  child=$!
  printf 'begin %s %s %s\n' "${BASHPID:-$$}" "$child" "$began" >> "$FM_STARTUP_RECOVERY_TRACE"
  while kill -0 "$child" 2>/dev/null; do
    "$FM_TEST_REAL_PS" -eo pid=,ppid= | awk -v root="$child" '
      { parent[$1]=$2 }
      END { for (pid in parent) { p=pid; for (i=0;i<100 && p>1;i++) {
        if (p==root) { print pid; break } p=parent[p]
      } } }
    ' >> "$FM_STARTUP_RECOVERY_TRACE.pids"
    sleep .1
  done
  wait "$child"
  rc=$?
  printf 'end %s %s %s\n' "$child" "$rc" "$(( $(date +%s) - began ))" >> "$FM_STARTUP_RECOVERY_TRACE"
  exit "$rc"
fi
exec "$FM_TEST_REAL_BASH" "$@"
SH
    # An absolute shebang avoids the observing wrapper recursively invoking
    # itself through env; the installed Bash path is portable across this host.
    chmod +x "$root/bin/bash"
    cat > "$root/bin/touch" <<'SH'
#!/usr/bin/env bash
"$FM_TEST_REAL_TOUCH" "$@" || exit $?
if [ "${1:-}" = "$FM_HOME/state/.last-watcher-beat" ] && [ ! -f "$FM_HOME/release-first-cycle" ]; then
  printf 'ready\n' > "$FM_HOME/watcher-at-beacon"
  for ((i=0;i<200;i++)); do
    [ ! -f "$FM_HOME/release-first-cycle" ] || exit 0
    sleep .1
  done
  exit 1
fi
SH
    chmod +x "$root/bin/touch"
    # Reserve and start the real worker before blocking publication. Bootstrap
    # is only the synthetic network dependency; delivery and locks are real.
    FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 FM_FAKE_BOOTSTRAP_OUT='DELAYED_ACTIONABLE' \
      FM_STARTUP_NETWORK_TIMEOUT=10 FM_SESSION_START_TIMEOUT=2 \
      run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
    await_worker_record "$home"
    worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
    generation=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
    waited=0
    while [ ! -s "$log" ] && [ "$waited" -lt 100 ]; do
      sleep 0.1; waited=$((waited + 1))
    done
    [ -s "$log" ] || fail "the reserved worker never began its checks"
    # Let watcher initialization finish while the queue is free, then pause at
    # its real beacon boundary before selecting the startup recovery attempt.
    publication_holder=$(hold_startup_lock "$home" .startup-network.lock)
    PATH="$root/bin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$home/state" \
      FM_SESSION_START_TIMEOUT=30 FM_STARTUP_RECOVERY_TRACE="$home/recovery.trace" FM_POLL=1 bash "$ROOT/bin/fm-watch.sh" \
      > "$home/watch.out" 2> "$home/watch.err" &
    watcher=$!
    track_startup_fixture_process "$watcher"
    [ -z "${FM_STARTUP_TEST_PROCESS_LOG:-}" ] || printf 'watcher %s\n' "$watcher" >> "$FM_STARTUP_TEST_PROCESS_LOG"
    waited=0
    while [ ! -s "$home/watcher-at-beacon" ] && [ "$waited" -lt 100 ]; do sleep .1; waited=$((waited+1)); done
    [ -s "$home/watcher-at-beacon" ] || fail "disposable watcher did not finish initialization"
    holder=$publication_holder
    if [ "$lock" != .startup-network.lock ]; then
      holder=$(hold_startup_lock "$home" "$lock")
      kill "$publication_holder" 2>/dev/null || true
      await_pid_exit "$publication_holder" 50 || fail "initial publication holder did not exit"
    fi
    await_pid_exit "$worker" 100 || fail "detached worker exceeded its bound with $lock held"
    result="$home/state/.startup-network-results/$generation"
    assert_grep 'DELAYED_ACTIONABLE' "$result/report" "the held $lock discarded completed findings"
    [ -s "$result/timings" ] || fail "the held $lock discarded completed timings"
    [ ! -s "$home/state/.wake-queue" ] || fail "the held $lock unexpectedly admitted a wake"
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" bash -c '
      . "$1"
      fm_supervision_needed "$2"
    ' _ "$ROOT/bin/fm-supervision-lib.sh" "$home/state" \
      || fail "startup-only retained completion lost supervision with $lock held"
    touch "$home/release-first-cycle"
    # The existing watcher must survive a refused bounded recovery cycle, then
    # deliver without a second start or any manual recovery call.
    # Publication contention allows ordinary later cycles. Queue/marker locks
    # can also delay existing downstream readers, so verify one completed
    # recovery attempt there without changing those unrelated readers.
    cycles=1
    [ "$lock" != .startup-network.lock ] || cycles=2
    waited=0
    while [ "$(awk '$1=="end" {n++} END {print n+0}' "$home/recovery.trace" 2>/dev/null)" -lt "$cycles" ] \
      && [ "$waited" -lt 200 ]; do sleep .1; waited=$((waited+1)); done
    [ "$(awk '$1=="end" {n++} END {print n+0}' "$home/recovery.trace")" -ge "$cycles" ] \
      || fail "$cycles refused recovery cycles did not complete while $lock stayed held: $(cat "$home/recovery.trace")"
    awk '$1=="end" && ($3==0 || $4>8) {bad=1} END {exit bad}' "$home/recovery.trace" \
      || fail "recovery ignored the five-second ceiling with a 30-second configured budget"
    [ -s "$home/recovery.trace.pids" ] || fail "recovery process tree was not observed"
    # Snapshot only completed cycles: the next cycle may legitimately be live.
    # Wait for a cycle boundary, then stop this observer before the next starts.
    kill -STOP "$watcher" || fail "could not pause the disposable watcher at its recovery boundary"
    while [ "$(awk '$1=="begin" {n++} END {print n+0}' "$home/recovery.trace")" \
      -gt "$(awk '$1=="end" {n++} END {print n+0}' "$home/recovery.trace")" ]; do
      sleep .1; waited=$((waited+1))
      [ "$waited" -lt 300 ] || fail "in-progress recovery did not terminate while its watcher was paused"
    done
    while IFS= read -r pid; do
      await_pid_exit "$pid" 30 || fail "bounded recovery left descendant $pid alive while $lock stayed held"
    done < <(sort -u "$home/recovery.trace.pids")
    kill -0 "$watcher" 2>/dev/null || fail "watcher exited before contention cleared: $(cat "$home/watch.err")"
    kill -CONT "$watcher" || fail "could not resume the disposable watcher"
    kill "$holder" 2>/dev/null || true
    await_pid_exit "$holder" 50 || fail "fixture holder did not exit"
    wait_for_startup_network_wake "$home" 200 \
      || fail "the existing watcher never recovered $lock: $(cat "$home/watch.out" "$home/watch.err")"
    count=$(awk -F '\t' -v key="startup-network:$generation" '$3 == "check" && $4 == key { n++ } END { print n+0 }' "$home/state/.wake-queue")
    [ "$count" -eq 1 ] || fail "watcher recovery created $count generation rows"
    report=$(run_stage "$home" "$root" report --generation "$generation")
    assert_contains "$report" DELAYED_ACTIONABLE "recovered wake lost its immutable report"
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ] || fail "watcher recovery reran startup checks"
  done
  pass "fm-startup-network: existing watcher delivers after publication, queue and nested marker contention without another startup"
}

test_stale_completions_cannot_publish_or_block_fresh_checks() {
  local rec home root log old fresh holder rc waited=0
  rec=$(new_world stale-retained)
  IFS='|' read -r home root log <<< "$rec"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=2 FM_FAKE_BOOTSTRAP_OUT=OLD_RESULT \
    FM_SESSION_START_TIMEOUT=2 run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  await_worker_record "$home"
  old=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  while [ ! -s "$log" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1; waited=$((waited + 1))
  done
  [ -s "$log" ] || fail "old checks never began"
  holder=$(hold_startup_lock "$home" .startup-network.lock) || fail "old publication fixture did not acquire its lock"
  sleep 5
  [ -f "$home/state/.startup-network-results/$old/status" ] || fail "old completion was not retained"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "old fixture lock did not release"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=3 FM_FAKE_BOOTSTRAP_OUT=FRESH_RESULT \
    FM_SESSION_START_TIMEOUT=2 run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  fresh=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  [ "$fresh" != "$old" ] || fail "retained stale completion blocked a fresh reservation"
  run_stage "$home" "$root" recover --generation "$old" || fail "stale recovery did not settle as a no-op"
  [ "$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")" = "$fresh" ] || fail "old completion replaced a running successor"
  assert_no_grep "$old" "$home/state/.wake-queue" "old generation delivered against a running successor"
  wait_for_startup_network_wake "$home" 100 || fail "fresh checks did not finish and deliver"
  run_stage "$home" "$root" recover --generation "$old" || fail "completed-successor stale recovery failed"
  assert_no_grep "$old" "$home/state/.wake-queue" "old generation delivered against a completed successor"
  assert_grep FRESH_RESULT "$home/state/.startup-network.report" "old completion replaced a completed successor report"
  [ "$(wc -l < "$log" | tr -d ' ')" -eq 2 ] || fail "fresh network checks did not execute"
  rc=0
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append check "startup-network:../unsafe" unsafe' \
    _ "$ROOT/bin/fm-wake-lib.sh" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "malformed generation was admitted"
  pass "fm-startup-network: retained stale results cannot replace successors or prevent fresh checks"
}

test_report_refuses_a_missing_or_unsafe_explicit_generation() {
  local rec home root log rc report generation
  rec=$(new_world explicit-report-refusal)
  IFS='|' read -r home root log <<< "$rec"
  printf 'state=done\ngeneration=current\nreport_published=1\n' > "$home/state/.startup-network.status"
  printf 'CURRENT_REPORT\n' > "$home/state/.startup-network.report"
  for generation in missing ../unsafe; do
    rc=0
    report=$(run_stage "$home" "$root" report --generation "$generation") || rc=$?
    [ "$rc" -ne 0 ] || fail "an unavailable explicit generation reported success"
    assert_not_contains "$report" CURRENT_REPORT "an explicit generation was redirected to another report"
  done
  pass "fm-startup-network: explicit report generations refuse missing or unsafe artifacts"
}

startup_supervision_needed() { # <home>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    . "$1"
    fm_supervision_needed "$2"
  ' _ "$ROOT/bin/fm-supervision-lib.sh" "$1/state"
}

test_running_and_refused_records_have_correct_supervision() {
  local rec home root log worker waited=0 pid
  rec=$(new_world running-supervision)
  IFS='|' read -r home root log <<< "$rec"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=3 FM_SESSION_START_TIMEOUT=2 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  await_worker_record "$home"
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  while [ ! -s "$log" ] && [ "$waited" -lt 50 ]; do sleep .1; waited=$((waited+1)); done
  [ -s "$log" ] || fail "the running supervision worker never began checks"
  startup_supervision_needed "$home" || fail "a real running startup with no crew lost supervision"
  await_pid_exit "$worker" 100 || fail "clean startup worker did not terminate"
  if startup_supervision_needed "$home"; then fail "clean completion did not settle supervision"; fi
  for pid in 999999999 invalid 0; do
    printf 'generation=refused\nstate=running\npid=%s\nstarted=%s\n' "$pid" "$(date +%s)" \
      > "$home/state/.startup-network.status"
    if startup_supervision_needed "$home"; then fail "dead or invalid worker $pid retained supervision"; fi
  done
  pass "fm-startup-network: live startup-only work requires supervision and clean/dead/invalid records settle"
}

test_aged_running_record_cannot_borrow_an_unrelated_pid() {
  local rec home root log started
  rec=$(new_world aged-supervision)
  IFS='|' read -r home root log <<< "$rec"
  started=$(( $(date +%s) - 400 ))
  printf 'generation=aged\nstate=running\npid=%s\nstarted=%s\n' "$$" "$started" \
    > "$home/state/.startup-network.status"
  if FM_STARTUP_NETWORK_TIMEOUT=10 startup_supervision_needed "$home"; then
    fail "an aged running record borrowed an unrelated live PID for supervision"
  fi
  pass "fm-startup-network: abandoned running records cannot borrow a reused PID"
}

test_optional_timing_failure_preserves_completion() {
  local rec home root log generation report
  rec=$(new_world timing-copy-failure)
  IFS='|' read -r home root log <<< "$rec"
  export FM_TEST_REAL_CP
  FM_TEST_REAL_CP=$(command -v cp)
  cat > "$root/bin/cp" <<'SH'
#!/usr/bin/env bash
case ${2:-} in
  */.startup-network-results/*/timings)
    printf 'partial diagnostic\n' > "$2"
    exit 1 ;;
esac
exec "$FM_TEST_REAL_CP" "$@"
SH
  chmod +x "$root/bin/cp"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT=TIMING_FAILURE_RESULT \
    FM_SESSION_START_TIMEOUT=2 run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  await_worker_record "$home"
  generation=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  wait_for_startup_network_wake "$home" 100 || fail "optional timing I/O failure stranded completed findings"
  report=$(run_stage "$home" "$root" report --generation "$generation")
  assert_contains "$report" TIMING_FAILURE_RESULT "optional timing failure lost the report"
  assert_absent "$home/state/.startup-network-results/$generation/timings" "partial diagnostic timings were retained"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" -eq 1 ] || fail "timing failure duplicated delivery"
  pass "fm-startup-network: diagnostic timing-copy failure preserves completed delivery"
}

test_current_worker_survives_losing_result_root_creation() {
  local rec home root log old current worker waited holder watcher
  rec=$(new_world concurrent-result-root)
  IFS='|' read -r home root log <<< "$rec"
  printf '%s\n' "$$" > "$home/state/.lock"
  export FM_TEST_REAL_MKDIR
  FM_TEST_REAL_MKDIR=$(command -v mkdir)
  cat > "$root/bin/mkdir" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "$FM_HOME/state/.startup-network-results" ]; then
  role=${FM_STARTUP_TEST_ROLE:?}
  printf '%s\n' "${BASHPID:-$$}" > "$FM_HOME/$role.arrived"
  for ((i=0; i<100; i++)); do
    if [ "$role" = old ] && [ -s "$FM_HOME/current.arrived" ] && [ -f "$FM_HOME/release-root" ]; then
      "$FM_TEST_REAL_MKDIR" "$1" || exit 1
      touch "$FM_HOME/root.created"
      exit 0
    elif [ "$role" = current ] && [ -f "$FM_HOME/root.created" ]; then
      exec "$FM_TEST_REAL_MKDIR" "$@"
    fi
    sleep .1
  done
  exit 1
fi
exec "$FM_TEST_REAL_MKDIR" "$@"
SH
  # The locked successor has only disposable network dependencies here.
  rm "$root/bin/fm-inactive-reconcile.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/fm-inactive-reconcile.sh"
  chmod +x "$root/bin/mkdir" "$root/bin/fm-inactive-reconcile.sh"
  FM_STARTUP_TEST_ROLE=old FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT=OLD_RESULT \
    FM_SESSION_START_TIMEOUT=2 run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  await_worker_record "$home"
  old=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  track_startup_fixture_process "$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")"
  waited=0
  while [ ! -s "$home/old.arrived" ] && [ "$waited" -lt 100 ]; do sleep .1; waited=$((waited+1)); done
  [ -s "$home/old.arrived" ] || fail "old worker did not reach first-time retention"
  FM_STARTUP_TEST_ROLE=current FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT=CURRENT_RESULT \
    FM_SESSION_START_TIMEOUT=2 run_stage "$home" "$root" start --locked 1 --harvest-pid 999999999
  current=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  track_startup_fixture_process "$worker"
  [ "$current" != "$old" ] || fail "locked successor did not reserve a fresh generation"
  waited=0
  while [ ! -s "$home/current.arrived" ] && [ "$waited" -lt 100 ]; do sleep .1; waited=$((waited+1)); done
  [ -s "$home/current.arrived" ] || fail "current worker did not race first-time retention"
  holder=$(hold_startup_lock "$home" .startup-network.lock)
  touch "$home/release-root"
  await_pid_exit "$worker" 150 || fail "current retention worker did not exit"
  assert_grep "generation=$current" "$home/state/.startup-network-results/$current/status" \
    "current worker lost its durable completion to another worker's mkdir"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$root/bin/tmux"
  chmod +x "$root/bin/tmux"
  fm_test_track_watcher_state "$home/state"
  PATH="$root/bin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$home/state" \
    FM_SESSION_START_TIMEOUT=2 FM_POLL=1 bash "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err" &
  watcher=$!
  track_startup_fixture_process "$watcher"
  waited=0
  while [ ! -f "$home/state/.last-watcher-beat" ] && [ "$waited" -lt 100 ]; do sleep .1; waited=$((waited+1)); done
  [ -f "$home/state/.last-watcher-beat" ] || fail "root-race watcher did not enter its owned cycle"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "root-race publication holder did not exit"
  wait_for_startup_network_wake "$home" 150 || fail "root-race current completion did not recover without another startup"
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  assert_grep CURRENT_RESULT "$home/state/.startup-network.report" "root creation race lost current findings"
  assert_no_grep "$old" "$home/state/.wake-queue" "old root winner delivered against its successor"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" -eq 1 ] || fail "root creation race duplicated delivery"
  pass "fm-startup-network: concurrent root creation cannot strand the current worker"
}

test_successor_reservation_fences_in_progress_recovery() {
  local rec home root log old current recovery rc waited=0
  rec=$(new_world reservation-during-recovery)
  IFS='|' read -r home root log <<< "$rec"
  mkdir "$home/state/.startup-network.report"
  rc=0
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT=OLD_RESULT \
    run_stage "$home" "$root" run --locked 0 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the old result was not retained behind failed publication"
  old=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  rmdir "$home/state/.startup-network.report"
  export FM_TEST_REAL_LN
  FM_TEST_REAL_LN=$(command -v ln)
  cat > "$root/bin/ln" <<'SH'
#!/usr/bin/env bash
if [ "${FM_STARTUP_TEST_ROLE:-}" = recovery ] && [ "${!#}" = "$FM_HOME/state/.startup-network.lock" ]; then
  printf 'waiting\n' > "$FM_HOME/recovery-at-reservation"
  for ((i=0;i<100;i++)); do
    [ ! -f "$FM_HOME/release-recovery" ] || exec "$FM_TEST_REAL_LN" "$@"
    sleep .1
  done
  exit 1
fi
exec "$FM_TEST_REAL_LN" "$@"
SH
  chmod +x "$root/bin/ln"
  FM_STARTUP_TEST_ROLE=recovery run_stage "$home" "$root" recover --generation "$old" 10 \
    > "$home/recover.out" 2> "$home/recover.err" &
  recovery=$!
  track_startup_fixture_process "$recovery"
  while [ ! -s "$home/recovery-at-reservation" ] && [ "$waited" -lt 50 ]; do sleep .1; waited=$((waited+1)); done
  [ -s "$home/recovery-at-reservation" ] || fail "old recovery did not reach its publication lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=2 FM_FAKE_BOOTSTRAP_OUT=FRESH_RESULT \
    FM_SESSION_START_TIMEOUT=2 run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  current=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  [ "$current" != "$old" ] || fail "in-progress stale recovery prevented a fresh reservation"
  touch "$home/release-recovery"
  wait "$recovery" || fail "stale recovery did not settle as a no-op"
  [ "$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")" = "$current" ] \
    || fail "old recovery overwrote the running successor"
  assert_no_grep "$old" "$home/state/.wake-queue" "in-progress recovery delivered a superseded generation"
  wait_for_startup_network_wake "$home" 100 || fail "successor checks did not deliver"
  assert_grep FRESH_RESULT "$home/state/.startup-network.report" "old recovery overwrote successor findings"
  [ "$(wc -l < "$log" | tr -d ' ')" -eq 2 ] || fail "fresh checks did not execute independently of old recovery"
  pass "fm-startup-network: successor reservation fences a recovery already waiting to publish"
}

# Focused selection keeps failure reproduction bounded without skipping the
# default full suite. Names must be declared test interfaces, never eval input.
if [ -n "${FM_STARTUP_NETWORK_CASES:-}" ]; then
  for startup_case in $FM_STARTUP_NETWORK_CASES; do
    case "$startup_case" in test_*) ;; *) fail "invalid startup case: $startup_case" ;; esac
    declare -F "$startup_case" >/dev/null || fail "unknown startup case: $startup_case"
    "$startup_case"
  done
  exit 0
fi

test_aged_running_record_cannot_borrow_an_unrelated_pid
test_running_and_refused_records_have_correct_supervision
test_optional_timing_failure_preserves_completion
test_current_worker_survives_losing_result_root_creation
test_successor_reservation_fences_in_progress_recovery
test_report_refuses_a_missing_or_unsafe_explicit_generation
test_existing_watcher_recovers_after_worker_deadline
test_stale_completions_cannot_publish_or_block_fresh_checks

test_failed_publication_keeps_a_recoverable_completed_result
test_wait_fails_without_a_published_stage
test_start_returns_without_holding_the_callers_stdout
test_harvest_acknowledgement_suppresses_the_wake_and_no_claim_produces_it
test_a_claimant_crash_after_publish_still_queues_the_wake
test_a_report_publication_failure_retains_findings_until_recovery
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
echo "# fm-startup-network.test.sh: all assertions passed"
