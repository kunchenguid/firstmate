#!/usr/bin/env bash
# Behavior tests for the partial cursor-agent crew oneshot adapter:
# launch template, harness usage listing, and crew-harness resolution.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cursor-agent-harness)
SPAWN="$ROOT/bin/fm-spawn.sh"

# Extract launch_template() from fm-spawn.sh and evaluate the cursor-agent case
# without running a full spawn (avoids backend/treehouse fixtures).
extract_launch_template() {
  # shellcheck disable=SC1090
  eval "$(sed -n '/^launch_template()/,/^}/p' "$ROOT/bin/fm-spawn.sh")"
}

test_usage_lists_cursor_agent() {
  assert_grep 'cursor-agent' "$ROOT/bin/fm-harness.sh" \
    "fm-harness.sh should list cursor-agent in usage/comments"
  pass "fm-harness.sh lists cursor-agent"
}

test_launch_template_cursor_agent() {
  local got
  extract_launch_template
  got=$(launch_template cursor-agent) || fail "launch_template cursor-agent returned non-zero"
  assert_contains "$got" 'cursor-agent -p --force --trust' \
    "launch template missing oneshot flags"
  # Intentional literals: template must contain the characters $(pwd) / $(cat …),
  # not their expansions. shellcheck SC2016 would otherwise false-positive.
  # shellcheck disable=SC2016
  assert_contains "$got" '--workspace "$(pwd)"' \
    "launch template missing --workspace"
  # shellcheck disable=SC2016
  assert_contains "$got" '"$(cat __BRIEF__)"' \
    "launch template missing brief cat"
  if launch_template cursor >/dev/null 2>&1; then
    fail "bare 'cursor' must not have a launch template (canonical name is cursor-agent)"
  fi
  pass "launch_template emits cursor-agent oneshot command"
}

test_launch_template_cursor_agent_rejects_secondmate() {
  extract_launch_template
  if launch_template cursor-agent secondmate >/dev/null 2>&1; then
    fail "cursor-agent must not have a secondmate launch template"
  fi
  pass "launch_template refuses cursor-agent secondmate"
}

test_crew_harness_resolves_cursor_agent() {
  local cfg got
  cfg="$TMP_ROOT/config"
  mkdir -p "$cfg"
  printf '%s\n' 'cursor-agent' > "$cfg/crew-harness"
  # Force own unknown: clear every Layer-1 marker detect_own checks, including
  # CURSOR_AGENT which this Builder session itself may set.
  got=$(
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT \
      FM_CONFIG_OVERRIDE="$cfg" \
      "$ROOT/bin/fm-harness.sh" crew
  )
  [ "$got" = "cursor-agent" ] || fail "crew resolved '$got', expected cursor-agent"
  pass "config/crew-harness=cursor-agent resolves crew to cursor-agent"
}

test_detect_own_cursor_agent_env() {
  local got cfg
  cfg="$TMP_ROOT/empty-config"
  mkdir -p "$cfg"
  got=$(
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
      CURSOR_AGENT=1 \
      FM_CONFIG_OVERRIDE="$cfg" \
      "$ROOT/bin/fm-harness.sh"
  )
  [ "$got" = "cursor-agent" ] || fail "detect_own with CURSOR_AGENT=1 returned '$got'"
  pass "CURSOR_AGENT=1 detects as cursor-agent"
}

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
  has-session|new-session|new-window|set-window-option|kill-window) exit 0 ;;
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

test_spawn_uses_cursor_agent_oneshot() {
  local id case_dir home proj wt fakebin launchlog out status launch
  id=cursor-spawn-z6
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' 'cursor-agent' > "$home/config/crew-harness"
  printf 'cursor-agent brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" cursor-agent-wt
  touch "$home/state/.last-watcher-beat"
  : > "$launchlog"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
      FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$proj" 2>&1
  )
  status=$?
  rm -rf "/tmp/fm-$id"
  expect_code 0 "$status" "cursor-agent crew spawn should succeed"
  assert_contains "$out" "spawned $id harness=cursor-agent kind=ship" \
    "spawn did not report cursor-agent ship launch"
  assert_grep 'harness=cursor-agent' "$home/state/$id.meta" \
    "spawn meta missing cursor-agent harness"
  assert_grep 'kind=ship' "$home/state/$id.meta" \
    "spawn meta should record a crew ship task"
  launch=$(cat "$launchlog")
  # shellcheck disable=SC2016
  assert_contains "$launch" 'cursor-agent -p --force --trust --workspace "$(pwd)"' \
    "spawn launch command missing cursor-agent oneshot flags"
  assert_contains "$launch" "\"\$(cat '$home/data/$id/brief.md')\"" \
    "spawn launch command missing quoted brief path"
  pass "fm-spawn uses cursor-agent oneshot template and records cursor-agent metadata"
}

test_usage_lists_cursor_agent
test_launch_template_cursor_agent
test_launch_template_cursor_agent_rejects_secondmate
test_crew_harness_resolves_cursor_agent
test_detect_own_cursor_agent_env
test_spawn_uses_cursor_agent_oneshot
