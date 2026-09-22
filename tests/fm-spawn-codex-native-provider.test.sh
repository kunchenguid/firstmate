#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's narrow Codex native-subscription guard.
# Every Codex executable in this suite is a local fixture. No model or provider
# endpoint is contacted.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-codex-native-provider)

make_case() { # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  mkdir -p "$home/user-home/.codex"
  cat > "$home/user-home/.codex/config.toml" <<'TOML'
model_provider = "metered"
openai_base_url = "https://metered.invalid/v1"

[model_providers.metered]
name = "Metered custom provider"
base_url = "https://metered.invalid/v1"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
TOML
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
set -u
fixture_dir=$(cd "$(dirname "$0")" && pwd -P)
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
  printf '%s\n' \
    "CODEX_HOME=${CODEX_HOME-unset}" \
    "OPENAI_API_KEY=${OPENAI_API_KEY-unset}" \
    "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY-unset}" \
    "CODEX_API_KEY=${CODEX_API_KEY-unset}" \
    "CODEX_ACCESS_TOKEN=${CODEX_ACCESS_TOKEN-unset}" \
    "OPENAI_BASE_URL=${OPENAI_BASE_URL-unset}" > "$fixture_dir/codex-preflight.env"
  if [ -f "$fixture_dir/codex-status" ]; then
    cat "$fixture_dir/codex-status"
  else
    printf 'Logged in using ChatGPT\n'
  fi
  if [ -f "$fixture_dir/codex-status-code" ]; then
    exit "$(cat "$fixture_dir/codex-status-code")"
  fi
  exit 0
fi
printf '%s\n' "$@" > "$fixture_dir/codex-launch.argv"
printf '%s\n' \
  "CODEX_HOME=${CODEX_HOME-unset}" \
  "OPENAI_API_KEY=${OPENAI_API_KEY-unset}" \
  "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY-unset}" \
  "CODEX_API_KEY=${CODEX_API_KEY-unset}" \
  "CODEX_ACCESS_TOKEN=${CODEX_ACCESS_TOKEN-unset}" \
  "OPENAI_BASE_URL=${OPENAI_BASE_URL-unset}" > "$fixture_dir/codex-launch.env"
SH
  chmod +x "$fakebin/codex"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
  LAUNCH_LOG="$CASE_DIR/launch.log"
  CODEX_HOME_DIR="$HOME_DIR/user-home/.codex"
}

run_native() {
  local id=$1
  shift
  : > "$LAUNCH_LOG"
  CODEX_HOME="$CODEX_HOME_DIR" \
    OPENAI_API_KEY=forbidden-openai ANTHROPIC_API_KEY=forbidden-anthropic \
    CODEX_API_KEY=forbidden-codex CODEX_ACCESS_TOKEN=forbidden-access \
    OPENAI_BASE_URL=https://ambient.invalid/v1 \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
      --harness codex --codex-native-provider "$@"
}

assert_native_env() { # <file>
  local file=$1
  assert_grep "CODEX_HOME=$CODEX_HOME_DIR" "$file" "native Codex did not use the preflighted CODEX_HOME"
  assert_grep 'OPENAI_API_KEY=unset' "$file" "OPENAI_API_KEY reached native Codex"
  assert_grep 'ANTHROPIC_API_KEY=unset' "$file" "ANTHROPIC_API_KEY reached native Codex"
  assert_grep 'CODEX_API_KEY=unset' "$file" "CODEX_API_KEY reached native Codex"
  assert_grep 'CODEX_ACCESS_TOKEN=unset' "$file" "CODEX_ACCESS_TOKEN reached native Codex"
  assert_grep 'OPENAI_BASE_URL=unset' "$file" "OPENAI_BASE_URL reached native Codex"
}

test_native_launch_pins_builtin_provider_and_environment() {
  local rec id out rc launch
  id=native-provider-ok
  rec=$(make_case native-ok "$id")
  read_case "$rec"
  out=$(run_native "$id"); rc=$?
  expect_code 0 "$rc" "native Codex spawn should succeed: $out"
  assert_native_env "$FAKEBIN_DIR/codex-preflight.env"
  assert_grep 'codex_native_provider=chatgpt' "$HOME_DIR/state/$id.meta" "task metadata did not retain the native billing posture"
  assert_grep "codex_native_bin=$FAKEBIN_DIR/codex" "$HOME_DIR/state/$id.meta" "task metadata did not retain the pinned Codex executable"
  assert_grep "codex_native_home=$CODEX_HOME_DIR" "$HOME_DIR/state/$id.meta" "task metadata did not retain the pinned CODEX_HOME"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/codex'" "launch did not bind the absolute preflighted Codex executable"
  assert_contains "$launch" "model_provider=\"openai\"" "launch did not select the built-in OpenAI provider"
  assert_contains "$launch" "openai_base_url=\"\"" "launch did not clear a configured OpenAI base URL"
  assert_contains "$launch" "forced_login_method=\"chatgpt\"" "launch did not force ChatGPT authentication"
  OPENAI_API_KEY=launch-openai ANTHROPIC_API_KEY=launch-anthropic \
    CODEX_API_KEY=launch-codex CODEX_ACCESS_TOKEN=launch-access \
    OPENAI_BASE_URL=https://launch.invalid/v1 \
    PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch" \
      || fail "captured native Codex launch did not execute"
  assert_native_env "$FAKEBIN_DIR/codex-launch.env"
  assert_grep 'model_provider="openai"' "$FAKEBIN_DIR/codex-launch.argv" "executed launch lost provider pin"
  assert_grep 'openai_base_url=""' "$FAKEBIN_DIR/codex-launch.argv" "executed launch lost endpoint reset"
  assert_grep 'forced_login_method="chatgpt"' "$FAKEBIN_DIR/codex-launch.argv" "executed launch lost ChatGPT auth pin"
  pass "Codex native launch overrides malicious provider config and scrubs API credential surfaces"
}

test_native_launch_survives_empty_allowlist() {
  local rec id out rc launch
  id=native-provider-allowlist
  rec=$(make_case native-allowlist "$id")
  read_case "$rec"
  : > "$HOME_DIR/config/launch-env-allowlist"
  out=$(run_native "$id"); rc=$?
  expect_code 0 "$rc" "native Codex spawn with empty launch allowlist should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  OPENAI_API_KEY=launch-openai ANTHROPIC_API_KEY=launch-anthropic \
    CODEX_API_KEY=launch-codex CODEX_ACCESS_TOKEN=launch-access \
    OPENAI_BASE_URL=https://launch.invalid/v1 \
    PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch" \
      || fail "allowlisted native Codex launch did not execute"
  assert_native_env "$FAKEBIN_DIR/codex-launch.env"
  pass "Codex native binding and credential scrubbing survive the launch environment allowlist"
}

test_native_auth_refuses_non_chatgpt_and_failure() {
  local rec id out rc mode
  for mode in api-key malformed failed; do
    id="native-auth-$mode"
    rec=$(make_case "$id" "$id")
    read_case "$rec"
    case "$mode" in
      api-key) printf 'Logged in using an API key\n' > "$FAKEBIN_DIR/codex-status" ;;
      malformed) printf 'Logged in using ChatGPT\nextra output\n' > "$FAKEBIN_DIR/codex-status" ;;
      failed)
        printf 'Logged in using ChatGPT\n' > "$FAKEBIN_DIR/codex-status"
        printf '7\n' > "$FAKEBIN_DIR/codex-status-code"
        ;;
    esac
    out=$(run_native "$id"); rc=$?
    expect_code 1 "$rc" "$mode login status must refuse native Codex"
    assert_contains "$out" "report exactly 'Logged in using ChatGPT'" "$mode refusal did not name the native-auth requirement"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "$mode auth refusal published task metadata"
    [ ! -s "$LAUNCH_LOG" ] || fail "$mode auth refusal delivered a worker launch"
  done
  pass "Codex native preflight requires one exact ChatGPT login-status result"
}

test_native_shape_refuses_before_task_mutation() {
  local rec id out rc args name
  for name in implicit positional non-codex raw batch secondmate relaunch orca; do
    id="native-shape-$name"
    rec=$(make_case "$id" "$id")
    read_case "$rec"
    : > "$LAUNCH_LOG"
    case "$name" in
      implicit) args=("$id" "$PROJ_DIR" --mode no-mistakes --yolo off --codex-native-provider) ;;
      positional) args=("$id" "$PROJ_DIR" codex --mode no-mistakes --yolo off --codex-native-provider) ;;
      non-codex) args=("$id" "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --codex-native-provider) ;;
      raw) args=("$id" "$PROJ_DIR" 'codex --custom' --mode no-mistakes --yolo off --codex-native-provider) ;;
      batch) args=("$id=$PROJ_DIR" --mode no-mistakes --yolo off --harness codex --codex-native-provider) ;;
      secondmate) args=("$id" "$PROJ_DIR" --secondmate --harness codex --codex-native-provider) ;;
      relaunch) args=("$id" --relaunch --harness codex --codex-native-provider) ;;
      orca) args=("$id" "$PROJ_DIR" --mode no-mistakes --yolo off --harness codex --backend orca --codex-native-provider) ;;
    esac
    out=$(CODEX_HOME="$CODEX_HOME_DIR" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "${args[@]}"); rc=$?
    expect_code 1 "$rc" "$name native-provider shape should refuse"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "$name shape refusal published task metadata"
    [ ! -e "$HOME_DIR/state/.spawn-$id.lock" ] || fail "$name shape refusal took the task spawn lock"
    [ ! -s "$LAUNCH_LOG" ] || fail "$name shape refusal delivered a worker launch"
  done
  pass "Codex native guard refuses unsupported lifecycle shapes before task mutation"
}

test_native_launch_pins_builtin_provider_and_environment
test_native_launch_survives_empty_allowlist
test_native_auth_refuses_non_chatgpt_and_failure
test_native_shape_refuses_before_task_mutation

printf '\nAll Codex native-provider spawn tests passed.\n'
