#!/usr/bin/env bash
# TeamClaude worker routing. Drives bin/fm-teamclaude.sh and the launch
# command fm-spawn actually sends. Nothing here reads implementation source.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ROOT_BIN="$ROOT/bin/fm-teamclaude.sh"
TMP_ROOT=$(fm_test_tmproot fm-teamclaude-routing)
STUB="$ROOT/tests/fixtures/teamclaude-stub"

make_case() {
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
  local _case
  IFS='|' read -r _case HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  : > "$LAUNCH_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

install_down_teamclaude() {
  cat > "$1/teamclaude" <<'SH'
#!/bin/sh
cmd=${1:-}
case "$cmd" in
  env)
    dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
    printf "export HTTPS_PROXY=http://127.0.0.1:9\n"
    printf "export HTTP_PROXY=http://127.0.0.1:9\n"
    printf "export NODE_EXTRA_CA_CERTS='%s'\n" "$dir/ca.pem"
    printf 'unset ANTHROPIC_BASE_URL\n'
    ;;
  status)
    printf 'Cannot connect to proxy at localhost:9\n' >&2
    exit 1
    ;;
  threshold)
    printf 'Switch threshold: 95%%\n  unified5h: 80%%\n'
    ;;
  *) exit 1 ;;
esac
SH
  cp "$STUB/ca.pem" "$1/ca.pem"
  chmod +x "$1/teamclaude"
}

test_claude_env_is_mitm_without_a_direct_fallback() {
  local env_out
  env_out=$("$ROOT_BIN" claude-env) || fail "claude-env failed against the suite stub"
  assert_contains "$env_out" "HTTPS_PROXY='http://127.0.0.1:3456'" \
    "claude-env did not publish the MITM proxy"
  assert_contains "$env_out" "-u ANTHROPIC_BASE_URL" \
    "claude-env did not clear a direct base URL"
  assert_contains "$env_out" "NODE_EXTRA_CA_CERTS=" \
    "claude-env did not publish the TeamClaude CA"
  assert_not_contains "$env_out" "ANTHROPIC_API_KEY" \
    "claude-env must not put an API key on the launch"
  assert_not_contains "$env_out" "auto-fallback" \
    "claude-env must not offer a direct fallback"
  pass "claude-env is the MITM proxy environment with no direct fallback"
}

test_missing_cli_refuses_loudly() {
  local out status
  out=$(PATH="/usr/bin:/bin" "$ROOT_BIN" claude-env 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "a missing teamclaude CLI must refuse"
  assert_contains "$out" "not on PATH" "the refusal must say the CLI is missing"
  assert_contains "$out" "no direct fallback" "the refusal must say there is no direct fallback"
  assert_not_contains "$out" "auto-fallback" "the refusal must not mention a direct fallback flag"
  pass "a missing teamclaude CLI refuses the worker and names the missing tool"
}

test_down_proxy_refuses_loudly() {
  local down out status
  down="$TMP_ROOT/down-cli"
  mkdir -p "$down"
  install_down_teamclaude "$down"
  out=$(PATH="$down:/usr/bin:/bin" "$ROOT_BIN" claude-env 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "a down proxy must refuse claude-env"
  assert_contains "$out" "not available" "the refusal must say the proxy is down"
  assert_contains "$out" "no direct fallback" "the refusal must say there is no direct fallback"
  assert_contains "$out" "Cannot connect to proxy" "the refusal must keep the proxy diagnostic"
  pass "a down TeamClaude proxy refuses with the proxy diagnostic and no direct fallback"
}

threshold_report() {  # <state-file>
  FM_TEST_TEAMCLAUDE_THRESHOLD_FILE="$1" "$STUB/teamclaude" threshold
}

test_thresholds_at_policy_start_without_reapplying() {
  local out status file state
  file="$TMP_ROOT/threshold-already"
  for state in 'default=95%|unified5h=80%' 'default=80%|unified7d=95%'; do
    printf '%s\n' "$state" | tr '|' '\n' > "$file"
    out=$(FM_TEST_TEAMCLAUDE_THRESHOLD_FILE="$file" FM_TEST_TEAMCLAUDE_SET_RC=1 \
      "$ROOT_BIN" claude-env 2>"$TMP_ROOT/threshold-already.err") && status=0 || status=$?
    expect_code 0 "$status" "thresholds already at 5h 80% and 7d 95% ($state) must start without a set: $(cat "$TMP_ROOT/threshold-already.err")"
    assert_contains "$out" "HTTPS_PROXY=" "the launch fragment is produced when the thresholds match"
  done
  pass "thresholds already at unified5h 80% and unified7d 95% start the worker without reapplying them"
}

test_thresholds_off_policy_are_set_per_bucket() {
  local out status file state
  file="$TMP_ROOT/threshold-applied"
  for state in 'default=80%' 'default=95%'; do
    printf '%s\n' "$state" > "$file"
    out=$(FM_TEST_TEAMCLAUDE_THRESHOLD_FILE="$file" "$ROOT_BIN" claude-env 2>"$TMP_ROOT/threshold.err") && status=0 || status=$?
    expect_code 0 "$status" "thresholds TeamClaude accepts must let the launch start ($state): $(cat "$TMP_ROOT/threshold.err")"
    assert_contains "$out" "HTTPS_PROXY=" "the launch fragment is produced once the thresholds match"
    assert_equals "Switch threshold: ${state#default=}"$'\n'"  unified5h: 80%"$'\n'"  unified7d: 95%" \
      "$(threshold_report "$file")" \
      "the launch must set unified5h to 80% and unified7d to 95% and leave the default ($state) alone"
  done
  pass "thresholds off the policy are set per bucket to 5h 80% and 7d 95%, never flattened"
}

test_threshold_read_ignores_stderr_noise() {
  local out status file
  file="$TMP_ROOT/threshold-noisy"
  printf 'default=95%%\nunified5h=80%%\n' > "$file"
  out=$(FM_TEST_TEAMCLAUDE_THRESHOLD_FILE="$file" FM_TEST_TEAMCLAUDE_SET_RC=1 \
    FM_TEST_TEAMCLAUDE_STDERR='(node:1) DeprecationWarning: noisy runtime' \
    "$ROOT_BIN" claude-env 2>"$TMP_ROOT/threshold-noisy.err") && status=0 || status=$?
  expect_code 0 "$status" "matching thresholds with stderr noise must start: $(cat "$TMP_ROOT/threshold-noisy.err")"
  assert_contains "$out" "HTTPS_PROXY=" "the launch fragment is produced when the thresholds match"
  pass "a runtime warning on stderr does not hide matching thresholds"
}

test_claude_env_carries_the_hold_timeout() {
  local out seen
  out=$(FM_TEST_TEAMCLAUDE_HOLD_MS=180000 "$ROOT_BIN" claude-env) || fail "claude-env failed with a hold timeout"
  seen=$(eval "env $out /bin/sh -c 'printf %s \"\${API_TIMEOUT_MS-unset}\"'") \
    || fail "the claude-env fragment did not run"
  assert_equals "180000" "$seen" "a Claude worker must get TeamClaude's API_TIMEOUT_MS"
  out=$("$ROOT_BIN" claude-env) || fail "claude-env failed without a hold timeout"
  seen=$(eval "env -u API_TIMEOUT_MS $out /bin/sh -c 'printf %s \"\${API_TIMEOUT_MS-unset}\"'") \
    || fail "the claude-env fragment did not run"
  assert_equals "unset" "$seen" "without a hold, claude-env must not set API_TIMEOUT_MS"
  pass "claude-env passes TeamClaude's hold timeout to the Claude worker"
}

test_thresholds_that_stay_off_policy_refuse_loudly() {
  local out status
  out=$(FM_TEST_TEAMCLAUDE_THRESHOLD='80%' "$ROOT_BIN" claude-env 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "thresholds that do not reach the policy must refuse"
  assert_contains "$out" "still unified5h=80% unified7d=80%" "the refusal must name the thresholds it read"
  assert_contains "$out" "no direct fallback" "the refusal must say there is no direct fallback"
  assert_not_contains "$out" "HTTPS_PROXY=" "a refused launch must not produce the proxy fragment"

  out=$(FM_TEST_TEAMCLAUDE_THRESHOLD='80%' FM_TEST_TEAMCLAUDE_SET_RC=1 "$ROOT_BIN" claude-env 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "thresholds that cannot be applied must refuse"
  assert_contains "$out" "teamclaude threshold unified5h=80 unified7d=95\` failed" "the refusal must say applying the thresholds failed"
  assert_contains "$out" "cannot write the proxy config" "the refusal must keep TeamClaude's diagnostic"
  pass "thresholds that cannot be applied or verified refuse the worker"
}

test_codex_shim_resolves_to_the_real_binary() {
  local bin_dir out
  bin_dir="$TMP_ROOT/shim-path"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'SH'
#!/bin/sh
# opencodex codex autostart shim
printf 'shim\n'
SH
  cat > "$bin_dir/codex.opencodex-real" <<'SH'
#!/bin/sh
printf 'real\n'
SH
  chmod +x "$bin_dir/codex" "$bin_dir/codex.opencodex-real"
  out=$(PATH="$bin_dir:$STUB:/usr/bin:/bin" "$ROOT_BIN" codex-exec) \
    || fail "codex-exec failed"
  assert_contains "$out" "$bin_dir/codex.opencodex-real" \
    "codex-exec must select the real binary beside the shim"
  assert_not_contains "$out" "$bin_dir/codex'" \
    "codex-exec must not select the shim itself"
  pass "an opencodex autostart shim is not the Codex binary a worker runs"
}

test_codex_config_points_at_the_proxy_without_a_second_rotator() {
  local out
  out=$("$ROOT_BIN" codex-config) || fail "codex-config failed"
  assert_contains "$out" 'model_provider="teamclaude"' "codex-config must select the TeamClaude provider"
  assert_contains "$out" 'base_url="http://127.0.0.1:3456/backend-api/codex"' \
    "codex-config must point the provider at the Codex HTTP path"
  assert_contains "$out" 'wire_api="responses"' "codex-config must use the responses wire API"
  assert_not_contains "$out" "HTTPS_PROXY" "codex-config must not add a MITM proxy"
  pass "codex-config is the TeamClaude HTTP provider and not a second proxy"
}

test_spawn_claude_carries_the_proxy_and_clears_a_direct_base_url() {
  local rec out status launch seen
  rec=$(make_case claude-up claude tc-claude-a1)
  read_case "$rec"
  out=$(run_spawn tc-claude-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "claude spawn through the stub should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "HTTPS_PROXY='http://127.0.0.1:3456'" \
    "the claude launch must carry the MITM proxy"
  assert_contains "$launch" "-u ANTHROPIC_BASE_URL" \
    "the claude launch must clear a direct base URL"
  assert_not_contains "$launch" "auto-fallback" "the claude launch must not fall back directly"
  cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/bin/sh
printf 'proxy=%s\n' "${HTTPS_PROXY-unset}"
printf 'base=%s\n' "${ANTHROPIC_BASE_URL-unset}"
SH
  chmod +x "$FAKEBIN_DIR/claude"
  seen=$(env -i HOME="$TMP_ROOT/pane" PATH="$FAKEBIN_DIR:$STUB:/usr/bin:/bin" \
    ANTHROPIC_BASE_URL='https://api.anthropic.com' /bin/sh -c "$launch") \
    || fail "the emitted claude launch failed to run"
  assert_contains "$seen" "proxy=http://127.0.0.1:3456" \
    "the claude process must see the TeamClaude proxy"
  assert_contains "$seen" "base=unset" \
    "the claude process must not keep a direct ANTHROPIC_BASE_URL"
  pass "a Claude worker launch uses TeamClaude and drops a direct base URL"
}

test_spawn_down_proxy_refuses_before_a_worker_exists() {
  local rec out status
  rec=$(make_case claude-down claude tc-claude-down-a1)
  read_case "$rec"
  install_down_teamclaude "$FAKEBIN_DIR"
  out=$(run_spawn tc-claude-down-a1 "$PROJ_DIR" --mode no-mistakes --yolo off) && status=0 || status=$?
  expect_code 1 "$status" "claude spawn must refuse when the proxy is down"
  assert_contains "$out" "no direct fallback" "the spawn refusal must say there is no direct fallback"
  assert_contains "$out" "Cannot connect to proxy" "the spawn refusal must include the proxy diagnostic"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused claude spawn still typed a launch command"
  [ ! -e "$HOME_DIR/state/tc-claude-down-a1.meta" ] || fail "a refused claude spawn wrote task metadata"
  pass "a down proxy stops the Claude launch before a worker exists"
}

test_spawn_codex_bypasses_the_shim_and_skips_the_proxy_only_for_loopback() {
  local rec out status launch seen
  rec=$(make_case codex-shim codex tc-codex-a1)
  read_case "$rec"
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/bin/sh
# opencodex codex autostart shim
printf 'shim\n'
SH
  cat > "$FAKEBIN_DIR/codex.opencodex-real" <<'SH'
#!/bin/sh
printf 'bin=%s\n' "$0"
printf 'proxy=%s\n' "${HTTPS_PROXY-unset}"
printf 'all=%s\n' "${ALL_PROXY-unset}"
printf 'ca=%s\n' "${NODE_EXTRA_CA_CERTS-unset}"
printf 'NO_PROXY=%s\n' "${NO_PROXY-unset}"
printf 'no_proxy=%s\n' "${no_proxy-unset}"
SH
  chmod +x "$FAKEBIN_DIR/codex" "$FAKEBIN_DIR/codex.opencodex-real"
  out=$(run_spawn tc-codex-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "codex spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "$FAKEBIN_DIR/codex.opencodex-real" \
    "the codex launch must execute the real binary"
  assert_contains "$launch" 'model_provider="teamclaude"' \
    "the codex launch must select the TeamClaude provider"
  seen=$(env -i HOME="$TMP_ROOT/pane" PATH="$FAKEBIN_DIR:$STUB:/usr/bin:/bin" \
    HTTPS_PROXY='http://corp.example:8080' ALL_PROXY='http://corp.example:8080' \
    NODE_EXTRA_CA_CERTS='/etc/corp-ca.pem' NO_PROXY='corp.internal' /bin/sh -c "$launch") \
    || fail "the emitted codex launch failed to run"
  assert_contains "$seen" "bin=$FAKEBIN_DIR/codex.opencodex-real" \
    "the launched process must be the real binary, not the shim"
  assert_contains "$seen" "proxy=http://corp.example:8080" \
    "the codex worker must keep the captain's HTTPS_PROXY for its other tools"
  assert_contains "$seen" "all=http://corp.example:8080" \
    "the codex worker must keep the captain's ALL_PROXY"
  assert_contains "$seen" "ca=/etc/corp-ca.pem" \
    "the codex worker must keep the captain's CA"
  assert_contains "$seen" "NO_PROXY=corp.internal,127.0.0.1,localhost" \
    "the codex launch must add loopback to the captain's NO_PROXY"
  assert_contains "$seen" "no_proxy=127.0.0.1,localhost" \
    "the codex launch must bypass a proxy for loopback when no_proxy was unset"
  printf '%s\n' "$seen" | grep -qx shim \
    && fail "the shim must not have been the process that ran"
  pass "a Codex worker reaches TeamClaude on loopback without the shim and keeps the captain's proxy"
}

test_spawn_pi_does_not_use_teamclaude() {
  local rec out status launch
  rec=$(make_case pi-keep pi tc-pi-keep-a1)
  read_case "$rec"
  printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN_DIR/pi"
  chmod +x "$FAKEBIN_DIR/pi"
  install_down_teamclaude "$FAKEBIN_DIR"
  out=$(run_spawn tc-pi-keep-a1 "$PROJ_DIR" --mode no-mistakes --yolo off --model openai-codex/gpt-5.5)
  status=$?
  expect_code 0 "$status" "a Pi worker must start without TeamClaude: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "HTTPS_PROXY" "a Pi launch must not be moved onto TeamClaude"
  assert_not_contains "$launch" "127.0.0.1:9" "a Pi launch must not name the TeamClaude proxy"
  pass "a Pi worker, even on openai-codex, does not go through TeamClaude for now"
}

test_spawn_opencode_is_unchanged() {
  local rec out status launch
  rec=$(make_case opencode-keep opencode tc-opencode-a1)
  read_case "$rec"
  out=$(run_spawn tc-opencode-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "opencode spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "opencode " "the opencode launch must still start opencode"
  assert_not_contains "$launch" "HTTPS_PROXY" "an OpenCode launch must not be moved onto TeamClaude"
  assert_not_contains "$launch" "model_provider" "an OpenCode launch must not take the Codex provider override"
  pass "an OpenCode worker launch is unchanged"
}

test_claude_env_is_mitm_without_a_direct_fallback
test_missing_cli_refuses_loudly
test_down_proxy_refuses_loudly
test_thresholds_at_policy_start_without_reapplying
test_thresholds_off_policy_are_set_per_bucket
test_threshold_read_ignores_stderr_noise
test_claude_env_carries_the_hold_timeout
test_thresholds_that_stay_off_policy_refuse_loudly
test_codex_shim_resolves_to_the_real_binary
test_codex_config_points_at_the_proxy_without_a_second_rotator
test_spawn_claude_carries_the_proxy_and_clears_a_direct_base_url
test_spawn_down_proxy_refuses_before_a_worker_exists
test_spawn_codex_bypasses_the_shim_and_skips_the_proxy_only_for_loopback
test_spawn_pi_does_not_use_teamclaude
test_spawn_opencode_is_unchanged
