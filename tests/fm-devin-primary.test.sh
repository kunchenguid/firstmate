#!/usr/bin/env bash
# tests/fm-devin-primary.test.sh - the Devin primary hook owner
# (bin/fm-devin-primary.sh): the SessionStart lock/pane/daemon contract, the
# Stop-hook self-heal, guard passthrough and per-turn block cap, the
# documented example config, and the SessionEnd
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

# The hooks act only from a genuine primary code root (a plain checkout, never
# a linked task worktree), so run them from a plain-checkout copy of the
# tracked scripts and docs rather than from $ROOT, which may be a worktree.
CODE_ROOT="$TMP_ROOT/code-root"
mkdir -p "$CODE_ROOT"
cp -R "$ROOT/bin" "$ROOT/docs" "$CODE_ROOT/"
: > "$CODE_ROOT/AGENTS.md"
fm_git_init_commit "$CODE_ROOT" >/dev/null
SCRIPT="$CODE_ROOT/bin/fm-devin-primary.sh"

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

# Run the stop hook as the lock-owning devin session.
run_owned_stop() {  # <home> <payload>
  env -u TMUX_PANE \
    FM_HOME="$1" FM_SUPERVISOR_TARGET=test-pane FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_LAUNCH_ENTRY="$STUB_DAEMON" FM_TURNEND_MAX_BLOCKS=3 \
    "$NAMED_DEVIN" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s" "$1" | bash "$0" stop 2> "$FM_HOME/stop-err"
    ' "$SCRIPT" "$2"
}

test_stop_allows_after_a_successful_heal() {
  local dir out rc
  dir=$(make_home "$TMP_ROOT/stop-heal")
  : > "$dir/state/task1.meta"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_owned_stop "$dir" '{"prompt_id":"p-heal","session_id":"s-1","stop_hook_active":false}'); rc=$?
  expect_code 0 "$rc" "a healed stop must exit 0"
  [ -z "$out" ] || fail "a stop whose self-heal proved a live daemon still blocked on the stale beacon: $out"
  kill -0 "$(cat "$dir/state/.supervise-daemon.lock/pid" 2>/dev/null)" 2>/dev/null \
    || fail "the stop self-heal did not leave a live daemon"
  assert_contains "$(cat "$dir/stop-err" 2>/dev/null)" "quiet daemon running" "the healed stop did not log the ensure result"
  pass "fm-devin-primary stop: a successful self-heal allows the stop"
}

test_away_return_catchup_defers_the_daemon() {
  local dir out rc ctx i
  dir=$(make_home "$TMP_ROOT/catchup")
  printf 'pending\n' > "$dir/state/.afk-return-catchup"
  out=$(run_hook session-start "$dir" '{"source":"startup"}'); rc=$(run_hook_rc "$dir")
  expect_code 0 "$rc" "session-start failed during catch-up: $(run_hook_err "$dir")"
  assert_not_contains "$out" '"decision":"block"' "session-start refused the session while the away-return gate was pending: $out"
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  assert_contains "$ctx" "bin/fm-afk-return.sh check" "session-start context did not name the catch-up gate's check: $ctx"
  [ ! -e "$dir/state/.supervise-daemon.lock" ] || fail "session-start launched a daemon while the catch-up gate was pending"

  out=$(run_owned_stop "$dir" '{"prompt_id":"p-idle","session_id":"s-1","stop_hook_active":false}'); rc=$?
  expect_code 0 "$rc" "an idle stop during catch-up must exit 0"
  [ -z "$out" ] || fail "a stop with nothing in flight blocked during catch-up: $out"

  : > "$dir/state/task1.meta"
  for i in 1 2 3; do
    out=$(run_owned_stop "$dir" '{"prompt_id":"p-catchup","session_id":"s-1","stop_hook_active":false}'); rc=$?
    expect_code 0 "$rc" "catch-up stop $i must exit 0 while blocking"
    assert_contains "$out" '"decision":"block"' "catch-up stop $i with work in flight did not block: $out"
    assert_contains "$out" "bin/fm-afk-return.sh check" "catch-up stop $i did not name the gate's check: $out"
  done
  out=$(run_owned_stop "$dir" '{"prompt_id":"p-catchup","session_id":"s-1","stop_hook_active":false}')
  [ -z "$out" ] || fail "the catch-up block did not fail open past the per-turn cap: $out"
  [ ! -e "$dir/state/.supervise-daemon.lock" ] || fail "a stop launched a daemon while the catch-up gate was pending"

  rm -f "$dir/state/.afk-return-catchup"
  out=$(run_owned_stop "$dir" '{"prompt_id":"p-after","session_id":"s-1","stop_hook_active":false}')
  [ -z "$out" ] || fail "the first stop after the gate cleared did not heal and allow: $out"
  [ "$(head -n 1 "$dir/state/.afk" 2>/dev/null)" = quiet ] || fail "the stop after the gate cleared did not restore quiet mode"
  kill -0 "$(cat "$dir/state/.supervise-daemon.lock/pid" 2>/dev/null)" 2>/dev/null \
    || fail "the stop after the gate cleared did not leave a live daemon"
  pass "fm-devin-primary: a pending away-return gate blocks a busy stop toward its check, then the next stop restores quiet supervision"
}

test_stop_passes_guard_block_and_respects_cap() {
  local dir payload out rc i
  dir=$(make_home "$TMP_ROOT/stop-block")
  : > "$dir/state/task1.meta"
  run_hook ensure "$dir" '' >/dev/null
  expect_code 0 "$(run_hook_rc "$dir")" "ensure failed: $(run_hook_err "$dir")"
  payload='{"prompt_id":"p-cap","session_id":"s-1","stop_hook_active":false}'
  for i in 1 2 3; do
    out=$(run_owned_stop "$dir" "$payload"); rc=$?
    expect_code 0 "$rc" "stop $i must exit 0 while passing a block through"
    assert_contains "$out" '"decision":"block"' "stop $i did not pass the guard's block through: $out"
    assert_contains "$out" "TURN WOULD END BLIND" "stop $i block lost the guard banner: $out"
  done
  out=$(run_owned_stop "$dir" "$payload"); rc=$?
  expect_code 0 "$rc" "the capped stop must still exit 0"
  [ -z "$out" ] || fail "the 4th stop produced output past the per-turn cap: $out"
  out=$(run_owned_stop "$dir" '{"prompt_id":"p-next","session_id":"s-1","stop_hook_active":false}')
  assert_contains "$out" '"decision":"block"' "a new turn did not get a fresh block budget: $out"
  pass "fm-devin-primary stop: guard block passes through as JSON and the per-turn cap fails open"
}

test_stop_reports_a_failed_heal_in_the_block() {
  local dir out
  dir=$(make_home "$TMP_ROOT/stop-heal-fail")
  : > "$dir/state/task1.meta"
  out=$(env -u TMUX_PANE \
    FM_HOME="$dir" FM_SUPERVISOR_TARGET=test-pane FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_LAUNCH_ENTRY=/nonexistent/fm-no-daemon \
    "$NAMED_DEVIN" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s" "$1" | bash "$0" stop 2>/dev/null
    ' "$SCRIPT" '{"prompt_id":"p-fail","session_id":"s-1","stop_hook_active":false}')
  assert_contains "$out" '"decision":"block"' "a stop whose self-heal failed did not block: $out"
  assert_contains "$out" "daemon restart attempt FAILED" "the block lost the failed ensure report: $out"
  pass "fm-devin-primary stop: a failed self-heal rides in the block reason"
}

test_session_start_warns_when_off_is_mixed_with_a_channel() {
  local dir out ctx
  dir=$(make_home "$TMP_ROOT/start-off-mixed")
  printf '%s\n' 'command:true' 'off' > "$dir/config/wedge-alarm"
  out=$(run_hook session-start "$dir" '{"source":"startup"}')
  expect_code 0 "$(run_hook_rc "$dir")" "session-start failed: $(run_hook_err "$dir")"
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  assert_contains "$ctx" "disables every wedge-alarm channel" "off beside another channel did not warn that every channel is off: $ctx"
  pass "fm-devin-primary session-start: any off directive warns that every wedge-alarm channel is off"
}

# Print the pid in <home>'s daemon lock, waiting briefly for a just-launched
# stub daemon to write it.
wait_daemon_pid() {  # <home>
  local i=0
  while [ "$i" -lt 100 ] && [ ! -s "$1/state/.supervise-daemon.lock/pid-identity" ]; do
    i=$((i + 1))
    sleep 0.05
  done
  cat "$1/state/.supervise-daemon.lock/pid" 2>/dev/null
}

test_session_start_names_a_kept_away_record() {
  local dir out ctx before
  dir=$(make_home "$TMP_ROOT/start-away")
  env -u TMUX_PANE FM_HOME="$dir" FM_SUPERVISOR_TARGET=test-pane FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_LAUNCH_ENTRY="$STUB_DAEMON" FM_AFK_MODE=away \
    bash -c '"$0" enter && "$0" start' "$CODE_ROOT/bin/fm-afk-launch.sh" >/dev/null 2>&1 \
    || fail "could not start away mode for the fixture"
  [ "$(head -n 1 "$dir/state/.afk" 2>/dev/null)" = away ] || fail "the fixture did not record away mode"
  before=$(wait_daemon_pid "$dir")
  out=$(run_hook session-start "$dir" '{"source":"startup"}')
  expect_code 0 "$(run_hook_rc "$dir")" "session-start failed: $(run_hook_err "$dir")"
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  assert_contains "$ctx" "away daemon running" "a kept away record was not named as away: $ctx"
  assert_not_contains "$ctx" "quiet daemon" "a kept away record was labelled quiet: $ctx"
  [ "$(cat "$dir/state/.supervise-daemon.lock/pid" 2>/dev/null)" = "$before" ] \
    || fail "session-start replaced a live daemon that already supervised this pane and harness"
  pass "fm-devin-primary session-start: an existing away record is reported as away"
}

# Start a daemon for <home> the way an earlier primary would have: through the
# real launch path, for <pane> under <harness>, in <mode>. Prints its pid.
start_earlier_daemon() {  # <home> <pane> <harness> <mode>
  env -u TMUX_PANE FM_HOME="$1" FM_SUPERVISOR_TARGET="$2" FM_SUPERVISOR_BACKEND=tmux \
    FM_AFK_LAUNCH_ENTRY="$STUB_DAEMON" FM_TEST_HARNESS="$3" FM_AFK_MODE="$4" \
    bash -c '"$0" enter && "$0" start' "$CODE_ROOT/bin/fm-afk-launch.sh" >/dev/null 2>&1 \
    || fail "could not start the earlier $3 daemon for the fixture"
  wait_daemon_pid "$1"
}

test_session_start_replaces_a_daemon_for_another_pane() {
  local dir old new out ctx
  dir=$(make_home "$TMP_ROOT/start-stale-pane")
  old=$(start_earlier_daemon "$dir" dead-pane devin away)
  kill -0 "$old" 2>/dev/null || fail "the earlier daemon is not running"
  out=$(run_hook session-start "$dir" '{"source":"startup"}')
  expect_code 0 "$(run_hook_rc "$dir")" "session-start failed: $(run_hook_err "$dir")"
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  new=$(cat "$dir/state/.supervise-daemon.lock/pid" 2>/dev/null)
  ! kill -0 "$old" 2>/dev/null || fail "the daemon supervising the dead pane is still running"
  if [ -z "$new" ] || [ "$new" = "$old" ] || ! kill -0 "$new" 2>/dev/null; then
    fail "session-start did not leave a fresh live daemon (old $old, new ${new:-none})"
  fi
  assert_contains "$ctx" "away daemon running: pid $new supervising pane test-pane" "the context did not report the fresh daemon's recorded pane: $ctx"
  [ "$(head -n 1 "$dir/state/.afk" 2>/dev/null)" = away ] || fail "the restart did not keep away mode"
  [ -f "$dir/state/.afk-contract" ] || fail "the restart archived the away record"
  [ -z "$(ls -A "$dir/state/afk-contracts" 2>/dev/null)" ] || fail "the restart archived an away record under state/afk-contracts"
  pass "fm-devin-primary session-start: a live daemon for another pane is replaced and the away record survives"
}

test_session_start_replaces_a_daemon_for_another_harness() {
  local dir old new out ctx
  dir=$(make_home "$TMP_ROOT/start-stale-harness")
  : > "$dir/config/supervision-host-off"
  old=$(start_earlier_daemon "$dir" test-pane claude quiet)
  kill -0 "$old" 2>/dev/null || fail "the earlier claude daemon is not running"
  out=$(run_hook session-start "$dir" '{"source":"startup"}')
  expect_code 0 "$(run_hook_rc "$dir")" "session-start failed: $(run_hook_err "$dir")"
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  new=$(cat "$dir/state/.supervise-daemon.lock/pid" 2>/dev/null)
  ! kill -0 "$old" 2>/dev/null || fail "the daemon judging the pane as claude is still running"
  if [ -z "$new" ] || [ "$new" = "$old" ] || ! kill -0 "$new" 2>/dev/null; then
    fail "session-start did not leave a fresh live daemon (old $old, new ${new:-none})"
  fi
  assert_contains "$ctx" "quiet daemon running: pid $new supervising pane test-pane" "the context did not report the fresh quiet daemon: $ctx"
  [ "$(cut -f5 "$dir/state/.afk-daemon-terminal" 2>/dev/null)" = devin ] \
    || fail "the fresh daemon's record does not name the devin harness: $(cat "$dir/state/.afk-daemon-terminal" 2>/dev/null)"
  pass "fm-devin-primary session-start: a live daemon launched for another primary harness is replaced"
}

test_example_config_hooks_run_the_wrapper() {
  local dir config cmd out
  dir=$(make_home "$TMP_ROOT/example-config")
  config=$(sed "s|<FIRSTMATE_HOME>|$CODE_ROOT|g" "$ROOT/docs/examples/devin-primary-config.json")
  [ "$(printf '%s' "$config" | jq -r '.version')" = 1 ] || fail "the example config is not a version 1 Devin config"
  [ "$(printf '%s' "$config" | jq -r '.read_config_from.claude')" = false ] || fail "the example config imports Claude config"
  [ "$(printf '%s' "$config" | jq -r '.hooks.SessionStart[0].hooks[0].fail_closed')" = true ] \
    || fail "the example SessionStart hook does not fail closed"
  cmd=$(printf '%s' "$config" | jq -r '.hooks.SessionStart[0].hooks[0].command')
  out=$(env -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET FM_HOME="$dir" \
    "$NAMED_DEVIN" -c 'printf "%s" "{\"source\":\"startup\"}" | bash -c "$0"' "$cmd")
  assert_contains "$out" "devin --config" "the example SessionStart hook did not reach the wrapper's pane refusal: $out"
  cmd=$(printf '%s' "$config" | jq -r '.hooks.PreToolUse[] | select(.matcher == "^ask_user_question$") | .hooks[0].command')
  [ "$(bash -c "$cmd" | jq -r '.decision')" = block ] || fail "the example PreToolUse hook does not block ask_user_question"
  pass "fm-devin-primary: the documented example config runs the wrapper and blocks the question dialog"
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
test_session_start_warns_when_off_is_mixed_with_a_channel
test_session_start_names_a_kept_away_record
test_session_start_replaces_a_daemon_for_another_pane
test_session_start_replaces_a_daemon_for_another_harness
test_example_config_hooks_run_the_wrapper
test_stop_allows_after_a_successful_heal
test_stop_passes_guard_block_and_respects_cap
test_stop_reports_a_failed_heal_in_the_block
test_away_return_catchup_defers_the_daemon
test_stop_silent_outside_lock_ownership
test_session_end_noop_without_lock_ownership
