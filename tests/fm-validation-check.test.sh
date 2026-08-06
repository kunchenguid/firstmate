#!/usr/bin/env bash
# Behavior tests for registered no-mistakes validation-gate watcher checks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"

ARM="$ROOT/bin/fm-validation-check.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-validation-check)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/root/bin" "$fakebin" "$dir/wt"
  fm_git_init_commit "$dir/wt"
  fm_write_meta "$dir/home/state/task-a.meta" \
    'window=firstmate:fm-task-a' \
    'endpoint_task_id=task-a' \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=no-mistakes'
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'axi status')
    [ -z "${FM_TEST_EXECUTED:-}" ] || : > "$FM_TEST_EXECUTED"
    cat "${FM_TEST_STATUS:?}"
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' headRefOid '*) printf '%s\n' deadbeefcafefeed0000000000000000deadbeef ;;
  *) printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}" ;;
esac
SH
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/gh" "$dir/root/bin/fm-guard.sh"
  printf '%s\n' "$dir"
}

run_arm() {
  local dir=$1
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" PATH="$dir/fakebin:$BASE_PATH" \
    "$ARM" task-a
}

run_poll() {
  local dir=$1 status=$2
  FM_TEST_STATUS="$status" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    PATH="$dir/fakebin:$BASE_PATH" bash "$dir/home/state/task-a.check.sh"
}

test_arms_a_private_registered_check_and_stays_quiet_when_healthy() {
  local dir status out i
  dir=$(make_case healthy)
  status="$dir/status"
  printf 'id: run-healthy\nstatus: running\nawaiting_agent: working 2m\n' > "$status"

  run_arm "$dir" >/dev/null || fail "could not arm a validation check"
  [ "$(file_mode "$dir/home/state/task-a.check.sh")" = 700 ] \
    || fail "validation check was not mode 0700"
  fm_custom_check_registered "$dir/home/state" task-a \
    || fail "validation check was not registered before it could run"

  for i in 1 2 3 4 5; do
    out=$(run_poll "$dir" "$status") || fail "healthy validation poll exited non-zero"
    [ -z "$out" ] || fail "healthy validation poll emitted on pass $i: $out"
  done
  pass "validation check is registered and silent for healthy runs"
}

test_wakes_only_for_terminal_or_over_age_parked_runs() {
  local dir status out terminal
  dir=$(make_case wake-conditions)
  status="$dir/status"
  run_arm "$dir" >/dev/null || fail "could not arm wake-condition check"

  for terminal in passed failed cancelled completed; do
    printf 'id: run-%s\nstatus: %s\n' "$terminal" "$terminal" > "$status"
    out=$(run_poll "$dir" "$status") || fail "terminal validation poll failed for $terminal"
    [ "$out" = "validation: terminal $terminal" ] \
      || fail "terminal $terminal did not produce its one actionable line: $out"
  done

  printf 'id: run-outcome\nstatus: running\noutcome: passed\n' > "$status"
  out=$(run_poll "$dir" "$status") || fail "terminal outcome validation poll failed"
  [ "$out" = 'validation: terminal passed' ] \
    || fail "terminal outcome did not produce its one actionable line: $out"

  printf 'id: run-ci-ready\nstatus: running\noutcome: checks-passed\n' > "$status"
  out=$(run_poll "$dir" "$status") || fail "checks-passed validation poll failed"
  [ -z "$out" ] || fail "checks-passed is not a validation-gate wake condition: $out"

  printf 'id: run-equal\nstatus: running\nawaiting_agent: parked 4m\n' > "$status"
  out=$(run_poll "$dir" "$status") || fail "equal-threshold validation poll failed"
  [ -z "$out" ] || fail "equal threshold parked run woke early: $out"

  printf 'id: run-parked\nstatus: running\nawaiting_agent: parked 5m\n' > "$status"
  out=$(run_poll "$dir" "$status") || fail "parked validation poll failed"
  [ "$out" = 'validation: awaiting_agent parked 300s' ] \
    || fail "over-age parked run did not produce one actionable line: $out"

  printf 'id: run-configured\nstatus: running\nawaiting_agent: parked 301s\n' > "$status"
  out=$(FM_VALIDATION_PARKED_SECS=300 run_poll "$dir" "$status") \
    || fail "configured-threshold validation poll failed"
  [ "$out" = 'validation: awaiting_agent parked 301s' ] \
    || fail "configured parked threshold was not honored: $out"
  pass "validation check wakes only for terminal and over-age parked runs"
}

test_fails_silent_when_a_local_status_read_is_unavailable_or_unparseable() {
  local dir status out empty_path
  dir=$(make_case silent-failures)
  status="$dir/status"
  run_arm "$dir" >/dev/null || fail "could not arm silent-failure check"

  empty_path="$dir/empty-path"
  mkdir "$empty_path"
  out=$(FM_TEST_STATUS="$status" PATH="$empty_path" /bin/bash "$dir/home/state/task-a.check.sh") \
    || fail "missing no-mistakes did not fail silent"
  [ -z "$out" ] || fail "missing no-mistakes emitted: $out"

  printf 'this is not no-mistakes status output\n' > "$status"
  out=$(run_poll "$dir" "$status") || fail "unparseable status did not fail silent"
  [ -z "$out" ] || fail "unparseable status emitted: $out"

  rm -rf "$dir/wt"
  out=$(run_poll "$dir" "$status") || fail "missing worktree did not fail silent"
  [ -z "$out" ] || fail "missing worktree emitted: $out"
  pass "validation check fails silent on unavailable or invalid local state"
}

test_watcher_does_not_execute_an_unregistered_validation_check() {
  local dir status marker out rc
  dir=$(make_case unregistered)
  status="$dir/status"
  marker="$dir/executed"
  printf 'id: run-parked\nstatus: running\nawaiting_agent: parked 5m\n' > "$status"
  run_arm "$dir" >/dev/null || fail "could not arm unregistered-check fixture"
  rm -f "$dir/home/state/task-a.check-trust"

  rc=0
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_TEST_STATUS="$status" \
    FM_TEST_EXECUTED="$marker" FM_POLL=1 FM_CHECK_INTERVAL=1 FM_SIGNAL_GRACE=1 \
    PATH="$dir/fakebin:$BASE_PATH" "$CHECKPOINT" --seconds 2 2>&1) || rc=$?
  case "$rc" in
    0|124) ;;
    *) fail "watcher rejected-check fixture exited $rc: $out" ;;
  esac
  [ ! -e "$marker" ] || fail "watcher executed a validation check after its trust binding was removed"
  pass "watcher refuses an unregistered validation check without executing it"
}

test_pr_merge_poll_replaces_and_outprioritizes_validation_poll() {
  local dir status out
  dir=$(make_case pr-transition)
  status="$dir/status"
  printf 'id: run-terminal\nstatus: passed\n' > "$status"
  run_arm "$dir" >/dev/null || fail "could not arm validation half of transition"
  out=$(run_poll "$dir" "$status") || fail "validation half of transition failed"
  [ "$out" = 'validation: terminal passed' ] \
    || fail "validation half did not wake before PR hand-off: $out"

  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" task-a https://github.com/example/repo/pull/9 >/dev/null \
    || fail "could not publish PR merge poll over validation check"
  fm_pr_poll_artifacts_valid "$dir/home/state" task-a "$POLL" \
    || fail "PR hand-off did not leave an authenticated merge poll"
  out=$(FM_TEST_GH_STATE=MERGED PATH="$dir/fakebin:$BASE_PATH" bash "$dir/home/state/task-a.check.sh") \
    || fail "published merge poll did not run"
  [ "$out" = merged ] || fail "merge poll did not replace validation behavior: $out"

  out=$(run_arm "$dir") || fail "validation armer refused a PR-owned check slot"
  assert_contains "$out" 'reserved for PR merge polling' \
    "validation armer did not disclose PR poll precedence"
  fm_pr_poll_artifacts_valid "$dir/home/state" task-a "$POLL" \
    || fail "validation armer displaced the PR merge poll"
  out=$(FM_TEST_GH_STATE=MERGED PATH="$dir/fakebin:$BASE_PATH" bash "$dir/home/state/task-a.check.sh") \
    || fail "merge poll did not run after reverse-order arming attempt"
  [ "$out" = merged ] || fail "reverse-order arming changed merge poll behavior: $out"
  pass "validation and PR poll hand-off preserves merge-poll priority in both orders"
}

test_arms_a_private_registered_check_and_stays_quiet_when_healthy
test_wakes_only_for_terminal_or_over_age_parked_runs
test_fails_silent_when_a_local_status_read_is_unavailable_or_unparseable
test_watcher_does_not_execute_an_unregistered_validation_check
test_pr_merge_poll_replaces_and_outprioritizes_validation_poll
