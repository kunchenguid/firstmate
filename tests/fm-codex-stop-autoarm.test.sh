#!/usr/bin/env bash
# Behavior tests for the Codex Stop-owned watcher auto-arm
# (bin/fm-codex-stop-autoarm.sh, docs/supervision-protocols/codex.md).
#
# The hook fires as an async Codex Stop hook. These tests run it hermetically as
# a child of a fake harness (a bash symlink named "codex") whose pid is written
# into the fixture home's state/.lock, with a fake `codex` executable on PATH
# recording every `codex queue` call. The arm wrapper is a per-test fixture, so
# no real watcher, model, Codex session, or fleet state is touched.
#
# What these cases pin, because each is a way the fix could silently stop
# working:
#   * the wake is delivered by `codex queue --thread <session_id>`, carrying the
#     thread from THIS Stop payload;
#   * the hook keeps its own single-flight ledger, so it can never race Claude's;
#   * scope, session-lock identity, away mode, and supervision need all keep it
#     completely inert and silent;
#   * a payload with no thread, or a host with no codex binary, stands down
#     instead of arming a watcher whose wake could never be delivered;
#   * a healthy watcher is not announced, and a failure is announced once.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-stop-autoarm)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/codex-harness"
FAKE_HARNESS="$FAKEBIN/codex-harness"

# A fake `codex` CLI that appends every queue call to $FM_HOME/state/queued.log.
cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = queue ]; then
  shift
  thread= ; message=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --thread) thread=$2; shift 2 ;;
      --message) message=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  {
    printf 'THREAD=%s\n' "$thread"
    printf 'MESSAGE<<\n%s\n>>MESSAGE\n' "$message"
  } >> "${FM_HOME:-/dev/null}/state/queued.log"
  printf 'Queued message x for thread %s.\n' "$thread"
  exit "${FM_TEST_CODEX_QUEUE_RC:-0}"
fi
exit 2
SH
chmod +x "$FAKEBIN/codex"

install_autoarm_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin"
  for f in fm-codex-stop-autoarm.sh fm-primary-scope-lib.sh fm-supervision-lib.sh \
    fm-wake-lib.sh fm-session-lock-lib.sh fm-cursor-lib.sh fm-lock.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir/bin/fm-codex-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

# One in-flight task, which is what makes a home need supervision at all.
need_supervision() {
  local dir=$1
  printf 'window=fixture:w1:p1\nbackend=tmux\n' > "$dir/state/t1.meta"
}

make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/codex-autoarm-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

PAYLOAD_THREAD=${PAYLOAD_THREAD:-01a09c3d-8294-7d12-953d-034d4afc6d11}

# Run the hook as a child of the fake harness holding the fixture session lock.
run_autoarm() {
  local dir=$1 payload=${2:-} rc=0
  [ -n "$payload" ] || payload="{\"session_id\":\"$PAYLOAD_THREAD\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
  printf '%s\n' "$payload" \
    | FM_HOME="$dir" PATH="$FAKEBIN:$PATH" "$FAKE_HARNESS" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  return "$rc"
}

# Run the hook with NO session lock written, so identity must keep it inert.
run_autoarm_unowned() {
  local dir=$1 rc=0
  printf '%s\n' "{\"session_id\":\"$PAYLOAD_THREAD\"}" \
    | FM_HOME="$dir" PATH="$FAKEBIN:$PATH" "$FAKE_HARNESS" -c '
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  return "$rc"
}

write_arm_fixture() {
  local dir=$1 kind=$2
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: t1.status\n'
exit 0
SH
      ;;
    healthy)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: attached pid=%s (beacon 1s)\n' "$$"
exit 0
SH
      ;;
    failing)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    unreachable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "MUST-NOT-RUN" >> "$FM_HOME/state/arm-ran"
exit 0
SH
      ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
  # The healthy path re-verifies through the real predicate, which needs a live
  # watcher process to point at; a fixture beacon alone must not fake one.
  cat > "$dir/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
sleep 300
SH
  chmod +x "$dir/bin/fm-watch.sh"
}

queued_log() {
  cat "$1/state/queued.log" 2>/dev/null || true
}

assert_inert() {
  local dir=$1 what=$2
  assert_absent "$dir/state/arm-ran" "$what: no watcher is armed"
  assert_absent "$dir/state/queued.log" "$what: nothing is queued into the Codex thread"
  assert_absent "$dir/state/.codex-autoarm-epoch" "$what: no ledger claim is taken"
}

test_actionable_close_queues_the_wake_into_this_payloads_thread() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/deliver")
  need_supervision "$dir"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir") || true
  assert_present "$dir/state/arm-ran" "the hook foreground-armed the watcher"
  assert_contains "$(queued_log "$dir")" "THREAD=$PAYLOAD_THREAD" \
    "the wake is queued into the thread this Stop payload named"
  assert_contains "$(queued_log "$dir")" "firstmate watcher wake" \
    "the queued message is the wake banner"
  assert_contains "$(queued_log "$dir")" "signal: t1.status" \
    "the queued message carries the watcher's own reason line"
  assert_contains "$(queued_log "$dir")" "fm-wake-drain.sh" \
    "the queued message tells the next turn to drain first"
  assert_equals "" "$out" "the hook prints nothing itself"
  pass "fm-codex-stop-autoarm: an actionable close is queued into the Codex thread"
}

test_it_keeps_its_own_ledger_separate_from_claudes() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/ledger")
  need_supervision "$dir"
  write_arm_fixture "$dir" actionable
  run_autoarm "$dir" >/dev/null || true
  assert_present "$dir/state/.codex-autoarm-epoch" "the Codex hook writes its own ledger"
  assert_absent "$dir/state/.claude-autoarm-epoch" \
    "the Codex hook never touches Claude's ledger"
  assert_contains "$(cat "$dir/state/.codex-autoarm-epoch")" "outcome=rewake" \
    "a delivered wake is recorded as the generation's outcome"
  pass "fm-codex-stop-autoarm: the single-flight ledger is its own, never Claude's"
}

# The same hook, fired from a harness process that KEEPS holding the session
# lock after the hook returns, which is the live shape every mid-turn reader
# sees: the session that armed the watcher is still the session running the
# handling turn. Sets HOLD_PID for the caller to reap.
HOLD_PID=
run_autoarm_holding_lock() {
  local dir=$1 i=0
  printf '%s\n' "{\"session_id\":\"$PAYLOAD_THREAD\"}" \
    | FM_HOME="$dir" PATH="$FAKEBIN:$PATH" "$FAKE_HARNESS" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
        : > "$FM_HOME/state/hook-returned"
        sleep 60
      ' >/dev/null 2>&1 &
  HOLD_PID=$!
  while [ "$i" -lt 300 ] && [ ! -e "$dir/state/hook-returned" ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

midturn_healthy() {  # <dir>
  local dir=$1
  FM_AUTOARM_PREFIX=.codex-autoarm FM_STATE_OVERRIDE="$dir/state" \
    bash -c '. "$1"; fm_autoarm_midturn_healthy "$2"' _ "$dir/bin/fm-wake-lib.sh" "$dir/state"
}

# The pull guard (bin/fm-guard.sh) reads a stale mid-turn beacon as a supervision
# lapse unless the auto-arm ledger proves a handling turn owns the gap. That
# proof needs the rewake row bound to the live session lock and the current
# watcher recovery generation, so an unbound row makes every Codex handling turn
# that outruns grace print "SUPERVISION IS OFF" while supervision is healthy.
test_a_delivered_rewake_is_bound_to_this_session_and_recovery_generation() {
  local dir rc=0
  dir=$(make_primary_dir "$TMP_ROOT/rewake-binding")
  need_supervision "$dir"
  write_arm_fixture "$dir" actionable
  run_autoarm_holding_lock "$dir"
  assert_contains "$(queued_log "$dir")" "firstmate watcher wake" \
    "the wake was delivered, so there is a rewake row to bind"
  midturn_healthy "$dir" || rc=$?
  kill "$HOLD_PID" 2>/dev/null || true
  wait "$HOLD_PID" 2>/dev/null || true
  expect_code 0 "$rc" \
    "a delivered Codex rewake must satisfy the mid-turn proof its own session can read back"
  pass "fm-codex-stop-autoarm: a delivered rewake is bound to the session lock and recovery generation"
}

# A rewake that cannot be bound still has to go out: codex queue is the only wake
# channel this hook has, so refusing delivery would drop the event entirely.
test_an_unbindable_rewake_is_still_delivered() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/rewake-unbindable")
  need_supervision "$dir"
  write_arm_fixture "$dir" actionable
  # An arm that reports an actionable close without leaving a downtime marker.
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'signal: t1.status\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  run_autoarm "$dir" >/dev/null || true
  assert_contains "$(queued_log "$dir")" "firstmate watcher wake" \
    "an unbindable rewake is still queued into the thread"
  pass "fm-codex-stop-autoarm: an unbindable rewake is delivered rather than dropped"
}

# The failure notice is the only operator-visible report that the automatic
# mechanism is broken, so a push the CLI rejected must not consume the episode.
test_a_rejected_failure_push_is_retried_on_the_next_stop() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/failure-push-rejected")
  need_supervision "$dir"
  write_arm_fixture "$dir" failing
  export FM_TEST_CODEX_QUEUE_RC=1
  run_autoarm "$dir" >/dev/null || true
  unset FM_TEST_CODEX_QUEUE_RC
  assert_contains "$(queued_log "$dir")" "auto-arm FAILED" \
    "the notice push is attempted before any episode marker exists"
  assert_absent "$dir/state/.codex-autoarm-failure-notified" \
    "a rejected push must not consume the episode's only notice"
  : > "$dir/state/queued.log"
  run_autoarm "$dir" >/dev/null || true
  assert_contains "$(queued_log "$dir")" "auto-arm FAILED" \
    "the next Stop retries the notice the rejected push never delivered"
  assert_present "$dir/state/.codex-autoarm-failure-notified" \
    "an accepted push is what marks the episode as announced"
  pass "fm-codex-stop-autoarm: a rejected failure push is retried, not silently consumed"
}

# A freshly exec'd process is reported by ps as "/usr/bin/env bash <script>" for
# a moment and as "bash <script>" once the exec settles, so an identity read too
# early never matches the one the predicate reads later. Wait for two identical
# consecutive reads before recording, or the healthy case fails for a reason
# that has nothing to do with the hook.
watcher_identity() {
  local dir=$1 pid=$2 prev= cur= i=0
  while [ "$i" -lt 50 ]; do
    cur=$(FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-wake-lib.sh" "$pid")
    [ -n "$cur" ] && [ "$cur" = "$prev" ] && break
    prev=$cur
    i=$((i + 1))
    sleep 0.1
  done
  printf '%s' "$cur"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 bin_dir
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
}

test_a_healthy_watcher_is_not_announced() {
  local dir pid identity
  dir=$(make_primary_dir "$TMP_ROOT/healthy")
  need_supervision "$dir"
  write_arm_fixture "$dir" healthy
  # A real live watcher process for the strict predicate to verify, recorded the
  # way the watcher itself records it.
  "$dir/bin/fm-watch.sh" >/dev/null 2>&1 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid")
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  run_autoarm "$dir" >/dev/null 2>&1 || true
  assert_absent "$dir/state/queued.log" \
    "a cycle that closed with a healthy watcher never wakes the model"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "fm-codex-stop-autoarm: a healthy close is silent"
}

test_failure_is_announced_once_per_episode() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/failure")
  need_supervision "$dir"
  write_arm_fixture "$dir" failing
  run_autoarm "$dir" >/dev/null || true
  assert_contains "$(queued_log "$dir")" "auto-arm FAILED" \
    "a broken mechanism is reported into the thread"
  assert_present "$dir/state/.codex-autoarm-failure-notified" \
    "the episode marker is written so the notice is not repeated"
  : > "$dir/state/queued.log"
  run_autoarm "$dir" >/dev/null || true
  assert_not_contains "$(queued_log "$dir")" "auto-arm FAILED" \
    "the same failure episode is not announced again"
  pass "fm-codex-stop-autoarm: a broken mechanism is announced once, not on every turn"
}

test_a_payload_with_no_thread_stands_down() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/no-thread")
  need_supervision "$dir"
  write_arm_fixture "$dir" unreachable
  run_autoarm "$dir" '{"hook_event_name":"Stop","stop_hook_active":false}' >/dev/null || true
  assert_inert "$dir" "a Stop payload with no session id"
  pass "fm-codex-stop-autoarm: no thread to wake means no watcher is armed"
}

test_a_host_without_codex_stands_down() {
  local dir out rc=0
  dir=$(make_primary_dir "$TMP_ROOT/no-codex")
  need_supervision "$dir"
  write_arm_fixture "$dir" unreachable
  # A PATH with the ordinary system tools (jq included) but no codex anywhere.
  out=$(printf '%s\n' "{\"session_id\":\"$PAYLOAD_THREAD\"}" \
    | FM_HOME="$dir" PATH="/usr/bin:/bin" "$FAKE_HARNESS" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
      ' 2>&1) || rc=$?
  expect_code 0 "$rc" "a host without the codex CLI exits 0 silently"
  assert_equals "" "$out" "and says nothing"
  assert_inert "$dir" "a host without the codex CLI"
  pass "fm-codex-stop-autoarm: no codex CLI means no watcher is armed"
}

test_a_child_task_worktree_stays_inert() {
  local base dir
  base=$(make_primary_dir "$TMP_ROOT/wt-base")
  dir=$(make_crewmate_worktree_dir "$base" "$TMP_ROOT/wt-child")
  need_supervision "$dir"
  write_arm_fixture "$dir" unreachable
  run_autoarm "$dir" >/dev/null || true
  assert_inert "$dir" "a linked crewmate worktree"
  pass "fm-codex-stop-autoarm: a child task worktree is never a primary"
}

test_a_home_without_the_session_lock_stays_inert() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/unowned")
  need_supervision "$dir"
  write_arm_fixture "$dir" unreachable
  run_autoarm_unowned "$dir" >/dev/null || true
  assert_inert "$dir" "a session that does not hold the home's lock"
  pass "fm-codex-stop-autoarm: only the lock-owning session may arm"
}

test_away_mode_keeps_it_inert() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/afk")
  need_supervision "$dir"
  write_arm_fixture "$dir" unreachable
  printf 'away\n' > "$dir/state/.afk"
  run_autoarm "$dir" >/dev/null || true
  assert_inert "$dir" "away mode"
  pass "fm-codex-stop-autoarm: away mode leaves supervision to the daemon"
}

test_an_idle_home_stays_inert() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/idle")
  write_arm_fixture "$dir" unreachable
  run_autoarm "$dir" >/dev/null || true
  assert_inert "$dir" "a home with nothing to supervise"
  pass "fm-codex-stop-autoarm: an idle home arms nothing"
}


test_actionable_close_queues_the_wake_into_this_payloads_thread
test_it_keeps_its_own_ledger_separate_from_claudes
test_a_delivered_rewake_is_bound_to_this_session_and_recovery_generation
test_an_unbindable_rewake_is_still_delivered
test_a_rejected_failure_push_is_retried_on_the_next_stop
test_a_healthy_watcher_is_not_announced
test_failure_is_announced_once_per_episode
test_a_payload_with_no_thread_stands_down
test_a_host_without_codex_stands_down
test_a_child_task_worktree_stays_inert
test_a_home_without_the_session_lock_stays_inert
test_away_mode_keeps_it_inert
test_an_idle_home_stays_inert
