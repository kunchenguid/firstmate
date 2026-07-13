#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-use-tmux-tests)
USE_TMUX="$ROOT/bin/fm-use-tmux.sh"

test_use_tmux_smoke_uses_configured_project_and_fm_home_data() {
  local case_dir=fm-use-tmux-smoke-project
  local home fake_root project fakebin log out data_override
  home="$TMP_ROOT/$case_dir/home"
  fake_root="$TMP_ROOT/$case_dir/fakeroot"
  project="$TMP_ROOT/$case_dir/project"
  fakebin="$TMP_ROOT/$case_dir/fakebin"
  log="$TMP_ROOT/$case_dir/spawn.log"
  data_override="$TMP_ROOT/$case_dir/data-override"
  mkdir -p "$home/config" "$home/state" "$home/data" "$fake_root/bin" "$fakebin"
  fm_git_init_commit "$project"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -V) printf 'tmux 3.4\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  cat > "$fake_root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf 'FM_HOME=%s args=%s\n' "$FM_HOME" "$*" >> "${FM_TEST_SPAWN_LOG:?}"
mkdir -p "$FM_HOME/state"
touch "$FM_HOME/state/$1.turn-ended"
printf 'spawned %s\n' "$1"
SH
  chmod +x "$fake_root/bin/fm-spawn.sh"
  cat > "$fake_root/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf 'teardown %s complete\n' "$1"
SH
  chmod +x "$fake_root/bin/fm-teardown.sh"

  out=$(PATH="$fakebin:$PATH" TMUX=/tmp/tmux-test XDG_CONFIG_HOME="$TMP_ROOT/$case_dir/xdg" \
    FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" \
    FM_TEST_SPAWN_LOG="$log" FM_TMUX_SMOKE_PROJECT="$project" \
    "$USE_TMUX" start 2>&1)
  assert_contains "$out" "tmux daily-driver ready" "tmux start should complete"
  assert_grep "FM_HOME=$home" "$log" "smoke should pass active FM_HOME to fm-spawn"
  assert_grep "$project" "$log" "smoke should pass the configured smoke project to fm-spawn"
  assert_no_grep "projects/falkordb-stak" "$log" "smoke should not use a hardcoded project path"
  assert_present "$data_override/smoke-use-tmux/brief.md" "smoke brief should be written under FM_DATA_OVERRIDE"
  assert_absent "$home/data/smoke-use-tmux/brief.md" "smoke brief should not be written under FM_HOME/data when data is overridden"
  assert_absent "$fake_root/data/smoke-use-tmux/brief.md" "smoke brief should not be written under FM_ROOT/data"
  pass "use-tmux smoke uses configured project and resolved data dir"
}

test_use_tmux_smoke_selects_project_under_fm_home() {
  local case_dir=fm-use-tmux-smoke-auto-project
  local home fake_root project fakebin log
  home="$TMP_ROOT/$case_dir/home"
  fake_root="$TMP_ROOT/$case_dir/fakeroot"
  project="$home/projects/alpha"
  fakebin="$TMP_ROOT/$case_dir/fakebin"
  log="$TMP_ROOT/$case_dir/spawn.log"
  mkdir -p "$home/config" "$home/state" "$home/data" "$fake_root/bin" "$fakebin"
  fm_git_init_commit "$project"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -V) printf 'tmux 3.4\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  cat > "$fake_root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_SPAWN_LOG:?}"
mkdir -p "$FM_HOME/state"
touch "$FM_HOME/state/$1.turn-ended"
printf 'spawned %s\n' "$1"
SH
  chmod +x "$fake_root/bin/fm-spawn.sh"
  cat > "$fake_root/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf 'teardown %s complete\n' "$1"
SH
  chmod +x "$fake_root/bin/fm-teardown.sh"

  PATH="$fakebin:$PATH" TMUX=/tmp/tmux-test XDG_CONFIG_HOME="$TMP_ROOT/$case_dir/xdg" \
    FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_TEST_SPAWN_LOG="$log" \
    "$USE_TMUX" start >/dev/null
  assert_grep "$project" "$log" "smoke should auto-select a git repo under FM_HOME/projects"
  pass "use-tmux smoke auto-selects a project under FM_HOME"
}

test_use_tmux_smoke_selects_project_under_projects_override() {
  local case_dir=fm-use-tmux-smoke-projects-override
  local home fake_root projects_override project fakebin log
  home="$TMP_ROOT/$case_dir/home"
  fake_root="$TMP_ROOT/$case_dir/fakeroot"
  projects_override="$TMP_ROOT/$case_dir/projects-override"
  project="$projects_override/alpha"
  fakebin="$TMP_ROOT/$case_dir/fakebin"
  log="$TMP_ROOT/$case_dir/spawn.log"
  mkdir -p "$home/config" "$home/state" "$home/data" "$fake_root/bin" "$fakebin"
  fm_git_init_commit "$project"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -V) printf 'tmux 3.4\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  cat > "$fake_root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_SPAWN_LOG:?}"
mkdir -p "$FM_HOME/state"
touch "$FM_HOME/state/$1.turn-ended"
printf 'spawned %s\n' "$1"
SH
  chmod +x "$fake_root/bin/fm-spawn.sh"
  cat > "$fake_root/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf 'teardown %s complete\n' "$1"
SH
  chmod +x "$fake_root/bin/fm-teardown.sh"

  PATH="$fakebin:$PATH" TMUX=/tmp/tmux-test XDG_CONFIG_HOME="$TMP_ROOT/$case_dir/xdg" \
    FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_PROJECTS_OVERRIDE="$projects_override" \
    FM_TEST_SPAWN_LOG="$log" "$USE_TMUX" start >/dev/null
  assert_grep "$project" "$log" "smoke should auto-select a git repo under FM_PROJECTS_OVERRIDE"
  pass "use-tmux smoke auto-selects a project under FM_PROJECTS_OVERRIDE"
}

test_use_tmux_smoke_uses_configured_project_and_fm_home_data
test_use_tmux_smoke_selects_project_under_fm_home
test_use_tmux_smoke_selects_project_under_projects_override

if [ "${FAIL_COUNT:-0}" -eq 0 ]; then
  printf 'all use-tmux tests passed\n'
  exit 0
fi
printf '%d use-tmux test(s) failed\n' "${FAIL_COUNT}"
exit 1
