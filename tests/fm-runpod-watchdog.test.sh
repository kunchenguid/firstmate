#!/usr/bin/env bash
# Behavior tests for bin/fm-runpod-watchdog.sh, the detached pod killswitch.
#
# The two cases that decide whether this thing is safe to run unattended are a
# passed deadline that MUST terminate and verify, and an unreadable run record
# that MUST NOT terminate anything. Both are asserted here, plus the states in
# between: a live deadline, a termination the API accepted but the pod list does
# not confirm, a pod id that was never in the account, a ceiling anchored to the
# pod's own start rather than to arm time, alarms this watchdog raises and then
# closes itself, and the credential never reaching any file the script writes.
#
# The RunPod API is faked at the process boundary with a PATH curl shim, so
# every assertion runs through the real executable and no test ever touches a
# real account or rents anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCHDOG="$ROOT/bin/fm-runpod-watchdog.sh"
CLASSIFY="$ROOT/bin/fm-classify-lib.sh"
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
#   api/pods.fail      present => every list read fails (transport error)
#   api/pods.fail-until  the list read fails for this many reads, then succeeds
#   api/uptime         runtime.uptimeInSeconds reported for every listed pod
#   api/uptime.null    present => pods report no runtime at all
#   api/vanish-after   drop api/vanish-pod from the list after this many reads
#   api/appear-after   add api/appear-pod to the list after this many reads
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
    reads=$(cat "$API/list-reads" 2>/dev/null || echo 0)
    reads=$((reads + 1))
    printf '%s\n' "$reads" > "$API/list-reads"
    if [ -e "$API/pods.fail" ]; then
      echo 'curl: (7) simulated transport failure' >&2
      exit 7
    fi
    if [ -e "$API/pods.fail-until" ] && [ "$reads" -le "$(cat "$API/pods.fail-until")" ]; then
      echo 'curl: (7) simulated transport failure' >&2
      exit 7
    fi
    if [ -e "$API/vanish-after" ] && [ "$reads" -gt "$(cat "$API/vanish-after")" ]; then
      grep -vxF -- "$(cat "$API/vanish-pod")" "$API/pods" > "$API/pods.tmp" 2>/dev/null || :
      mv -f "$API/pods.tmp" "$API/pods"
    fi
    if [ -e "$API/appear-after" ] && [ "$reads" -gt "$(cat "$API/appear-after")" ]; then
      appear=$(cat "$API/appear-pod")
      grep -qxF -- "$appear" "$API/pods" 2>/dev/null || printf '%s\n' "$appear" >> "$API/pods"
    fi
    uptime=$(cat "$API/uptime" 2>/dev/null || echo 3600)
    {
      printf '{"data":{"myself":{"pods":['
      sep=
      while IFS= read -r id || [ -n "$id" ]; do
        [ -n "$id" ] || continue
        if [ -e "$API/uptime.null" ]; then
          printf '%s{"id":"%s","runtime":null}' "$sep" "$id"
        else
          printf '%s{"id":"%s","runtime":{"uptimeInSeconds":%s}}' "$sep" "$id" "$uptime"
        fi
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

# `arm`, and the detached loop it starts, against the same fake API.
arm_watchdog() {
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_RUNPOD_ENV_FILE="$home/.env" \
    FM_RUNPOD_API_URL='https://fake.invalid/graphql' FM_TEST_API_DIR="$home/api" \
    FM_RUNPOD_POLL_SECONDS=0.5 PATH="$fakebin:$PATH" \
    "$WATCHDOG" arm "$@"
}

watchdog_status() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$WATCHDOG" status "$@"
}

# The effective deletion instant `status` reports, back as an epoch second.
status_deadline_epoch() {
  local line=$1 iso
  iso=$(printf '%s' "$line" | sed -n 's/.* deadline=\([^ ]*\) .*/\1/p')
  date -u -d "$iso" +%s 2>/dev/null
}

# Waits for the detached loop to publish the deadline it is actually enforcing,
# so the assertions below read a resolved anchor rather than racing the launch.
wait_for_anchor() {
  local home=$1 task=$2 want=$3 i=0 out
  while [ "$i" -lt 100 ]; do
    out=$(watchdog_status "$home" --task "$task" 2>/dev/null || true)
    case "$out" in
      *"anchor=$want"*) printf '%s\n' "$out"; return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "$out"
  return 1
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

# Seeds the watchdog's own derived-state file - the persisted contract `status`
# reads and `arm` carries forward - so a case can place an anchor at an instant
# no test could reach by waiting.
write_observed() {
  local home=$1 task=$2 pod=$3 start=$4
  {
    printf 'fm-runpod-watch-observed-v1\n'
    printf 'pod=%s\n' "$pod"
    printf 'pod_start_epoch=%s\n' "$start"
    printf 'anchor=pod-start\n'
    printf 'effective_deadline_epoch=%s\n' "$(( start + 20630 ))"
    printf 'effective_source=ceiling\n'
    printf 'updated_epoch=%s\n' "$start"
  } > "$home/state/$task.runpod-watch.observed"
}

open_decisions() {
  bash -c '. "$1"; status_open_decisions "$2"' _ "$CLASSIFY" "$1" 2>/dev/null || true
}

TMP_ROOT=$(fm_test_tmproot fm-runpod-watchdog) || fail 'could not create fixture root'

# --- a passed deadline terminates, and the termination is verified by listing
H=$TMP_ROOT/deadline
FB=$(new_home "$H")
printf 'pod-alpha\npod-other\n' > "$H/api/pods"
printf '{"data":{"podTerminate":null}}' > "$H/api/terminate.out"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=1"
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
OPEN=$(open_decisions "$H/state/t1.status")
assert_equals '' "$OPEN" \
  'passed deadline: a completed stop left an open decision on the task nothing can close'
pass 'a run whose deadline has passed is terminated, verified by listing, and leaves no open decision'

# --- an unreadable record NEVER terminates
for CASE in absent malformed truncated oversized-deadline; do
  H=$TMP_ROOT/unreadable-$CASE
  FB=$(new_home "$H")
  printf 'pod-alpha\n' > "$H/api/pods"
  case "$CASE" in
    absent) : ;;
    malformed) printf 'not-the-record-tag\npod=pod-alpha\ndeadline_epoch=1\n' > "$H/state/t1.runpod-watch" ;;
    truncated) printf 'fm-runpod-watch-v1\npod=pod-alpha\n' > "$H/state/t1.runpod-watch" ;;
    # A digit string outside intmax makes `[ a -lt b ]` abort rather than answer
    # false, and that abort used to land on the terminating side of the deadline
    # comparison; such a record must be refused as untrustworthy instead.
    oversized-deadline)
      write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=99999999999999999999999" ;;
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
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=$(( $(date +%s) + 3600 ))"
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
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=1"
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
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=$(( $(date +%s) + 3600 ))"
RC=$(run_loop "$H" t1 4 "$FB")
assert_not_equals 0 "$RC" 'api down: a failed list read must not end the watch'
assert_grep 'cannot reach RunPod' "$H/state/t1.status" 'api down: firstmate was not alarmed'
pass 'a failed pod-list read keeps the watch alive instead of concluding anything'

# --- a pod that was seen and then vanishes is the normal ending
H=$TMP_ROOT/gone
FB=$(new_home "$H")
printf 'pod-alpha\npod-other\n' > "$H/api/pods"
printf '1\n' > "$H/api/vanish-after"
printf 'pod-alpha\n' > "$H/api/vanish-pod"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=$(( $(date +%s) + 3600 ))"
RC=$(run_loop "$H" t1 10 "$FB")
expect_code 0 "$RC" 'pod gone: the loop should exit cleanly when the pod it watched has left'
assert_not_contains "$(calls "$H")" terminate 'pod gone: podTerminate was called on an absent pod'
assert_absent "$H/state/t1.runpod-watch" 'pod gone: the record was left behind'
assert_absent "$H/state/t1.runpod-watch.observed" 'pod gone: the derived-state file was left behind'
pass 'a pod that was seen and then disappears ends the watch cleanly'

# --- a pod id that was NEVER in the account keeps the watch alive and says so,
# --- even once its deadline has passed and a read has failed in between
H=$TMP_ROOT/never-seen
FB=$(new_home "$H")
printf 'pod-other\n' > "$H/api/pods"
# The deadline has already passed, and the first read fails at the transport.
# A not-found podTerminate reply would look like a stop to anything that read
# absence as proof, so this is the sequence that must produce no stop at all.
printf '1\n' > "$H/api/pods.fail-until"
printf '{"errors":[{"message":"pod not found to terminate"}]}' > "$H/api/terminate.out"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=1"
RC=$(run_loop "$H" t1 8 "$FB")
assert_not_equals 0 "$RC" \
  'never seen: an id that was never in the account must not end the watch as if the run had finished'
assert_not_contains "$(calls "$H")" terminate \
  'never seen: podTerminate was called for a pod this watchdog never saw'
assert_grep 'never seen pod pod-alpha' "$H/state/t1.status" \
  'never seen: firstmate was not told the pod id may be wrong while a rented pod bills on'
assert_no_grep 'has been stopped' "$H/state/t1.status" \
  'never seen: the watchdog credited itself with a stop it did not make'
assert_no_grep 'absence confirmed' "$H/state/t1.status" \
  'never seen: absence was reported as proof of a stop for a pod never sighted'
assert_grep 'pod=pod-alpha' "$H/state/t1.runpod-watch" \
  'never seen: the record was deleted, retiring a watch that never guarded anything'
OPEN=$(open_decisions "$H/state/t1.status")
assert_contains "$OPEN" 'never seen pod pod-alpha' \
  'never seen: the standing warning that a rented pod may be billing was closed'
assert_not_contains "$OPEN" 'cannot reach RunPod' \
  'never seen: a list read that succeeded left a false unreachable-API blocker open'
pass 'a pod never sighted is never stopped, never reported stopped, and keeps alarming past its deadline'

# --- retiring the watch does not close the never-sighted warning
H=$TMP_ROOT/never-seen-disarm
FB=$(new_home "$H")
printf 'pod-other\n' > "$H/api/pods"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=$(( $(date +%s) + 3600 ))"
run_loop "$H" t1 4 "$FB" >/dev/null
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$WATCHDOG" disarm --task t1 >/dev/null
OPEN=$(open_decisions "$H/state/t1.status")
assert_contains "$OPEN" 'never seen pod pod-alpha' \
  'never seen: disarming the watch closed the warning that a rented pod may still be billing'
pass 'disarming a watch that never sighted its pod leaves that warning standing'

# --- and sighting a DIFFERENT pod does not close it either
H=$TMP_ROOT/never-seen-other-pod
FB=$(new_home "$H")
printf 'pod-beta\n' > "$H/api/pods"
write_record "$H" t1 "pod=pod-typo" "deadline_epoch=$(( $(date +%s) + 3600 ))"
run_loop "$H" t1 4 "$FB" >/dev/null
assert_contains "$(open_decisions "$H/state/t1.status")" 'never seen pod pod-typo' \
  'cross-pod clear: the warning about the typo\'"'"'d pod never opened, so this case would pass vacuously'
# The operator retires that watch and re-arms the task on the pod that is real.
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$WATCHDOG" disarm --task t1 >/dev/null
write_record "$H" t1 "pod=pod-beta" "deadline_epoch=$(( $(date +%s) + 3600 ))"
run_loop "$H" t1 4 "$FB" >/dev/null
assert_grep 'pod pod-beta started at' "$H/state/t1.runpod-watch.log" \
  'cross-pod clear: the second watch never sighted pod-beta, so this case would pass vacuously'
OPEN=$(open_decisions "$H/state/t1.status")
assert_contains "$OPEN" 'never seen pod pod-typo' \
  'cross-pod clear: sighting pod-beta closed the warning that a GPU may be billing under pod-typo'
pass 'a never-sighted warning about one pod is not closed by sighting another'

# --- and when one of two unseen pods turns up, the open decision names the
# --- one that is still missing, not the one that is now fine
H=$TMP_ROOT/never-seen-partial
FB=$(new_home "$H")
printf 'pod-other\n' > "$H/api/pods"
write_record "$H" t1 "pod=pod-typo" "deadline_epoch=$(( $(date +%s) + 3600 ))"
run_loop "$H" t1 4 "$FB" >/dev/null
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$WATCHDOG" disarm --task t1 >/dev/null
# The operator re-arms on the pod they actually requested, before RunPod lists
# it, so a second subject opens the same condition and overwrites the note.
printf '0\n' > "$H/api/list-reads"
printf '2\n' > "$H/api/appear-after"
printf 'pod-beta\n' > "$H/api/appear-pod"
write_record "$H" t1 "pod=pod-beta" "deadline_epoch=$(( $(date +%s) + 3600 ))"
run_loop "$H" t1 6 "$FB" >/dev/null
assert_grep 'pod pod-beta started at' "$H/state/t1.runpod-watch.log" \
  'partial clear: pod-beta never turned up, so this case would pass vacuously'
assert_grep 'never seen pod pod-beta' "$H/state/t1.status" \
  'partial clear: pod-beta never raised its own alarm, so this case would pass vacuously'
OPEN=$(open_decisions "$H/state/t1.status")
assert_contains "$OPEN" 'never seen pod pod-typo' \
  'partial clear: the open decision no longer names the pod that is still unaccounted for'
assert_not_contains "$OPEN" 'never seen pod pod-beta' \
  'partial clear: the open decision still warns about the pod that has since turned up'
pass 'when one unseen pod turns up, the surviving decision names the one still missing'

# --- alarms carry their own decision key and cannot clobber a crewmate's
H=$TMP_ROOT/decision-key
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
: > "$H/api/pods.fail"
printf 'needs-decision: fp8 or int4 for the C6 sweep?\n' > "$H/state/t1.status"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=$(( $(date +%s) + 3600 ))"
run_loop "$H" t1 4 "$FB" >/dev/null
OPEN=$(open_decisions "$H/state/t1.status")
assert_contains "$OPEN" 'fp8 or int4' \
  "decision key: the watchdog alarm swallowed the crewmate's open decision"
assert_contains "$OPEN" 'cannot reach RunPod' 'decision key: the watchdog alarm is not open at all'
printf 'resolved: fp8 chosen\n' >> "$H/state/t1.status"
OPEN=$(open_decisions "$H/state/t1.status")
assert_not_contains "$OPEN" 'fp8 or int4' \
  "decision key: the crewmate's own resolution did not close the crewmate's decision"
assert_contains "$OPEN" 'cannot reach RunPod' \
  "decision key: a crewmate's unrelated resolution closed the still-true watchdog alarm"
pass 'watchdog alarms own their decision key instead of sharing the unkeyed default'

# --- an alarm the watchdog raised is closed by the watchdog when it clears
H=$TMP_ROOT/alarm-cleared
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
printf '2\n' > "$H/api/pods.fail-until"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=$(( $(date +%s) + 3600 ))"
run_loop "$H" t1 6 "$FB" >/dev/null
assert_grep 'cannot reach RunPod' "$H/state/t1.status" \
  'cleared alarm: the unreachable API never alarmed, so this case would pass vacuously'
OPEN=$(open_decisions "$H/state/t1.status")
assert_not_contains "$OPEN" 'cannot reach RunPod' \
  'cleared alarm: the API came back but the watchdog left its own blocker open'
assert_equals '' "$OPEN" 'cleared alarm: something the watchdog opened is still open'
pass 'an alarm the watchdog raised is closed under its own key once the condition clears'

# --- an unrelated .env value cannot take the credential away
H=$TMP_ROOT/envparse
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
printf '{"data":{"podTerminate":null}}' > "$H/api/terminate.out"
# A shared operator .env carries other people's values; an apostrophe in one of
# them must not be able to disarm a live killswitch.
{
  printf "FM_NOTE=don't stop the C6 sweep\n"
  printf 'RUNPOD_API_KEY=%s\n' "$FAKE_KEY"
  printf 'FM_TRAILING=unquoted value with spaces\n'
} > "$H/.env"
chmod 0600 "$H/.env"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=1"
RC=$(run_loop "$H" t1 20 "$FB")
expect_code 0 "$RC" 'shared .env: the watchdog did not complete its stop'
assert_contains "$(calls "$H")" terminate \
  'shared .env: an unrelated value in the shared .env took the credential away'
assert_grep "$FAKE_KEY" "$H/api/curl-stdin.log" 'shared .env: the key never reached the API'
if [ -e "$H/state/t1.status" ]; then
  assert_no_grep 'cannot read its RunPod credential' "$H/state/t1.status" \
    'shared .env: the credential read failed on a neighbouring value'
fi
pass 'the credential is parsed out of the shared .env rather than executed with it'

# --- a corrupt pid file cannot signal the caller's process group
H=$TMP_ROOT/pidzero
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=$(( $(date +%s) + 3600 ))"
# pid 0 names the CALLER's process group, so `kill -TERM 0` from disarm would
# take down whatever invoked it - here, a sentinel sharing that group.
printf '0\n' > "$H/state/t1.runpod-watch.pid"
cat > "$TMP_ROOT/pidzero.sh" <<'SH'
set -u
sleep 30 &
printf '%s
' "$!" > "$3"
"$1" disarm --task t1 >/dev/null 2>&1
printf '%s
' "$?" > "$2"
SH
setsid env FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_RUNPOD_ENV_FILE="$H/.env" \
  PATH="$FB:$PATH" \
  bash "$TMP_ROOT/pidzero.sh" "$WATCHDOG" "$TMP_ROOT/pidzero.rc" "$TMP_ROOT/pidzero.pid" \
  >/dev/null 2>&1 || true
SENTINEL=$(cat "$TMP_ROOT/pidzero.pid" 2>/dev/null || true)
case "$SENTINEL" in '' | *[!0-9]*) fail 'pid zero: the sentinel never started' ;; esac
kill -0 "$SENTINEL" 2>/dev/null \
  || fail "pid zero: disarm signalled its own process group and killed the sentinel"
kill -TERM "$SENTINEL" 2>/dev/null || true
assert_equals 0 "$(cat "$TMP_ROOT/pidzero.rc" 2>/dev/null || true)" \
  'pid zero: disarm did not complete'
assert_absent "$H/state/t1.runpod-watch" 'pid zero: disarm left the record behind'
pass 'a corrupt pid file cannot make the watchdog signal the process group that invoked it'

# --- the credential never reaches anything the script writes
H=$TMP_ROOT/secret
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
printf '{"data":{"podTerminate":null}}' > "$H/api/terminate.out"
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=1"
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

# --- a value-taking flag with no value is refused, not spun on
for SUB in "arm --task t1 --pod pod-alpha --deadline" "disarm --task" "status --task" "run --task"; do
  # shellcheck disable=SC2086 # the subcommand and its flags are the fixture
  OUT=$(FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_RUNPOD_ENV_FILE="$H/.env" \
    PATH="$FB:$PATH" timeout -s KILL 10 "$WATCHDOG" $SUB 2>&1) && RC=0 || RC=$?
  assert_not_equals 137 "$RC" "missing value ($SUB): the option parser spun instead of refusing"
  assert_not_equals 0 "$RC" "missing value ($SUB): a flag with no value was accepted"
  assert_contains "$OUT" 'needs a value' "missing value ($SUB): the refusal did not say what was wrong"
done
pass 'a value-taking flag given as the last argument is refused instead of spun on'

# --- the ceiling is anchored to the pod's own start, not to arm time
H=$TMP_ROOT/ceiling
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
# The pod has already been up for two hours when the watchdog is armed, which is
# exactly the case an arm-time anchor would silently under-count.
printf '7200\n' > "$H/api/uptime"
ARM_EPOCH=$(date -u +%s)
DECLARED=$(( ARM_EPOCH + 21600 ))
arm_watchdog "$H" "$FB" --task t1 --pod pod-alpha --deadline "$DECLARED" \
  --ceiling-usd 20 --rate-usd-hr 3.49 > "$H/arm.out" 2>&1 \
  || fail "arm with a ceiling failed: $(cat "$H/arm.out" 2>/dev/null)"
OUT=$(wait_for_anchor "$H" t1 pod-start) \
  || fail "ceiling: the watchdog never resolved the pod start anchor: $OUT"
assert_contains "$OUT" 'source=ceiling' \
  'ceiling: a 20 USD ceiling at 3.49 USD/hr is under six hours and should bind before the declared deadline'
assert_contains "$OUT" 'ceiling=20usd@3.49/hr' 'ceiling: the declared ceiling was not recorded'
EFF=$(status_deadline_epoch "$OUT")
# 20 USD / 3.49 USD-hr = 20630s of uptime; the pod had already burned 7200 of it.
WANT=$(( ARM_EPOCH - 7200 + 20630 ))
ARM_ANCHORED=$(( ARM_EPOCH + 20630 ))
[ -n "$EFF" ] || fail "ceiling: status did not print a readable deadline: $OUT"
[ "$EFF" -ge "$(( WANT - 120 ))" ] && [ "$EFF" -le "$(( WANT + 120 ))" ] \
  || fail "ceiling: effective deadline $EFF is not anchored to the pod start (wanted ~$WANT, arm-anchored would be $ARM_ANCHORED)"
# Re-arming with a later declared deadline must not buy more ceiling.
arm_watchdog "$H" "$FB" --task t1 --pod pod-alpha --deadline "$(( ARM_EPOCH + 43200 ))" \
  --ceiling-usd 20 --rate-usd-hr 3.49 > "$H/arm2.out" 2>&1 \
  || fail "re-arm with a ceiling failed: $(cat "$H/arm2.out" 2>/dev/null)"
OUT=$(wait_for_anchor "$H" t1 pod-start) \
  || fail "ceiling: the re-armed watchdog never resolved the pod start anchor: $OUT"
EFF2=$(status_deadline_epoch "$OUT")
[ -n "$EFF2" ] || fail "ceiling: status did not print a readable deadline after re-arming: $OUT"
[ "$EFF2" -le "$(( EFF + 120 ))" ] \
  || fail "ceiling: re-arming moved the ceiling deadline from $EFF to $EFF2"
watchdog_status "$H" --task t1 >/dev/null
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$WATCHDOG" disarm --task t1 >/dev/null
pass 'the declared ceiling is anchored to the pod start, and re-arming cannot extend it'

# --- the anchor survives a re-arm even when the pod's runtime restarted
H=$TMP_ROOT/anchor-persists
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
printf '7200\n' > "$H/api/uptime"
ARM_EPOCH=$(date -u +%s)
arm_watchdog "$H" "$FB" --task t1 --pod pod-alpha --deadline "$(( ARM_EPOCH + 21600 ))" \
  --ceiling-usd 20 --rate-usd-hr 3.49 > "$H/arm.out" 2>&1 \
  || fail "anchor: arm failed: $(cat "$H/arm.out" 2>/dev/null)"
OUT=$(wait_for_anchor "$H" t1 pod-start) \
  || fail "anchor: the watchdog never resolved the pod start anchor: $OUT"
EFF=$(status_deadline_epoch "$OUT")
[ -n "$EFF" ] || fail "anchor: status did not print a readable deadline: $OUT"
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$WATCHDOG" disarm --task t1 >/dev/null
# The pod's runtime restarts, so RunPod now reports it as freshly started. A
# watch that re-derived its anchor from that would hand the run the whole
# ceiling a second time, on top of the two hours already burned.
printf '5\n' > "$H/api/uptime"
arm_watchdog "$H" "$FB" --task t1 --pod pod-alpha --deadline "$(( ARM_EPOCH + 43200 ))" \
  --ceiling-usd 20 --rate-usd-hr 3.49 > "$H/arm2.out" 2>&1 \
  || fail "anchor: re-arm failed: $(cat "$H/arm2.out" 2>/dev/null)"
OUT=$(wait_for_anchor "$H" t1 pod-start) \
  || fail "anchor: the re-armed watchdog never resolved the pod start anchor: $OUT"
EFF2=$(status_deadline_epoch "$OUT")
[ -n "$EFF2" ] || fail "anchor: status did not print a readable deadline after re-arming: $OUT"
[ "$EFF2" -le "$(( EFF + 120 ))" ] \
  || fail "anchor: a runtime restart plus a re-arm moved the ceiling deadline from $EFF to $EFF2"
# A DIFFERENT pod is a different watch and correctly takes a fresh anchor.
printf 'pod-gamma\n' > "$H/api/pods"
arm_watchdog "$H" "$FB" --task t1 --pod pod-gamma --deadline "$(( ARM_EPOCH + 43200 ))" \
  --ceiling-usd 20 --rate-usd-hr 3.49 > "$H/arm3.out" 2>&1 \
  || fail "anchor: arm on a new pod failed: $(cat "$H/arm3.out" 2>/dev/null)"
OUT=$(wait_for_anchor "$H" t1 pod-start) \
  || fail "anchor: the watchdog never resolved an anchor for the new pod: $OUT"
EFF3=$(status_deadline_epoch "$OUT")
[ -n "$EFF3" ] || fail "anchor: status did not print a readable deadline for the new pod: $OUT"
[ "$EFF3" -gt "$(( EFF + 120 ))" ] \
  || fail "anchor: a different pod inherited the previous pod's anchor ($EFF3 vs $EFF)"
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$WATCHDOG" disarm --task t1 >/dev/null
pass 'a pod-start anchor survives a re-arm for the same pod and is not inherited by another'

# --- a carried anchor that is already spent does NOT terminate on first sight
H=$TMP_ROOT/anchor-stale
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
printf '60\n' > "$H/api/uptime"
NOW=$(date -u +%s)
# The pod was watched yesterday, then STOPPED on RunPod - id and volume kept,
# GPU released, meter off - and resumed this morning. Its stored anchor is now
# 28 hours old, so a 20 USD / 3.49 USD-hr ceiling derived from it fell due long
# before this watch began. Enforcing it would destroy a healthy run on poll one.
write_observed "$H" t1 pod-alpha "$(( NOW - 100000 ))"
arm_watchdog "$H" "$FB" --task t1 --pod pod-alpha --deadline "$(( NOW + 21600 ))" \
  --ceiling-usd 20 --rate-usd-hr 3.49 > "$H/arm.out" 2>&1 \
  || fail "stale anchor: arm failed: $(cat "$H/arm.out" 2>/dev/null)"
OUT=$(wait_for_anchor "$H" t1 stale) \
  || fail "stale anchor: the watchdog never reported the anchor as stale: $OUT"
assert_contains "$OUT" 'source=declared' \
  'stale anchor: a ceiling derived from a spent anchor was reported as in force'
assert_not_contains "$(calls "$H")" terminate \
  'stale anchor: a healthy running pod was terminated on the first poll by a spent anchor'
assert_grep 'pod-alpha' "$H/api/pods" 'stale anchor: the pod was terminated'
assert_grep 'pod=pod-alpha' "$H/state/t1.runpod-watch" 'stale anchor: the watch retired itself'
assert_grep 'NOT being enforced' "$H/state/t1.status" \
  'stale anchor: firstmate was not told the ceiling is not in force'
assert_no_grep 'has been stopped' "$H/state/t1.status" \
  'stale anchor: a stop was reported'
EFF=$(status_deadline_epoch "$OUT")
[ -n "$EFF" ] || fail "stale anchor: status did not print a readable deadline: $OUT"
[ "$EFF" -ge "$NOW" ] \
  || fail "stale anchor: status reports an effective deadline already in the past ($EFF)"
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$WATCHDOG" disarm --task t1 >/dev/null
pass 'a carried anchor whose ceiling already fell due is refused, alarmed, and terminates nothing'

# --- status never quotes the previous arm's figures
H=$TMP_ROOT/status-rearm
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
printf '7200\n' > "$H/api/uptime"
NOW=$(date -u +%s)
arm_watchdog "$H" "$FB" --task t1 --pod pod-alpha --deadline "$(( NOW + 21600 ))" \
  --ceiling-usd 20 --rate-usd-hr 3.49 > "$H/arm.out" 2>&1 \
  || fail "status re-arm: arm failed: $(cat "$H/arm.out" 2>/dev/null)"
OUT=$(wait_for_anchor "$H" t1 pod-start) \
  || fail "status re-arm: the first watch never resolved its anchor: $OUT"
assert_contains "$OUT" 'source=ceiling' 'status re-arm: the first watch was not enforcing its ceiling'
OLD_EFF=$(status_deadline_epoch "$OUT")
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$WATCHDOG" disarm --task t1 >/dev/null
# The pod is no longer listed, so the re-armed watch never sights it and never
# republishes - the case where an operator most needs `status` to be honest.
: > "$H/api/pods"
NEW_DEADLINE=$(( NOW + 43200 ))
arm_watchdog "$H" "$FB" --task t1 --pod pod-alpha --deadline "$NEW_DEADLINE" \
  > "$H/arm2.out" 2>&1 || fail "status re-arm: re-arm failed: $(cat "$H/arm2.out" 2>/dev/null)"
OUT=$(watchdog_status "$H" --task t1)
assert_contains "$OUT" 'source=declared' \
  "status re-arm: status quoted the previous arm's ceiling as the source in force"
assert_contains "$OUT" 'anchor=unresolved' \
  "status re-arm: status quoted the previous arm's anchor"
EFF=$(status_deadline_epoch "$OUT")
[ "$EFF" = "$NEW_DEADLINE" ] \
  || fail "status re-arm: status reports $EFF, not this arm's declared deadline $NEW_DEADLINE (previous arm's was $OLD_EFF)"
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$WATCHDOG" disarm --task t1 >/dev/null
pass "status never reports an instant, source, or anchor from a previous arm"

# --- a ceiling whose anchor cannot be read is NOT enforced, and says so
H=$TMP_ROOT/ceiling-unanchored
FB=$(new_home "$H")
printf 'pod-alpha\n' > "$H/api/pods"
: > "$H/api/uptime.null"
NOW=$(date -u +%s)
write_record "$H" t1 "pod=pod-alpha" "deadline_epoch=$(( NOW + 21600 ))" \
  "ceiling_seconds=20630" "ceiling_usd=20" "rate_usd_hr=3.49"
RC=$(run_loop "$H" t1 4 "$FB")
assert_not_equals 0 "$RC" 'unanchored ceiling: the loop must keep watching the declared deadline'
assert_not_contains "$(calls "$H")" terminate \
  'unanchored ceiling: a ceiling with no anchor terminated a pod inside its declared deadline'
assert_grep 'NOT being enforced' "$H/state/t1.status" \
  'unanchored ceiling: firstmate was not told the ceiling is not in force'
OUT=$(watchdog_status "$H" --task t1)
assert_contains "$OUT" 'anchor=unknown' 'unanchored ceiling: status hid the unknown anchor'
assert_contains "$OUT" 'source=declared' \
  'unanchored ceiling: status reported a ceiling instant nothing is enforcing'
pass 'a ceiling whose pod-start anchor cannot be read is not enforced, and status says so'

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
