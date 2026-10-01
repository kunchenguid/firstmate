#!/usr/bin/env bash
# tests/fm-worker-env.test.sh - the intended worker environment and its drift
# detector.
#
# The parser and detector are exercised in process; the launch integration is
# driven through the real spawn against a fake pane and a real isolated git
# worktree, so the assertion is what the pane actually received.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-worker-env.sh
. "$ROOT/bin/fm-worker-env.sh"

ENVSH="$ROOT/bin/fm-worker-env.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-env)
# The resolved defaults come from the ambient roots, so pin the test's own
# expectation to whatever this process carries rather than assuming a value.
unset XDG_CONFIG_HOME XDG_DATA_HOME

make_fake_opencode() {  # <dir>
  cat > "$1/opencode" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'opencode v0.0.0-fake\n'
fi
exit 0
SH
  chmod +x "$1/opencode"
}

write_worker_env() {  # <config-dir> <line>...
  local config=$1 line
  shift
  mkdir -p "$config"
  : > "$config/worker-env"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$config/worker-env"
  done
}

test_absent_file_applies_defaults() {
  local home config got
  home="$TMP_ROOT/absent"
  config="$home/config"
  mkdir -p "$config"

  fm_worker_env_load "$config" || fail "an absent config/worker-env must load cleanly"
  assert_equals '' "$FM_WORKER_ENV_PATH" "absent file should declare no PATH"
  assert_equals '' "$FM_WORKER_ENV_XDG_CONFIG_HOME" "absent file should declare no config root"
  assert_equals '' "$FM_WORKER_ENV_XDG_DATA_HOME" "absent file should declare no data root"
  assert_equals '' "$FM_WORKER_ENV_OPENCODE_BIN" "absent file should declare no opencode bin"

  got=$(fm_worker_env_resolved_path)
  assert_equals "${PATH:-}" "$got" "an undeclared PATH should fall back to the launching PATH"
  got=$(fm_worker_env_resolved_config_home)
  assert_equals "${XDG_CONFIG_HOME:-${HOME:-}/.config}" "$got" "an undeclared config root should fall back to the ambient root"
  got=$(fm_worker_env_resolved_data_home)
  assert_equals "${XDG_DATA_HOME:-${HOME:-}/.local/share}" "$got" "an undeclared data root should fall back to the ambient root"
  got=$(fm_worker_env_opencode_launch_bin)
  assert_equals 'opencode' "$got" "an undeclared opencode bin should stay the bare command"
  pass "an absent config/worker-env leaves every documented default in force"
}

test_declared_values_resolve() {
  local home config got bin
  home="$TMP_ROOT/declared"
  config="$home/config"
  bin="$home/fake/opencode"
  mkdir -p "$home/fake"
  make_fake_opencode "$home/fake"
  write_worker_env "$config" \
    'PATH=/usr/bin:/bin' \
    "XDG_CONFIG_HOME=$home/cfg" \
    "XDG_DATA_HOME=$home/data" \
    "OPENCODE_BIN=$bin"

  fm_worker_env_load "$config" || fail "a valid config/worker-env must load"
  assert_equals '/usr/bin:/bin' "$(fm_worker_env_resolved_path)" "declared PATH should win"
  assert_equals "$home/cfg" "$(fm_worker_env_resolved_config_home)" "declared config root should win"
  assert_equals "$home/data" "$(fm_worker_env_resolved_data_home)" "declared data root should win"
  got=$(fm_worker_env_opencode_launch_bin)
  assert_equals "'$bin'" "$got" "a declared opencode bin should become a quoted absolute path"
  pass "declared config/worker-env values override the ambient defaults"
}

test_malformed_file_refuses() {
  local home config out status line
  home="$TMP_ROOT/malformed"
  config="$home/config"
  # Each case names what is wrong so a partial parse cannot pass silently.
  while IFS='|' read -r label line; do
    write_worker_env "$config" "$line"
    out=$(fm_worker_env_load "$config" 2>&1)
    status=$?
    expect_code 1 "$status" "$label should refuse"
    assert_contains "$out" "config/worker-env" "$label refusal should name the file"
  done <<'CASES'
unknown key|BOGUS=/tmp
relative path|XDG_DATA_HOME=relative/dir
empty value|OPENCODE_BIN=
not name=value|X
relative PATH entry|PATH=/usr/bin:relative
CASES
  pass "a malformed config/worker-env is refused with a naming error"
}

test_promote_bindir() {
  local got
  got=$(fm_worker_env_promote_bindir '/a:/b:/c' '/b/opencode')
  assert_equals '/b:/a:/c' "$got" "promotion should move the binary directory to the front"
  got=$(fm_worker_env_promote_bindir '/a:/b' 'opencode')
  assert_equals '/a:/b' "$got" "a bare name should leave the path unchanged"
  got=$(fm_worker_env_promote_bindir '/a:/b' '/c/opencode')
  assert_equals '/c:/a:/b' "$got" "a new directory should be prepended"
  pass "promoting the resolved binary directory is idempotent and order-stable"
}

# --- detector ---------------------------------------------------------------

run_detector() {  # <config-dir> <home> [args...]
  local config=$1 home=$2
  shift 2
  env -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
    -u OPENCODE_API_KEY -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GEMINI_API_KEY -u OPENROUTER_API_KEY \
    HOME="$home" FM_CONFIG_OVERRIDE="$config" PATH="$FAKEBIN:$PATH" \
    bash "$ENVSH" check "$@" 2>&1
}

test_detector_clean() {
  local home config bin out status
  home="$TMP_ROOT/detector-clean"
  config="$home/config"
  bin="$home/fake/opencode"
  FAKEBIN="$home/fake"
  mkdir -p "$FAKEBIN" "$home/data/opencode" "$home/cfg/opencode"
  make_fake_opencode "$FAKEBIN"
  printf "{}\n" > "$home/data/opencode/auth.json"
  write_worker_env "$config" \
    "PATH=$FAKEBIN:/usr/bin:/bin" \
    "XDG_CONFIG_HOME=$home/cfg" \
    "XDG_DATA_HOME=$home/data" \
    "OPENCODE_BIN=$bin"

  out=$(run_detector "$config" "$home" --harness opencode)
  status=$?
  expect_code 0 "$status" "a fully provisioned worker environment should report no drift: $out"
  assert_contains "$out" "opencode v0.0.0-fake" "the detector should report the resolved opencode version"
  pass "a provisioned worker environment reports no drift"
}

test_detector_flags_missing_auth() {
  local home config bin out status
  home="$TMP_ROOT/detector-noauth"
  config="$home/config"
  bin="$home/fake/opencode"
  FAKEBIN="$home/fake"
  mkdir -p "$FAKEBIN" "$home/cfg/opencode"
  make_fake_opencode "$FAKEBIN"
  write_worker_env "$config" \
    "PATH=$FAKEBIN:/usr/bin:/bin" \
    "XDG_CONFIG_HOME=$home/cfg" \
    "XDG_DATA_HOME=$home/data" \
    "OPENCODE_BIN=$bin"

  out=$(run_detector "$config" "$home" --harness opencode)
  status=$?
  expect_code 1 "$status" "missing opencode auth should be a drift: $out"
  assert_contains "$out" "no opencode credential" "the detector should name the missing credential"
  pass "missing opencode auth is reported as drift"
}

test_detector_flags_unresolvable_harness() {
  local home config out status
  home="$TMP_ROOT/detector-noharness"
  config="$home/config"
  FAKEBIN="$home/fake"
  mkdir -p "$FAKEBIN"
  write_worker_env "$config" "PATH=$FAKEBIN:/usr/bin:/bin"

  out=$(run_detector "$config" "$home" --harness definitely-not-installed)
  status=$?
  expect_code 1 "$status" "an unresolvable harness should be a drift: $out"
  assert_contains "$out" "not resolvable" "the detector should name the unresolved harness"
  pass "an unresolvable harness is reported as drift"
}

test_detector_flags_primary_worktree_root() {
  local home config proj wt out status
  home="$TMP_ROOT/detector-root"
  config="$home/config"
  FAKEBIN="$home/fake"
  mkdir -p "$FAKEBIN" "$home/cfg/opencode" "$home/data/opencode"
  make_fake_opencode "$FAKEBIN"
  printf "{}\n" > "$home/data/opencode/auth.json"
  write_worker_env "$config" \
    "PATH=$FAKEBIN:/usr/bin:/bin" \
    "XDG_CONFIG_HOME=$home/cfg" \
    "XDG_DATA_HOME=$home/data" \
    "OPENCODE_BIN=$FAKEBIN/opencode"
  proj="$home/project"
  wt="$home/wt"
  fm_git_worktree "$proj" "$wt" "wt-detector-root"

  out=$(run_detector "$config" "$home" --harness opencode --worktree "$wt" --primary "$proj")
  status=$?
  expect_code 0 "$status" "a linked worktree distinct from the primary should be clean: $out"

  out=$(run_detector "$config" "$home" --harness opencode --worktree "$proj" --primary "$proj")
  status=$?
  expect_code 1 "$status" "a worktree root equal to the primary checkout should be drift: $out"
  assert_contains "$out" "primary checkout" "the detector should name the primary checkout root"
  pass "the detector separates a real task worktree from the primary checkout"
}

# --- launch integration -----------------------------------------------------

make_spawn_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

test_opencode_launch_carries_the_worker_environment() {
  local rec id out status launch
  id=worker-env-opencode-a1
  rec=$(make_spawn_case worker-env-opencode opencode "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "opencode spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "export PATH=" "opencode launch must establish the worker PATH explicitly"
  assert_contains "$launch" "XDG_CONFIG_HOME=" "opencode launch must establish the config root explicitly"
  assert_contains "$launch" "XDG_DATA_HOME=" "opencode launch must establish the data root explicitly"
  assert_contains "$launch" "OPENCODE_CONFIG_CONTENT=" "opencode launch must keep its config content"
  assert_not_contains "$launch" "__OPENCODEBIN__" "the opencode binary placeholder must be substituted"
  pass "an opencode launch carries an explicit PATH and XDG roots"
}

test_opencode_launch_executes_with_the_declared_environment() {
  local rec id out status launch seen setting
  id=worker-env-opencode-exec-a1
  rec=$(make_spawn_case worker-env-opencode-exec opencode "$id")
  read_case "$rec"
  cat > "$FAKEBIN_DIR/opencode" <<'SH'
#!/bin/sh
printf 'CFG=%s DATA=%s\n' "${XDG_CONFIG_HOME-unset}" "${XDG_DATA_HOME-unset}"
SH
  chmod +x "$FAKEBIN_DIR/opencode"
  write_worker_env "$HOME_DIR/config" \
    "PATH=$FAKEBIN_DIR:/usr/bin:/bin" \
    "XDG_CONFIG_HOME=$HOME_DIR/cfg" \
    "XDG_DATA_HOME=$HOME_DIR/data"

  # Both allowlist postures must carry the declared values: the cleared
  # environment is where a value that only rides the daemon would be lost.
  for setting in absent enabled; do
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "opencode spawn with allowlist=$setting should succeed: $out"
    launch=$(cat "$LAUNCH_LOG")
    # Execute the emitted launch under a synthetic pane whose ambient roots are
    # contrary, so only a launch that sets them can pass.
    seen=$(env -i HOME="$HOME_DIR/user-home" PATH=/usr/bin:/bin TERM=xterm \
      TMUX=synthetic-pane \
      XDG_CONFIG_HOME=/ambient/cfg XDG_DATA_HOME=/ambient/data \
      /bin/sh -c "$launch") \
      || fail "opencode launch with allowlist=$setting failed to run"
    assert_contains "$seen" "CFG=$HOME_DIR/cfg DATA=$HOME_DIR/data" \
      "the opencode launch with allowlist=$setting did not hand the worker its declared roots"
  done
  pass "the emitted opencode launch sets the declared roots for the worker"
}

test_opencode_launch_uses_a_declared_binary() {
  local rec id out status launch bin
  id=worker-env-opencode-pin-a1
  rec=$(make_spawn_case worker-env-opencode-pin opencode "$id")
  read_case "$rec"
  bin="$FAKEBIN_DIR/opencode"
  cat > "$bin" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$bin"
  write_worker_env "$HOME_DIR/config" "OPENCODE_BIN=$bin"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "pinned opencode spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$bin'" "a declared OPENCODE_BIN must replace the bare command"
  assert_not_contains "$launch" "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode --prompt" \
    "a pinned launch must not fall back to the bare opencode name"
  pass "a declared OPENCODE_BIN is launched by absolute path"
}

test_other_harnesses_keep_their_launch() {
  local rec id out status launch
  id=worker-env-codex-a1
  rec=$(make_spawn_case worker-env-codex codex "$id")
  read_case "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "codex spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "export PATH=" "the opencode worker environment must not touch other harnesses"
  pass "the opencode worker environment stays scoped to the opencode adapter"
}

test_malformed_worker_env_refuses_before_metadata() {
  local rec id out status
  id=worker-env-malformed-a1
  rec=$(make_spawn_case worker-env-malformed opencode "$id")
  read_case "$rec"
  write_worker_env "$HOME_DIR/config" "BOGUS=/tmp"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a malformed config/worker-env should refuse the spawn"
  assert_contains "$out" "config/worker-env" "the refusal should name the malformed file"
  assert_absent "$HOME_DIR/state/$id.meta" "the refusal should happen before metadata is written"
  pass "a malformed config/worker-env refuses before any endpoint or record exists"
}

test_absent_file_applies_defaults
test_declared_values_resolve
test_malformed_file_refuses
test_promote_bindir
test_detector_clean
test_detector_flags_missing_auth
test_detector_flags_unresolvable_harness
test_detector_flags_primary_worktree_root
test_opencode_launch_carries_the_worker_environment
test_opencode_launch_executes_with_the_declared_environment
test_opencode_launch_uses_a_declared_binary
test_other_harnesses_keep_their_launch
test_malformed_worker_env_refuses_before_metadata
