#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh pi project-skill loading (`__PISKILL__`).
#
# pi does not auto-discover project skills (it ignores .claude/skills and
# .pi/skills at the project root) but accepts `--skill <dir>`. fm-spawn threads
# `--skill <worktree>/.claude/skills` into the pi CREWMATE/SCOUT launch template
# only, and only when the resolved worktree actually has a .claude/skills
# directory. These tests pin that contract by capturing the literal launch
# command sent through a fake tmux pane, mirroring fm-spawn-dispatch-profile's
# launch-capture mechanism.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-piskill)

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
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> <harness> <id...>: echoes a |delimited| record of the
# case dirs. Mirrors fm-spawn-dispatch-profile's helper, kept local so this
# suite owns its own assumptions.
make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
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
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# Resolve the canonical .claude/skills path the same way fm-spawn does
# (cd + pwd -P), so the assertion is robust to /tmp -> /private/tmp symlinks.
abs_skills() {
  (cd "$1/.claude/skills" && pwd -P)
}

# pi crewmate spawn on a worktree that HAS .claude/skills must thread
# `--skill <abs>/.claude/skills` into the launch, with correct spacing so the
# following `-e` flag stays separated.
test_pi_crewmate_gets_skill_when_dir_present() {
  local rec id out status launch meta
  id=piskill-on-z1
  rec=$(make_spawn_case piskill-on pi "$id")
  read_case_record "$rec"
  mkdir -p "$WT_DIR/.claude/skills"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi crewmate spawn with .claude/skills should succeed"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "harness=pi" "$meta" "meta missing harness=pi"

  launch=$(cat "$LAUNCH_LOG")
  abs_skill_skills=$(abs_skills "$WT_DIR")
  assert_contains "$launch" "--skill '$abs_skill_skills' -e " \
    "pi launch did not thread --skill '<abspath>/.claude/skills' with correct spacing before -e"
  pass "pi crewmate threads --skill when the worktree has .claude/skills"
}

# pi crewmate spawn on a worktree WITHOUT .claude/skills must add no --skill
# flag, leaving the launch byte-identical to the pre-change pi crewmate template.
test_pi_crewmate_no_skill_when_dir_absent() {
  local rec id out status launch
  id=piskill-off-z2
  rec=$(make_spawn_case piskill-off pi "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi crewmate spawn without .claude/skills should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--skill" "pi launch must not pass --skill when .claude/skills is absent"
  assert_contains "$launch" "pi -e " "pi launch without skills should still have its bare -e flag"
  pass "pi crewmate omits --skill when the worktree has no .claude/skills"
}

# Non-pi harnesses never get --skill even when .claude/skills exists, because
# the flag is pi-specific and their templates carry no __PISKILL__ token.
test_non_pi_crewmate_never_gets_skill() {
  local harness rec id out status launch
  for harness in codex claude; do
    id="piskill-$harness-z3"
    rec=$(make_spawn_case "piskill-$harness" "$harness" "$id")
    read_case_record "$rec"
    mkdir -p "$WT_DIR/.claude/skills"

    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness crewmate spawn should succeed"
    assert_contains "$out" "spawned $id harness=$harness kind=ship" "$harness spawn did not report a ship crewmate"
    launch=$(cat "$LAUNCH_LOG")
    assert_not_contains "$launch" "--skill" "$harness launch must never carry the pi-only --skill flag"
  done
  pass "codex and claude crewmate launches never receive --skill"
}

# A pi --secondmate launch must never receive --skill: secondmates are
# supervisors in a firstmate home, not project workers. The .claude/skills dir is
# created in the secondmate home too, proving the KIND != secondmate guard (and
# the tokenless secondmate template) hold even when the directory exists.
test_pi_secondmate_never_gets_skill() {
  local rec id sm out status launch
  id=piskill-secondmate-z4
  rec=$(make_spawn_case piskill-sm pi "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  mkdir -p "$sm/.claude/skills"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi secondmate spawn should succeed"
  assert_contains "$out" "harness=pi kind=secondmate" "secondmate spawn did not resolve to a pi secondmate launch"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--skill" "pi secondmate launch must never carry --skill"
  pass "pi --secondmate launch never receives --skill"
}

test_pi_crewmate_gets_skill_when_dir_present
test_pi_crewmate_no_skill_when_dir_absent
test_non_pi_crewmate_never_gets_skill
test_pi_secondmate_never_gets_skill

echo "# all fm-spawn-piskill tests passed"