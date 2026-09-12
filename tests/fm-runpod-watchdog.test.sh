#!/usr/bin/env bash
# Behavior tests for bin/fm-runpod-watchdog.sh, the detached pod killswitch.
#
# The two cases that decide whether this thing is safe to run unattended are a
# passed deadline that MUST terminate and verify, and an unreadable run record
# that MUST NOT terminate anything. Both are asserted here, plus the states in
# between: a live deadline, a termination the API accepted but the pod list does
# not confirm, a stalled progress artifact, and the credential never reaching
# any file the script writes.
#
# The RunPod API is faked at the process boundary with a PATH curl shim, so
# every assertion runs through the real executable and no test ever touches a
# real account or rents anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCHDOG="$ROOT/bin/fm-runpod-watchdog.sh"
FAKE_KEY='fm-test-runpod-key-must-never-be-logged'

# Builds an isolated home: state dir, .env carrying the fake key, and a curl
# shim whose behavior the case steers through files under $TMP/api.
new_home() {
  local home=$1 fakebin
  mkdir -p "$home/state" "$home/api"
  printf 'RUNPOD_API_KEY=%s\n' "$FAKE_KEY" > "$home/.env"
  chmod 0600 "$home/.env"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
# Fake RunPod GraphQL endpoint. Reads the request body from the --data-binary
# file, records the call, and answers from files the test controls:
#   api/pods           one pod id per line; the account's current pod list
#   api/pods.fail      present => the list read fails (transport error)
#   api/terminate.out  raw response body for podTerminate
#   api/terminate.keep present => podTerminate does NOT remove the pod from
#                      api/pods, simulating an accepted call that did not land
set -u
API=${FM_TEST_API_DIR:?}
body=
prev=
for arg in "$@"; do
  case "$prev" in
    --data-binary) body=${arg#@} ;;
  esac
  prev=$arg
done
query=$(cat "$body" 2>/dev/null)
# Drain the config file on stdin; it carries the Authorization header, which is
# exactly what must never escape into anything the script writes.
config=$(cat)
printf '%s\n' "$config" >> "$API/curl-stdin.log"
case "$query" in
  *podTerminate*)
    printf 'terminate\n' >> "$API/calls.log"
    if [ ! -e "$API/terminate.keep" ]; then
      pod=$(printf '%s' "$query" | sed -n 's/.*podId: \\\"\([A-Za-z0-9_-]*\)\\\".*/\1/p')
      if [ -n "$pod" ] && [ -e "$API/pods" ]; then
        grep -vxF -- "$pod" "$API/pods" > "$API/pods.tmp" 2>/dev/null || :
        mv -f "$API/pods.tmp" "$API/pods"
      fi
    fi
    cat "$API/terminate.out" 2>/dev/null || printf '{"data":{"podTerminate":null}}'
    ;;
  *myself*)
    printf 'list\n' >> "$API/calls.log"
    if [ -e "$API/pods.fail" ]; then
      echo 'curl: (7) simulated transport failure' >&2
      exit 7
    fi
    {
      printf '{"data":{"myself":{"pods":['
      sep=
      while IFS= read -r id || [ -n "$id" ]; do
        [ -n "$id" ] || continue
        printf '%s{"id":"%s"}' "$sep" "$id"
        sep=,
      done < "$API/pods" 2>/dev/null
      printf ']}}}'
    }
    ;;
  *)
    printf '{"errors":[{"message":"unexpected query"}]}'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# Runs the watchdog loop in the foreground with a short poll, bounded by a hard
# timeout so a case that wrongly loops forever fails instead of hanging CI.
run_loop() {
  local home=$1 task=$2 seconds=$3 fakebin=$4 rc=0
  FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_RUNPOD_ENV_FILE="$home/.env" \
  FM_RUNPOD_API_URL='https://fake.invalid/graphql' \
  FM_RUNPOD_POLL_SECONDS=0.2 \
  FM_RUNPOD_VERIFY_ATTEMPTS=2 \
  FM_RUNPOD_VERIFY_INTERVAL=0.1 \
  FM_RUNPOD_ALARM_REPEAT_SECONDS=0 \
  FM_TEST_API_DIR="$home/api" \
  PATH="$fakebin:$PATH" \
    timeout -s TERM "$seconds" "$WATCHDOG" run --task "$task" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

write_record() {
  local home=$1 task=$2
  shift 2
  {
    printf 'fm-runpod-watch-v1\n'
    printf 'task=%s\n' "$task"
    printf '%s\n' "$@"
  } > "$home/state/$task.runpod-watch"
}

calls() {
  cat "$1/api/calls.log" 2>/dev/null || true
}

TMP_ROOT=$(fm_test_tmproot fm-runpod-watchdog) || fail 'could not create fixture root'

# --- a passed deadline terminates, and the termination is verified by listing
H=$TMP_ROOT/deadline
FB=$(new_home "$H")
printf 'pod-alpha\npod-other\n' > "$H/api/pods"
printf '{"data":{"podTerminate":null}}' > "$H/api/terminate.out"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=1" "deadline_source=declared"
RC=$(run_loop "$H" t1 20 "$FB")
expect_code 0 "$RC" 'passed deadline: loop should finish cleanly after a verified termination'
assert_contains "$(calls "$H")" terminate 'passed deadline: podTerminate was never called'
assert_grep 'verified absent from the pod list pod=pod-alpha' "$H/state/t1.runpod-watch.log" \
  'passed deadline: termination was not verified against the pod list'
assert_grep 'has been stopped' "$H/state/t1.status" \
  'passed deadline: firstmate was not told the pod was stopped'
assert_grep 'absence confirmed by listing' "$H/state/t1.status" \
  'passed deadline: the stop was reported without naming the listing as the proof'
assert_grep 'pod-other' "$H/api/pods" 'passed deadline: another account pod was removed'
pass 'a run whose deadline has passed is terminated and the termination is verified by listing'

# --- an unreadable record NEVER terminates
for CASE in absent malformed truncated; do
  H=$TMP_ROOT/unreadable-$CASE
  FB=$(new_home "$H")
  printf 'pod-alpha\n' > "$H/api/pods"
  case "$CASE" in
    absent) : ;;
    malformed) printf 'not-the-record-tag\npod=pod-alpha\ndeadline_epoch=1\n' > "$H/state/t1.runpod-watch" ;;
    truncated) printf 'fm-runpod-watch-v1\npod=pod-alpha\n' > "$H/state/t1.runpod-watch" ;;
  esac
  RC=$(run_loop "$H" t1 4 "$FB")
  assert_not_equals 0 "$RC" "unreadable record ($CASE): the loop must keep waiting, not finish"
  assert_not_contains "$(calls "$H")" terminate \
    "unreadable record ($CASE): podTerminate was called with no trustworthy deadline record"
  assert_grep 'pod-alpha' "$H/api/pods" "unreadable record ($CASE): the pod was removed"
  assert_grep 'will NOT terminate anything' "$H/state/t1.status" \
    "unreadable record ($CASE): firstmate was not alarmed"
done
pass 'a run whose state cannot be read is NOT terminated, and firstmate is alarmed instead'

# --- a live deadline terminates nothing
H=$TMP_ROOT/live
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=$(( $(date +%s) + 3600 ))" "deadline_source=declared"
RC=$(run_loop "$H" t1 4 "$FB")
assert_not_equals 0 "$RC" 'live deadline: the loop must keep watching'
assert_not_contains "$(calls "$H")" terminate 'live deadline: a healthy run inside its deadline was terminated'
assert_grep 'pod-alpha' "$H/api/pods" 'live deadline: the pod was removed'
pass 'a run still inside its declared deadline is left alone'

# --- an accepted termination that the listing does not confirm is not reported as stopped
H=$TMP_ROOT/unverified
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
printf '{"data":{"podTerminate":null}}' > "$H/api/terminate.out"
: > "$H/api/terminate.keep"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=1" "deadline_source=declared"
RC=$(run_loop "$H" t1 6 "$FB")
assert_not_equals 0 "$RC" 'unverified termination: the loop must keep retrying, never finish'
assert_grep 'NOT verified' "$H/state/t1.status" \
  'unverified termination: firstmate was not told the pod may still be billing'
assert_no_grep 'has been stopped' "$H/state/t1.status" \
  'unverified termination: the pod was reported stopped without listing proof'
pass 'a termination the pod list does not confirm is alarmed, never reported as stopped'

# --- an unreadable pod list is not read as "the pod is gone"
H=$TMP_ROOT/apidown
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
: > "$H/api/pods.fail"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=$(( $(date +%s) + 3600 ))" "deadline_source=declared"
RC=$(run_loop "$H" t1 4 "$FB")
assert_not_equals 0 "$RC" 'api down: a failed list read must not end the watch'
assert_grep 'cannot reach RunPod' "$H/state/t1.status" 'api down: firstmate was not alarmed'
pass 'a failed pod-list read keeps the watch alive instead of concluding anything'

# --- a stalled progress artifact alarms but never terminates
H=$TMP_ROOT/stalled
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
: > "$H/progress"
fm_touch_epoch "$(( $(date +%s) - 7200 ))" "$H/progress"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=$(( $(date +%s) + 3600 ))" \
  "deadline_source=declared" "progress_file=$H/progress" "progress_grace_seconds=60"
RC=$(run_loop "$H" t1 4 "$FB")
assert_not_equals 0 "$RC" 'stalled progress: the loop must keep watching'
assert_not_contains "$(calls "$H")" terminate \
  'stalled progress: a stalled progress file terminated a run that was still inside its deadline'
assert_grep 'may be wedged' "$H/state/t1.status" 'stalled progress: firstmate was not alarmed'
pass 'a stalled progress artifact alarms and never terminates before the deadline'

# --- the pod vanishing before its deadline is the normal ending
H=$TMP_ROOT/gone
FB=$(new_home "$H")
printf 'pod-other\n' > "$H/api/pods"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=$(( $(date +%s) + 3600 ))" "deadline_source=declared"
RC=$(run_loop "$H" t1 6 "$FB")
expect_code 0 "$RC" 'pod gone: the loop should exit cleanly when there is nothing left to guard'
assert_not_contains "$(calls "$H")" terminate 'pod gone: podTerminate was called on an absent pod'
assert_absent "$H/state/t1.runpod-watch" 'pod gone: the record was left behind'
pass 'a pod that disappears before its deadline ends the watch cleanly'

# --- a pod already gone at its deadline is not claimed as a watchdog stop
H=$TMP_ROOT/deadline-already-gone
FB=$(new_home "$H")
printf 'pod-other\n' > "$H/api/pods"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=1" "deadline_source=declared"
RC=$(run_loop "$H" t1 6 "$FB")
expect_code 0 "$RC" 'already gone at deadline: the loop should finish cleanly'
assert_not_contains "$(calls "$H")" terminate \
  'already gone at deadline: podTerminate was called on a pod that was already absent'
if [ -e "$H/state/t1.status" ]; then
  assert_no_grep 'has been stopped' "$H/state/t1.status" \
    'already gone at deadline: the watchdog credited itself with a stop it did not make'
fi
pass 'a pod already absent when its deadline passes is not reported as a watchdog termination'

# --- the credential never reaches anything the script writes
H=$TMP_ROOT/secret
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
printf '{"data":{"podTerminate":null}}' > "$H/api/terminate.out"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=1" "deadline_source=declared"
run_loop "$H" t1 20 "$FB" >/dev/null
assert_grep "$FAKE_KEY" "$H/api/curl-stdin.log" \
  'credential: the fake API never saw the key, so this case would pass vacuously'
for WRITTEN in "$H/state/t1.runpod-watch.log" "$H/state/t1.status" "$H/state/t1.runpod-watch"; do
  [ -e "$WRITTEN" ] || continue
  assert_no_grep "$FAKE_KEY" "$WRITTEN" "credential: the key leaked into $(basename "$WRITTEN")"
done
pass 'the credential reaches the API but never any file the watchdog writes'

# --- arm refuses without a deadline, because it enforces one rather than inventing one
H=$TMP_ROOT/armargs
FB=$(new_home "$H")
OUT=$(FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_RUNPOD_ENV_FILE="$H/.env" \
  PATH="$FB:$PATH" "$WATCHDOG" arm --task t1 --pod pod-alpha 2>&1) && RC=0 || RC=$?
assert_not_equals 0 "$RC" 'arm without a deadline should refuse'
assert_contains "$OUT" 'does not invent one' 'arm: refusal did not say why a deadline is required'
assert_absent "$H/state/t1.runpod-watch" 'arm: a record was published without a deadline'
OUT=$(FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_RUNPOD_ENV_FILE="$H/.env" \
  PATH="$FB:$PATH" "$WATCHDOG" arm --task t1 --pod pod-alpha --deadline 2020-01-01T00:00:00Z 2>&1) && RC=0 || RC=$?
assert_not_equals 0 "$RC" 'arm with an already-passed deadline should refuse'
assert_absent "$H/state/t1.runpod-watch" 'arm: a record was published for a passed deadline'
pass 'arm refuses to guess a deadline and refuses one that has already passed'

# --- the ceiling a run declared becomes the earlier wall-clock deadline
H=$TMP_ROOT/ceiling
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_RUNPOD_ENV_FILE="$H/.env" \
  FM_RUNPOD_API_URL='https://fake.invalid/graphql' FM_TEST_API_DIR="$H/api" \
  FM_RUNPOD_POLL_SECONDS=600 PATH="$FB:$PATH" \
  "$WATCHDOG" arm --task t1 --pod pod-alpha --deadline "$(( $(date +%s) + 21600 ))" \
    --ceiling-usd 20 --rate-usd-hr 3.49 >"$H/arm.out" 2>&1 \
    || fail "arm with a ceiling failed: $(cat "$H/arm.out" 2>/dev/null)"
OUT=$(FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$WATCHDOG" status --task t1)
assert_contains "$OUT" 'source=ceiling' \
  'ceiling: a 20 USD ceiling at 3.49 USD/hr is under six hours and should bind before the declared deadline'
assert_contains "$OUT" 'ceiling=20' 'ceiling: the declared ceiling was not recorded'
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$WATCHDOG" disarm --task t1 >/dev/null
pass 'the ceiling a run declared binds when it is the earlier wall-clock instant'

# --- the armed watchdog outlives the shell that armed it
H=$TMP_ROOT/detach
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
PARENT_OUT=$TMP_ROOT/parent.out
# The arming shell must be a separate process this test can watch die, so it
# arms and then exits, recording its own pid on the way out.
cat > "$TMP_ROOT/arm-then-exit.sh" <<'SH'
set -u
"$1" arm --task t1 --pod pod-alpha --deadline "$(( $(date +%s) + 3600 ))" >"$2" 2>&1
rc=$?
echo $$ > "$3"
exit "$rc"
SH
env -i HOME="$HOME" PATH="$FB:$PATH" \
  FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_RUNPOD_ENV_FILE="$H/.env" \
  FM_RUNPOD_API_URL='https://fake.invalid/graphql' FM_TEST_API_DIR="$H/api" \
  FM_RUNPOD_POLL_SECONDS=600 \
  bash "$TMP_ROOT/arm-then-exit.sh" "$WATCHDOG" "$PARENT_OUT" "$TMP_ROOT/parent.pid" \
  || fail "arm failed: $(cat "$PARENT_OUT" 2>/dev/null)"
WD_PID=$(cat "$H/state/t1.runpod-watch.pid" 2>/dev/null || true)
case "$WD_PID" in '' | *[!0-9]*) fail 'detach: no watchdog pid was recorded' ;; esac
PARENT_PID=$(cat "$TMP_ROOT/parent.pid")
kill -0 "$PARENT_PID" 2>/dev/null && fail 'detach: the arming shell is somehow still alive'
kill -0 "$WD_PID" 2>/dev/null || fail 'detach: the watchdog died with the shell that armed it'
# A new session id is what makes it immune to the harness tearing down its
# process group and controlling terminal on exit.
WD_SID=$(ps -o sid= -p "$WD_PID" 2>/dev/null | tr -d ' ')
SELF_SID=$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')
if [ -n "$WD_SID" ] && [ -n "$SELF_SID" ]; then
  assert_not_equals "$SELF_SID" "$WD_SID" 'detach: the watchdog shares this session, so a session teardown would take it'
fi
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$WATCHDOG" disarm --task t1 >/dev/null
kill -0 "$WD_PID" 2>/dev/null && fail 'detach: disarm left the watchdog running'
pass 'the armed watchdog survives the death of the shell that armed it, in its own session'
