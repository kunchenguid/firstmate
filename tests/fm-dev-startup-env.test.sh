#!/usr/bin/env bash
# Behavior tests for local config/dev_startup.env parsing, generated launch
# exports, common spawn wrapping, redaction, and secondmate inheritance.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dev-startup-env-lib.sh
. "$ROOT/bin/fm-dev-startup-env-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-dev-startup-env)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.invalid

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

reset_startup_env_ambient() {
  unset DEV_STARTUP_ALPHA DEV_STARTUP_BETA DEV_STARTUP_EMPTY DEV_STARTUP_LITERAL DEV_STARTUP_SENTINEL LANGFUSE_URL 2>/dev/null || true
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_CALL_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
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
  cat > "$fakebin/fake-harness" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'harness:%s:%s\n' "${DEV_STARTUP_SENTINEL-absent}" "${LANGFUSE_URL-absent}"
  sh -c 'printf "child:%s:%s\n" "${DEV_STARTUP_SENTINEL-absent}" "${LANGFUSE_URL-absent}"'
} > "${FM_FAKE_RESULT:?}"
SH
  chmod +x "$fakebin/tmux" "$fakebin/fake-harness"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'task instructions\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

read_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF_CASE
$1
EOF_CASE
  LAUNCH_LOG="$CASE_DIR/launch.log"
  TMUX_LOG="$CASE_DIR/tmux.log"
}

run_spawn() {
  local id=$1
  shift
  : > "$LAUNCH_LOG"
  : > "$TMUX_LOG"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX='fake,1,0' \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_TMUX_CALL_LOG="$TMUX_LOG" \
    GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "$@" 2>&1
}

run_secondmate_spawn() {
  local id=$1 secondmate_home=$2
  : > "$LAUNCH_LOG"
  : > "$TMUX_LOG"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$secondmate_home" TMUX='fake,1,0' \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_TMUX_CALL_LOG="$TMUX_LOG" \
    GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" "$secondmate_home" 'fake-harness --run' --secondmate 2>&1
}

test_absent_is_noop() {
  local d launch wrapped
  d="$TMP_ROOT/absent"
  mkdir -p "$d/task"
  fm_dev_startup_env_validate "$d/missing.env" || fail "absent startup env should validate"
  [ "$FM_DEV_STARTUP_ENV_ACTIVE" = 0 ] || fail "absent startup env should stay inactive"
  fm_dev_startup_env_prepare "$d/task" || fail "absent startup env prepare should be a no-op"
  [ -z "$FM_DEV_STARTUP_ENV_ARTIFACT" ] || fail "absent startup env created an artifact"
  launch='fake-harness --run'
  wrapped=$(fm_dev_startup_env_wrap_launch "$launch")
  [ "$wrapped" = "$launch" ] || fail "absent startup env changed the launch command"
  pass "absent dev_startup.env is a byte-compatible launch no-op"
}

test_parser_artifact_and_literal_values() {
  local d cfg task artifact content out
  d="$TMP_ROOT/parser"
  cfg="$d/dev_startup.env"
  task="$d/task"
  mkdir -p "$task"
  cat > "$cfg" <<'ENV'
# comment
DEV_STARTUP_ALPHA=first
export DEV_STARTUP_BETA='two words'
DEV_STARTUP_EMPTY=
DEV_STARTUP_LITERAL="$(touch /tmp/fm-dev-startup-env-must-not-run)"
DEV_STARTUP_ALPHA=last
ENV
  rm -f /tmp/fm-dev-startup-env-must-not-run
  reset_startup_env_ambient
  fm_dev_startup_env_validate "$cfg" || fail "valid startup env was rejected"
  fm_dev_startup_env_prepare "$task" || fail "valid startup env artifact preparation failed"
  artifact=$FM_DEV_STARTUP_ENV_ARTIFACT
  [ -f "$artifact" ] || fail "generated startup env artifact is missing"
  [ "$(file_mode "$artifact")" = 600 ] || fail "generated startup env artifact mode is not 0600"
  content=$(cat "$artifact")
  assert_contains "$content" 'export DEV_STARTUP_ALPHA=' "artifact does not contain generated exports"
  assert_not_contains "$content" 'first' "duplicate first assignment survived last-wins parsing"
  DEV_STARTUP_ALPHA=ambient
  export DEV_STARTUP_ALPHA
  # shellcheck disable=SC1090
  . "$artifact"
  out="$DEV_STARTUP_ALPHA|$DEV_STARTUP_BETA|$DEV_STARTUP_EMPTY|$DEV_STARTUP_LITERAL"
  # shellcheck disable=SC2016  # The command substitution text must stay literal.
  [ "$out" = 'ambient|two words||$(touch /tmp/fm-dev-startup-env-must-not-run)' ] \
    || fail "parsed/exported values or ambient precedence are wrong: $out"
  [ ! -e /tmp/fm-dev-startup-env-must-not-run ] || fail "literal command substitution executed"
  reset_startup_env_ambient
  pass "dotenv records parse literally with quotes, empty values, last-wins, ambient precedence, and mode 0600"
}

test_invalid_and_protected_refuse_before_allocation() {
  local rec id out status tasktmp key err
  id=dev-env-invalid-z1
  rec=$(make_spawn_case invalid "$id")
  read_spawn_case "$rec"
  printf 'NOT VALID\n' > "$HOME_DIR/config/dev_startup.env"
  tasktmp="/tmp/fm-$id"
  rm -rf "$tasktmp"
  out=$(run_spawn "$id")
  status=$?
  expect_code 1 "$status" "invalid startup env syntax should refuse spawn"
  assert_contains "$out" 'invalid dev_startup.env syntax at line 1' "syntax refusal diagnostic is missing"
  [ ! -s "$TMUX_LOG" ] || fail "invalid syntax reached backend allocation"
  assert_absent "$HOME_DIR/state/$id.meta" "invalid syntax wrote task metadata"
  assert_absent "$tasktmp" "invalid syntax created task-private temp"

  printf 'PATH=sentinel-must-not-leak\n' > "$HOME_DIR/config/dev_startup.env"
  out=$(run_spawn "$id")
  status=$?
  expect_code 1 "$status" "protected startup env key should refuse spawn"
  assert_contains "$out" 'protected dev_startup.env key: PATH' "protected-key diagnostic did not name the key"
  assert_not_contains "$out" 'sentinel-must-not-leak' "protected-key diagnostic leaked the value"
  [ ! -s "$TMUX_LOG" ] || fail "protected key reached backend allocation"
  assert_absent "$HOME_DIR/state/$id.meta" "protected key wrote task metadata"

  for key in \
    FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE \
    HOME PATH SHELL PWD OLDPWD GOTMPDIR TMUX TMUX_PANE \
    HERDR_TEST_IDENTITY ZELLIJ_TEST_IDENTITY CMUX_TEST_IDENTITY ORCA_TEST_IDENTITY \
    FM_BACKEND_HERDR_TEST FM_ZELLIJ_TEST_IDENTITY
  do
    printf '%s=sentinel-must-not-leak\n' "$key" > "$HOME_DIR/config/dev_startup.env"
    if err=$(fm_dev_startup_env_validate "$HOME_DIR/config/dev_startup.env" 2>&1); then
      fail "protected startup key was accepted: $key"
    fi
    assert_contains "$err" "protected dev_startup.env key: $key" "protected-key diagnostic missed $key"
    assert_not_contains "$err" 'sentinel-must-not-leak' "protected-key diagnostic leaked the value for $key"
  done
  pass "invalid syntax and protected keys refuse before allocation without exposing values"
}

test_common_spawn_wrapper_and_fake_harness_child() {
  local rec id out status launch artifact result observed harness name
  id=dev-env-launch-z2
  rec=$(make_spawn_case launch "$id")
  read_spawn_case "$rec"
  cat > "$HOME_DIR/config/dev_startup.env" <<'ENV'
DEV_STARTUP_SENTINEL=ok
LANGFUSE_URL=https://example.invalid
ENV
  out=$(run_spawn "$id" 'fake-harness --run')
  status=$?
  expect_code 0 "$status" "fake harness spawn with startup env should succeed"
  launch=$(tail -n 1 "$LAUNCH_LOG")
  artifact="/tmp/fm-$id/dev-startup-env.sh"
  [ -f "$artifact" ] || fail "spawn did not leave the artifact for the launched shell"
  [ "$(file_mode "$artifact")" = 600 ] || fail "spawn artifact mode is not 0600"
  assert_contains "$launch" ". '$artifact'; rm -f -- '$artifact'; fake-harness --run" \
    "common launch wrapper does not load, remove, then launch"
  for observed in "$out" "$(cat "$HOME_DIR/state/$id.meta")" "$(cat "$HOME_DIR/data/$id/brief.md")" "$launch"; do
    assert_not_contains "$observed" 'https://example.invalid' "configured value leaked into spawn records or output"
    assert_not_contains "$observed" 'DEV_STARTUP_SENTINEL=ok' "configured assignment leaked into spawn records or output"
  done
  result="$CASE_DIR/result"
  FM_FAKE_RESULT="$result" PATH="$FAKEBIN_DIR:$BASE_PATH" bash -c "$(cat "$LAUNCH_LOG")"
  assert_absent "$artifact" "launched shell did not immediately remove the generated artifact"
  [ "$(cat "$result")" = $'harness:ok:https://example.invalid\nchild:ok:https://example.invalid' ] \
    || fail "fake harness or child did not inherit configured values"
  assert_absent "$WT_DIR/.env" "spawn injected a .env into the worktree"
  [ -z "$(git -C "$WT_DIR" status --porcelain)" ] || fail "startup environment dirtied the worktree"

  for harness in claude codex opencode pi grok; do
    name="template-$harness"
    id="dev-env-${harness}-z3"
    rec=$(make_spawn_case "$name" "$id")
    read_spawn_case "$rec"
    printf 'DEV_STARTUP_SENTINEL=template-sentinel\n' > "$HOME_DIR/config/dev_startup.env"
    out=$(run_spawn "$id" --harness "$harness")
    status=$?
    expect_code 0 "$status" "$harness spawn should pass through the common startup wrapper"
    launch=$(tail -n 1 "$LAUNCH_LOG")
    assert_contains "$launch" ". '/tmp/fm-$id/dev-startup-env.sh'; rm -f -- '/tmp/fm-$id/dev-startup-env.sh';" \
      "$harness launch did not pass through the common wrapper"
    assert_not_contains "$launch" 'template-sentinel' "$harness launch command exposed a configured value"
    assert_not_contains "$(cat "$HOME_DIR/state/$id.meta")" 'template-sentinel' "$harness metadata exposed a configured value"
  done
  pass "tmux and all five harness templates use one redacted wrapper; harness children inherit values without worktree files"
}

test_scout_and_secondmate_launches_receive_environment() {
  local rec id out status result artifact secondmate_home
  id=dev-env-scout-z5
  rec=$(make_spawn_case scout "$id")
  read_spawn_case "$rec"
  cat > "$HOME_DIR/config/dev_startup.env" <<'ENV'
DEV_STARTUP_SENTINEL=scout-ok
LANGFUSE_URL=https://scout.invalid
ENV
  out=$(run_spawn "$id" 'fake-harness --run' --scout)
  status=$?
  expect_code 0 "$status" "scout spawn with startup env should succeed"
  result="$CASE_DIR/scout-result"
  artifact="/tmp/fm-$id/dev-startup-env.sh"
  FM_FAKE_RESULT="$result" PATH="$FAKEBIN_DIR:$BASE_PATH" bash -c "$(cat "$LAUNCH_LOG")"
  [ "$(cat "$result")" = $'harness:scout-ok:https://scout.invalid\nchild:scout-ok:https://scout.invalid' ] \
    || fail "scout harness or child did not inherit configured values"
  assert_absent "$artifact" "scout launch did not remove its generated artifact"
  assert_not_contains "$out" 'https://scout.invalid' "scout spawn output exposed a configured value"

  id=dev-env-secondmate-z6
  rec=$(make_spawn_case secondmate "$id")
  read_spawn_case "$rec"
  secondmate_home="$CASE_DIR/secondmate-home"
  mkdir -p "$secondmate_home/bin" "$secondmate_home/data"
  printf '# Firstmate\n' > "$secondmate_home/AGENTS.md"
  printf '%s\n' "$id" > "$secondmate_home/.fm-secondmate-home"
  printf 'secondmate charter\n' > "$secondmate_home/data/charter.md"
  cat > "$HOME_DIR/config/dev_startup.env" <<'ENV'
DEV_STARTUP_SENTINEL=secondmate-ok
LANGFUSE_URL=https://secondmate-launch.invalid
ENV
  out=$(run_secondmate_spawn "$id" "$secondmate_home")
  status=$?
  expect_code 0 "$status" "secondmate spawn with startup env should succeed"
  result="$CASE_DIR/secondmate-result"
  artifact="/tmp/fm-$id/dev-startup-env.sh"
  FM_FAKE_RESULT="$result" PATH="$FAKEBIN_DIR:$BASE_PATH" bash -c "$(cat "$LAUNCH_LOG")"
  [ "$(cat "$result")" = $'harness:secondmate-ok:https://secondmate-launch.invalid\nchild:secondmate-ok:https://secondmate-launch.invalid' ] \
    || fail "secondmate harness or child did not inherit configured values"
  assert_absent "$artifact" "secondmate launch did not remove its generated artifact"
  [ "$(cat "$secondmate_home/config/dev_startup.env")" = 'DEV_STARTUP_SENTINEL=secondmate-ok'$'\n''LANGFUSE_URL=https://secondmate-launch.invalid' ] \
    || fail "secondmate spawn did not inherit dev_startup.env into its home"
  assert_not_contains "$out" 'https://secondmate-launch.invalid' "secondmate spawn output exposed a configured value"
  pass "scout and secondmate harnesses and their child processes receive the common startup environment"
}

test_read_once_respawn_and_inheritance() {
  local d src dest old_task new_task old_artifact new_artifact old_value new_value report changed
  d="$TMP_ROOT/read-once-inherit"
  src="$d/primary/config"
  dest="$d/secondmate/config"
  old_task="$d/old-task"
  new_task="$d/new-task"
  mkdir -p "$src" "$dest" "$old_task" "$new_task"
  printf 'DEV_STARTUP_SENTINEL=old\n' > "$src/dev_startup.env"

  propagate_inheritable_config "$src" "$dest" || fail "initial startup env inheritance failed"
  [ "$(cat "$dest/dev_startup.env")" = 'DEV_STARTUP_SENTINEL=old' ] || fail "initial inherited startup env is wrong"
  report="$d/inherit.report"
  printf 'dev_startup.env\tpushed\t\n' > "$report"
  changed=$(fm_config_reread_changed_items "$report")
  [ -z "$changed" ] || fail "dev_startup.env was included in a live-agent reread instruction"
  fm_dev_startup_env_validate "$dest/dev_startup.env" || fail "inherited startup env did not validate"
  printf 'DEV_STARTUP_SENTINEL=new\n' > "$dest/dev_startup.env"
  fm_dev_startup_env_prepare "$old_task" || fail "old task snapshot preparation failed"
  old_artifact=$FM_DEV_STARTUP_ENV_ARTIFACT
  reset_startup_env_ambient
  # shellcheck disable=SC1090
  . "$old_artifact"
  old_value=$DEV_STARTUP_SENTINEL
  reset_startup_env_ambient
  [ "$old_value" = old ] || fail "task reread a file changed after its spawn-time parse"

  printf 'DEV_STARTUP_SENTINEL=new\n' > "$src/dev_startup.env"
  propagate_inheritable_config "$src" "$dest" || fail "updated startup env inheritance failed"
  [ "$(cat "$dest/dev_startup.env")" = 'DEV_STARTUP_SENTINEL=new' ] || fail "inherited startup env update did not converge"
  fm_dev_startup_env_validate "$dest/dev_startup.env" || fail "updated inherited startup env did not validate"
  fm_dev_startup_env_prepare "$new_task" || fail "new task snapshot preparation failed"
  new_artifact=$FM_DEV_STARTUP_ENV_ARTIFACT
  reset_startup_env_ambient
  # shellcheck disable=SC1090
  . "$new_artifact"
  new_value=$DEV_STARTUP_SENTINEL
  reset_startup_env_ambient
  [ "$new_value" = new ] || fail "new spawn did not read the updated inherited value"

  rm -f "$src/dev_startup.env"
  propagate_inheritable_config "$src" "$dest" || fail "startup env absence convergence failed"
  assert_absent "$dest/dev_startup.env" "primary startup env removal did not mirror downstream"
  pass "secondmate inheritance copies, updates, and removes startup env; existing snapshots stay fixed while new spawns reread"
}

test_secondmate_own_crewmate_reads_inherited_file() {
  local rec id primary out status result artifact
  id=dev-env-secondmate-own-z4
  rec=$(make_spawn_case secondmate-own "$id")
  read_spawn_case "$rec"
  primary="$CASE_DIR/primary-config"
  mkdir -p "$primary"
  cat > "$primary/dev_startup.env" <<'ENV'
DEV_STARTUP_SENTINEL=inherited-ok
LANGFUSE_URL=https://secondmate.invalid
ENV
  propagate_inheritable_config "$primary" "$HOME_DIR/config" || fail "secondmate startup env inheritance failed"
  out=$(run_spawn "$id" 'fake-harness --run')
  status=$?
  expect_code 0 "$status" "secondmate home's own crewmate spawn should succeed"
  result="$CASE_DIR/result"
  artifact="/tmp/fm-$id/dev-startup-env.sh"
  FM_FAKE_RESULT="$result" PATH="$FAKEBIN_DIR:$BASE_PATH" bash -c "$(cat "$LAUNCH_LOG")"
  [ "$(cat "$result")" = $'harness:inherited-ok:https://secondmate.invalid\nchild:inherited-ok:https://secondmate.invalid' ] \
    || fail "secondmate home's own crewmate did not receive inherited startup values"
  assert_absent "$artifact" "secondmate-own launch did not remove its generated artifact"
  assert_not_contains "$out" 'https://secondmate.invalid' "secondmate-own spawn output exposed an inherited value"
  pass "a secondmate home's own crewmate and child process read its inherited dev_startup.env"
}

test_absent_is_noop
test_parser_artifact_and_literal_values
test_invalid_and_protected_refuse_before_allocation
test_common_spawn_wrapper_and_fake_harness_child
test_scout_and_secondmate_launches_receive_environment
test_read_once_respawn_and_inheritance
test_secondmate_own_crewmate_reads_inherited_file
