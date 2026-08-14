#!/usr/bin/env bash
# Behavior tests for omp-harness spawn wiring, turn-end extension lifecycle,
# launch flags, and session-lock holder detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)

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
  send-keys) printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"; exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh omp
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="omp-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_omp_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 log=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_TMUX_LOG="$log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" --mode local-only --yolo off 2>&1
}

test_omp_spawn_writes_turnend_extension_and_launches() {
  local rec case_dir home proj wt fakebin id out status log
  rec=$(make_spawn_case basic)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  log="$case_dir/tmux.log"
  out=$(run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$log" omp)
  status=$?
  expect_code 0 "$status" "omp spawn should succeed"
  assert_contains "$out" "spawned $id harness=omp" "omp spawn did not report success"

  assert_present "$home/state/$id.omp-ext.ts" "omp turn-end extension was not written"
  assert_grep 'turn_end' "$home/state/$id.omp-ext.ts" "omp turn-end extension does not listen for turn_end"
  assert_grep "$id.turn-ended" "$home/state/$id.omp-ext.ts" "omp turn-end extension does not touch the task turn-end file"
  assert_grep '--auto-approve' "$log" "omp launch line missing --auto-approve"
  assert_grep "$id.omp-ext.ts" "$log" "omp launch line does not load the turn-end extension"
  assert_grep 'omp' "$home/state/$id.meta" "meta missing harness"
  pass "omp spawn writes the turn-end extension and launches with --auto-approve"
}

test_omp_turnend_extension_encodes_special_state_path() {
  local case_dir home proj wt fakebin id log out status extension literal decoded expected
  case_dir="$TMP_ROOT/turnend-literal"
  home="$case_dir/home\"slash\\path"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="omp-turnend-literal-x1"
  log="$case_dir/tmux.log"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"

  out=$(run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$log" omp)
  status=$?
  expect_code 0 "$status" "omp spawn with a special state path should succeed"
  extension="$home/state/$id.omp-ext.ts"
  assert_present "$extension" "omp turn-end extension was not written for a special state path"
  literal=$(sed -n 's/.*execFile("touch", \[\(.*\)\]));/\1/p' "$extension")
  [ -n "$literal" ] || fail "omp turn-end extension did not contain a path literal"
  decoded=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]))' "$literal") \
    || fail "omp turn-end extension path is not a valid JavaScript string literal"
  expected="$(cd "$home/state" && pwd -P)/$id.turn-ended"
  [ "$decoded" = "$expected" ] \
    || fail "omp turn-end extension path changed during encoding"
  pass "omp spawn safely encodes special characters in the turn-end path"
}

test_omp_teardown_removes_extension() {
  local rec case_dir home proj wt fakebin id out status log
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  log="$case_dir/tmux.log"
  out=$(run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$log" omp)
  status=$?
  expect_code 0 "$status" "omp spawn should succeed before teardown"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "omp teardown failed"

  assert_absent "$home/state/$id.omp-ext.ts" "omp turn-end extension survived teardown"
  pass "omp teardown removes the turn-end extension"
}

test_fm_lock_recognizes_omp_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'bun'; exit 0 ;;
  *"args="*) printf '%s\n' 'bun /opt/omp/bin/omp --auto-approve'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize a bun omp process as a live holder"
  pass "fm-lock recognizes omp harness processes"
}

test_fm_lock_omp_args_do_not_self_match_config_paths() {
  local home fakebin out
  home="$TMP_ROOT/lock-home-config"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake-config")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'bun'; exit 0 ;;
  *"args="*) printf '%s\n' 'bun /home/agent/some-script.js /home/agent/.omp/agent/config.yml'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: stale" "fm-lock mistook a .omp/ config path in args for the omp harness"
  pass "fm-lock does not self-match .omp/ config paths"
}

test_fm_harness_omp_ancestry_uses_bun_script_argument() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/harness-fake")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'bun'; exit 0 ;;
  *"args="*) printf '%s\n' "${FM_FAKE_OMP_ARGS:?}"; exit 0 ;;
  *"ppid="*) printf '%s\n' '1'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_FAKE_OMP_ARGS='bun /opt/omp/bin/omp --auto-approve' env -u OMPCODE -u CLAUDECODE -u PI_CODING_AGENT PATH="$fakebin:$PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" = omp ] || fail "fm-harness did not recognize omp as bun's script argument: $out"
  out=$(FM_FAKE_OMP_ARGS='bun /home/agent/some-script.js /home/agent/.omp/agent/config.yml' env -u OMPCODE -u CLAUDECODE -u PI_CODING_AGENT PATH="$fakebin:$PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" = unknown ] || fail "fm-harness mistook a later .omp config argument for the harness: $out"
  pass "fm-harness identifies OMP only from bun's script argument"
}

test_omp_launch_template_model_and_effort() {
  local rec case_dir home proj wt fakebin id out status log meta
  rec=$(make_spawn_case launch-flags)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  log="$case_dir/tmux.log"
  out=$(run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$log" --harness omp --model 'kimi-code/k3' --effort xhigh)
  status=$?
  expect_code 0 "$status" "omp spawn with model/effort should succeed"
  assert_contains "$out" "spawned $id harness=omp" "omp spawn with flags did not report success"
  meta="$home/state/$id.meta"
  assert_grep 'model=kimi-code/k3' "$meta" "meta missing model"
  assert_grep 'effort=xhigh' "$meta" "meta missing effort"
  assert_grep "--model 'kimi-code/k3'" "$log" "omp launch line missing --model"
  assert_grep "--thinking 'xhigh'" "$log" "omp launch line missing --thinking effort flag"
  pass "omp records model/effort and launches with --model and --thinking"
}

test_omp_secondmate_template_loads_primary_extensions() {
  local text
  text=$(cat "$ROOT/bin/fm-spawn.sh")
  assert_contains "$text" "omp --auto-approve __MODELFLAG____EFFORTFLAG__-e __OMPTURNEND__ -e __OMPWATCH__" "omp secondmate launch template does not include both primary extensions"
  assert_contains "$text" 'omp --auto-approve __MODELFLAG____EFFORTFLAG__-e __OMPEXT__' "omp crewmate launch template does not load the turn-end extension"
  assert_contains "$text" "\$PROJ_ABS/.omp/extensions/fm-primary-omp-watch.ts" "fm-spawn does not point the omp secondmate watch placeholder at the tracked extension"
  assert_contains "$text" "\$PROJ_ABS/.omp/extensions/fm-primary-turnend-guard.ts" "fm-spawn does not point the omp secondmate guard placeholder at the tracked extension"
  assert_contains "$text" "__OMPTURNEND__" "fm-spawn does not replace the omp turn-end guard extension placeholder"
  assert_contains "$text" "__OMPWATCH__" "fm-spawn does not replace the omp watch extension placeholder"
  pass "omp launch templates include the tracked extensions"
}

test_omp_spawn_writes_turnend_extension_and_launches
test_omp_turnend_extension_encodes_special_state_path
test_omp_teardown_removes_extension
test_fm_lock_recognizes_omp_holder
test_fm_lock_omp_args_do_not_self_match_config_paths
test_fm_harness_omp_ancestry_uses_bun_script_argument
test_omp_launch_template_model_and_effort
test_omp_secondmate_template_loads_primary_extensions
