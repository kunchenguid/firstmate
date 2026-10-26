#!/usr/bin/env bash
# tests/fm-spawn-task-tmpdir.test.sh - ship and scout workers keep their general
# scratch (TMPDIR, TMP, TEMP) under the per-task temp root /tmp/fm-<id>/ so
# task cleanup removes it, while a secondmate keeps the ambient temp directory.
#
# TMPDIR is a broad knob, so the cases below pin what keeps it safe: the value
# is short (Unix-socket path limit), it sits inside the private 0700 root the
# spawn already validates (ownership), a secondmate is never given it, and the
# shared /tmp stays reachable by absolute path. Like the compact-adviser suite,
# the assertions never read bin/fm-spawn.sh's source: they drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane received so the probe reports what a real agent would see.
# Teardown removal of the root is covered in tests/fm-gotmp.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-task-tmpdir)

# bin/fm-spawn.sh creates /tmp/fm-<id> (and a /tmp/fm-<id>+<home hash> launch
# directory) outside the suite's temp root, so every id ends in a per-run suffix
# and the exit cleanup removes only the paths that suffix names. make_case runs
# in a command substitution, so cleanup cannot rely on a list it appends to.
RUN_SUFFIX="t$$"

cleanup_task_roots() {
  local root
  for root in /tmp/fm-tmpdir-*-"$RUN_SUFFIX" /tmp/fm-tmpdir-*-"$RUN_SUFFIX"+*; do
    [ ! -e "$root" ] || rm -rf "$root"
  done
}
trap 'cleanup_task_roots; fm_test_cleanup' EXIT

path_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# make_case <name> <harness> <id>
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  rm -rf "/tmp/fm-$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log|$case_dir/pane.log"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# Replace the harness binary with a probe that prints the three temp variables,
# or "unset" for a variable that is absent, one per line.
install_temp_probe() {  # <fakebin> <harness>
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf '%s\n' "${TMPDIR-unset}" "${TMP-unset}" "${TEMP-unset}"
SH
  chmod +x "$1/$2"
}

# Run the emitted launch in a synthetic pane shell whose ambient temp variables
# point at a shared directory, so a launch that merely forwarded the ambient
# environment is caught instead of reported as a pass.
#   emitted_temp_env <fakebin> <launch-log> <pane-log> [ambient-temp]
emitted_temp_env() {
  local fakebin=$1 launchlog=$2 panelog=$3 ambient=${4:-/ambient-shared-tmp} launch preamble
  launch=$(cat "$launchlog")
  # The pane exports run before the launch command in the real pane shell, so
  # replay them in the same order.
  preamble=$(grep '^export ' "$panelog")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane TMPDIR="$ambient" TMP="$ambient" TEMP="$ambient" \
    /bin/sh -c "$preamble
$launch"
}

assert_task_scratch() {  # <id> <label> <probe-output>
  local id=$1 label=$2 seen=$3 want="/tmp/fm-$1/tmp"
  assert_equals "$want"$'\n'"$want"$'\n'"$want" "$seen" \
    "$label: the agent must start with TMPDIR, TMP, and TEMP set to the per-task scratch directory"
  [ -d "$want" ] || fail "$label: spawn did not create $want"
  [ "$(path_mode "/tmp/fm-$id")" = 700 ] \
    || fail "$label: the per-task root must stay private, got mode $(path_mode "/tmp/fm-$id")"
  [ "$(path_mode "$want")" = 700 ] \
    || fail "$label: the scratch directory must not be readable by others, got mode $(path_mode "$want")"
  [ -O "$want" ] || fail "$label: the scratch directory must be owned by the spawning user"
  # Unix-socket paths are limited to about 104 bytes. The scratch directory adds
  # only four bytes ("/tmp") to the root, so the socket budget a tool had under
  # the root is nearly unchanged.
  [ "${#want}" -le $(( ${#id} + 12 )) ] \
    || fail "$label: the scratch path must stay short, got ${#want} bytes for a ${#id}-byte id"
}

test_ship_gets_task_scratch() {
  local setting rec id out status seen
  for setting in absent enabled; do
    id="tmpdir-ship-$setting-$RUN_SUFFIX"
    rec=$(make_case "ship-$setting" codex "$id")
    read_case "$rec"
    # An empty allowlist is the strictest opt-in: the cleared launch environment
    # keeps only Firstmate's own floor, which must carry the three names.
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "ship spawn with allowlist=$setting should succeed: $out"
    install_temp_probe "$FAKEBIN_DIR" codex
    seen=$(emitted_temp_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
      || fail "ship, allowlist $setting: the emitted launch failed to run"
    assert_task_scratch "$id" "ship, allowlist $setting" "$seen"
  done
  pass "a ship worker starts with TMPDIR, TMP, and TEMP inside its private per-task root"
}

test_scout_gets_task_scratch() {
  local rec id out status seen
  id="tmpdir-scout-$RUN_SUFFIX"
  rec=$(make_case scout codex "$id")
  read_case "$rec"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "scout spawn should succeed: $out"
  install_temp_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_temp_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "scout: the emitted launch failed to run"
  assert_task_scratch "$id" scout "$seen"
  pass "a scout worker starts with TMPDIR, TMP, and TEMP inside its private per-task root"
}

# The shared /tmp must stay reachable: only the three variables move, so a tool
# that needs the shared directory still reaches it by absolute path, and the Go
# build temp keeps its own sibling directory.
test_shared_tmp_and_gotmp_stay_reachable() {
  local rec id out status
  id="tmpdir-shared-$RUN_SUFFIX"
  rec=$(make_case shared codex "$id")
  read_case "$rec"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn should succeed: $out"
  [ -d "/tmp/fm-$id/gotmp" ] || fail "the Go build temp directory must still be created beside the scratch directory"
  assert_grep "export GOTMPDIR=/tmp/fm-$id/gotmp" "$PANE_LOG" "GOTMPDIR must keep its own directory"
  assert_grep "export TMPDIR=/tmp/fm-$id/tmp TMP=/tmp/fm-$id/tmp TEMP=/tmp/fm-$id/tmp" "$PANE_LOG" \
    "the pane must receive one scratch export for the three temp variables"
  [ "$(grep -c '^export TMUX_TMPDIR=' "$PANE_LOG")" = 0 ] \
    || fail "spawn must not move TMUX_TMPDIR: the tmux server socket stays in the shared directory"
  pass "TMPDIR is the only temp knob that moves; GOTMPDIR and the shared /tmp keep their roles"
}

# A secondmate runs a whole home that outlives any one task, so its temp is not
# tied to a task's cleanup and must stay ambient.
test_secondmate_keeps_ambient_temp() {
  local setting rec id sm out status seen
  for setting in absent enabled; do
    id="tmpdir-sm-$setting-$RUN_SUFFIX"
    rec=$(make_case "secondmate-$setting" codex "$id")
    read_case "$rec"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    sm="$CASE_DIR/secondmate-home"
    mkdir -p "$sm/bin" "$sm/data"
    printf '# Firstmate\n' > "$sm/AGENTS.md"
    printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
    printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
    printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
    git -C "$sm" init -q -b main
    out=$(run_case_spawn "$id" "$sm" --secondmate)
    status=$?
    expect_code 0 "$status" "secondmate spawn with allowlist=$setting should succeed: $out"
    [ "$(grep -c '^export TMPDIR=' "$PANE_LOG")" = 0 ] \
      || fail "secondmate, allowlist $setting: its pane must not receive a TMPDIR export"
    [ ! -e "/tmp/fm-$id/tmp" ] \
      || fail "secondmate, allowlist $setting: spawn must not create a scratch directory for a home"
    install_temp_probe "$FAKEBIN_DIR" codex
    seen=$(emitted_temp_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG" /ambient-shared-tmp) \
      || fail "secondmate, allowlist $setting: the emitted launch failed to run"
    assert_equals $'/ambient-shared-tmp\n/ambient-shared-tmp\n/ambient-shared-tmp' "$seen" \
      "secondmate, allowlist $setting: the ambient temp variables must pass through untouched"
  done
  pass "a secondmate home keeps its ambient temp directory in both allowlist postures"
}

# A reused task root is validated before the scratch directory is created inside
# it, so the ownership checks cover it: a root that other users can write to is
# refused rather than used for scratch.
test_shared_root_refused_before_scratch() {
  local rec id out status
  id="tmpdir-shared-root-$RUN_SUFFIX"
  rec=$(make_case sharedroot codex "$id")
  read_case "$rec"
  mkdir "/tmp/fm-$id"
  chmod 777 "/tmp/fm-$id"
  out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must refuse a task root other users can write to: $out"
  assert_contains "$out" "is not a private directory owned by this user" \
    "the refusal must name the private-root ownership check"
  [ ! -e "/tmp/fm-$id/tmp" ] || fail "no scratch directory may be created inside a refused root"
  pass "a world-writable pre-existing task root is refused before any scratch directory is created"
}

test_ship_gets_task_scratch
test_scout_gets_task_scratch
test_shared_tmp_and_gotmp_stay_reachable
test_secondmate_keeps_ambient_temp
test_shared_root_refused_before_scratch
