#!/usr/bin/env bash
# Behavior tests for bin/fm-gnhf.sh, the guarded launcher for GNHF runs.
#
# A fake `gnhf` records the argv, working directory, and GNHF_TELEMETRY it
# received, so each case asserts what the guard refused, what it forced, and
# what it left in the durable run record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCHER="$ROOT/bin/fm-gnhf.sh"
TMP_ROOT=$(fm_test_tmproot fm-gnhf)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CALL="$TMP_ROOT/gnhf-call"

mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state"
cat > "$HOME_DIR/data/projects.md" <<'EOF'
- demo [local-only] - a registered project (added 2026-01-01)
EOF
fm_git_init_commit "$HOME_DIR/projects/demo"
fm_git_init_commit "$HOME_DIR/projects/extra"

cat > "$FAKEBIN/gnhf" <<'SH'
#!/usr/bin/env bash
{
  printf 'cwd=%s\n' "$PWD"
  printf 'telemetry=%s\n' "${GNHF_TELEMETRY-unset}"
  printf 'run_auth=%s\n' "${FM_GNHF_RUN_AUTH-unset}"
  i=0
  for arg in "$@"; do
    i=$((i + 1))
    printf 'arg%s=%s\n' "$i" "$arg"
  done
} > "$FM_GNHF_TEST_CALL"
# The termination case needs a child that outlives the launch and can be
# signalled. exec replaces this shell, so the recorded pid is the worker itself
# and a stopped child cannot leave a stray grandchild behind.
if [ -n "${FM_GNHF_TEST_SLEEP:-}" ]; then
  printf '%s\n' "$$" > "$FM_GNHF_TEST_PID"
  exec sleep "$FM_GNHF_TEST_SLEEP"
fi
printf 'fake gnhf output\n'
exit "${FM_GNHF_TEST_RC:-0}"
SH
chmod +x "$FAKEBIN/gnhf"

# run_gnhf <args...>: run the launcher against the fixture home. Sets RC and OUT.
# AUTH and TELEMETRY are passed only when already set, so the default-posture
# cases see the launcher's own defaults.
run_gnhf() {
  local -a envs=(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_GNHF_TEST_CALL="$CALL")
  if [ -n "${AUTH:-}" ]; then envs+=(FM_GNHF_RUN_AUTH="$AUTH"); fi
  if [ -n "${TELEMETRY:-}" ]; then envs+=(GNHF_TELEMETRY="$TELEMETRY"); fi
  if [ -n "${FAKE_RC:-}" ]; then envs+=(FM_GNHF_TEST_RC="$FAKE_RC"); fi
  rm -f "$CALL"
  OUT=$(env -u FM_GNHF_RUN_AUTH -u GNHF_TELEMETRY -u FM_GNHF_TEST_RC "${envs[@]}" "$LAUNCHER" "$@" 2>&1)
  RC=$?
  AUTH=
  TELEMETRY=
  FAKE_RC=
}

# The launcher prints both durable paths; the cases read them from there rather
# than guessing a name, so a run id that changes shape cannot quietly pass.
record_path() {
  printf '%s\n' "$OUT" | sed -n 's/^fm-gnhf: run record: //p'
}

status_path() {
  printf '%s\n' "$OUT" | sed -n 's/^fm-gnhf: status log: //p'
}

test_default_run_forces_worktree_and_records_posture() {
  run_gnhf --project demo -- --agent claude "do the work"
  [ "$RC" -eq 0 ] || fail "a default run failed: $RC ($OUT)"
  assert_contains "$(cat "$CALL")" $'arg1=--worktree\n' "the launcher did not force --worktree first"
  assert_contains "$(cat "$CALL")" $'telemetry=0\n' "telemetry did not default to off"
  assert_contains "$(cat "$CALL")" "cwd=$HOME_DIR/projects/demo" "the run did not start in the resolved checkout"
  local record status
  record=$(record_path)
  status=$(status_path)
  [ -n "$record" ] && [ -n "$status" ] || fail "the launcher wrote no durable run record"
  assert_contains "$(cat "$record")" $'mode=local-only\n' "the registered delivery mode was not recorded"
  assert_contains "$(cat "$record")" $'yolo=off\n' "the registered merge authority was not recorded"
  assert_contains "$(cat "$status")" 'working [at=' "the run record has no live status line"
  assert_contains "$(cat "$status")" 'done [at=' "the run record has no terminal status line"
  pass "fm-gnhf: a default run uses an isolated worktree, disables telemetry, and records the posture"
}

test_current_branch_is_refused_without_authorization() {
  run_gnhf --project demo -- --current-branch "do the work"
  [ "$RC" -eq 2 ] || fail "an unauthorized --current-branch run exited $RC, expected 2"
  [ ! -e "$CALL" ] || fail "an unauthorized --current-branch run still launched gnhf"
  assert_contains "$OUT" "refusing --current-branch" "the refusal did not name the flag"
  pass "fm-gnhf: --current-branch is refused without a per-run authorization"
}

test_push_is_refused_without_authorization() {
  run_gnhf --project demo -- --push "do the work"
  [ "$RC" -eq 2 ] || fail "an unauthorized --push run exited $RC, expected 2"
  [ ! -e "$CALL" ] || fail "an unauthorized --push run still launched gnhf"
  assert_contains "$OUT" "refusing --push" "the refusal did not name the flag"
  pass "fm-gnhf: --push is refused without a per-run authorization"
}

test_authorized_push_passes_through() {
  AUTH=push
  run_gnhf --project demo -- --push "do the work"
  [ "$RC" -eq 0 ] || fail "an authorized --push run failed: $RC ($OUT)"
  assert_contains "$(cat "$CALL")" $'arg1=--worktree\n' "--push lost the forced worktree mode"
  assert_contains "$(cat "$CALL")" $'arg2=--push\n' "--push did not reach gnhf"
  pass "fm-gnhf: an authorized --push run reaches gnhf with the worktree mode intact"
}

test_authorized_current_branch_runs_in_the_checkout() {
  AUTH=current-branch
  run_gnhf --project demo -- --current-branch "do the work"
  [ "$RC" -eq 0 ] || fail "an authorized --current-branch run failed: $RC ($OUT)"
  assert_contains "$(cat "$CALL")" $'arg1=--current-branch\n' "--current-branch did not reach gnhf first"
  assert_not_contains "$(cat "$CALL")" '--worktree' "an authorized --current-branch run also carried --worktree"
  pass "fm-gnhf: an authorized --current-branch run reaches gnhf without the worktree flag"
}

test_unresolvable_project_stops_the_run() {
  run_gnhf --project ghost -- "do the work"
  [ "$RC" -eq 2 ] || fail "an unresolvable project exited $RC, expected 2"
  [ ! -e "$CALL" ] || fail "an unresolvable project still launched gnhf"
  assert_contains "$OUT" "cannot be resolved" "the refusal did not say the project could not be resolved"
  pass "fm-gnhf: an unresolvable project stops before launch"
}

test_unregistered_project_defaults_to_no_mistakes_off() {
  run_gnhf --project extra -- "do the work"
  [ "$RC" -eq 0 ] || fail "an unregistered project failed instead of using the default posture: $RC ($OUT)"
  local record
  record=$(record_path)
  assert_contains "$(cat "$record")" $'mode=no-mistakes\n' "an unregistered project did not default to no-mistakes"
  assert_contains "$(cat "$record")" $'yolo=off\n' "an unregistered project did not default to merge authority off"
  pass "fm-gnhf: an unregistered project defaults to no-mistakes with merge authority off"
}

test_task_status_is_appended() {
  run_gnhf --task t1 --project demo -- "do the work"
  [ "$RC" -eq 0 ] || fail "a --task run failed: $RC ($OUT)"
  assert_contains "$(cat "$HOME_DIR/state/t1.status")" 'working [at=' "the task status log has no live line"
  assert_contains "$(cat "$HOME_DIR/state/t1.status")" 'done [at=' "the task status log has no terminal line"
  pass "fm-gnhf: --task mirrors the run status into the task's status log"
}

test_failed_run_is_recorded() {
  FAKE_RC=7
  run_gnhf --project demo -- "do the work"
  [ "$RC" -eq 7 ] || fail "a failed gnhf run exited $RC, expected the tool's 7"
  assert_contains "$(cat "$(status_path)")" 'failed [at=' "a failed run wrote no failed status line"
  pass "fm-gnhf: a failed run propagates gnhf's exit status and records failure"
}

test_authorization_does_not_reach_the_child() {
  AUTH=push
  run_gnhf --project demo -- --push "do the work"
  [ "$RC" -eq 0 ] || fail "an authorized --push run failed: $RC ($OUT)"
  assert_contains "$(cat "$CALL")" $'run_auth=unset\n' "the per-run authorization reached the gnhf child"
  pass "fm-gnhf: the per-run authorization is unset in the gnhf child's environment"
}

test_termination_stops_the_child_and_records_failure() {
  local out="$TMP_ROOT/terminate.out" pidfile="$TMP_ROOT/terminate.pid"
  local launcher_pid child rc waited status
  rm -rf "$HOME_DIR/state/gnhf" "$out" "$pidfile" "$HOME_DIR/state/t-term.status"
  env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_GNHF_TEST_CALL="$CALL" \
    FM_GNHF_TEST_SLEEP=30 FM_GNHF_TEST_PID="$pidfile" \
    "$LAUNCHER" --task t-term --project demo -- "do the work" >"$out" 2>&1 &
  launcher_pid=$!
  waited=0
  while [ ! -s "$pidfile" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if [ ! -s "$pidfile" ]; then
    kill -TERM "$launcher_pid" 2>/dev/null
    wait "$launcher_pid" 2>/dev/null
    fail "the fake gnhf never recorded its pid"
  fi
  child=$(cat "$pidfile")
  # Let the launcher reach its wait loop and install the termination traps.
  sleep 0.3
  kill -TERM "$launcher_pid"
  wait "$launcher_pid"
  rc=$?
  [ "$rc" -eq 143 ] || fail "a terminated run exited $rc, expected 143"
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null
    fail "the gnhf child was still running after the launcher was terminated"
  fi
  # The state directory was cleared above, so the terminated run's status log is
  # the only match; a literal unexpanded pattern fails the existence check.
  local -a statuses=("$HOME_DIR"/state/gnhf/*.status)
  status=${statuses[0]}
  [ -e "$status" ] || fail "the terminated run wrote no status log"
  assert_contains "$(cat "$status")" 'failed [at=' "a terminated run wrote no terminal status line"
  assert_contains "$(cat "$status")" 'stopped by SIGTERM' "the terminal status did not name the signal"
  assert_contains "$(cat "$HOME_DIR/state/t-term.status")" 'stopped by SIGTERM' "the task status log did not record the termination"
  pass "fm-gnhf: SIGTERM stops the gnhf child and records a terminal status in both logs"
}

test_print_plan_does_not_launch() {
  run_gnhf --project demo --print-plan -- --agent claude "do the work"
  [ "$RC" -eq 0 ] || fail "--print-plan failed: $RC ($OUT)"
  [ ! -e "$CALL" ] || fail "--print-plan still launched gnhf"
  assert_contains "$OUT" "mode=local-only" "--print-plan did not print the resolved mode"
  assert_contains "$OUT" "location=an isolated worktree" "--print-plan did not print the run location"
  local planned
  planned=$(printf '%s\n' "$OUT" | sed -n 's/^record=//p')
  [ -n "$planned" ] || fail "--print-plan did not report the record path"
  [ ! -e "$planned" ] || fail "--print-plan wrote a run record"
  pass "fm-gnhf: --print-plan resolves and reports without launching or recording"
}

fm_test_run \
  test_default_run_forces_worktree_and_records_posture \
  test_current_branch_is_refused_without_authorization \
  test_push_is_refused_without_authorization \
  test_authorized_push_passes_through \
  test_authorized_current_branch_runs_in_the_checkout \
  test_unresolvable_project_stops_the_run \
  test_unregistered_project_defaults_to_no_mistakes_off \
  test_task_status_is_appended \
  test_failed_run_is_recorded \
  test_authorization_does_not_reach_the_child \
  test_termination_stops_the_child_and_records_failure \
  test_print_plan_does_not_launch
