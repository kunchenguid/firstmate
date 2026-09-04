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

test_unknown_process_state_is_never_adopted_or_reported_alive() {
  local home progress fakebin pid result
  home=$(make_home unknown-process-state)
  progress=$(make_progress_command unknown-state-progress 'printf "visible\n"')
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'stat='*) exit 1 ;;
  *'lstart='*) printf 'Thu Sep  3 22:25:13 2026 fixture worker\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  start_sleeper
  pid=$STARTED_PID
  PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$home/missing-proc" FM_HOME="$home" \
    "$COMMAND" register observed --description "Collecting fixture observations" \
      --task fixture-investigation --pid "$pid" --started-at 2026-09-03T22:25:13Z \
      --progress "$progress" >/dev/null 2>&1 \
    && fail "fixture unexpectedly registered with unreadable process state"

  register_fixture "$home" observed "$pid" "$progress" ''
  result=$(PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$home/missing-proc" list_json "$home") \
    || fail "could not observe an indeterminate process state"
  printf '%s\n' "$result" | jq -e '
    .records[0].liveness.status == "unknown"
      and .records[0].liveness.reason == "process-state-unreadable"
      and .records[0].progress.status == "unknown"
  ' >/dev/null || fail "an indeterminate process state was reported alive"
  pass "unreadable process state is refused at adoption and remains unknown during observation"
}

test_many_hung_probes_share_one_disclosed_collection_budget() {
  local home progress result started elapsed i
  home=$(make_home collection-budget)
  progress=$(make_progress_command collection-budget-progress 'sleep 10; printf "late\n"')
  start_sleeper
  i=1
  while [ "$i" -le 6 ]; do
    register_fixture "$home" "hung-$i" "$STARTED_PID" "$progress" '' --progress-timeout 10
    i=$((i + 1))
  done
  started=$(date +%s)
  result=$(FM_BACKGROUND_WORK_COLLECTION_BUDGET=2 \
    FM_BACKGROUND_WORK_COLLECTION_PROBE_TIMEOUT=1 \
    FM_BACKGROUND_WORK_COLLECTION_MAX_PROBES=4 list_json "$home") \
    || fail "bounded concurrent collection failed"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 4 ] || fail "hung probes exceeded the shared collection budget (${elapsed}s)"
  printf '%s\n' "$result" | jq -e '
    (.records | length) == 6
      and .collection.budget_seconds == 2
      and .collection.total_records == 6
      and .collection.probes_attempted == 4
      and .collection.probes_completed <= 4
      and .collection.truncated == true
      and all(.records[]; .progress.status == "unknown"
        and (.progress.reason == "timeout" or .progress.reason == "collection-budget"))
      and all(.records[] | select(.progress.reason == "collection-budget");
        .liveness.status == "unknown")
      and ([.records[] | select(.progress.reason == "collection-budget")] | length) >= 2
  ' >/dev/null || fail "budgeted collection hid records, health, or truncation: $result"
  pass "many hung probes remain visible and unknown under one disclosed collection budget"
}

test_registration_bound_keeps_whole_collection_finite() {
  local home progress i result
  home=$(make_home registry-bound)
  progress=$(make_progress_command registry-bound-progress 'printf "ready\n"')
  start_sleeper
  i=1
  while [ "$i" -le 3 ]; do
    FM_BACKGROUND_WORK_MAX_RECORDS=3 register_fixture \
      "$home" "bounded-$i" "$STARTED_PID" "$progress" ''
    i=$((i + 1))
  done
  if FM_BACKGROUND_WORK_MAX_RECORDS=3 register_fixture \
    "$home" bounded-4 "$STARTED_PID" "$progress" '' 2>/dev/null; then
    fail "registration exceeded the finite registry bound"
  fi
  result=$(FM_BACKGROUND_WORK_MAX_RECORDS=3 list_json "$home") \
    || fail "could not list a full bounded registry"
  printf '%s\n' "$result" | jq -e '
    .collection.total_records == 3 and (.records | length) == 3
  ' >/dev/null || fail "a full bounded registry did not preserve every row"
  pass "registration bounds whole-collection enumeration without hiding registered work"
}

test_concurrent_retire_cannot_hide_captured_registry() {
  local home progress fakebin real_jq result_file marker list_pid result i
  home=$(make_home retire-race)
  progress=$(make_progress_command retire-race-progress 'printf "ready\n"')
  start_sleeper
  register_fixture "$home" keep "$STARTED_PID" "$progress" ''
  register_fixture "$home" retiring "$STARTED_PID" "$progress" ''
  fakebin="$home/fakebin"
  marker="$home/assembly-started"
  result_file="$home/list.json"
  real_jq=$(command -v jq)
  mkdir -p "$fakebin"
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
if [ "${1-}" = -s ]; then
  : > "$ASSEMBLY_MARKER"
  sleep 1
fi
exec "$REAL_JQ" "$@"
SH
  chmod +x "$fakebin/jq"
  PATH="$fakebin:$PATH" REAL_JQ="$real_jq" ASSEMBLY_MARKER="$marker" \
    FM_HOME="$home" "$COMMAND" list --json > "$result_file" &
  list_pid=$!
  i=0
  while [ ! -f "$marker" ] && [ "$i" -lt 50 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -f "$marker" ] || fail "list did not reach final assembly"
  FM_HOME="$home" "$COMMAND" retire retiring >/dev/null \
    || fail "concurrent retirement failed after registry capture"
  wait "$list_pid" || fail "concurrent retirement made list fail"
  result=$(cat "$result_file")
  printf '%s\n' "$result" | jq -e '
    (.records | map(.id) | sort) == ["keep", "retiring"]
  ' >/dev/null || fail "concurrent retirement hid captured or unrelated work: $result"
  pass "list retains one stable registry snapshot across concurrent retirement"
}

test_live_adopted_process_reads_alive_and_progressing
test_dead_process_remains_listed_as_dead
test_unchanged_progress_becomes_stalled_while_process_stays_alive
test_hung_progress_command_reads_unknown
test_reused_pid_reads_dead
test_unregistered_process_is_not_listed
test_retire_removes_visibility_without_signalling_process
test_unknown_process_state_is_never_adopted_or_reported_alive
test_many_hung_probes_share_one_disclosed_collection_budget
test_registration_bound_keeps_whole_collection_finite
test_concurrent_retire_cannot_hide_captured_registry
