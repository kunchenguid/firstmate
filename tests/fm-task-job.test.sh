#!/usr/bin/env bash
# tests/fm-task-job.test.sh - task jobs (bin/fm-task-job.sh,
# bin/fm-task-job-lib.sh): a worker command that outlives its turn and whose
# exit reaches the task's steering inbox.
#
# The gap this closes: a worker ends its turn while its own monitoring command
# still runs, the command then finishes, and no turn follows, because the
# harness records the exit against the ended turn and nothing rings the worker.
# These tests pin the replacement with real processes and a fake terminal:
#   1. A finished command becomes one durable hold-aware inbox record keyed by
#      task, starting spawn generation, and job id, and its doorbell rings.
#   2. The record names the generation that started the job even after a
#      relaunch replaced it.
#   3. A command past its timeout is stopped with its whole process group.
#   4. A task holding an open decision of its own gets the record without a
#      ring, and the watcher's job delivery leaves it unrung until the decision
#      closes, then rings it.
#   5. A doorbell that did not land is re-rung by the watcher until the worker
#      acknowledges the record.
#   6. A running watcher reports an unrecoverable job after runner loss without
#      signaling an unproven process group or publishing a completion.
#   7. Teardown's stop-all stops live jobs without delivering anything.
#   8. A job whose task inbox was removed never recreates it.
#   9. Start refuses without a task identity or a valid timeout.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

JOB="$ROOT/bin/fm-task-job.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-job)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
DOORBELL="Firstmate instruction waiting: list \"\$FM_TASK_INBOX\"/*.msg in your 't1.inbox' steering inbox"
command -v tasks-axi >/dev/null 2>&1 || { echo 'skip: tasks-axi not found'; exit 0; }

# A fake tmux: every literal send-keys is logged to FM_SEND_LOG so a doorbell
# is observable, FM_FAKE_TMUX_SEND_FAIL=1 makes sends fail, and capture-pane
# shows an idle composer box.
make_stubs() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    if [ -n "${FM_JOB_RETIRE_ON_SEND:-}" ]; then
      for arg in "$@"; do
        case "$arg" in
          *"'t1.inbox'"*)
            rm -rf -- "$FM_JOB_RETIRE_ON_SEND"
            if [ "${FM_JOB_RETIRE_SEND_FAIL:-0}" = 1 ]; then
              printf 'send failed\n' >> "${FM_SEND_LOG:-/dev/null}"
              exit 1
            fi
            ;;
        esac
      done
    fi
    if [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ]; then
      printf 'send failed\n' >> "${FM_SEND_LOG:-/dev/null}"
      exit 1
    fi
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 0 ] || printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ "${FM_JOB_BUSY_TARGET:-0}" = 1 ]; then
      for arg in "$@"; do
        case "$arg" in *fm-t1*) printf 'BUSYTOKEN active\n'; exit 0 ;; esac
      done
    fi
    printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' "${FM_FAKE_TMUX_WINDOWS:-fm-t1}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  make_fake_crew_state "$fb" >/dev/null
}

setup_case() {  # <name> -> echoes the case dir; task t1 lives in <dir>/state
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state/t1.inbox/handled" "$dir/data" "$dir/owning-data" "$dir/config"
  fm_test_tasks_toml "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  cp "$dir/data/backlog.md" "$dir/owning-data/backlog.md"
  make_stubs "$dir"
  : > "$dir/send.log"
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=grok" "spawn_gen=gen-A"
  printf 'paused [at=1]: waiting for my own monitor\n' > "$dir/state/t1.status"
  printf '%s\n' "$dir"
}

# Start a task job the way a worker does: from the task's environment.
job_start() {  # <dir> <start args...>
  local dir=$1
  shift
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/owning-data" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_TASK_INBOX="$dir/state/t1.inbox" FM_SEND_LOG="$dir/send.log" \
    "$JOB" start "$@"
}

case_command() {
  local dir=$1
  shift
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/owning-data" FM_CONFIG_OVERRIDE="$dir/config" "$@"
}

wait_for_file() {
  local i=0
  while [ "$i" -lt 200 ]; do
    [ -s "$1" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

start_stubborn_job() {
  cat > "$1/stubborn.pl" <<'PL'
$SIG{TERM} = "IGNORE";
open(my $ready, ">", $ARGV[0]) or die $!;
print $ready "$$\n";
close($ready);
sleep 60;
PL
  cat > "$1/monitor.sh" <<'SH'
perl "$1/stubborn.pl" "$1/grandchild.pid" &
wait
SH
  job_start "$1" --timeout "$2" -- sh "$1/monitor.sh" "$1"
}

start_waiting_job() {
  cat > "$1/wait.sh" <<'SH'
while [ ! -f "$1" ]; do sleep 0.1; done
SH
  job_start "$1" --timeout 60 -- sh "$1/wait.sh" "$1/release"
}

job_lib() {  # <dir> <function> [args...]
  local dir=$1
  shift
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/owning-data" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_STATE_OVERRIDE="$dir/state" FM_SEND_LOG="$dir/send.log" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-job-lib.sh" "$@"
}

# One watcher steering-inbox pass, as the poll loop runs it.
steer_check() {  # <dir>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_DATA_OVERRIDE="$1/owning-data" FM_CONFIG_OVERRIDE="$1/config" \
    FM_STATE_OVERRIDE="$1/state" FM_SEND_LOG="$1/send.log" \
    FM_TASK_INBOX_GRACE_SECS="${2:-90}" \
    bash -c '
      . "$1" || exit 1
      fm_task_job_reconcile "$STATE" t1 || exit 1
      task_job_check sess:fm-t1 t1 || exit 1
      inbox_steer_check sess:fm-t1 t1
      [ -z "$TASK_JOB_WAKE_REASON" ] || wake "$TASK_JOB_WAKE_REASON"
    ' _ "$WATCH" >/dev/null 2>&1
}

age_path() {  # <path>  (set mtime well past any grace under test)
  touch -t 202001010000 "$1"
}

records() {  # <dir> -> unhandled record paths, one per line
  local f
  for f in "$1/state/t1.inbox"/*.msg; do
    [ -e "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

record_count() {  # <dir>
  records "$1" | grep -c . || true
}

wait_for_record() {  # <dir>
  local i=0
  while [ "$i" -lt 200 ]; do
    steer_check "$1" "${2:-90}" || return 1
    [ "$(record_count "$1")" -ge 1 ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_gone() {  # <pid>
  local i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

job_dir_of() {  # <dir> <start-output>
  local id
  id=$(printf '%s\n' "$2" | sed -n 's/^job: //p')
  printf '%s/state/t1.inbox/jobs/%s' "$1" "$id"
}

body_of() {  # <record>
  sed '1,/^--$/d' "$1"
}

test_completion_reaches_inbox_and_rings() {
  local dir out jobdir rec body until_line
  dir=$(setup_case finished)
  out=$(job_start "$dir" --timeout 60 -- \
    sh -c 'echo monitored-outcome; exit 3') || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  [ -d "$jobdir" ] || fail "start did not report its job directory:"$'\n'"$out"
  assert_contains "$out" "output: $jobdir/output" "start should print the output path"
  until_line=$(printf '%s\n' "$out" | sed -n 's/^until: //p')
  case "$until_line" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]Z) ;;
    *) fail "start should print a UTC minute for the paused declaration, got: $until_line" ;;
  esac
  wait_for_file "$jobdir/exit" || fail "the runner did not publish its exit"
  wait_gone "$(sed -n 's/^pid=//p' "$jobdir/runner")" || fail "the runner did not finish"
  [ "$(record_count "$dir")" = 0 ] || fail "the runner delivered without a watcher"
  [ ! -s "$dir/send.log" ] || fail "the runner rang without a watcher"
  wait_for_record "$dir" || fail "a finished command produced no inbox record"
  wait_gone "$(sed -n 's/^pid=//p' "$jobdir/runner")" || fail "the runner outlived its delivery"
  [ "$(record_count "$dir")" = 1 ] || fail "expected one completion record, got:"$'\n'"$(records "$dir")"
  rec=$(records "$dir")
  body=$(body_of "$rec")
  assert_contains "$body" "Task job ${jobdir##*/} finished: the command exited with status 3." \
    "the record should name the job and its exit status"
  assert_contains "$body" "Task: t1; started by worker generation gen-A." \
    "the record should key the completion by task and spawn generation"
  assert_contains "$body" "Output: $jobdir/output" "the record should point at the output"
  assert_contains "$body" "not a new instruction" "the record should read as a result, not an order"
  assert_grep 'delivery=hold-aware' "$rec" "a completion record should be hold-aware"
  assert_grep 'monitored-outcome' "$jobdir/output" "the command's output should be captured"
  assert_grep "record=${rec##*/}" "$jobdir/delivered" "the job should record where it was delivered"
  assert_grep "$DOORBELL" "$dir/send.log" "the completion should ring the worker's doorbell"
  pass "task job: a finished command becomes one keyed inbox record and rings the worker"
}

test_completion_names_the_starting_generation() {
  local dir out jobdir
  dir=$(setup_case relaunched)
  out=$(job_start "$dir" --timeout 60 -- sh -c 'sleep 1') || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=grok" "spawn_gen=gen-B"
  wait_for_record "$dir" || fail "the job was not delivered to the relaunched task"
  assert_contains "$(body_of "$(records "$dir")")" "started by worker generation gen-A." \
    "a relaunched task should learn which generation started the job"
  assert_grep 'gen=gen-A' "$jobdir/job" "the job record should keep its starting generation"
  pass "task job: a completion names the spawn generation that started it"
}

test_timeout_stops_the_command_group() {
  local dir out jobdir grandchild
  dir=$(setup_case timeout)
  # shellcheck disable=SC2016 # The job's own shell expands $! and $0.
  out=$(job_start "$dir" --timeout 1 -- \
    sh -c 'sleep 30 & echo $! > "$0"; wait' "$dir/grandchild.pid") || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  wait_for_record "$dir" || fail "a timed-out command produced no inbox record"
  assert_contains "$(body_of "$(records "$dir")")" "passed its 1-second timeout and was stopped" \
    "the record should report the timeout"
  assert_grep 'outcome=timed-out' "$jobdir/exit" "the exit record should say timed-out"
  grandchild=$(cat "$dir/grandchild.pid")
  wait_gone "$grandchild" || fail "the timeout left a process the command started running"
  pass "task job: a command past its timeout is stopped with its whole process group"
}

test_timeout_stops_a_command_in_its_own_group() {
  local dir out jobdir child owner group
  dir=$(setup_case timeout-own-group)
  # shellcheck disable=SC2016 # Perl creates the process group before exec preserves its identity.
  out=$(job_start "$dir" --timeout 5 -- perl -MPOSIX -e '
    POSIX::setpgid(0, 0) == 0 or die "setpgid: $!";
    $| = 1;
    print "own-group-ready\n";
    exec "sleep", "60" or die "exec: $!";
  ') || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  child=$(sed -n 's/^pid=//p' "$jobdir/child")
  owner=$(sed -n 's/^pid=//p' "$jobdir/runner")
  wait_for_file "$jobdir/output" || fail "the command did not report its new group"
  group=$(ps -o pgid= -p "$child" | tr -d ' ')
  [ "$group" = "$child" ] && [ "$group" != "$owner" ] \
    || fail "the command did not move out of the runner's group"
  if ! wait_for_file "$jobdir/exit"; then
    kill -TERM "$child" 2>/dev/null || true
    wait_gone "$owner" || fail "the runner did not exit after fixture cleanup"
    fail "the command's own group bypassed the job deadline"
  fi
  assert_grep 'outcome=timed-out' "$jobdir/exit" "the escaped command must time out"
  wait_gone "$child" || fail "the deadline left the command's own group running"
  wait_for_record "$dir" || fail "the escaped command produced no timeout completion"
  assert_contains "$(body_of "$(records "$dir")")" "passed its 5-second timeout and was stopped" \
    "the completion should report the requested timeout"
  pass "task job: a command in its own process group still honors its timeout"
}

test_hold_defers_the_ring_until_the_decision_closes() {
  local dir out jobdir rec rings
  dir=$(setup_case held)
  printf 'needs-decision [key=pick]: ship alpha or beta?\n' >> "$dir/state/t1.status"
  out=$(job_start "$dir" --timeout 60 -- true) || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  wait_for_file "$jobdir/exit" || fail "the held job did not finish"
  wait_gone "$(sed -n 's/^pid=//p' "$jobdir/runner")" || fail "the held runner did not finish"
  [ "$(record_count "$dir")" = 0 ] || fail "the runner delivered a held completion"
  wait_for_record "$dir" || fail "a held task's job was not delivered"
  wait_gone "$(sed -n 's/^pid=//p' "$(job_dir_of "$dir" "$out")/runner")" || fail "the runner outlived its delivery"
  [ ! -s "$dir/send.log" ] || fail "a completion rang a worker holding its own decision:"$'\n'"$(cat "$dir/send.log")"
  rec=$(records "$dir")
  age_path "$rec"
  steer_check "$dir"
  steer_check "$dir"
  [ ! -s "$dir/send.log" ] || fail "the ladder rang a held completion:"$'\n'"$(cat "$dir/send.log")"
  [ -f "$rec" ] || fail "the held completion record must stay in the inbox"

  printf 'resolved [key=pick]: alpha\n' >> "$dir/state/t1.status"
  steer_check "$dir"
  steer_check "$dir"
  rings=$(grep -cF "$DOORBELL" "$dir/send.log" || true)
  [ "$rings" = 1 ] || fail "expected one ring once the decision closed, got $rings:"$'\n'"$(cat "$dir/send.log")"
  pass "task job: a hold receives the result unrung, and the ladder rings it once the decision closes"
}

test_captain_hold_defers_completion() {
  local dir out rec
  dir=$(setup_case captain-held)
  out=$(start_waiting_job "$dir") || fail "start failed: $out"
  printf 'needs-decision [key=pick]: ship alpha or beta?\n' >> "$dir/state/t1.status"
  printf 'captain-held [key=pick]: waiting for captain\n' >> "$dir/state/t1.status"
  touch "$dir/release"
  wait_for_record "$dir" || fail "a captain-held task's completion was not recorded"
  wait_gone "$(sed -n 's/^pid=//p' "$(job_dir_of "$dir" "$out")/runner")" || fail "the runner outlived delivery"
  [ ! -s "$dir/send.log" ] || fail "a captain-held completion rang immediately"
  rec=$(records "$dir")
  age_path "$rec"
  steer_check "$dir"
  steer_check "$dir"
  [ ! -s "$dir/send.log" ] || fail "the watcher rang a captain-held completion"
  [ -f "$rec" ] || fail "the captain-held completion disappeared"
  printf 'resolved [key=pick]: alpha\n' >> "$dir/state/t1.status"
  steer_check "$dir"
  assert_grep "$DOORBELL" "$dir/send.log" "the watcher should ring after the captain hold clears"
  pass "task job: captain holds suppress immediate and watcher completion rings"
}

test_backlog_captain_hold_defers_completion() {
  local dir out jobdir rec
  dir=$(setup_case backlog-held)
  tasks-axi add t1 "Run the monitor" --kind ship --repo sample \
    --file "$dir/owning-data/backlog.md" >/dev/null || fail "could not create the backlog work item"
  cat > "$dir/wait.sh" <<'SH'
while [ ! -f "$1" ]; do sleep 0.1; done
SH
  out=$(PATH="$dir/fakebin:$PATH" FM_TASK_INBOX="$dir/state/t1.inbox" FM_SEND_LOG="$dir/send.log" \
    env -u FM_HOME -u FM_DATA_OVERRIDE "$JOB" start --timeout 60 -- sh "$dir/wait.sh" "$dir/release") \
    || fail "start from a cleared launcher environment failed: $out"
  case_command "$dir" "$ROOT/bin/fm-captain-hold.sh" hold t1 \
    --reason "captain approval required" >/dev/null || fail "could not hold the running work item"
  assert_no_grep 'captain-held' "$dir/state/t1.status" "this hold must exist only in the backlog"
  touch "$dir/release"
  jobdir=$(job_dir_of "$dir" "$out")
  wait_for_file "$jobdir/exit" || fail "the backlog-held job did not finish"
  wait_gone "$(sed -n 's/^pid=//p' "$jobdir/runner")" || fail "the backlog-held runner did not finish"
  [ "$(record_count "$dir")" = 0 ] || fail "the runner delivered from the cleared environment"
  wait_for_record "$dir" || fail "the backlog-held completion was not recorded"
  wait_gone "$(sed -n 's/^pid=//p' "$(job_dir_of "$dir" "$out")/runner")" || fail "the runner outlived delivery"
  [ ! -s "$dir/send.log" ] || fail "immediate delivery rang a backlog-held task"
  rec=$(records "$dir")
  age_path "$rec"
  steer_check "$dir"
  steer_check "$dir"
  [ ! -s "$dir/send.log" ] || fail "watcher redelivery rang a backlog-held task"
  [ -f "$rec" ] || fail "the backlog-held completion disappeared"
  printf 'Continue the work.\n' > "$dir/decision.txt"
  case_command "$dir" "$ROOT/bin/fm-captain-hold.sh" answer t1 \
    --decision-file "$dir/decision.txt" --release >/dev/null || fail "could not release the backlog hold"
  steer_check "$dir"
  steer_check "$dir"
  [ "$(grep -cF "$DOORBELL" "$dir/send.log" || true)" = 1 ] || fail "release did not ring the completion exactly once"
  pass "task job: a backlog hold placed during a running job suppresses every ring until release"
}

test_first_job_creates_inbox_for_live_task() {
  local dir out
  dir=$(setup_case first-inbox)
  rm -rf "$dir/state/t1.inbox"
  out=$(job_start "$dir" --timeout 60 -- true) || fail "first job refused valid task metadata: $out"
  wait_for_record "$dir" || fail "the first job did not create its completion inbox"
  wait_gone "$(sed -n 's/^pid=//p' "$(job_dir_of "$dir" "$out")/runner")" || fail "the runner outlived delivery"
  assert_grep "$DOORBELL" "$dir/send.log" "the first job should ring its live task"
  pass "task job: valid live metadata permits first inbox creation"
}

test_runner_waits_for_descendants_after_command_exit() {
  local dir out jobdir runner child descendant
  dir=$(setup_case command-exited)
  cat > "$dir/descendant.sh" <<'SH'
printf '%s\n' "$$" > "$1/descendant.pid"
while [ ! -f "$1/release" ]; do sleep 0.1; done
SH
  cat > "$dir/parent.sh" <<'SH'
sh "$1/descendant.sh" "$1" &
exit 4
SH
  out=$(job_start "$dir" --timeout 60 -- sh "$dir/parent.sh" "$dir") || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  runner=$(sed -n 's/^pid=//p' "$jobdir/runner")
  child=$(sed -n 's/^pid=//p' "$jobdir/child")
  wait_for_file "$dir/descendant.pid" || fail "the descendant did not start"
  descendant=$(cat "$dir/descendant.pid")
  wait_gone "$child" || fail "the command leader did not exit"
  kill -0 "$runner" 2>/dev/null || fail "the runner abandoned its descendant"
  [ ! -e "$jobdir/exit" ] || fail "completion was published before the group emptied"
  [ "$(record_count "$dir")" = 0 ] || fail "a live descendant allowed completion delivery"
  touch "$dir/release"
  wait_for_record "$dir" || fail "the emptied group did not produce a completion"
  wait_gone "$runner" || fail "the runner outlived completion"
  wait_gone "$descendant" || fail "the descendant outlived completion"
  assert_grep 'status=4' "$jobdir/exit" "the completion should preserve the command's exit status"
  pass "task job: the runner owns surviving descendants after the command leader exits"
}

test_teardown_during_timeout_cleanup() {
  local dir out jobdir runner child descendant
  dir=$(setup_case interrupted-stop)
  out=$(FM_TASK_JOB_KILL_GRACE_SECS=03 start_stubborn_job "$dir" 1) || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  runner=$(sed -n 's/^pid=//p' "$jobdir/runner")
  child=$(sed -n 's/^pid=//p' "$jobdir/child")
  wait_for_file "$dir/grandchild.pid" || fail "the TERM-resistant descendant did not start"
  descendant=$(cat "$dir/grandchild.pid")
  wait_gone "$child" || fail "timeout TERM did not stop the command leader"
  kill -0 "$descendant" 2>/dev/null || fail "the descendant did not survive TERM"
  kill -0 "$runner" 2>/dev/null || fail "the runner exited during cleanup"
  FM_TASK_JOB_KILL_GRACE_SECS=03 case_command "$dir" "$JOB" stop-all "$dir/state" t1 \
    || fail "teardown could not complete interrupted timeout cleanup"
  wait_gone "$runner" || fail "teardown left the runner alive"
  wait_gone "$descendant" || fail "teardown left a TERM-resistant descendant alive"
  [ ! -e "$jobdir/exit" ] || fail "teardown published a completion during cleanup"
  [ "$(record_count "$dir")" = 0 ] || fail "teardown delivered a completion during cleanup"
  pass "task job: teardown retains runner ownership through timeout cleanup"
}

test_recovery_after_runner_dies_during_cleanup() {
  local dir out jobdir runner child descendant
  dir=$(setup_case interrupted-recovery)
  out=$(FM_TASK_JOB_KILL_GRACE_SECS=08 start_stubborn_job "$dir" 1) || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  runner=$(sed -n 's/^pid=//p' "$jobdir/runner")
  child=$(sed -n 's/^pid=//p' "$jobdir/child")
  wait_for_file "$dir/grandchild.pid" || fail "the TERM-resistant descendant did not start"
  descendant=$(cat "$dir/grandchild.pid")
  wait_gone "$child" || fail "timeout TERM did not stop the command leader"
  kill -0 "$descendant" 2>/dev/null || fail "the descendant did not survive TERM"
  kill -0 "$runner" 2>/dev/null || fail "the leading-zero grace failed before recovery"
  kill -KILL "$runner"
  wait_gone "$runner" || fail "the runner did not stop"
  job_lib "$dir" fm_task_job_reconcile "$dir/state" t1 > "$dir/recovery.out" 2>&1 || fail "recovery failed"
  kill -0 "$descendant" 2>/dev/null || fail "recovery signaled a group without its runner"
  assert_grep "unrecoverable job ${jobdir##*/}" "$dir/recovery.out" "runner loss must be reported"
  [ ! -e "$jobdir/exit" ] || fail "unproven cleanup published a terminal result"
  [ "$(record_count "$dir")" = 0 ] || fail "unproven cleanup delivered a completion"
  kill -KILL "$descendant"
  wait_gone "$descendant" || fail "fixture cleanup left its descendant alive"
  pass "task job: interrupted cleanup preserves unproven groups and reports the job as unrecoverable"
}

test_runner_identity_is_independent_of_timezone() {
  local dir out jobdir runner child utc local_time
  dir=$(setup_case timezone)
  out=$(TZ=UTC start_waiting_job "$dir") || fail "UTC launch failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  runner=$(sed -n 's/^pid=//p' "$jobdir/runner")
  child=$(sed -n 's/^pid=//p' "$jobdir/child")
  utc=$(LC_ALL=C TZ=UTC ps -p "$runner" -o lstart=)
  local_time=$(LC_ALL=C TZ=EST5 ps -p "$runner" -o lstart=)
  [ "$utc" != "$local_time" ] || fail "the fixture did not expose different timezone renderings"
  TZ=EST5 FM_TASK_JOB_KILL_GRACE_SECS=0 case_command "$dir" "$JOB" stop-all "$dir/state" t1 \
    || fail "the non-UTC supervisor rejected its UTC-launched runner"
  wait_gone "$runner" || fail "timezone-independent cleanup left the runner"
  wait_gone "$child" || fail "timezone-independent cleanup left the command"
  [ ! -e "$jobdir/exit" ] || fail "stopping the owned runner published a completion"
  pass "task job: a non-UTC supervisor stops its UTC-launched runner using the shared identity"
}

test_decimal_timeouts_and_graces() {
  local value dir out jobdir started deadline
  for value in 010 00008 00009; do
    dir=$(setup_case "decimal-$value")
    out=$(job_start "$dir" --timeout "$value" -- sleep 60) || fail "decimal timeout $value refused: $out"
    jobdir=$(job_dir_of "$dir" "$out")
    started=$(sed -n 's/^started=//p' "$jobdir/job")
    deadline=$(sed -n 's/^deadline=//p' "$jobdir/job")
    [ "$((deadline - started))" -eq "$value" ] || fail "timeout $value did not keep its decimal duration"
    FM_TASK_JOB_KILL_GRACE_SECS=0000 case_command "$dir" "$JOB" stop-all "$dir/state" t1 \
      || fail "a zero-padded grace broke cleanup"
  done
  [ "$(job_lib "$dir" fm_task_job_secs 08 5)" = 8 ] || fail "kill grace 08 was not normalized"
  [ "$(job_lib "$dir" fm_task_job_secs 010 5)" = 10 ] || fail "kill grace 010 was not normalized"
  pass "task job: leading-zero timeout and grace inputs retain decimal meaning"
}

test_watcher_delivers_a_finished_job_once() {
  local dir out jobdir rec
  dir=$(setup_case watcher-owned)
  out=$(start_waiting_job "$dir") || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  touch "$dir/release"
  wait_for_file "$jobdir/exit" || fail "the runner did not record completion"
  wait_gone "$(sed -n 's/^pid=//p' "$jobdir/runner")" || fail "the runner did not finish"
  [ "$(record_count "$dir")" = 0 ] || fail "the runner wrote the inbox"
  [ ! -s "$dir/send.log" ] || fail "the runner rang the worker"
  steer_check "$dir"
  rec=$(records "$dir")
  [ "$(record_count "$dir")" = 1 ] || fail "the watcher did not deliver once"
  [ "$(grep -cF "$DOORBELL" "$dir/send.log" || true)" = 1 ] || fail "the delivering poll did not ring once"
  steer_check "$dir"
  [ "$(grep -cF "$DOORBELL" "$dir/send.log" || true)" = 1 ] || fail "the next poll bypassed retry spacing"
  mv "$rec" "$dir/state/t1.inbox/handled/"
  rm -f "$jobdir/delivered"
  : > "$dir/send.log"
  steer_check "$dir"
  [ "$(record_count "$dir")" = 0 ] || fail "the watcher duplicated an acknowledged completion"
  [ ! -s "$dir/send.log" ] || fail "an acknowledged completion rang again"
  pass "task job: only the watcher delivers and rings a finished job"
}

test_completion_bypasses_older_steer() {
  local mode dir older out jobdir rec
  for mode in grace escalated held; do
    dir=$(setup_case "older-$mode")
    older=$(job_lib "$dir" fm_task_inbox_write "$dir/state" t1 "Older instruction") || fail "could not seed older steer"
    if [ "$mode" != grace ]; then
      age_path "$older"
      job_lib "$dir" fm_task_inbox_record_ring "$dir/state" t1 "$older" || fail "could not seed ladder"
      job_lib "$dir" fm_task_inbox_record_escalated "$dir/state" t1 "$older" || fail "could not escalate older steer"
    fi
    if [ "$mode" = held ]; then
      printf 'needs-decision [key=pick]: choose a result\n' >> "$dir/state/t1.status"
    fi
    out=$(job_start "$dir" --timeout 60 -- true) || fail "start failed: $out"
    jobdir=$(job_dir_of "$dir" "$out")
    wait_for_file "$jobdir/exit" || fail "completion did not finish"
    wait_gone "$(sed -n 's/^pid=//p' "$jobdir/runner")" || fail "runner did not exit"
    steer_check "$dir"
    [ "$(record_count "$dir")" = 2 ] || fail "$mode: completion was not recorded beside older steer"
    if [ "$mode" = held ]; then
      steer_check "$dir"
      [ ! -s "$dir/send.log" ] || fail "an older steer caused a held completion to ring"
      printf 'resolved [key=pick]: continue\n' >> "$dir/state/t1.status"
      steer_check "$dir"
    fi
    [ "$(grep -cF "$DOORBELL" "$dir/send.log" || true)" = 1 ] || fail "$mode: older steer suppressed the first completion ring"
    steer_check "$dir"
    [ "$(grep -cF "$DOORBELL" "$dir/send.log" || true)" = 1 ] || fail "$mode: first ring repeated on the next poll"
    out=$(job_start "$dir" --timeout 60 -- true) || fail "second start failed: $out"
    jobdir=$(job_dir_of "$dir" "$out")
    wait_for_file "$jobdir/exit" || fail "second completion did not finish"
    wait_gone "$(sed -n 's/^pid=//p' "$jobdir/runner")" || fail "second runner did not exit"
    steer_check "$dir"
    [ "$(grep -cF "$DOORBELL" "$dir/send.log" || true)" = 2 ] || fail "$mode: second completion did not ring independently"
    steer_check "$dir"
    [ "$(grep -cF "$DOORBELL" "$dir/send.log" || true)" = 2 ] || fail "$mode: completion attempt history was overwritten"
    while IFS= read -r rec; do
      [ "$rec" = "$older" ] || mv "$rec" "$dir/state/t1.inbox/handled/"
    done < <(records "$dir")
    steer_check "$dir"
    [ "$(grep -cF "$DOORBELL" "$dir/send.log" || true)" = 2 ] || fail "$mode: an acknowledged completion rang again"
  done
  pass "task job: new and released completions ring independently of older steers"
}

test_finished_live_runner_is_owned_until_stopped() {
  local dir out jobdir runner child
  dir=$(setup_case exit-before-delivery)
  out=$(start_waiting_job "$dir") || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  runner=$(sed -n 's/^pid=//p' "$jobdir/runner")
  child=$(sed -n 's/^pid=//p' "$jobdir/child")
  job_lib "$dir" fm_task_job_publish_exit "$jobdir" exited 0 || fail "could not publish exit"
  job_lib "$dir" fm_task_job_reconcile "$dir/state" t1 || fail "reconcile failed"
  [ "$(record_count "$dir")" = 0 ] || fail "reconcile delivered while the runner was alive"
  FM_TASK_JOB_KILL_GRACE_SECS=1 case_command "$dir" "$JOB" stop-all "$dir/state" t1 || fail "stop-all failed"
  wait_gone "$runner" || fail "stop-all left a runner with an exit record running"
  wait_gone "$child" || fail "stop-all left the command running"
  [ "$(record_count "$dir")" = 0 ] || fail "stop-all delivered the completion"
  rm -rf "$dir/state/t1.inbox"
  [ ! -e "$dir/state/t1.inbox" ] || fail "the stopped runner recreated its inbox"
  pass "task job: reconcile defers to a live runner and teardown stops it after exit publication"
}

test_failed_completion_has_its_own_retry_and_escalation() {
  local dir older out jobdir rec failures
  dir=$(setup_case independent-retries)
  older=$(job_lib "$dir" fm_task_inbox_write "$dir/state" t1 "Older instruction") || fail "could not seed steer"
  age_path "$older"
  job_lib "$dir" fm_task_inbox_record_escalated "$dir/state" t1 "$older" || fail "could not escalate steer"
  out=$(job_start "$dir" --timeout 60 -- true) || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  wait_for_file "$jobdir/exit" || fail "completion did not finish"
  wait_gone "$(sed -n 's/^pid=//p' "$jobdir/runner")" || fail "runner did not exit"
  FM_FAKE_TMUX_SEND_FAIL=1 FM_TASK_INBOX_RING_MAX=2 steer_check "$dir"
  rec="$dir/state/t1.inbox/$(sed -n 's/^record=//p' "$jobdir/delivered")"
  [ -f "$rec" ] || fail "completion was not recorded"
  assert_grep 'count=1' "$jobdir/delivery" "the failed first ring must count for this job"
  failures=$(grep -cF 'send failed' "$dir/send.log" || true)
  [ "$failures" -gt 0 ] || fail "the first ring did not attempt delivery"
  FM_FAKE_TMUX_SEND_FAIL=1 FM_TASK_INBOX_RING_MAX=2 steer_check "$dir"
  assert_grep 'count=1' "$jobdir/delivery" "an immediate poll must preserve retry spacing"
  [ "$(grep -cF 'send failed' "$dir/send.log" || true)" = "$failures" ] || fail "an immediate poll attempted another send"
  sleep 1.1
  FM_FAKE_TMUX_SEND_FAIL=1 FM_TASK_INBOX_RING_MAX=2 steer_check "$dir" 1
  assert_grep 'count=2' "$jobdir/delivery" "an older escalated steer must not suppress a failed retry"
  [ "$(grep -cF 'send failed' "$dir/send.log" || true)" -gt "$failures" ] || fail "the completion retry did not attempt delivery"
  [ ! -e "$jobdir/escalated" ] || fail "completion escalated during its retry"
  FM_TASK_INBOX_RING_MAX=2 steer_check "$dir"
  [ ! -e "$jobdir/escalated" ] || fail "escalation bypassed spacing"
  sleep 1.1
  FM_TASK_INBOX_RING_MAX=2 steer_check "$dir" 1
  assert_grep "$rec" "$dir/state/.wake-queue" "completion must have its own stale wake"
  assert_grep 'after 2 doorbell delivery attempts' "$dir/state/.wake-queue" "completion must exhaust its own budget"
  FM_TASK_INBOX_RING_MAX=2 steer_check "$dir" 1
  [ "$(grep -cF "$rec" "$dir/state/.wake-queue")" = 1 ] || fail "completion escalation repeated"
  [ "$(cat "$dir/state/t1.inbox/.escalated")" = "${older##*/}" ] || fail "completion overwrote the steer escalation"
  mv "$rec" "$dir/state/t1.inbox/handled/"
  : > "$dir/send.log"
  steer_check "$dir" 0
  [ ! -s "$dir/send.log" ] || fail "acknowledged completion rang again"
  pass "task job: failed rings retry and escalate independently of an older escalated steer"
}

test_completion_never_delays_a_steer() {
  local dir out jobdir rec steer action
  dir=$(setup_case steer-after-completion)
  printf 'needs-decision [key=pick]: choose a result\n' >> "$dir/state/t1.status"
  out=$(job_start "$dir" --timeout 60 -- true) || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  wait_for_record "$dir" || fail "held completion was not recorded"
  rec=$(records "$dir")
  steer=$(job_lib "$dir" fm_task_inbox_write "$dir/state" t1 "New instruction") || fail "could not seed steer"
  age_path "$steer"
  steer_check "$dir"
  [ "$(grep -cF "$DOORBELL" "$dir/send.log" || true)" = 1 ] || fail "held completion delayed a newer steer"
  [ ! -e "$jobdir/delivery" ] || fail "held completion consumed a delivery attempt"
  mv "$steer" "$dir/state/t1.inbox/handled/"
  action=$(job_lib "$dir" fm_task_inbox_due_action "$dir/state" t1)
  [ "$action" = quiet ] || fail "the steer ladder selected a completion: $action"
  printf 'resolved [key=pick]: continue\n' >> "$dir/state/t1.status"
  FM_TASK_INBOX_RING_MAX=1 steer_check "$dir"
  sleep 1.1
  steer=$(job_lib "$dir" fm_task_inbox_write "$dir/state" t1 "Another instruction") || fail "could not seed next steer"
  age_path "$steer"
  FM_TASK_INBOX_RING_MAX=1 steer_check "$dir" 1
  [ "$(grep -cF "$DOORBELL" "$dir/send.log" || true)" = 3 ] || fail "completion escalation delayed a steer"
  assert_grep "$rec" "$dir/state/.wake-queue" "the completion must escalate independently"
  pass "task job: held and escalating completions never block a newer steer"
}

test_cleanup_preserves_reused_runner_groups() {
  local scenario outcome mode dir other out jobdir otherjob runner descendant child rc
  for scenario in finished-live finished-gone lost-live lost-gone; do
    outcome=${scenario%-*}
    mode=${scenario#*-}
    dir=$(setup_case "reused-$outcome-$mode")
    out=$(job_start "$dir" --timeout 60 -- true) || fail "start failed: $out"
    jobdir=$(job_dir_of "$dir" "$out")
    wait_for_file "$jobdir/exit" || fail "old job did not finish"
    wait_gone "$(sed -n 's/^pid=//p' "$jobdir/runner")" || fail "old runner did not exit"
    if [ "$outcome" = lost ]; then rm -f "$jobdir/exit"; fi
    other=$(setup_case "new-owner-$outcome-$mode")
    out=$(start_stubborn_job "$other" 120) || fail "new job failed: $out"
    otherjob=$(job_dir_of "$other" "$out")
    runner=$(sed -n 's/^pid=//p' "$otherjob/runner")
    child=$(sed -n 's/^pid=//p' "$otherjob/child")
    wait_for_file "$other/grandchild.pid" || fail "new descendant did not start"
    descendant=$(cat "$other/grandchild.pid")
    job_lib "$dir" fm_task_job_write_record "$jobdir/runner" "pid=$runner" "start=retired runner identity" \
      || fail "could not model historical pid reuse in the runner record"
    if [ "$mode" = gone ]; then
      kill -KILL "$runner"
      wait_gone "$runner" || fail "new runner did not stop"
    fi
    rc=0
    FM_TASK_JOB_KILL_GRACE_SECS=0 case_command "$dir" "$JOB" stop-all "$dir/state" t1 \
      > "$dir/stop.out" 2>&1 || rc=$?
    if [ "$outcome" = finished ]; then
      expect_code 0 "$rc" "finished job cleanup"
    else
      expect_code 1 "$rc" "lost job cleanup with reused group"
      assert_grep "unrecoverable job ${jobdir##*/}" "$dir/stop.out" "cleanup must name the unproven job"
      job_lib "$dir" fm_task_job_reconcile "$dir/state" t1 > "$dir/recovery.out" 2>&1 || fail "recovery failed"
      job_lib "$dir" fm_task_job_reconcile "$dir/state" t1 >> "$dir/recovery.out" 2>&1 || fail "later recovery failed"
      assert_grep "unrecoverable job ${jobdir##*/}" "$dir/recovery.out" "recovery must report the reused group"
      [ "$(grep -cF "unrecoverable job ${jobdir##*/}" "$dir/state/t1.status")" = 1 ] || fail "recovery repeated its durable report"
      [ ! -e "$jobdir/exit" ] || fail "recovery invented a terminal result"
      [ "$(record_count "$dir")" = 0 ] || fail "recovery delivered an unproven completion"
    fi
    kill -0 "$descendant" 2>/dev/null || fail "historical job cleanup killed another job's descendant"
    if [ "$mode" = live ]; then
      kill -0 "$runner" 2>/dev/null || fail "finished job cleanup killed another runner"
    fi
    if [ "$mode" = live ]; then
      FM_TASK_JOB_KILL_GRACE_SECS=0 case_command "$other" "$JOB" stop-all "$other/state" t1 \
        || fail "new owner's cleanup failed"
    else
      kill -KILL "$child" "$descendant" 2>/dev/null || true
    fi
    wait_gone "$descendant" || fail "new owner's cleanup left a descendant"
  done
  pass "task job: finished and lost records never signal reused runner pids or surviving groups"
}

test_secondmate_teardown_stops_child_job_without_delivery() {
  local dir home child_wt out jobdir runner child tool world
  dir=$(setup_case secondmate-retirement)
  world="$TMP_ROOT/secondmate-world"
  home="$world/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/job-scratch"
  printf 't1\n' > "$home/.fm-secondmate-home"
  git init -q -b main "$world/project"
  git -C "$world/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$world/project" worktree add -q -b fm/t1 "$world/mate-wt" main
  child_wt="$world/child-wt"
  git -C "$world/project" worktree add -q -b fm/child "$child_wt" main
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=secondmate" "mode=local-only" \
    "spawn_gen=mate-gen" "home=$home" "worktree=$world/mate-wt" "project=$world/project"
  fm_write_meta "$home/state/child.meta" "window=sess:fm-child" "endpoint_task_id=child" \
    "kind=scout" "mode=local-only" "spawn_gen=child-gen" "worktree=$child_wt" "project=$world/project"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  for tool in treehouse no-mistakes gh-axi gh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/$tool"
    chmod +x "$dir/fakebin/$tool"
  done
  out=$(cd "$dir/job-scratch" && PATH="$dir/fakebin:$PATH" FM_HOME="$home" \
    FM_TASK_INBOX="$home/state/child.inbox" "$JOB" start --timeout 120 -- sleep 60) \
    || fail "child start failed: $out"
  jobdir="$home/state/child.inbox/jobs/$(printf '%s\n' "$out" | sed -n 's/^job: //p')"
  runner=$(sed -n 's/^pid=//p' "$jobdir/runner")
  child=$(sed -n 's/^pid=//p' "$jobdir/child")
  FM_TASK_JOB_KILL_GRACE_SECS=0 FM_SEND_LOG="$dir/send.log" FM_ROOT_OVERRIDE="$ROOT" \
    case_command "$dir" "$ROOT/bin/fm-teardown.sh" t1 --force > "$dir/teardown.out" 2>&1 \
    || fail "secondmate teardown failed: $(cat "$dir/teardown.out")"
  wait_gone "$runner" || fail "secondmate teardown left the child runner"
  wait_gone "$child" || fail "secondmate teardown left the child command"
  [ ! -e "$home" ] || fail "secondmate home survived retirement"
  job_lib "$dir" fm_task_job_reconcile "$home/state" child || fail "retired recovery failed"
  [ ! -e "$home/state/child.inbox" ] || fail "retired child inbox was recreated"
  [ ! -s "$dir/send.log" ] || fail "retiring the secondmate delivered a completion"
  pass "task job: recursive secondmate teardown stops child jobs without ringing or recreating an inbox"
}

test_watcher_rerings_until_acknowledged() {
  local dir out rec
  dir=$(setup_case rering)
  out=$(job_start "$dir" --timeout 60 -- true) || fail "start failed: $out"
  FM_FAKE_TMUX_SEND_FAIL=1 wait_for_record "$dir" 1 || fail "the job was not delivered"
  wait_gone "$(sed -n 's/^pid=//p' "$(job_dir_of "$dir" "$out")/runner")" || fail "the runner outlived its delivery"
  assert_no_grep "$DOORBELL" "$dir/send.log" "the failed first ring should not have landed"
  rec=$(records "$dir")
  age_path "$rec"
  sleep 1.1
  steer_check "$dir" 1
  assert_grep "$DOORBELL" "$dir/send.log" "the watcher should re-ring an unacknowledged completion"

  mv "$rec" "$dir/state/t1.inbox/handled/"
  : > "$dir/send.log"
  steer_check "$dir"
  [ ! -s "$dir/send.log" ] || fail "the watcher rang after the acknowledgement:"$'\n'"$(cat "$dir/send.log")"
  pass "task job: an unlanded doorbell is re-rung until the worker acknowledges the record"
}

watch_bg() {  # <dir> <out>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_DATA_OVERRIDE="$1/owning-data" FM_CONFIG_OVERRIDE="$1/config" \
    FM_STATE_OVERRIDE="$1/state" FM_SEND_LOG="$1/send.log" \
    FM_CREW_STATE_BIN="$1/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_JOB_KILL_GRACE_SECS=1 \
    "$WATCH" > "$2" 2>&1 &
}

test_watcher_survives_retired_completion_bookkeeping() {
  local scenario boundary scope dir out jobdir other wpid i rc rec retire send_retire write_retire fault busy send_fail
  for scenario in delivery-job delivery-inbox delivery-failed busy-job escalated-job delivery-surviving busy-surviving escalated-surviving; do
    boundary=${scenario%%-*}
    scope=${scenario#*-}
    dir=$(setup_case "bookkeeping-$scenario")
    printf 'working: monitoring a command\n' > "$dir/state/t1.status"
    fm_write_meta "$dir/state/t2.meta" "window=sess:fm-t2" "kind=ship" "harness=grok" "spawn_gen=gen-B"
    printf 'working: monitoring another command\n' > "$dir/state/t2.status"
    prime_status_seen "$dir/state" "$dir/state/t1.status"
    prime_status_seen "$dir/state" "$dir/state/t2.status"
    out=$(job_start "$dir" --timeout 60 -- true) || fail "first start failed: $out"
    jobdir=$(job_dir_of "$dir" "$out")
    out=$(FM_TASK_INBOX="$dir/state/t2.inbox" case_command "$dir" "$JOB" start --timeout 60 -- true) \
      || fail "second start failed: $out"
    other="$dir/state/t2.inbox/jobs/$(printf '%s\n' "$out" | sed -n 's/^job: //p')"
    wait_for_file "$jobdir/exit" || fail "first job did not finish"
    wait_for_file "$other/exit" || fail "second job did not finish"
    wait_gone "$(sed -n 's/^pid=//p' "$jobdir/runner")" || fail "first runner did not finish"
    wait_gone "$(sed -n 's/^pid=//p' "$other/runner")" || fail "second runner did not finish"
    job_lib "$dir" fm_task_job_deliver "$dir/state" t1 "$jobdir" || fail "could not prepare first completion"
    if [ "$boundary" = escalated ]; then
      job_lib "$dir" fm_task_job_write_record "$jobdir/delivery" count=999 last=1 || fail "could not prepare escalation"
    fi
    retire=$jobdir
    [ "$scope" != inbox ] || retire="$dir/state/t1.inbox"
    [ "$scope" != surviving ] || retire=
    send_retire='' write_retire='' fault='' busy=0 send_fail=0
    if [ "$boundary" = delivery ] && [ "$scope" != surviving ]; then
      send_retire=$retire
      [ "$scope" != failed ] || send_fail=1
    else
      write_retire=$retire
      fault="$jobdir/$boundary"
    fi
    if [ "$scenario" = escalated-job ]; then
      write_retire='' fault=''
      cat > "$dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = show ]; then
  rm -rf -- "$FM_JOB_RETIRE_BEFORE_ESCALATION"
fi
exec "$FM_REAL_TASKS_AXI" "$@"
SH
      chmod +x "$dir/fakebin/tasks-axi"
    fi
    [ "$boundary" != busy ] || busy=1
    cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
if [ "${!#}" = "${FM_JOB_RECORD_FAULT:-}" ]; then
  [ -z "${FM_JOB_RETIRE_AT_WRITE:-}" ] || rm -rf -- "$FM_JOB_RETIRE_AT_WRITE"
  exit 1
fi
exec "$FM_REAL_MV" "$@"
SH
    chmod +x "$dir/fakebin/mv"
    FM_FAKE_TMUX_WINDOWS=$'fm-t1\nfm-t2' FM_JOB_RETIRE_ON_SEND="$send_retire" \
      FM_JOB_RETIRE_SEND_FAIL="$send_fail" FM_JOB_RECORD_FAULT="$fault" FM_JOB_RETIRE_AT_WRITE="$write_retire" \
      FM_JOB_BUSY_TARGET="$busy" FM_BUSY_REGEX=BUSYTOKEN FM_REAL_MV="$(command -v mv)" \
      FM_JOB_RETIRE_BEFORE_ESCALATION="$jobdir" FM_REAL_TASKS_AXI="$(command -v tasks-axi)" \
      watch_bg "$dir" "$dir/watch.out"
    wpid=$!
    if [ "$scope" = surviving ]; then
      wait_gone "$wpid" || { kill "$wpid" 2>/dev/null; fail "$scenario swallowed a surviving job's write failure"; }
      rc=0
      wait "$wpid" || rc=$?
      [ "$rc" -ne 0 ] || fail "$scenario reported a successful watcher exit"
      [ -d "$jobdir" ] || fail "$scenario removed the surviving job"
      [ -s "$dir/watch.out" ] || fail "$scenario suppressed a surviving job's bookkeeping error"
      continue
    fi
    i=0
    while [ "$i" -lt 200 ] && ! grep -qF "'t2.inbox'" "$dir/send.log"; do
      kill -0 "$wpid" 2>/dev/null || break
      sleep 0.1
      i=$((i + 1))
    done
    if ! grep -qF "'t2.inbox'" "$dir/send.log"; then
      kill "$wpid" 2>/dev/null || true
      fail "$scenario stopped supervision before the second task rang: $(cat "$dir/watch.out")"
    fi
    rec="$dir/state/t2.inbox/$(sed -n 's/^record=//p' "$other/delivered")"
    mv "$rec" "$dir/state/t2.inbox/handled/"
    sleep 2.5
    kill -0 "$wpid" 2>/dev/null || fail "$scenario exited after concurrent retirement: $(cat "$dir/watch.out")"
    kill "$wpid" 2>/dev/null || true
    wait "$wpid" 2>/dev/null || true
    [ ! -e "$retire" ] || fail "$scenario recreated retired job state"
    [ ! -s "$dir/watch.out" ] || fail "$scenario was not a quiet no-op: $(cat "$dir/watch.out")"
  done
  pass "watcher: retired completion bookkeeping preserves supervision while surviving write failures remain errors"
}

test_watcher_reports_a_lost_runner_as_unrecoverable() {
  local dir out jobdir runner child descendant wpid i
  dir=$(setup_case lost)
  prime_status_seen "$dir/state" "$dir/state/t1.status"
  out=$(start_stubborn_job "$dir" 120) || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  runner=$(sed -n 's/^pid=//p' "$jobdir/runner")
  child=$(sed -n 's/^pid=//p' "$jobdir/child")
  wait_for_file "$dir/grandchild.pid" || fail "the TERM-ignoring descendant did not start"
  descendant=$(cat "$dir/grandchild.pid")
  kill -TERM "$child"
  wait_gone "$child" || fail "the command leader did not exit"
  kill -0 "$descendant" 2>/dev/null || fail "the descendant did not survive TERM"
  kill -KILL "$runner"
  wait_gone "$runner" || fail "could not stop the runner under test"
  watch_bg "$dir" "$dir/watch.out"
  wpid=$!
  i=0
  while [ "$i" -lt 200 ] && ! grep -qF "unrecoverable job ${jobdir##*/}" "$dir/state/t1.status"; do
    sleep 0.1
    i=$((i + 1))
  done
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  assert_grep "unrecoverable job ${jobdir##*/}" "$dir/state/t1.status" "the watcher must name the lost job"
  assert_grep "unrecoverable job ${jobdir##*/}" "$dir/watch.out" "the watcher must report its refusal loudly"
  kill -0 "$descendant" 2>/dev/null || fail "the watcher signaled an unproven process group"
  [ ! -e "$jobdir/exit" ] || fail "the watcher invented an exit result"
  [ "$(record_count "$dir")" = 0 ] || fail "the watcher delivered an unproven completion"
  [ ! -s "$dir/send.log" ] || fail "the watcher rang an unproven completion"
  kill -KILL "$descendant"
  wait_gone "$descendant" || fail "fixture cleanup left its descendant alive"
  pass "watcher: runner loss preserves unproven groups and names the unrecoverable job"
}

test_stop_all_stops_without_delivering() {
  local dir out jobdir runner child
  dir=$(setup_case stop)
  out=$(job_start "$dir" --timeout 120 -- sleep 60) || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  runner=$(sed -n 's/^pid=//p' "$jobdir/runner")
  child=$(sed -n 's/^pid=//p' "$jobdir/child")
  FM_TASK_JOB_KILL_GRACE_SECS=1 case_command "$dir" "$JOB" stop-all "$dir/state" t1 || fail "stop-all failed"
  wait_gone "$runner" || fail "stop-all left the runner running"
  wait_gone "$child" || fail "stop-all left the command running"
  [ ! -e "$jobdir/exit" ] || fail "a stopped job must not publish an exit"
  [ "$(record_count "$dir")" = 0 ] || fail "a stopped job must not be delivered"
  pass "task job: teardown's stop-all stops live jobs without delivering them"
}

test_removed_inbox_is_never_recreated() {
  local dir out runner
  dir=$(setup_case retired)
  out=$(job_start "$dir" --timeout 60 -- sleep 1) || fail "start failed: $out"
  runner=$(sed -n 's/^pid=//p' "$(job_dir_of "$dir" "$out")/runner")
  rm -rf "$dir/state/t1.inbox"
  wait_gone "$runner" || fail "the runner did not finish"
  [ ! -e "$dir/state/t1.inbox" ] || fail "a retired task's job recreated its inbox"
  [ ! -s "$dir/send.log" ] || fail "a retired task's job rang its old endpoint"
  pass "task job: a job whose task inbox is gone delivers nothing and recreates nothing"
}

test_delivery_serializes_with_retirement() {
  local dir out jobdir runner delivery retirement rc=0
  dir=$(setup_case retiring-race)
  out=$(job_start "$dir" --timeout 60 -- true) || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  runner=$(sed -n 's/^pid=//p' "$jobdir/runner")
  wait_for_file "$jobdir/exit" || fail "the command did not finish"
  wait_gone "$runner" || fail "the runner did not exit"
  cat > "$dir/deliver.sh" <<'SH'
. "$1/bin/fm-task-job-lib.sh"
fm_task_job_message() {
  printf ready > "$FM_HOME/message-ready"
  while [ ! -e "$FM_HOME/deliver-release" ]; do sleep 0.1; done
  printf completion
}
fm_task_job_deliver "$FM_HOME/state" t1 "$2"
SH
  cat > "$dir/retire.sh" <<'SH'
. "$1/bin/fm-wake-lib.sh"
lock=$(fm_meta_lock_path "$FM_HOME/state/t1.meta") || exit 1
printf ready > "$FM_HOME/retire-started"
fm_lock_acquire_wait "$lock" || exit 1
trap 'fm_lock_release "$lock"' EXIT
rm -rf "$FM_HOME/state/t1.inbox"
rm -f "$FM_HOME/state/t1.meta"
printf retired > "$FM_HOME/retired"
SH
  case_command "$dir" bash "$dir/deliver.sh" "$ROOT" "$jobdir" > "$dir/deliver.out" 2> "$dir/deliver.err" &
  delivery=$!
  wait_for_file "$dir/message-ready" || fail "delivery did not reach its enqueue boundary"
  [ -e "$dir/state/.meta-t1.lock" ] || fail "delivery reached enqueue without holding the task lock"
  case_command "$dir" bash "$dir/retire.sh" "$ROOT" > "$dir/retire.out" 2> "$dir/retire.err" &
  retirement=$!
  wait_for_file "$dir/retire-started" || fail "retirement did not start"
  [ ! -e "$dir/retired" ] || fail "retirement bypassed an in-flight enqueue"
  touch "$dir/deliver-release"
  wait "$delivery" || fail "delivery failed while its task was live"
  wait "$retirement" || fail "retirement failed after enqueue finished"
  job_lib "$dir" fm_task_job_deliver "$dir/state" t1 "$jobdir" || rc=$?
  [ "$rc" -ne 0 ] || fail "a retired task accepted a stale completion"
  [ ! -e "$dir/state/t1.inbox" ] || fail "delivery recreated a retired inbox"
  [ ! -s "$dir/send.log" ] || fail "delivery rang a retired endpoint"
  pass "task job: enqueue and retirement serialize and stale redelivery cannot recreate the inbox"
}

test_startup_failure_preserves_recovery_records() {
  local dir out rc=0 jobdir='' candidate child
  dir=$(setup_case startup-failure)
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  */child)
    i=0
    while [ ! -s "$FM_HOME/launched.pid" ] && [ "$i" -lt 200 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    [ -s "$FM_HOME/launched.pid" ] || exit 1
    kill -KILL "$PPID"
    exit 1 ;;
esac
exec "$FM_REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  # Perl must receive its own PID and variables without shell expansion.
  # shellcheck disable=SC2016
  out=$(FM_REAL_MV="$(command -v mv)" job_start "$dir" --timeout 60 -- \
    perl -e 'open(my $f, ">", $ARGV[0]) or die $!; print $f "$$\n"; close($f); sleep 60' \
    "$dir/launched.pid" 2>&1) || rc=$?
  expect_code 1 "$rc" "start with a runner killed before child publication"
  wait_for_file "$dir/launched.pid" || fail "the command did not launch before startup failed"
  child=$(cat "$dir/launched.pid")
  kill -0 "$child" 2>/dev/null || fail "the startup failure did not leave the command running"
  for candidate in "$dir/state/t1.inbox/jobs/"*; do
    [ ! -d "$candidate" ] || jobdir=$candidate
  done
  [ -n "$jobdir" ] || fail "startup failure erased the running command's recovery records"
  [ -s "$jobdir/job" ] && [ -s "$jobdir/argv" ] && [ -s "$jobdir/runner" ] \
    || fail "startup failure did not preserve the job, command and runner records"
  [ ! -e "$jobdir/child" ] && [ ! -e "$jobdir/exit" ] \
    || fail "the runner did not fail in the intended startup window"
  assert_contains "$out" "$jobdir" "startup refusal should identify the retained recovery records"
  assert_not_contains "$out" "nothing is running" "startup refusal must not claim the command stopped"
  FM_REAL_MV="$(command -v mv)" steer_check "$dir" || fail "startup-failure recovery failed"
  kill -0 "$child" 2>/dev/null || fail "recovery signaled a command without its runner"
  assert_grep "unrecoverable job ${jobdir##*/}" "$dir/state/t1.status" "recovery must report the retained unproven job"
  FM_REAL_MV="$(command -v mv)" steer_check "$dir" || fail "later startup-failure recovery failed"
  [ ! -e "$jobdir/exit" ] || fail "recovery invented a terminal result"
  [ "$(record_count "$dir")" = 0 ] || fail "recovery delivered an unproven completion"
  [ ! -s "$dir/send.log" ] || fail "recovery rang an unproven completion"
  [ "$(grep -cF "unrecoverable job ${jobdir##*/}" "$dir/state/t1.status")" = 1 ] || fail "recovery repeated its durable report"
  kill -KILL "$child"
  wait_gone "$child" || fail "fixture cleanup left the launched command alive"
  pass "task job: startup failure retains recovery records and reports unproven ownership without signaling"
}

test_hold_lookup_error_is_reported_once() {
  local dir out jobdir other
  dir=$(setup_case hold-lookup-error)
  out=$(job_start "$dir" --timeout 60 -- true) || fail "start failed: $out"
  jobdir=$(job_dir_of "$dir" "$out")
  out=$(job_start "$dir" --timeout 60 -- true) || fail "second start failed: $out"
  other=$(job_dir_of "$dir" "$out")
  if ! wait_for_file "$jobdir/exit" || ! wait_for_file "$other/exit"; then
    fail "jobs did not finish"
  fi
  wait_gone "$(sed -n 's/^pid=//p' "$jobdir/runner")" || fail "first runner did not finish"
  wait_gone "$(sed -n 's/^pid=//p' "$other/runner")" || fail "second runner did not finish"
  cat > "$dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = show ] && [ -e "$FM_HOME/hold-lookup-fails" ]; then
  echo 'backlog lookup unavailable' >&2
  exit 1
fi
exec "$FM_REAL_TASKS_AXI" "$@"
SH
  chmod +x "$dir/fakebin/tasks-axi"
  touch "$dir/hold-lookup-fails"
  FM_REAL_TASKS_AXI="$(command -v tasks-axi)" steer_check "$dir" || fail "failed-lookup delivery pass failed"
  [ "$(record_count "$dir")" = 2 ] || fail "lookup failure must not lose the completion records"
  job_lib "$dir" fm_task_job_write_record "$other/delivery" count=999 last=1 || fail "could not seed spent attempts"
  FM_REAL_TASKS_AXI="$(command -v tasks-axi)" steer_check "$dir" 1 || fail "failed-lookup retry pass failed"
  [ ! -s "$dir/send.log" ] || fail "a failed hold lookup rang a completion"
  [ ! -e "$jobdir/delivery" ] || fail "a failed lookup consumed a delivery attempt"
  [ ! -e "$other/escalated" ] || fail "a failed hold lookup escalated a completion"
  [ "$(grep -cF 'captain hold lookup failed' "$dir/state/t1.status" || true)" = 1 ] \
    || fail "the failed lookup must be reported once across jobs and watcher passes"
  assert_grep 'backlog lookup unavailable' "$dir/state/t1.status" "the status must name the lookup error"
  rm -f "$dir/hold-lookup-fails"
  FM_REAL_TASKS_AXI="$(command -v tasks-axi)" steer_check "$dir" || fail "recovered-lookup pass failed"
  [ "$(grep -cF "$DOORBELL" "$dir/send.log" || true)" = 1 ] || fail "lookup recovery must allow the first ring"
  [ -s "$other/escalated" ] || fail "lookup recovery must allow a spent completion to escalate"
  [ "$(grep -cF 'captain hold lookup failed' "$dir/state/t1.status" || true)" = 1 ] \
    || fail "lookup recovery duplicated the error status"
  pass "task job: hold lookup errors suppress rings and escalation, report once, and allow delivery after recovery"
}

test_diagnostics_preserve_declared_holds_and_decisions() {
  local mode dir out jobdir lost runner child held open
  held='captain-held [key=external]: waiting for the captain on another work item'
  for mode in unrecoverable lookup; do
    dir=$(setup_case "diagnostic-$mode")
    printf 'needs-decision [key=pending-reply-keep]: pending-reply-keep: retain this decision\n' >> "$dir/state/t1.status"
    open=$(job_lib "$dir" status_open_decisions "$dir/state/t1.status")
    [ -n "$open" ] || fail "the fixture did not retain its reserved decision"
    [ -z "$(job_lib "$dir" status_own_open_decisions "$dir/state/t1.status")" ] || fail "the fixture masked the declared hold with its own decision"
    out=$(job_start "$dir" --timeout 60 -- true) || fail "completion start failed: $out"
    jobdir=$(job_dir_of "$dir" "$out")
    wait_for_file "$jobdir/exit" || fail "completion did not finish"
    wait_gone "$(sed -n 's/^pid=//p' "$jobdir/runner")" || fail "completion runner did not finish"
    if [ "$mode" = unrecoverable ]; then
      out=$(job_start "$dir" --timeout 60 -- sleep 60) || fail "lost job start failed: $out"
      lost=$(job_dir_of "$dir" "$out")
      runner=$(sed -n 's/^pid=//p' "$lost/runner")
      child=$(sed -n 's/^pid=//p' "$lost/child")
      kill -KILL "$runner"
      wait_gone "$runner" || fail "lost runner did not stop"
      kill -KILL "$child"
      wait_gone "$child" || fail "fixture command did not stop"
      printf '%s\n' "$held" >> "$dir/state/t1.status"
    else
      cat > "$dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = show ]; then
  printf 'captain-held [key=external]: waiting for the captain on another work item\n' >> "$FM_HOME/state/t1.status"
  echo 'diagnostic hold lookup unavailable' >&2
  exit 1
fi
exec "$FM_REAL_TASKS_AXI" "$@"
SH
      chmod +x "$dir/fakebin/tasks-axi"
    fi
    FM_REAL_TASKS_AXI="$(command -v tasks-axi)" steer_check "$dir" || fail "$mode diagnostic pass failed"
    assert_grep "task-job" "$dir/state/t1.status" "the diagnostic must remain a status line"
    [ "$(job_lib "$dir" status_declared_wait_line "$dir/state/t1.status")" = "$held" ] || fail "$mode diagnostic replaced the declared hold"
    [ "$(job_lib "$dir" status_open_decisions "$dir/state/t1.status")" = "$open" ] || fail "$mode diagnostic changed open decisions"
    FM_REAL_TASKS_AXI="$(command -v tasks-axi)" steer_check "$dir" 0 || fail "$mode later pass failed"
    [ -s "$jobdir/delivered" ] || fail "$mode held completion was not recorded"
    [ ! -e "$jobdir/delivery" ] || fail "$mode diagnostic allowed a held delivery attempt"
    [ ! -s "$dir/send.log" ] || fail "$mode diagnostic rang a held completion"
  done
  pass "task job: both diagnostic writers preserve declared captain holds and open decisions"
}

test_start_refuses_without_identity_or_timeout() {
  local dir rc out
  dir=$(setup_case refuse)
  rc=0
  out=$(env -u FM_TASK_INBOX "$JOB" start --timeout 5 -- true 2>&1) || rc=$?
  expect_code 1 "$rc" "start without FM_TASK_INBOX"
  assert_contains "$out" "FM_TASK_INBOX is not set" "the refusal should name the missing identity"
  rc=0
  out=$(job_start "$dir" -- true 2>&1) || rc=$?
  expect_code 2 "$rc" "start without a timeout"
  rc=0
  out=$(job_start "$dir" --timeout 9999999 -- true 2>&1) || rc=$?
  expect_code 2 "$rc" "start with an oversized timeout"
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=grok"
  rc=0
  out=$(job_start "$dir" --timeout 5 -- true 2>&1) || rc=$?
  expect_code 1 "$rc" "start without a spawn generation"
  assert_contains "$out" "no spawn_gen" "the refusal should name the missing generation"
  [ ! -d "$dir/state/t1.inbox/jobs" ] || [ -z "$(ls "$dir/state/t1.inbox/jobs")" ] \
    || fail "a refused start left a job record behind"
  rm -f "$dir/state/t1.meta"
  rm -rf "$dir/state/t1.inbox"
  rc=0
  out=$(job_start "$dir" --timeout 5 -- true 2>&1) || rc=$?
  expect_code 1 "$rc" "start after task retirement"
  [ ! -e "$dir/state/t1.inbox" ] || fail "a retired task's start recreated its inbox"
  pass "task job: start refuses without a task identity, a spawn generation, or a valid timeout"
}

fm_test_run \
  test_timeout_stops_a_command_in_its_own_group \
  test_startup_failure_preserves_recovery_records \
  test_hold_lookup_error_is_reported_once \
  test_diagnostics_preserve_declared_holds_and_decisions \
  test_completion_reaches_inbox_and_rings \
  test_completion_names_the_starting_generation \
  test_timeout_stops_the_command_group \
  test_hold_defers_the_ring_until_the_decision_closes \
  test_captain_hold_defers_completion \
  test_backlog_captain_hold_defers_completion \
  test_first_job_creates_inbox_for_live_task \
  test_runner_waits_for_descendants_after_command_exit \
  test_teardown_during_timeout_cleanup \
  test_recovery_after_runner_dies_during_cleanup \
  test_decimal_timeouts_and_graces \
  test_runner_identity_is_independent_of_timezone \
  test_watcher_delivers_a_finished_job_once \
  test_completion_bypasses_older_steer \
  test_failed_completion_has_its_own_retry_and_escalation \
  test_completion_never_delays_a_steer \
  test_cleanup_preserves_reused_runner_groups \
  test_secondmate_teardown_stops_child_job_without_delivery \
  test_finished_live_runner_is_owned_until_stopped \
  test_watcher_rerings_until_acknowledged \
  test_watcher_survives_retired_completion_bookkeeping \
  test_watcher_reports_a_lost_runner_as_unrecoverable \
  test_stop_all_stops_without_delivering \
  test_removed_inbox_is_never_recreated \
  test_delivery_serializes_with_retirement \
  test_start_refuses_without_identity_or_timeout
