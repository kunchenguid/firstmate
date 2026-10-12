#!/usr/bin/env bash
# Executable-interface coverage for opt-in terminal worker exit and safe cleanup.
# shellcheck disable=SC1010  # fixture states include the shell keyword "done"
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLEANUP="$ROOT/bin/fm-terminal-worker-cleanup.sh"
TMP_ROOT=$(fm_test_tmproot fm-terminal-worker-cleanup)

make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  HOME_DIR="$WORLD/home"
  mkdir -p "$HOME_DIR"/{state,data,config,projects} "$WORLD/bin"
  cat > "$WORLD/bin/state" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: fake\n' "${FM_FAKE_STATE:-unknown}"
SH
  cat > "$WORLD/bin/control" <<'SH'
#!/usr/bin/env bash
printf 'control %s %s\n' "$1" "$2" >> "$FM_FAKE_LOG"
exit "${FM_FAKE_CONTROL_RC:-0}"
SH
  cat > "$WORLD/bin/teardown" <<'SH'
#!/usr/bin/env bash
printf 'teardown %s\n' "$1" >> "$FM_FAKE_LOG"
rc=${FM_FAKE_TEARDOWN_RC:-0}
if [ "$rc" -eq 0 ] && [ "${FM_FAKE_TEARDOWN_REMOVE:-0}" = 1 ]; then
  rm -f "$FM_STATE_OVERRIDE/$1.meta" "$FM_STATE_OVERRIDE/$1.status"
fi
exit "$rc"
SH
  chmod +x "$WORLD/bin"/*
  : > "$WORLD/log"
}

write_task() { # <id> <kind> <worktree>
  local id=$1 kind=$2 worktree=$3
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "kind=$kind" "backend=tmux" "harness=codex" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$worktree" "project=$HOME_DIR/projects/sample"
  printf 'done: finished\n' > "$HOME_DIR/state/$id.status"
}

run_cleanup() { # <id>
  local id=$1
  PATH="$WORLD/bin:$PATH" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_LOG="$WORLD/log" \
    FM_TERMINAL_WORKER_STATE_BIN="$WORLD/bin/state" \
    FM_TERMINAL_WORKER_CONTROL_BIN="$WORLD/bin/control" \
    FM_TERMINAL_WORKER_TEARDOWN_BIN="$WORLD/bin/teardown" \
    "$CLEANUP" "$id"
}

log_count() { grep -c "$1" "$WORLD/log" 2>/dev/null || true; }

assert_followup() { # <id> <phase> <reason>
  local id=$1 phase=$2 reason=$3 report
  report="$HOME_DIR/state/terminal-worker-cleanup/$id.pending"
  [ -f "$report" ] || fail "$id: durable cleanup follow-up is missing"
  grep -Fxq "phase=$phase" "$report" || fail "$id: follow-up phase is not $phase"
  grep -Fq "$reason" "$report" || fail "$id: follow-up did not preserve the reason"
  grep -Fxq 'artifact=/preserved/copy' "$report" || fail "$id: follow-up did not name the preserved copy"
  grep -Fxq 'follow_up=land the preserved copy or explicitly discard it, then retry cleanup' "$report" \
    || fail "$id: follow-up did not state how to resume"
}

test_default_is_unchanged() {
  make_world default-off
  write_task default-task ship /preserved/copy
  FM_FAKE_STATE=done run_cleanup default-task >/dev/null
  [ ! -s "$WORLD/log" ] || fail "default-off home controlled a worker"
  [ ! -f "$HOME_DIR/state/terminal-worker-cleanup/default-task.pending" ] \
    || fail "default-off home created a cleanup follow-up"
  pass "automatic temporary-worker exit remains off by default"
}

test_clean_landed_completion_exits_before_cleanup() {
  make_world clean
  : > "$HOME_DIR/config/auto-exit-temporary-workers"
  write_task clean-task ship /preserved/copy
  FM_FAKE_STATE=done FM_FAKE_TEARDOWN_REMOVE=1 run_cleanup clean-task >/dev/null
  [ "$(sed -n '1p' "$WORLD/log")" = 'control clean-task exit' ] \
    || fail "clean completion did not stop the worker first"
  [ "$(sed -n '2p' "$WORLD/log")" = 'teardown clean-task' ] \
    || fail "clean completion did not attempt safe cleanup second"
  [ ! -e "$HOME_DIR/state/terminal-worker-cleanup/clean-task.pending" ] \
    || fail "successful cleanup left its follow-up"
  pass "clean landed completion exits before safe cleanup"
}

test_dirty_completion_preserves_followup() {
  make_world dirty
  : > "$HOME_DIR/config/auto-exit-temporary-workers"
  write_task dirty-task ship /preserved/copy
  FM_FAKE_STATE=done FM_FAKE_TEARDOWN_RC=1 \
    FM_FAKE_TEARDOWN_REMOVE=0 run_cleanup dirty-task >/dev/null
  [ "$(sed -n '1p' "$WORLD/log")" = 'control dirty-task exit' ] \
    || fail "dirty completion did not stop the worker before refusal"
  assert_followup dirty-task cleanup-refused 'safe artifact cleanup was refused after exit: '
  pass "dirty completion stops the worker and preserves an actionable follow-up"
}

test_unlanded_completion_preserves_copy() {
  make_world unlanded
  : > "$HOME_DIR/config/auto-exit-temporary-workers"
  write_task unlanded-task ship /preserved/copy
  FM_FAKE_STATE=done FM_FAKE_TEARDOWN_RC=1 \
    FM_FAKE_TEARDOWN_REMOVE=0 run_cleanup unlanded-task >/dev/null
  FM_FAKE_TEARDOWN_RC=1 FM_FAKE_CONTROL_RC=0 \
    FM_FAKE_STATE=done run_cleanup unlanded-task >/dev/null
  assert_followup unlanded-task cleanup-refused 'safe artifact cleanup was refused after exit: '
  [ "$(log_count 'control unlanded-task exit')" -eq 2 ] || fail "unlanded retry did not re-run idempotent exit"
  pass "unlanded completion remains preserved across a cleanup retry"
}

test_parked_and_blocked_need_separate_opt_in() {
  local state
  for state in parked blocked; do
    make_world "$state"
    : > "$HOME_DIR/config/auto-exit-temporary-workers"
    write_task "$state-task" ship /preserved/copy
    FM_FAKE_STATE="$state" run_cleanup "$state-task" >/dev/null
    [ ! -s "$WORLD/log" ] || fail "$state without its separate flag controlled a worker"
    : > "$HOME_DIR/config/auto-exit-$state-workers"
    FM_FAKE_STATE="$state" FM_FAKE_TEARDOWN_REMOVE=1 run_cleanup "$state-task" >/dev/null
    [ "$(log_count "control $state-task exit")" -eq 1 ] || fail "$state separate opt-in did not exit the worker"
  done
  pass "parked and blocked workers require separate opt-ins"
}

test_failed_completion_exits() {
  make_world failed
  : > "$HOME_DIR/config/auto-exit-temporary-workers"
  write_task failed-task ship /preserved/copy
  FM_FAKE_STATE=failed FM_FAKE_TEARDOWN_REMOVE=1 run_cleanup failed-task >/dev/null
  [ "$(sed -n '1p' "$WORLD/log")" = 'control failed-task exit' ] || fail "failed outcome did not exit"
  [ "$(sed -n '2p' "$WORLD/log")" = 'teardown failed-task' ] || fail "failed outcome did not clean up"
  pass "failed outcome exits before cleanup"
}

test_missing_and_uncertain_records_are_retained() {
  make_world missing
  : > "$HOME_DIR/config/auto-exit-temporary-workers"
  printf 'done: evidence\n' > "$HOME_DIR/state/missing-task.status"
  FM_FAKE_STATE=done run_cleanup missing-task >/dev/null
  report="$HOME_DIR/state/terminal-worker-cleanup/missing-task.pending"
  [ -f "$report" ] || fail "missing-task: durable cleanup follow-up is missing"
  grep -Fxq 'phase=uncertain' "$report" || fail "missing-task: missing record was not uncertain"
  grep -Fxq 'artifact=' "$report" || fail "missing-task: missing record did not preserve an empty artifact field"
  grep -Fq 'task metadata is missing' "$report" || fail "missing-task: missing record did not name the reconciliation action"
  [ ! -s "$WORLD/log" ] || fail "missing metadata reached a lifecycle command"

  write_task uncertain-task ship /preserved/copy
  FM_FAKE_STATE=unknown run_cleanup uncertain-task >/dev/null
  assert_followup uncertain-task uncertain 'current worker state is uncertain'
  [ "$(log_count 'uncertain-task')" -eq 0 ] || fail "uncertain state reached a lifecycle command"
  pass "missing and uncertain records preserve evidence without lifecycle mutation"
}

test_duplicate_notifications_are_idempotent() {
  make_world duplicate
  : > "$HOME_DIR/config/auto-exit-temporary-workers"
  write_task duplicate-task ship /preserved/copy
  FM_FAKE_STATE=done FM_FAKE_TEARDOWN_REMOVE=1 run_cleanup duplicate-task >/dev/null
  FM_FAKE_STATE=done FM_FAKE_TEARDOWN_REMOVE=1 run_cleanup duplicate-task >/dev/null
  [ "$(log_count 'control duplicate-task exit')" -eq 1 ] || fail "duplicate notification repeated worker exit"
  [ "$(log_count 'teardown duplicate-task')" -eq 1 ] || fail "duplicate notification repeated cleanup"
  pass "duplicate terminal notifications converge without duplicate outcomes"
}

test_retry_after_cleanup_refusal() {
  make_world retry
  : > "$HOME_DIR/config/auto-exit-temporary-workers"
  write_task retry-task ship /preserved/copy
  FM_FAKE_STATE=done FM_FAKE_TEARDOWN_RC=1 run_cleanup retry-task >/dev/null
  assert_followup retry-task cleanup-refused 'safe artifact cleanup was refused after exit: '
  FM_FAKE_STATE=done FM_FAKE_TEARDOWN_RC=0 FM_FAKE_TEARDOWN_REMOVE=1 \
    run_cleanup retry-task >/dev/null
  [ "$(log_count 'control retry-task exit')" -eq 2 ] || fail "cleanup retry did not recheck exit"
  [ "$(log_count 'teardown retry-task')" -eq 2 ] || fail "cleanup retry did not retry safe cleanup"
  [ ! -e "$HOME_DIR/state/terminal-worker-cleanup/retry-task.pending" ] \
    || fail "successful cleanup retry left the follow-up"
  pass "cleanup refusal is retried after the worker has already exited"
}

test_persistent_secondmate_is_excluded() {
  make_world secondmate
  : > "$HOME_DIR/config/auto-exit-temporary-workers"
  fm_write_secondmate_meta "$HOME_DIR/state/mate.meta" "$HOME_DIR"
  printf 'done: child report\n' > "$HOME_DIR/state/mate.status"
  FM_FAKE_STATE=done run_cleanup mate >/dev/null
  [ ! -s "$WORLD/log" ] || fail "persistent secondmate was controlled as temporary work"
  pass "persistent secondmates remain alive and outside temporary cleanup"
}

test_default_is_unchanged
test_clean_landed_completion_exits_before_cleanup
test_dirty_completion_preserves_followup
test_unlanded_completion_preserves_copy
test_parked_and_blocked_need_separate_opt_in
test_failed_completion_exits
test_missing_and_uncertain_records_are_retained
test_duplicate_notifications_are_idempotent
test_retry_after_cleanup_refusal
test_persistent_secondmate_is_excluded
