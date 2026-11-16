#!/usr/bin/env bash
# tests/fm-footprint-spawn.test.sh - a ship or scout spawn creates the task's
# scratch area, records it, and hands the worker FM_TASK_SCRATCH, the Docker
# label set, and (for a verified tool) the redirected temp directory; a
# malformed config/footprint refuses before launch; a secondmate gets none.
#
# The assertions drive the real bin/fm-spawn.sh against a fake pane and a real
# isolated git worktree, then EXECUTE the launch command the pane received with
# the harness replaced by a probe that prints its environment, so what the
# probe prints is what a real agent would have started with.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-footprint-spawn)
SHORT=$(mktemp -d /tmp/fmfs.XXXXXX) || fail "cannot create a short scratch root"
SHORT=$(cd -P "$SHORT" && pwd -P) || fail "cannot resolve the short scratch root"
FM_TEST_CLEANUP_DIRS+=("$SHORT")
export FM_SCRATCH_ROOT_OVERRIDE="$SHORT"

make_case() {  # <name> <harness> <id>
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_LOG="$CASE_DIR/pane.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$1"
  fm_test_spawn_brief "$HOME_DIR" "$3"
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
}

run_spawn() {
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

install_env_probe() {  # <harness>
  cat > "$FAKEBIN_DIR/$1" <<'SH'
#!/bin/sh
printf 'scratch=%s\ntmpdir=%s\nlabel=%s\ncompose=%s\n' "${FM_TASK_SCRATCH-unset}" "${TMPDIR-unset}" "${FM_DOCKER_LABEL-unset}" "${COMPOSE_PROJECT_NAME-unset}"
SH
  chmod +x "$FAKEBIN_DIR/$1"
}

emitted_launch_env() {
  local preamble
  preamble=$(grep '^export ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm TMUX=synthetic-pane \
    TMPDIR=/ambient/tmp /bin/sh -c "$preamble
$(cat "$LAUNCH_LOG")"
}

home_key() {
  bash -c '. "$1/bin/fm-footprint-lib.sh"; fm_footprint_home_key "$2"' _ "$ROOT" "$HOME_DIR"
}

test_ship_spawn_exports_scratch_for_a_verified_tool() {
  local out status key scratch seen allow
  for allow in absent enabled; do
    make_case "ship-$allow" codex "fp-ship-$allow"
    [ "$allow" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_spawn "fp-ship-$allow" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "ship spawn ($allow allowlist) should succeed: $out"
    key=$(home_key)
    scratch="$SHORT/$key/fp-ship-$allow"
    assert_grep "scratch=$scratch" "$HOME_DIR/state/fp-ship-$allow.meta" "the task record must name its scratch area"
    [ -d "$scratch/tmp" ] || fail "the scratch area and its temp directory must exist"
    assert_grep "export FM_TASK_SCRATCH=" "$PANE_LOG" "the pane must receive the scratch export before launch"
    install_env_probe codex
    seen=$(emitted_launch_env) || fail "the emitted launch failed to run"
    assert_equals "scratch=$scratch
tmpdir=$scratch/tmp
label=firstmate.task=$key/fp-ship-$allow
compose=fm-$key-fp-ship-$allow" "$seen" "a codex ship ($allow allowlist) must start with its scratch area, temp, and labels"
  done
  pass "a ship spawn records its scratch area and the worker starts with it, its temp, and its labels"
}

test_scout_spawn_respects_switches() {
  local out status seen key
  make_case scout-off claude fp-scout
  printf 'task-tmpdir off\ndocker-labels off\n' > "$HOME_DIR/config/footprint"
  out=$(run_spawn fp-scout "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "scout spawn should succeed: $out"
  key=$(home_key)
  install_env_probe claude
  seen=$(emitted_launch_env) || fail "the emitted launch failed to run"
  assert_equals "scratch=$SHORT/$key/fp-scout
tmpdir=/ambient/tmp
label=unset
compose=unset" "$seen" "switched-off temp and labels must leave the worker's inherited values"
  assert_contains "$out" "note: task-tmpdir off" "the spawn must say temp stays where it is"
  pass "a scout spawn gets its scratch area and honours task-tmpdir and docker-labels off"
}

test_malformed_footprint_config_refuses_before_launch() {
  local out status
  make_case bad-config codex fp-bad
  printf 'cache-cap-gb lots\n' > "$HOME_DIR/config/footprint"
  out=$(run_spawn fp-bad "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a malformed config/footprint must refuse the spawn"
  assert_contains "$out" "cache-cap-gb' must be a number of GB" "the refusal must name the bad line"
  assert_equals "" "$(cat "$LAUNCH_LOG")" "nothing may be launched after the refusal"
  pass "a malformed config/footprint refuses the spawn before any launch"
}

test_secondmate_gets_no_scratch() {
  local out status sm
  make_case secondmate codex sm-fp
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' sm-fp > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  out=$(run_spawn sm-fp "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should succeed: $out"
  assert_no_regex '^scratch=' "$HOME_DIR/state/sm-fp.meta" "a secondmate must not get a task scratch area"
  assert_no_grep 'FM_TASK_SCRATCH' "$PANE_LOG" "a secondmate pane must not receive scratch exports"
  pass "a secondmate spawn gets no task scratch area"
}

fm_test_run \
  test_ship_spawn_exports_scratch_for_a_verified_tool \
  test_scout_spawn_respects_switches \
  test_malformed_footprint_config_refuses_before_launch \
  test_secondmate_gets_no_scratch
