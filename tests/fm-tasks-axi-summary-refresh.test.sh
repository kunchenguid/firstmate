#!/usr/bin/env bash
# Prove bin/fm-tasks-axi.sh republishes state/home-summary.json after successful
# backlog mutations without changing read-only calls or failed mutations, without
# holding its caller or the caller's process group, and without dropping a write
# that lands while another refresh holds the home's refresh lock.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
REFRESH="$ROOT/bin/fm-home-summary-refresh.sh"
HOLD="$ROOT/bin/fm-captain-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-tasks-axi-summary-refresh)

unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

empty_backlog() {
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$1"
}

make_home() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/data" "$dir/state" "$dir/config" "$dir/bin"
  fm_test_tasks_toml "$dir/.tasks.toml"
  printf '%s\n' "$dir"
}

# A stand-in refresh that appends its own process group to <marker> and then
# sleeps <seconds>, so a test can observe whether, where, and how a trigger ran.
make_recording_refresh() {  # <name> <marker> <seconds>
  local fake="$TMP_ROOT/$1.sh"
  cat > "$fake" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$(ps -o pgid= -p \$\$ | tr -d '[:space:]')" >> "$2"
sleep $3
SH
  chmod +x "$fake"
  printf '%s\n' "$fake"
}

run_wrapper() {  # <home> <args...>
  local home=$1
  shift
  (
    cd "$home" && FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
      FM_TEST_SEAM=1 "$WRAPPER" "$@"
  )
}

run_hold() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEST_SEAM=1 "$HOLD" "$@"
}

wait_for_ledger() {  # <home> <max-seconds> <jq-filter>
  local home=$1 max=$2 filter=$3 i=0
  while [ "$i" -lt "$max" ]; do
    if jq -e "$filter" "$home/state/home-summary.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_for_file() {  # <path> <max-tenths>
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ ! -s "$1" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_stale_ledger_republishes_after_backlog_hold() {
  local home
  home=$(make_home stale-ledger)
  printf '# fixture\n' > "$home/AGENTS.md"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$REFRESH" --best-effort >/dev/null \
    || fail "initial publication without backlog failed"
  jq -e '.invalidity.kind == "missing_backlog"' "$home/state/home-summary.json" >/dev/null \
    || fail "ledger did not record missing_backlog before backlog existed"
  empty_backlog "$home/data/backlog.md"
  run_wrapper "$home" add cap-hold-1 "Captain pick" --kind captain --repo firstmate >/dev/null \
    || fail "backlog add through the wrapper failed"
  run_hold "$home" hold cap-hold-1 --title "Captain pick" --reason "choose A or B" >/dev/null \
    || fail "captain hold failed"
  wait_for_ledger "$home" 30 '.valid == true and any(.decisions_open[]; .id == "cap-hold-1" and .reason == "choose A or B")' \
    || fail "ledger never published the open captain hold: $(jq -c . "$home/state/home-summary.json" 2>/dev/null || true)"
  pass "backlog mutation through the wrapper republished a stale ledger with the captain hold"
}

test_write_during_running_refresh_is_published() {
  local home lock release holder i=0
  home=$(make_home lock-held)
  printf '# fixture\n' > "$home/AGENTS.md"
  empty_backlog "$home/data/backlog.md"
  lock="$home/state/.home-summary-refresh.lock"
  release="$TMP_ROOT/lock-held.release"
  bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 1; while [ ! -e "$3" ]; do sleep 0.1; done; fm_lock_release "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$release" &
  holder=$!
  while [ ! -d "$lock" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -d "$lock" ] || { touch "$release"; wait "$holder"; fail "fixture could not hold the refresh lock"; }
  run_wrapper "$home" add held-1 "queued while a refresh runs" >/dev/null \
    || { touch "$release"; wait "$holder"; fail "backlog add through the wrapper failed"; }
  sleep 1
  [ ! -e "$home/state/home-summary.json" ] \
    || { touch "$release"; wait "$holder"; fail "refresh published while another refresh held the lock"; }
  touch "$release"
  wait "$holder" || fail "lock holder fixture failed"
  wait_for_ledger "$home" 30 'any(.queued[]; .id == "held-1")' \
    || fail "write that landed during a running refresh was never published: $(jq -c . "$home/state/home-summary.json" 2>/dev/null || true)"
  pass "a write that lands while another refresh holds the lock is still published"
}

test_read_only_calls_do_not_republish() {
  local home marker fake
  home=$(make_home read-only)
  empty_backlog "$home/data/backlog.md"
  marker="$home/state/refresh-invocations"
  fake=$(make_recording_refresh read-only-refresh "$marker" 0)
  FM_TEST_HOME_SUMMARY_REFRESH_BIN="$fake" run_wrapper "$home" list >/dev/null || fail "list failed"
  FM_TEST_HOME_SUMMARY_REFRESH_BIN="$fake" run_wrapper "$home" >/dev/null || fail "dashboard failed"
  FM_TEST_HOME_SUMMARY_REFRESH_BIN="$fake" run_wrapper "$home" ready >/dev/null || fail "ready failed"
  FM_TEST_HOME_SUMMARY_REFRESH_BIN="$fake" run_wrapper "$home" public-followup list --json >/dev/null \
    || fail "public-followup list failed"
  FM_TEST_HOME_SUMMARY_REFRESH_BIN="$fake" run_wrapper "$home" public-followup ready --json >/dev/null \
    || fail "public-followup ready failed"
  sleep 1
  assert_absent "$marker" "a read-only call republished the home summary"
  FM_TEST_HOME_SUMMARY_REFRESH_BIN="$fake" run_wrapper "$home" add ro-control "control write" >/dev/null \
    || fail "control add failed"
  wait_for_file "$marker" 50 || fail "successful mutation did not republish the home summary"
  pass "read-only calls did not republish the home summary while a mutation did"
}

expect_republish() {  # <home> <fake> <marker> <args...>
  local home=$1 fake=$2 marker=$3
  shift 3
  rm -f "$marker"
  FM_TEST_HOME_SUMMARY_REFRESH_BIN="$fake" run_wrapper "$home" "$@" >/dev/null || fail "$* failed"
  wait_for_file "$marker" 50 || fail "'$*' rewrote the backlog without republishing the home summary"
}

test_mutating_aliases_republish() {
  local home marker fake
  home=$(make_home aliases)
  empty_backlog "$home/data/backlog.md"
  marker="$home/state/refresh-invocations"
  fake=$(make_recording_refresh aliases-refresh "$marker" 0)
  expect_republish "$home" "$fake" "$marker" add alias-1 "first"
  expect_republish "$home" "$fake" "$marker" add alias-2 "second"
  expect_republish "$home" "$fake" "$marker" edit alias-1 --title "renamed"
  expect_republish "$home" "$fake" "$marker" close alias-1
  expect_republish "$home" "$fake" "$marker" delete alias-2
  pass "edit, close, and delete aliases republish the home summary"
}

test_failed_mutation_leaves_output_and_status() {
  local home out rc marker fake
  home=$(make_home failed-mutation)
  empty_backlog "$home/data/backlog.md"
  marker="$home/state/refresh-invocations"
  fake=$(make_recording_refresh failed-mutation-refresh "$marker" 0)
  out=$(FM_TEST_HOME_SUMMARY_REFRESH_BIN="$fake" run_wrapper "$home" start missing-task-id 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "start of a missing task should fail"
  sleep 1
  assert_absent "$marker" "failed mutation republished the ledger"
  assert_contains "$out" "missing-task-id" "failed mutation stderr/stdout was unexpected"
  pass "failed backlog mutation left exit status and output unchanged without republishing"
}

test_slow_refresh_does_not_hold_wrapper_or_its_group() {
  local home marker fake start end elapsed group refresh_group i=0
  home=$(make_home slow-refresh)
  empty_backlog "$home/data/backlog.md"
  marker="$home/state/refresh-invocations"
  fake=$(make_recording_refresh slow-refresh "$marker" 5)
  start=$(date +%s)
  set -m
  (
    FM_TEST_HOME_SUMMARY_REFRESH_BIN="$fake" run_wrapper "$home" add slow-1 "queued work" >/dev/null
  ) &
  group=$!
  set +m
  wait "$group" || fail "add failed"
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$elapsed" -lt 4 ] || fail "wrapper waited on home-summary refresh (${elapsed}s)"
  while kill -0 -- "-$group" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  ! kill -0 -- "-$group" 2>/dev/null || fail "detached refresh kept the caller's process group alive"
  wait_for_file "$marker" 50 || fail "detached refresh never ran"
  refresh_group=$(sed -n '1p' "$marker")
  assert_not_equals "$group" "$refresh_group" "detached refresh ran in the caller's process group"
  pass "successful mutation returned and released its process group before a slow refresh finished"
}

test_stale_ledger_republishes_after_backlog_hold
test_write_during_running_refresh_is_published
test_read_only_calls_do_not_republish
test_mutating_aliases_republish
test_failed_mutation_leaves_output_and_status
test_slow_refresh_does_not_hold_wrapper_or_its_group
