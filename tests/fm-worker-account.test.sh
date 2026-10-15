#!/usr/bin/env bash
# Behavior tests for the opt-in per-home worker account pin
# (config/claude-account, config/pi-account; bin/fm-worker-account-lib.sh).
#
# Each case drives the real fm-spawn.sh through the shared fake tmux, which
# records the launch command, then runs that command in a synthetic pane whose
# ambient environment carries a different account. The fake claude and pi
# answer the sign-in checks the way the real runners do - an environment
# credential counts as signed in, otherwise the selected root's stored login
# decides - and record the account environment and arguments a launched worker
# receives. tests/fm-worker-account-live-e2e.test.sh proves those answers
# against the real runners.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-account)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN PI_CODING_AGENT_DIR OPENAI_API_KEY

# make_account_fakes <fakebin> <case-dir>
# The fakes cannot read test variables during a sign-in check, which runs with
# a cleared environment, so their log paths are written into them here.
make_account_fakes() {
  local fakebin=$1 dir=$2
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  printf '%s\n' "\${CLAUDE_CONFIG_DIR-unset}" >> '$dir/claude-checks'
  [ -z "\${ANTHROPIC_API_KEY:-}\${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || exit 0
  [ -f "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.credentials.json" ]
  exit
fi
{
  printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR-unset}"
  printf 'ANTHROPIC_API_KEY=%s\n' "\${ANTHROPIC_API_KEY-unset}"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN-unset}"
  printf 'CLAUDE_CODE_USE_BEDROCK=%s\n' "\${CLAUDE_CODE_USE_BEDROCK-unset}"
} > '$dir/claude-worker'
SH
  cat > "$fakebin/pi" <<SH
#!/usr/bin/env bash
root=\${PI_CODING_AGENT_DIR:-\$HOME/.pi/agent}
case "\${1:-}" in
  --help) printf '%s\n' 'Pi 0.86.1' 'Options: --help --tui-mode <mode>'; exit 0 ;;
  auth)
    provider=\$4
    printf '%s %s\n' "\${PI_CODING_AGENT_DIR-unset}" "\$provider" >> '$dir/pi-checks'
    if [ -f "\$root/old-pi" ]; then echo "Unknown command: auth" >&2; exit 1; fi
    if [ -n "\${OPENAI_API_KEY:-}" ] || grep -qx "\$provider" "\$root/signed-in" 2>/dev/null; then
      printf '{"status":"ready","provider":"%s","authType":"oauth"}\n' "\$provider"
      exit 0
    fi
    if grep -qx "\$provider" "\$root/extension-providers" 2>/dev/null; then
      printf '{"status":"not_ready","provider":"%s","reason":"provider_not_found"}\n' "\$provider"
      exit 1
    fi
    printf '{"status":"not_ready","provider":"%s","reason":"credentials_not_configured"}\n' "\$provider"
    exit 1
    ;;
  --list-models)
    printf 'provider  model  context\n'
    [ ! -f "\$root/listed" ] || cat "\$root/listed"
    exit 0
    ;;
esac
{
  printf 'PI_CODING_AGENT_DIR=%s\n' "\${PI_CODING_AGENT_DIR-unset}"
  printf 'ARGS=%s\n' "\$*"
} > '$dir/pi-worker'
SH
  chmod +x "$fakebin/claude" "$fakebin/pi"
}

# new_case <name> <crew-harness> -> sets CASE HOME_DIR PROJ WT FAKEBIN
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_account_fakes "$FAKEBIN" "$CASE"
  make_pool_fake "$FAKEBIN" "$CASE"
  fm_test_spawn_home "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$HOME_DIR/user-home"
  : > "$CASE/launch.log"
}

# signed_in_claude_root <dir>: a Claude config root holding a stored login.
signed_in_claude_root() {
  mkdir -p "$1"
  printf '{}\n' > "$1/.credentials.json"
}

# spawn_ship <id> [fm-spawn args...]: a ship spawn from HOME_DIR whose invoking
# process carries an ambient signed-in Claude root and an ambient API key.
spawn_ship() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  signed_in_claude_root "$CASE/ambient-claude"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    ANTHROPIC_API_KEY=ambient-invoker-key \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

# run_pane: execute the recorded launch in a pane whose ambient environment
# names another account for every runner.
run_pane() {
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    CLAUDE_CONFIG_DIR="$CASE/ambient-claude" ANTHROPIC_API_KEY=ambient-pane-key \
    CLAUDE_CODE_OAUTH_TOKEN=ambient-pane-token CLAUDE_CODE_USE_BEDROCK=1 \
    PI_CODING_AGENT_DIR="$CASE/ambient-pi" OPENAI_API_KEY=ambient-pane-openai \
    bash -c "$(cat "$CASE/launch.log")" || fail "the recorded launch failed in the synthetic pane"
}

# assert_refused_before_launch <id> <out> <needle>
assert_refused_before_launch() {
  local id=$1 out=$2 needle=$3
  assert_contains "$out" "$needle" "the refusal should say: $needle"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

test_absent_pin_keeps_the_launch_unchanged() {
  local out rc id=acct-absent
  new_case absent claude
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "an unpinned Claude spawn should succeed: $out"
  assert_not_contains "$out" "account=" "an unpinned spawn must not report an account"
  assert_no_grep "account=" "$HOME_DIR/state/$id.meta" "an unpinned task record must not carry an account"
  assert_absent "$CASE/claude-checks" "an unpinned spawn must not run a sign-in check"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/ambient-claude" "$CASE/claude-worker" \
    "an unpinned launch must keep forwarding the invoking process's own Claude root"
  assert_grep "ANTHROPIC_API_KEY=ambient-pane-key" "$CASE/claude-worker" \
    "an unpinned launch must leave the pane's environment credentials alone"
  assert_absent "$CASE/pool-calls" "a home with no pool file must never run the pool command"

  new_case absent-pi pi
  out=$(spawn_ship acct-absent-pi --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "an unpinned Pi spawn with an unqualified model should succeed: $out"
  assert_not_contains "$(cat "$CASE/launch.log")" "--provider" "an unpinned Pi launch must not add a provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/ambient-pi" "$CASE/pi-worker" \
    "an unpinned Pi launch must keep the pane's own Pi root"
  pass "an absent pin leaves Claude and Pi launches exactly as they were"
}

test_claude_pin_selects_the_root_and_sheds_ambient_credentials() {
  local out rc id=acct-claude
  new_case claude-pin claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a Claude spawn pinned to a signed-in root should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the spawn should report the pinned account"
  assert_grep "account=$CASE/work" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned account"
  [ "$(cat "$CASE/claude-checks")" = "$CASE/work" ] \
    || fail "the sign-in check should ask about the pinned root only: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$CASE/work/.claude.json" 2>/dev/null)" "$WT" \
    "workspace trust should be registered in the pinned root's store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the ambient Claude store must not receive the trust entry"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "the worker should run under the pinned root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the pin"
  assert_grep "CLAUDE_CODE_OAUTH_TOKEN=unset" "$CASE/claude-worker" "an ambient OAuth token must not outrank the pin"
  assert_grep "CLAUDE_CODE_USE_BEDROCK=unset" "$CASE/claude-worker" "an ambient cloud-provider switch must not outrank the pin"
  pass "a Claude pin selects its root and sheds the credentials that would outrank it"
}

test_claude_pin_refuses_a_signed_out_root_despite_an_ambient_login() {
  local out rc id=acct-claude-out
  new_case claude-signed-out claude
  mkdir -p "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "a Claude pin to a signed-out root must refuse"
  assert_refused_before_launch "$id" "$out" "config/claude-account pins Claude workers to $CASE/work, which is not signed in"
  assert_absent "$CASE/work/.claude.json" "a refused spawn must not register trust in the pinned root"
  pass "a Claude pin refuses a signed-out root even when the invoking process has a usable login and API key"
}

test_claude_ordinary_pin_unsets_the_config_root() {
  local out rc id=acct-ordinary
  new_case ordinary claude
  printf 'ordinary' > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "an ordinary pin with no default login must refuse"
  assert_refused_before_launch "$id" "$out" "pins Claude workers to the ordinary account, which is not signed in"
  signed_in_claude_root "$HOME_DIR/user-home/.claude"
  : > "$CASE/claude-checks"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "an ordinary pin with a default login should succeed: $out"
  assert_contains "$out" "account=ordinary" "the spawn should report the ordinary account"
  [ "$(cat "$CASE/claude-checks")" = unset ] \
    || fail "the ordinary check must run with CLAUDE_CONFIG_DIR unset: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$HOME_DIR/user-home/.claude.json" 2>/dev/null)" "$WT" \
    "ordinary trust should land in the default ~/.claude.json store"
  assert_absent "$CASE/ambient-claude/.claude.json" "the ambient Claude store must not receive the trust entry"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" \
    "the ordinary account must drop an ambient CLAUDE_CONFIG_DIR"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the ordinary pin"
  pass "an ordinary Claude pin selects the default login and drops an ambient root"
}

test_malformed_pins_refuse_before_launch() {
  local out rc id=acct-bad n=0 body
  new_case malformed claude
  mkdir -p "$CASE/work"
  for body in 'relative/root' "$CASE/work"$'\r' '' 'ordinary'$'\n''environment' "$CASE/missing-root"; do
    n=$((n + 1))
    printf '%s' "$body" > "$HOME_DIR/config/claude-account"
    out=$(spawn_ship "$id-$n"); rc=$?
    expect_code 1 "$rc" "malformed pin #$n must refuse"
    assert_refused_before_launch "$id-$n" "$out" "config/claude-account"
  done
  rm "$HOME_DIR/config/claude-account"
  mkdir "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-dir"); rc=$?
  expect_code 1 "$rc" "a directory in place of the pin must refuse"
  assert_refused_before_launch "$id-dir" "$out" "config/claude-account must be a readable regular file"
  rmdir "$HOME_DIR/config/claude-account"
  printf 'ordinary\n' > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-pi" --harness pi --model openai-codex/gpt-5.5); rc=$?
  expect_code 1 "$rc" "a Pi pin without a providers line must refuse"
  assert_refused_before_launch "$id-pi" "$out" "config/pi-account must hold"
  assert_absent "$CASE/claude-checks" "a malformed pin must refuse before any sign-in check"
  pass "malformed, relative, CR-terminated, empty, extra-line, missing-root, and non-file pins refuse before launch"
}

test_pi_pin_selects_the_root_and_the_declared_provider() {
  local out rc id=acct-pi launch
  new_case pi-pin pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id" --model openai-codex/gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn pinned to a signed-in provider should succeed: $out"
  assert_contains "$out" "account=$CASE/pi-work account_provider=openai-codex" \
    "the spawn should report the pinned root and provider"
  assert_grep "account=$CASE/pi-work" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned root"
  assert_grep "account_provider=openai-codex" "$HOME_DIR/state/$id.meta" "the task record should carry the pinned provider"
  [ "$(cat "$CASE/pi-checks")" = "$CASE/pi-work openai-codex" ] \
    || fail "the sign-in check should ask the pinned root about the model's provider: $(cat "$CASE/pi-checks")"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" "--provider 'openai-codex' --model 'openai-codex/gpt-5.5'" \
    "the launch should confine Pi's model lookup to the declared provider"
  run_pane
  assert_grep "PI_CODING_AGENT_DIR=$CASE/pi-work" "$CASE/pi-worker" "the worker should run under the pinned Pi root"
  assert_grep "--provider openai-codex --model openai-codex/gpt-5.5" "$CASE/pi-worker" \
    "the worker should receive the declared provider"
  pass "a Pi pin selects its root and passes the declared provider"
}

test_pi_pin_refusals() {
  local out rc id=acct-pi-bad
  new_case pi-refusals pi
  mkdir -p "$CASE/pi-work"
  printf 'openai-codex\n' > "$CASE/pi-work/signed-in"
  printf '%s\nopenai-codex anthropic\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-bare" --model gpt-5.5); rc=$?
  expect_code 1 "$rc" "an unqualified Pi model must refuse under a pin"
  assert_refused_before_launch "$id-bare" "$out" "'gpt-5.5' names no provider"
  out=$(spawn_ship "$id-none"); rc=$?
  expect_code 1 "$rc" "a Pi launch with no model must refuse under a pin"
  assert_refused_before_launch "$id-none" "$out" "'none' names no provider"
  out=$(spawn_ship "$id-other" --model openrouter/gpt-5.5); rc=$?
  expect_code 1 "$rc" "an undeclared Pi provider must refuse"
  assert_refused_before_launch "$id-other" "$out" "names provider 'openrouter'"
  out=$(OPENAI_API_KEY=ambient-invoker-openai spawn_ship "$id-out" --model anthropic/claude-sonnet); rc=$?
  expect_code 1 "$rc" "a declared provider the root is not signed in to must refuse"
  assert_refused_before_launch "$id-out" "$out" "which is not signed in for provider 'anthropic'"
  out=$(spawn_ship "$id-raw" --harness "pi --provider openai-codex --model openai-codex/gpt-5.5"); rc=$?
  expect_code 1 "$rc" "a raw Pi launch must refuse under a pin"
  assert_refused_before_launch "$id-raw" "$out" "a raw Pi launch command runs verbatim"
  pass "a Pi pin refuses unqualified, missing, undeclared, signed-out, and raw launches"
}

test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing() {
  local out rc id=acct-pi-list
  new_case pi-listing pi
  mkdir -p "$CASE/pi-work"
  printf 'codex-native\n' > "$CASE/pi-work/extension-providers"
  printf '%s\ncodex-native openai-codex\n' "$CASE/pi-work" > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id-unlisted" --model codex-native/gpt-6); rc=$?
  expect_code 1 "$rc" "an extension provider the root lists no model for must refuse"
  assert_refused_before_launch "$id-unlisted" "$out" "no model listed for provider codex-native"
  printf 'codex-native  gpt-6  272K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-ext" --model codex-native/gpt-6); rc=$?
  expect_code 0 "$rc" "an extension provider listed under the root should launch: $out"
  : > "$CASE/pi-work/old-pi"
  printf 'openai-codex-mini  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old-near" --model openai-codex/gpt-5); rc=$?
  expect_code 1 "$rc" "a Pi without auth check must match the provider column exactly"
  assert_refused_before_launch "$id-old-near" "$out" "no model listed for provider openai-codex"
  printf 'openai-codex  gpt-5  128K\n' > "$CASE/pi-work/listed"
  out=$(spawn_ship "$id-old" --model openai-codex/gpt-5); rc=$?
  expect_code 0 "$rc" "a Pi without auth check should launch when the root lists the provider: $out"
  pass "extension providers and a Pi without auth check fall back to an exact model-listing match"
}

test_a_pin_governs_only_its_own_runner() {
  local out rc id=acct-scope
  new_case scope codex
  mkdir -p "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id-codex"); rc=$?
  expect_code 0 "$rc" "a codex spawn must ignore a Claude pin: $out"
  assert_not_contains "$out" "account=" "a codex spawn must not report a Claude pin"
  out=$(spawn_ship "$id-pi" --harness pi --model gpt-5.5); rc=$?
  expect_code 0 "$rc" "a Pi spawn must ignore a Claude pin: $out"
  assert_absent "$CASE/claude-checks" "no Claude sign-in check may run for another runner"
  pass "a Claude pin leaves codex and Pi launches unchanged"
}

test_raw_claude_command_receives_the_pin() {
  local out rc id=acct-raw
  new_case raw-claude claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id" --harness "claude --print raw"); rc=$?
  expect_code 0 "$rc" "a raw Claude spawn under a signed-in pin should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "a raw Claude spawn should report the pin"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "a raw Claude worker should run under the pinned root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "a raw Claude worker must not keep an ambient API key"
  pass "a raw Claude launch command receives the home's pin"
}

test_raw_claude_account_override_refuses_under_a_pin() {
  local out rc id=acct-raw-override var
  new_case raw-override claude
  signed_in_claude_root "$CASE/work"
  signed_in_claude_root "$CASE/other"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  for var in "CLAUDE_CONFIG_DIR=$CASE/other" ANTHROPIC_API_KEY=override-key; do
    out=$(spawn_ship "$id-${var%%=*}" --harness "FOO=1 $var claude --print raw"); rc=$?
    expect_code 1 "$rc" "a raw Claude command setting ${var%%=*} must refuse under a pin"
    assert_refused_before_launch "$id-${var%%=*}" "$out" "the raw launch command sets ${var%%=*}"
    assert_contains "$out" "remove ${var%%=*} from the raw command, or change or remove config/claude-account" \
      "the refusal should say how to proceed"
  done
  assert_absent "$CASE/claude-worker" "a refused raw override must never start Claude"
  pass "a pinned home refuses a raw Claude command that overrides the account"
}

test_raw_claude_account_override_is_kept_without_a_pin() {
  local out rc id=acct-raw-unpinned
  new_case raw-unpinned claude
  mkdir -p "$CASE/other"
  out=$(spawn_ship "$id" --harness "CLAUDE_CONFIG_DIR=$CASE/other ANTHROPIC_API_KEY=override-key claude --print raw"); rc=$?
  expect_code 0 "$rc" "an unpinned home should accept a raw Claude account override: $out"
  assert_not_contains "$out" "account=" "an unpinned raw spawn must not report an account"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/other" "$CASE/claude-worker" "an unpinned raw override should keep its own root"
  assert_grep "ANTHROPIC_API_KEY=override-key" "$CASE/claude-worker" "an unpinned raw override should keep its own key"
  pass "an unpinned home keeps a raw Claude account override"
}

test_local_secondmate_reads_the_launching_home_pin() {
  local out rc id=acct-sm sm
  new_case secondmate claude
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  sm="$CASE/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/config" "$CASE/sm-own"
  git init -q -b main "$sm"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' "$CASE/sm-own" > "$sm/config/claude-account"
  signed_in_claude_root "$CASE/ambient-claude"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$sm" --secondmate); rc=$?
  expect_code 0 "$rc" "a local secondmate spawn under the launching home's pin should succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the secondmate spawn should report the launching home's pin"
  [ "$(cat "$sm/config/claude-account")" = "$CASE/sm-own" ] \
    || fail "the launching home's pin must not be inherited over the secondmate home's own file"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" \
    "the secondmate agent should run under the launching home's pinned root"
  pass "a local secondmate reads the launching home's pin and its own home's file is never inherited over"
}

# make_pool_fake: a fake `byokit-accounts` that speaks the real pick contract.
# It prints the canned <case>/pick-<tool>.json, exits with <case>/pick.rc when
# that file holds a non-zero status and adds one plain stderr line, and records
# its argv so a test can prove the tool and pool folder it was asked about.
make_pool_fake() {
  local fakebin=$1 dir=$2
  cat > "$fakebin/byokit-accounts" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$dir/pool-calls'
rc=0
[ ! -f '$dir/pick.rc' ] || rc=\$(cat '$dir/pick.rc')
[ ! -f "$dir/pick-\${2:-none}.json" ] || cat "$dir/pick-\${2:-none}.json"
[ "\$rc" = 0 ] || printf 'error: No %s account can take a run right now.\n' "\${2:-none}" >&2
exit "\$rc"
SH
  chmod +x "$fakebin/byokit-accounts"
}

# enable_pool <home-dir> <pool-state-dir> [<command>]: writes config/account-pool.
enable_pool() {
  {
    [ -z "${3:-}" ] || printf 'command=%s\n' "$3"
    printf 'state=%s\n' "$2"
  } > "$1/config/account-pool"
  mkdir -p "$2"
}

# pool_pick_ok <case-dir> <tool> <id> <var> <folder> <unset-json-array>
pool_pick_ok() {
  printf '{"ok":true,"id":"%s","tool":"%s","name":"Pool","room":{"left":80,"freshness":"fresh"},"windows":[],"rows":[{"id":"%s","tool":"%s","name":"Pool","state":"ready","room":{"left":80,"freshness":"fresh"}}],"readAt":1,"set":{"%s":"%s"},"unset":%s}\n' \
    "$3" "$2" "$3" "$2" "$4" "$5" "$6" > "$1/pick-$2.json"
  rm -f "$1/pick.rc"
}

# pool_pick_answer <case-dir> <tool> <answer-json>: write one raw pick answer,
# so a test can drive a malformed or unusable contract through the real spawn.
pool_pick_answer() {
  printf '%s\n' "$3" > "$1/pick-$2.json"
  rm -f "$1/pick.rc"
}

test_pool_selects_an_account_when_no_pin_applies() {
  local out rc id=acct-pool canary
  new_case pool-claude claude
  enable_pool "$HOME_DIR" "$CASE/pool" "$FAKEBIN/byokit-accounts"
  mkdir -p "$CASE/pool/claude"
  printf 'pool-credential-canary\n' > "$CASE/pool/claude/.credentials.json"
  pool_pick_ok "$CASE" claude pa_aa11bb22 CLAUDE_CONFIG_DIR "$CASE/pool/claude" \
    '["ANTHROPIC_API_KEY","CLAUDE_CODE_OAUTH_TOKEN","CLAUDE_CODE_USE_BEDROCK"]'
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a pool spawn with no pin should succeed: $out"
  assert_contains "$out" "account=pa_aa11bb22" "the spawn should report the picked account"
  assert_grep "account=pa_aa11bb22" "$HOME_DIR/state/$id.meta" "the task record should carry the picked account"
  assert_grep "pick claude --json --state $CASE/pool" "$CASE/pool-calls" "the pick should name the mapped tool and the pool folder"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/pool/claude" "$CASE/claude-worker" "the worker should run under the picked account folder"
  for canary in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK; do
    assert_grep "$canary=unset" "$CASE/claude-worker" "the pick's unset list should shed $canary"
  done
  # No credential may reach the launch line, the task record, the status file, or any message.
  printf '%s\n' "$out" > "$CASE/spawn.out"
  for f in "$CASE/launch.log" "$CASE/spawn.out" "$HOME_DIR/state/$id.meta" "$HOME_DIR/state/$id.status"; do
    [ -e "$f" ] || continue
    for canary in pool-credential-canary ambient-invoker-key ambient-pane-key; do
      assert_no_grep "$canary" "$f" "$canary must never reach $f"
    done
  done
  pass "the pool picks an account, the launch carries its folder, and no credential is recorded"
}

test_pool_sheds_exactly_the_picks_unset_list() {
  local out rc id=acct-pool-shed
  new_case pool-shed claude
  enable_pool "$HOME_DIR" "$CASE/pool"
  mkdir -p "$CASE/pool/claude"
  pool_pick_ok "$CASE" claude pa_ee55ff66 CLAUDE_CONFIG_DIR "$CASE/pool/claude" '[]'
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a pool pick with an empty unset list should succeed: $out"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/pool/claude" "$CASE/claude-worker" \
    "the worker should run under the picked account folder"
  assert_grep "ANTHROPIC_API_KEY=ambient-pane-key" "$CASE/claude-worker" \
    "an empty pick unset list must leave the pane's credentials alone rather than shed the pin's list"
  assert_grep "CLAUDE_CODE_USE_BEDROCK=1" "$CASE/claude-worker" \
    "an empty pick unset list must leave every ambient credential alone"
  pass "the pool sheds exactly the pick's unset list"
}

test_a_pin_still_wins_over_the_pool() {
  local out rc id=acct-pool-pin
  new_case pool-pin claude
  enable_pool "$HOME_DIR" "$CASE/pool"
  pool_pick_ok "$CASE" claude pa_aa11bb22 CLAUDE_CONFIG_DIR "$CASE/pool/claude" '["ANTHROPIC_API_KEY"]'
  signed_in_claude_root "$CASE/work"
  printf '%s\n' "$CASE/work" > "$HOME_DIR/config/claude-account"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a pinned home with a pool file should still succeed: $out"
  assert_contains "$out" "account=$CASE/work" "the pin should win over the pool"
  assert_absent "$CASE/pool-calls" "a pin should keep the pool from being asked"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/work" "$CASE/claude-worker" "the worker should run under the pin, not the pool"
  pass "a home pin still wins over the pool"
}

test_pool_refusals_create_nothing() {
  local out rc
  new_case pool-refusal claude
  enable_pool "$HOME_DIR" "$CASE/pool"
  printf '1\n' > "$CASE/pick.rc"
  cat > "$CASE/pick-claude.json" <<'JSON'
{"ok":false,"tool":"claude","reason":"No claude account can take a run right now.","rows":[{"id":"pa_a","tool":"claude","name":"Work","state":"resting","restUntil":9999999999999},{"id":"pa_b","tool":"claude","name":"Personal","state":"signed_out"}]}
JSON
  out=$(spawn_ship acct-pool-none); rc=$?
  expect_code 1 "$rc" "a failed pool pick must refuse the spawn"
  assert_refused_before_launch acct-pool-none "$out" "cannot start a claude worker"
  assert_contains "$out" "Work resting, Personal signed out" "the refusal should say who is resting or signed out"
  assert_contains "$out" "byokit-accounts add claude" "the refusal should name the login to do"

  new_case pool-malformed claude
  printf '# a comment\n\ncommand=/usr/bin/byokit-accounts\n' > "$HOME_DIR/config/account-pool"
  out=$(spawn_ship acct-pool-bad); rc=$?
  expect_code 1 "$rc" "a pool file with no state= must refuse"
  assert_refused_before_launch acct-pool-bad "$out" "config/account-pool must name the pool folder"
  assert_absent "$CASE/pool-calls" "a malformed pool file must refuse before running the command"
  pass "a failed pick and a malformed pool file both refuse before launch"
}

test_pool_refuses_an_unusable_answer() {
  local out rc n=0 answer
  while IFS= read -r answer; do
    n=$((n + 1))
    new_case "pool-bad-$n" claude
    enable_pool "$HOME_DIR" "$CASE/pool"
    mkdir -p "$CASE/pool/claude"
    printf '{}\n' > "$CASE/pool/login.json"
    pool_pick_answer "$CASE" claude "${answer//FOLDER/$CASE/pool/claude}"
    out=$(spawn_ship "acct-pool-bad-$n"); rc=$?
    expect_code 1 "$rc" "an unusable pick answer must refuse the spawn ($answer): $out"
    assert_refused_before_launch "acct-pool-bad-$n" "$out" "answered with an unusable claude account selection"
  done <<'ANSWERS'
{"id":"pa_x","set":{"CLAUDE_CONFIG_DIR":"FOLDER"},"unset":"ANTHROPIC_API_KEY"}
{"id":"pa_x","set":{"CLAUDE_CONFIG_DIR":"FOLDER"},"unset":[123]}
{"id":"pa_x","set":{"CLAUDE_CONFIG_DIR":"FOLDER"},"unset":{"CLAUDE_CONFIG_DIR":"/x"}}
{"id":"pa_x","set":{"CLAUDE_CONFIG_DIR":"FOLDER"},"unset":["A B"]}
{"id":"pa_x","set":{"CLAUDE_CONFIG_DIR":"FOLDER"},"unset":["1BAD"]}
{"id":"pa_x","set":{"HOME":"FOLDER"},"unset":[]}
{"id":"pa_x","set":{"CLAUDE_CONFIG_DIR":"FOLDER/login.json"},"unset":[]}
ANSWERS
  pass "the pool refuses a malformed unset list, a foreign store variable, and a non-directory folder"
}

test_pool_refuses_a_raw_command_that_overrides_the_pick() {
  local out rc id=acct-pool-raw var
  new_case pool-raw claude
  enable_pool "$HOME_DIR" "$CASE/pool"
  mkdir -p "$CASE/pool/claude" "$CASE/other"
  pool_pick_ok "$CASE" claude pa_aa11bb22 CLAUDE_CONFIG_DIR "$CASE/pool/claude" '["ANTHROPIC_API_KEY"]'
  for var in "CLAUDE_CONFIG_DIR=$CASE/other" ANTHROPIC_API_KEY=override-key; do
    out=$(spawn_ship "$id-${var%%=*}" --harness "FOO=1 $var claude --print raw"); rc=$?
    expect_code 1 "$rc" "a raw Claude command setting ${var%%=*} must refuse under a pool pick"
    assert_refused_before_launch "$id-${var%%=*}" "$out" "the raw launch command sets ${var%%=*}"
    assert_contains "$out" "remove ${var%%=*} from the raw command, or remove config/account-pool" \
      "the refusal should say how to proceed"
  done
  assert_absent "$CASE/claude-worker" "a refused raw override must never start Claude"

  new_case pool-raw-ok claude
  enable_pool "$HOME_DIR" "$CASE/pool"
  mkdir -p "$CASE/pool/claude"
  pool_pick_ok "$CASE" claude pa_cc33dd44 CLAUDE_CONFIG_DIR "$CASE/pool/claude" '["ANTHROPIC_API_KEY"]'
  out=$(spawn_ship acct-pool-raw-ok --harness "FOO=1 claude --print raw"); rc=$?
  expect_code 0 "$rc" "a raw Claude command that sets nothing the pick needs should still launch: $out"
  assert_contains "$out" "account=pa_cc33dd44" "the raw spawn should report the picked account"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/pool/claude" "$CASE/claude-worker" \
    "a raw Claude worker should run under the picked folder"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" \
    "a raw Claude worker should still shed the pick's unset list"
  pass "a pool home refuses a raw launch command that overrides the pick, and keeps one that does not"
}

test_pool_config_broken_symlink_refuses() {
  local out rc id=acct-pool-link
  new_case pool-link claude
  ln -s "$CASE/missing-pool-file" "$HOME_DIR/config/account-pool"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "a config/account-pool broken symlink must refuse the spawn"
  assert_refused_before_launch "$id" "$out" "config/account-pool must be a readable regular file"
  assert_absent "$CASE/pool-calls" "a broken pool symlink must refuse before running the command"

  new_case pool-link-ok claude
  mkdir -p "$CASE/pool/claude"
  printf 'state=%s\n' "$CASE/pool" > "$CASE/pool.conf"
  ln -s "$CASE/pool.conf" "$HOME_DIR/config/account-pool"
  pool_pick_ok "$CASE" claude pa_aa11bb22 CLAUDE_CONFIG_DIR "$CASE/pool/claude" '["ANTHROPIC_API_KEY"]'
  out=$(spawn_ship acct-pool-link-ok); rc=$?
  expect_code 0 "$rc" "a config/account-pool symlink to a readable file should still be a usable pool: $out"
  assert_contains "$out" "account=pa_aa11bb22" "the pool behind a symlink should still be picked"
  pass "a broken config/account-pool symlink refuses, and a resolvable one still works"
}

test_absent_pin_keeps_the_launch_unchanged
test_claude_pin_selects_the_root_and_sheds_ambient_credentials
test_claude_pin_refuses_a_signed_out_root_despite_an_ambient_login
test_claude_ordinary_pin_unsets_the_config_root
test_malformed_pins_refuse_before_launch
test_pi_pin_selects_the_root_and_the_declared_provider
test_pi_pin_refusals
test_pi_extension_provider_and_old_pi_fall_back_to_the_model_listing
test_a_pin_governs_only_its_own_runner
test_raw_claude_command_receives_the_pin
test_raw_claude_account_override_refuses_under_a_pin
test_raw_claude_account_override_is_kept_without_a_pin
test_local_secondmate_reads_the_launching_home_pin
test_pool_selects_an_account_when_no_pin_applies
test_pool_sheds_exactly_the_picks_unset_list
test_pool_refuses_an_unusable_answer
test_pool_refuses_a_raw_command_that_overrides_the_pick
test_pool_config_broken_symlink_refuses
test_a_pin_still_wins_over_the_pool
test_pool_refusals_create_nothing

echo "# all fm-worker-account tests passed"
