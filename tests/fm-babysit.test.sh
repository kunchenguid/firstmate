#!/usr/bin/env bash
# Behavior tests for bin/fm-babysit.sh, the worker-side long-command wrapper.
#
# A worker wraps a command that outlasts its host harness's tool timeout so the
# completion is turned into one durable steering message through fm-send.sh,
# whose inbox doorbell then wakes the worker instead of a polling sleep loop.
# bin/fm-babysit.sh owns that contract; this suite pins it end to end:
# foreground execution with stdout/stderr captured to a printed log path, exit
# mirroring with a send attempt always preceding a 0 exit, the completion
# statuses (completed, failed, signaled, timed-out, interrupted), process-group
# cleanup on timeout with no orphaned grandchildren, --fm-home precedence over
# FM_HOME with a loud refusal when neither is set, the bounded tail in the
# message, exactly one send retry with a pane-visible fallback line on double
# failure, one real delivery through the sibling fm-send.sh into a fixture
# home, the portable mktemp suffix on the default log path, KILL coverage for
# TERM-resistant descendants on timeout, a single interrupt against a
# TERM-ignoring child, and the monitor-mode group isolation used where setsid
# is unavailable.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BABYSIT="$ROOT/bin/fm-babysit.sh"

TMP=$(fm_test_tmproot fm-babysit)

# make_send_shim <dir> -> echoes a fake FM_BABYSIT_SEND that records every
# invocation (one count line plus the task id, the FM_HOME it saw, and the
# message body) and exits with the code in <dir>/send-exit (default 0).
make_send_shim() {
  local dir=$1
  mkdir -p "$dir"
  : > "$dir/sendlog"
  printf '0\n' > "$dir/send-exit"
  cat > "$dir/fake-send.sh" <<SH
#!/usr/bin/env bash
printf 'call\n' >> "$dir/sendlog"
printf 'task=%s\n' "\$1" >> "$dir/sendlog"
printf 'home=%s\n' "\$FM_HOME" >> "$dir/sendlog"
printf '%s\n' "\$2" >> "$dir/sendlog"
exit "\$(cat "$dir/send-exit")"
SH
  chmod +x "$dir/fake-send.sh"
  printf '%s\n' "$dir/fake-send.sh"
}

send_calls() {
  grep -c '^call$' "$1/sendlog" 2>/dev/null || true
}

# run_babysit <case-dir> [babysit-args...]: run the wrapper with a recording
# send shim already in place. Echoes combined output; returns its exit code.
run_babysit() {
  local dir=$1
  shift
  env FM_BABYSIT_SEND="$dir/fake-send.sh" FM_HOME="$dir/home" \
    "FM_BABYSIT_KILL_GRACE=${FM_BABYSIT_KILL_GRACE:-5}" \
    "FM_BABYSIT_NO_SETSID=${FM_BABYSIT_NO_SETSID:-}" "$BABYSIT" "$@" 2>&1
}

test_success_sends_one_message_with_log_and_tail() {
  local dir out rc log msg
  dir="$TMP/success"
  mkdir -p "$dir/home"
  make_send_shim "$dir" >/dev/null
  out=$(run_babysit "$dir" --tail 5 t1 -- sh -c 'echo hello-out; echo hello-err >&2'); rc=$?
  expect_code 0 "$rc" "a succeeding child must exit 0"
  assert_equals 1 "$(send_calls "$dir")" "a completion must send exactly one message"
  assert_contains "$out" "log: " "the log path must be printed at start"
  log=$(printf '%s\n' "$out" | sed -n 's/.*log: //p' | head -n 1)
  assert_present "$log" "the printed log path must exist"
  assert_grep "hello-out" "$log" "stdout must be captured to the log"
  assert_grep "hello-err" "$log" "stderr must be captured to the log"
  msg=$(cat "$dir/sendlog")
  assert_contains "$msg" "completed ok" "the message must report the completed status"
  assert_contains "$msg" "exit 0" "the message must report the exit code"
  assert_contains "$msg" "elapsed " "the message must report the elapsed time"
  assert_contains "$msg" "$log" "the message must report the log path"
  assert_contains "$msg" "hello-out" "the message must carry the log tail"
  assert_contains "$out" "notified task t1" "the pane must confirm the notification"
  pass "success sends one message with log path, exit, elapsed, and tail"
}

test_failure_mirrors_child_exit_code() {
  local dir out rc
  dir="$TMP/failure"
  mkdir -p "$dir/home"
  make_send_shim "$dir" >/dev/null
  out=$(run_babysit "$dir" t1 -- sh -c 'echo oops; exit 3'); rc=$?
  expect_code 3 "$rc" "the wrapper must exit with the child code"
  assert_equals 1 "$(send_calls "$dir")" "a failure must still send exactly one message"
  assert_contains "$(cat "$dir/sendlog")" "failed" "the message must report the failed status"
  assert_contains "$(cat "$dir/sendlog")" "exit 3" "the message must report the child exit code"
  assert_contains "$out" "notified task t1" "the pane must confirm the notification"
  pass "failure mirrors the child exit code after the send attempt"
}

test_signaled_child_reports_signal() {
  local dir out rc
  dir="$TMP/signaled"
  mkdir -p "$dir/home"
  make_send_shim "$dir" >/dev/null
  out=$(run_babysit "$dir" t1 -- sh -c 'kill -TERM $$'); rc=$?
  expect_code 143 "$rc" "a SIGTERM death must mirror 128+15"
  assert_contains "$(cat "$dir/sendlog")" "killed by signal TERM" "the message must report the killing signal"
  assert_contains "$out" "notified task t1" "the pane must confirm the notification"
  pass "a signaled child is reported as killed by that signal"
}

test_timeout_kills_process_group_without_orphans() {
  local dir out rc grandchild
  dir="$TMP/timeout"
  mkdir -p "$dir/home"
  make_send_shim "$dir" >/dev/null
  rm -f "$dir/grandchild.pid"
  # shellcheck disable=SC2016 # $! and $1 expand in the child shell, not here.
  out=$(FM_BABYSIT_KILL_GRACE=1 run_babysit "$dir" --timeout 2 t1 -- \
    sh -c 'sleep 60 & echo $! > "$1"/grandchild.pid; echo started; wait' _ "$dir"); rc=$?
  expect_code 124 "$rc" "a timed-out child must exit 124"
  assert_contains "$(cat "$dir/sendlog")" "timed out after 2s" "the message must report the timeout status"
  assert_contains "$(cat "$dir/sendlog")" "exit 124" "the message must report exit 124"
  assert_contains "$(cat "$dir/sendlog")" "started" "the message must carry the log tail"
  grandchild=$(cat "$dir/grandchild.pid")
  if kill -0 "$grandchild" 2>/dev/null; then
    fail "the timed-out process group must leave no orphaned grandchild (pid $grandchild alive)"
  fi
  pass "timeout kills the whole process group, reports timed-out, and leaves no orphan"
}

test_missing_home_is_refused_loudly() {
  local dir out rc
  dir="$TMP/nohome"
  mkdir -p "$dir/home"
  make_send_shim "$dir" >/dev/null
  out=$(env -u FM_HOME "$BABYSIT" t1 -- true 2>&1); rc=$?
  assert_not_equals 0 "$rc" "a missing send home must refuse"
  assert_contains "$out" "--fm-home" "the refusal must name the --fm-home flag"
  assert_contains "$out" "FM_HOME" "the refusal must name FM_HOME"
  assert_equals 0 "$(send_calls "$dir")" "a refused run must send nothing"
  pass "a missing send home is refused loudly before anything runs"
}

test_fm_home_flag_beats_ambient_environment() {
  local dir out rc
  dir="$TMP/flaghome"
  mkdir -p "$dir/home" "$dir/elsewhere"
  make_send_shim "$dir" >/dev/null
  out=$(env FM_BABYSIT_SEND="$dir/fake-send.sh" FM_HOME="$dir/elsewhere" \
    "$BABYSIT" --fm-home "$dir/home" t1 -- true 2>&1); rc=$?
  expect_code 0 "$rc" "the flag-home run must succeed"
  assert_contains "$(cat "$dir/sendlog")" "home=$dir/home" "the send must use the --fm-home home, not FM_HOME"
  assert_contains "$out" "notified task t1" "the pane must confirm the notification"
  pass "--fm-home takes precedence over the ambient FM_HOME"
}

test_tail_bound_keeps_only_recent_lines() {
  local dir
  dir="$TMP/tailbound"
  mkdir -p "$dir/home"
  make_send_shim "$dir" >/dev/null
  # shellcheck disable=SC2016 # $i expands in the child shell, not here.
  run_babysit "$dir" --tail 3 t1 -- sh -c 'i=1; while [ "$i" -le 100 ]; do echo "marker-line-$i"; i=$((i + 1)); done' >/dev/null 2>&1
  assert_contains "$(cat "$dir/sendlog")" "--- last 3 lines" "the message must state the tail bound"
  assert_contains "$(cat "$dir/sendlog")" "marker-line-100" "the tail must include the most recent lines"
  if grep -qx 'marker-line-1' "$dir/sendlog"; then
    fail "the bounded tail must not carry the first log lines"
  fi
  pass "the message tail is bounded to the most recent lines"
}

test_double_send_failure_prints_fallback_and_retries_once() {
  local dir out rc
  dir="$TMP/fallback"
  mkdir -p "$dir/home"
  make_send_shim "$dir" >/dev/null
  printf '1\n' > "$dir/send-exit"
  out=$(run_babysit "$dir" t1 -- sh -c 'echo hi'); rc=$?
  expect_code 0 "$rc" "the wrapper still exits with the child code after a lost notification"
  assert_equals 2 "$(send_calls "$dir")" "the send must be retried exactly once"
  assert_contains "$out" "FAILED to notify task t1" "the pane must show the fallback line"
  assert_contains "$out" "send failed twice" "the fallback must say both attempts failed"
  assert_contains "$out" "log: " "the fallback must keep the log path observable"
  pass "a double send failure retries once, then prints one fallback line and writes nothing else"
}

test_flaky_send_succeeds_on_retry() {
  local dir out rc
  dir="$TMP/flaky"
  mkdir -p "$dir/home"
  cat > "$dir/fake-send.sh" <<SH
#!/usr/bin/env bash
n=\$(cat "$dir/attempts" 2>/dev/null || echo 0)
echo \$((n + 1)) > "$dir/attempts"
[ "\$n" -ge 1 ] && exit 0 || exit 1
SH
  chmod +x "$dir/fake-send.sh"
  echo 0 > "$dir/attempts"
  out=$(env FM_BABYSIT_SEND="$dir/fake-send.sh" FM_HOME="$dir/home" \
    "$BABYSIT" t1 -- true 2>&1); rc=$?
  expect_code 0 "$rc" "a retry success must exit 0"
  assert_equals 2 "$(cat "$dir/attempts")" "the send must be attempted exactly twice"
  assert_contains "$out" "notified task t1" "the pane must confirm the notification"
  pass "a first-attempt send failure is retried once and then notified"
}

test_real_send_reaches_the_fixture_home_inbox() {
  local dir out rc msg
  dir="$TMP/real-send"
  mkdir -p "$dir/home/state" "$dir/home/data/t1" "$dir/fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/tmux"
  chmod +x "$dir/fakebin/tmux"
  fm_write_meta "$dir/home/state/t1.meta" \
    "window=fmses:fm-t1" \
    "endpoint_task_id=t1" \
    "worktree=$dir" \
    "project=$dir" \
    "harness=claude" \
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=off" \
    "model=default" \
    "effort=default"
  out=$(env -u FM_BABYSIT_SEND PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    "$BABYSIT" t1 -- sh -c 'echo real-delivery' 2>&1); rc=$?
  expect_code 0 "$rc" "the real-send run must succeed"
  assert_present "$dir/home/state/t1.inbox/001.msg" "the real fm-send.sh must record one inbox message"
  msg=$(cat "$dir/home/state/t1.inbox/001.msg")
  assert_contains "$msg" "completed ok" "the inbox record must carry the completion status"
  assert_contains "$msg" "real-delivery" "the inbox record must carry the log tail"
  assert_contains "$out" "notified task t1" "the pane must confirm the notification"
  pass "the default send path delivers one durable message through the real fm-send.sh"
}

test_default_log_uses_portable_mktemp_suffix() {
  local dir out rc log
  dir="$TMP/portable-log"
  mkdir -p "$dir/home"
  make_send_shim "$dir" >/dev/null
  out=$(run_babysit "$dir" t1 -- sh -c 'echo portable-mktemp-probe'); rc=$?
  expect_code 0 "$rc" "the default-log run must succeed"
  log=$(printf '%s\n' "$out" | sed -n 's/.*log: //p' | head -n 1)
  case "$log" in
    *.log.??????) : ;;
    *) fail "the default log path must keep the mktemp Xs last (portable form), got: $log" ;;
  esac
  assert_present "$log" "the portable-suffix log file must exist"
  assert_grep "portable-mktemp-probe" "$log" "the log must capture the child output"
  pass "the default log path uses the portable mktemp suffix form"
}

test_timeout_kills_term_resistant_grandchild() {
  local dir out rc grandchild
  dir="$TMP/timeout-resistant"
  mkdir -p "$dir/home"
  make_send_shim "$dir" >/dev/null
  rm -f "$dir/grandchild.pid"
  # shellcheck disable=SC2016 # $! and $1 expand in the child shell, not here.
  out=$(FM_BABYSIT_KILL_GRACE=1 run_babysit "$dir" --timeout 2 t1 -- \
    sh -c 'trap "" TERM; sleep 60 & echo $! > "$1"/grandchild.pid; echo started; wait' _ "$dir"); rc=$?
  expect_code 124 "$rc" "a timed-out run must exit 124 even when descendants ignore TERM"
  assert_contains "$(cat "$dir/sendlog")" "timed out after 2s" "the message must report the timeout status"
  grandchild=$(cat "$dir/grandchild.pid")
  if kill -0 "$grandchild" 2>/dev/null; then
    fail "the KILL phase must reach a TERM-resistant grandchild (pid $grandchild alive)"
  fi
  pass "timeout KILLs the recorded group even when descendants ignore TERM"
}

test_single_interrupt_kills_term_ignoring_child() {
  local dir child wrapper tries
  dir="$TMP/single-interrupt"
  mkdir -p "$dir/home"
  make_send_shim "$dir" >/dev/null
  rm -f "$dir/child.pid"
  # shellcheck disable=SC2016 # $$ expands in the child shell, not here.
  env FM_BABYSIT_SEND="$dir/fake-send.sh" FM_HOME="$dir/home" FM_BABYSIT_KILL_GRACE=1 \
    "$BABYSIT" t1 -- sh -c 'echo $$ > "$1"/child.pid; trap "" TERM; exec sleep 60' _ "$dir" \
    >"$dir/int.out" 2>&1 &
  wrapper=$!
  sleep 0.5
  kill -TERM "$wrapper"
  tries=0
  while kill -0 "$wrapper" 2>/dev/null && [ "$tries" -lt 100 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if kill -0 "$wrapper" 2>/dev/null; then
    fail "one interrupt must terminate the wrapper even when the child ignores TERM"
  fi
  wait "$wrapper"; rc=$?
  expect_code 143 "$rc" "an interrupted wrapper must exit 143"
  assert_equals 1 "$(send_calls "$dir")" "the interrupt must send exactly one message"
  assert_contains "$(cat "$dir/sendlog")" "interrupted by SIGTERM" "the message must report the interruption"
  child=$(cat "$dir/child.pid")
  if kill -0 "$child" 2>/dev/null; then
    fail "the interrupted run must leave no TERM-ignoring child behind (pid $child alive)"
  fi
  pass "one interrupt drives the full terminate primitive and still notifies"
}

test_setsid_fallback_still_isolates_group() {
  local dir out rc grandchild
  dir="$TMP/nosetsid"
  mkdir -p "$dir/home"
  make_send_shim "$dir" >/dev/null
  rm -f "$dir/grandchild.pid"
  # shellcheck disable=SC2016 # $! and $1 expand in the child shell, not here.
  out=$(FM_BABYSIT_KILL_GRACE=1 FM_BABYSIT_NO_SETSID=1 run_babysit "$dir" --timeout 2 t1 -- \
    sh -c 'sleep 60 & echo $! > "$1"/grandchild.pid; echo started; wait' _ "$dir"); rc=$?
  expect_code 124 "$rc" "the monitor-mode fallback must still time out cleanly"
  assert_contains "$(cat "$dir/sendlog")" "timed out after 2s" "the fallback run must still notify"
  grandchild=$(cat "$dir/grandchild.pid")
  if kill -0 "$grandchild" 2>/dev/null; then
    fail "the monitor-mode fallback must leave no orphaned grandchild (pid $grandchild alive)"
  fi
  pass "the setsid fallback still isolates the child group and notifies"
}

test_backgrounded_wrapper_leaves_no_orphan_on_timeout() {
  local dir wrapper grandchild
  dir="$TMP/bg-timeout"
  mkdir -p "$dir/home"
  make_send_shim "$dir" >/dev/null
  rm -f "$dir/grandchild.pid"
  # shellcheck disable=SC2016 # $! and $1 expand in the child shell, not here.
  env FM_BABYSIT_SEND="$dir/fake-send.sh" FM_HOME="$dir/home" FM_BABYSIT_KILL_GRACE=1 \
    "$BABYSIT" --timeout 2 t1 -- \
    sh -c 'sleep 60 & echo $! > "$1"/grandchild.pid; wait' _ "$dir" \
    >"$dir/bg.out" 2>&1 &
  wrapper=$!
  tries=0
  while kill -0 "$wrapper" 2>/dev/null && [ "$tries" -lt 100 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if kill -0 "$wrapper" 2>/dev/null; then
    fail "a backgrounded wrapper must exit on its own after its timeout"
  fi
  wait "$wrapper" || true
  grandchild=$(cat "$dir/grandchild.pid")
  if kill -0 "$grandchild" 2>/dev/null; then
    fail "a backgrounded wrapper must leave no orphaned grandchild (pid $grandchild alive)"
  fi
  assert_contains "$(cat "$dir/sendlog")" "timed out" "the backgrounded timeout must still notify"
  pass "a backgrounded wrapper still cleans up its process group on timeout"
}

test_success_sends_one_message_with_log_and_tail
test_failure_mirrors_child_exit_code
test_signaled_child_reports_signal
test_timeout_kills_process_group_without_orphans
test_missing_home_is_refused_loudly
test_fm_home_flag_beats_ambient_environment
test_tail_bound_keeps_only_recent_lines
test_double_send_failure_prints_fallback_and_retries_once
test_flaky_send_succeeds_on_retry
test_real_send_reaches_the_fixture_home_inbox
test_backgrounded_wrapper_leaves_no_orphan_on_timeout
test_default_log_uses_portable_mktemp_suffix
test_timeout_kills_term_resistant_grandchild
test_single_interrupt_kills_term_ignoring_child
test_setsid_fallback_still_isolates_group
