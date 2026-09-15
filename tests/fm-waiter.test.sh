#!/usr/bin/env bash
# Behavior tests for bin/fm-waiter.sh, the worker-side event-driven completion wake helper.
#
# A worker registers a backgrounded job once and wakes on its completion within
# seconds instead of polling it in sleep slices: register writes one durable
# wait record under the home's state/, and each wait call sweeps in short
# intervals until the watched pids die, the registration hold expires, or the
# call's own budget runs out. bin/fm-waiter.sh owns that contract; this suite
# pins it end to end: observed completion with one durable message and a
# mirrored exit code, the completion statuses (completed, failed, signaled,
# pid-form unknown), the immediate 145 when the pids already exited with no
# message sent, hold expiry with process-group cleanup and exit 124, budget
# exhaustion with exit 142 and the record kept live, cancel with group cleanup,
# double-register refusal, --fm-home precedence with a loud refusal when no
# home is set, id and log-path confinement, the bounded tail, exactly one send
# retry with a pane-visible fallback line on double failure, and one real
# delivery through the sibling fm-send.sh into a fixture home.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

WAITER="$ROOT/bin/fm-waiter.sh"

TMP=$(fm_test_tmproot fm-waiter)

# make_send_shim <dir> -> echoes a fake FM_WAITER_SEND that records every
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

# reg_of <case-dir> -> echoes the first registration id in <dir>/home/state.
reg_of() {
  local f
  for f in "$1"/home/state/.wait-w-*; do
    [ -e "$f" ] || return 0
    basename "$f" | sed 's/^.wait-//'
    return 0
  done
}

# wait_records <case-dir> -> echoes how many wait records <dir>/home/state holds.
wait_records() {
  local n=0 f
  for f in "$1"/home/state/.wait-w-*; do
    [ -e "$f" ] || break
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# run_waiter <case-dir> [waiter-args...]: run the helper with a recording send
# shim already in place. Echoes combined output; returns its exit code.
run_waiter() {
  local dir=$1
  shift
  env FM_WAITER_SEND="$dir/fake-send.sh" FM_HOME="$dir/home" \
    "FM_WAITER_KILL_GRACE=${FM_WAITER_KILL_GRACE:-5}" "$WAITER" "$@" 2>&1
}

test_observed_completion_sends_one_message_and_mirrors_exit() {
  local dir out rc reg msg
  dir="$TMP/observed"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  out=$(run_waiter "$dir" register t1 -- sh -c 'sleep 2; echo hello-out; echo hello-err >&2'); rc=$?
  expect_code 0 "$rc" "register must succeed"
  assert_contains "$out" "registration " "register must print the registration id"
  assert_contains "$out" "log: " "register must print the log path"
  reg=$(reg_of "$dir")
  assert_contains "$reg" "w-" "the state dir must hold the wait record"
  out=$(run_waiter "$dir" wait "$reg" --interval 1 --budget 30); rc=$?
  expect_code 0 "$rc" "an observed completion must exit with the watched code"
  assert_equals 1 "$(send_calls "$dir")" "an observed completion must send exactly one message"
  msg=$(cat "$dir/sendlog")
  assert_contains "$msg" "task=t1" "the message must go to the owning task"
  assert_contains "$msg" "completed ok" "the message must report the completed status"
  assert_contains "$msg" "exit 0" "the message must report the exit code"
  assert_contains "$msg" "elapsed " "the message must report the elapsed time"
  assert_contains "$msg" "hello-out" "the message must carry the log tail"
  assert_contains "$msg" "hello-err" "the message must carry stderr too"
  assert_contains "$out" "notified task t1" "the pane must confirm the notification"
  pass "observed completion sends one message and mirrors the exit code"
}

test_failure_mirrors_child_exit_code() {
  local dir out rc reg
  dir="$TMP/failure"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  run_waiter "$dir" register t1 -- sh -c 'sleep 2; exit 3' >/dev/null 2>&1
  reg=$(reg_of "$dir")
  out=$(run_waiter "$dir" wait "$reg" --interval 1 --budget 30); rc=$?
  expect_code 3 "$rc" "the wait must exit with the watched code"
  assert_equals 1 "$(send_calls "$dir")" "a failure must still send exactly one message"
  assert_contains "$(cat "$dir/sendlog")" "failed" "the message must report the failed status"
  assert_contains "$(cat "$dir/sendlog")" "exit 3" "the message must report the watched exit code"
  pass "failure mirrors the watched exit code after the send attempt"
}

test_signaled_child_reports_signal() {
  local dir out rc reg
  dir="$TMP/signaled"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  # shellcheck disable=SC2016 # $$ expands in the child shell, not here.
  run_waiter "$dir" register t1 -- sh -c 'sleep 2; kill -TERM $$' >/dev/null 2>&1
  reg=$(reg_of "$dir")
  out=$(run_waiter "$dir" wait "$reg" --interval 1 --budget 30); rc=$?
  expect_code 143 "$rc" "a SIGTERM death must mirror 128+15"
  assert_contains "$(cat "$dir/sendlog")" "killed by signal TERM" "the message must report the killing signal"
  assert_contains "$out" "notified task t1" "the pane must confirm the notification"
  pass "a signaled child is reported as killed by that signal"
}

test_already_exited_returns_145_without_sending() {
  local dir out rc reg pid
  dir="$TMP/already"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  sleep 0.3 &
  pid=$!
  out=$(run_waiter "$dir" register t1 -- "$pid"); rc=$?
  expect_code 0 "$rc" "register must succeed while the pid is alive"
  reg=$(reg_of "$dir")
  wait "$pid" 2>/dev/null || true
  out=$(run_waiter "$dir" wait "$reg" --interval 1); rc=$?
  expect_code 145 "$rc" "a wait on dead pids must return 145 at once"
  assert_equals 0 "$(send_calls "$dir")" "the 145 path must send no message"
  assert_contains "$out" "unavailable" "the 145 output must still print the capture state"
  assert_equals "done" "$(sed -n 's/^status=//p' "$dir/home/state/.wait-$reg")" "the 145 path must mark the record done"
  out=$(run_waiter "$dir" wait "$reg" --interval 1); rc=$?
  expect_code 145 "$rc" "a re-wait on a reported registration must return 145, not an error"
  assert_contains "$out" "already reported" "the re-wait must say the registration was reported"
  pass "an already-exited watch returns 145 immediately with no message"
}

test_register_with_no_live_pid_is_refused() {
  local dir out rc pid
  dir="$TMP/nolive"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  sleep 0.1 &
  pid=$!
  wait "$pid" 2>/dev/null || true
  out=$(run_waiter "$dir" register t1 -- "$pid" 2>&1); rc=$?
  assert_not_equals 0 "$rc" "a register with no live pid must refuse"
  assert_contains "$out" "no live pid" "the refusal must say there is nothing to watch"
  assert_equals 0 "$(send_calls "$dir")" "a refused register must send nothing"
  pass "a register with no live pid is refused loudly"
}

test_hold_expiry_kills_group_reports_and_exits_124() {
  local dir out rc reg pids
  dir="$TMP/expiry"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  rm -f "$dir/grandchild.pid"
  # shellcheck disable=SC2016 # $! and $1 expand in the child shell, not here.
  run_waiter "$dir" register --hold 2 t1 -- \
    sh -c 'sleep 60 & echo $! > "$1"/grandchild.pid; echo started; wait' _ "$dir" >/dev/null 2>&1
  reg=$(reg_of "$dir")
  out=$(FM_WAITER_KILL_GRACE=1 run_waiter "$dir" wait "$reg" --interval 1 --budget 30); rc=$?
  expect_code 124 "$rc" "an expired hold must exit 124"
  assert_equals 1 "$(send_calls "$dir")" "expiry must send exactly one message"
  assert_contains "$(cat "$dir/sendlog")" "expired after 2s" "the message must report the expiry"
  assert_contains "$(cat "$dir/sendlog")" "exit 124" "the message must report exit 124"
  assert_contains "$(cat "$dir/sendlog")" "started" "the message must carry the capture state"
  assert_contains "$out" "notified task t1" "the pane must confirm the notification"
  pids=$(sed -n 's/^pids=//p' "$dir/home/state/.wait-$reg")
  if kill -0 "$pids" 2>/dev/null; then
    kill -KILL "$pids" 2>/dev/null || true
    fail "the expired command group must leave no orphaned child (pid $pids alive)"
  fi
  if kill -0 "$(cat "$dir/grandchild.pid")" 2>/dev/null; then
    fail "the expired command group must leave no orphaned grandchild"
  fi
  pass "hold expiry kills the process group, reports expiry, and exits 124"
}

test_budget_exhaustion_keeps_registration_then_cancel_cleans_up() {
  local dir out rc reg pids
  dir="$TMP/budget"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  run_waiter "$dir" register t1 -- sh -c 'sleep 60' >/dev/null 2>&1
  reg=$(reg_of "$dir")
  out=$(run_waiter "$dir" wait "$reg" --interval 1 --budget 2); rc=$?
  expect_code 142 "$rc" "a budget-exhausted wait must exit 142"
  assert_equals 0 "$(send_calls "$dir")" "the budget path must send nothing"
  assert_contains "$out" "still running" "the pane must say the watch is still running"
  assert_contains "$out" "re-invoke wait" "the pane must say how to resume"
  assert_equals "live" "$(sed -n 's/^status=//p' "$dir/home/state/.wait-$reg")" "the record must stay live"
  pids=$(sed -n 's/^pids=//p' "$dir/home/state/.wait-$reg")
  out=$(FM_WAITER_KILL_GRACE=1 run_waiter "$dir" cancel "$reg" 2>&1); rc=$?
  expect_code 0 "$rc" "cancel must succeed"
  assert_contains "$out" "cancelled" "the pane must confirm the cancel"
  assert_absent "$dir/home/state/.wait-$reg" "cancel must remove the record"
  if kill -0 "$pids" 2>/dev/null; then
    kill -KILL "$pids" 2>/dev/null || true
    fail "cancel must kill the command-form process group (pid $pids alive)"
  fi
  out=$(run_waiter "$dir" wait "$reg" --interval 1 2>&1); rc=$?
  assert_not_equals 0 "$rc" "a wait after cancel must fail"
  assert_contains "$out" "unknown registration" "the failure must name the unknown registration"
  pass "budget exhaustion exits 142 with the record live, and cancel cleans up"
}

test_double_register_is_refused() {
  local dir out rc pid
  dir="$TMP/double"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  sleep 30 &
  pid=$!
  run_waiter "$dir" register t1 -- "$pid" >/dev/null 2>&1
  out=$(run_waiter "$dir" register t1 -- "$pid" 2>&1); rc=$?
  assert_not_equals 0 "$rc" "a second live register for one task must refuse"
  assert_contains "$out" "already has a live registration" "the refusal must name the live registration"
  assert_equals 1 "$(wait_records "$dir")" "the refused register must create no record"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  run_waiter "$dir" cancel "$(reg_of "$dir")" >/dev/null 2>&1
  pass "a double register for one task is refused loudly"
}

test_pid_form_live_completion_reports_unknown_status() {
  local dir out rc reg pid
  dir="$TMP/pidform"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  sleep 3 &
  pid=$!
  run_waiter "$dir" register t1 -- "$pid" >/dev/null 2>&1
  reg=$(reg_of "$dir")
  out=$(run_waiter "$dir" wait "$reg" --interval 1 --budget 30); rc=$?
  expect_code 0 "$rc" "a pid-form completion with unknown status must exit 0"
  wait "$pid" 2>/dev/null || true
  assert_equals 1 "$(send_calls "$dir")" "a pid-form completion must send exactly one message"
  assert_contains "$(cat "$dir/sendlog")" "unavailable" "the message must say the status is unavailable"
  assert_contains "$(cat "$dir/sendlog")" "exit 0" "the message must report exit 0"
  assert_contains "$out" "notified task t1" "the pane must confirm the notification"
  pass "a pid-form watch reports completion with unavailable status"
}

test_missing_home_is_refused_loudly() {
  local dir out rc
  dir="$TMP/nohome"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  out=$(env -u FM_HOME "$WAITER" register t1 -- true 2>&1); rc=$?
  assert_not_equals 0 "$rc" "a missing send home must refuse"
  assert_contains "$out" "--fm-home" "the refusal must name the --fm-home flag"
  assert_contains "$out" "FM_HOME" "the refusal must name FM_HOME"
  assert_equals 0 "$(send_calls "$dir")" "a refused run must send nothing"
  pass "a missing send home is refused loudly before anything runs"
}

test_fm_home_flag_beats_ambient_environment() {
  local dir out rc reg
  dir="$TMP/flaghome"
  mkdir -p "$dir/home/state" "$dir/elsewhere/state"
  make_send_shim "$dir" >/dev/null
  run_waiter "$dir" register t1 -- sh -c 'sleep 2' >/dev/null 2>&1
  reg=$(reg_of "$dir")
  assert_present "$dir/home/state/.wait-$reg" "the record must live under the ambient home here"
  out=$(env FM_WAITER_SEND="$dir/fake-send.sh" FM_HOME="$dir/elsewhere" \
    "$WAITER" --fm-home "$dir/home" wait "$reg" --interval 1 --budget 30 2>&1); rc=$?
  expect_code 0 "$rc" "the flag-home wait must succeed"
  assert_contains "$(cat "$dir/sendlog")" "home=$dir/home" "the send must use the --fm-home home, not FM_HOME"
  assert_contains "$out" "notified task t1" "the pane must confirm the notification"
  pass "--fm-home takes precedence over the ambient FM_HOME"
}

test_interval_is_clamped_and_validated() {
  local dir out rc reg
  dir="$TMP/interval"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  out=$(run_waiter "$dir" register t1 --interval 99 -- sh -c 'sleep 30' 2>&1); rc=$?
  expect_code 0 "$rc" "an over-cap interval must clamp, not refuse"
  assert_contains "$out" "clamped to 15s" "the clamp must be announced"
  reg=$(reg_of "$dir")
  assert_equals "15" "$(sed -n 's/^interval=//p' "$dir/home/state/.wait-$reg")" "the record must store the clamped interval"
  run_waiter "$dir" cancel "$reg" >/dev/null 2>&1
  out=$(run_waiter "$dir" register t1 --interval 0 -- true 2>&1); rc=$?
  assert_not_equals 0 "$rc" "a zero interval must refuse"
  assert_equals 0 "$(wait_records "$dir")" "a refused register must create no record"
  pass "the sweep interval clamps to the 15s cap and refuses zero"
}

test_evil_ids_and_foreign_log_are_refused() {
  local dir out rc
  dir="$TMP/evil"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  out=$(run_waiter "$dir" register '../evil' -- true 2>&1); rc=$?
  assert_not_equals 0 "$rc" "a traversing task id must refuse"
  out=$(run_waiter "$dir" wait '../../etc' 2>&1); rc=$?
  assert_not_equals 0 "$rc" "a traversing registration id must refuse"
  out=$(run_waiter "$dir" register t1 --log /etc/fm-waiter-evil.log -- true 2>&1); rc=$?
  assert_not_equals 0 "$rc" "a command-form log outside the home and scratch must refuse"
  assert_contains "$out" "FM_HOME or TMPDIR" "the refusal must state the confinement"
  assert_absent "/etc/fm-waiter-evil.log" "the refused log must not be created"
  assert_equals 0 "$(wait_records "$dir")" "refused registers must create no records"
  assert_equals 0 "$(send_calls "$dir")" "refused runs must send nothing"
  pass "traversing ids and foreign log paths are refused with nothing written"
}

test_tail_bound_keeps_only_recent_lines() {
  local dir reg
  dir="$TMP/tailbound"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  # shellcheck disable=SC2016 # $i expands in the child shell, not here.
  run_waiter "$dir" register --tail 3 t1 -- sh -c 'sleep 2; i=1; while [ "$i" -le 100 ]; do echo "marker-line-$i"; i=$((i + 1)); done' >/dev/null 2>&1
  reg=$(reg_of "$dir")
  run_waiter "$dir" wait "$reg" --interval 1 --budget 30 >/dev/null 2>&1
  assert_contains "$(cat "$dir/sendlog")" "--- last 3 lines" "the message must state the tail bound"
  assert_contains "$(cat "$dir/sendlog")" "marker-line-100" "the tail must include the most recent lines"
  if grep -qx 'marker-line-1' "$dir/sendlog"; then
    fail "the bounded tail must not carry the first log lines"
  fi
  pass "the message tail is bounded to the most recent lines"
}

test_double_send_failure_prints_fallback_and_retries_once() {
  local dir out rc reg
  dir="$TMP/fallback"
  mkdir -p "$dir/home/state"
  make_send_shim "$dir" >/dev/null
  printf '1\n' > "$dir/send-exit"
  run_waiter "$dir" register t1 -- sh -c 'sleep 2; echo hi' >/dev/null 2>&1
  reg=$(reg_of "$dir")
  out=$(run_waiter "$dir" wait "$reg" --interval 1 --budget 30); rc=$?
  expect_code 0 "$rc" "the wait still exits with the watched code after a lost notification"
  assert_equals 2 "$(send_calls "$dir")" "the send must be retried exactly once"
  assert_contains "$out" "FAILED to notify task t1" "the pane must show the fallback line"
  assert_contains "$out" "send failed twice" "the fallback must say both attempts failed"
  assert_equals "done" "$(sed -n 's/^status=//p' "$dir/home/state/.wait-$reg")" "the lost notification must still close the record exactly once"
  pass "a double send failure retries once, then prints one fallback line and writes nothing else"
}

test_flaky_send_succeeds_on_retry() {
  local dir out rc reg
  dir="$TMP/flaky"
  mkdir -p "$dir/home/state"
  cat > "$dir/fake-send.sh" <<SH
#!/usr/bin/env bash
n=\$(cat "$dir/attempts" 2>/dev/null || echo 0)
echo \$((n + 1)) > "$dir/attempts"
[ "\$n" -ge 1 ] && exit 0 || exit 1
SH
  chmod +x "$dir/fake-send.sh"
  echo 0 > "$dir/attempts"
  run_waiter "$dir" register t1 -- sh -c 'sleep 2; true' >/dev/null 2>&1
  reg=$(reg_of "$dir")
  out=$(run_waiter "$dir" wait "$reg" --interval 1 --budget 30); rc=$?
  expect_code 0 "$rc" "a retry success must exit 0"
  assert_equals 2 "$(cat "$dir/attempts")" "the send must be attempted exactly twice"
  assert_contains "$out" "notified task t1" "the pane must confirm the notification"
  pass "a first-attempt send failure is retried once and then notified"
}

test_real_send_reaches_the_fixture_home_inbox() {
  local dir out rc reg msg
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
  out=$(env -u FM_WAITER_SEND PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    "$WAITER" register t1 -- sh -c 'sleep 2; echo real-delivery' 2>&1); rc=$?
  expect_code 0 "$rc" "the real-send register must succeed"
  reg=$(reg_of "$dir")
  out=$(env -u FM_WAITER_SEND PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    "$WAITER" wait "$reg" --interval 1 --budget 30 2>&1); rc=$?
  expect_code 0 "$rc" "the real-send wait must succeed"
  assert_present "$dir/home/state/t1.inbox/001.msg" "the real fm-send.sh must record one inbox message"
  msg=$(cat "$dir/home/state/t1.inbox/001.msg")
  assert_contains "$msg" "completed ok" "the inbox record must carry the completion status"
  assert_contains "$msg" "real-delivery" "the inbox record must carry the log tail"
  assert_contains "$out" "notified task t1" "the pane must confirm the notification"
  pass "the default send path delivers one durable message through the real fm-send.sh"
}

test_observed_completion_sends_one_message_and_mirrors_exit
test_failure_mirrors_child_exit_code
test_signaled_child_reports_signal
test_already_exited_returns_145_without_sending
test_register_with_no_live_pid_is_refused
test_hold_expiry_kills_group_reports_and_exits_124
test_budget_exhaustion_keeps_registration_then_cancel_cleans_up
test_double_register_is_refused
test_pid_form_live_completion_reports_unknown_status
test_missing_home_is_refused_loudly
test_fm_home_flag_beats_ambient_environment
test_interval_is_clamped_and_validated
test_evil_ids_and_foreign_log_are_refused
test_tail_bound_keeps_only_recent_lines
test_double_send_failure_prints_fallback_and_retries_once
test_flaky_send_succeeds_on_retry
test_real_send_reaches_the_fixture_home_inbox
