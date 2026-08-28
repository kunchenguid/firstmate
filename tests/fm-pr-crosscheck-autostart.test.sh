#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# End-to-end scratch-home coverage for PR-ready Crosscheck autostart.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
SECRET_VALUE='fixture-private-fleet-value'
HEAD_ONE=1111111111111111111111111111111111111111
HEAD_TWO=2222222222222222222222222222222222222222
fm_test_tmproot_into TMP_ROOT fm-pr-crosscheck-autostart

cleanup_autostart_workers() {
  local record pid state
  while IFS= read -r record; do
    [ -f "$record" ] || continue
    read -r state pid <<EOF
$(python3 - "$record" <<'PY' 2>/dev/null || true
import json
import sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit
print(value.get("state", ""), value.get("pid", 0))
PY
)
EOF
    case "$state:$pid" in
      starting:[1-9]*|running:[1-9]*) /bin/kill -TERM -- "-$pid" >/dev/null 2>&1 || true ;;
    esac
  done < <(find "$TMP_ROOT" -name '*.crosscheck-autostart.json' -type f 2>/dev/null)
  fm_test_cleanup
}
trap cleanup_autostart_workers EXIT

if [ -n "${FM_TEST_AUTOSTART_REVISION:-}" ]; then
  mkdir -p "$TMP_ROOT/implementation"
  cp -R "$ROOT/bin" "$TMP_ROOT/implementation/bin"
  for implementation in fm-pr-check.sh fm-crosscheck-autostart.py; do
    git -C "$ROOT" show "$FM_TEST_AUTOSTART_REVISION:bin/$implementation" \
      > "$TMP_ROOT/implementation/bin/$implementation" || fail "cannot load pre-repair implementation"
  done
  PR_CHECK="$TMP_ROOT/implementation/bin/fm-pr-check.sh"
fi

make_case() {
  local name=$1 case_dir root home control
  case_dir="$TMP_ROOT/$name"
  root="$case_dir/root"
  home="$case_dir/home"
  control="$case_dir/control"
  mkdir -p "$root/bin" "$home/state" "$home/data" "$home/config" "$control"
  cat > "$root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$root/bin/fm-github-pr.py" <<'SH'
#!/usr/bin/env bash
set -u
command=$1
url=$2
number=${url##*/}
case "$command" in
  head) cat "$FM_TEST_CONTROL/head-$number" ;;
  state)
    if [ -f "$FM_TEST_CONTROL/merged-$number" ]; then
      printf 'MERGED\n'
    else
      printf 'OPEN\n'
    fi
    ;;
  *) exit 97 ;;
esac
SH
  cat > "$root/bin/fm-crosscheck.sh" <<'SH'
#!/usr/bin/env bash
set -u
verb=$1
task=$2
url=$3
number=${url##*/}
head=$(cat "$FM_TEST_CONTROL/head-$number")
shift 3
case "$verb" in
  run)
    [ "${FM_TEST_FLEET_SECRET:-}" = fixture-private-fleet-value ] || {
      printf 'fleet environment is incomplete\n'
      exit 96
    }
    [ "${1:-}" = --expected-head ] && [ "${2:-}" = "$head" ] || {
      printf 'registered exact head was not enforced\n'
      exit 95
    }
    ;;
  verify) [ "$#" -eq 0 ] || exit 94 ;;
  *) exit 97 ;;
esac
control=${FM_TEST_CONTROL:?}
printf '%s\t%s\t%s\t%s\n' "$verb" "$task" "$head" "$url" >> "$control/calls"
case "$verb" in
  verify)
    if [ -f "$control/clear-$task-$head" ]; then
      printf '%s\n' "$head"
      exit 0
    fi
    printf 'no clear review for %s\n' "$head"
    exit 1
    ;;
  run)
    touch "$control/started-$task-$head"
    while [ -f "$control/block-$task-$head" ] \
      && [ ! -f "$control/release-$task-$head" ]; do
      sleep 0.05
    done
    touch "$control/clear-$task-$head"
    printf 'crosscheck clear: %s at %s\n' "$url" "$head"
    ;;
esac
SH
  chmod +x "$root/bin/fm-guard.sh" "$root/bin/fm-github-pr.py" "$root/bin/fm-crosscheck.sh"
  cat > "$case_dir/fleet.env" <<EOF
FM_TEST_FLEET_SECRET='$SECRET_VALUE'
EOF
  chmod 600 "$case_dir/fleet.env"
  : > "$control/calls"
  printf '%s\n' "$case_dir"
}

seed_task() {
  local case_dir=$1 task=$2
  mkdir -p "$case_dir/home/data/$task" "$case_dir/worktrees/$task" "$case_dir/projects/$task"
  fm_write_meta "$case_dir/home/state/$task.meta" \
    "window=fm-$task" \
    "worktree=$case_dir/worktrees/$task" \
    "project=$case_dir/projects/$task" \
    'kind=ship' \
    'mode=no-mistakes' \
    "generation_id=generation-$task"
}

set_head() {
  local case_dir=$1 pull=$2 head=$3
  printf '%s\n' "$head" > "$case_dir/control/head-$pull"
}

run_pr_check() {
  local case_dir=$1 task=$2 pull=$3
  FM_ROOT_OVERRIDE="$case_dir/root" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_DATA_OVERRIDE="$case_dir/home/data" \
  FM_CROSSCHECK_FLEET_ENV="$case_dir/fleet.env" \
  FM_CROSSCHECK_AUTOSTART_ACTIVE_WAIT_SECONDS=10 \
  FM_CROSSCHECK_AUTOSTART_COMMAND_TIMEOUT_SECONDS=20 \
  FM_TEST_CONTROL="$case_dir/control" \
    "$PR_CHECK" "$task" "https://github.com/example/repo/pull/$pull"
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
result = value.get(sys.argv[2], "")
print(result)
PY
}

wait_for_state() {
  local record=$1 expected_state=$2 expected_head=$3 minimum_attempt=${4:-1} i=0 state head attempt
  while [ "$i" -lt 400 ]; do
    if [ -f "$record" ]; then
      state=$(json_field "$record" state 2>/dev/null || true)
      head=$(json_field "$record" head_sha 2>/dev/null || true)
      attempt=$(json_field "$record" attempt 2>/dev/null || true)
      if [ "$state" = "$expected_state" ] && [ "$head" = "$expected_head" ] \
        && case "$attempt" in ''|*[!0-9]*) false ;; *) [ "$attempt" -ge "$minimum_attempt" ] ;; esac; then
        return 0
      fi
    fi
    sleep 0.05
    i=$((i + 1))
  done
  [ ! -f "$record" ] || cat "$record" >&2
  return 1
}

count_run_calls() {
  local case_dir=$1 task=$2 head=${3:-}
  if [ -n "$head" ]; then
    awk -F '\t' -v task="$task" -v head="$head" \
      '$1 == "run" && $2 == task && $3 == head { count++ } END { print count + 0 }' \
      "$case_dir/control/calls"
  else
    awk -F '\t' -v task="$task" \
      '$1 == "run" && $2 == task { count++ } END { print count + 0 }' \
      "$case_dir/control/calls"
  fi
}

monotonic_now() {
  python3 -c 'import time; print(time.monotonic())'
}

elapsed_seconds() {
  python3 - "$1" "$2" <<'PY'
import sys
print(float(sys.argv[2]) - float(sys.argv[1]))
PY
}

assert_less_than() {
  python3 - "$1" "$2" <<'PY' || fail "$3"
import sys
raise SystemExit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)
PY
}

test_prompt_return_active_and_clear_dedupe() {
  local case_dir task=preturn pull=1 started ended elapsed state_file out calls
  case_dir=$(make_case prompt-return)
  seed_task "$case_dir" "$task"
  set_head "$case_dir" "$pull" "$HEAD_ONE"
  touch "$case_dir/control/block-$task-$HEAD_ONE"

  started=$(monotonic_now)
  out=$(run_pr_check "$case_dir" "$task" "$pull") \
    || fail "PR-ready registration failed before asynchronous review: $out"
  ended=$(monotonic_now)
  elapsed=$(elapsed_seconds "$started" "$ended")
  assert_less_than "$elapsed" 3 \
    "PR-ready registration waited ${elapsed}s for the blocked Crosscheck review"
  assert_contains "$out" 'crosscheck autostart: started' \
    "PR-ready registration did not report the asynchronous launch"
  fm_test_wait_for_file "$case_dir/control/started-$task-$HEAD_ONE" '' 0.02 \
    || fail "asynchronous Crosscheck review never started"

  out=$(run_pr_check "$case_dir" "$task" "$pull") \
    || fail "matching active registration failed: $out"
  assert_contains "$out" 'matching review already active' \
    "matching active review was not deduplicated"
  calls=$(count_run_calls "$case_dir" "$task" "$HEAD_ONE")
  expect_code 1 "$calls" "matching active Crosscheck run count"

  touch "$case_dir/control/release-$task-$HEAD_ONE"
  state_file="$case_dir/home/state/$task.crosscheck-autostart.json"
  wait_for_state "$state_file" clear "$HEAD_ONE" 1 \
    || fail "first Crosscheck review did not reach exact-head CLEAR"
  out=$(run_pr_check "$case_dir" "$task" "$pull") \
    || fail "matching clear registration failed: $out"
  wait_for_state "$state_file" clear "$HEAD_ONE" 2 \
    || fail "matching CLEAR deduplication did not finish exact-head verification"
  calls=$(count_run_calls "$case_dir" "$task" "$HEAD_ONE")
  expect_code 1 "$calls" "matching CLEAR Crosscheck run count"
  rm "$case_dir/fleet.env"
  run_pr_check "$case_dir" "$task" "$pull" >/dev/null \
    || fail "matching CLEAR registration depended on repaired launch configuration"
  wait_for_state "$state_file" clear "$HEAD_ONE" 3 \
    || fail "matching CLEAR result was not reusable while launch configuration was absent"
  calls=$(count_run_calls "$case_dir" "$task" "$HEAD_ONE")
  expect_code 1 "$calls" "configuration-independent matching CLEAR run count"
  if grep -F "$SECRET_VALUE" \
    "$case_dir/home/state/$task.crosscheck-autostart.json" \
    "$case_dir/home/state/$task.crosscheck-autostart.request.json" \
    "$case_dir/home/state/$task.crosscheck-autostart.log" >/dev/null; then
    fail "operator fleet environment value was copied into autostart state or logs"
  fi
  pass "PR-ready registration returns promptly and deduplicates active and CLEAR exact heads"
}

test_configuration_failures_are_visible_and_retryable() {
  local case_dir task=retry pull=2 state_file out wake calls message
  case_dir=$(make_case retry)
  seed_task "$case_dir" "$task"
  set_head "$case_dir" "$pull" "$HEAD_ONE"
  state_file="$case_dir/home/state/$task.crosscheck-autostart.json"

  rm "$case_dir/fleet.env"
  out=$(run_pr_check "$case_dir" "$task" "$pull" 2>&1) \
    || fail "missing fleet environment failed PR registration"
  assert_contains "$out" 'crosscheck autostart: started' \
    "missing fleet environment prevented prompt-return coordinator launch"
  wait_for_state "$state_file" failed "$HEAD_ONE" 1 \
    || fail "missing fleet environment did not persist task-local failure"
  message=$(json_field "$state_file" message)
  assert_contains "$message" 'fleet environment is missing' \
    "missing fleet environment did not leave an actionable task diagnostic"

  printf "FM_TEST_FLEET_SECRET='%s'\n" "$SECRET_VALUE" > "$case_dir/fleet.env"
  chmod 666 "$case_dir/fleet.env"
  out=$(run_pr_check "$case_dir" "$task" "$pull" 2>&1) \
    || fail "unsafe fleet environment failed PR registration"
  assert_contains "$out" 'crosscheck autostart: started' \
    "unsafe fleet environment prevented prompt-return coordinator launch"
  wait_for_state "$state_file" failed "$HEAD_ONE" 2 \
    || fail "unsafe fleet environment did not persist retryable state"
  message=$(json_field "$state_file" message)
  assert_contains "$message" 'group/world writable' \
    "unsafe fleet environment did not leave an actionable task diagnostic"

  printf 'FM_TEST_UNRELATED=present\n' > "$case_dir/fleet.env"
  chmod 600 "$case_dir/fleet.env"
  run_pr_check "$case_dir" "$task" "$pull" >/dev/null \
    || fail "incomplete fleet environment failed PR registration"
  wait_for_state "$state_file" failed "$HEAD_ONE" 3 \
    || fail "incomplete fleet environment did not become an asynchronous task failure"
  wake=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/home/state" \
    FM_TEST_CONTROL="$case_dir/control" \
    bash "$case_dir/home/state/$task.check.sh") \
    || fail "failed-autostart task check exited nonzero"
  assert_contains "$wake" 'UNREVIEWED: Crosscheck autostart failed' \
    "failed background launch was not visible to supervision"

  touch "$case_dir/control/merged-$pull"
  wake=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/home/state" \
    FM_TEST_CONTROL="$case_dir/control" \
    bash "$case_dir/home/state/$task.check.sh") \
    || fail "merged task check exited nonzero"
  [ "$wake" = merged ] || fail "persisted launcher failure hid live merge: $wake"
  [ "$(json_field "$state_file" state)" = failed ] \
    || fail "merge observation erased the actionable launcher failure"
  rm "$case_dir/control/merged-$pull"

  printf "FM_TEST_FLEET_SECRET='%s'\n" "$SECRET_VALUE" > "$case_dir/fleet.env"
  out=$(run_pr_check "$case_dir" "$task" "$pull") \
    || fail "retry after restoring the fleet environment failed: $out"
  wait_for_state "$state_file" clear "$HEAD_ONE" 4 \
    || fail "retry did not reach exact-head CLEAR"
  calls=$(count_run_calls "$case_dir" "$task" "$HEAD_ONE")
  expect_code 1 "$calls" "retry Crosscheck run count"
  pass "missing, unsafe, and incomplete configuration stay visible and retry with one task identity"
}

test_dead_coordinator_is_visible_and_retryable() {
  local case_dir task=dead pull=3 state_file pid wake calls out
  case_dir=$(make_case dead-coordinator)
  seed_task "$case_dir" "$task"
  set_head "$case_dir" "$pull" "$HEAD_ONE"
  touch "$case_dir/control/block-$task-$HEAD_ONE"
  run_pr_check "$case_dir" "$task" "$pull" >/dev/null \
    || fail "dead-coordinator fixture did not register"
  fm_test_wait_for_file "$case_dir/control/started-$task-$HEAD_ONE" '' 0.02 \
    || fail "dead-coordinator fixture never entered the review"
  state_file="$case_dir/home/state/$task.crosscheck-autostart.json"
  wait_for_state "$state_file" running "$HEAD_ONE" 1 \
    || fail "dead-coordinator fixture never recorded a running owner"
  pid=$(json_field "$state_file" pid)

  set_head "$case_dir" "$pull" "$HEAD_TWO"
  touch "$case_dir/control/block-$task-$HEAD_TWO"
  out=$(run_pr_check "$case_dir" "$task" "$pull") \
    || fail "dead-coordinator new-head queue failed: $out"
  assert_contains "$out" "queued new head $HEAD_TWO" \
    "dead-coordinator fixture did not queue its successor head"
  /bin/kill -TERM -- "-$pid" >/dev/null 2>&1 \
    || fail "could not terminate the isolated coordinator fixture"

  sleep 0.1
  wake=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/home/state" \
    FM_TEST_CONTROL="$case_dir/control" \
    bash "$case_dir/home/state/$task.check.sh") \
    || fail "dead coordinator task check exited nonzero"
  assert_contains "$wake" 'stopped before the requested head started' \
    "dead coordinator did not surface its queued head as retryable"
  wait_for_state "$state_file" failed "$HEAD_TWO" 2 \
    || fail "dead coordinator did not record failure for its queued head"

  touch "$case_dir/control/release-$task-$HEAD_TWO"
  run_pr_check "$case_dir" "$task" "$pull" >/dev/null \
    || fail "dead coordinator did not retry under the same task identity"
  wait_for_state "$state_file" clear "$HEAD_TWO" 3 \
    || fail "dead coordinator retry did not reach exact-head CLEAR"
  calls=$(count_run_calls "$case_dir" "$task" "$HEAD_ONE")
  expect_code 1 "$calls" "dead coordinator abandoned-head Crosscheck run count"
  calls=$(count_run_calls "$case_dir" "$task" "$HEAD_TWO")
  expect_code 1 "$calls" "dead coordinator retry Crosscheck run count"
  pass "a dead task-local coordinator surfaces and retries its queued exact head"
}

test_new_head_restarts_without_prompt_wait() {
  local case_dir task=newhead pull=4 state_file out calls
  case_dir=$(make_case new-head)
  seed_task "$case_dir" "$task"
  set_head "$case_dir" "$pull" "$HEAD_ONE"
  touch "$case_dir/control/block-$task-$HEAD_ONE"
  run_pr_check "$case_dir" "$task" "$pull" >/dev/null \
    || fail "first-head registration failed"
  fm_test_wait_for_file "$case_dir/control/started-$task-$HEAD_ONE" '' 0.02 \
    || fail "first-head review did not start"

  set_head "$case_dir" "$pull" "$HEAD_TWO"
  touch "$case_dir/control/block-$task-$HEAD_TWO"
  out=$(run_pr_check "$case_dir" "$task" "$pull") \
    || fail "new-head registration failed: $out"
  assert_contains "$out" "queued new head $HEAD_TWO" \
    "new head did not replace the active coordinator request"
  touch "$case_dir/control/release-$task-$HEAD_ONE"
  fm_test_wait_for_file "$case_dir/control/started-$task-$HEAD_TWO" '' 0.02 \
    || fail "coordinator did not restart Crosscheck for the new head"
  touch "$case_dir/control/release-$task-$HEAD_TWO"
  state_file="$case_dir/home/state/$task.crosscheck-autostart.json"
  wait_for_state "$state_file" clear "$HEAD_TWO" 2 \
    || fail "new-head review did not reach exact-head CLEAR"
  calls=$(count_run_calls "$case_dir" "$task" "$HEAD_ONE")
  expect_code 1 "$calls" "first-head Crosscheck run count"
  calls=$(count_run_calls "$case_dir" "$task" "$HEAD_TWO")
  expect_code 1 "$calls" "new-head Crosscheck run count"
  pass "a newly registered PR head restarts Crosscheck after the active head returns"
}

test_unrelated_prs_start_concurrently() {
  local case_dir task_a=parallel-a task_b=parallel-b state_a state_b calls
  case_dir=$(make_case concurrency)
  seed_task "$case_dir" "$task_a"
  seed_task "$case_dir" "$task_b"
  set_head "$case_dir" 5 "$HEAD_ONE"
  set_head "$case_dir" 6 "$HEAD_TWO"
  touch "$case_dir/control/block-$task_a-$HEAD_ONE" \
    "$case_dir/control/block-$task_b-$HEAD_TWO"

  run_pr_check "$case_dir" "$task_a" 5 >/dev/null \
    || fail "first unrelated PR registration failed"
  run_pr_check "$case_dir" "$task_b" 6 >/dev/null \
    || fail "second unrelated PR registration failed"
  fm_test_wait_for_file "$case_dir/control/started-$task_a-$HEAD_ONE" '' 0.02 \
    || fail "first unrelated Crosscheck did not start"
  fm_test_wait_for_file "$case_dir/control/started-$task_b-$HEAD_TWO" '' 0.02 \
    || fail "second unrelated Crosscheck was serialized behind a fleet-global lock"
  calls=$(count_run_calls "$case_dir" "$task_a")
  expect_code 1 "$calls" "first unrelated Crosscheck run count"
  calls=$(count_run_calls "$case_dir" "$task_b")
  expect_code 1 "$calls" "second unrelated Crosscheck run count"

  touch "$case_dir/control/release-$task_a-$HEAD_ONE" \
    "$case_dir/control/release-$task_b-$HEAD_TWO"
  state_a="$case_dir/home/state/$task_a.crosscheck-autostart.json"
  state_b="$case_dir/home/state/$task_b.crosscheck-autostart.json"
  wait_for_state "$state_a" clear "$HEAD_ONE" 1 \
    || fail "first concurrent Crosscheck did not clear"
  wait_for_state "$state_b" clear "$HEAD_TWO" 1 \
    || fail "second concurrent Crosscheck did not clear"
  pass "unrelated PR Crosschecks run concurrently with task-local coordination only"
}

test_retirement_handoff() {
  local case_dir task=retire pull=7
  case_dir=$(make_case retirement)
  seed_task "$case_dir" "$task"
  set_head "$case_dir" "$pull" "$HEAD_ONE"
  mkdir "$case_dir/hook"
  cat > "$case_dir/hook/sitecustomize.py" <<'PYHOOK'
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import time

control = Path(os.environ["FM_TEST_CONTROL"])
state = Path(os.environ["FM_STATE_OVERRIDE"])
original_close = os.close
original_flock = fcntl.flock
original_replace = os.replace


def wait_for(path):
    deadline = time.monotonic() + 15
    while not path.exists():
        if time.monotonic() > deadline:
            raise RuntimeError("retirement barrier timed out")
        time.sleep(0.01)


if len(sys.argv) > 3 and sys.argv[1] == "start":
    def flock(descriptor, operation):
        handoff = state / ".retire.crosscheck-autostart-handoff.lock"
        if handoff.exists() and os.fstat(descriptor).st_ino == handoff.stat().st_ino:
            (control / "successor-contending").touch()
        return original_flock(descriptor, operation)

    def replace(source, destination, *args, **kwargs):
        result = original_replace(source, destination, *args, **kwargs)
        if Path(destination).name == "retire.crosscheck-autostart.request.json":
            (control / "successor-contending").touch()
        return result

    fcntl.flock = flock
    os.replace = replace

if len(sys.argv) > 3 and sys.argv[1] == "worker":
    coordinator = int(sys.argv[2])

    def close(descriptor):
        if descriptor == coordinator and not (control / "retirement-entered").exists():
            (control / "retirement-entered").touch()
            (control / "head-7").write_text("2" * 40 + "\n")
            (control / "successor-contending").unlink(missing_ok=True)
            with (control / "registration-output").open("w") as output:
                subprocess.Popen(
                    [os.environ["FM_TEST_PR_CHECK"], "retire",
                     "https://github.com/example/repo/pull/7"],
                    stdout=output, stderr=output,
                )
            wait_for(control / "successor-contending")
        return original_close(descriptor)

    os.close = close
PYHOOK
  PYTHONPATH="$case_dir/hook" FM_TEST_PR_CHECK="$PR_CHECK" \
    run_pr_check "$case_dir" "$task" "$pull" >/dev/null \
    || fail "retirement fixture registration failed"
  fm_test_wait_for_file "$case_dir/control/retirement-entered" '' 0.02 \
    || fail "coordinator did not reach the retirement boundary"
  fm_test_wait_for_file "$case_dir/control/started-$task-$HEAD_TWO" '' 0.02 \
    || fail "registration during retirement lost its successor review"
  wait_for_state "$case_dir/home/state/$task.crosscheck-autostart.json" clear "$HEAD_TWO" 2 \
    || fail "retirement successor did not clear the new exact head"
  expect_code 1 "$(count_run_calls "$case_dir" "$task" "$HEAD_TWO")" \
    "retirement successor Crosscheck count"
  pass "registration at coordinator retirement hands off the new exact head"
}

test_registration_capture_order() {
  local case_dir task=ordered pull=8 first second state_file
  case_dir=$(make_case capture-order)
  seed_task "$case_dir" "$task"
  set_head "$case_dir" "$pull" "$HEAD_ONE"
  cat > "$case_dir/root/bin/fm-github-pr.py" <<'SH'
#!/usr/bin/env bash
if [ "$1" != head ]; then
  echo OPEN
  exit 0
fi
head=$(cat "$FM_TEST_CONTROL/head-8")
if [ "${FM_TEST_CAPTURE_FIRST:-}" = 1 ]; then
  touch "$FM_TEST_CONTROL/captured-first"
  while [ ! -f "$FM_TEST_CONTROL/release-capture" ]; do sleep 0.01; done
fi
printf '%s\n' "$head"
SH
  touch "$case_dir/control/block-$task-$HEAD_TWO"
  FM_TEST_CAPTURE_FIRST=1 run_pr_check "$case_dir" "$task" "$pull" \
    > "$case_dir/first.out" 2>&1 &
  first=$!
  fm_test_wait_for_file "$case_dir/control/captured-first" '' 0.02 \
    || fail "first registration did not capture its head"
  set_head "$case_dir" "$pull" "$HEAD_TWO"
  (
    FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1 \
    FM_ACCOUNT_TEST_HOOKS=firstmate-account-tests-v1 \
    FM_ACCOUNT_LOCK_WAIT_TEST_OBSERVED="$case_dir/control/second-waiting" \
      run_pr_check "$case_dir" "$task" "$pull" > "$case_dir/second.out" 2>&1
    result=$?
    touch "$case_dir/control/second-finished"
    exit "$result"
  ) &
  second=$!
  python3 - "$case_dir/control" <<'PYWAIT' || fail "second registration did not reach the ordering barrier"
from pathlib import Path
import sys
import time
control = Path(sys.argv[1])
deadline = time.monotonic() + 15
while not any((control / name).exists() for name in ("second-waiting", "second-finished")):
    if time.monotonic() > deadline:
        raise SystemExit(1)
    time.sleep(0.01)
PYWAIT
  touch "$case_dir/control/release-capture"
  wait "$first" || fail "first registration failed"
  wait "$second" || fail "second registration failed"
  state_file="$case_dir/home/state/$task.crosscheck-autostart.request.json"
  [ "$(json_field "$state_file" head_sha)" = "$HEAD_TWO" ] \
    || fail "older captured head replaced the newer registration"
  touch "$case_dir/control/release-$task-$HEAD_TWO"
  state_file="$case_dir/home/state/$task.crosscheck-autostart.json"
  wait_for_state "$state_file" clear "$HEAD_TWO" \
    || fail "latest captured head never reached CLEAR"
  expect_code 1 "$(count_run_calls "$case_dir" "$task" "$HEAD_TWO")" \
    "latest captured head review count"
  pass "head capture and publication preserve task-local registration order"
}

test_status_completion_race() {
  local case_dir task=statusrace pull=9 state_file out
  case_dir=$(make_case status-race)
  seed_task "$case_dir" "$task"
  set_head "$case_dir" "$pull" "$HEAD_ONE"
  touch "$case_dir/control/block-$task-$HEAD_ONE"
  mkdir "$case_dir/hook"
  cat > "$case_dir/hook/sitecustomize.py" <<'PYHOOK'
import fcntl
import json
import os
from pathlib import Path
import sys
import time

control = Path(os.environ["FM_TEST_CONTROL"])
state = Path(os.environ["FM_STATE_OVERRIDE"])
original_flock = fcntl.flock
original_close = os.close
original_loads = json.loads


def same_file(descriptor, name):
    path = state / name
    return path.exists() and os.fstat(descriptor).st_ino == path.stat().st_ino


def wait_for(path):
    deadline = time.monotonic() + 15
    while not path.exists():
        if time.monotonic() > deadline:
            raise RuntimeError("status barrier timed out")
        time.sleep(0.01)


if len(sys.argv) > 3 and sys.argv[1] == "worker":
    coordinator = int(sys.argv[2])

    def flock(descriptor, operation):
        if same_file(descriptor, ".statusrace.crosscheck-autostart-handoff.lock"):
            (control / "worker-retiring").touch()
        return original_flock(descriptor, operation)

    def close(descriptor):
        result = original_close(descriptor)
        if descriptor == coordinator:
            (control / "worker-closed").touch()
        return result

    fcntl.flock = flock
    os.close = close

if len(sys.argv) > 3 and sys.argv[1] == "status":
    coordinated = False

    def flock(descriptor, operation):
        global coordinated
        result = original_flock(descriptor, operation)
        if same_file(descriptor, ".statusrace.crosscheck-autostart-handoff.lock"):
            coordinated = True
        return result

    fcntl.flock = flock

    def loads(raw, *args, **kwargs):
        value = original_loads(raw, *args, **kwargs)
        if isinstance(value, dict) and value.get("state") == "running":
            (control / "status-read-running").touch()
            (control / ("release-statusrace-" + "1" * 40)).touch()
            wait_for(control / ("worker-retiring" if coordinated else "worker-closed"))
        return value

    json.loads = loads
PYHOOK
  PYTHONPATH="$case_dir/hook" run_pr_check "$case_dir" "$task" "$pull" >/dev/null \
    || fail "status-race registration failed"
  fm_test_wait_for_file "$case_dir/control/started-$task-$HEAD_ONE" '' 0.02 \
    || fail "status-race review never started"
  out=$(PYTHONPATH="$case_dir/hook" FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" FM_TEST_CONTROL="$case_dir/control" \
    "$(dirname "$PR_CHECK")/fm-crosscheck-autostart.py" status "$task" \
      "https://github.com/example/repo/pull/$pull" "$HEAD_ONE" "generation-$task" 2>&1) \
    || fail "status replaced worker completion with failure: $out"
  [ -f "$case_dir/control/status-read-running" ] || fail "status race was not exercised"
  state_file="$case_dir/home/state/$task.crosscheck-autostart.json"
  wait_for_state "$state_file" clear "$HEAD_ONE" \
    || fail "status overwrote durable CLEAR"
  out=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/home/state" \
    FM_TEST_CONTROL="$case_dir/control" bash "$case_dir/home/state/$task.check.sh") \
    || fail "follow-up poll failed"
  [ -z "$out" ] || fail "CLEAR unexpectedly emitted a merge or failure wake: $out"
  pass "status cannot replace concurrent worker completion with a stale failure"
}

test_repeated_pr_registration_replaces_metadata() {
  local case_dir task=longlived meta state_file
  case_dir=$(make_case repeated-pr)
  seed_task "$case_dir" "$task"
  meta="$case_dir/home/state/$task.meta"
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/90' \
    'pr_head=9090909090909090909090909090909090909090' \
    'pr=https://github.com/example/repo/pull/91' \
    'pr_head=9191919191919191919191919191919191919191' >> "$meta"
  set_head "$case_dir" 10 "$HEAD_ONE"
  run_pr_check "$case_dir" "$task" 10 >/dev/null \
    || fail "first long-lived-task PR registration failed"
  set_head "$case_dir" 11 "$HEAD_TWO"
  run_pr_check "$case_dir" "$task" 11 >/dev/null \
    || fail "later long-lived-task PR registration failed"
  expect_code 1 "$(grep -c '^pr=' "$meta")" "registered PR metadata count"
  expect_code 1 "$(grep -c '^pr_head=' "$meta")" "registered PR head metadata count"
  grep -qxF 'pr=https://github.com/example/repo/pull/11' "$meta" \
    || fail "later PR URL did not replace earlier registrations"
  grep -qxF "pr_head=$HEAD_TWO" "$meta" \
    || fail "later live head did not replace earlier registrations"
  state_file="$case_dir/home/state/$task.crosscheck-autostart.json"
  wait_for_state "$state_file" clear "$HEAD_TWO" 2 \
    || fail "later PR registration did not reach exact-head CLEAR"
  pass "a later PR atomically replaces all earlier PR metadata for one task"
}

case "${FM_TEST_AUTOSTART_CASE:-all}" in
  retirement) test_retirement_handoff ;;
  registration) test_registration_capture_order; test_repeated_pr_registration_replaces_metadata ;;
  status) test_status_completion_race ;;
  consumer) test_configuration_failures_are_visible_and_retryable ;;
  all)
    test_retirement_handoff
    test_registration_capture_order
    test_repeated_pr_registration_replaces_metadata
    test_status_completion_race
    test_prompt_return_active_and_clear_dedupe
    test_configuration_failures_are_visible_and_retryable
    test_dead_coordinator_is_visible_and_retryable
    test_new_head_restarts_without_prompt_wait
    test_unrelated_prs_start_concurrently
    ;;
  *) fail "unknown autostart regression selection" ;;
esac

echo '# all selected fm-pr-crosscheck-autostart tests passed'
