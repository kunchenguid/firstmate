#!/usr/bin/env bash
# tests/fm-lane-disk-spawn.test.sh - the opt-in per-lane build-output root
# (bin/fm-lane-disk-lib.sh) reaches the worker's launch environment and the
# task record, and stays entirely absent by default.
#
# Like tests/fm-spawn-compact-adviser-disable.test.sh, the assertions never read
# bin/fm-spawn.sh's source: they drive the real spawn against a fake pane and a
# real isolated git worktree, then EXECUTE the launch command the pane received
# under a cleared environment, with the harness replaced by a probe that prints
# the variable under test.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-lane-disk-spawn)
unset FM_BUILD_OUTPUT_ROOT FM_BUILD_OUTPUT_DIR CARGO_TARGET_DIR PYTHONPYCACHEPREFIX

# make_case <name> <id>: echoes "<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 id=$2 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$case_dir/home" codex
  fm_git_worktree "$case_dir/project" "$case_dir/wt" "wt-$name"
  fm_test_spawn_brief "$case_dir/home" "$id"
  printf '%s\n' "$case_dir/home|$case_dir/project|$case_dir/wt|$fakebin|$case_dir/launch.log|$case_dir/pane.log"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

spawn_ship() {  # <id>
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$1" "$PROJ_DIR" --mode no-mistakes --yolo off
}

# launched_value <variable>: what the agent would see for <variable>.
launched_value() {
  local preamble
  cat > "$FAKEBIN_DIR/codex" <<SH
#!/bin/sh
printf '%s\n' "\${$1-unset}"
SH
  chmod +x "$FAKEBIN_DIR/codex"
  preamble=$(grep '^export ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$preamble
$(cat "$LAUNCH_LOG")"
}

test_build_output_root_is_off_by_default() {
  local out status
  read_case "$(make_case off lane-off-a1)"
  out=$(spawn_ship lane-off-a1)
  status=$?
  expect_code 0 "$status" "default spawn should succeed: $out"
  assert_equals unset "$(launched_value CARGO_TARGET_DIR)" "a default spawn exported CARGO_TARGET_DIR"
  assert_equals unset "$(launched_value FM_BUILD_OUTPUT_DIR)" "a default spawn exported FM_BUILD_OUTPUT_DIR"
  assert_no_grep build_output_dir= "$HOME_DIR/state/lane-off-a1.meta" "a default spawn recorded build_output_dir="
  pass "a spawn without the build-output setting exports and records nothing new"
}

test_build_output_root_file_exports_and_records() {
  local out status root dir
  read_case "$(make_case file lane-file-a1)"
  root="$TMP_ROOT/file-root"
  dir="$root/lane-file-a1"
  printf '%s/\n' "$root" > "$HOME_DIR/config/build-output-root"
  # The cleared allowlist environment is where an ambient forward would be lost.
  : > "$HOME_DIR/config/launch-env-allowlist"
  out=$(spawn_ship lane-file-a1)
  status=$?
  expect_code 0 "$status" "spawn with config/build-output-root should succeed: $out"
  [ -d "$dir" ] || fail "spawn did not create the per-lane build-output directory $dir"
  assert_grep "build_output_dir=$dir" "$HOME_DIR/state/lane-file-a1.meta" "spawn did not record build_output_dir="
  assert_equals "$dir" "$(launched_value FM_BUILD_OUTPUT_DIR)" "FM_BUILD_OUTPUT_DIR is not the per-lane directory"
  assert_equals "$dir/cargo-target" "$(launched_value CARGO_TARGET_DIR)" "CARGO_TARGET_DIR is not under the per-lane directory"
  assert_equals "$dir/pycache" "$(launched_value PYTHONPYCACHEPREFIX)" "PYTHONPYCACHEPREFIX is not under the per-lane directory"
  pass "config/build-output-root creates, records, and exports the per-lane build-output directory"
}

test_build_output_root_env_override() {
  local out status root
  read_case "$(make_case env-off lane-envoff-a1)"
  printf '%s\n' "$TMP_ROOT/env-off-root" > "$HOME_DIR/config/build-output-root"
  out=$(FM_BUILD_OUTPUT_ROOT=off spawn_ship lane-envoff-a1)
  status=$?
  expect_code 0 "$status" "spawn with FM_BUILD_OUTPUT_ROOT=off should succeed: $out"
  assert_equals unset "$(launched_value CARGO_TARGET_DIR)" "FM_BUILD_OUTPUT_ROOT=off still exported CARGO_TARGET_DIR"
  assert_absent "$TMP_ROOT/env-off-root" "FM_BUILD_OUTPUT_ROOT=off still created the file's root"

  read_case "$(make_case env-on lane-envon-a1)"
  root="$TMP_ROOT/env-on-root"
  out=$(FM_BUILD_OUTPUT_ROOT="$root" spawn_ship lane-envon-a1)
  status=$?
  expect_code 0 "$status" "spawn with FM_BUILD_OUTPUT_ROOT set should succeed: $out"
  assert_equals "$root/lane-envon-a1/cargo-target" "$(launched_value CARGO_TARGET_DIR)" \
    "FM_BUILD_OUTPUT_ROOT did not enable the per-lane directory"

  read_case "$(make_case env-relative lane-envrel-a1)"
  out=$(FM_BUILD_OUTPUT_ROOT=relative/root spawn_ship lane-envrel-a1)
  status=$?
  expect_code 0 "$status" "spawn with a relative FM_BUILD_OUTPUT_ROOT should still succeed: $out"
  assert_contains "$out" "is not an absolute path" "a relative root was not reported"
  assert_equals unset "$(launched_value CARGO_TARGET_DIR)" "a relative root still exported CARGO_TARGET_DIR"

  read_case "$(make_case env-dotdot lane-envdot-a1)"
  out=$(FM_BUILD_OUTPUT_ROOT="$TMP_ROOT/x/../dot-root" spawn_ship lane-envdot-a1)
  status=$?
  expect_code 0 "$status" "spawn with a .. component in FM_BUILD_OUTPUT_ROOT should still succeed: $out"
  assert_contains "$out" "has a . or .. component" "a root with a .. component was not reported"
  assert_equals unset "$(launched_value CARGO_TARGET_DIR)" "a root with a .. component still exported CARGO_TARGET_DIR"
  assert_absent "$TMP_ROOT/dot-root" "a root with a .. component still created a directory teardown would refuse to remove"
  pass "FM_BUILD_OUTPUT_ROOT overrides config/build-output-root, and a relative or dotted value stays off"
}

test_build_output_root_is_off_by_default
test_build_output_root_file_exports_and_records
test_build_output_root_env_override
