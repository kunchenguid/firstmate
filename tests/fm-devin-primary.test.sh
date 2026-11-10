#!/usr/bin/env bash
# tests/fm-devin-primary.test.sh - the Devin primary hook owner
# (bin/fm-devin-primary.sh): the SessionStart lock/pane/daemon contract, the
# Stop-hook guard passthrough and per-turn block cap, and the SessionEnd
# ownership gate.
#
# Every hook runs inside a devin-named fake process (a bash symlink named
# `devin`) so the session-lock ancestry walk resolves exactly as under the real
# CLI. The quiet daemon is a stub (FM_AFK_LAUNCH_ENTRY) that records its own
# identity in the daemon lock and then sleeps - the launch and lock mechanics
# are real, only the watcher is absent, which is also what keeps the turn-end
# guard blocking in the Stop cases.
# shellcheck disable=SC2016 # single quotes are deliberate: $$ and $FM_HOME expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-devin-primary)
fm_git_identity fmtest fmtest@example.invalid

SCRIPT="$ROOT/bin/fm-devin-primary.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/devin"
NAMED_DEVIN="$FAKEBIN/devin"

# The launch path refuses on the harnesses it knows cannot host the daemon; pin
# the primary harness to devin through its test seam, exactly as production
# would detect it from ancestry.
export FM_TEST_HARNESS=devin FM_TEST_SEAM=1
unset PI_CODING_AGENT FM_PI_HARNESS CURSOR_AGENT CURSOR_INVOKED_AS CLAUDECODE GEMINI_CLI ATLASSIAN_AGENT_TYPE ROVODEV_CLI

# A private tmux server for the daemon terminal the launch path creates; never
# the default server.
export TMUX_TMPDIR="$TMP_ROOT/tmux-server"
mkdir -p "$TMUX_TMPDIR"

# A stub daemon for the launch terminal: it records its own pid and identity in
# the home's daemon lock (the real daemon does the same at startup) and then
# stays alive, so fm_afk_daemon_owns_supervision holds. It never runs a
# watcher, so state/.last-watcher-beat stays stale - which is what keeps the
# turn-end guard blocking in the Stop-hook cases.
STUB_DAEMON="$TMP_ROOT/stub-daemon.sh"
cat > "$STUB_DAEMON" <<SH
#!/usr/bin/env bash
set -u
. "$ROOT/bin/fm-wake-lib.sh"
state="\${FM_HOME:?}/state"
mkdir -p "\$state/.supervise-daemon.lock"
printf '%s\n' "\$\$" > "\$state/.supervise-daemon.lock/pid"
fm_pid_identity "\$\$" > "\$state/.supervise-daemon.lock/pid-identity"
sleep 600
SH
chmod +x "$STUB_DAEMON"

BG_PIDS=()
CLEANUP() {
  local pid
  for pid in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  tmux kill-server 2>/dev/null || true
}
trap 'CLEANUP; fm_test_cleanup' EXIT

# An isolated firstmate home: only state/ and config/ matter to the hook, which
# resolves FM_ROOT (the real checkout) separately for primary scope.
make_home() {  # <dir-path>
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
  printf '%s\n' "$dir"
}

# Run a hook subcommand inside a devin-named process, with the pane seam set so
# the launch path can resolve the supervisor endpoint without a real pane.
run_hook() {  # <subcommand> <home> [payload] [extra-env...]
  local sub=$1 home=$2 payload=${3:-'{}'}
  shift 3 || shift $#
  env -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID "$@" \
    FM_HOME="$home" FM_SUPERVISOR_TARGET=test-pane FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_LAUNCH_ENTRY="$STUB_DAEMON" \
    "$NAMED_DEVIN" -c '
      printf "%s" "$1" | bash "$2" "$3" > "$4/out" 2> "$4/err"
      printf "%s\n" "$?" > "$4/rc"
    ' _ "$payload" "$SCRIPT" "$sub" "$home"
  cat "$home/out" 2>/dev/null || true
}

run_hook_rc() { tr -d '[:space:]' < "$1/rc" 2>/dev/null || true; }
run_hook_err() { cat "$1/err" 2>/dev/null || true; }

# A live devin-named process outside the hook's own ancestry: a foreign lock
# owner the reclaim must refuse.
start_foreign_devin() {
  # `bash -c 'sleep 60'` would exec sleep and lose the devin comm; keep the
  # named process alive behind a child so it stays a live foreign harness.
  "$NAMED_DEVIN" -c 'sleep 60 & wait' >/dev/null 2>&1 &
  BG_PIDS+=("$!")
  printf '%s\n' "$!"
}

test_session_start_blocks_on_foreign_lock() {
  local dir foreign out rc
  dir=$(make_home "$TMP_ROOT/start-foreign")
  foreign=$(start_foreign_devin)
  printf '%s\n' "$foreign" > "$dir/state/.lock"
  out=$(run_hook session-start "$dir" '{"source":"startup"}'); rc=$(run_hook_rc "$dir")
  expect_code 0 "$rc" "session-start must report a lock refusal as a JSON block with exit 0"
  assert_contains "$out" '"decision":"block"' "session-start did not block a foreign-held lock: $out"
  assert_contains "$out" "session lock" "session-start block reason did not name the lock: $out"
  [ ! -e "$dir/state/.afk" ] || fail "a lock-refused session-start still entered quiet mode"
  pass "fm-devin-primary session-start: a foreign-held lock blocks the session"
}

test_session_start_blocks_without_a_pane() {
  local dir out rc
  dir=$(make_home "$TMP_ROOT/start-nopane")
  out=$(env -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET \
    FM_HOME="$dir" \
    "$NAMED_DEVIN" -c '
      printf "%s" "{\"source\":\"startup\"}" | bash "$0" session-start
    ' "$SCRIPT"); rc=$?
  expect_code 0 "$rc" "session-start must report a missing pane as a JSON block with exit 0"
  assert_contains "$out" '"decision":"block"' "session-start did not block a pane-less launch: $out"
  assert_contains "$out" "tmux or Herdr" "session-start block reason did not name the pane requirement: $out"
  [ ! -e "$dir/state/.lock" ] || fail "a pane-less session-start still took the session lock"
  [ ! -e "$dir/state/.afk" ] || fail "a pane-less session-start still entered quiet mode"
  pass "fm-devin-primary session-start: no addressable pane blocks the session"
}

test_session_start_ensures_daemon_and_warns_on_wedge_alarm() {
  local dir out rc ctx
  dir=$(make_home "$TMP_ROOT/start-happy")
  out=$(run_hook session-start "$dir" '{"source":"startup"}'); rc=$(run_hook_rc "$dir")
  expect_code 0 "$rc" "session-start failed: $(run_hook_err "$dir")"
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  [ -n "$ctx" ] || fail "session-start did not inject additionalContext: $out"
  assert_contains "$ctx" "lock acquired" "session-start context lost the lock report: $ctx"
  assert_contains "$ctx" "quiet daemon running" "session-start context lost the daemon report: $ctx"
  assert_contains "$ctx" "Run bin/fm-session-start.sh now, once." "session-start context lost the digest nudge: $ctx"
  [ "$(head -n 1 "$dir/state/.afk" 2>/dev/null)" = quiet ] \
    || fail "session-start did not enter quiet mode: $(cat "$dir/state/.afk" 2>/dev/null)"
  kill -0 "$(cat "$dir/state/.supervise-daemon.lock/pid" 2>/dev/null)" 2>/dev/null \
    || fail "the ensure did not leave a live daemon"
  if [ "$(uname)" != Darwin ]; then
    assert_contains "$ctx" "WARNING" "session-start context lost the wedge-alarm warning: $ctx"
    assert_contains "$ctx" "config/wedge-alarm" "wedge-alarm warning did not name the config: $ctx"
  fi
  run_hook_err "$dir" | grep -q "lock acquired" \
    || fail "session-start did not echo its summary to stderr"
  pass "fm-devin-primary session-start: lock, quiet daemon, wedge warning, and context injection"
}

test_stop_passes_guard_block_and_respects_cap() {
  local dir payload out rc i
  dir=$(make_home "$TMP_ROOT/stop-block")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  payload='{"prompt_id":"p-cap","session_id":"s-1","stop_hook_active":false}'
  for i in 1 2 3; do
    out=$(env -u TMUX_PANE \
      FM_HOME="$dir" FM_SUPERVISOR_TARGET=test-pane FM_SUPERVISOR_BACKEND=tmux \
      FM_AFK_LAUNCH_ENTRY="$STUB_DAEMON" FM_DEVIN_STOP_MAX_BLOCKS=3 \
      "$NAMED_DEVIN" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        printf "%s" "$1" | bash "$0" stop
      ' "$SCRIPT" "$payload"); rc=$?
    expect_code 0 "$rc" "stop $i must exit 0 while passing a block through"
    assert_contains "$out" '"decision":"block"' "stop $i did not pass the guard's block through: $out"
    [ "$(cat "$dir/state/.devin-stop-blocks.p-cap" 2>/dev/null)" = "$i" ] \
      || fail "stop $i left counter $(cat "$dir/state/.devin-stop-blocks.p-cap" 2>/dev/null), expected $i"
    if [ "$i" -eq 1 ]; then
      assert_contains "$out" "quiet daemon restart attempt" "a self-healed stop block lost the ensure report: $out"
    fi
  done
  out=$(env -u TMUX_PANE \
    FM_HOME="$dir" FM_SUPERVISOR_TARGET=test-pane FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_LAUNCH_ENTRY="$STUB_DAEMON" FM_DEVIN_STOP_MAX_BLOCKS=3 \
    "$NAMED_DEVIN" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s" "$1" | bash "$0" stop
    ' "$SCRIPT" "$payload"); rc=$?
  expect_code 0 "$rc" "the capped stop must still exit 0"
  [ -z "$out" ] || fail "the 4th stop produced output past the per-turn cap: $out"
  pass "fm-devin-primary stop: guard block passes through as JSON and the per-turn cap fails open"
}

test_stop_silent_outside_lock_ownership() {
  local dir foreign out rc
  dir=$(make_home "$TMP_ROOT/stop-foreign")
  : > "$dir/state/task1.meta"
  foreign=$(start_foreign_devin)
  printf '%s\n' "$foreign" > "$dir/state/.lock"
  out=$(run_hook stop "$dir" '{"prompt_id":"p1","session_id":"s-9","stop_hook_active":false}'); rc=$(run_hook_rc "$dir")
  expect_code 0 "$rc" "a foreign session's stop hook must exit 0"
  [ -z "$out" ] || fail "a foreign session's stop hook produced output: $out"
  pass "fm-devin-primary stop: silent when this session does not own the lock"
}

test_session_end_noop_without_lock_ownership() {
  local dir foreign out rc
  dir=$(make_home "$TMP_ROOT/end-foreign")
  printf 'quiet\n%s\n' "$(date +%s)" > "$dir/state/.afk"
  foreign=$(start_foreign_devin)
  printf '%s\n' "$foreign" > "$dir/state/.lock"
  out=$(run_hook session-end "$dir" '{}'); rc=$(run_hook_rc "$dir")
  expect_code 0 "$rc" "session-end must always exit 0"
  [ -z "$out" ] || fail "session-end produced output: $out"
  [ -e "$dir/state/.afk" ] || fail "session-end stopped supervision it did not own"
  pass "fm-devin-primary session-end: inert when this session does not own the lock"
}

test_session_start_blocks_on_foreign_lock
test_session_start_blocks_without_a_pane
test_session_start_ensures_daemon_and_warns_on_wedge_alarm
test_stop_passes_guard_block_and_respects_cap
test_stop_silent_outside_lock_ownership
test_session_end_noop_without_lock_ownership
