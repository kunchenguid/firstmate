#!/usr/bin/env bash
# Behavioral coverage for confirmed terminal worker automatic cleanup.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTO_CLOSE="$ROOT/bin/fm-auto-close.sh"
DONE_STATE=$(printf '%s' 'done')
TMP_ROOT=$(fm_test_tmproot fm-auto-close)

make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  HOME_DIR="$WORLD/home"
  STATE="$HOME_DIR/state"
  FAKE="$WORLD/fakebin"
  mkdir -p "$STATE" "$HOME_DIR/data" "$FAKE"
  : > "$WORLD/control.log"
  : > "$WORLD/teardown.log"
  cat > "$FAKE/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: fake\n' "${FM_FAKE_STATE:-unknown}"
SH
  cat > "$FAKE/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_CONTROL_LOG:?}"
exit "${FM_CONTROL_RC:-0}"
SH
  cat > "$FAKE/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEARDOWN_LOG:?}"
exit "${FM_TEARDOWN_RC:-0}"
SH
  chmod +x "$FAKE"/*
}

write_task() { # <kind> <status> [spawn-gen]
  local kind=$1 status=$2 spawn=${3:-spawn-one}
  fm_write_meta "$STATE/task.meta" \
    'window=firstmate:fm-task' 'endpoint_task_id=task' \
    'worktree=/tmp/task' 'project=/tmp/project' 'harness=codex' \
    "kind=$kind" 'mode=direct-PR' "spawn_gen=$spawn"
  printf '%s\n' "$status" > "$STATE/task.status"
}

run_auto() { # <mode>
  PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_AUTO_CLOSE_CREW_STATE_BIN="$FAKE/fm-crew-state.sh" \
    FM_AUTO_CLOSE_CONTROL_BIN="$FAKE/fm-control.sh" \
    FM_AUTO_CLOSE_TEARDOWN_BIN="$FAKE/fm-teardown.sh" \
    FM_CONTROL_LOG="$WORLD/control.log" FM_TEARDOWN_LOG="$WORLD/teardown.log" \
    FM_CONTROL_RC="${FM_CONTROL_RC:-0}" FM_TEARDOWN_RC="${FM_TEARDOWN_RC:-0}" \
    "$AUTO_CLOSE" "$1" task
}

assert_quiet() {
  [ ! -s "$WORLD/control.log" ] || fail "$1 sent worker control"
  [ ! -s "$WORLD/teardown.log" ] || fail "$1 attempted cleanup"
  [ ! -e "$STATE/task.auto-close" ] || fail "$1 wrote cleanup receipt"
}

test_confirmed_terminal_stops_then_cleans() {
  make_world terminal
  write_task ship 'done: PR https://example.test/o/r/pull/1'
  FM_FAKE_STATE=$DONE_STATE
  export FM_FAKE_STATE
  run_auto maybe
  [ "$(cat "$WORLD/control.log")" = 'task exit' ] || fail "terminal worker was not exited exactly once"
  [ "$(cat "$WORLD/teardown.log")" = 'task --auto-terminal' ] || fail "terminal worker was not cleaned through auto-terminal teardown"
  grep -Fxq 'terminal_state=done' "$STATE/task.auto-close" || fail "terminal receipt missing"
  pass "confirmed terminal worker exits before safe cleanup"
}

test_active_ambiguous_and_open_work_stay_untouched() {
  local label kind status state
  for label in working unknown held secondmate; do
    make_world "$label"
    kind=ship
    status='done: terminal'
    state=$DONE_STATE
    case "$label" in
      working) status='working: active'; state=working ;;
      unknown) state=unknown ;;
      held) status=$'blocked [key=choice]: need answer\ndone: terminal' ;;
      secondmate) kind=secondmate ;;
    esac
    write_task "$kind" "$status"
    FM_FAKE_STATE="$state" run_auto maybe
    assert_quiet "$label"
  done
  pass "active, ambiguous, captain-held, and secondmate work is untouched"
}

test_changed_status_after_exit_refuses_receipt() {
  make_world changed-status
  write_task ship 'done: terminal'
  cat > "$FAKE/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_CONTROL_LOG:?}"
printf 'working: replacement resumed\n' >> "${FM_STATE_OVERRIDE:?}/task.status"
SH
  chmod +x "$FAKE/fm-control.sh"
  FM_FAKE_STATE="${DONE_STATE}"
  export FM_FAKE_STATE
  run_auto maybe
  [ "$(cat "$WORLD/control.log")" = 'task exit' ] || fail "changed-status case did not exit worker"
  [ ! -s "$WORLD/teardown.log" ] || fail "changed status reached cleanup"
  [ ! -e "$STATE/task.auto-close" ] || fail "changed status received cleanup receipt"
  pass "status change after exit prevents automatic cleanup"
}

test_receipt_retry_uses_teardown_owner() {
  make_world retry
  write_task ship 'failed: terminal'
  FM_TEARDOWN_RC=1 FM_FAKE_STATE='failed' run_auto maybe >/dev/null 2>&1 || true
  : > "$WORLD/teardown.log"
  FM_TEARDOWN_RC=0 run_auto finish
  [ "$(cat "$WORLD/teardown.log")" = 'task --auto-terminal' ] || fail "receipt retry bypassed teardown owner"
  pass "failed cleanup remains safely retryable from receipt"
}

test_confirmed_terminal_stops_then_cleans
test_active_ambiguous_and_open_work_stay_untouched
test_changed_status_after_exit_refuses_receipt
test_receipt_retry_uses_teardown_owner

echo "all fm-auto-close tests passed"
