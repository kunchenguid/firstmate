#!/usr/bin/env bash
# Behavior tests for the remote transport's per-home lanes, caller-disconnect
# cancellation, stdin default, and staging-litter reaping.
#
# Pins, against the real worker and the real fm-on -> entrypoint transport
# (through the deterministic FM_SSH_BIN seam tests/fm-on.test.sh proves
# preserves exit status):
#   T9: a job for home B completes while home A runs a long job, and two
#       A-jobs execute strictly in stage order even when staged rapidly.
#   T3: a caller killed mid-wait cancels its job - the worker never executes a
#       cancelled queued job and terminates a running cancelled job's process
#       group - and a caller whose parent dies without delivering a signal
#       (the dead-ssh-channel shape) cancels the same way; afterwards a burst
#       of short commands completes with no convoy.
#   T6: a non-payload fm-on call with an OPEN stdin pipe completes instead of
#       wedging staging, and a payload caller with --stdin still delivers its
#       bytes through the worker.
#   Stage litter older than the reap age does not survive a worker pass while
#   fresh staging does.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-transport-lanes)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
HOME_A="$TMP_ROOT/home-a"
HOME_B="$TMP_ROOT/home-b"
HOME_EDGE="$TMP_ROOT/home-a "
LOCAL_HOME="$TMP_ROOT/local-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
mkdir -p "$REMOTE_ROOT/bin" "$HOME_A" "$HOME_B" "$HOME_EDGE" "$LOCAL_HOME/data" "$ACCOUNT_HOME"

cleanup_lane_fixture() {
  if [ -f "$STATE_ROOT/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$STATE_ROOT/worker.pid")" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_lane_fixture EXIT

cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" \
  "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-delta-read.sh" \
  "$ROOT/bin/fm-remote-secondmate-control.sh" "$ROOT/bin/fm-backend.sh" \
  "$ROOT/bin/fm-pending-reply-lib.sh" "$ROOT/bin/fm-task-inbox-lib.sh" \
  "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-marker-lib.sh" \
  "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-tmux-lib.sh" \
  "$ROOT/bin/fm-composer-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" \
  "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" \
  "$ROOT/bin/fm-ff-lib.sh" "$ROOT/bin/fm-secondmate-registry-lib.sh" \
  "$REMOTE_ROOT/bin/"
mkdir -p "$REMOTE_ROOT/bin/backends"
cp "$ROOT/bin/backends/herdr.sh" "$REMOTE_ROOT/bin/backends/herdr.sh"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
# Appends its tag to a shared log, then optionally sleeps: the log order is the
# observable execution order.
cat > "$REMOTE_ROOT/bin/fm-mark-job.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$2"
if [ "${3:-0}" = hold ]; then
  while [ ! -e "$4" ]; do sleep 0.1; done
else
  sleep "${3:-0}"
fi
SH
cat > "$REMOTE_ROOT/bin/fm-touch-job.sh" <<'SH'
#!/bin/bash
printf 'ran\n' > "$1"
SH
# Marks its start, sleeps, then marks completion: cancellation must leave the
# start marker without the completion marker.
cat > "$REMOTE_ROOT/bin/fm-two-phase-job.sh" <<'SH'
#!/bin/bash
printf 'started\n' > "$1"
sleep "$3"
printf 'finished\n' > "$2"
SH
cat > "$REMOTE_ROOT/bin/fm-stdin-probe.sh" <<'SH'
#!/bin/bash
while IFS= read -r line || [ -n "$line" ]; do printf 'stdin=%s\n' "$line"; done
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'lane transport fixture'

# ios routes to home A, build routes to home B.
cat > "$LOCAL_HOME/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $REMOTE_ROOT; home: $HOME_A; scope: iOS work; projects: alpha; added 2026-08-02)
- build - build delivery (host: remote-mac; root: $REMOTE_ROOT; home: $HOME_B; scope: build work; projects: beta; added 2026-08-02)
EOF

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
shift 2
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=$((60 * FM_TEST_TIMEOUT_SCALE))
export FM_REMOTE_JOB_TIMEOUT=$((30 * FM_TEST_TIMEOUT_SCALE))
export FM_REMOTE_JOB_STAGE_REAP_SECONDS=1
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

fm_remote_job_prepare_state "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"
rm -f -- "$STATE_ROOT/seq"
SEQ_PIDS=()
for i in $(seq 1 20); do
  fm_remote_job_next_seq > "$TMP_ROOT/seq-$i" &
  SEQ_PIDS+=("$!")
done
for pid in "${SEQ_PIDS[@]}"; do
  wait "$pid" || fail "a concurrent sequence allocator failed"
done
SEQ_RESULTS=$(cat "$TMP_ROOT"/seq-* | sort -n)
SEQ_EXPECTED=$(seq 1 20)
[ "$SEQ_RESULTS" = "$SEQ_EXPECTED" ] \
  || fail "concurrent sequence claims were not unique and monotonic: $SEQ_RESULTS"
[ "$(find "$STATE_ROOT/.seq-claims" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 20 ] \
  || fail "concurrent sequence allocations did not retain every durable claim"
mkdir "$STATE_ROOT/.seq-claims/999998" "$STATE_ROOT/.seq-claims/999999"
touch -t 200001010000 "$STATE_ROOT/.seq-claims/999998"
fm_remote_job_reap_stale "$ACCOUNT_HOME" || fail "sequence claim reaping failed"
assert_absent "$STATE_ROOT/.seq-claims/999998" "an expired sequence claim survived stale reaping"
assert_present "$STATE_ROOT/.seq-claims/999999" "a fresh sequence claim was reaped"
mkdir "$STATE_ROOT/.seq-claims/999997"
touch -t 200001010000 "$STATE_ROOT/.seq-claims/999997"
fm_remote_job_reap_stale "$ACCOUNT_HOME" || fail "rate-limited sequence claim reaping failed"
assert_present "$STATE_ROOT/.seq-claims/999997" "sequence claims were rescanned before the hourly interval"
touch -t 200001010000 "$STATE_ROOT/.seq-claims-reaped"
fm_remote_job_reap_stale "$ACCOUNT_HOME" || fail "expired sequence claim reaping failed"
assert_absent "$STATE_ROOT/.seq-claims/999997" "an expired sequence claim survived the next hourly scan"
rmdir "$STATE_ROOT/.seq-claims/999999"
pass "atomic sequence claims remain unique and reap only after expiry"

fm_on() {
  FM_HOME="$LOCAL_HOME" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  "$ROOT/bin/fm-on.sh" "$@"
}

job_state() { # <id>
  fm_remote_job_read_state "$STATE_ROOT/jobs/$1" 2>/dev/null || true
}

wait_for_state() { # <id> <state>
  local i=0
  while [ "$i" -lt "$((200 * FM_TEST_TIMEOUT_SCALE))" ]; do
    [ "$(job_state "$1")" = "$2" ] && return 0
    i=$((i + 1))
    sleep 0.05
  done
  return 1
}

HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
for _ in $(seq 1 "$((100 * FM_TEST_TIMEOUT_SCALE))"); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.ready" "the worker did not publish its readiness heartbeat"

# T9: home B's job completes while home A runs a long job, and A's queued job
# stays strictly behind A's running job.
LOG_A="$TMP_ROOT/log-a"
LOG_B="$TMP_ROOT/log-b"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_A" fm-mark-job.sh a1 "$LOG_A" hold "$TMP_ROOT/a1.release" < /dev/null > /dev/null
A1=$FM_REMOTE_JOB_ID
wait_for_state "$A1" running || fail "home A's long job did not begin running"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_A" fm-mark-job.sh a2 "$LOG_A" 0 < /dev/null > /dev/null
A2=$FM_REMOTE_JOB_ID
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_EDGE" fm-mark-job.sh b1 "$LOG_B" 0 < /dev/null > /dev/null
B1=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$B1" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "home B's job behind home A's long job did not complete"
[ "$(job_state "$A1")" = running ] || fail "home A's long job should still be running for the FIFO assertion"
[ "$(cat "$LOG_A")" = a1 ] || fail "home A's queued job ran beside its running job: $(cat "$LOG_A")"
fm_remote_job_reap "$ACCOUNT_HOME" "$B1" || fail "home B's job could not be reaped"
touch "$TMP_ROOT/a1.release"
fm_remote_job_wait "$ACCOUNT_HOME" "$A1" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$A2" || fail "$FM_REMOTE_JOB_ERROR"
[ "$(printf '%s' "$(cat "$LOG_A")")" = "$(printf 'a1\na2')" ] \
  || fail "home A's jobs did not execute in stage order: $(cat "$LOG_A")"
fm_remote_job_reap "$ACCOUNT_HOME" "$A1" || fail "home A's first job could not be reaped"
fm_remote_job_reap "$ACCOUNT_HOME" "$A2" || fail "home A's second job could not be reaped"
pass "lanes run homes concurrently while each home stays FIFO"

# T9 stage order: five jobs staged in rapid succession behind a busy lane must
# execute in staging-sequence order, not the queue directory's random-id order.
: > "$LOG_A"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_A" fm-mark-job.sh hold "$LOG_A" hold "$TMP_ROOT/rapid.release" < /dev/null > /dev/null
HOLD=$FM_REMOTE_JOB_ID
wait_for_state "$HOLD" running || fail "the lane-holding job did not begin running"
RAPID_IDS=()
for tag in r1 r2 r3 r4 r5; do
  fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_A" fm-mark-job.sh "$tag" "$LOG_A" 0 < /dev/null > /dev/null
  RAPID_IDS+=("$FM_REMOTE_JOB_ID")
done
touch "$TMP_ROOT/rapid.release"
fm_remote_job_wait "$ACCOUNT_HOME" "$HOLD" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_reap "$ACCOUNT_HOME" "$HOLD" || true
for id in "${RAPID_IDS[@]}"; do
  fm_remote_job_wait "$ACCOUNT_HOME" "$id" || fail "$FM_REMOTE_JOB_ERROR"
  fm_remote_job_reap "$ACCOUNT_HOME" "$id" || true
done
[ "$(cat "$LOG_A")" = "$(printf 'hold\nr1\nr2\nr3\nr4\nr5')" ] \
  || fail "rapidly staged same-home jobs did not execute in stage order: $(tr '\n' ' ' < "$LOG_A")"
pass "same-home jobs staged behind a held lane execute in staging-sequence order"

: > "$LOG_A"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_A" fm-mark-job.sh publish-hold "$LOG_A" hold "$TMP_ROOT/publication.release" < /dev/null > /dev/null
PUBLISH_HOLD=$FM_REMOTE_JOB_ID
wait_for_state "$PUBLISH_HOLD" running || fail "the publication-order lane holder did not begin running"
(
  {
    printf 'delayed payload\n'
    fm_test_wait_until 300 test -e "$TMP_ROOT/stdin.release" || exit 1
  } | fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_A" \
    fm-mark-job.sh delayed "$LOG_A" 0
) > "$TMP_ROOT/delayed-stage-id" &
DELAYED_STAGE_PID=$!
for _ in $(seq 1 "$((200 * FM_TEST_TIMEOUT_SCALE))"); do
  ls "$STATE_ROOT/jobs"/.stage.* >/dev/null 2>&1 && break
  sleep 0.02
done
ls "$STATE_ROOT/jobs"/.stage.* >/dev/null 2>&1 \
  || fail "the delayed stdin stage did not begin capturing"
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_A" fm-mark-job.sh fast "$LOG_A" 0 < /dev/null > /dev/null
FAST_STAGE=$FM_REMOTE_JOB_ID
touch "$TMP_ROOT/stdin.release"
wait "$DELAYED_STAGE_PID" || fail "the delayed stdin stage failed to publish"
DELAYED_STAGE=$(cat "$TMP_ROOT/delayed-stage-id")
FAST_SEQ=$(fm_remote_job_read_number "$STATE_ROOT/jobs/$FAST_STAGE" seq) \
  || fail "the fast stage lost its sequence"
DELAYED_SEQ=$(fm_remote_job_read_number "$STATE_ROOT/jobs/$DELAYED_STAGE" seq) \
  || fail "the delayed stage lost its sequence"
[ "$FAST_SEQ" -lt "$DELAYED_SEQ" ] \
  || fail "sequence order did not follow publication order: fast=$FAST_SEQ delayed=$DELAYED_SEQ"
touch "$TMP_ROOT/publication.release"
fm_remote_job_wait "$ACCOUNT_HOME" "$PUBLISH_HOLD" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$FAST_STAGE" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_wait "$ACCOUNT_HOME" "$DELAYED_STAGE" || fail "$FM_REMOTE_JOB_ERROR"
[ "$(cat "$LOG_A")" = "$(printf 'publish-hold\nfast\ndelayed')" ] \
  || fail "execution order diverged from publication sequence: $(tr '\n' ' ' < "$LOG_A")"
fm_remote_job_reap "$ACCOUNT_HOME" "$PUBLISH_HOLD" || true
fm_remote_job_reap "$ACCOUNT_HOME" "$FAST_STAGE" || true
fm_remote_job_reap "$ACCOUNT_HOME" "$DELAYED_STAGE" || true
pass "same-home sequence order follows completed staging publication"

# T3a: a caller killed while its job is still queued cancels it; the worker
# never executes it.
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$HOME_A" fm-mark-job.sh hold2 "$LOG_A" hold "$TMP_ROOT/cancel.release" < /dev/null > /dev/null
HOLD2=$FM_REMOTE_JOB_ID
wait_for_state "$HOLD2" running || fail "the cancellation fixture's lane holder did not begin running"
QUEUED_EFFECT="$TMP_ROOT/queued-cancel-effect"
fm_on ios fm-touch-job.sh "$QUEUED_EFFECT" > /dev/null 2>&1 &
QUEUED_CALLER=$!
QUEUED_JOB=
for _ in $(seq 1 "$((200 * FM_TEST_TIMEOUT_SCALE))"); do
  for job in "$STATE_ROOT"/jobs/job-*; do
    [ -d "$job" ] || continue
    [ "${job##*/}" = "$HOLD2" ] && continue
    [ "$(job_state "${job##*/}")" = queued ] && QUEUED_JOB=${job##*/} && break
  done
  [ -n "$QUEUED_JOB" ] && break
  sleep 0.05
done
[ -n "$QUEUED_JOB" ] || fail "the doomed caller's job never appeared in the queue"
kill -TERM "$QUEUED_CALLER" 2>/dev/null || true
wait "$QUEUED_CALLER" 2>/dev/null || true
for _ in $(seq 1 "$((200 * FM_TEST_TIMEOUT_SCALE))"); do
  [ ! -d "$STATE_ROOT/jobs/$QUEUED_JOB" ] && break
  sleep 0.05
done
[ ! -d "$STATE_ROOT/jobs/$QUEUED_JOB" ] \
  || fail "the cancelled queued job's record survived (state: $(job_state "$QUEUED_JOB"))"
touch "$TMP_ROOT/cancel.release"
fm_remote_job_wait "$ACCOUNT_HOME" "$HOLD2" || fail "$FM_REMOTE_JOB_ERROR"
fm_remote_job_reap "$ACCOUNT_HOME" "$HOLD2" || true
assert_absent "$QUEUED_EFFECT" "the worker executed a queued job whose caller was killed"
pass "a caller killed mid-wait cancels its queued job before execution"

# T3b: a caller killed while its job is running terminates the job's process
# group instead of letting it run to completion for nobody.
RUN_START="$TMP_ROOT/running-cancel-start"
RUN_FINISH="$TMP_ROOT/running-cancel-finish"
fm_on build fm-two-phase-job.sh "$RUN_START" "$RUN_FINISH" 8 > /dev/null 2>&1 &
RUNNING_CALLER=$!
for _ in $(seq 1 "$((200 * FM_TEST_TIMEOUT_SCALE))"); do
  [ -f "$RUN_START" ] && break
  sleep 0.05
done
assert_present "$RUN_START" "the running-cancellation fixture never started"
kill -TERM "$RUNNING_CALLER" 2>/dev/null || true
wait "$RUNNING_CALLER" 2>/dev/null || true
CANCEL_BEGAN=$(date +%s)
for _ in $(seq 1 "$((200 * FM_TEST_TIMEOUT_SCALE))"); do
  ls "$STATE_ROOT"/jobs/job-* >/dev/null 2>&1 || break
  sleep 0.05
done
CANCEL_ELAPSED=$(( $(date +%s) - CANCEL_BEGAN ))
ls "$STATE_ROOT"/jobs/job-* >/dev/null 2>&1 \
  && fail "the cancelled running job's record survived"
[ "$CANCEL_ELAPSED" -le 6 ] || fail "running-job cancellation took ${CANCEL_ELAPSED}s"
sleep 2
assert_absent "$RUN_FINISH" "a cancelled running job's process group ran to completion"
pass "a caller killed mid-wait stops its running job's process group"

# T3c: a caller whose parent exits WITHOUT delivering any signal - the shape a
# dead ssh channel leaves behind - still cancels through the entrypoint's
# parent-liveness probe.
ORPHAN_START="$TMP_ROOT/orphan-cancel-start"
ORPHAN_FINISH="$TMP_ROOT/orphan-cancel-finish"
# shellcheck disable=SC2016 # Expansion is deliberately deferred to the child shell.
env FM_HOME="$LOCAL_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  bash -c '
    "$1/bin/fm-on.sh" build fm-two-phase-job.sh "$2" "$3" 12 >/dev/null 2>&1 &
    while [ ! -f "$2" ]; do sleep 0.1; done
  ' _ "$ROOT" "$ORPHAN_START" "$ORPHAN_FINISH"
assert_present "$ORPHAN_START" "the orphan-cancellation fixture never started"
ORPHAN_BEGAN=$(date +%s)
for _ in $(seq 1 "$((300 * FM_TEST_TIMEOUT_SCALE))"); do
  ls "$STATE_ROOT"/jobs/job-* >/dev/null 2>&1 || break
  sleep 0.05
done
ORPHAN_ELAPSED=$(( $(date +%s) - ORPHAN_BEGAN ))
ls "$STATE_ROOT"/jobs/job-* >/dev/null 2>&1 \
  && fail "the orphaned caller's job record survived its disconnect"
[ "$ORPHAN_ELAPSED" -le 10 ] || fail "orphan-disconnect cancellation took ${ORPHAN_ELAPSED}s"
sleep 2
assert_absent "$ORPHAN_FINISH" "a job abandoned by a signal-less disconnect ran to completion"
pass "a signal-less caller disconnect cancels the abandoned job through the parent probe"

# T3: after the cancellations, a burst of short bounded commands meets its own
# budget - no convoy behind abandoned work.
BURST_BEGAN=$(date +%s)
for tag in c1 c2 c3; do
  rc=0
  fm_run_timed 15 env FM_HOME="$LOCAL_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
    FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$ROOT/bin/fm-on.sh" ios fm-touch-job.sh "$TMP_ROOT/burst-$tag" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "post-cancellation burst command $tag failed with $rc"
  assert_present "$TMP_ROOT/burst-$tag" "post-cancellation burst command $tag did not run"
done
BURST_ELAPSED=$(( $(date +%s) - BURST_BEGAN ))
[ "$BURST_ELAPSED" -le 12 ] || fail "the post-cancellation burst convoyed for ${BURST_ELAPSED}s"
pass "bounded reads after a cancellation meet their own budget with no convoy"

# T6: a non-payload call with an OPEN stdin pipe completes instead of wedging
# staging on a stdin capture that never reaches EOF.
printf 'rsm\n' > "$HOME_A/.fm-secondmate-home"
printf '# fixture secondmate home\n' > "$HOME_A/AGENTS.md"
mkdir -p "$HOME_A/state" "$HOME_A/bin"
rc=0
fm_run_timed 20 env FM_HOME="$LOCAL_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state rsm \
  < <(sleep 30) > "$TMP_ROOT/state-out" 2> "$TMP_ROOT/state-err" || rc=$?
[ "$rc" -ne 124 ] || fail "a control-state call with an open stdin pipe wedged staging"
assert_grep 'missing' "$TMP_ROOT/state-out" \
  "the control-state call did not complete through the worker: $(cat "$TMP_ROOT/state-err")"
pass "an open caller stdin no longer wedges a non-payload remote command"

# A live explicit stdin stage can exceed the litter age while waiting for EOF;
# the stale sweep must retain it until its owning entrypoint publishes the job.
rc=0
{
  printf 'slow payload one\n'
  sleep 3
  printf 'slow payload two\n'
} | fm_on --stdin ios fm-stdin-probe.sh > "$TMP_ROOT/slow-payload-out" 2> "$TMP_ROOT/slow-payload-err" || rc=$?
expect_code 0 "$rc" "a live slow stdin stage must survive stale reaping: $(cat "$TMP_ROOT/slow-payload-err")"
assert_grep 'stdin=slow payload one' "$TMP_ROOT/slow-payload-out" "the slow stdin stage lost its first bytes"
assert_grep 'stdin=slow payload two' "$TMP_ROOT/slow-payload-out" "the slow stdin stage was reaped before EOF"
pass "a live explicit-stdin stage survives the staging-litter age bound"

# T6: a payload caller with --stdin still delivers its bytes.
printf 'payload byte one\npayload byte two\n' > "$TMP_ROOT/payload"
fm_on --stdin ios fm-stdin-probe.sh < "$TMP_ROOT/payload" > "$TMP_ROOT/payload-out" 2>/dev/null \
  || fail "the --stdin payload call failed"
assert_grep 'stdin=payload byte one' "$TMP_ROOT/payload-out" "--stdin did not deliver the payload"
assert_grep 'stdin=payload byte two' "$TMP_ROOT/payload-out" "--stdin lost part of the payload"
pass "--stdin still delivers a payload caller's bytes"

# Stage litter: an abandoned .stage.* older than the reap age does not survive
# a worker pass, while staging owned by this live process is left alone even if
# CI scheduling pauses long enough for it to cross the age bound.
OLD_STAGE="$STATE_ROOT/jobs/.stage.abandoned"
LIVE_STAGE="$STATE_ROOT/jobs/.stage.live"
LIVE_STAGE_BUILD="$STATE_ROOT/jobs/.stage-live-build"
mkdir -p "$OLD_STAGE" "$LIVE_STAGE_BUILD"
printf '%s\n' "$$" > "$LIVE_STAGE_BUILD/.owner-pid"
fm_remote_job_process_start "$$" > "$LIVE_STAGE_BUILD/.owner-start" \
  || fail "the live staging fixture could not record its owner identity"
mv -- "$LIVE_STAGE_BUILD" "$LIVE_STAGE"
touch -t 200001010000 "$OLD_STAGE" "$LIVE_STAGE"
for _ in $(seq 1 "$((100 * FM_TEST_TIMEOUT_SCALE))"); do
  [ ! -d "$OLD_STAGE" ] && break
  sleep 0.05
done
[ ! -d "$OLD_STAGE" ] || fail "stage litter older than the reap age survived the worker pass"
assert_present "$LIVE_STAGE" "the worker reaped staging owned by a live process"
rm -rf -- "$LIVE_STAGE"
pass "abandoned stage litter is reaped by age while live staging survives"

echo "ALL TESTS PASSED"
