#!/usr/bin/env bash
# Context-ceiling executable behavior and fm-send routing safety.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTEXT="$ROOT/bin/fm-context.sh"
SEND="$ROOT/bin/fm-send.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-ceiling)

make_home() {  # <name> <harness>
  local home="$TMP_ROOT/$1" harness=$2
  mkdir -p "$home/state" "$home/config"
  fm_write_meta "$home/state/task.meta" \
    "window=fake:fm-task" \
    "endpoint_task_id=task" \
    "worktree=$home/worktree" \
    "project=$home/project" \
    "harness=$harness" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off"
  printf '%s\n' "$home"
}

make_stubs() {  # <dir>
  local fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane)
    case " $* " in
      *' -S -12 '*) printf '%s\n' "${FM_CONTEXT_CAPTURE:-}" ;;
      *) printf '╭────╮\n│    │\n╰────╯\n' ;;
    esac
    ;;
  display-message)
    case " $* " in *cursor_y*) printf '1\n' ;; *) printf 'fake-pane\n' ;; esac
    ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    ;;
  list-windows) ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
  printf '%s\n' "$fakebin"
}

run_context() {  # <fakebin> <home> <capture> <args...>
  local fakebin=$1 home=$2 capture=$3
  shift 3
  env PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_CONTEXT_CAPTURE="$capture" \
    "$CONTEXT" "$@"
}

run_send() {  # <fakebin> <home> <capture> <log> <args...>
  local fakebin=$1 home=$2 capture=$3 log=$4
  shift 4
  : > "$log"
  env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTEXT_CAPTURE="$capture" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@"
}

test_readable_under_and_over() {
  local home fakebin out rc
  home=$(make_home readable claude)
  fakebin=$(make_stubs "$home")

  out=$(run_context "$fakebin" "$home" '✦ Opus 5 | [■■□□] 13% | ↯ 130k/1000k | ◆ task' eligible task)
  rc=$?
  expect_code 0 "$rc" "readable under-ceiling session should be eligible"
  assert_contains "$out" 'status=under percent=13 threshold=45 source=footer' \
    "under-ceiling verdict should expose its observed percentage"

  out=$(run_context "$fakebin" "$home" '✦ Opus 5 | [■■□□] 45% | ↯ 450k/1000k | ◆ task' eligible task 2>&1)
  rc=$?
  expect_code 3 "$rc" "readable at-ceiling session should not be eligible"
  assert_contains "$out" 'status=over percent=45 threshold=45 source=footer' \
    "over-ceiling verdict should expose its observed percentage"
  pass "context executable classifies readable under and over sessions"
}

test_unreadable_is_over() {
  local home fakebin out rc
  home=$(make_home unreadable codex)
  fakebin=$(make_stubs "$home")
  out=$(run_context "$fakebin" "$home" 'context: 2% (fake external text)' eligible task 2>&1)
  rc=$?
  expect_code 3 "$rc" "externally unreadable session should not be eligible"
  assert_contains "$out" 'status=over percent=unreadable' \
    "unreadable session should produce an over verdict"
  pass "context executable treats unreadable sessions as over"
}

test_verified_harness_footer_matrix() {
  local home fakebin out rc harness capture expected
  for harness in pi pi-signed kimi; do
    home=$(make_home "matrix-$harness" "$harness")
    fakebin=$(make_stubs "$home")
    case "$harness" in
      pi|pi-signed)
        capture='Opus 4.8 (1M context)   ▍               3%'
        expected='status=under percent=3 threshold=45 source=footer'
        ;;
      kimi)
        capture='context: 46% (118k/256k)'
        expected='status=over percent=46 threshold=45 source=footer'
        ;;
    esac
    out=$(run_context "$fakebin" "$home" "$capture" show task)
    assert_contains "$out" "$expected" "$harness footer should produce its verified verdict"
  done

  for harness in codex opencode grok; do
    home=$(make_home "matrix-$harness" "$harness")
    fakebin=$(make_stubs "$home")
    out=$(run_context "$fakebin" "$home" '13%' eligible task 2>&1)
    rc=$?
    expect_code 3 "$rc" "$harness without a verified external meter should not be eligible"
    assert_contains "$out" 'status=over percent=unreadable' \
      "$harness without a verified external meter should remain unreadable"
  done
  pass "verified harness footer readers are explicit and every other harness stays unreadable"
}

test_self_report_and_configured_threshold() {
  local home fakebin out rc
  home=$(make_home self-report codex)
  fakebin=$(make_stubs "$home")
  printf '20\n' > "$home/config/context-ceiling"
  out=$(env PATH="$fakebin:$PATH" FM_HOME="$home" FM_CONTEXT_STATE_DIR="$home/state" \
    FM_CONTEXT_TASK_ID=task "$CONTEXT" self-report 19)
  assert_contains "$out" 'self_reported=19' "self-report command should publish its value"
  out=$(run_context "$fakebin" "$home" '' eligible task)
  rc=$?
  expect_code 0 "$rc" "fresh self-report below configured threshold should be eligible"
  assert_contains "$out" 'status=under percent=19 threshold=20 source=self-report' \
    "self-report verdict should use the configured threshold"
  pass "context executable accepts a fresh task-bound self-report"
}

test_invalid_config_fails_closed() {
  local home fakebin out rc
  home=$(make_home invalid-config claude)
  fakebin=$(make_stubs "$home")
  printf '45\nextra\n' > "$home/config/context-ceiling"
  out=$(run_context "$fakebin" "$home" '✦ Opus 5 | [■■□□] 2% | ↯ 20k/1000k | ◆ task' eligible task 2>&1)
  rc=$?
  expect_code 3 "$rc" "invalid context config should never become eligible"
  assert_contains "$out" 'status=over percent=unreadable threshold=invalid source=config-error' \
    "invalid context config should produce a visible fail-closed verdict"
  pass "invalid context config never silently reads as safe"
}

test_new_work_gate_and_operational_bypass() {
  local home fakebin log out rc over under
  home=$(make_home send claude)
  fakebin=$(make_stubs "$home")
  log="$home/send.log"
  over='✦ Opus 5 | [■■□□] 61% | ↯ 610k/1000k | ◆ task'
  under='✦ Opus 5 | [■■□□] 12% | ↯ 120k/1000k | ◆ task'

  out=$(run_send "$fakebin" "$home" "$over" "$log" task 'STOP: preserve the signed application' 2>&1)
  rc=$?
  expect_code 0 "$rc" "operational message must pass while target is over-ceiling"
  [ "$(cat "$log")" = 'STOP: preserve the signed application' ] \
    || fail "operational message did not reach the over-ceiling target"

  out=$(run_send "$fakebin" "$home" "$over" "$log" task --new-work 'start another task' 2>&1)
  rc=$?
  expect_code 1 "$rc" "explicit new work should be refused while target is over-ceiling"
  [ ! -s "$log" ] || fail "refused new work was typed into the target"
  assert_contains "$out" 'new work refused' "new-work refusal should be loud"

  out=$(run_send "$fakebin" "$home" "$under" "$log" task --new-work 'start another task' 2>&1)
  rc=$?
  expect_code 0 "$rc" "explicit new work should pass for an under-ceiling target"
  [ "$(cat "$log")" = 'start another task' ] || fail "eligible new work did not reach the target"
  pass "fm-send gates only explicit new work and never blocks operational text"
}

test_help_surfaces() {
  "$CONTEXT" --help | grep -F 'self-report <percent>' >/dev/null \
    || fail "fm-context --help omitted self-report"
  "$SEND" --help | grep -F '[--new-work]' >/dev/null \
    || fail "fm-send --help omitted --new-work"
  pass "changed executable help surfaces describe their behavior"
}

test_session_start_surfaces_verdict() {
  local home out
  home=$(make_home session-start codex)
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$SESSION_START")
  assert_contains "$out" 'CONTEXT_CEILING id=task status=over percent=unreadable' \
    "session-start fleet digest should surface the context verdict"
  pass "session-start fleet digest surfaces context without being asked"
}

test_heartbeat_surfaces_new_over_verdict() {
  local home out pid i=0
  home=$(make_home heartbeat codex)
  out="$home/watch.out"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_POLL=0.2 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 "$WATCH" > "$out" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "heartbeat did not surface the over-ceiling verdict"
  fi
  wait "$pid" 2>/dev/null || true
  grep -F 'context-ceiling: CONTEXT_CEILING id=task status=over percent=unreadable' "$out" >/dev/null \
    || fail "heartbeat wake omitted the context verdict: $(cat "$out")"
  grep "$(printf '\theartbeat\tcontext-ceiling\t')" "$home/state/.wake-queue" >/dev/null \
    || fail "heartbeat did not durably queue its context finding"
  pass "heartbeat review surfaces a newly over-ceiling session"
}

test_readable_under_and_over
test_unreadable_is_over
test_verified_harness_footer_matrix
test_self_report_and_configured_threshold
test_invalid_config_fails_closed
test_new_work_gate_and_operational_bypass
test_help_surfaces
test_session_start_surfaces_verdict
test_heartbeat_surfaces_new_over_verdict

echo '# all fm-context-ceiling tests passed'
