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
query=$*
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
args=${FM_FAKE_CURSOR_AGENT_ARGS:-"/opt/cursor-agent --force --trust brief"}
comm=${FM_FAKE_CURSOR_COMM:-${args%% *}}
if [ "$field" = comm= ] && [ -n "${FM_FAKE_CURSOR_PROC_ROOT:-}" ] && [ -n "${FM_FAKE_CURSOR_ARGV0:-}" ]; then
  mkdir -p "$FM_FAKE_CURSOR_PROC_ROOT/$pid"
  printf '%s\0' "$FM_FAKE_CURSOR_ARGV0" > "$FM_FAKE_CURSOR_PROC_ROOT/$pid/cmdline"
fi
case "$query" in
  *"lstart="*)
    printf 'Mon Jan  1 00:00:00 2001\n'
    exit 0 ;;
  # ppid= must be answered separately from args=/comm=: the ancestry walk in
  # fm-harness.sh reads it as a number, and a fake that returns a command
  # string for every -p query would make the walk error instead of ending.
  *"ppid="*) exit 1 ;;
  *"-t "*)
    printf '%s %s\n' "${FM_FAKE_CURSOR_AGENT_PID:-4242}" "$args"
    exit 0 ;;
  *"comm="*)
    printf '%s\n' "$comm"
    exit 0 ;;
  *"-p "*)
    printf '%s\n' "$args"
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

test_mainthread_only_matches_narrowed_cursor_identity() {
  local fakebin out proc_root
  fakebin=$(make_cursor_fakebin "$TMP_ROOT/mainthread-detection")
  proc_root="$TMP_ROOT/mainthread-detection/proc"
  mkdir -p "$proc_root"
  out=$(CURSOR_AGENT= CLAUDECODE= PI_CODING_AGENT= FM_PI_HARNESS= GROK_AGENT= \
    FM_FAKE_CURSOR_COMM=MainThread \
    FM_FAKE_CURSOR_AGENT_ARGS='/usr/bin/node /tmp/claude --foo' \
    PATH="$fakebin:$PATH" "$HARNESS" 2>/dev/null)
  [ "$out" = unknown ] \
    || fail "unverified MainThread with Claude-like args detected as '$out'"
  out=$(CURSOR_AGENT= CLAUDECODE= PI_CODING_AGENT= FM_PI_HARNESS= GROK_AGENT= \
    FM_FAKE_CURSOR_COMM=MainThread \
    FM_FAKE_CURSOR_AGENT_ARGS='/usr/bin/node /tmp/codex --foo' \
    PATH="$fakebin:$PATH" "$HARNESS" 2>/dev/null)
  [ "$out" = unknown ] \
    || fail "unverified MainThread with Codex-like args detected as '$out'"
  out=$(CURSOR_AGENT= CLAUDECODE= PI_CODING_AGENT= FM_PI_HARNESS= GROK_AGENT= \
    FM_FAKE_CURSOR_COMM=MainThread \
    FM_FAKE_CURSOR_AGENT_ARGS='/opt/cursor-agent/versions/current/cursor-agent --force' \
    FM_PROC_ROOT_OVERRIDE="$proc_root" FM_FAKE_CURSOR_PROC_ROOT="$proc_root" \
    FM_FAKE_CURSOR_ARGV0='/opt/cursor-agent/versions/current/cursor-agent' \
    PATH="$fakebin:$PATH" "$HARNESS" 2>/dev/null)
  [ "$out" = cursor ] \
    || fail "verified Cursor MainThread detected as '$out'"
  pass "harness: MainThread is accepted only through narrowed Cursor identity"
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

test_cursor_resolver_falls_back_to_proven_agent_alias() {
  # Only the agent alias on PATH (cursor-agent absent), and it PROVES itself
  # Cursor through its own --help identity: the resolver falls back to it,
  # never failing just because the primary name is missing.
  local rec id out status launch isolated_home
  id=cursor-alias-z5
  rec=$(make_cursor_case cursor-alias "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/cursor-agent"
  fm_fake_cursor_alias "$FAKEBIN_DIR" agent
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
  expect_code 0 "$status" "cursor spawn with a proven agent alias should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/agent' --force --trust" \
    "cursor resolver must fall back to a proven agent alias"
  pass "cursor resolver falls back to a proven agent alias when cursor-agent is absent"
}

test_cursor_resolver_accepts_symlinked_agent_alias() {
  # The alias proves itself structurally instead: it resolves into Cursor's own
  # versioned install tree, so no probe is needed. Either signal alone suffices,
  # so no single vendor string is load-bearing.
  local rec id out status launch isolated_home
  id=cursor-alias-link-za
  rec=$(make_cursor_case cursor-alias-link "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/cursor-agent"
  fm_fake_cursor_alias_symlinked "$FAKEBIN_DIR" agent "$CASE_DIR/share"
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
  expect_code 0 "$status" "cursor spawn with a structurally proven alias should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "cursor-agent' --force --trust" \
    "the alias must launch through its canonical Cursor path"
  pass "cursor resolver accepts an agent alias that resolves into Cursor's install tree"
}

test_cursor_resolver_rejects_unrelated_agent() {
  # An ordinary executable that merely happens to be named `agent`, and that
  # exits 0 for everything including --help. Launching it with Cursor's flags
  # is the hazard this refusal exists to prevent, so the spawn must fail rather
  # than type a launch command.
  local rec id out status isolated_home
  id=cursor-alias-impostor-zb
  rec=$(make_cursor_case cursor-alias-impostor "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/cursor-agent"
  fm_fake_unrelated_agent "$FAKEBIN_DIR"
  isolated_home="$CASE_DIR/nohome"
  mkdir -p "$isolated_home"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$isolated_home" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "cursor spawn must refuse an unrelated executable named agent"
  assert_contains "$out" "no verified cursor executable" \
    "the refusal must name the missing verified cursor executable"
  if [ -s "$LAUNCH_LOG" ]; then
    fail "a refused cursor spawn must never type a launch command"
  fi
  pass "cursor resolver refuses an unrelated executable named agent"
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
  assert_contains "$out" "plus '$isolated_home/.local/bin/cursor-agent' and '$isolated_home/.local/bin/agent'" \
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

test_muse_launch_unsets_cursor_agent() {
  # muse is markerless, so an inherited CURSOR_AGENT=1 would make a muse worker
  # detect itself as cursor. It was the one verified harness the launch boundary
  # omitted; the rule is now stated once for every non-cursor harness, so muse
  # is covered by construction rather than by an added template exception.
  # Marker absence is asserted INSIDE the launched process, not in the launch
  # command's source text.
  local rec id out status launch envlog probe_out xdg_config xdg_data
  id=muse-under-cursor-zc
  rec=$(make_cursor_case muse-under-cursor "$id")
  read_case_record "$rec"
  printf '%s\n' muse > "$HOME_DIR/config/crew-harness"
  xdg_config="$CASE_DIR/xdgconfig"
  xdg_data="$CASE_DIR/xdgdata"
  mkdir -p "$xdg_config/muse" "$xdg_data"
  printf '{"key":"test"}\n' > "$xdg_config/muse/auth.json"
  cat > "$FAKEBIN_DIR/muse" <<'SH'
#!/usr/bin/env bash
printf 'cursor_agent=%s\n' "${CURSOR_AGENT:-unset}" >> "${FM_FAKE_MUSE_ENV:-/dev/null}"
exec "${FM_HARNESS_PROBE:-true}"
SH
  chmod +x "$FAKEBIN_DIR/muse"
  envlog="$CASE_DIR/muse.env"
  : > "$envlog"
  : > "$LAUNCH_LOG"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' CURSOR_AGENT=1 \
    XDG_CONFIG_HOME="$xdg_config" XDG_DATA_HOME="$xdg_data" \
    FM_FAKE_MUSE_EXECUTABLE="$FAKEBIN_DIR/muse" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "muse spawn under CURSOR_AGENT=1 should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    "env -u CURSOR_AGENT "*) : ;;
    *) fail "muse launch must unset CURSOR_AGENT at the launch boundary"$'\n'"launch: $launch" ;;
  esac
  # The fake ps otherwise reports a cursor-agent ancestor for every pid, which
  # would answer this case from the fixture instead of from the marker.
  probe_out=$(CURSOR_AGENT=1 PATH="$FAKEBIN_DIR:$PATH" \
    FM_FAKE_CURSOR_AGENT_ARGS='/bin/bash' \
    FM_HARNESS_PROBE="$HARNESS" FM_FAKE_MUSE_ENV="$envlog" \
    bash -c "$launch")
  [ "$probe_out" != cursor ] \
    || fail "a muse worker still detected itself as cursor from an inherited marker"
  assert_contains "$(cat "$envlog")" "cursor_agent=unset" \
    "the muse child inherited the CURSOR_AGENT marker despite the launch-boundary unset"
  pass "muse launch unsets CURSOR_AGENT inside the launched process"
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
    FM_FAKE_CURSOR_AGENT_ARGS="$FAKEBIN_DIR/cursor-agent --force --trust brief" \
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
  # A PROVEN alias: it resolves into Cursor's own versioned install tree, so
  # both the resolver and worker-server discovery accept it. An unrelated
  # /opt/agent is covered by the negative cases above and below.
  fm_fake_cursor_alias_symlinked "$FAKEBIN_DIR" agent "$CASE_DIR/share"
  ( exec sleep 300 ) &
  worker_pid=$!
  disown
  sleep 0.3
  kill -0 "$worker_pid" 2>/dev/null || fail "cursor-worker-alias-z8: worker stand-in did not start"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_CURSOR_AGENT_ARGS="$FAKEBIN_DIR/agent --force --trust brief" \
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
    FM_FAKE_CURSOR_AGENT_ARGS="$FAKEBIN_DIR/cursor-agent --force --trust brief" \
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

# make_spaced_comm_proc <root> <pid> <starttime>
# A synthetic /proc/<pid>/stat whose parenthesized comm contains spaces AND a
# closing parenthesis, which is what shifts every positional field after it. A
# reader that takes `$22` off the raw line records the wrong number here; the
# shared parse strips through the FINAL `)` first and reads index 19 of the
# remainder, so it records the real starttime.
make_spaced_comm_proc() {
  local root=$1 pid=$2 starttime=$3 i line
  mkdir -p "$root/$pid"
  line="$pid (node (worker server))"
  # Fields 3..21: state plus the eighteen numeric fields before starttime.
  line="$line S 1 1 1 0 -1 4194304"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do line="$line $i"; done
  line="$line $starttime 0 0"
  printf '%s\n' "$line" > "$root/$pid/stat"
}

test_worker_server_identity_survives_spaced_comm() {
  # Spawn's recorded identity and teardown's re-check must be the SAME parse:
  # if they disagree on a spaced comm, the recycled-pid guard silently stops
  # protecting anything.
  local proc_root spawn_id teardown_id recycled
  proc_root="$TMP_ROOT/spaced-proc"
  make_spaced_comm_proc "$proc_root" 4242 987654

  spawn_id=$(FM_PROC_ROOT_OVERRIDE="$proc_root" bash -c \
    ". '$ROOT/bin/fm-process-identity-lib.sh'; fm_process_identity 4242")
  [ "$spawn_id" = "starttime=987654" ] \
    || fail "spaced comm parsed as '$spawn_id', expected starttime=987654"

  teardown_id=$(FM_PROC_ROOT_OVERRIDE="$proc_root" bash -c \
    ". '$ROOT/bin/fm-process-identity-lib.sh'; fm_process_identity 4242")
  [ "$spawn_id" = "$teardown_id" ] \
    || fail "spawn recorded '$spawn_id' but teardown read '$teardown_id'"

  FM_PROC_ROOT_OVERRIDE="$proc_root" bash -c \
    ". '$ROOT/bin/fm-process-identity-lib.sh'; fm_process_identity_matches 4242 '$spawn_id'" \
    || fail "the recorded identity must match the process it was recorded from"

  # Same pid, different starttime: a recycled pid must never match.
  recycled="$TMP_ROOT/spaced-proc-recycled"
  make_spaced_comm_proc "$recycled" 4242 111111
  if FM_PROC_ROOT_OVERRIDE="$recycled" bash -c \
    ". '$ROOT/bin/fm-process-identity-lib.sh'; fm_process_identity_matches 4242 '$spawn_id'"; then
    fail "a recycled pid with a different starttime must not match the recorded identity"
  fi
  pass "worker-server identity is parsed identically at spawn and teardown for a spaced comm"
}

test_process_identity_portable_lstart_fallback() {
  # When /proc is absent (override to an empty root), the neutral owner falls
  # back to a self-describing lstart= identity from ps.
  local identity
  identity=$(FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proc-here" bash -c \
    ". '$ROOT/bin/fm-process-identity-lib.sh'; fm_process_identity $$")
  case "$identity" in
    lstart=*) ;;
    *) fail "portable path must emit lstart=..., got '$identity'" ;;
  esac
  FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proc-here" bash -c \
    ". '$ROOT/bin/fm-process-identity-lib.sh'; fm_process_identity_matches $$ '$identity'" \
    || fail "portable lstart identity must match the live process"
  pass "fm_process_identity: portable no-/proc path emits matching lstart identity"
}

test_cursor_worker_server_reaped_after_spaced_comm_record() {
  # End to end: spawn records the identity from a spaced-comm /proc, teardown
  # re-checks it with the same parse, and the matching process is reaped.
  local rec id out status worker_pid proc_root recorded
  id=cursor-worker-spaced-zd
  rec=$(make_cursor_case cursor-worker-spaced "$id")
  read_case_record "$rec"
  ( exec sleep 300 ) &
  worker_pid=$!
  disown
  sleep 0.3
  kill -0 "$worker_pid" 2>/dev/null || fail "$id: worker stand-in did not start"
  proc_root="$CASE_DIR/proc"
  make_spaced_comm_proc "$proc_root" "$worker_pid" 5551212

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_PROC_ROOT_OVERRIDE="$proc_root" \
    FM_FAKE_CURSOR_AGENT_ARGS="$FAKEBIN_DIR/cursor-agent --force --trust brief" \
    FM_FAKE_CURSOR_AGENT_PID=4242 FM_FAKE_CURSOR_WORKER_PID=$worker_pid \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "cursor spawn with a spaced-comm worker-server should succeed"$'\n'"$out"
  recorded=$(grep '^cursor_worker_server_start=' "$HOME_DIR/state/$id.meta" | tail -1)
  [ "$recorded" = "cursor_worker_server_start=starttime=5551212" ] \
    || fail "spawn recorded '$recorded', expected the spaced-comm starttime 5551212"
  kill -KILL "$worker_pid" 2>/dev/null || true
  pass "spawn records the spaced-comm starttime teardown later re-checks"
}

test_cursor_refuses_backends_without_worker_server_discovery() {
  # zellij, orca, and cmux expose no pane process tree, so cursor's detached
  # worker-server could never be recorded and would leak. The refusal must land
  # before any endpoint, launch command, or task metadata exists.
  local rec id out status backend
  for backend in zellij orca cmux; do
    id="cursor-backend-$backend-ze"
    rec=$(make_cursor_case "cursor-backend-$backend" "$id")
    read_case_record "$rec"
    # Present the backend CLIs so the spawn reaches the cursor refusal rather
    # than stopping earlier on a missing tool: the point of the case is that
    # cursor is refused on an OTHERWISE USABLE backend.
    fm_fake_exit0 "$FAKEBIN_DIR" zellij orca cmux
    : > "$LAUNCH_LOG"
    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --backend "$backend" --mode no-mistakes --yolo off 2>&1) \
      && status=0 || status=$?
    [ "$status" -ne 0 ] || fail "cursor spawn on backend=$backend must be refused"
    assert_contains "$out" "backend=$backend" \
      "the refusal must name the selected backend"
    assert_contains "$out" "tmux, herdr" \
      "the refusal must name the backends cursor supports"
    assert_contains "$out" "worker-server" \
      "the refusal must say worker-server discovery is unavailable"
    if [ -e "$HOME_DIR/state/$id.meta" ]; then
      fail "a refused cursor spawn on backend=$backend must not publish task metadata"
    fi
    if [ -s "$LAUNCH_LOG" ]; then
      fail "a refused cursor spawn on backend=$backend must not type a launch command"
    fi
  done
  pass "cursor refuses zellij, orca, and cmux before any endpoint, launch, or metadata"
}

# --- run all tests (order matters: simpler checks first) ---------------------

test_cursor_env_marker
test_cursor_env_marker_wins_over_claudecode
test_mainthread_only_matches_narrowed_cursor_identity
test_cursor_launch_command_typed
test_cursor_model_flag_threaded
test_cursor_effort_recorded_not_emitted
test_cursor_resolver_prefers_cursor_agent_over_agent
test_cursor_resolver_falls_back_to_proven_agent_alias
test_cursor_resolver_accepts_symlinked_agent_alias
test_cursor_resolver_rejects_unrelated_agent
test_cursor_resolver_unix_home_fallback
test_cursor_missing_binary_refusal
test_non_cursor_launch_unsets_cursor_agent
test_muse_launch_unsets_cursor_agent
test_cursor_worker_server_recorded_at_spawn
test_cursor_worker_server_alias_uses_portable_identity
test_cursor_worker_server_absent_record_is_omitted
test_worker_server_identity_survives_spaced_comm
test_process_identity_portable_lstart_fallback
test_cursor_worker_server_reaped_after_spaced_comm_record
test_cursor_refuses_backends_without_worker_server_discovery
