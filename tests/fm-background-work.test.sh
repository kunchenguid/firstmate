#!/usr/bin/env bash
# Behavior tests for detached background-work visibility.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMMAND="$ROOT/bin/fm-background-work.sh"
TMP_ROOT=$(fm_test_tmproot fm-background-work)
declare -a LIVE_PIDS=()

cleanup_background_work_tests() {
  local pid
  for pid in "${LIVE_PIDS[@]+"${LIVE_PIDS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_background_work_tests EXIT
trap 'cleanup_background_work_tests; exit 130' INT
trap 'cleanup_background_work_tests; exit 143' TERM

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home"
  printf '%s\n' "$home"
}

make_progress_command() {
  local body=$2 script="$TMP_ROOT/$1.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$body"
  } > "$script"
  chmod 0755 "$script"
  printf '%s\n' "$script"
}

start_sleeper() {
  sleep 60 &
  STARTED_PID=$!
  LIVE_PIDS+=("$STARTED_PID")
}

stop_sleeper() {
  local pid=$1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

register_fixture() {
  local home=$1 id=$2 pid=$3 progress=$4 progress_arg=$5
  local -a progress_argv=("$progress")
  shift 5
  [ -z "$progress_arg" ] || progress_argv+=("$progress_arg")
  FM_HOME="$home" "$COMMAND" register "$id" \
    --description "Collecting fixture observations" \
    --task "fixture-investigation" \
    --pid "$pid" \
    --started-at "2026-09-03T22:25:13Z" \
    --expected-finish-at "2026-09-05T00:25:13Z" \
    "$@" \
    --progress "${progress_argv[@]}" >/dev/null
}

list_json() {
  FM_HOME="$1" "$COMMAND" list --json
}

write_fake_proc_identity() {
  local proc_root=$1 pid=$2 starttime=$3
  mkdir -p "$proc_root/$pid"
  printf '%s\n' "$pid (fixture) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 $starttime 20 21 22" \
    > "$proc_root/$pid/stat"
  printf 'fixture\0worker\0' > "$proc_root/$pid/cmdline"
}

test_live_adopted_process_reads_alive_and_progressing() {
  local home progress_file progress first second
  home=$(make_home live)
  progress_file="$home/progress"
  printf '10\n' > "$progress_file"
  # shellcheck disable=SC2016 # The expression belongs in the generated fixture.
  progress=$(make_progress_command live-progress 'printf "%s rows\n" "$(cat "$1")"')
  start_sleeper
  register_fixture "$home" collector "$STARTED_PID" "$progress" "$progress_file"

  first=$(list_json "$home") || fail "could not list the first live observation"
  printf '%s\n' "$first" | jq -e '
    .schema == "fm-background-work-list.v1" and
    (.records | length) == 1 and
    .records[0].id == "collector" and
    .records[0].liveness.status == "alive" and
    .records[0].progress.status == "unknown" and
    .records[0].progress.reason == "first-observation" and
    .records[0].progress.value == "10 rows"
  ' >/dev/null || fail "a newly adopted live process did not read alive with an honest first observation"

  printf '11\n' > "$progress_file"
  second=$(list_json "$home") || fail "could not list the changed live observation"
  printf '%s\n' "$second" | jq -e '
    .records[0].liveness.status == "alive" and
    .records[0].progress.status == "progressing" and
    .records[0].progress.reason == "value-changed" and
    .records[0].progress.value == "11 rows"
  ' >/dev/null || fail "a changed progress value did not read progressing"
  pass "an already-running process is adopted by identity and reports real progress"
}

test_dead_process_remains_listed_as_dead() {
  local home progress result pid
  home=$(make_home dead)
  progress=$(make_progress_command dead-progress 'printf "one cycle\n"')
  start_sleeper
  pid=$STARTED_PID
  register_fixture "$home" departed "$pid" "$progress" ''
  stop_sleeper "$pid"

  result=$(list_json "$home") || fail "could not list the dead process"
  printf '%s\n' "$result" | jq -e '
    (.records | length) == 1 and
    .records[0].id == "departed" and
    .records[0].liveness.status == "dead" and
    .records[0].liveness.reason == "process-missing" and
    .records[0].progress.status == "unknown"
  ' >/dev/null || fail "a dead registered process disappeared or looked healthy"
  pass "a dead process remains visible and explicitly dead"
}

test_unchanged_progress_becomes_stalled_while_process_stays_alive() {
  local home progress first result
  home=$(make_home stalled)
  progress=$(make_progress_command stalled-progress 'printf "cycle 7\n"')
  start_sleeper
  register_fixture "$home" stuck "$STARTED_PID" "$progress" '' --stale-after 1
  first=$(list_json "$home") || fail "could not seed the stalled observation"
  printf '%s\n' "$first" | jq -e '.records[0].progress.reason == "first-observation"' >/dev/null \
    || fail "the stalled case did not start from an honest first observation"
  sleep 1

  result=$(list_json "$home") || fail "could not list unchanged progress"
  printf '%s\n' "$result" | jq -e '
    .records[0].liveness.status == "alive" and
    .records[0].progress.status == "stalled" and
    .records[0].progress.reason == "value-unchanged" and
    .records[0].progress.value == "cycle 7"
  ' >/dev/null || fail "an alive process with stale progress was reported healthy"
  pass "alive and stalled is distinct from alive and progressing"
}

test_hung_progress_command_reads_unknown() {
  local home progress result
  home=$(make_home timeout)
  progress=$(make_progress_command timeout-progress 'sleep 10; printf "late\n"')
  start_sleeper
  register_fixture "$home" slow-probe "$STARTED_PID" "$progress" '' --progress-timeout 1

  result=$(list_json "$home") || fail "could not list a timed-out progress command"
  printf '%s\n' "$result" | jq -e '
    .records[0].liveness.status == "alive" and
    .records[0].progress.status == "unknown" and
    .records[0].progress.reason == "timeout" and
    .records[0].progress.value == null
  ' >/dev/null || fail "a timed-out progress command defaulted to a healthy-looking state"
  pass "a hung progress command is bounded and reads unknown"
}

test_reused_pid_reads_dead() {
  local home progress proc_root result pid
  home=$(make_home reused)
  progress=$(make_progress_command reused-progress 'printf "cycle 1\n"')
  proc_root="$home/proc"
  start_sleeper
  pid=$STARTED_PID
  write_fake_proc_identity "$proc_root" "$pid" 100
  FM_PROC_ROOT_OVERRIDE="$proc_root" FM_HOME="$home" "$COMMAND" register reused \
    --description "Collecting fixture observations" \
    --task "fixture-investigation" \
    --pid "$pid" \
    --started-at "2026-09-03T22:25:13Z" \
    --progress "$progress" >/dev/null \
    || fail "could not register the PID-reuse fixture"
  write_fake_proc_identity "$proc_root" "$pid" 200

  result=$(FM_PROC_ROOT_OVERRIDE="$proc_root" list_json "$home") \
    || fail "could not list the reused PID fixture"
  printf '%s\n' "$result" | jq -e '
    .records[0].liveness.status == "dead" and
    .records[0].liveness.reason == "pid-reused" and
    .records[0].progress.status == "unknown"
  ' >/dev/null || fail "a reused PID was mistaken for the registered work"
  pass "PID reuse is reported as the registered process being dead"
}

test_unregistered_process_is_not_listed() {
  local home result
  home=$(make_home unregistered)
  start_sleeper
  result=$(list_json "$home") || fail "could not list an empty background-work registry"
  printf '%s\n' "$result" | jq -e '
    .schema == "fm-background-work-list.v1" and (.records | length) == 0
  ' >/dev/null || fail "an unregistered process appeared in the list"
  pass "an unregistered process is simply absent"
}

test_retire_removes_visibility_without_signalling_process() {
  local home progress pid result
  home=$(make_home retire)
  progress=$(make_progress_command retire-progress 'printf "visible\n"')
  start_sleeper
  pid=$STARTED_PID
  register_fixture "$home" temporary "$pid" "$progress" ''
  FM_HOME="$home" "$COMMAND" retire temporary >/dev/null \
    || fail "could not retire the visibility record"
  kill -0 "$pid" 2>/dev/null || fail "retiring visibility signalled the process"
  result=$(list_json "$home") || fail "could not list after retirement"
  printf '%s\n' "$result" | jq -e '(.records | length) == 0' >/dev/null \
    || fail "retired background work remained listed"
  pass "retirement removes only visibility and leaves the process running"
}

test_live_adopted_process_reads_alive_and_progressing
test_dead_process_remains_listed_as_dead
test_unchanged_progress_becomes_stalled_while_process_stays_alive
test_hung_progress_command_reads_unknown
test_reused_pid_reads_dead
test_unregistered_process_is_not_listed
test_retire_removes_visibility_without_signalling_process
