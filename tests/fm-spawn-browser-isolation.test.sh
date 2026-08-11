#!/usr/bin/env bash
# tests/fm-spawn-browser-isolation.test.sh - spawn-path regressions proving every
# firstmate-launched agent receives the browser-isolation environment, using fake
# tmux panes and real isolated git worktrees.
#
# AGENTS.md section 3 points every agent at chrome-devtools-axi and crewmates run
# with permissions bypassed, so the browser that tool reaches is inside the
# agent's blast radius. chrome-devtools-axi's own default is already an isolated
# throwaway profile, but a default is not a guarantee: any CHROME_DEVTOOLS_AXI_*
# value exported into firstmate's environment is inherited by every agent it
# launches, and the unnamed "default" session is one shared bridge. fm-spawn
# therefore pins the isolating choice on the launch command itself.
#
# These tests pin the assembled launch command, which is the interface firstmate
# actually ships to a pane. The companion guard
# tests/fm-browser-isolation-live-e2e.test.sh proves the two facts a launch string
# cannot show: that the pinned values really select an isolated profile in the
# installed chrome-devtools-axi, and that they survive into the shell a real
# harness gives its agent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-browser-isolation)

# The five profile inputs fm-spawn must neutralise, and the value each must carry.
# Written out here rather than derived from bin/fm-spawn.sh so this stays an
# independent pin: a change to the implementation has to be made twice, on purpose.
PINNED_AUTO_CONNECT='CHROME_DEVTOOLS_AXI_AUTO_CONNECT=0'
PINNED_EMPTY_VARS=(
  'CHROME_DEVTOOLS_AXI_BROWSER_URL='
  'CHROME_DEVTOOLS_AXI_USER_DATA_DIR='
  'CHROME_DEVTOOLS_AXI_CHROME_ARGS='
  'CHROME_DEVTOOLS_AXI_PORT='
)

# Fake tmux: answers the pane-path query and logs every literal `send-keys -l`
# argument, so the launch command firstmate would run is observable without
# starting a harness.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
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
  fm_fake_exit0 "$fakebin" treehouse
  # pi resolves and probes a concrete executable before composing its template.
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = --help ] && printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
exit 0
SH
  chmod +x "$fakebin/pi"
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> <harness> <task-id>: build an isolated home, project,
# worktree and fake bin dir, then echo the fields the run helpers need.
make_spawn_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Delivery contract: mode=no-mistakes' > "$home/data/$id/brief.md"
  : > "$launchlog"
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$launchlog"
}

read_case_record() {
  local IFS='|'
  read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<< "$1"
}

# run_ship_spawn: drive a real fm-spawn ship dispatch through the fake pane.
# Extra arguments are appended to the fm-spawn invocation.
run_ship_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 id=$5 proj=$6
  shift 6
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off "$@" 2>&1
}

# assert_full_pin <launch> <expected-session> <label>: every pinned variable is
# present with its exact value, and the whole block precedes the harness binary.
assert_full_pin() {
  local launch=$1 session=$2 label=$3 var
  assert_contains "$launch" "$PINNED_AUTO_CONNECT" \
    "$label: launch does not refuse chrome-devtools-axi's attach-to-the-captain's-Chrome mode"
  for var in "${PINNED_EMPTY_VARS[@]}"; do
    # A space-or-end boundary distinguishes the pinned empty value from an
    # inherited non-empty one, which would read as "VAR=/some/path".
    case "$launch" in
      *"$var "*) : ;;
      *) fail "$label: launch does not neutralise $var (a non-empty inherited value would select a real profile)" ;;
    esac
  done
  assert_contains "$launch" "CHROME_DEVTOOLS_AXI_SESSION='$session'" \
    "$label: launch does not bind this task to its own browser session"
  case "$launch" in
    "CHROME_DEVTOOLS_AXI_"*|*" CHROME_DEVTOOLS_AXI_AUTO_CONNECT=0 "*) : ;;
    *) fail "$label: the pin is not positioned as an environment prefix on the launch command" ;;
  esac
}

test_every_verified_harness_carries_the_pin() {
  local harness rec id launch checked=0
  # muse and kimi resolve a real installed binary before composing a template, so
  # they cannot be driven from a fake bin dir here; the live guard covers them.
  for harness in claude codex opencode grok pi; do
    id="browseriso-$harness-b1"
    rec=$(make_spawn_case "browseriso-$harness" "$harness" "$id")
    read_case_record "$rec"
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null \
      || fail "$harness spawn failed"
    launch=$(cat "$LAUNCH_LOG")
    assert_full_pin "$launch" "fm-$id" "$harness"
    checked=$((checked + 1))
  done
  [ "$checked" -eq 5 ] || fail "expected 5 harnesses checked, got $checked"
  pass "every verified harness template launches inside the browser-isolation environment"
}

test_raw_launch_command_escape_hatch_carries_the_pin() {
  local rec id launch
  # The escape hatch bypasses launch_template entirely. It is the case a
  # per-template pin would silently miss, so it is pinned explicitly.
  id=browseriso-raw-b2
  rec=$(make_spawn_case browseriso-raw claude "$id")
  read_case_record "$rec"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    'some-unverified-agent --flag' >/dev/null || fail "raw launch command spawn failed"
  launch=$(cat "$LAUNCH_LOG")
  assert_full_pin "$launch" "fm-$id" "raw launch command"
  assert_contains "$launch" 'some-unverified-agent --flag' \
    "raw launch command was not preserved"
  pass "the unverified-adapter escape hatch is covered by the same pin"
}

test_each_task_gets_its_own_browser_session() {
  local rec launch_a launch_b id_a=browseriso-sess-a-b3 id_b=browseriso-sess-b-b3
  rec=$(make_spawn_case browseriso-sess-a claude "$id_a")
  read_case_record "$rec"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_a" "$PROJ_DIR" >/dev/null \
    || fail "first spawn failed"
  launch_a=$(cat "$LAUNCH_LOG")

  rec=$(make_spawn_case browseriso-sess-b claude "$id_b")
  read_case_record "$rec"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id_b" "$PROJ_DIR" >/dev/null \
    || fail "second spawn failed"
  launch_b=$(cat "$LAUNCH_LOG")

  assert_contains "$launch_a" "CHROME_DEVTOOLS_AXI_SESSION='fm-$id_a'" "first task got the wrong session"
  assert_contains "$launch_b" "CHROME_DEVTOOLS_AXI_SESSION='fm-$id_b'" "second task got the wrong session"
  assert_not_contains "$launch_a" "CHROME_DEVTOOLS_AXI_SESSION='fm-$id_b'" \
    "two tasks would share one browser, so one could read a page the other authenticated"
  pass "two tasks launch on two separate browser sessions"
}

test_longest_accepted_task_id_still_yields_a_usable_session_name() {
  local rec id launch session
  # chrome-devtools-axi rejects a session name outside 1-64 chars of
  # [A-Za-z0-9._-], and that rejection breaks EVERY browser command for the agent
  # that inherits it. fm_task_id_creation_valid accepts ids up to 64 chars, so the
  # "fm-" prefix is exactly what can push the name out of range.
  id=$(printf '%64s' '' | tr ' ' 'b')
  rec=$(make_spawn_case browseriso-longid claude "$id")
  read_case_record "$rec"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" >/dev/null \
    || fail "spawn with a maximum-length task id failed"
  launch=$(cat "$LAUNCH_LOG")
  session=$(printf '%s\n' "$launch" | sed -n "s/.*CHROME_DEVTOOLS_AXI_SESSION='\([^']*\)'.*/\1/p")
  [ -n "$session" ] || fail "no browser session name in the launch command"
  [ "${#session}" -le 64 ] \
    || fail "session name is ${#session} chars; chrome-devtools-axi refuses over 64 and the agent loses the browser entirely"
  case "$session" in
    fm-*) : ;;
    *) fail "session name '$session' is not recognisable as firstmate's" ;;
  esac
  printf '%s' "$session" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' \
    || fail "session name '$session' is outside the charset chrome-devtools-axi accepts"
  pass "a maximum-length task id still produces a session name the browser tool accepts"
}

test_secondmate_agents_are_isolated_too() {
  local case_dir home smhome launchlog fakebin id=browseriso-sm-b5 launch out
  # A secondmate is a firstmate instance that also browses, so it needs its own
  # isolated session for the same reason a crewmate does.
  case_dir="$TMP_ROOT/browseriso-sm"
  home="$case_dir/home"
  smhome="$case_dir/smhome"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$smhome/data" "$smhome/state" "$smhome/config" "$smhome/projects" "$smhome/bin"
  printf '%s\n' claude > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  touch "$smhome/AGENTS.md"
  printf '%s\n' 'charter' > "$home/data/$id/brief.md"
  : > "$launchlog"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$smhome" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$smhome" --secondmate 2>&1) \
    || fail "secondmate spawn failed"$'\n'"$out"

  launch=$(cat "$launchlog")
  assert_full_pin "$launch" "fm-$id" "secondmate"
  pass "a secondmate agent launches inside its own browser-isolation environment"
}

test_every_verified_harness_carries_the_pin
test_raw_launch_command_escape_hatch_carries_the_pin
test_each_task_gets_its_own_browser_session
test_longest_accepted_task_id_still_yields_a_usable_session_name
test_secondmate_agents_are_isolated_too

fm_test_cleanup "$TMP_ROOT"
