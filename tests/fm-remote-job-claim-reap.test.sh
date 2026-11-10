#!/usr/bin/env bash
# Serving must not starve while the hourly sequence-claim sweep runs.
#
# Live failure shape (scout report, ~17k claim dirs): fm_remote_job_reap_stale
# walked every .seq-claims entry with a per-claim uname+stat fork before
# worker_process_once, so a job staged during the sweep sat queued with no
# .claim past fm-send's 30s remote budget while worker.ready stayed fresh.
#
# This drives the real worker and lib against a synthetic ~17k claim directory
# with the hourly marker due, stages one job during that sweep, and requires
# the job to be claimed and finished well under that budget. Expired claims
# must be removed and fresh ones kept.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-claim-reap)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/remote-jobs"
CLAIM_COUNT=17460
EXPIRED_COUNT=8730
# Well under fm-send's 30s remote budget; the pre-fix walk is ~80s here.
SERVE_BOUND_SECONDS=15
WORKER_PID=
command -v python3 >/dev/null || fail "test needs python3 to seed a large claim directory quickly"

cleanup_claim_reap_fixture() {
  if [ -n "$WORKER_PID" ]; then
    kill -TERM "$WORKER_PID" 2>/dev/null || true
    wait "$WORKER_PID" 2>/dev/null || true
  fi
  if [ -f "$STATE_ROOT/worker.pid" ]; then
    # shellcheck source=bin/fm-remote-job-lib.sh
    . "$ROOT/bin/fm-remote-job-lib.sh"
    fm_remote_job_stop_worker_tree "$(cat "$STATE_ROOT/worker.pid")" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_claim_reap_fixture EXIT

mkdir -p "$REMOTE_ROOT/bin" "$REMOTE_HOME" "$ACCOUNT_HOME"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" \
  "$ROOT/bin/fm-remote-delta-read.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-touch-job.sh" <<'SH'
#!/bin/bash
printf 'ran\n' > "$1"
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'claim-reap fixture'

export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=60
export FM_REMOTE_JOB_TIMEOUT=30
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

fm_remote_job_prepare_state "$ACCOUNT_HOME" || fail "$FM_REMOTE_JOB_ERROR"

python3 - "$STATE_ROOT/.seq-claims" "$CLAIM_COUNT" "$EXPIRED_COUNT" <<'PY'
import os, sys, time

claims_dir, count_s, expired_s = sys.argv[1:4]
count = int(count_s)
expired = int(expired_s)
old = time.time() - 90000
for i in range(1, count + 1):
    path = os.path.join(claims_dir, str(i))
    os.mkdir(path)
    if i <= expired:
        os.utime(path, (old, old))
PY

printf '%s\n' "$CLAIM_COUNT" > "$STATE_ROOT/seq"
# Force the claim sweep on the worker's first pass.
fm_touch_epoch 946684800 "$STATE_ROOT/.seq-claims-reaped"

assert_present "$STATE_ROOT/.seq-claims/1" "expired claim seed missing"
assert_present "$STATE_ROOT/.seq-claims/$CLAIM_COUNT" "fresh claim seed missing"
assert_present "$STATE_ROOT/.seq-claims/$EXPIRED_COUNT" "expired boundary seed missing"
FRESH_KEEP=$((EXPIRED_COUNT + 1))
assert_present "$STATE_ROOT/.seq-claims/$FRESH_KEEP" "fresh boundary seed missing"

HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve \
  > "$TMP_ROOT/worker.out" 2> "$TMP_ROOT/worker.err" &
WORKER_PID=$!

for _ in $(seq 1 200); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  sleep 0.05
done
assert_present "$STATE_ROOT/worker.ready" "the worker did not become ready"

TOUCHED="$TMP_ROOT/served"
began=$SECONDS
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" \
  fm-touch-job.sh "$TOUCHED" < /dev/null > /dev/null \
  || fail "staging a job during the due claim sweep failed: $FM_REMOTE_JOB_ERROR"
JOB_ID=$FM_REMOTE_JOB_ID

# Bound the wait tightly so a fork-per-claim walk fails this test instead of
# succeeding after the sweep finally finishes.
deadline=$((SECONDS + SERVE_BOUND_SECONDS))
state=
while [ "$SECONDS" -lt "$deadline" ]; do
  state=$(fm_remote_job_read_state "$STATE_ROOT/jobs/$JOB_ID" 2>/dev/null || true)
  [ "$state" = 'done' ] && break
  sleep 0.05
done
elapsed=$((SECONDS - began))
[ "$state" = 'done' ] \
  || fail "job $JOB_ID stayed '$state' for ${elapsed}s during a due claim sweep (bound ${SERVE_BOUND_SECONDS}s); serving was starved"
[ "$elapsed" -le "$SERVE_BOUND_SECONDS" ] \
  || fail "job $JOB_ID finished only after ${elapsed}s; serving was starved by the claim sweep"
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB_ID" || fail "$FM_REMOTE_JOB_ERROR"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ] \
  || fail "the job staged during the claim sweep exited $FM_REMOTE_JOB_EXIT"
assert_present "$TOUCHED" "the job staged during the claim sweep never ran"
[ "$(cat "$TOUCHED")" = ran ] \
  || fail "the job staged during the claim sweep did not publish its side effect"
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB_ID" || fail "could not reap the served job"

assert_absent "$STATE_ROOT/.seq-claims/1" "an expired sequence claim survived the sweep"
assert_absent "$STATE_ROOT/.seq-claims/$EXPIRED_COUNT" "the expired boundary claim survived the sweep"
assert_present "$STATE_ROOT/.seq-claims/$FRESH_KEEP" "a fresh sequence claim was reaped"
assert_present "$STATE_ROOT/.seq-claims/$CLAIM_COUNT" "the freshest seed claim was reaped"

remaining=$(find "$STATE_ROOT/.seq-claims" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
# Fresh seed ids FRESH_KEEP..CLAIM_COUNT remain, plus the staged job's seq claim.
expected_fresh=$((CLAIM_COUNT - EXPIRED_COUNT))
[ "$remaining" -ge "$expected_fresh" ] \
  || fail "too few claims remained after the sweep ($remaining; expected at least $expected_fresh fresh seeds)"
[ "$remaining" -le $((expected_fresh + 5)) ] \
  || fail "too many claims remained after the sweep ($remaining; expected about $expected_fresh plus the staged seq)"

pass "a due claim sweep over ~${CLAIM_COUNT} dirs does not starve job serving"
