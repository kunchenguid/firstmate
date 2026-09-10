#!/usr/bin/env bash
# Behavior tests for the Treehouse pool root selected by fm-spawn.sh.
#
# These cases drive the executable spawn interface with a fake tmux pane and a
# real isolated git worktree.
# The fake pane records the submitted worktree-acquisition command and the final
# worker launch command without starting a harness.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-treehouse-root)

make_case() {
  local name=$1 case_dir home project worktree fakebin command_log launch_log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  command_log="$case_dir/commands.log"
  launch_log="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$project" "$worktree" "worktree-$name"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin|$command_log|$launch_log"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR COMMAND_LOG LAUNCH_LOG <<EOF
$1
EOF
}

run_worker_spawn() {
  local id=$1
  fm_test_spawn_brief "$HOME_DIR" "$id" "Exercise Treehouse root selection for $id."
  : > "$COMMAND_LOG"
  : > "$LAUNCH_LOG"
  FM_FAKE_CMD_LOG="$COMMAND_LOG" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off
}

assert_only_treehouse_command() {
  local expected=$1 actual
  actual=$(sed -n '1p' "$COMMAND_LOG")
  [ "$actual" = "$expected" ] \
    || fail "wrong Treehouse acquisition command (expected '$expected', got '$actual')"
  [ "$(grep -Fxc -- "$expected" "$COMMAND_LOG")" -eq 1 ] \
    || fail "Treehouse acquisition command was not sent exactly once"
}

test_unconfigured_spawn_sends_byte_identical_bare_command() {
  local rec id out status
  id=treehouse-root-default-a1
  rec=$(make_case default)
  read_case "$rec"

  out=$(run_worker_spawn "$id")
  status=$?
  expect_code 0 "$status" "unconfigured worker spawn should succeed"
  assert_contains "$out" "spawned $id" "unconfigured worker spawn did not report success"
  assert_only_treehouse_command 'treehouse get'
  pass "an unconfigured spawn sends the existing bare treehouse get command"
}

test_configured_root_is_sent_to_treehouse() {
  local rec id out status root
  id=treehouse-root-config-a2
  rec=$(make_case config)
  read_case "$rec"
  root="$CASE_DIR/pool root"
  printf '%s\n' "$root" > "$HOME_DIR/config/treehouse-root"

  out=$(run_worker_spawn "$id")
  status=$?
  expect_code 0 "$status" "configured worker spawn should succeed"
  assert_contains "$out" "spawned $id" "configured worker spawn did not report success"
  assert_only_treehouse_command "treehouse get --root '$root'"
  pass "config/treehouse-root is safely carried onto treehouse get"
}

test_environment_root_wins_over_config() {
  local rec id out status file_root env_root
  id=treehouse-root-env-a3
  rec=$(make_case env)
  read_case "$rec"
  file_root="$CASE_DIR/file-pool"
  env_root="$CASE_DIR/env-pool"
  printf '%s\n' "$file_root" > "$HOME_DIR/config/treehouse-root"

  out=$(FM_TREEHOUSE_ROOT="$env_root" run_worker_spawn "$id")
  status=$?
  expect_code 0 "$status" "environment-configured worker spawn should succeed"
  assert_contains "$out" "spawned $id" "environment-configured worker spawn did not report success"
  assert_only_treehouse_command "treehouse get --root '$env_root'"
  assert_no_grep "$file_root" "$COMMAND_LOG" \
    "config/treehouse-root won even though FM_TREEHOUSE_ROOT was set"
  pass "FM_TREEHOUSE_ROOT wins over config/treehouse-root"
}

test_relative_root_is_refused() {
  local rec id out status
  id=treehouse-root-relative-a4
  rec=$(make_case relative)
  read_case "$rec"
  printf '%s\n' relative-pool > "$HOME_DIR/config/treehouse-root"

  out=$(run_worker_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a relative Treehouse root was accepted"
  assert_contains "$out" "must be an absolute path" \
    "relative-root refusal did not name the absolute-path requirement"
  [ ! -s "$COMMAND_LOG" ] || fail "relative-root refusal sent a pane command"
  pass "a relative Treehouse root is refused before acquisition"
}

test_present_file_without_root_is_refused() {
  local rec id out status
  id=treehouse-root-empty-a5
  rec=$(make_case empty)
  read_case "$rec"
  printf '  # comment\n\n   \n' > "$HOME_DIR/config/treehouse-root"

  out=$(run_worker_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a present file naming no Treehouse root was accepted"
  assert_contains "$out" "names no root" \
    "empty-file refusal did not explain that no root was named"
  [ ! -s "$COMMAND_LOG" ] || fail "empty-file refusal sent a pane command"
  pass "a present config file naming no root is refused"
}

test_project_storage_roots_are_refused() {
  local rec id out status root
  id=treehouse-root-projects-a6
  rec=$(make_case projects)
  read_case "$rec"
  root="$HOME_DIR/projects/private-pool"
  printf '%s\n' "$root" > "$HOME_DIR/config/treehouse-root"

  out=$(run_worker_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a Treehouse root inside project storage was accepted"
  assert_contains "$out" "inside project storage" \
    "project-storage refusal did not name the protected boundary"
  [ ! -s "$COMMAND_LOG" ] || fail "project-storage refusal sent a pane command"
  pass "a Treehouse root inside project storage is refused"
}

test_spawning_checkout_roots_are_refused() {
  local rec id out status root
  id=treehouse-root-checkout-a7
  rec=$(make_case checkout)
  read_case "$rec"
  root="$PROJECT_DIR/.treehouse"
  printf '%s\n' "$root" > "$HOME_DIR/config/treehouse-root"

  out=$(run_worker_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a Treehouse root inside the spawning checkout was accepted"
  assert_contains "$out" "inside the spawning checkout" \
    "checkout refusal did not name the protected boundary"
  [ ! -s "$COMMAND_LOG" ] || fail "checkout-root refusal sent a pane command"
  pass "a Treehouse root inside the spawning checkout is refused"
}

test_symlinked_ancestor_into_project_storage_is_refused() {
  local rec id out status target link root
  id=treehouse-root-symlink-a8
  rec=$(make_case symlink)
  read_case "$rec"
  target="$HOME_DIR/projects/existing-project"
  link="$CASE_DIR/pools-link"
  mkdir -p "$target"
  ln -s "$target" "$link"
  root="$link/nested-pool"
  printf '%s\n' "$root" > "$HOME_DIR/config/treehouse-root"

  out=$(run_worker_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a symlinked Treehouse root inside project storage was accepted"
  assert_contains "$out" "inside project storage" \
    "symlinked-ancestor refusal did not name the protected boundary"
  [ ! -s "$COMMAND_LOG" ] || fail "symlinked-root refusal sent a pane command"
  pass "a symlinked ancestor cannot route the Treehouse root into project storage"
}

test_case_insensitive_project_storage_spelling_is_refused() {
  local rec id out status root
  id=treehouse-root-casefold-c1
  rec=$(make_case casefold)
  read_case "$rec"
  if [ ! -d "$HOME_DIR/PROJECTS" ]; then
    echo "skip: fixture filesystem is case-sensitive"
    return 0
  fi
  root="$HOME_DIR/PROJECTS/casefold-pool"
  printf '%s\n' "$root" > "$HOME_DIR/config/treehouse-root"

  out=$(run_worker_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "case-insensitive spelling bypassed project-storage containment"
  assert_contains "$out" "inside project storage" \
    "case-insensitive containment refusal did not name project storage"
  [ ! -s "$COMMAND_LOG" ] || fail "case-insensitive containment refusal sent a pane command"
  pass "filesystem identity catches case-insensitive project-storage spelling"
}

test_dollar_character_is_refused_before_treehouse_expands_it() {
  local rec id out status root
  id=treehouse-root-dollar-c2
  rec=$(make_case dollar)
  read_case "$rec"
  root="$CASE_DIR/\$HOME/pool"
  printf '%s\n' "$root" > "$HOME_DIR/config/treehouse-root"

  out=$(run_worker_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a Treehouse root containing a dollar character was accepted"
  assert_contains "$out" "must not contain a '$' character" \
    "dollar-character refusal did not name Treehouse's later expansion"
  [ ! -s "$COMMAND_LOG" ] || fail "dollar-character refusal sent a pane command"
  pass "a dollar character is refused before Treehouse can expand the root"
}

test_config_line_trims_leading_and_trailing_whitespace() {
  local rec id out status root
  id=treehouse-root-trim-c3
  rec=$(make_case trim)
  read_case "$rec"
  root="$CASE_DIR/trimmed-pool"
  printf '   %s   \n' "$root" > "$HOME_DIR/config/treehouse-root"

  out=$(run_worker_spawn "$id")
  status=$?
  expect_code 0 "$status" "whitespace-padded configured worker spawn should succeed"
  assert_contains "$out" "spawned $id" \
    "whitespace-padded configured worker spawn did not report success"
  assert_only_treehouse_command "treehouse get --root '$root'"
  pass "config/treehouse-root trims leading and trailing whitespace"
}

test_missing_parent_dotdot_hidden_symlink_reproduction_is_refused() {
  local rec id out status existing link root
  id=treehouse-root-hidden-checkout-b1
  rec=$(make_case hidden-checkout)
  read_case "$rec"
  existing="$CASE_DIR/existing"
  link="$existing/symlink"
  mkdir -p "$existing"
  ln -s "$PROJECT_DIR" "$link"
  root="$existing/missing/../symlink/pool"
  printf '%s\n' "$root" > "$HOME_DIR/config/treehouse-root"

  out=$(run_worker_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "the missing-parent dot-dot symlink bypass was accepted"
  assert_contains "$out" "must not contain a '..' path component" \
    "the exact bypass did not reach the dot-dot refusal"
  [ ! -s "$COMMAND_LOG" ] || fail "the exact bypass sent a pane command"
  pass "the missing-parent dot-dot symlink bypass is refused before acquisition"
}

test_normalization_reveals_project_storage_symlink() {
  local rec id out status existing target link projects_override root
  id=treehouse-root-converge-b2
  rec=$(make_case converge)
  read_case "$rec"
  existing="$CASE_DIR/existing"
  target="$CASE_DIR/project-storage"
  link="$existing/symlink"
  mkdir -p "$existing" "$target"
  ln -s "$target" "$link"
  projects_override="$existing/missing/../symlink"
  root="$target/pool"
  printf '%s\n' "$root" > "$HOME_DIR/config/treehouse-root"

  out=$(FM_TEST_PROJECTS_OVERRIDE="$projects_override" run_worker_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a root inside project storage hidden until normalization was accepted"
  assert_contains "$out" "inside project storage" \
    "convergent resolution did not expose the project-storage boundary"
  [ ! -s "$COMMAND_LOG" ] || fail "normalization-hidden boundary sent a pane command"
  pass "convergent resolution exposes a symlinked project-storage boundary after normalization"
}

test_dotdot_component_is_refused_even_when_destination_is_safe() {
  local rec id out status root
  id=treehouse-root-dotdot-b3
  rec=$(make_case dotdot)
  read_case "$rec"
  mkdir -p "$CASE_DIR/ordinary"
  root="$CASE_DIR/ordinary/../safe-pool"
  printf '%s\n' "$root" > "$HOME_DIR/config/treehouse-root"

  out=$(run_worker_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a Treehouse root containing a dot-dot component was accepted"
  assert_contains "$out" "must not contain a '..' path component" \
    "dot-dot refusal did not name the forbidden component"
  [ ! -s "$COMMAND_LOG" ] || fail "dot-dot refusal sent a pane command"
  pass "every configured Treehouse root containing a dot-dot component is refused"
}

test_secondmate_launch_clears_environment_root() {
  local rec id subhome out status launch
  id=treehouse-root-secondmate-a9
  rec=$(make_case secondmate)
  read_case "$rec"
  subhome="$CASE_DIR/secondmate-home"
  mkdir -p "$subhome/bin" "$subhome/data"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf '# Firstmate\n' > "$subhome/AGENTS.md"
  printf 'Secondmate charter.\n' > "$subhome/data/charter.md"
  : > "$LAUNCH_LOG"

  out=$(FM_TREEHOUSE_ROOT="$CASE_DIR/primary-pool" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" "$subhome" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed"
  assert_contains "$out" "spawned $id" "secondmate spawn did not report success"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_CONFIG_OVERRIDE= FM_TREEHOUSE_ROOT= FM_PUBLIC_FOLLOWUP_PRIMARY_HOME=" \
    "secondmate launch did not clear FM_TREEHOUSE_ROOT"
  assert_not_contains "$launch" "FM_TREEHOUSE_ROOT='$CASE_DIR/primary-pool'" \
    "secondmate launch copied the primary Treehouse root value"
  pass "a secondmate launch clears the primary's FM_TREEHOUSE_ROOT"
}

test_unconfigured_spawn_sends_byte_identical_bare_command
test_configured_root_is_sent_to_treehouse
test_environment_root_wins_over_config
test_relative_root_is_refused
test_present_file_without_root_is_refused
test_project_storage_roots_are_refused
test_spawning_checkout_roots_are_refused
test_symlinked_ancestor_into_project_storage_is_refused
test_config_line_trims_leading_and_trailing_whitespace
test_dollar_character_is_refused_before_treehouse_expands_it
test_case_insensitive_project_storage_spelling_is_refused
test_missing_parent_dotdot_hidden_symlink_reproduction_is_refused
test_normalization_reveals_project_storage_symlink
test_dotdot_component_is_refused_even_when_destination_is_safe
test_secondmate_launch_clears_environment_root

echo "# all fm-spawn-treehouse-root tests passed"
