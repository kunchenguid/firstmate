#!/usr/bin/env bash
# Behavior tests for fm-pr-park.sh: the pull request fingerprint, the watch's
# condition and action, and park, unpark, and rollback through stand-ins for
# fm-control.sh and fm-procevent-when.sh that record their arguments.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-park)
PR_URL=https://github.com/acme/widget/pull/42
T1_WATCH=park-628b49d96dcde97a430dd4f597705899e09a968f793491e4b704ca

command -v jq >/dev/null 2>&1 || fail "jq is required to stand in for gh's built-in jq"

# A fixture home whose bin/ holds the real script and its libraries, beside
# stand-ins for the two lifecycle scripts it drives. The fake gh applies the
# script's own jq program to <home>/pr.json, and fails while <home>/gh-fail
# exists.
make_home() {
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/bin" "$home/state" "$home/data"
  cp "$ROOT/bin/fm-pr-park.sh" "$ROOT/bin/fm-pr-lib.sh" "$ROOT/bin/fm-backend.sh" "$home/bin/"
  cat > "$home/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
dir=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${FM_HOME:-}" ] || exit 1
printf '%s\n' "$FM_HOME" >> "$dir/control-home.log"
printf '%s\n' "$*" >> "$dir/control.log"
[ ! -e "$dir/control-fail" ]
SH
  cat > "$home/bin/fm-procevent-when.sh" <<'SH'
#!/usr/bin/env bash
dir=$(cd "$(dirname "$0")/.." && pwd)
printf '%s\n' "$*" >> "$dir/when.log"
[ "${#2}" -le 59 ] || exit 1
[ ! -e "$dir/when-fail" ]
SH
  chmod +x "$home/bin/"*.sh
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
home=$(cd "$(dirname "$0")/.." && pwd)
[ ! -e "$home/gh-fail" ] || exit 1
prog=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -q) prog=$2; shift 2 ;;
    *) shift ;;
  esac
done
exec jq -r "$prog" "$home/pr.json"
SH
  chmod +x "$fakebin/gh"
  printf 'kind=ship\n' > "$home/state/t1.meta"
  write_pr "$home" QUEUED
  printf '%s\n' "$home"
}

# <home> <status of the CI check run>: a fork PR whose CI run reports that
# status, plus one pending status context.
write_pr() {
  local home=$1 status=$2 conclusion=${3:-}
  cat > "$home/pr.json" <<JSON
{"state":"OPEN","headRefOid":"abc123","reviewDecision":"","reviews":[],"comments":[{}],
 "statusCheckRollup":[
  {"__typename":"CheckRun","name":"test","status":"$status","conclusion":"$conclusion"},
  {"__typename":"StatusContext","context":"lint","state":"PENDING"}]}
JSON
}

park() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$home/bin/fm-pr-park.sh" "$@"
}

test_fingerprint_changes_only_when_a_check_appears_or_finishes() {
  local home baseline status
  home=$(make_home fingerprint)
  park "$home" park t1 "$PR_URL" >/dev/null || fail "park of a readable PR failed"
  baseline=$(sed -n '3p' "$home/state/t1.park")
  [ "$baseline" = 'OPEN abc123  0 1 lint=pending,test=pending' ] || fail "unexpected baseline: $baseline"
  write_pr "$home" IN_PROGRESS
  park "$home" changed t1; status=$?
  expect_code 1 "$status" "a queued check that starts running must not change the fingerprint"
  write_pr "$home" COMPLETED SUCCESS
  park "$home" changed t1; status=$?
  expect_code 0 "$status" "a check that finishes must change the fingerprint"
  park "$home" unpark t1 >/dev/null || fail "unpark failed"
  park "$home" park t1 "$PR_URL" >/dev/null || fail "re-park failed"
  baseline=$(sed -n '3p' "$home/state/t1.park")
  [ "$baseline" = 'OPEN abc123  0 1 lint=pending,test=success' ] || fail "unexpected completed baseline: $baseline"
  pass "fingerprint: running and queued checks agree; a finished check changes it"
}

test_park_records_baseline_arms_watch_and_stops_worker() {
  local home out
  home=$(make_home park)
  out=$(park "$home" park t1 "$PR_URL") || fail "park of a ship task on a GitHub PR failed: $out"
  assert_contains "$out" "parked: t1 on $PR_URL" "park must report the parked task and PR"
  [ "$(stat -c %a "$home/state/t1.park" 2>/dev/null || stat -f %Lp "$home/state/t1.park")" = 600 ] \
    || fail "the park record must be private"
  assert_grep "$PR_URL" "$home/state/t1.park" "the park record must name the PR"
  assert_grep "arm $T1_WATCH --interval 300 --stable 1 --condition $home/bin/fm-pr-park.sh changed t1 --action $home/bin/fm-pr-park.sh resume-note t1" \
    "$home/when.log" "park must arm the change watch with this script as condition and action"
  assert_grep "t1 exit" "$home/control.log" "park must stop the worker through fm-control.sh exit"
  pass "park: records the baseline, arms the watch, then stops the worker"
}

test_park_resolves_default_home_for_control() {
  local home out
  home=$(make_home default-home)
  out=$(
    unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE
    PATH="$home/fakebin:$PATH" "$home/bin/fm-pr-park.sh" park t1 "$PR_URL"
  ) || fail "park with FM_HOME unset failed: $out"
  assert_contains "$out" "parked: t1 on $PR_URL" "default-home park must succeed"
  [ -f "$home/state/t1.park" ] || fail "default-home park rolled back its record"
  [ "$(cat "$home/control-home.log")" = "$home" ] || fail "control must receive the resolved default home"
  assert_grep "t1 exit" "$home/control.log" "default-home park must stop the worker"
  pass "park: resolves and passes the default home to control"
}

test_condition_and_action_follow_the_pr() {
  local home status note
  home=$(make_home condition)
  park "$home" park t1 "$PR_URL" >/dev/null || fail "park failed"
  park "$home" changed t1; status=$?
  expect_code 1 "$status" "an unchanged PR must read as a clean false"
  write_pr "$home" IN_PROGRESS
  park "$home" changed t1; status=$?
  expect_code 1 "$status" "a check that only started running must not fire the watch"
  : > "$home/gh-fail"
  park "$home" changed t1; status=$?
  expect_code 2 "$status" "an unreadable PR must be a condition error, never a change"
  rm -f "$home/gh-fail"
  write_pr "$home" COMPLETED FAILURE
  park "$home" changed t1; status=$?
  expect_code 0 "$status" "a finished check must fire the watch"
  note=$(park "$home" resume-note t1) || fail "resume-note failed"
  [ "$note" = "$home/data/t1/park-resume.md" ] || fail "resume-note must print its note path, got: $note"
  assert_grep "external change to $PR_URL" "$note" "the note must name the PR"
  assert_grep "Before: OPEN abc123" "$note" "the note must carry the baseline"
  assert_grep "test=failure" "$note" "the note must carry the current fingerprint"
  pass "changed/resume-note: fire only on a real change, and the note names what changed"
}

test_park_refusals_change_nothing() {
  local home out status
  home=$(make_home refusals)
  out=$(park "$home" park t1 https://gitlab.com/acme/widget/-/merge_requests/3 2>&1); status=$?
  expect_code 1 "$status" "a merge request outside GitHub must be refused"
  assert_contains "$out" "only GitHub pull requests" "the refusal must say why"
  printf 'kind=secondmate\n' > "$home/state/t2.meta"
  out=$(park "$home" park t2 "$PR_URL" 2>&1); status=$?
  expect_code 1 "$status" "a secondmate must be refused"
  : > "$home/gh-fail"
  out=$(park "$home" park t1 "$PR_URL" 2>&1); status=$?
  expect_code 1 "$status" "an unreadable PR must be refused"
  rm -f "$home/gh-fail"
  [ ! -e "$home/state/t1.park" ] || fail "a refused park left a record"
  [ ! -e "$home/when.log" ] && [ ! -e "$home/control.log" ] || fail "a refused park armed a watch or stopped the worker"
  park "$home" park t1 "$PR_URL" >/dev/null || fail "park failed"
  out=$(park "$home" park t1 "$PR_URL" 2>&1); status=$?
  expect_code 1 "$status" "a parked task must be refused until it is unparked"
  assert_contains "$out" "already parked" "the refusal must say the task is parked"
  pass "park: refuses a non-GitHub PR, a secondmate, an unreadable PR, and a second park"
}

test_failed_stop_rolls_back_and_unpark_is_idempotent() {
  local home out status
  home=$(make_home rollback)
  : > "$home/control-fail"
  out=$(park "$home" park t1 "$PR_URL" 2>&1); status=$?
  expect_code 1 "$status" "a worker that cannot be stopped must fail the park"
  assert_contains "$out" "keeps its session" "the failure must say the worker keeps its session"
  [ ! -e "$home/state/t1.park" ] || fail "a rolled-back park left its record"
  assert_grep "retire $T1_WATCH" "$home/when.log" "a rolled-back park must retire its watch"
  rm -f "$home/control-fail" "$home/when.log"
  park "$home" park t1 "$PR_URL" >/dev/null || fail "park failed"
  park "$home" unpark t1 >/dev/null || fail "unpark failed"
  [ ! -e "$home/state/t1.park" ] || fail "unpark left the record"
  assert_grep "retire $T1_WATCH" "$home/when.log" "unpark must retire the watch"
  park "$home" unpark t1 >/dev/null || fail "a second unpark must succeed"
  pass "park: a failed stop rolls back; unpark retires the watch and is idempotent"
}

test_long_task_ids_use_distinct_bounded_watches() {
  local home id other name other_name status
  home=$(make_home long-ids)
  id=$(printf '%064d' 0)
  other="${id%?}1"
  printf 'kind=ship\n' > "$home/state/$id.meta"
  printf 'kind=scout\n' > "$home/state/$other.meta"
  park "$home" park "$id" "$PR_URL" >/dev/null || fail "64-character task must park"
  name=$(awk '$1 == "arm" { print $2; exit }' "$home/when.log")
  [ "${#name}" -le 59 ] || fail "watch source exceeds 64 characters"
  park "$home" unpark "$id" >/dev/null || fail "long task must unpark"
  assert_grep "retire $name" "$home/when.log" "unpark must retire the armed watch"
  : > "$home/control-fail"
  park "$home" park "$other" "$PR_URL" >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "failed stop must roll back a long task"
  other_name=$(awk '$1 == "arm" { name=$2 } END { print name }' "$home/when.log")
  [ "$name" != "$other_name" ] || fail "task ids differing at character 64 must have distinct watches"
  assert_grep "retire $other_name" "$home/when.log" "rollback must retire its own watch"
  [ ! -e "$home/state/$other.park" ] || fail "rollback left a long task parked"
  pass "long task ids: bounded distinct watches in park, unpark, and rollback"
}

test_fingerprint_changes_only_when_a_check_appears_or_finishes
test_park_records_baseline_arms_watch_and_stops_worker
test_park_resolves_default_home_for_control
test_condition_and_action_follow_the_pr
test_park_refusals_change_nothing
test_failed_stop_rolls_back_and_unpark_is_idempotent

test_long_task_ids_use_distinct_bounded_watches
