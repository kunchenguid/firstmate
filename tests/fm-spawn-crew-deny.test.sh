#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's crew-scoped permissions.deny injection.
#
# A claude CREW (ship/scout) launch must carry a --settings file holding the
# crew-scoped deny set; a secondmate (a firstmate instance, not a crew) and every
# other harness must NOT. These tests drive fm-spawn through launch construction
# with a fake tmux pane and a real isolated git worktree (same rig as
# fm-spawn-dispatch-profile.test.sh): the fake tmux captures the literal launch
# command sent with `tmux send-keys -l`, and the generated deny JSON is inspected
# directly. This is deliberately a pure config-inspection test - it never executes
# any denied command (the captain's hard verification limit), so a deny that
# silently failed to load could not run the command here anyway.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-crew-deny)

# Every Bash(...) / Read(...) rule the deny set must contain. Egress, token
# exfiltration, force-push, catastrophic-delete circuit breakers, and secret-path
# Read-tool blocks (report data/sec-automode-scout-q3, quick win 1 + npmrc hygiene).
# shellcheck disable=SC2016  # $HOME is a literal deny-pattern token, not a shell expansion
REQUIRED_DENY=(
  'Bash(curl:*)'
  'Bash(wget:*)'
  'Bash(gh auth token:*)'
  'Bash(git push --force:*)'
  'Bash(git push -f:*)'
  'Bash(git push --force-with-lease:*)'
  'Bash(rm -rf /:*)'
  'Bash(rm -rf ~:*)'
  'Bash(rm -rf $HOME:*)'
  'Read(~/.ssh/**)'
  'Read(~/.aws/**)'
  'Read(~/.kube/**)'
  'Read(~/.npmrc)'
  'Read(~/.claude/.credentials.json)'
  'Read(~/.docker/config.json)'
)

# Patterns that MUST NOT appear, or the deny set would break a legitimate crew
# workflow: plain git push to a task branch, gh api POST, kubectl reads, and the
# package managers reading their own feeds at the OS level.
FORBIDDEN_DENY=(
  'Bash(git push:*)'
  'Bash(gh api'
  'Bash(kubectl'
  'Bash(yarn'
  'Bash(npm'
  'Bash(helm'
  'Bash(treehouse'
  'Bash(tasks-axi'
)

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
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_valid_json() {
  local path=$1 msg=$2
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$path" \
    >/dev/null 2>&1 || fail "$msg (invalid JSON at $path)"
}

assert_deny_set_complete() {
  local path=$1 rule
  assert_valid_json "$path" "deny settings file is not valid JSON"
  for rule in "${REQUIRED_DENY[@]}"; do
    assert_grep "$rule" "$path" "deny set missing required rule: $rule"
  done
  for rule in "${FORBIDDEN_DENY[@]}"; do
    assert_no_grep "$rule" "$path" "deny set over-blocks a legitimate workflow: $rule"
  done
}

test_claude_ship_gets_deny_settings() {
  local rec id out status launch deny
  id=crew-deny-ship-z1
  rec=$(make_spawn_case crew-deny-ship claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude ship spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude kind=ship" "spawn did not report a claude ship crew"

  launch=$(cat "$LAUNCH_LOG")
  deny="/tmp/fm-$id/crew-deny.settings.json"
  assert_contains "$launch" "claude --dangerously-skip-permissions --settings '$deny'" \
    "claude ship launch did not carry the crew deny --settings flag"
  assert_present "$deny" "claude ship spawn did not generate the deny settings file"
  assert_deny_set_complete "$deny"
  pass "claude ship crew launch carries a complete, non-over-blocking deny --settings file"
}

test_claude_scout_gets_deny_settings() {
  local rec id out status launch deny
  id=crew-deny-scout-z2
  rec=$(make_spawn_case crew-deny-scout claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "claude scout spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude kind=scout" "spawn did not report a claude scout crew"

  launch=$(cat "$LAUNCH_LOG")
  deny="/tmp/fm-$id/crew-deny.settings.json"
  assert_contains "$launch" "--settings '$deny'" "claude scout launch did not carry the crew deny --settings flag"
  assert_present "$deny" "claude scout spawn did not generate the deny settings file"
  assert_deny_set_complete "$deny"
  pass "claude scout crew launch carries the deny --settings file"
}

test_claude_secondmate_omits_deny_settings() {
  local rec id sm out status launch deny
  id=crew-deny-secondmate-z3
  rec=$(make_spawn_case crew-deny-secondmate claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "claude secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude kind=secondmate" "spawn did not report a claude secondmate"

  launch=$(cat "$LAUNCH_LOG")
  deny="/tmp/fm-$id/crew-deny.settings.json"
  assert_not_contains "$launch" "--settings" "secondmate (a firstmate instance, not a crew) must not carry the crew deny --settings flag"
  assert_absent "$deny" "secondmate spawn must not generate the crew deny settings file"
  pass "a claude secondmate launches WITHOUT the crew deny set"
}

test_non_claude_harness_omits_deny_settings() {
  local rec id out status launch deny
  id=crew-deny-codex-z4
  rec=$(make_spawn_case crew-deny-codex codex "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex ship spawn should succeed"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report a codex crew"

  launch=$(cat "$LAUNCH_LOG")
  deny="/tmp/fm-$id/crew-deny.settings.json"
  assert_not_contains "$launch" "--settings" "a non-claude harness must not carry the claude-only crew deny --settings flag"
  assert_absent "$deny" "a non-claude harness must not generate the claude deny settings file"
  pass "a non-claude crew harness launches WITHOUT the claude-only deny set"
}

test_claude_ship_gets_deny_settings
test_claude_scout_gets_deny_settings
test_claude_secondmate_omits_deny_settings
test_non_claude_harness_omits_deny_settings

echo "# all fm-spawn-crew-deny tests passed"
