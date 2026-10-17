#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

wait_for_checkpoint_lock() {
  local home=$1 i=0
  while [ "$i" -lt 100 ]; do
    if [ -s "$home/state/.watch.lock/pid" ] \
      && [ -e "$home/state/.last-watcher-beat" ]; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

# The scheduled-check sweep must not depend on the model being inside a
# checkpoint: a Codex coordinator's turn between two checkpoints (a long drain,
# a provider wait) otherwise runs with no watcher at all, and a due sweep waits
# for the next checkpoint (2026-10-14: the completed-sweep gap was 414s against
# a 360s limit on a 300s interval, with a fresh beat at every observation).
#
# The fixtures run the real checkpoint, arm, and watcher in a home whose session
# lock names a live process, as a Codex home's does: the lock is what the
# continuing arm pins to know the session it serves.

# A home with a live session, a registered sweep check, and a one-second check
# interval. The check appends its epoch to <home>/sweeps and reports one event
# for each <home>/emit.<n> it finds. Each fixture home is recorded so the exit
# trap can stop what a failed test leaves behind.
make_sweep_home() {  # <name>
  local home
  home=$(make_home "$1")
  sleep 3600 >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$home/session.pid"
  printf '%s\n' "$!" > "$home/state/.lock"
  # A steady home: its last recovery episode was acknowledged, so nothing but
  # the fixture's own events is a wake.
  printf 'acked:downtime:fixture.1.aaa\n' > "$home/state/.watcher-down"
  printf '%s\n' "$home" >> "$TMP_ROOT/homes"
  fm_test_track_watcher_state "$home/state"
  cat > "$home/state/sweep.check.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$(date +%s)" >> "$home/sweeps"
for f in "$home"/emit.*; do
  [ -e "\$f" ] || continue
  rm -f "\$f"
  printf 'fixture-event-%s\n' "\${f##*.}"
  exit 0
done
SH
  chmod 0700 "$home/state/sweep.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" sweep >/dev/null || fail "could not register the sweep check"
  printf '%s\n' "$home"
}

pid_live() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
pid_gone() { ! kill -0 "$1" 2>/dev/null; }
parent_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }

# Stop what a fixture home still runs: the arm that owns its watcher, the
# watcher, and its session.
stop_sweep_home() {  # <home>
  local home=$1 watcher arm pid
  watcher=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$watcher" ]; then
    arm=$(parent_of "$watcher")
    case "$(ps -o command= -p "${arm:-0}" 2>/dev/null)" in *fm-watch-arm.sh*) kill -TERM "$arm" 2>/dev/null || true ;; esac
    kill -TERM "$watcher" 2>/dev/null || true
  fi
  pid=$(cut -f1 "$home/state/.supervision-host-left" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  pid=$(cat "$home/session.pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
}

stop_all_sweep_homes() {
  local home
  [ -f "$TMP_ROOT/homes" ] || return 0
  while IFS= read -r home; do stop_sweep_home "$home"; done < "$TMP_ROOT/homes"
}

# The checkpoint under the fixture's cadence: a quiet one by default.
run_checkpoint() {  # <home> <seconds> [tag]; sets STATUS, output in <home>/out<tag>.txt
  local home=$1 tag=${3:-}
  STATUS=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds "$2" \
    >"$home/out$tag.txt" 2>"$home/err$tag.txt" || STATUS=$?
}

sweep_count() { if [ -f "$1/sweeps" ]; then wc -l < "$1/sweeps" | tr -d ' '; else echo 0; fi; }
sweeps_reach() { [ "$(sweep_count "$1")" -ge "$2" ]; }
event_consumed() { [ ! -e "$1/emit.$2" ]; }
max_sweep_gap() {  # <home>
  awk 'NR > 1 && $1 - p > m { m = $1 - p } { p = $1 } END { print m + 0 }' "$1/sweeps"
}

# The watcher processes running from this checkout's bin. A command substitution
# inside a watcher is a forked copy with the same command line, so a process
# whose parent is itself a watcher is not counted.
live_watchers() {
  ps -A -o pid= -o ppid= -o command= 2>/dev/null | awk -v w="$ROOT/bin/fm-watch.sh" '
    $3 ~ /(^|\/)bash$/ && $4 == w { ppid[$1] = $2; order[++n] = $1 }
    END { for (i = 1; i <= n; i++) if (!(ppid[order[i]] in ppid)) c++; print c + 0 }'
}

# The arm that owns the home's watcher cycle.
cycle_arm() {  # <home>
  parent_of "$(cat "$1/state/.watch.lock/pid" 2>/dev/null)"
}

left_arm_of() { cut -f1 "$1/state/.supervision-host-left" 2>/dev/null; }

# Emit event <n> and require sweeps to carry on after the close it causes.
emit_and_expect_sweeps() {  # <home> <n> <label>
  local home=$1 n=$2 before
  before=$(sweep_count "$home")
  : > "$home/emit.$n"
  wait_until 200 event_consumed "$home" "$n" || fail "$3: event $n was never swept"
  wait_until 300 sweeps_reach "$home" $((before + 4)) \
    || fail "$3: check sweeps stopped after event $n (sweeps $(sweep_count "$home"), were $before): the cycle that closed on it was not restarted"
}

wait_until() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# The live gap (2026-10-14): the completed-check gap was 414s against a 360s
# limit on a 300s interval, with a fresh beacon at every observation. The
# checkpoint ran the watcher only for its own bound, so the model's turn between
# two checkpoints had no watcher and a due sweep waited for the next checkpoint.
test_check_sweeps_continue_between_checkpoints() {
  local home before sweeps_in_gap max_gap first_arm
  home=$(make_sweep_home sweeps-between)
  run_checkpoint "$home" 3 1
  expect_code 124 "$STATUS" "first quiet checkpoint exit"
  assert_contains "$(cat "$home/out1.txt")" "checkpoint: no actionable wake within 3s" "first quiet checkpoint line missing"
  before=$(sweep_count "$home")
  [ "$before" -ge 1 ] || fail "fixture: the first checkpoint never swept"
  first_arm=$(left_arm_of "$home")
  pid_live "$first_arm" || fail "the quiet checkpoint did not leave its arm running: $(cat "$home/err1.txt")"
  [ "$(cycle_arm "$home")" = "$first_arm" ] || fail "the arm the checkpoint recorded does not own the watcher"
  # The model's turn between checkpoints: no checkpoint runs for 12 seconds.
  sleep 12
  sweeps_in_gap=$(( $(sweep_count "$home") - before ))
  [ "$sweeps_in_gap" -ge 5 ] \
    || fail "check sweeps stopped between checkpoints: $sweeps_in_gap sweeps in a 12s gap at a 1s interval (the cycle ran only inside the checkpoint)"
  [ "$(live_watchers)" -eq 1 ] || fail "more than one watcher runs in the gap"
  run_checkpoint "$home" 3 2
  expect_code 124 "$STATUS" "second quiet checkpoint exit"
  max_gap=$(max_sweep_gap "$home")
  [ "$max_gap" -le 4 ] || fail "sweeps were ${max_gap}s apart across the checkpoints and the gap: $(tr '\n' ' ' < "$home/sweeps")"
  [ "$(live_watchers)" -eq 1 ] || fail "more than one watcher runs after the second checkpoint"
  ! kill -0 "$first_arm" 2>/dev/null || fail "the second checkpoint left the first arm running (pid $first_arm)"
  [ "$(left_arm_of "$home")" != "$first_arm" ] || fail "the second checkpoint left the first arm's record in place"
  [ "$(cycle_arm "$home")" = "$(left_arm_of "$home")" ] || fail "the arm the second checkpoint recorded does not own the watcher"
  [ "$(grep -c 'reason=taken-over	' "$home/state/.watch-cycle-exits.log")" -eq 1 ] \
    || fail "the second checkpoint did not take the first arm's cycle over exactly once: $(cut -c1-120 "$home/state/.watch-cycle-exits.log")"
  stop_sweep_home "$home"
  pass "checkpoint: check sweeps continue between checkpoints at the registered cadence under one arm and one watcher"
}

# Closes keep arriving while the model reasons between checkpoints. Each one
# ends the cycle that saw it, the arm restarts the one watcher, and the events
# stay queued exactly once for the drain.
test_repeated_closes_while_the_model_reasons() {
  local home n drained arm ack
  home=$(make_sweep_home repeated-closes)
  run_checkpoint "$home" 3 1
  expect_code 124 "$STATUS" "quiet checkpoint exit"
  arm=$(left_arm_of "$home")
  for n in 1 2 3; do
    emit_and_expect_sweeps "$home" "$n" "repeated closes"
  done
  [ "$(max_sweep_gap "$home")" -le 15 ] || fail "repeated closes: sweeps were $(max_sweep_gap "$home")s apart: $(tr '\n' ' ' < "$home/sweeps")"
  [ "$(live_watchers)" -eq 1 ] || fail "repeated closes: more than one watcher runs"
  [ "$(left_arm_of "$home")" = "$arm" ] && [ "$(cycle_arm "$home")" = "$arm" ] \
    || fail "repeated closes: the left arm no longer owns the cycle"
  for n in 1 2 3; do
    [ "$(grep -c "fixture-event-$n\$" "$home/state/.wake-queue")" -eq 1 ] \
      || fail "repeated closes: event $n is not queued exactly once:"$'\n'"$(cat "$home/state/.wake-queue")"
  done
  run_checkpoint "$home" 3 2
  ! kill -0 "$arm" 2>/dev/null || fail "repeated closes: the next checkpoint left the arm it took over (pid $arm)"
  [ "$(live_watchers)" -eq 1 ] || fail "repeated closes: more than one watcher runs after the take-over"
  # The drain presents the newest event of the check and its acknowledgement
  # covers all three queued rows.
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drained" "fixture-event-3" "repeated closes: the newest event did not reach the drain"
  assert_contains "$drained" "--ack-through 3" "repeated closes: the acknowledgement must cover all three events"
  ack=$(printf '%s\n' "$drained" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p')
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" $ack >/dev/null 2>&1 || fail "repeated closes: the acknowledgement failed: $ack"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_not_contains "$drained" "fixture-event-" "repeated closes: an acknowledged event was delivered again"
  [ "$(grep -c 'fixture-event-' "$home/state/.wake-queue" 2>/dev/null || true)" -eq 0 ] \
    || fail "repeated closes: an acknowledged event is still queued"
  stop_sweep_home "$home"
  pass "checkpoint: events that close the cycle between checkpoints are restarted past and delivered once"
}

# A wake that ends the checkpoint leaves the cycle running too: the model's
# turn that handles it is the long one.
test_an_actionable_close_leaves_the_cycle_running() {
  local home pid status n arm
  home=$(make_sweep_home close-leaves-cycle)
  (
    wait_until 100 sweeps_reach "$home" 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  run_checkpoint "$home" 20 1
  wait
  expect_code 0 "$STATUS" "an actionable checkpoint exit"
  assert_contains "$(cat "$home/out1.txt")" "signal:" "the wake was not passed through"
  arm=$(left_arm_of "$home")
  pid_live "$arm" || fail "the actionable checkpoint did not leave its arm running"
  for n in 1 2; do
    emit_and_expect_sweeps "$home" "$n" "after the actionable close"
  done
  [ "$(live_watchers)" -eq 1 ] || fail "more than one watcher runs after the actionable close"
  run_checkpoint "$home" 3 2
  status=$STATUS
  [ "$status" -eq 124 ] || [ "$status" -eq 0 ] || fail "the next checkpoint failed ($status): $(cat "$home/out2.txt" "$home/err2.txt")"
  ! kill -0 "$arm" 2>/dev/null || fail "the next checkpoint left the arm it took over (pid $arm)"
  [ "$(live_watchers)" -eq 1 ] || fail "more than one watcher runs after the take-over"
  pid=$(left_arm_of "$home")
  [ -n "$pid" ] || [ "$status" -eq 0 ] || fail "the next checkpoint recorded no arm"
  stop_sweep_home "$home"
  pass "checkpoint: a wake that ends a checkpoint leaves the cycle running for the next checkpoint to take over"
}

# The arm's own stop conditions end an unattended cycle: a session lock that now
# names another session ends it at the next close, and the checkpoint after that
# starts fresh instead of reusing the recorded identity.
test_a_superseded_session_ends_the_left_cycle() {
  local home arm other
  home=$(make_sweep_home superseded)
  run_checkpoint "$home" 3 1
  arm=$(left_arm_of "$home")
  [ -n "$arm" ] || fail "fixture: no arm was left"
  sleep 3600 >/dev/null 2>&1 &
  other=$!
  printf '%s\n' "$other" > "$home/state/.lock"
  : > "$home/emit.1"
  wait_until 300 pid_gone "$arm" || { kill "$other" 2>/dev/null; fail "a superseded session's arm kept scanning (pid $arm)"; }
  [ "$(live_watchers)" -eq 0 ] || { kill "$other" 2>/dev/null; fail "a superseded session's watcher kept running"; }
  printf '%s\n' "$other" > "$home/session.pid.other"
  # The interrupted supervision may surface as a recovery wake; either way the
  # checkpoint starts a fresh cycle and leaves it.
  run_checkpoint "$home" 3 2
  [ "$STATUS" -eq 124 ] || [ "$STATUS" -eq 0 ] || fail "the checkpoint after a superseded session failed ($STATUS): $(cat "$home/out2.txt" "$home/err2.txt")"
  [ -n "$(left_arm_of "$home")" ] && [ "$(left_arm_of "$home")" != "$arm" ] || fail "the checkpoint reused the superseded arm's record"
  kill -0 "$(left_arm_of "$home")" 2>/dev/null || fail "the fresh cycle's arm is not running"
  [ "$(live_watchers)" -eq 1 ] || fail "more than one watcher runs after the fresh start"
  stop_sweep_home "$home"
  kill "$other" 2>/dev/null || true
  pass "checkpoint: a superseded session ends the left cycle and the next checkpoint starts a fresh one"
}

# A record whose process is gone, or whose pid was reused by something else, is
# never taken over and never signalled.
test_a_stale_left_record_is_never_reused() {
  local home bystander dead
  home=$(make_sweep_home stale-pid-reuse)
  sleep 3600 >/dev/null 2>&1 &
  bystander=$!
  printf '%s\t%s\n' "$bystander" "not-the-identity-it-was-recorded-under" > "$home/state/.supervision-host-left"
  run_checkpoint "$home" 3 1
  expect_code 124 "$STATUS" "a checkpoint beside a reused-pid record: $(cat "$home/out1.txt" "$home/err1.txt")"
  kill -0 "$bystander" 2>/dev/null || fail "the checkpoint signalled an unrelated process that reused a recorded pid"
  [ "$(left_arm_of "$home")" != "$bystander" ] || fail "the reused-pid record was kept"
  stop_sweep_home "$home"
  kill "$bystander" 2>/dev/null || true
  home=$(make_sweep_home stale-dead-pid)
  dead=$(dead_pid)
  printf '%s\t%s\n' "$dead" "gone" > "$home/state/.supervision-host-left"
  run_checkpoint "$home" 3 1
  expect_code 124 "$STATUS" "a checkpoint beside a dead-pid record: $(cat "$home/out1.txt" "$home/err1.txt")"
  [ "$(left_arm_of "$home")" != "$dead" ] && [ -n "$(left_arm_of "$home")" ] || fail "the dead-pid record was kept"
  stop_sweep_home "$home"
  pass "checkpoint: a recorded arm that is gone or whose pid was reused is neither taken over nor signalled"
}

# The window of 2026-10-14: a watcher killed by SIGKILL while the model reasoned
# was never replaced, and nothing swept until the next checkpoint (max gap 719s
# against a 360s bound). The left arm replaces it; a watcher the next
# checkpoint's take-over stops on purpose is not replaced by the arm it ended.
test_a_killed_watcher_is_replaced_between_checkpoints() {
  local home watcher before arm
  home=$(make_sweep_home killed-watcher)
  run_checkpoint "$home" 3 1
  expect_code 124 "$STATUS" "quiet checkpoint exit"
  arm=$(left_arm_of "$home")
  watcher=$(cat "$home/state/.watch.lock/pid")
  before=$(sweep_count "$home")
  kill -KILL "$watcher"
  wait_until 100 pid_gone "$watcher" || fail "fixture: the watcher did not die"
  wait_until 300 sweeps_reach "$home" $((before + 4)) \
    || fail "a killed watcher was not replaced: sweeps $(sweep_count "$home"), were $before"
  [ "$(live_watchers)" -eq 1 ] || fail "more than one watcher runs after the replacement"
  [ "$(cat "$home/state/.watch.lock/pid")" != "$watcher" ] || fail "the watcher lock still names the killed watcher"
  [ "$(cycle_arm "$home")" = "$arm" ] || fail "the replacement is not owned by the arm that was left"
  run_checkpoint "$home" 3 2
  ! kill -0 "$arm" 2>/dev/null || fail "the next checkpoint left the arm it took over"
  [ "$(live_watchers)" -eq 1 ] || fail "more than one watcher runs after the take-over"
  stop_sweep_home "$home"
  pass "checkpoint: a watcher killed between checkpoints is replaced by the arm that was left, and a take-over still ends it once"
}

# A record that cannot be written leaves no cycle running that the next
# checkpoint could not find: the arm is stopped, the quiet bound is reported, and
# the failure is visible.
test_an_unrecordable_cycle_is_stopped_and_reported() {
  local home
  home=$(make_sweep_home unrecordable)
  mkdir "$home/state/.supervision-host-left"
  run_checkpoint "$home" 3 1
  expect_code 124 "$STATUS" "an unrecordable quiet checkpoint exit"
  assert_contains "$(cat "$home/out1.txt")" "checkpoint: no actionable wake within 3s" "the quiet line is missing"
  assert_contains "$(cat "$home/err1.txt")" "could not be left running" "the failure to leave the cycle running was not reported"
  [ "$(live_watchers)" -eq 0 ] || fail "an unrecordable arm left a watcher running"
  [ -z "$(ls -A "$home/state/.supervision-host-left")" ] || fail "an unrecordable arm left a file in the record: $(ls -A "$home/state/.supervision-host-left")"
  stop_sweep_home "$home"
  pass "checkpoint: a cycle that cannot be recorded is stopped and the failure is reported"
}

test_announced_recovery_is_not_reannounced_by_next_checkpoint() {
  local home out err status marker
  home=$(make_home announced-recovery)
  out="$home/out.txt"
  err="$home/err.txt"
  append_wake "$home/state" check buried 'check: unacknowledged durable wake' \
    || fail "could not append the unacknowledged durable wake"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "first recovery checkpoint exit"
  assert_contains "$(cat "$out")" "check: rearm-resurface" \
    "first checkpoint did not announce the pending recovery"
  marker=$(cat "$home/state/.watcher-down")
  case "$marker" in
    announced:downtime:*) ;;
    *) fail "first checkpoint did not leave an announced generation: $marker" ;;
  esac
  [ -s "$home/state/.wake-queue" ] \
    || fail "durable wake did not stay unacknowledged after the announcement"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?

  expect_code 124 "$status" "announced recovery checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" \
    "announced recovery checkpoint did not supervise for its bound"
  assert_not_contains "$(cat "$out")" "check: rearm-resurface" \
    "announced recovery was reannounced by the next checkpoint"
  [ "$(cat "$home/state/.watcher-down")" = "$marker" ] \
    || fail "announced recovery checkpoint changed the outstanding generation"
  grep "$(printf '\tcheck\tburied\tcheck: unacknowledged durable wake')" \
    "$home/state/.wake-queue" >/dev/null \
    || fail "unacknowledged durable wake was not retained"
  pass "an announced recovery is not reannounced by the next foreground checkpoint"
}

test_never_announced_recovery_is_announced_once() {
  local home out err status
  home=$(make_home pending-recovery)
  out="$home/out.txt"
  err="$home/err.txt"
  printf 'pending:downtime:unreported.1.aaa\n' > "$home/state/.watcher-down"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?

  expect_code 0 "$status" "pending recovery checkpoint exit"
  [ "$(grep -c '^check: rearm-resurface$' "$out" || true)" -eq 1 ] \
    || fail "never-announced recovery did not surface exactly once: $(cat "$out")"
  [ "$(cat "$home/state/.watcher-down")" = 'announced:downtime:unreported.1.aaa' ] \
    || fail "never-announced recovery did not retain its announced generation"
  pass "a never-announced recovery still surfaces once from a foreground checkpoint"
}

test_queue_append_during_checkpoint_still_resurfaces() {
  local home out err status checkpoint_pid
  home=$(make_home queue-append)
  out="$home/out.txt"
  err="$home/err.txt"

  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" &
  checkpoint_pid=$!
  wait_for_checkpoint_lock "$home" || {
    kill "$checkpoint_pid" 2>/dev/null || true
    wait "$checkpoint_pid" 2>/dev/null || true
    fail "queue-append checkpoint did not take the watcher lock"
  }
  append_wake "$home/state" check concurrent 'check: appended during checkpoint' \
    || fail "could not append a durable wake during the checkpoint"
  status=0
  wait "$checkpoint_pid" || status=$?

  expect_code 0 "$status" "queue-append checkpoint exit"
  assert_contains "$(cat "$out")" "check: rearm-resurface" \
    "queue append during checkpoint did not resurface"
  grep "$(printf '\tcheck\tconcurrent\tcheck: appended during checkpoint')" \
    "$home/state/.wake-queue" >/dev/null \
    || fail "queue append was not retained durably after checkpoint recovery"
  pass "a queue append during a foreground checkpoint still resurfaces"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 FM_ARM_CONFIRM_TIMEOUT=2 "$CHECKPOINT" --seconds 15 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: FAILED" "the unconfirmed singleton was not reported as a failed cycle"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# A home opted into the supervision host whose checkpoint runs a stub host in
# a fixture code root: the stub records the bound it was given, then closes
# the way $FM_HOME/host-kind says.
make_host_home() {  # <name>
  local home
  home=$(make_home "$1")
  mkdir -p "$home/root/bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/root/bin/fm-supervision-engine-lib.sh"
  cat > "$home/root/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\nprimary=%s\npark=%s\nlimit=%s\n' "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_SUPERVISION_HOST_PARK_SECONDS:-}" "${FM_SUPERVISION_HOST_PARK_LIMIT:-}" > "$FM_HOME/host-env"
case "$(cat "$FM_HOME/host-kind")" in
  boundary) printf 'supervision-host: cycle boundary - fixture\n' ;;
  handback)
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
    printf 'signal: demo.status\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\n'
    ;;
  stood-down) printf 'supervision-host stood down: this session no longer owns supervision\n' ;;
esac
SH
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-supervision-host.sh"
  : > "$home/config/supervision-host"
  printf '%s\n' "$home"
}

run_host_checkpoint() {  # <home> <kind> [checkpoint args...]; sets STATUS
  local home=$1
  printf '%s\n' "$2" > "$home/host-kind"
  shift 2
  STATUS=0
  FM_HOME="$home" "$home/root/bin/fm-watch-checkpoint.sh" "$@" >"$home/out.txt" 2>"$home/err.txt" || STATUS=$?
}

test_host_checkpoint_bounds_the_park_by_posture() {
  local home f
  home=$(make_host_home host-bound)
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a host park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 5s" "the boundary must read as the ordinary quiet line"
  assert_contains "$(cat "$home/host-env")" $'args=park\nprimary=codex\npark=5\nlimit=1235' \
    "attended, the host must park for the checkpoint's own bound with the codex pin and a turn limit past it"
  : > "$home/state/.afk-contract"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "an away park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 3600s" "away, the bound must be raised"
  assert_contains "$(cat "$home/host-env")" 'park=3600' "away, the host must park for the away bound"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 5
  assert_contains "$(cat "$home/host-env")" 'park=900' "the away bound must be configurable"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 1000
  assert_contains "$(cat "$home/host-env")" 'park=1000' "the away bound must never shorten a longer checkpoint"
  # Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
  # QUIET), so the checkpoint keeps its attended bound beside it.
  for f in fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$home/root/bin/$f"; done
  rm -f "$home/state/.afk-contract"
  FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a park beside a quiet record that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/host-env")" 'park=5' "beside a quiet record the host must park for the attended bound"
  pass "checkpoint: an opted-in home runs the host for the checkpoint's bound, raised only while away"
}

test_host_checkpoint_passes_a_handback_and_reports_a_stand_down() {
  local home
  home=$(make_host_home host-handback)
  run_host_checkpoint "$home" handback --seconds 5
  expect_code 0 "$STATUS" "a handed-back wake is an actionable checkpoint"
  assert_contains "$(cat "$home/out.txt")" $'signal: demo.status\nsupervision-host: the away session could not take this wake' \
    "the wake and its host line must pass through"
  assert_not_contains "$(cat "$home/out.txt")" "watcher: started" "the host's cycle status is not part of the wake"
  run_host_checkpoint "$home" stood-down --seconds 5
  expect_code 1 "$STATUS" "a host that stood down is a failed checkpoint"
  assert_contains "$(cat "$home/out.txt")" "supervision-host stood down" "the stand-down must be shown"
  pass "checkpoint: a handed-back wake passes through, and a host stand-down is a failure"
}

# The Codex owner stays file-gated: without config/supervision-host, or with
# config/supervision-host-off, the checkpoint never runs the host.
test_host_checkpoint_needs_the_file_and_honors_off() {
  local home line
  home=$(make_host_home host-gate)
  for line in - off; do
    rm -f "$home/config/supervision-host" "$home/config/supervision-host-off" "$home/host-env"
    [ "$line" = - ] || : > "$home/config/supervision-host-off"
    run_host_checkpoint "$home" boundary --seconds 1
    [ ! -e "$home/host-env" ] || fail "a Codex home whose config/supervision-host is ${line/-/absent} ran the supervision host"
  done
  pass "checkpoint: a Codex home without config/supervision-host, or with an off file, never runs the host"
}

# The real host under a fake Codex harness that holds the home's session lock.
# shellcheck disable=SC2016 # the fake harness's script expands in its own shell
test_real_host_checkpoint_ends_quietly_at_its_bound() {
  local home fakebin status
  home=$(make_home host-real)
  : > "$home/config/supervision-host"
  fakebin="$TMP_ROOT/host-real-bin"
  mkdir -p "$fakebin"
  ln -s /bin/bash "$fakebin/codex"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$fakebin/codex" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$0" --seconds 4
  ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 124 "$status" "a quiet host checkpoint: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 4s" "the real host's boundary must read as the quiet line"
  assert_grep '	boundary	' "$home/state/.supervision-host.log" "the host must have ended its own park"
  if [ -e "$home/state/.watch.lock/pid" ] && kill -0 "$(cat "$home/state/.watch.lock/pid")" 2>/dev/null; then
    fail "a host checkpoint left its watcher running"
  fi
  pass "checkpoint: the real host ends its park at the checkpoint bound as a quiet checkpoint"
}

test_killed_watcher_keeps_a_quiet_checkpoint_bounded() {
  local home checkpoint watcher rc=0
  home=$(make_sweep_home killed-in-checkpoint)
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 8 \
    > "$home/out.txt" 2> "$home/err.txt" &
  checkpoint=$!
  wait_for_checkpoint_lock "$home" || fail "checkpoint never started its watcher"
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -KILL "$watcher"
  if ! wait_until 150 pid_gone "$checkpoint"; then
    kill -TERM "$checkpoint" 2>/dev/null || true
    wait "$checkpoint" 2>/dev/null || true
    fail "successor-only handoff kept the quiet checkpoint past its bound"
  fi
  wait "$checkpoint" || rc=$?
  expect_code 124 "$rc" "a replacement alone must not be actionable"
  [ "$(cat "$home/state/.watch.lock/pid")" != "$watcher" ] || fail "watcher was not replaced"
  pid_live "$(left_arm_of "$home")" || fail "checkpoint did not leave its replacement running"
  stop_sweep_home "$home"
  pass "checkpoint: a quiet watcher replacement preserves the checkpoint bound"
}

trap 'stop_all_sweep_homes; fm_test_cleanup' EXIT
if [ -n "${FM_TEST_CASES:-}" ]; then
  for test_case in $FM_TEST_CASES; do "$test_case"; done
  exit 0
fi
test_killed_watcher_keeps_a_quiet_checkpoint_bounded
test_quiet_checkpoint_exits_124_cleanly
test_check_sweeps_continue_between_checkpoints
test_repeated_closes_while_the_model_reasons
test_an_actionable_close_leaves_the_cycle_running
test_a_superseded_session_ends_the_left_cycle
test_a_stale_left_record_is_never_reused
test_a_killed_watcher_is_replaced_between_checkpoints
test_an_unrecordable_cycle_is_stopped_and_reported
test_announced_recovery_is_not_reannounced_by_next_checkpoint
test_never_announced_recovery_is_announced_once
test_queue_append_during_checkpoint_still_resurfaces
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_host_checkpoint_bounds_the_park_by_posture
test_host_checkpoint_passes_a_handback_and_reports_a_stand_down
test_host_checkpoint_needs_the_file_and_honors_off
test_real_host_checkpoint_ends_quietly_at_its_bound
