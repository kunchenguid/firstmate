#!/usr/bin/env bash
# tests/fm-spawn-remote-control.test.sh - bin/fm-spawn.sh's --remote-control
# (alias --rc) flag: Claude Code Remote Control at launch (AGENTS.md's spawn
# contract; docs.claude.com/en/docs/claude-code/remote-control).
#
# The guarantees under test:
#   - claude harness: the flag inserts --remote-control into the launch command
#     and records remote_control=1 in state/<id>.meta.
#   - absent flag: no --remote-control in the launch command, no remote_control=
#     line in meta (byte-identical to today's meta shape).
#   - non-claude harness: --remote-control is refused before any endpoint or
#     meta is created.
#   - raw launch command: --remote-control is refused even when its executable
#     name resolves to claude.
#   - remote secondmate: --remote-control is refused without changing registry
#     or task metadata state.
#   - it composes correctly with --model/--effort (all three flags land in the
#     launch command in template order, none dropped or garbled).
#   - --rc is a working alias for --remote-control.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-remote-control)

# Fake tmux: answers the pane-path query and logs every literal `send-keys -l`
# payload plus every plain `send-keys <text> Enter` payload (the GOTMPDIR
# export and the launch command itself) one per line, in send order - the same
# capture technique as tests/fm-trace-context-spawn.test.sh.
make_fakebin() {
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
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> [harness]: a scratch home + real git worktree + brief, wired
# for a plain ship spawn (KIND=ship, --mode no-mistakes --yolo off). Echoes
# "<home>|<project>|<worktree>|<fakebin>|<launchlog>|<id>".
make_case() {
  local name=$1 harness=${2:-claude} case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-z1
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id"
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

# run_spawn <home> <wt> <fakebin> <launchlog> <id> <project> [extra flags...]
run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

launch_line() {
  # The claude launch is sent as one literal `send-keys -l` payload; find it by
  # the fixed CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION prefix every claude launch
  # carries (bin/fm-spawn.sh launch_template()).
  grep 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION' "$1" | tail -1
}

test_flag_inserts_remote_control_for_claude() {
  local rec out status meta line
  rec=$(make_case rc-on claude)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" --remote-control)
  status=$?
  expect_code 0 "$status" "claude spawn with --remote-control should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $CASE_ID" "spawn should report success"

  line=$(launch_line "$LAUNCH_LOG")
  assert_contains "$line" ' --remote-control ' "the launch command must carry --remote-control"

  meta="$HOME_DIR/state/$CASE_ID.meta"
  assert_grep "remote_control=1" "$meta" "meta must record remote_control=1"
  pass "--remote-control inserts --remote-control into a claude launch and records remote_control=1 in meta"
}

test_flag_absent_is_a_no_op() {
  local rec out status meta line
  rec=$(make_case rc-off claude)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "plain claude spawn should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $CASE_ID" "spawn should report success"

  line=$(launch_line "$LAUNCH_LOG")
  assert_not_contains "$line" '--remote-control' "an ordinary spawn must never carry --remote-control"

  meta="$HOME_DIR/state/$CASE_ID.meta"
  assert_no_grep "remote_control=" "$meta" "an ordinary spawn's meta must stay byte-identical (no remote_control= line)"
  pass "no --remote-control flag: no --remote-control in the launch and no remote_control= in meta"
}

test_refuses_for_non_claude_harness() {
  local rec out status
  rec=$(make_case rc-codex codex)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" --remote-control)
  status=$?
  [ "$status" -ne 0 ] || fail "--remote-control on a codex spawn should be refused"$'\n'"$out"
  assert_contains "$out" "Remote Control" "the refusal should name Claude Code's Remote Control"
  assert_contains "$out" "codex" "the refusal should name the rejected harness"
  [ ! -e "$HOME_DIR/state/$CASE_ID.meta" ] \
    || fail "a refused --remote-control spawn must not write task metadata"
  pass "--remote-control is refused for a non-claude harness, before any metadata is written"
}

test_refuses_for_raw_claude_launch_command() {
  local rec out status
  rec=$(make_case rc-raw-claude claude)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" \
    "claude --verbose" --remote-control)
  status=$?
  [ "$status" -ne 0 ] || fail "--remote-control on a raw claude command should be refused"$'\n'"$out"
  assert_contains "$out" "cannot be reliably applied to a raw launch command" \
    "the refusal should explain why raw launch commands cannot use Remote Control"
  [ ! -e "$HOME_DIR/state/$CASE_ID.meta" ] \
    || fail "a refused raw-command Remote Control spawn must not write task metadata"
  [ ! -s "$LAUNCH_LOG" ] \
    || fail "a refused raw-command Remote Control spawn must not reach the launch backend"
  pass "--remote-control is refused for a raw claude launch command"
}

test_refuses_for_remote_secondmate() {
  local rec out status registry registry_before remote_home remote_root
  rec=$(make_case rc-remote-secondmate claude)
  read_case_record "$rec"
  registry="$HOME_DIR/data/secondmates.md"
  registry_before="$HOME_DIR/data/secondmates.before"
  remote_home="$HOME_DIR/remote-home"
  remote_root="$HOME_DIR/remote-root"
  printf '%s\n' \
    "- $CASE_ID - Remote fixture (host: remote-mac; root: $remote_root; home: $remote_home; scope: remote work; projects: sample; added 2026-08-08)" \
    > "$registry"
  cp "$registry" "$registry_before"

  out=$(env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$CASE_ID" --secondmate --remote-control 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--remote-control on a remote secondmate should be refused"$'\n'"$out"
  assert_contains "$out" "not yet supported for remote secondmates" \
    "the refusal should name the unsupported remote-secondmate boundary"
  [ ! -e "$HOME_DIR/state/$CASE_ID.meta" ] \
    || fail "a refused remote-secondmate Remote Control spawn must not write task metadata"
  cmp -s "$registry_before" "$registry" \
    || fail "a refused remote-secondmate Remote Control spawn changed the registry"
  [ ! -e "$HOME_DIR/state/.spawn-$CASE_ID.lock" ] \
    || fail "a refused remote-secondmate Remote Control spawn touched task lock state"
  pass "--remote-control is refused before remote secondmate state changes"
}

test_composes_with_model_and_effort() {
  local rec out status meta line
  rec=$(make_case rc-compose claude)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" \
    --remote-control --model opus --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with --remote-control, --model, --effort should succeed"$'\n'"$out"

  line=$(launch_line "$LAUNCH_LOG")
  assert_contains "$line" "--dangerously-skip-permissions --remote-control --model 'opus' --effort 'high' \"" \
    "all three flags must land in template order with no dropped or garbled flag"

  meta="$HOME_DIR/state/$CASE_ID.meta"
  assert_grep "remote_control=1" "$meta" "meta must still record remote_control=1 alongside model/effort"
  assert_grep "model=opus" "$meta" "meta must record model=opus"
  assert_grep "effort=high" "$meta" "meta must record effort=high"
  pass "--remote-control composes correctly with --model/--effort"
}

test_rc_alias_matches_remote_control() {
  local rec out status meta line
  rec=$(make_case rc-alias claude)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" --rc)
  status=$?
  expect_code 0 "$status" "claude spawn with --rc should succeed"$'\n'"$out"

  line=$(launch_line "$LAUNCH_LOG")
  assert_contains "$line" ' --remote-control ' "the --rc alias must insert the same --remote-control flag"

  meta="$HOME_DIR/state/$CASE_ID.meta"
  assert_grep "remote_control=1" "$meta" "the --rc alias must record remote_control=1 exactly like --remote-control"
  pass "--rc is a working alias for --remote-control"
}

test_flag_inserts_remote_control_for_claude
test_flag_absent_is_a_no_op
test_refuses_for_non_claude_harness
test_refuses_for_raw_claude_launch_command
test_refuses_for_remote_secondmate
test_composes_with_model_and_effort
test_rc_alias_matches_remote_control

echo "# all fm-spawn-remote-control tests passed"
