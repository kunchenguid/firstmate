#!/usr/bin/env bash
# Behavior tests for the remote job supervisor storm.
#
# The storm this pins: each fm-on call's ensure path started another Linux
# restart supervisor whenever it could not recognise the worker already
# serving, and nothing bounded supervisors across the account, so a host
# reached hundreds of them. Two triggers fed it: an identity check that
# depended on the reader's locale and time zone, so a doctor-started worker was
# never recognised by an SSH caller, and a worker lock left holding no owner by
# an unclean shutdown, which no later worker could reclaim.
#
# Each case owns its own state root and every worker it starts runs from this
# fixture's own code root, so nothing here touches another test's workers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-storm)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
WORKER="$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
HOLDER_PID=

worker_pids() { pgrep -f "$WORKER" 2>/dev/null || true; }

# Top-level supervisors launched from this fixture's code root.
supervisor_count() {
  local pid count=0
  for pid in $(pgrep -f "^/bin/bash $WORKER\$" 2>/dev/null || true); do
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

stop_fixture_workers() {
  local pid
  for pid in $(worker_pids); do
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
}

storm_cleanup() {
  [ -z "$HOLDER_PID" ] || kill -KILL "$HOLDER_PID" 2>/dev/null || true
  stop_fixture_workers
  fm_test_cleanup
}
trap storm_cleanup EXIT

mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
cat > "$REMOTE_ROOT/bin/fm-probe-job.sh" <<'SH'
#!/bin/bash
printf 'served\n'
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'remote job fixture'

export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=10
export FM_REMOTE_JOB_TIMEOUT=10
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

STATE=
use_state() { # <case-name>
  stop_fixture_workers
  STATE="$TMP_ROOT/state-$1"
  export FM_REMOTE_JOB_STATE_ROOT="$STATE"
  fm_remote_job_prepare_state "$ACCOUNT_HOME" || fail "cannot prepare the $1 state root"
}

wait_for_supervisors() { # <expected> <seconds>
  local deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(supervisor_count)" -eq "$1" ] && return 0
    sleep 0.1
  done
  [ "$(supervisor_count)" -eq "$1" ]
}

run_probe_job() {
  local id
  id=$(fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh < /dev/null) ||
    fail "cannot stage a probe job: $FM_REMOTE_JOB_ERROR"
  fm_remote_job_wait "$ACCOUNT_HOME" "$id" || fail "the probe job was not served: $FM_REMOTE_JOB_ERROR"
  [ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the probe job exited $FM_REMOTE_JOB_EXIT"
  fm_remote_job_reap "$ACCOUNT_HOME" "$id" || true
}

# --- 1. the leak: ensure adopts the healthy worker it finds ------------------

# The doctor starts the worker under env -i while every fm-on call ensures from
# an SSH login environment. Two different time zones drive ps lstart apart on
# macOS and Linux alike, which is exactly what made each call add a supervisor.
use_state adopt
(export TZ=UTC0 LC_ALL=C; fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME") ||
  fail "the doctor-shaped start failed"
wait_for_supervisors 1 5 || fail "the first ensure did not leave exactly one supervisor"
FIRST_WORKER=$(cat "$STATE/worker.pid")
OWNER_START=$(cat "$STATE/worker.lock/start")
if [ -r "/proc/$$/stat" ]; then
  case "$OWNER_START" in proc-starttime:*) ;; *) fail "a /proc host recorded a non-kernel owner identity: $OWNER_START" ;; esac
  START_TICKS=${OWNER_START#proc-starttime:}
  START_TICKS=${START_TICKS%%:*}
  STAT_LINE=$(cat "/proc/$FIRST_WORKER/stat")
  read -r -a STAT_FIELDS <<< "${STAT_LINE##*)}"
  [ "$START_TICKS" = "${STAT_FIELDS[19]}" ] ||
    fail "the recorded start ticks $START_TICKS are not the worker's /proc starttime ${STAT_FIELDS[19]}"
  echo "identity path: proc-starttime"
else
  case "$OWNER_START" in lstart-utc:*) ;; *) fail "a host without /proc recorded an unpinned owner identity: $OWNER_START" ;; esac
  echo "identity path: lstart-utc"
fi
[ "$(TZ=UTC0 /bin/ps -p "$FIRST_WORKER" -o lstart=)" != "$(TZ=XYZ-9 /bin/ps -p "$FIRST_WORKER" -o lstart=)" ] ||
  fail "the fixture's two time zones render the same start time, so this case would prove nothing"
for call in 1 2; do
  (export TZ=XYZ-9; fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME") ||
    fail "ensure call $call failed: $FM_REMOTE_JOB_ERROR"
done
[ "$(supervisor_count)" -eq 1 ] ||
  fail "two ensures in a row left $(supervisor_count) supervisors instead of adopting the healthy one"
[ "$(cat "$STATE/worker.pid")" = "$FIRST_WORKER" ] || fail "ensure replaced the healthy worker"
run_probe_job
pass "two ensures in a row adopt the healthy worker whatever environment started it"

# --- 2. a lock that names nobody is reclaimed --------------------------------

# After a power cut the lock held its command record and the temp records of an
# owner killed mid-publication, but no pid or start. rmdir cannot remove such a
# directory, which used to make every later worker exit.
for shape in missing empty; do
  use_state "unowned-$shape"
  LOCK="$STATE/worker.lock"
  mkdir -m 700 "$LOCK"
  printf '/bin/bash %s --serve\n' "$WORKER" > "$LOCK/command"
  : > "$LOCK/.pid.AbC123"
  : > "$LOCK/.start.XyZ789"
  [ "$shape" = missing ] || : > "$LOCK/pid"
  touch -t 200001010000 "$LOCK"
  fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" ||
    fail "a lock with a $shape pid record was not reclaimed: $FM_REMOTE_JOB_ERROR"
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$(cat "$STATE/worker.pid")" ] ||
    fail "the replacement worker does not own the reclaimed lock"
  assert_absent "$LOCK/.pid.AbC123" "the reclaimed lock kept an interrupted owner's temp record"
  run_probe_job
done
pass "a lock whose pid names nobody is reclaimed, temp records and all"

use_state dead-owner
LOCK="$STATE/worker.lock"
sh -c 'exit 0' &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
mkdir -m 700 "$LOCK"
printf '%s\n' "$DEAD_PID" > "$LOCK/pid"
touch -t 200001010000 "$LOCK"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" ||
  fail "a lock naming an exited owner was not reclaimed: $FM_REMOTE_JOB_ERROR"
pass "a lock whose recorded owner has exited is reclaimed"

# The same unclean shutdown leaves job claims holding no owner, one level down.
stop_fixture_workers
CLAIMED_ID=$(fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh < /dev/null) ||
  fail "cannot stage the ownerless-claim job"
mkdir -m 700 "$STATE/jobs/$CLAIMED_ID/.claim"
: > "$STATE/jobs/$CLAIMED_ID/.claim/.owner.AbC123"
touch -t 200001010000 "$STATE/worker.ready" "$STATE/worker.lock"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail "the claim fixture's worker did not start"
fm_remote_job_wait "$ACCOUNT_HOME" "$CLAIMED_ID" || fail "a job whose claim names no owner was never served"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || fail "the ownerless-claim job exited $FM_REMOTE_JOB_EXIT"
pass "a job claim that names no owner is reclaimed and its job served"

# Concurrent children after a power cut all judge the same stale lock
# reclaimable; one reclaims it and a new owner takes the lock before a slower
# reclaimer acts on its earlier judgement.
use_state reclaim-race
LOCK="$STATE/worker.lock"
mkdir -m 700 "$LOCK"
: > "$LOCK/.pid.AbC123"
touch -t 200001010000 "$LOCK"
fm_remote_job_lock_owner_status "$ACCOUNT_HOME"
STALE_STATUS=$?
fm_remote_job_lock_reclaimable "$ACCOUNT_HOME" "$STALE_STATUS" || fail "the stale ownerless lock was not judged reclaimable"
fm_remote_job_reclaim_lock_dir "$ACCOUNT_HOME" || fail "the first reclaimer did not reclaim the stale lock"
sleep 30 &
HOLDER_PID=$!
mkdir -m 700 "$LOCK"
printf '%s\n' "$HOLDER_PID" > "$LOCK/pid"
fm_remote_job_reclaim_lock_dir "$ACCOUNT_HOME"
RECLAIM_STATUS=$?
[ "$RECLAIM_STATUS" -eq 2 ] || fail "a reclaim acting on a stale judgement returned $RECLAIM_STATUS instead of keeping the fresh lock"
[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$HOLDER_PID" ] || fail "a late reclaim removed the fresh lock or its owner record"
assert_absent "$LOCK.reclaim" "the reclaim left its mutex behind"
mkdir -m 700 "$LOCK.reclaim"
touch -t 200001010000 "$LOCK.reclaim"
rm -rf -- "$LOCK"
mkdir -m 700 "$LOCK"
touch -t 200001010000 "$LOCK"
fm_remote_job_reclaim_lock_dir "$ACCOUNT_HOME" || fail "a mutex abandoned by a killed reclaimer wedged reclaim"
assert_absent "$LOCK" "the reclaim behind an abandoned mutex kept the stale lock"
kill -KILL "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=
pass "a late reclaim keeps a fresh lock and an abandoned reclaim mutex never wedges reclaim"

# --- 2b. a lock whose live owner cannot be verified is preserved --------------

use_state unverifiable
LOCK="$STATE/worker.lock"
sleep 120 &
HOLDER_PID=$!
mkdir -m 700 "$LOCK"
printf '%s\n' "$HOLDER_PID" > "$LOCK/pid"
touch -t 200001010000 "$LOCK"
UNVERIFIED_ERR=$(HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" "$WORKER" --serve 2>&1 >/dev/null)
UNVERIFIED_RC=$?
[ "$UNVERIFIED_RC" -ne 0 ] || fail "a worker acquired a lock whose live owner it could not verify"
assert_contains "$UNVERIFIED_ERR" "identity cannot be verified" "the refusal did not say why the lock was preserved"
[ "$(cat "$LOCK/pid")" = "$HOLDER_PID" ] || fail "the unverifiable owner's lock record was removed"
kill -0 "$HOLDER_PID" 2>/dev/null || fail "the unverifiable owner was signalled"
kill -KILL "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=
pass "a lock whose live owner cannot be verified is preserved"

# --- 3. the restart budget bounds the account, not one supervisor ------------

# A worker that fails at once, forever, is the shape of both observed triggers.
# A symlinked lock makes every serving child exit immediately. The per-supervisor
# guard stays at its default of 20, so only the account-wide budget can stop it.
use_state storm
ln -s "$TMP_ROOT" "$STATE/worker.lock"
STORM_ERR=
for call in 1 2 3 4 5 6; do
  if (export FM_REMOTE_JOB_RESTART_BUDGET=4 FM_REMOTE_JOB_SUPERVISOR_MAX_BACKOFF_SECONDS=0
    fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || { printf '%s\n' "$FM_REMOTE_JOB_ERROR" > "$TMP_ROOT/storm.err"; exit 1; }); then
    fail "ensure call $call reported a worker that cannot run as ready"
  fi
done
STORM_ERR=$(cat "$TMP_ROOT/storm.err")
assert_contains "$STORM_ERR" "restarts are suspended" "the exhausted budget did not fail loudly"
assert_contains "$STORM_ERR" "fm-remote-doctor.sh --fix" "the suspension did not name its recovery"
assert_present "$STATE/worker.restart-suspended" "the exhausted budget published no suspension"
wait_for_supervisors 0 10 || fail "$(supervisor_count) supervisors kept running after the budget was exhausted"
STARTS=$(cat "$STATE"/logs/*.log 2>/dev/null | grep -c 'cannot acquire or safely reclaim worker ownership' || true)
[ "$STARTS" -ge 1 ] || fail "the failing worker never ran, so this case proves nothing"
[ "$STARTS" -le 4 ] || fail "$STARTS workers started across six ensures despite a budget of 4"
pass "a worker that fails immediately stops at the account-wide bound across every supervisor"

(export FM_REMOTE_JOB_RESTART_BUDGET=4; fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME") &&
  fail "a suspended account started a worker"
[ "$(supervisor_count)" -eq 0 ] || fail "a suspended account started a supervisor"
rm -f "$STATE/worker.lock"
fm_remote_job_restart_resume || fail "the suspension could not be lifted"
(export FM_REMOTE_JOB_RESTART_BUDGET=4; fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME") ||
  fail "the resumed account did not start its worker"
wait_for_supervisors 1 5 || fail "the resumed account did not run exactly one supervisor"
run_probe_job
pass "a suspension holds until resumed, then exactly one worker starts"

# --- 4. the supported recovery collapses duplicates to the lock owner --------

# A host running an older build keeps multiplying supervisors until it updates,
# so the collapse must recognise that build's owner record: bare lstart text in
# the time zone its writer had. Callers in another zone then fail to recognise
# it and pile up, exactly as the host did.
use_state collapse
(export TZ=XYZ-9; fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME") || fail "the collapse fixture did not start"
OWNER_WORKER=$(cat "$STATE/worker.pid")
TZ=XYZ-9 /bin/ps -p "$OWNER_WORKER" -o lstart= > "$STATE/worker.lock/start"
for call in 1 2; do
  (export TZ=UTC0; fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME") ||
    fail "a duplicate-producing ensure failed: $FM_REMOTE_JOB_ERROR"
done
[ "$(supervisor_count)" -eq 3 ] || fail "the fixture expected three supervisors, found $(supervisor_count)"
DRY=$(TZ=XYZ-9 HOME="$ACCOUNT_HOME" "$ROOT/bin/fm-remote-job-reap-orphans.sh" --duplicates --dry-run)
[ "$(printf '%s\n' "$DRY" | grep -c '^would reap duplicate')" -eq 2 ] || fail "the dry run did not name exactly the two duplicates: $DRY"
[ "$(supervisor_count)" -eq 3 ] || fail "the dry run signalled a supervisor"
COLLAPSE=$(TZ=XYZ-9 HOME="$ACCOUNT_HOME" "$ROOT/bin/fm-remote-job-reap-orphans.sh" --duplicates)
[ "$(printf '%s\n' "$COLLAPSE" | grep -c '^reaped duplicate')" -eq 2 ] || fail "the collapse did not stop exactly two duplicates: $COLLAPSE"
wait_for_supervisors 1 5 || fail "the collapse left $(supervisor_count) supervisors"
kill -0 "$OWNER_WORKER" 2>/dev/null || fail "the collapse stopped the worker that owns the lock"
[ "$(cat "$STATE/worker.pid")" = "$OWNER_WORKER" ] || fail "the lock owner changed during the collapse"
run_probe_job
AGAIN=$(TZ=XYZ-9 HOME="$ACCOUNT_HOME" "$ROOT/bin/fm-remote-job-reap-orphans.sh" --duplicates)
[ -z "$AGAIN" ] || fail "a second collapse found more to stop: $AGAIN"
pass "the duplicate sweep collapses supervisors to the lock owner's and is idempotent"

# An operator may remove the storm's oversized worker log before recovering.
for call in 1 2; do
  (export TZ=UTC0; fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME") ||
    fail "a duplicate-producing ensure failed: $FM_REMOTE_JOB_ERROR"
done
[ "$(supervisor_count)" -eq 3 ] || fail "the removed-log fixture expected three supervisors, found $(supervisor_count)"
rm -f "$STATE/logs/$FM_REMOTE_JOB_LABEL.log"
REMOVED_LOG=$(TZ=XYZ-9 HOME="$ACCOUNT_HOME" "$ROOT/bin/fm-remote-job-reap-orphans.sh" --duplicates)
[ "$(printf '%s\n' "$REMOVED_LOG" | grep -c '^reaped duplicate')" -eq 2 ] ||
  fail "the collapse did not stop exactly two duplicates once the worker log was removed: $REMOVED_LOG"
wait_for_supervisors 1 5 || fail "the removed-log collapse left $(supervisor_count) supervisors"
kill -0 "$OWNER_WORKER" 2>/dev/null || fail "the removed-log collapse stopped the worker that owns the lock"
pass "the duplicate sweep still collapses supervisors after their worker log is removed"

# A worker bound to another queue is never a duplicate of this one.
OTHER_STATE="$TMP_ROOT/state-other-queue"
(export FM_REMOTE_JOB_STATE_ROOT="$OTHER_STATE"; fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME") ||
  fail "the other queue's worker did not start"
OTHER_WORKER=$(cat "$OTHER_STATE/worker.pid")
# With no verifiable owner, nothing bound to this queue is healthy.
printf 'lstart-utc:not the owner\n' > "$STATE/worker.lock/start"
NO_OWNER=$(HOME="$ACCOUNT_HOME" "$ROOT/bin/fm-remote-job-reap-orphans.sh" --duplicates)
assert_contains "$NO_OWNER" "reaped duplicate" "a worker with no verified lock owner beside it was kept"
kill -0 "$OWNER_WORKER" 2>/dev/null && fail "the collapse kept a worker although none verifiably owns the lock"
kill -0 "$OTHER_WORKER" 2>/dev/null || fail "the collapse stopped a worker bound to another queue"
wait_for_supervisors 1 5 || fail "the collapse left $(supervisor_count) supervisors instead of only the other queue's"
pass "the duplicate sweep stops every worker of its queue when none owns the lock, and no other queue's"

echo "ALL TESTS PASSED"
