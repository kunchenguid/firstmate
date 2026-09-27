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
    printf 'Switch threshold: 95%%\n'
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

test_threshold_below_95_is_applied_before_the_launch() {
  local out status file
  file="$TMP_ROOT/threshold-applied"
  printf '80%%\n' > "$file"
  out=$(FM_TEST_TEAMCLAUDE_THRESHOLD_FILE="$file" "$ROOT_BIN" claude-env 2>"$TMP_ROOT/threshold.err") && status=0 || status=$?
  expect_code 0 "$status" "a threshold TeamClaude accepts as 95% must let the launch start: $(cat "$TMP_ROOT/threshold.err")"
  assert_equals "95%" "$(cat "$file")" "the launch must apply TeamClaude's 95% threshold"
  assert_contains "$out" "HTTPS_PROXY=" "the launch fragment is produced once the threshold is 95%"
  pass "a threshold other than 95% is set to 95% and verified before the launch"
}

test_threshold_that_stays_off_95_refuses_loudly() {
  local out status
  out=$(FM_TEST_TEAMCLAUDE_THRESHOLD='80%' "$ROOT_BIN" claude-env 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "a threshold that does not become 95% must refuse"
  assert_contains "$out" "still not a flat 95%" "the refusal must say the threshold could not be verified"
  assert_not_contains "$out" "HTTPS_PROXY=" "a refused launch must not produce the proxy fragment"

  out=$(FM_TEST_TEAMCLAUDE_THRESHOLD='80%' FM_TEST_TEAMCLAUDE_SET_RC=1 "$ROOT_BIN" claude-env 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "a threshold that cannot be applied must refuse"
  assert_contains "$out" "teamclaude threshold 95\` failed" "the refusal must say applying the threshold failed"
  assert_contains "$out" "cannot write the proxy config" "the refusal must keep TeamClaude's diagnostic"
  pass "a threshold that cannot be applied or verified at 95% refuses the worker"
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

test_pi_routes_only_openai_codex() {
  local agent out status
  agent="$TMP_ROOT/pi-source"
  mkdir -p "$agent"
  out=$(PATH="/usr/bin:/bin" "$ROOT_BIN" pi-base-url --model openai/gpt-4o --provider '' \
    --agent-dir "$agent" 2>&1) && status=0 || status=$?
  expect_code 0 "$status" "an OpenAI API-key model must not require TeamClaude"
  assert_equals "" "$out" "an OpenAI API-key model must not be routed"

  out=$("$ROOT_BIN" pi-base-url --model openai-codex/gpt-5.5 --provider '' --agent-dir "$agent") \
    || fail "openai-codex pi-base-url failed"
  assert_equals "http://127.0.0.1:3456/backend-api" "$out" \
    "openai-codex must point at TeamClaude's /backend-api path"

  printf '%s\n' '{"defaultProvider":"openai-codex"}' > "$agent/settings.json"
  out=$("$ROOT_BIN" pi-base-url --model gpt-5.5 --provider '' --agent-dir "$agent") \
    || fail "a bare model pi-base-url failed"
  assert_equals "http://127.0.0.1:3456/backend-api" "$out" \
    "a bare model under an openai-codex default provider must route"
  out=$("$ROOT_BIN" pi-base-url --model '' --provider '' --agent-dir "$agent") \
    || fail "a model-less pi-base-url failed"
  assert_equals "http://127.0.0.1:3456/backend-api" "$out" \
    "a launch without --model under an openai-codex default provider must route"

  printf '%s\n' '{"defaultProvider":"anthropic"}' > "$agent/settings.json"
  out=$(PATH="/usr/bin:/bin" "$ROOT_BIN" pi-base-url --model '' --provider '' --agent-dir "$agent" 2>&1) \
    || fail "a model-less launch under another default provider must not refuse"
  assert_equals "" "$out" "a launch under another default provider must not be routed"
  pass "Pi routes openai-codex, including through the account default, and leaves API-key OpenAI alone"
}

# pi_ext_providers <ext>: load the generated Pi extension in a plain Node host
# and print each provider it registers as name=baseUrl.
pi_ext_providers() {
  EXT_PATH="$1" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
mod.default({
  on: () => {},
  events: { on: () => {} },
  registerProvider: (name, config) => console.log(`${name}=${config.baseUrl}`),
});
EOF
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

test_spawn_codex_bypasses_the_shim_and_clears_the_proxy() {
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
  assert_contains "$launch" "-u HTTPS_PROXY" \
    "the codex launch must clear an ambient MITM proxy"
  seen=$(env -i HOME="$TMP_ROOT/pane" PATH="$FAKEBIN_DIR:$STUB:/usr/bin:/bin" \
    HTTPS_PROXY='http://127.0.0.1:9' /bin/sh -c "$launch") \
    || fail "the emitted codex launch failed to run"
  assert_contains "$seen" "bin=$FAKEBIN_DIR/codex.opencodex-real" \
    "the launched process must be the real binary, not the shim"
  assert_contains "$seen" "proxy=unset" \
    "the codex process must not inherit HTTPS_PROXY"
  printf '%s\n' "$seen" | grep -qx shim \
    && fail "the shim must not have been the process that ran"
  pass "a Codex worker reaches TeamClaude without the opencodex shim or a MITM proxy"
}

test_spawn_pi_openai_codex_routes_and_api_key_does_not() {
  local rec out status launch
  cat > "$TMP_ROOT/pi-bin" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$TMP_ROOT/pi-bin"

  rec=$(make_case pi-api pi tc-pi-api-a1)
  read_case "$rec"
  cp "$TMP_ROOT/pi-bin" "$FAKEBIN_DIR/pi"
  install_down_teamclaude "$FAKEBIN_DIR"
  out=$(run_spawn tc-pi-api-a1 "$PROJ_DIR" --mode no-mistakes --yolo off --model openai/gpt-4o)
  status=$?
  expect_code 0 "$status" "Pi with an API-key model must start even when TeamClaude is down: $out"
  out=$(pi_ext_providers "$HOME_DIR/state/tc-pi-api-a1.pi-ext.ts") || fail "the Pi extension did not load: $out"
  assert_equals "" "$out" "an API-key Pi model must not register a TeamClaude provider"

  rec=$(make_case pi-codex pi tc-pi-codex-a1)
  read_case "$rec"
  cp "$TMP_ROOT/pi-bin" "$FAKEBIN_DIR/pi"
  out=$(run_spawn tc-pi-codex-a1 "$PROJ_DIR" --mode no-mistakes --yolo off --model openai-codex/gpt-5.5)
  status=$?
  expect_code 0 "$status" "Pi openai-codex spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "PI_CODING_AGENT_DIR=" \
    "an openai-codex Pi launch must keep the account's own agent directory"
  out=$(pi_ext_providers "$HOME_DIR/state/tc-pi-codex-a1.pi-ext.ts") || fail "the Pi extension did not load: $out"
  assert_equals "openai-codex=http://127.0.0.1:3456/backend-api" "$out" \
    "the per-task Pi extension must point openai-codex at TeamClaude"

  rec=$(make_case pi-default pi tc-pi-default-a1)
  read_case "$rec"
  cp "$TMP_ROOT/pi-bin" "$FAKEBIN_DIR/pi"
  mkdir -p "$HOME_DIR/user-home/.pi/agent"
  printf '%s\n' '{"defaultProvider":"openai-codex"}' > "$HOME_DIR/user-home/.pi/agent/settings.json"
  out=$(PI_CODING_AGENT_DIR='' run_spawn tc-pi-default-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "Pi spawn without --model should succeed: $out"
  out=$(pi_ext_providers "$HOME_DIR/state/tc-pi-default-a1.pi-ext.ts") || fail "the Pi extension did not load: $out"
  assert_equals "openai-codex=http://127.0.0.1:3456/backend-api" "$out" \
    "a Pi launch that defaults to openai-codex must route through TeamClaude"
  pass "a Pi worker routes openai-codex through TeamClaude and does not route API-key OpenAI"
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
test_threshold_below_95_is_applied_before_the_launch
test_threshold_that_stays_off_95_refuses_loudly
test_codex_shim_resolves_to_the_real_binary
test_codex_config_points_at_the_proxy_without_a_second_rotator
test_pi_routes_only_openai_codex
test_spawn_claude_carries_the_proxy_and_clears_a_direct_base_url
test_spawn_down_proxy_refuses_before_a_worker_exists
test_spawn_codex_bypasses_the_shim_and_clears_the_proxy
test_spawn_pi_openai_codex_routes_and_api_key_does_not
test_spawn_opencode_is_unchanged
