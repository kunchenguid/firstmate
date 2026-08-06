#!/usr/bin/env bash
# Behavior tests for the verified Cursor Agent CLI crewmate adapter.
#
# The launch tests drive fm-spawn through meta writing and launch construction
# with a fake tmux pane and a real isolated git worktree. The fake tmux captures
# the literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would type into the pane without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

cleanup_cursor_harness() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_cursor_harness EXIT

make_cursor_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_tty}"*) printf '%s\n' "${FM_FAKE_PANE_TTY:-/dev/pts/99}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # Fake ps/pgrep so the worker-server discovery can simulate the pane's
  # process tree: ps -t <tty> reports a cursor-agent process, and pgrep -P
  # reports its worker-server child. The parent pid and child pid come from
  # env so each test controls the topology.
cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"lstart="*)
    printf 'Mon Jan  1 00:00:00 2001\n'
    exit 0 ;;
  *"-t "*)
    printf '%s %s\n' "${FM_FAKE_CURSOR_AGENT_PID:-4242}" "${FM_FAKE_CURSOR_AGENT_ARGS:-"/opt/cursor-agent --force --trust brief"}"
    exit 0 ;;
  *"-p "*)
    printf '%s\n' "${FM_FAKE_CURSOR_AGENT_ARGS:-"/opt/cursor-agent --force --trust brief"}"
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  cat > "$fakebin/pgrep" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"index.js worker-server"*)
    [ -n "${FM_FAKE_CURSOR_WORKER_PID:-}" ] || exit 1
    printf '%s\n' "$FM_FAKE_CURSOR_WORKER_PID"
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/pgrep"
  fm_fake_exit0 "$fakebin" treehouse cursor-agent
  printf '%s\n' "$fakebin"
}

make_cursor_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  shift
  id=$1
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_cursor_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' cursor > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

# --- harness detection: CURSOR_AGENT=1 marker --------------------------------

test_cursor_env_marker() {
  local out
  out=$(CURSOR_AGENT=1 "$HARNESS" 2>/dev/null)
  [ "$out" = cursor ] || fail "CURSOR_AGENT=1 must detect as cursor, got '$out'"
  pass "CURSOR_AGENT=1 detects as cursor"
}

# --- harness detection: CURSOR_AGENT=1 wins over CLAUDECODE=1 -----------------

test_cursor_env_marker_wins_over_claudecode() {
  local out
  out=$(CURSOR_AGENT=1 CLAUDECODE=1 "$HARNESS" 2>/dev/null)
  [ "$out" = cursor ] || fail "CURSOR_AGENT=1 must win over CLAUDECODE=1, got '$out'"
  pass "CURSOR_AGENT=1 wins over CLAUDECODE=1"
}

# --- launch: --force, --trust, env sanitization, encoded brief, no --worktree --

test_cursor_launch_command_typed() {
  local rec id out status expected launch resolved
  id=cursor-launch-z1
  rec=$(make_cursor_case cursor-launch "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "cursor spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=cursor" "spawn did not report cursor harness"
  assert_grep "harness=cursor" "$HOME_DIR/state/$id.meta" "meta missing harness=cursor"
  launch=$(cat "$LAUNCH_LOG")
  resolved="$FAKEBIN_DIR/cursor-agent"
  expected="env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT '$resolved' --force --trust \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "cursor launch did not match the canonical command"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "cursor spawn resolves cursor-agent from PATH and types --force --trust with env sanitization and the encoded brief"
}

test_cursor_model_flag_threaded() {
  local rec id out status launch
  id=cursor-model-z2
  rec=$(make_cursor_case cursor-model "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet)
  status=$?
  expect_code 0 "$status" "cursor spawn with --model should succeed"
  assert_grep "model=sonnet" "$HOME_DIR/state/$id.meta" "meta missing model=sonnet"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/cursor-agent' --force --trust --model 'sonnet' \"" \
    "cursor launch did not thread the model flag"
  pass "cursor receives --model in the typed launch command"
}

test_cursor_effort_recorded_not_emitted() {
  local rec id out status launch
  id=cursor-effort-z3
  rec=$(make_cursor_case cursor-effort "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "cursor spawn with --effort should succeed"
  assert_grep "effort=high" "$HOME_DIR/state/$id.meta" "meta missing effort=high"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/cursor-agent' --force --trust --model 'sonnet'" \
    "cursor launch lost the model flag when effort was recorded"
  assert_not_contains "$launch" "--effort" "cursor launch must not emit an effort flag"
  pass "cursor records effort in meta but never emits it"
}

test_cursor_resolver_prefers_cursor_agent_over_agent() {
  # Both names on PATH: cursor-agent wins (agent is the legacy alias and too
  # generic to trust as the primary pick).
  local rec id out status launch
  id=cursor-prefer-z4
  rec=$(make_cursor_case cursor-prefer "$id")
  read_case_record "$rec"
  fm_fake_exit0 "$FAKEBIN_DIR" agent

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "cursor spawn with both names on PATH should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/cursor-agent' --force --trust" \
    "cursor resolver must prefer cursor-agent over the agent alias"
  pass "cursor resolver prefers cursor-agent over the agent alias"
}

test_cursor_resolver_falls_back_to_agent_alias() {
  # Only the agent alias on PATH (cursor-agent absent): the resolver falls
  # back to it, never failing just because the primary name is missing.
  local rec id out status launch isolated_home
  id=cursor-alias-z5
  rec=$(make_cursor_case cursor-alias "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/cursor-agent"
  fm_fake_exit0 "$FAKEBIN_DIR" agent
  isolated_home="$CASE_DIR/nohome"
  mkdir -p "$isolated_home"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$isolated_home" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "cursor spawn with only the agent alias should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/agent' --force --trust" \
    "cursor resolver must fall back to the agent alias"
  pass "cursor resolver falls back to the agent alias when cursor-agent is absent"
}

test_cursor_resolver_unix_home_fallback() {
  # Neither name on PATH but $HOME/.local/bin/cursor-agent exists: the
  # resolver finds the user-local install (non-interactive PATHs often omit
  # ~/.local/bin).
  local rec id out status launch isolated_home fallback_bin
  id=cursor-home-z6
  rec=$(make_cursor_case cursor-home "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/cursor-agent"
  isolated_home="$CASE_DIR/nohome"
  fallback_bin="$isolated_home/.local/bin"
  mkdir -p "$fallback_bin"
  fm_fake_exit0 "$fallback_bin" cursor-agent
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$isolated_home" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "cursor spawn with the ~/.local/bin fallback should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$fallback_bin/cursor-agent' --force --trust" \
    "cursor resolver must find the ~/.local/bin install"
  pass "cursor resolver finds the ~/.local/bin fallback install"
}

test_cursor_missing_binary_refusal() {
  local rec id out status isolated_home
  id=cursor-missing-z7
  rec=$(make_cursor_case cursor-missing "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/cursor-agent"
  isolated_home="$CASE_DIR/nohome"
  mkdir -p "$isolated_home"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$isolated_home" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a missing cursor executable should refuse the spawn"
  assert_contains "$out" "searched PATH for 'cursor-agent' and 'agent'" \
    "missing cursor refusal did not name the searched PATH names"
  assert_contains "$out" "fallbacks '$isolated_home/.local/bin/cursor-agent' and '$isolated_home/.local/bin/agent'" \
    "missing cursor refusal did not name the searched fallback paths"
  assert_absent "$HOME_DIR/state/$id.meta" "missing cursor refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing cursor refusal typed a launch command"
  pass "cursor refuses safely and actionably when no executable is available, naming every name and path searched"
}

test_non_cursor_launch_unsets_cursor_agent() {
  local rec id out status launch envlog probe_out
  id=claude-under-cursor-z5
  rec=$(make_cursor_case claude-under-cursor "$id")
  read_case_record "$rec"
  printf '%s\n' claude > "$HOME_DIR/config/crew-harness"
  # Fake claude: report whether the CURSOR_AGENT marker survived the launch
  # boundary, set its own verified marker on children, then run harness
  # detection - mirroring a real claude worker spawned from a cursor
  # secondmate, whose tmux server inherits CURSOR_AGENT=1.
  cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
printf 'cursor_agent=%s\n' "${CURSOR_AGENT:-unset}" >> "${FM_FAKE_CLAUDE_ENV:-/dev/null}"
export CLAUDECODE=1
exec "${FM_HARNESS_PROBE:-true}"
SH
  chmod +x "$FAKEBIN_DIR/claude"
  envlog="$CASE_DIR/claude.env"
  : > "$envlog"
  : > "$LAUNCH_LOG"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' GROK_HOME="$HOME_DIR/grok-home" CURSOR_AGENT=1 \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "claude spawn under CURSOR_AGENT=1 should succeed"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    "env -u CURSOR_AGENT "*) : ;;
    *) fail "non-cursor launch must unset CURSOR_AGENT at the launch boundary"$'\n'"launch: $launch" ;;
  esac
  probe_out=$(CURSOR_AGENT=1 PATH="$FAKEBIN_DIR:$PATH" \
    FM_HARNESS_PROBE="$HARNESS" FM_FAKE_CLAUDE_ENV="$envlog" \
    bash -c "$launch")
  [ "$probe_out" = claude ] \
    || fail "harness detection under the captured launch resolved '$probe_out', expected claude"
  assert_contains "$(cat "$envlog")" "cursor_agent=unset" \
    "the child inherited the CURSOR_AGENT marker despite the launch-boundary unset"
  pass "non-cursor launch unsets CURSOR_AGENT; detection resolves to the actual target harness"
}

# --- worker-server record: the cursor child daemon pid lands in meta ---------

test_cursor_worker_server_recorded_at_spawn() {
  local rec id out status worker_pid
  id=cursor-worker-z8
  rec=$(make_cursor_case cursor-worker "$id")
  read_case_record "$rec"
  # A real long-running process stands in for cursor's background worker-server
  # so /proc/<pid>/stat carries a real starttime; the fake ps/pgrep in the
  # fakebin report it as the pane's worker-server child.
  ( exec sleep 300 ) &
  worker_pid=$!
  disown
  sleep 0.3
  kill -0 "$worker_pid" 2>/dev/null || fail "cursor-worker-z8: worker stand-in did not start"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_CURSOR_AGENT_PID=4242 FM_FAKE_CURSOR_WORKER_PID=$worker_pid \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "cursor spawn with a worker-server child should succeed"
  assert_grep "cursor_worker_server=$worker_pid" "$HOME_DIR/state/$id.meta" \
    "cursor spawn did not record the worker-server pid in meta"
  assert_grep "cursor_worker_server_start=" "$HOME_DIR/state/$id.meta" \
    "cursor spawn did not record the worker-server starttime identity"
  kill -KILL "$worker_pid" 2>/dev/null || true
  pass "cursor spawn records the worker-server pid and starttime identity in meta"
}

test_cursor_worker_server_alias_uses_portable_identity() {
  local rec id out status worker_pid
  id=cursor-worker-alias-z8
  rec=$(make_cursor_case cursor-worker-alias "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/cursor-agent"
  fm_fake_exit0 "$FAKEBIN_DIR" agent
  ( exec sleep 300 ) &
  worker_pid=$!
  disown
  sleep 0.3
  kill -0 "$worker_pid" 2>/dev/null || fail "cursor-worker-alias-z8: worker stand-in did not start"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_CURSOR_AGENT_ARGS='/opt/agent --force --trust brief' \
    FM_FAKE_CURSOR_WORKER_PID=$worker_pid FM_PROC_ROOT_OVERRIDE="$CASE_DIR/no-proc" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "cursor alias spawn without /proc should succeed"
  assert_grep "cursor_worker_server=$worker_pid" "$HOME_DIR/state/$id.meta" \
    "cursor alias spawn did not record the worker-server pid"
  assert_grep 'cursor_worker_server_start=lstart=' "$HOME_DIR/state/$id.meta" \
    "cursor alias spawn did not record the portable lstart identity"
  kill -KILL "$worker_pid" 2>/dev/null || true
  pass "cursor worker-server discovery handles agent alias and portable identity"
}

test_cursor_worker_server_absent_record_is_omitted() {
  local rec id out status
  id=cursor-worker-none-z9
  rec=$(make_cursor_case cursor-worker-none "$id")
  read_case_record "$rec"
  # No worker-server child: the fake pgrep exits 1, so no record is written and
  # the spawn still succeeds (teardown falls back to its cwd-based reaper).
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_CURSOR_AGENT_PID=4242 FM_FAKE_CURSOR_WORKER_PID='' \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "cursor spawn without a worker-server child should succeed"
  if grep -q '^cursor_worker_server=' "$HOME_DIR/state/$id.meta" 2>/dev/null; then
    fail "cursor spawn without a worker-server child must not write a worker-server record"
  fi
  pass "cursor spawn without a worker-server child records nothing and still succeeds"
}

# --- run all tests (order matters: simpler checks first) ---------------------

test_cursor_env_marker
test_cursor_env_marker_wins_over_claudecode
test_cursor_launch_command_typed
test_cursor_model_flag_threaded
test_cursor_effort_recorded_not_emitted
test_cursor_resolver_prefers_cursor_agent_over_agent
test_cursor_resolver_falls_back_to_agent_alias
test_cursor_resolver_unix_home_fallback
test_cursor_missing_binary_refusal
test_non_cursor_launch_unsets_cursor_agent
test_cursor_worker_server_recorded_at_spawn
test_cursor_worker_server_alias_uses_portable_identity
test_cursor_worker_server_absent_record_is_omitted
